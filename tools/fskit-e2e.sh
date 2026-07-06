#!/usr/bin/env bash
# fskit-e2e.sh — repeatable read-only Finder-view certification (ADR 0009).
#
# Exercises the automatable half of the certification against the single per-user
# msld and the app-group appex socket: mount, read path, structural read-only,
# fault injection, and no-stranded-mount. The GUI Finder pass stays manual (see
# docs/reports/fskit-unit5-enablement.md). The appex must already be enabled in
# System Settings; this script does not sign or enable it.
#
# Usage: tools/fskit-e2e.sh [distro] [image] [--fault]
#   distro   registry distro to mount (default: ubuntu); must already be installed
#            unless <image> is given.
#   image    optional .img/.tar/.msl to install <distro> from if absent.
#   --fault  also run the destructive fault injection (kill msld, stop distro).
#            The core run always kills msl-fsd (self-healing); --fault adds the
#            heavier scenarios that disrupt the whole VM.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MSL="${MSL_BIN:-$ROOT/host/.build/release/msl}"
MSL_STATE="${MSL_HOME:-$HOME/.msl}"
DEADLINE=25                       # any single FS op must return within this (s)

DISTRO="ubuntu"
IMAGE=""
FAULT=0
for arg in "$@"; do
  case "$arg" in
    --fault) FAULT=1 ;;
    -*) echo "fskit-e2e: unknown flag $arg" >&2; exit 2 ;;
    *) if [ -z "${DISTRO_SET:-}" ]; then DISTRO="$arg"; DISTRO_SET=1; else IMAGE="$arg"; fi ;;
  esac
done
MP="$HOME/msl/$DISTRO"

info(){ printf 'fskit-e2e: ---   %s\n' "$1"; }
pass(){ printf 'fskit-e2e: PASS  %s\n' "$1"; }
fail(){ printf 'fskit-e2e: FAIL  %s\n' "$1" >&2; cleanup; exit 1; }

# Run a command under a hard wall-clock cap (macOS ships no `timeout`); exit 124
# on expiry so a wedged mount surfaces as a bounded FAIL, never a hung script.
timed(){ # timed <secs> <cmd...>
  local secs="$1"; shift
  perl -e '
    my $t = shift @ARGV;
    my $pid = fork();
    if ($pid == 0) { exec @ARGV or exit 127; }
    local $SIG{ALRM} = sub { kill "KILL", $pid; waitpid($pid, 0); exit 124; };
    alarm $t; waitpid($pid, 0);
    my $st = $?;
    exit(128 + ($st & 127)) if ($st & 127);   # child died from a signal (not the alarm)
    exit($st >> 8);
  ' "$secs" "$@"
}

stranded(){ mount | grep -q "on $MP "; }   # true if an mslfs mount lingers at MP

cleanup(){
  "$MSL" unmount "$DISTRO" --force >/dev/null 2>&1 || true
  if stranded; then /sbin/umount -f "$MP" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# ---- preconditions --------------------------------------------------------
[ -x "$MSL" ] || fail "msl binary not found/executable at $MSL (run: make host sign)"
if [ -n "$IMAGE" ] && ! "$MSL" list 2>/dev/null | grep -q "^$DISTRO"; then
  info "installing $DISTRO from $IMAGE"
  "$MSL" install "$DISTRO" --from "$IMAGE" || fail "install $DISTRO from $IMAGE failed"
fi
"$MSL" list 2>/dev/null | grep -q "$DISTRO" || fail "distro '$DISTRO' not installed (pass an image)"

# Registration probe: a controlled failure means the appex was reached; the
# literal "named mslfs not found" means it is not enabled yet. Bounded so a
# wedged appex fails here rather than hanging the whole run.
mkdir -p "$HOME/msl/.probe"
probe_rc=0
probe="$(timed "$DEADLINE" /sbin/mount -F -t mslfs 'msl://.probe?mount=x&nonce=y' "$HOME/msl/.probe" 2>&1)" || probe_rc=$?
/sbin/umount "$HOME/msl/.probe" >/dev/null 2>&1 || true; rmdir "$HOME/msl/.probe" 2>/dev/null || true
[ "$probe_rc" -eq 124 ] && fail "registration probe hung (>${DEADLINE}s) — appex wedged?"
if printf '%s' "$probe" | grep -Eqi "mslfs.*not found|not found.*mslfs|unknown .*type|filesystem type"; then
  fail "appex not registered/enabled — see docs/reports/fskit-unit5-enablement.md step 3"
fi
pass "appex registered (mslfs resolves)"

# ---- mount ----------------------------------------------------------------
info "mounting $DISTRO (boots the VM + distro if needed; may take a moment)"
timed 90 "$MSL" mount "$DISTRO" || fail "msl mount $DISTRO failed/timed out"
mount | grep -q "on $MP " || fail "mount table has no entry at $MP"
pass "mounted at $MP"

# ---- read path ------------------------------------------------------------
timed "$DEADLINE" /bin/test -d "$MP" || fail "stat mountpoint (bounded) failed"
pass "stat root"
timed "$DEADLINE" /bin/ls "$MP" >/dev/null || fail "readdir root (bounded) failed"
pass "readdir root ($(/bin/ls "$MP" | wc -l | tr -d ' ') entries)"

if timed "$DEADLINE" /bin/cat "$MP/etc/os-release" >/dev/null 2>&1; then
  pass "read /etc/os-release"
else
  info "no /etc/os-release (non-standard distro?) — skipping small-read check"
fi

# Multi-frame read: pick a >1 MiB guest file and verify the full length round-trips
# (the appex caps single reads at 1 MiB and loops).
# msl run needs an absolute argv[0] ("session argv[0] must be an absolute path").
BIG="$("$MSL" run "$DISTRO" -- /usr/bin/find /usr/lib /usr/bin -type f -size +1200k 2>/dev/null | head -1 | tr -d '\r' || true)"
if [ -n "$BIG" ] && [ -e "$MP$BIG" ]; then
  want="$("$MSL" run "$DISTRO" -- /usr/bin/stat -c %s "$BIG" 2>/dev/null | tr -d ' \r')"
  got="$(timed "$DEADLINE" /bin/cat "$MP$BIG" 2>/dev/null | wc -c | tr -d ' ')"
  [ -n "$want" ] && [ "$want" = "$got" ] || fail "multi-frame read $BIG: want=$want got=$got"
  pass "multi-frame read $BIG ($got bytes)"
else
  info "no >1 MiB file found — skipping multi-frame read check"
fi

# Symlink: resolve a known one through the mount.
SL="$("$MSL" run "$DISTRO" -- /usr/bin/find /etc /usr/bin -maxdepth 1 -type l 2>/dev/null | head -1 | tr -d '\r' || true)"
if [ -n "$SL" ] && [ -L "$MP$SL" ]; then
  tgt="$(timed "$DEADLINE" /usr/bin/readlink "$MP$SL" 2>/dev/null || true)"
  [ -n "$tgt" ] || fail "readlink $SL returned empty"
  case "$tgt" in /Users/*|/System/*|/private/*) fail "symlink escaped to macOS path: $tgt" ;; esac
  pass "readlink $SL -> $tgt"
else
  info "no symlink found in /etc or /usr/bin — skipping readlink check"
fi

# ---- structural read-only -------------------------------------------------
if timed "$DEADLINE" /usr/bin/touch "$MP/e2e-write-probe" 2>/dev/null; then
  rm -f "$MP/e2e-write-probe" 2>/dev/null || true
  fail "write succeeded on a read-only volume (EROFS expected)"
fi
pass "write rejected (read-only)"

# ---- fault: kill the guest worker (self-healing) --------------------------
info "fault: killing msl-fsd in the guest"
"$MSL" run "$DISTRO" -- /usr/bin/pkill -9 -f msl-fsd >/dev/null 2>&1 || true
rc=0; timed "$DEADLINE" /bin/ls "$MP" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 124 ] || fail "op hung after msl-fsd kill (unbounded — beachball risk)"
pass "op after msl-fsd kill returned bounded (rc=$rc)"
# A retry should reconnect (guest relaunches the worker) or fail bounded again.
rc=0; timed "$DEADLINE" /bin/ls "$MP" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 124 ] || fail "retry hung after msl-fsd kill"
[ "$rc" -eq 0 ] && pass "reconnected after msl-fsd kill" || info "retry bounded (rc=$rc); reconnect is remount-only"

# ---- heavier fault injection (opt-in) -------------------------------------
if [ "$FAULT" -eq 1 ]; then
  info "fault: killing msld (pidfile $MSL_STATE/msld.pid)"
  if [ -f "$MSL_STATE/msld.pid" ]; then kill -9 "$(cat "$MSL_STATE/msld.pid")" 2>/dev/null || true; fi
  rc=0; timed "$DEADLINE" /bin/ls "$MP" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 124 ] || fail "op hung after msld kill"
  pass "op after msld kill bounded (rc=$rc)"
  timed 30 "$MSL" unmount "$DISTRO" --force >/dev/null 2>&1 || true
  ! stranded || fail "mount stranded after msld kill + --force unmount"
  pass "force-unmount cleared mount after msld kill"

  info "fault: stop distro while mounted (re-mounting first)"
  timed 90 "$MSL" mount "$DISTRO" >/dev/null 2>&1 || info "remount skipped (daemon restart)"
  timed 60 "$MSL" stop "$DISTRO" >/dev/null 2>&1 || true
  ! stranded || fail "mount stranded after 'msl stop' (teardown must unmount first)"
  pass "distro stop unmounted first (no stranded mount)"
fi

# ---- teardown -------------------------------------------------------------
if mount | grep -q "on $MP "; then
  timed 30 "$MSL" unmount "$DISTRO" || fail "unmount $DISTRO failed"
fi
! stranded || fail "mount stranded at teardown"
pass "no stranded mount"

trap - EXIT
echo "fskit-e2e: OK"
