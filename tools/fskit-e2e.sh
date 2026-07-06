#!/usr/bin/env bash
# fskit-e2e.sh — repeatable Finder-view certification (ADR 0009).
#
# Exercises the automatable half of the certification against the single per-user
# msld and the app-group appex socket: mount, read path, read-only or write
# behavior, fault injection, and no-stranded-mount. The GUI Finder pass stays
# manual (see docs/reports/fskit-unit5-enablement.md). The appex must already be
# enabled in System Settings; this script does not sign or enable it.
#
# Usage: tools/fskit-e2e.sh [distro] [image] [--fault] [--write]
#   distro   registry distro to mount (default: ubuntu); must already be installed
#            unless <image> is given.
#   image    optional .img/.tar/.msl to install <distro> from if absent.
#   --fault  also run the destructive fault injection (kill msld, stop distro).
#            The core run always kills msl-fsd (self-healing); --fault adds the
#            heavier scenarios that disrupt the whole VM.
#   --write  certify read-write FSKit mutations; default certifies read-only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MSL="${MSL_BIN:-$ROOT/host/.build/release/msl}"
MSL_STATE="${MSL_HOME:-$HOME/.msl}"
DEADLINE=25                       # any single FS op must return within this (s)

DISTRO="ubuntu"
IMAGE=""
FAULT=0
WRITE=0
for arg in "$@"; do
  case "$arg" in
    --fault) FAULT=1 ;;
    --write) WRITE=1 ;;
    -*) echo "fskit-e2e: unknown flag $arg" >&2; exit 2 ;;
    *) if [ -z "${DISTRO_SET:-}" ]; then DISTRO="$arg"; DISTRO_SET=1; else IMAGE="$arg"; fi ;;
  esac
done
MP="$HOME/msl/$DISTRO"
WRITE_GUEST_BASE="/tmp/msl-fskit-e2e-$$"
WRITE_HOST_BASE="$MP$WRITE_GUEST_BASE"

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

stranded(){ mount | grep -q "on $MP "; }

cleanup_written_paths(){
  [ "${WRITE:-0}" -eq 1 ] || return
  if [ -n "${WRITE_HOST_BASE:-}" ]; then
    timed "$DEADLINE" /bin/rm -rf "$WRITE_HOST_BASE" >/dev/null 2>&1 || true
  fi
  if [ -n "${WRITE_GUEST_BASE:-}" ]; then
    timed "$DEADLINE" "$MSL" run "$DISTRO" -- /bin/rm -rf "$WRITE_GUEST_BASE" \
      >/dev/null 2>&1 || true
  fi
}

cleanup(){
  cleanup_written_paths
  "$MSL" unmount "$DISTRO" --force >/dev/null 2>&1 || true
  if stranded; then /sbin/umount -f "$MP" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

guest_cat(){
  timed "$DEADLINE" "$MSL" run "$DISTRO" -- /bin/cat "$1" 2>/dev/null | tr -d '\r'
}

guest_stat_size(){
  timed "$DEADLINE" "$MSL" run "$DISTRO" -- /usr/bin/stat -c %s "$1" 2>/dev/null | tr -d ' \r'
}

guest_wc_size(){
  timed "$DEADLINE" "$MSL" run "$DISTRO" -- /usr/bin/wc -c "$1" 2>/dev/null \
    | /usr/bin/awk '{ print $1 }' | tr -d ' \r'
}

write_file(){
  timed "$DEADLINE" /bin/sh -c 'printf "%s" "$2" > "$1"' sh "$1" "$2"
}

certify_writes(){
  local file="$WRITE_HOST_BASE/file"
  local guest_file="$WRITE_GUEST_BASE/file"
  timed "$DEADLINE" /bin/mkdir -p "$WRITE_HOST_BASE" || fail "create write test dir"
  timed "$DEADLINE" /usr/bin/touch "$file" || fail "create file through mount"
  pass "create file"

  write_file "$file" "alpha" || fail "write file through mount"
  [ "$(guest_cat "$guest_file")" = "alpha" ] || fail "guest readback after write"
  pass "write/readback from guest"

  timed "$DEADLINE" /bin/sh -c \
    'printf "abcdef" > "$1"; printf "XY" | /bin/dd of="$1" bs=1 seek=2 conv=notrunc >/dev/null 2>&1; printf "++" >> "$1"' \
    sh "$file" || fail "offset/append write through mount"
  [ "$(guest_cat "$guest_file")" = "abXYef++" ] || fail "guest readback after offset/append"
  pass "offset write and append"

  timed "$DEADLINE" /bin/sh -c '/usr/bin/perl -e '"'"'print "L" x (1300 * 1024)'"'"' > "$1"' \
    sh "$WRITE_HOST_BASE/large.bin" || fail "large write through mount"
  [ "$(guest_stat_size "$WRITE_GUEST_BASE/large.bin")" = "1331200" ] || fail "large write size mismatch"
  [ "$(guest_wc_size "$WRITE_GUEST_BASE/large.bin")" = "1331200" ] || fail "large readback size mismatch"
  pass "large write/readback (>1 MiB)"

  timed "$DEADLINE" /bin/mkdir "$WRITE_HOST_BASE/dir" || fail "mkdir through mount"
  timed "$DEADLINE" /bin/test -d "$WRITE_HOST_BASE/dir" || fail "mkdir not visible"
  pass "mkdir"

  timed "$DEADLINE" /bin/ln -s file "$WRITE_HOST_BASE/link" || fail "symlink through mount"
  [ "$(timed "$DEADLINE" "$MSL" run "$DISTRO" -- /usr/bin/readlink "$WRITE_GUEST_BASE/link" 2>/dev/null | tr -d '\r')" = "file" ] \
    || fail "guest readlink after symlink"
  pass "symlink"

  timed "$DEADLINE" /bin/ln "$file" "$WRITE_HOST_BASE/hard" || fail "hard link through mount"
  local ino_a ino_b
  ino_a="$(timed "$DEADLINE" "$MSL" run "$DISTRO" -- /usr/bin/stat -c %i "$guest_file" 2>/dev/null | tr -d ' \r')"
  ino_b="$(timed "$DEADLINE" "$MSL" run "$DISTRO" -- /usr/bin/stat -c %i "$WRITE_GUEST_BASE/hard" 2>/dev/null | tr -d ' \r')"
  [ -n "$ino_a" ] && [ "$ino_a" = "$ino_b" ] || fail "hard link inode mismatch"
  pass "hard link"

  timed "$DEADLINE" /bin/mv "$WRITE_HOST_BASE/hard" "$WRITE_HOST_BASE/hard-renamed" || fail "rename through mount"
  timed "$DEADLINE" "$MSL" run "$DISTRO" -- /bin/test -e "$WRITE_GUEST_BASE/hard-renamed" \
    || fail "guest cannot see renamed file"
  pass "rename"

  timed "$DEADLINE" /bin/rm "$WRITE_HOST_BASE/hard-renamed" || fail "delete file through mount"
  timed "$DEADLINE" "$MSL" run "$DISTRO" -- /bin/test ! -e "$WRITE_GUEST_BASE/hard-renamed" \
    || fail "guest still sees deleted file"
  pass "delete file"

  timed "$DEADLINE" /bin/mkdir "$WRITE_HOST_BASE/empty" || fail "create empty dir"
  timed "$DEADLINE" /bin/rmdir "$WRITE_HOST_BASE/empty" || fail "remove empty dir"
  pass "remove empty directory"

  timed "$DEADLINE" /bin/mkdir "$WRITE_HOST_BASE/nonempty" || fail "create non-empty dir"
  write_file "$WRITE_HOST_BASE/nonempty/child" "x" || fail "populate non-empty dir"
  if timed "$DEADLINE" /bin/rmdir "$WRITE_HOST_BASE/nonempty" 2>/dev/null; then
    fail "removed non-empty directory"
  fi
  pass "reject non-empty directory removal"

  cleanup_written_paths
  timed "$DEADLINE" "$MSL" run "$DISTRO" -- /bin/test ! -e "$WRITE_GUEST_BASE" \
    || fail "write test cleanup left guest path"
  pass "write test cleanup"
}

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
if [ "$WRITE" -eq 1 ]; then
  timed 90 "$MSL" mount "$DISTRO" || fail "msl mount $DISTRO failed/timed out"
else
  timed 90 "$MSL" mount "$DISTRO" --read-only || fail "msl mount $DISTRO --read-only failed/timed out"
fi
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

# FSKit can ask for more than the guest's 1 MiB reply cap; this verifies looped reads.
# `msl run` requires an absolute argv[0] ("session argv[0] must be an absolute path").
BIG="$("$MSL" run "$DISTRO" -- /usr/bin/find /usr/lib /usr/bin -type f -size +1200k 2>/dev/null | head -1 | tr -d '\r' || true)"
if [ -n "$BIG" ] && [ -e "$MP$BIG" ]; then
  want="$("$MSL" run "$DISTRO" -- /usr/bin/stat -c %s "$BIG" 2>/dev/null | tr -d ' \r')"
  got="$(timed "$DEADLINE" /bin/cat "$MP$BIG" 2>/dev/null | wc -c | tr -d ' ')"
  [ -n "$want" ] && [ "$want" = "$got" ] || fail "multi-frame read $BIG: want=$want got=$got"
  pass "multi-frame read $BIG ($got bytes)"
else
  info "no >1 MiB file found — skipping multi-frame read check"
fi

SL="$("$MSL" run "$DISTRO" -- /usr/bin/find /etc /usr/bin -maxdepth 1 -type l 2>/dev/null | head -1 | tr -d '\r' || true)"
if [ -n "$SL" ] && [ -L "$MP$SL" ]; then
  tgt="$(timed "$DEADLINE" /usr/bin/readlink "$MP$SL" 2>/dev/null || true)"
  [ -n "$tgt" ] || fail "readlink $SL returned empty"
  case "$tgt" in /Users/*|/System/*|/private/*) fail "symlink escaped to macOS path: $tgt" ;; esac
  pass "readlink $SL -> $tgt"
else
  info "no symlink found in /etc or /usr/bin — skipping readlink check"
fi

# ---- mutation surface -----------------------------------------------------
if [ "$WRITE" -eq 1 ]; then
  certify_writes
else
  if timed "$DEADLINE" /usr/bin/touch "$MP/e2e-write-probe" 2>/dev/null; then
    rm -f "$MP/e2e-write-probe" 2>/dev/null || true
    fail "write succeeded on a read-only volume (EROFS expected)"
  fi
  pass "write rejected (read-only)"
fi

# ---- fault: kill the guest worker (self-healing) --------------------------
info "fault: killing msl-fsd in the guest"
"$MSL" run "$DISTRO" -- /usr/bin/pkill -9 -f msl-fsd >/dev/null 2>&1 || true
rc=0; timed "$DEADLINE" /bin/ls "$MP" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 124 ] || fail "op hung after msl-fsd kill (unbounded — beachball risk)"
pass "op after msl-fsd kill returned bounded (rc=$rc)"
# Worker restart is best-effort; bounded failure is acceptable, but a hung op is not.
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
  if [ "$WRITE" -eq 1 ]; then
    timed 90 "$MSL" mount "$DISTRO" >/dev/null 2>&1 || info "remount skipped (daemon restart)"
  else
    timed 90 "$MSL" mount "$DISTRO" --read-only >/dev/null 2>&1 \
      || info "remount skipped (daemon restart)"
  fi
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
