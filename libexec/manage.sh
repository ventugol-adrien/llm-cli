#!/usr/bin/env bash
set -e
set -o pipefail

USAGE="llm manage <pause|resume|swap> [options]"
LOCATION="desktop"
VERBOSE=false

usage() {
    cat <<EOF
Usage: $USAGE

Commands:
  pause                         Pause the running model
  resume                        Resume the current model
  swap                          Change the running model
    status                        Show the current model status and config

Options:
  -l, --location LOCATION       API location: local, desktop, or remote
  -v, --verbose                 Print the request before sending it

Swap options:
    -m, --model MODEL             Model name (defaults to current config)
    -p, --params PARAMS           Model parameter count (defaults to current config)
    -c, --context CONTEXT         Context size (defaults to current config)
    -r, --vram VRAM               VRAM requirement (defaults to current config)
    -a, --agents AGENTS           Number of agents (defaults to current config)
  --preserve-flux               Preserve Flux resources
  --clear-cpu-encoder           Clear the CPU encoder
  --no-restart                  Do not restart the model
EOF
}

if [[ $# -eq 0 ]]; then
    usage >&2
    exit 1
fi

COMMAND="$1"
shift
if [[ "$COMMAND" == "-h" || "$COMMAND" == "--help" ]]; then
    usage
    exit 0
fi
MODEL=""
PARAMS=""
CONTEXT=""
VRAM=""
AGENTS=""
PRESERVE_FLUX=false
CLEAR_CPU_ENCODER=false
RESTART=true
METHOD=POST

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -l|--location)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 1; }
            LOCATION="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -m|--model)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 1; }
            MODEL="$2"
            shift 2
            ;;
        -p|--params)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 1; }
            PARAMS="$2"
            shift 2
            ;;
        -c|--context)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 1; }
            CONTEXT="$2"
            shift 2
            ;;
        -r|--vram)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 1; }
            VRAM="$2"
            shift 2
            ;;
        -a|--agents)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 1; }
            AGENTS="$2"
            shift 2
            ;;
        --preserve-flux)
            PRESERVE_FLUX=true
            shift
            ;;
        --clear-cpu-encoder)
            CLEAR_CPU_ENCODER=true
            shift
            ;;
        --no-restart)
            RESTART=false
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

case "$LOCATION" in
    local)
        API_URL="http://localhost:8000/llm"
        ;;
    desktop)
        API_URL="https://desktop.adriens-apis.io/llm"
        ;;
    remote)
        API_URL="https://gpu.adriens-apis.io/llm"
        ;;
    *)
        echo "Unknown location: $LOCATION" >&2
        exit 1
        ;;
esac

case "$COMMAND" in
    status)
        [[ -z "$MODEL$PARAMS$CONTEXT$VRAM$AGENTS" ]] || {
            echo "Swap options are not valid with status" >&2
            exit 1
        }
        ENDPOINT="$API_URL/status"
        REQUEST=""
        METHOD=GET
        ;;
    pause)
        [[ -z "$MODEL$PARAMS$CONTEXT$VRAM$AGENTS" ]] || {
            echo "Swap options are not valid with pause" >&2
            exit 1
        }
        ENDPOINT="$API_URL/pause"
        REQUEST='{}'
        ;;
    resume)
        [[ -z "$MODEL$PARAMS$CONTEXT$VRAM$AGENTS" ]] || {
            echo "Swap options are not valid with resume" >&2
            exit 1
        }
        ENDPOINT="$API_URL/resume?preserve_flux=$PRESERVE_FLUX&clear_cpu_encoder=$CLEAR_CPU_ENCODER&restart=$RESTART"
        REQUEST='{}'
        ;;
    swap)
        if [[ -z "$MODEL" || -z "$PARAMS" || -z "$CONTEXT" || -z "$VRAM" || -z "$AGENTS" ]]; then
            CURRENT_CONFIG=$(curl --fail-with-body -sS --connect-timeout 10 "$API_URL/status" | jq -e '.config') || {
                echo "Failed to read the current model config from $API_URL/status" >&2
                exit 1
            }
            MODEL="${MODEL:-$(jq -er '.model // error("Current config is missing model")' <<< "$CURRENT_CONFIG")}"
            PARAMS="${PARAMS:-$(jq -er '.params // error("Current config is missing params")' <<< "$CURRENT_CONFIG")}"
            CONTEXT="${CONTEXT:-$(jq -er '.context // error("Current config is missing context")' <<< "$CURRENT_CONFIG")}"
            VRAM="${VRAM:-$(jq -er '.vram // error("Current config is missing vram")' <<< "$CURRENT_CONFIG")}"
            AGENTS="${AGENTS:-$(jq -er '.agents // 1' <<< "$CURRENT_CONFIG")}"
        fi
        ENDPOINT="$API_URL/change-model/?preserve_flux=$PRESERVE_FLUX&clear_cpu_encoder=$CLEAR_CPU_ENCODER&restart=$RESTART"
        REQUEST=$(jq -cn \
            --arg model "$MODEL" \
            --arg params "$PARAMS" \
            --arg context "$CONTEXT" \
            --arg vram "$VRAM" \
            --arg agents "${AGENTS:-1}" \
            '{model: $model, params: $params, context: ($context | tonumber), vram: ($vram | tonumber), agents: ($agents | tonumber)}')
        ;;
    *)
        echo "Unknown manage command: $COMMAND" >&2
        usage >&2
        exit 1
        ;;
esac

if [[ "$VERBOSE" == true ]]; then
    echo "$METHOD $ENDPOINT"
    echo "Request: $REQUEST"
fi

if [[ "$METHOD" == GET ]]; then
    curl --fail-with-body -sS --connect-timeout 10 -X GET "$ENDPOINT"
else
    curl --fail-with-body -sS --connect-timeout 10 -X "$METHOD" "$ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "$REQUEST"
fi
printf '\n'
