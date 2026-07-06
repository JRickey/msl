#!/bin/sh

APP="${APP:-/Applications/msl.app}"
MSL="${MSL:-/usr/local/bin/msl}"
LSREGISTER="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister}"

console_user() {
	if [ -n "${MSL_TEST_CONSOLE_USER:-}" ]; then
		printf '%s\n' "$MSL_TEST_CONSOLE_USER"
		return 0
	fi
	/bin/ls -l /dev/console | /usr/bin/awk '{print $3}'
}

home_for_user() {
	if [ -n "${MSL_TEST_HOME:-}" ]; then
		printf '%s\n' "$MSL_TEST_HOME"
		return 0
	fi
	/usr/bin/dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null \
		| /usr/bin/sed 's/^NFSHomeDirectory: //'
}

run_as_user() {
	user="$1"
	home="$2"
	shift 2
	if [ "${MSL_TEST_DRY_RUN:-0}" = "1" ]; then
		printf 'run-as-user %s %s %s\n' "$user" "$home" "$*"
		return 0
	fi
	uid=$(/usr/bin/id -u "$user")
	/bin/launchctl asuser "$uid" /usr/bin/sudo -u "$user" /usr/bin/env HOME="$home" "$@"
}

maybe_register_app() {
	if [ "${MSL_TEST_DRY_RUN:-0}" = "1" ]; then
		return 0
	fi
	if [ -x "$LSREGISTER" ] && [ -d "$APP" ]; then
		"$LSREGISTER" -f "$APP" || true
	fi
}

maybe_restart_fskitd() {
	if [ "${MSL_TEST_DRY_RUN:-0}" = "1" ]; then
		printf 'restart-fskitd\n'
		return 0
	fi
	if /usr/bin/pgrep -x fskitd >/dev/null 2>&1; then
		/usr/bin/killall fskitd || true
	fi
}

msl_postinstall_main() {
	maybe_register_app

	user=$(console_user)
	case "$user" in
		""|root|_mbsetupuser|loginwindow)
			return 0
			;;
	esac

	home=$(home_for_user "$user")
	if [ -z "$home" ] || [ ! -d "$home" ]; then
		return 0
	fi

	if [ -x "$MSL" ]; then
		run_as_user "$user" "$home" "$MSL" fskit enable --no-restart || true
	fi

	maybe_restart_fskitd

	if [ -d "$APP" ]; then
		run_as_user "$user" "$home" /usr/bin/open "$APP" || true
	fi

	return 0
}
