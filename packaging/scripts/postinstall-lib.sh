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

msl_process_report() {
	if [ -n "${MSL_TEST_PROCESS_REPORT+x}" ]; then
		printf '%s\n' "$MSL_TEST_PROCESS_REPORT"
		return 0
	fi
	/bin/ps -axo pid=,args= | /usr/bin/awk '
		/\/Applications\/msl\.app\/Contents\/MacOS\/msl/ ||
		/\/usr\/local\/bin\/msl/ ||
		/\/host\/\.build\/release\/msl/ { print }
	'
}

msl_mount_report() {
	if [ -n "${MSL_TEST_MOUNT_REPORT+x}" ]; then
		printf '%s\n' "$MSL_TEST_MOUNT_REPORT"
		return 0
	fi
	/sbin/mount | /usr/bin/awk '/mslfs/ { print }'
}

msl_preinstall_main() {
	processes=$(msl_process_report)
	mounts=$(msl_mount_report)
	if [ -n "$processes" ] || [ -n "$mounts" ]; then
		{
			echo "msl is currently running."
			echo
			echo "Close Linux shells, unmount Finder volumes, and quit msl before installing."
			echo "Suggested commands:"
			echo "  msl unmount <distro>"
			echo "  msl shutdown"
			echo
			if [ -n "$mounts" ]; then
				echo "Active mslfs mounts:"
				printf '%s\n' "$mounts"
				echo
			fi
			if [ -n "$processes" ]; then
				echo "Active msl processes:"
				printf '%s\n' "$processes"
				echo
			fi
		} >&2
		return 1
	fi
	return 0
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
