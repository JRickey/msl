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
