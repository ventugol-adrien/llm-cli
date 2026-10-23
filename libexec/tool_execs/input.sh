#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]] || ! jq -e '
	type == "object" and
	(.answer | type == "string")
' <<<"${1:-}" >/dev/null; then
	echo 'Usage: input.sh {"answer":"Question to ask the user"}' >&2
	exit 2
fi

prompt=$(jq -r '.answer' <<<"$1")
if ! { exec {tty_fd}<>/dev/tty; } 2>/dev/null; then
	echo 'Cannot ask for input: no readable terminal is available.' >&2
	exit 1
fi
printf '%s ' "$prompt" >&2
if ! IFS= read -r user_input <&"$tty_fd"; then
	echo 'Unable to read user input.' >&2
	exit 1
fi
exec {tty_fd}>&-
printf '%s\n' "$user_input"
