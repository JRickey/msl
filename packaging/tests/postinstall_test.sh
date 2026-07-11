#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$ROOT/packaging/scripts/postinstall-lib.sh"

out=$(MSL_TEST_DRY_RUN=1 MSL_TEST_CONSOLE_USER=loginwindow msl_postinstall_main)
[ -z "$out" ] || {
	echo "expected no actions for loginwindow, got: $out" >&2
	exit 1
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/msl-postinstall.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/home" "$tmp/app" "$tmp/bin"
touch "$tmp/bin/msl"
chmod 0755 "$tmp/bin/msl"

out=$(
	APP="$tmp/app" MSL="$tmp/bin/msl" MSL_TEST_DRY_RUN=1 \
	MSL_TEST_CONSOLE_USER=tester MSL_TEST_HOME="$tmp/home" \
	msl_postinstall_main
)
printf '%s\n' "$out" | grep -q 'fskit enable --no-restart'
printf '%s\n' "$out" | grep -q 'restart-fskitd'

out=$(
	APP="$tmp/app" MSL_TEST_DRY_RUN=1 MSL_TEST_PROCESS_REPORT= \
	MSL_TEST_MOUNT_REPORT= msl_preinstall_main
)
[ -z "$out" ] || {
	echo "expected no preinstall actions when msl is idle, got: $out" >&2
	exit 1
}

mkdir -p "$tmp/app/Contents/MacOS"
touch "$tmp/app/Contents/MacOS/msl"
chmod 0755 "$tmp/app/Contents/MacOS/msl"

# Processes present, dry-run: shutdown is attempted, but the static report cannot
# clear, so the abort guidance stands. rc 1.
if APP="$tmp/app" MSL="$tmp/bin/msl" MSL_TEST_DRY_RUN=1 \
	MSL_TEST_CONSOLE_USER=tester MSL_TEST_HOME="$tmp/home" \
	MSL_TEST_PROCESS_REPORT='123 /Applications/msl.app/Contents/MacOS/msl daemon run' \
	MSL_TEST_MOUNT_REPORT= \
	msl_preinstall_main >"$tmp/preinstall.out" 2>"$tmp/preinstall.err"; then
	echo "expected preinstall to abort when a static report never clears" >&2
	exit 1
fi
grep -q 'run-as-user .* shutdown' "$tmp/preinstall.out"
grep -q 'msl is still running' "$tmp/preinstall.err"
grep -q 'msl shutdown' "$tmp/preinstall.err"

# Success path: the after-shutdown report clears, so the install proceeds. rc 0.
out=$(
	APP="$tmp/app" MSL="$tmp/bin/msl" MSL_TEST_DRY_RUN=1 \
	MSL_TEST_CONSOLE_USER=tester MSL_TEST_HOME="$tmp/home" \
	MSL_TEST_PROCESS_REPORT='123 /Applications/msl.app/Contents/MacOS/msl daemon run' \
	MSL_TEST_MOUNT_REPORT= MSL_TEST_PROCESS_REPORT_AFTER= MSL_TEST_MOUNT_REPORT_AFTER= \
	msl_preinstall_main
)
printf '%s\n' "$out" | grep -q 'run-as-user .* shutdown'

# Broken-shim fallback: no app-bundle target, so SIGTERM the reported pid.
rm -rf "$tmp/app/Contents"
if APP="$tmp/app" MSL="$tmp/bin/msl" MSL_TEST_DRY_RUN=1 \
	MSL_TEST_CONSOLE_USER=tester MSL_TEST_HOME="$tmp/home" \
	MSL_TEST_PROCESS_REPORT='123 /usr/local/bin/msl daemon run' \
	MSL_TEST_MOUNT_REPORT= \
	msl_preinstall_main >"$tmp/preinstall-kill.out" 2>/dev/null; then
	echo "expected preinstall to abort on a broken-shim static report" >&2
	exit 1
fi
grep -q 'run-as-user .* /bin/kill 123' "$tmp/preinstall-kill.out"

# Active mslfs mount, dry-run: still reported after a settle pass. rc 1.
if APP="$tmp/app" MSL="$tmp/bin/msl" MSL_TEST_DRY_RUN=1 \
	MSL_TEST_CONSOLE_USER=tester MSL_TEST_HOME="$tmp/home" MSL_TEST_PROCESS_REPORT= \
	MSL_TEST_MOUNT_REPORT='msl://ubuntu on /Users/tester/msl/ubuntu (mslfs)' \
	msl_preinstall_main 2>"$tmp/preinstall-mount.err"; then
	echo "expected preinstall to reject an active mslfs mount" >&2
	exit 1
fi
grep -q 'Active mslfs mounts' "$tmp/preinstall-mount.err"
