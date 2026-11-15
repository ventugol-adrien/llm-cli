#!/usr/bin/env bash
set -e
set -o pipefail

usage() {
	cat <<'EOF'
Usage: llm manage <status|pause|resume|swap> [options]

Commands:
  status, models                List router models and their load status
  pause, unload                 Unload the selected model
  resume, load                  Load the selected model
  swap                          Load the selected model, evicting another if at capacity

Options:
  -m, --model MODEL             Preset name (LLM_MODEL_NAME; default: qwen3.5-4bunc)
  -v, --verbose                 Print the request before sending it
  -h, --help                    Show help

The model is selected per request; swap does not change the default model.
Set context, projection, and other model options in the router's models.ini.
EOF
}

if [[ $# -eq 0 ]]; then
	usage >&2
	exit 1
fi
COMMAND="$1"
shift
if [[ "$COMMAND" == -h || "$COMMAND" == --help ]]; then
	usage
	exit 0
fi
MODEL="${LLM_MODEL_NAME:-qwen3.5-4bunc}"
MODEL_EXPLICIT=false
VERBOSE=false
while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	-m | --model)
		if [[ $# -lt 2 || "$2" != *[![:space:]]* || "$2" == -* ]]; then
			echo "$1 requires a model" >&2
			exit 1
		fi
		MODEL="$2"
		MODEL_EXPLICIT=true
		shift 2
		;;
	-v | --verbose)
		VERBOSE=true
		shift
		;;
	*)
		echo "Unknown option: $1" >&2
		usage >&2
		exit 1
		;;
	esac
done

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/llama_urls.sh"
SOCKET_ARGS=()
if [[ -n "${LLAMA_SOCKET:-}" ]]; then
	API_URL="http://localhost"
	SOCKET_ARGS=(--unix-socket "$LLAMA_SOCKET")
else
	API_URL=$(llama:base_url)
fi

METHOD=POST
case "$COMMAND" in
status | models)
	if [[ "$MODEL_EXPLICIT" == true ]]; then
		echo "$COMMAND lists all models; --model is not supported" >&2
		exit 1
	fi
	METHOD=GET
	ENDPOINT="$API_URL/models"
	;;
pause | unload)
	ENDPOINT="$API_URL/models/unload"
	;;
resume | load | swap)
	ENDPOINT="$API_URL/models/load"
	;;
*)
	echo "Unknown manage command: $COMMAND" >&2
	usage >&2
	exit 1
	;;
esac

REQUEST_ARGS=()
if [[ "$METHOD" == POST ]]; then
	if [[ "$MODEL" != *[![:space:]]* ]]; then
		echo "model must be a nonempty name" >&2
		exit 1
	fi
	REQUEST=$(jq -cn --arg model "$MODEL" '{model: $model}')
	REQUEST_ARGS=(-H "Content-Type: application/json" -d "$REQUEST")
fi
if [[ "$VERBOSE" == true ]]; then
	echo "$METHOD $ENDPOINT"
	if [[ "$METHOD" == POST ]]; then echo "Request: $REQUEST"; fi
fi
curl --fail-with-body -sS --connect-timeout 10 "${SOCKET_ARGS[@]}" \
	-X "$METHOD" "$ENDPOINT" "${REQUEST_ARGS[@]}"
printf '\n'
