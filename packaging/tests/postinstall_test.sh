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
printf '%s\n' "$out" | grep -q "remove-app $tmp/app"

if APP="$tmp/app" MSL_TEST_DRY_RUN=1 \
	MSL_TEST_PROCESS_REPORT='123 /Applications/msl.app/Contents/MacOS/msl daemon run' \
	MSL_TEST_MOUNT_REPORT= msl_preinstall_main 2>"$tmp/preinstall.err"; then
	echo "expected preinstall to reject a running msl process" >&2
	exit 1
fi
grep -q 'msl is currently running' "$tmp/preinstall.err"
grep -q 'msl shutdown' "$tmp/preinstall.err"

if APP="$tmp/app" MSL_TEST_DRY_RUN=1 MSL_TEST_PROCESS_REPORT= \
	MSL_TEST_MOUNT_REPORT='msl://ubuntu on /Users/tester/msl/ubuntu (mslfs)' \
	msl_preinstall_main 2>"$tmp/preinstall-mount.err"; then
	echo "expected preinstall to reject an active mslfs mount" >&2
	exit 1
fi
grep -q 'Active mslfs mounts' "$tmp/preinstall-mount.err"
