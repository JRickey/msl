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

msl_recheck_process_report() {
	if [ -n "${MSL_TEST_PROCESS_REPORT_AFTER+x}" ]; then
		printf '%s\n' "$MSL_TEST_PROCESS_REPORT_AFTER"
		return 0
	fi
	msl_process_report
}

msl_recheck_mount_report() {
	if [ -n "${MSL_TEST_MOUNT_REPORT_AFTER+x}" ]; then
		printf '%s\n' "$MSL_TEST_MOUNT_REPORT_AFTER"
		return 0
	fi
	msl_mount_report
}

# Run `msl shutdown` as the console user with a fixed time budget
# (MSL_PREINSTALL_SHUTDOWN_WAIT seconds) so an unresponsive daemon cannot stall
# the installer. Returns 0 if it finished in time; 1 (after killing it) if not,
# so the caller falls through to the pid-SIGTERM fallback.
msl_bounded_shutdown() {
	user="$1"
	home="$2"
	run_as_user "$user" "$home" "$MSL" shutdown &
	shutdown_pid=$!
	n=${MSL_PREINSTALL_SHUTDOWN_WAIT:-20}
	i=0
	while [ "$i" -lt "$n" ]; do
		if ! kill -0 "$shutdown_pid" 2>/dev/null; then
			wait "$shutdown_pid" 2>/dev/null || true
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	kill "$shutdown_pid" 2>/dev/null || true
	wait "$shutdown_pid" 2>/dev/null || true
	return 1
}

# Ask the per-user daemon to stop. Prefer `msl shutdown` when the shim and its
# app-bundle target are both present; otherwise SIGTERM the reported pids as the
# console user (the broken-shim case, where the app was trashed under a live daemon).
msl_shutdown_attempt() {
	user=$(console_user)
	case "$user" in
		""|root|_mbsetupuser|loginwindow)
			return 0
			;;
	esac
	home=$(home_for_user "$user")
	if [ -z "$home" ]; then
		return 0
	fi
	if [ -x "$MSL" ] && [ -x "$APP/Contents/MacOS/msl" ]; then
		if [ "${MSL_TEST_DRY_RUN:-0}" = "1" ]; then
			run_as_user "$user" "$home" "$MSL" shutdown || true
			return 0
		fi
		if msl_bounded_shutdown "$user" "$home"; then
			return 0
		fi
	fi
	pids=$(msl_process_report | /usr/bin/awk '{print $1}')
	for pid in $pids; do
		case "$pid" in
			''|*[!0-9]*) continue ;;
		esac
		run_as_user "$user" "$home" /bin/kill "$pid" || true
	done
	return 0
}

# Poll until msl processes and mounts have cleared, bounded by
# MSL_PREINSTALL_WAIT seconds. Returns 0 once clear, 1 if still busy at the cap.
# Dry-run takes a single pass since its reports are static.
msl_preinstall_settle() {
	n=${MSL_PREINSTALL_WAIT:-10}
	i=0
	while [ "$i" -lt "$n" ]; do
		procs=$(msl_recheck_process_report)
		mnts=$(msl_recheck_mount_report)
		if [ -z "$procs" ] && [ -z "$mnts" ]; then
			return 0
		fi
		i=$((i + 1))
		if [ "$i" -ge "$n" ]; then
			break
		fi
		if [ "${MSL_TEST_DRY_RUN:-0}" = "1" ]; then
			break
		fi
		sleep 1
	done
	return 1
}

msl_preinstall_main() {
	processes=$(msl_process_report)
	mounts=$(msl_mount_report)
	if [ -z "$processes" ] && [ -z "$mounts" ]; then
		return 0
	fi
	msl_shutdown_attempt
	if msl_preinstall_settle; then
		return 0
	fi
	processes=$(msl_recheck_process_report)
	mounts=$(msl_recheck_mount_report)
	{
		echo "msl is still running after an attempted shutdown."
		echo
		echo "Quit msl, close Linux shells, and unmount Finder volumes, then retry."
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
