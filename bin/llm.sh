#!/usr/bin/env bash
set -e

SCRIPT_DIRECTORY="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
USAGE="{llama|gemini|grok|manage} [arguments]"

case "${1:-}" in
-h | --help | "")
	echo "Usage: $0 $USAGE (ask aliases llama)"
	exit 0
	;;
ask | llama)
	shift
	LLM_CLI_PROVIDER=llama "$SCRIPT_DIRECTORY/../libexec/ask.sh" "$@"
	;;
gemini | grok)
	provider="$1"
	shift
	LLM_CLI_PROVIDER="$provider" "$SCRIPT_DIRECTORY/../libexec/ask.sh" "$@"
	;;
manage)
	shift
	"$SCRIPT_DIRECTORY/../libexec/manage.sh" "$@"
	;;
*)
	echo "Usage: $0 $USAGE"
	exit 1
	;;
esac
