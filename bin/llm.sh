#!/usr/bin/env bash
set -eE

SCRIPT_DIRECTORY="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_VENV_BIN="$SCRIPT_DIRECTORY/../.venv/bin"
if [[ -x "$PROJECT_VENV_BIN/python3" ]]; then
	PATH="$PROJECT_VENV_BIN:$PATH"
	export PATH
fi
LLM_CLI_CONFIG="${LLM_CLI_CONFIG:-$HOME/.config/llm-cli}"
LLM_CLI_PROFILE_DIR="${LLM_CLI_PROFILE_DIR:-$LLM_CLI_CONFIG/profiles}"
LLM_CLI_HOOKS="${LLM_CLI_HOOKS:-$LLM_CLI_CONFIG/hooks}"
USAGE="[--profile NAME] {llama|gemini|grok|manage} [arguments]"

if [[ ! -d "$LLM_CLI_CONFIG" ]]; then
	mkdir -p "$LLM_CLI_CONFIG"
fi
if [[ ! -d "$LLM_CLI_PROFILE_DIR" ]]; then
	mkdir -p "$LLM_CLI_PROFILE_DIR"
fi
if [[ ! -d "$LLM_CLI_HOOKS" ]]; then
	mkdir -p "$LLM_CLI_HOOKS"
fi

profile_required=false
if [[ -n "${PROFILE:-}" ]]; then
	profile_required=true
fi
PROFILE="${PROFILE:-default}"
if [[ "${1:-}" == --profile ]]; then
	if [[ $# -lt 2 || ! "$2" =~ ^[a-zA-Z0-9._-]+$ || "$2" == -* ]]; then
		echo "--profile requires a profile name (without a path or .env suffix)" >&2
		exit 1
	fi
	PROFILE="$2"
	profile_required=true
	shift 2
fi
if [[ ! "$PROFILE" =~ ^[a-zA-Z0-9._-]+$ || "$PROFILE" == -* ]]; then
	echo "Invalid profile name: $PROFILE" >&2
	exit 1
fi

case "${1:-}" in
-h | --help | "")
	echo "Usage: $0 $USAGE (ask aliases llama)"
	exit 0
	;;
ask | llama)
	LLM_CLI_COMMAND=llama
	command_path="$SCRIPT_DIRECTORY/../libexec/ask.sh"
	;;
gemini | grok)
	LLM_CLI_COMMAND="$1"
	command_path="$SCRIPT_DIRECTORY/../libexec/ask.sh"
	;;
manage)
	LLM_CLI_COMMAND=manage
	command_path="$SCRIPT_DIRECTORY/../libexec/manage.sh"
	;;
*)
	echo "Usage: $0 $USAGE"
	exit 1
	;;
esac
shift
command_args=("$@")
command_status=0
LLM_CLI_PROFILE="$PROFILE"
LLM_CLI_EXIT_STATUS=0
export LLM_CLI_CONFIG LLM_CLI_PROFILE_DIR LLM_CLI_HOOKS
export LLM_CLI_COMMAND LLM_CLI_PROFILE LLM_CLI_EXIT_STATUS

source_config_file() {
	local config_file="$1"
	shift
	if [[ ! -f "$config_file" || ! -r "$config_file" ]]; then
		echo "Configuration script is not a readable file: $config_file" >&2
		return 1
	fi
	source "$config_file" "$@"
}

source_failed() {
	local status=$?
	echo "Failed to source ${config_file:-configuration script} (exit $status)" >&2
	if [[ "$LLM_CLI_EXIT_STATUS" != 0 ]]; then
		status="$LLM_CLI_EXIT_STATUS"
	fi
	exit "$status"
}
trap source_failed ERR

run_hook() {
	local hook="$LLM_CLI_HOOKS/$1.sh"
	shift
	if [[ -e "$hook" || -L "$hook" ]]; then
		source_config_file "$hook" "$@"
	fi
}

finish() {
	local status=$?
	local hook_status
	trap - EXIT ERR
	if [[ "$command_status" != 0 ]]; then
		status="$command_status"
	fi
	LLM_CLI_EXIT_STATUS="$status"
	# Isolate the final hook so errexit cannot replace an earlier failure.
	set +e
	(
		set -e
		run_hook on_exit "${command_args[@]}"
	)
	hook_status=$?
	if [[ "$hook_status" != 0 ]]; then
		echo "Failed to source $LLM_CLI_HOOKS/on_exit.sh (exit $hook_status)" >&2
		if [[ "$status" == 0 ]]; then
			status="$hook_status"
		fi
	fi
	exit "$status"
}

profile_path="$LLM_CLI_PROFILE_DIR/$PROFILE.env"
if [[ "$profile_required" == true || -e "$profile_path" || -L "$profile_path" ]]; then
	profile_shell_options="$-"
	set -a
	source_config_file "$profile_path"
	if [[ "$profile_shell_options" == *a* ]]; then
		set -a
	else
		set +a
	fi
	unset profile_shell_options
fi
if [[ "$LLM_CLI_COMMAND" != manage ]]; then
	export LLM_CLI_PROVIDER="$LLM_CLI_COMMAND"
fi

trap finish EXIT
run_hook on_start "${command_args[@]}"
if "$command_path" "${command_args[@]}"; then
	command_status=0
else
	command_status=$?
fi
LLM_CLI_EXIT_STATUS="$command_status"
if [[ "$command_status" == 0 ]]; then
	run_hook on_success "${command_args[@]}"
else
	run_hook on_error "${command_args[@]}"
fi
exit "$command_status"
