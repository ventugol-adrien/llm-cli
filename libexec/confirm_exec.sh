#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIRECTORY/format.sh"

if [[ $# -lt 1 ]]; then
	printf 'Usage: %s EXECUTABLE [ARGUMENT...]\n       %s --tool-call PROVIDER NAME EXECUTABLE ARGUMENTS_JSON [ARGUMENT...]\n' "$0" "$0" >&2
	exit 2
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
	printf 'Usage: %s EXECUTABLE [ARGUMENT...]\n       %s --tool-call PROVIDER NAME EXECUTABLE ARGUMENTS_JSON [ARGUMENT...]\n' "$0" "$0"
	exit 0
fi

tool_call=false
tool_provider=""
tool_name=""
tool_arguments=""
if [[ "$1" == "--tool-call" ]]; then
	if [[ $# -lt 5 ]]; then
		printf 'Usage: %s --tool-call PROVIDER NAME EXECUTABLE ARGUMENTS_JSON [ARGUMENT...]\n' "$0" >&2
		exit 2
	fi
	tool_call=true
	tool_provider="$2"
	tool_name="$3"
	executable="$4"
	tool_arguments="$5"
	if ! jq -e 'type == "object"' <<<"$tool_arguments" >/dev/null; then
		printf 'Tool arguments must be a JSON object.\n' >&2
		exit 2
	fi
	shift 5
else
	executable="$1"
	shift
fi

if [[ "$executable" == */* ]]; then
	if [[ ! -x "$executable" || -d "$executable" ]]; then
		printf 'Not an executable file: %s\n' "$executable" >&2
		exit 127
	fi
else
	if ! executable_path="$(type -P -- "$executable")"; then
		printf 'Executable not found in PATH: %s\n' "$executable" >&2
		exit 127
	fi
	executable="$executable_path"
fi

if ! { exec {tty_fd}<>/dev/tty; } 2>/dev/null; then
	printf 'Cannot prompt for confirmation: no readable terminal is available.\n' >&2
	exit 124
fi

if [[ "$tool_call" == true ]]; then
	python3 - "$tool_provider" "$tool_name" "$executable" "$tool_arguments" <<'PYTHON'
import json
import sys

from rich.console import Console
from rich.syntax import Syntax
from rich.text import Text

provider, name, executable, arguments = sys.argv[1:]
preview = json.dumps(json.loads(arguments), ensure_ascii=False, indent=2)
console = Console(stderr=True, highlight=False)
console.print(Text.assemble((f"{provider.capitalize()} requested tool ", "bold"), (name, "bold")))
console.print(Text(executable, style="italic #b0b0b0"))
console.print(Syntax(preview, "json", word_wrap=True))
PYTHON
else
	printf 'About to run:' >&2
	printf ' %q' "$executable" "$@" >&2
	printf '\n' >&2
fi
if [[ "$tool_call" != true ]]; then
	progress:step "Approval required before execution"
fi

confirmation_prompt='Run this executable? [y/N] '
if [[ "$tool_call" == true ]]; then
	confirmation_prompt='Run tool? [y/N] '
fi
if ! IFS= read -r -p "$confirmation_prompt" answer <&"$tty_fd"; then
	printf 'Unable to read confirmation.\n' >&2
	exit 124
fi
exec {tty_fd}>&-

case "$answer" in
y | Y | yes | YES | Yes | ok | OK | Ok | k | '')
	if [[ "$executable" == "$SCRIPT_DIRECTORY/tool_execs/input.sh" ]]; then
		exec "$executable" "$@"
	fi
	output_file=$(mktemp)
	trap 'rm -f "$output_file"' EXIT
	if progress:run "Running $(basename -- "$executable")" "$output_file" "$executable" "$@"; then
		cat "$output_file"
	else
		execution_status=$?
		cat "$output_file"
		exit "$execution_status"
	fi
	;;
*)
	printf 'Execution cancelled.\n' >&2
	exit 125
	;;
esac
