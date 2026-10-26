set -e
set -o pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIRECTORY/format.sh"
USAGE="llm ${LLM_CLI_PROVIDER:-llama} \"message\" [options]
	--search                Enable Gemini Google Search grounding or Grok web/X search
	--tools NAME...         Register Gemini built-in or function tools
	--image-gen             Generate an image with Grok (Grok only)
	--buff                  Print the complete response after buffering it
	--stream [true|false]   Stream the response (default true; false for Grok/Gemini)
	--schema NAME           Use NAME.yaml from the output schema directory
  -m, --model MODEL        Override the backend model
  -l, --location LOCATION  local, desktop, or remote (llama only)
  -i, --images PATH...     Attach local images or HTTP(S) URLs
  -f, --files PATH...      Attach local text files or HTTP(S) URLs
  -v, --verbose           Show request details
  -h, --help              Show this help
Piped input is appended to the message. Use \"llm llama\" for llama.cpp models.
Gemini reads its key with: secret-tool lookup service gemini key api_key
Grok reads its Authorization header value with: secret-tool lookup service grok key api_key
Gemini has no min_p equivalent; that setting remains llama-only."

MESSAGE=""
MODEL=""
LOCATION=""
PROVIDER="${LLM_CLI_PROVIDER:-llama}"
case "$PROVIDER" in
llama | gemini | grok) ;;
*)
	echo "Unknown backend: $PROVIDER" >&2
	exit 1
	;;
esac
VERBOSE=false
IMAGES=()
FILES=()
TOOL_NAMES=()
TOOL_DEFINITIONS=()
SEARCH=false
SCHEMA=""
IMAGE_GEN=false
BUFFERED=false
STREAM=true

while [[ $# -gt 0 ]]; do
	flag="$1"
	case "${flag}" in
	-h | --help)
		printf 'Usage: %s\n' "$USAGE"
		exit 0
		;;
	--search)
		SEARCH=true
		shift
		;;
	--tools)
		shift
		if [[ $# -eq 0 || "$1" == -* ]]; then
			echo "--tools requires at least one tool name" >&2
			exit 1
		fi
		while [[ $# -gt 0 && "$1" != -* ]]; do
			TOOL_NAMES+=("$1")
			shift
		done
		;;
	--image-gen)
		IMAGE_GEN=true
		shift
		;;
	--buff)
		BUFFERED=true
		shift
		;;
	--stream | --stream=*)
		stream_value=true
		if [[ "$flag" == --stream=* ]]; then
			stream_value="${flag#*=}"
			shift
		else
			shift
			if [[ $# -gt 0 && ( "$1" == true || "$1" == false || -z "$1" ) ]]; then
				stream_value="$1"
				shift
			fi
		fi
		if [[ -z "$stream_value" ]]; then
			stream_value=true
		fi
		case "$stream_value" in
		true | false) STREAM="$stream_value" ;;
		*)
			echo "--stream accepts only true or false" >&2
			exit 1
			;;
		esac
		;;
	--schema)
		if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
			echo "$flag requires a schema name" >&2
			exit 1
		fi
		SCHEMA="$2"
		shift 2
		;;
	-m | --model)
		if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
			echo "$flag requires a model" >&2
			exit 1
		fi
		MODEL="$2"
		shift 2
		;;
	-l | --location)
		if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
			echo "$flag requires a location" >&2
			exit 1
		fi
		LOCATION="$2"
		shift 2
		;;
	-v | --verbose)
		VERBOSE=true
		shift
		;;
	-i | --images)
		shift
		if [[ $# -eq 0 || "$1" == -* ]]; then
			echo "$flag requires at least one image" >&2
			exit 1
		fi
		while [[ $# -gt 0 && "$1" != -* ]]; do
			IMAGES+=("$1")
			shift
		done
		;;
	-f | --files)
		shift
		if [[ $# -eq 0 || "$1" == -* ]]; then
			echo "$flag requires at least one file" >&2
			exit 1
		fi
		while [[ $# -gt 0 && "$1" != -* ]]; do
			FILES+=("$1")
			shift
		done
		;;
	-*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	*)
		if [[ -n "$MESSAGE" ]]; then
			echo "Unexpected argument: $1 (quote the message)" >&2
			exit 1
		fi
		MESSAGE="$1"
		shift
		;;
	esac
done

if [[ -z "$MESSAGE" ]]; then
	printf 'Usage: %s\n' "$USAGE" >&2
	exit 1
fi

find_tool_config() {
	local tool_name="$1"
	local directory
	local candidate

	for directory in \
		"$HOME/.config/llm-cli/tools" \
		"$HOME/dev/llm-cli/.config/tools" \
		"$SCRIPT_DIRECTORY/../.config/tools"; do
		candidate="$directory/$tool_name.yaml"
		if [[ -f "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

load_tool() {
	local tool_name="$1"
	local tool_file
	local tool_executable
	local tool_definition
	local existing

	if [[ ! "$tool_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
		echo "Invalid tool name: $tool_name" >&2
		return 1
	fi
	for existing in "${LOADED_TOOL_NAMES[@]}"; do
		if [[ "$existing" == "$tool_name" ]]; then
			echo "Tool specified more than once: $tool_name" >&2
			return 1
		fi
	done
	if ! tool_file=$(find_tool_config "$tool_name"); then
		echo "Tool not found: $tool_name" >&2
		return 1
	fi
	if ! tool_definition=$(python3 - "$tool_file" "$tool_name" <<'PYTHON'
import json
import sys

import yaml

path, requested_name = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as stream:
        definition = yaml.safe_load(stream)
except (OSError, UnicodeError, yaml.YAMLError) as error:
    print(f"Unable to load tool configuration {path}: {error}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(definition, dict):
    print(f"Tool configuration must contain a mapping: {path}", file=sys.stderr)
    raise SystemExit(1)
tool_type = definition.get("type")
if tool_type not in ("google_search", "function"):
    print(f"Unsupported tool type {tool_type!r} in {path}; expected 'google_search' or 'function'", file=sys.stderr)
    raise SystemExit(1)
if tool_type != "function":
    print(json.dumps(definition, separators=(",", ":")))
    raise SystemExit(0)
if definition.get("name") != requested_name:
    print(
        f"Tool name in {path} must match requested name {requested_name!r}",
        file=sys.stderr,
    )
    raise SystemExit(1)
if not isinstance(definition.get("description"), str) or not definition["description"].strip():
    print(f"Tool configuration requires a non-empty description: {path}", file=sys.stderr)
    raise SystemExit(1)
parameters = definition.get("parameters")
if not isinstance(parameters, dict) or parameters.get("type") != "object":
    print(f"Tool configuration requires object parameters: {path}", file=sys.stderr)
    raise SystemExit(1)

print(json.dumps({
    "type": "function",
    "name": requested_name,
    "description": definition["description"],
    "parameters": parameters,
}, separators=(",", ":")))
PYTHON
	); then
		return 1
	fi
	if [[ "$(jq -r '.type' <<<"$tool_definition")" == function ]]; then
		tool_executable="$SCRIPT_DIRECTORY/tool_execs/$tool_name.sh"
		if [[ ! -x "$tool_executable" || -d "$tool_executable" ]]; then
			echo "Tool executable not found: $tool_executable" >&2
			return 1
		fi
		FUNCTION_TOOL_NAMES+=("$tool_name")
	fi
	TOOL_DEFINITIONS+=("$tool_definition")
	LOADED_TOOL_NAMES+=("$tool_name")
}

LOADED_TOOL_NAMES=()
FUNCTION_TOOL_NAMES=()
for tool_name in "${TOOL_NAMES[@]}"; do
	load_tool "$tool_name"
done

if [[ ${#TOOL_NAMES[@]} -gt 0 ]]; then
	if [[ "$PROVIDER" != gemini ]]; then
		echo "--tools is only supported by the Gemini backend" >&2
		exit 1
	fi
	if [[ "$IMAGE_GEN" == true ]]; then
		echo "--tools cannot be combined with --image-gen" >&2
		exit 1
	fi
fi

if [[ "$SEARCH" == true && "$PROVIDER" != gemini && "$PROVIDER" != grok ]]; then
	echo "--search is only supported by the Gemini and Grok backends" >&2
	exit 1
fi
if [[ "$STREAM" == false && "$PROVIDER" == llama ]]; then
	echo "--stream false is not supported by the llama backend" >&2
	exit 1
fi
if [[ "$IMAGE_GEN" == true ]]; then
	if [[ "$PROVIDER" != grok ]]; then
		echo "--image-gen is only supported by the Grok backend" >&2
		exit 1
	fi
	if [[ "$SEARCH" == true || -n "$SCHEMA" || ${#IMAGES[@]} -gt 0 || ${#FILES[@]} -gt 0 || ${#TOOL_NAMES[@]} -gt 0 ]]; then
		echo "--image-gen cannot be combined with --search, --schema, --images, --files, or --tools" >&2
		exit 1
	fi
fi

SCHEMA_NAME=""
SCHEMA_JSON='null'
if [[ -n "$SCHEMA" ]]; then
	SCHEMA_DIRECTORY="${LLM_CLI_SCHEMA_DIRECTORY:-/home/adrien/.config/llm-cli/output_schemas}"
	case "$SCHEMA" in
	*.yaml)
		SCHEMA_NAME="${SCHEMA%.yaml}"
		SCHEMA_FILE="$SCHEMA_DIRECTORY/$SCHEMA"
		;;
	*)
		SCHEMA_NAME="$SCHEMA"
		SCHEMA_FILE="$SCHEMA_DIRECTORY/$SCHEMA.yaml"
		;;
	esac
	if [[ ! "$SCHEMA_NAME" =~ ^[a-zA-Z0-9._-]+$ || ! -f "$SCHEMA_FILE" ]]; then
		echo "Schema not found: $SCHEMA" >&2
		exit 1
	fi
	if ! SCHEMA_JSON=$(yq -c . "$SCHEMA_FILE") || ! jq -e 'type == "object"' <<<"$SCHEMA_JSON" >/dev/null; then
		echo "Invalid YAML schema: $SCHEMA_FILE" >&2
		exit 1
	fi
fi

if [[ ! -t 0 ]]; then
	STDIN_CONTENT=""
	IFS= read -r -d '' STDIN_CONTENT || true
	if [[ -n "$STDIN_CONTENT" ]]; then
		MESSAGE+=$'\n\n'"$STDIN_CONTENT"
	fi
fi

source "$SCRIPT_DIRECTORY/../lib/llm_providers/$PROVIDER.sh"
MESSAGE_METADATA=$(jq -cn --arg model "$MODEL" '{model: $model}')

if [[ "$VERBOSE" == true ]]; then
	echo "Message: $MESSAGE"
	echo "Backend: $PROVIDER"
	echo "Model: $MODEL"
	echo "Location: $LOCATION"
	echo "Images: ${IMAGES[*]}"
	echo "Files: ${FILES[*]}"
	echo "Tools: ${TOOL_NAMES[*]}"
	echo "Search: $SEARCH"
	echo "Schema: $SCHEMA_NAME"
fi

REQ_ID="$(uuidgen)"
SYSTEM="Help the user with their query. Respond only with clean, readable CommonMark Markdown. Your response is parsed and rendered in a TTY using Python Rich Live and Rich Markdown. Use headings, paragraphs, lists, tables, fenced code blocks, bold, and italics where appropriate. Do not emit raw ANSI escape sequences. Rich does not render LaTeX: never use dollar-sign math delimiters or LaTeX commands such as \\text or \\rightarrow. Use plain text, Unicode symbols and emojis instead, such as ✓ and →."
ASSET_TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$ASSET_TEMP_DIR"' EXIT

SESSION_MESSAGES_FILE="$ASSET_TEMP_DIR/session-messages.json"
if [[ -n "${AGENT_SESSION_ID:-}" ]]; then
	source "$SCRIPT_DIRECTORY/../lib/db.sh"
	db:get_messages >"$SESSION_MESSAGES_FILE"
else
	printf '[]' >"$SESSION_MESSAGES_FILE"
fi

REQUEST_JSON=$(printf '%s' "$MESSAGE" | jq -n \
	--arg id "$REQ_ID" \
	--arg system_prompt "$SYSTEM" \
	--rawfile message /dev/stdin \
	--slurpfile session_messages "$SESSION_MESSAGES_FILE" \
	'{ id: $id, session_events: $session_messages[0], messages: [
			{ role: "system", content: $system_prompt }
		] + [
			$session_messages[0][] |
			select(.role == "user" or .role == "assistant") |
			{role, content}
		] + [
			{ role: "user", content: $message }
		] }')

if [[ ${#IMAGES[@]} -gt 0 ]]; then
	for image in "${IMAGES[@]}"; do
		image_source="$image"
		if [[ "$image" =~ ^https?:// ]]; then
			image_source="$ASSET_TEMP_DIR/image-$(date +%s%N)"
			if ! curl -fsSL --retry 2 -o "$image_source" "$image"; then
				echo "Failed to fetch image URL: $image" >&2
				exit 1
			fi
		elif [[ ! -f "$image_source" ]]; then
			echo "Image file not found: $image" >&2
			exit 1
		fi
		encoded_image="$ASSET_TEMP_DIR/encoded-image-$(date +%s%N)"
		base64 -w 0 "$image_source" >"$encoded_image"
		add_image "$image_source" "$encoded_image"
	done
fi

if [[ ${#FILES[@]} -gt 0 ]]; then
	for file in "${FILES[@]}"; do
		file_source="$file"
		if [[ "$file" =~ ^https?:// ]]; then
			file_source="$ASSET_TEMP_DIR/file-$(date +%s%N)"
			if ! curl -fsSL --retry 2 -o "$file_source" "$file"; then
				echo "Failed to fetch file URL: $file" >&2
				exit 1
			fi
		elif [[ ! -f "$file_source" ]]; then
			echo "File not found: $file" >&2
			exit 1
		fi
		REQUEST_JSON=$(jq -c \
			--arg path "$file" \
			--rawfile content "$file_source" \
			'. + { files: ((.files // []) + [{ path: $path, content: $content }]) }' <<<"$REQUEST_JSON")
	done
fi

REQUEST_FILE="$ASSET_TEMP_DIR/request.json"
TOOL_HISTORY_FILE="$ASSET_TEMP_DIR/tool-history.json"
HAS_TOOL_HISTORY=false
if [[ ${#TOOL_NAMES[@]} -gt 0 ]] ||
	jq -e 'any(.session_events[]?; .role == "assistant_step" or .role == "tool_result")' \
		<<<"$REQUEST_JSON" >/dev/null; then
	HAS_TOOL_HISTORY=true
fi
if [[ "$HAS_TOOL_HISTORY" == true ]]; then
	TOOL_HISTORY_JSON=$(jq -c '
		. as $request |
		[
			$request.session_events[]? |
			if .role == "user" then
				{type: "user_input", content: [{type: "text", text: .content}]}
			elif .role == "assistant" then
				{type: "model_output", content: [{type: "text", text: .content}]}
			elif .role == "assistant_step" or .role == "tool_result" then
				.content | fromjson
			else
				empty
			end
		] + [
			{
				type: "user_input",
				content: [{type: "text", text: $request.messages[-1].content}]
			}
		] |
		.[-1].content += [
			($request.images // [])[] | {
				type: "image",
				mime_type: .mime_type,
				data: .data
			}
		] |
		.[-1].content += [
			($request.files // [])[] | {
				type: "text",
				text: ("File: " + .path + "\n\n" + .content)
			}
		]' <<<"$REQUEST_JSON")
	printf '%s' "$TOOL_HISTORY_JSON" >"$TOOL_HISTORY_FILE"
	REQUEST_JSON=$(jq -c --slurpfile history "$TOOL_HISTORY_FILE" '.tool_history = $history[0]' <<<"$REQUEST_JSON")
fi
if [[ ${#TOOL_NAMES[@]} -gt 0 ]]; then
	if [[ -n "${AGENT_SESSION_ID:-}" ]]; then
		db:init_session
		db:insert_message user "$MESSAGE" "$MESSAGE_METADATA" "turn:$REQ_ID:user" "$REQ_ID"
	fi
	STREAM_OPTIONS=()
	if [[ "$BUFFERED" == true ]]; then
		STREAM_OPTIONS+=(--buffered)
	fi
	if [[ -n "$SCHEMA_NAME" ]]; then
		STREAM_OPTIONS+=(--structured-output)
	fi
	INTERACTION_INDEX=0
	while true; do
		printf '%s' "$TOOL_HISTORY_JSON" >"$TOOL_HISTORY_FILE"
		REQUEST_JSON=$(jq -c --slurpfile history "$TOOL_HISTORY_FILE" '.tool_history = $history[0]' <<<"$REQUEST_JSON")
		printf '%s' "$REQUEST_JSON" >"$REQUEST_FILE"
		build_request
		printf '%s' "$REQ" >"$REQUEST_FILE"
		RAW_RESPONSE_FILE="$ASSET_TEMP_DIR/tool-response.json"
		request_status="Waiting for Gemini"
		if [[ "$INTERACTION_INDEX" -gt 0 ]]; then
			request_status="Waiting for Gemini after tool results"
		fi
		if ! send_request | python3 "$SCRIPT_DIRECTORY/stream_response.py" \
			--provider gemini \
			--interaction-file "$RAW_RESPONSE_FILE" \
			--status-label "$request_status" "${STREAM_OPTIONS[@]}"; then
			if [[ -s "$RAW_RESPONSE_FILE" ]]; then
				if jq -e 'has("error")' "$RAW_RESPONSE_FILE" >/dev/null; then
					jq -r '.error.message // .error' "$RAW_RESPONSE_FILE" >&2
				else
					cat "$RAW_RESPONSE_FILE" >&2
				fi
			fi
			echo "Gemini tool request failed" >&2
			exit 1
		fi
		if ! jq -e 'type == "object" and (.steps | type == "array")' "$RAW_RESPONSE_FILE" >/dev/null; then
			echo "Gemini tool response did not contain an interaction steps array" >&2
			exit 1
		fi
		INTERACTION_STEPS=$(jq -c '.steps' "$RAW_RESPONSE_FILE")
		TOOL_HISTORY_JSON=$(jq -c --slurpfile response "$RAW_RESPONSE_FILE" '. + $response[0].steps' <<<"$TOOL_HISTORY_JSON")
		STEP_INDEX=0
		while IFS= read -r interaction_step; do
			if [[ -n "${AGENT_SESSION_ID:-}" ]]; then
				db:insert_message assistant_step "$interaction_step" "$MESSAGE_METADATA" \
					"turn:$REQ_ID:interaction:$INTERACTION_INDEX:step:$STEP_INDEX" "$REQ_ID"
			fi
			STEP_INDEX=$((STEP_INDEX + 1))
		done < <(jq -c '.[]' <<<"$INTERACTION_STEPS")
		FUNCTION_CALLS=$(jq -c '[.[] | select(.type == "function_call")]' <<<"$INTERACTION_STEPS")
		if [[ "$(jq 'length' <<<"$FUNCTION_CALLS")" -eq 0 ]]; then
			exit 0
		fi
		STOP_TOOL_EXECUTION=false
		while IFS= read -r function_call; do
			call_name=$(jq -er '.name | strings | select(length > 0)' <<<"$function_call") || {
				echo "Gemini returned a function call without a name" >&2
				exit 1
			}
			call_id=$(jq -er '.id | strings | select(length > 0)' <<<"$function_call") || {
				echo "Gemini returned a function call without an id" >&2
				exit 1
			}
			call_arguments=$(jq -ce '.arguments | select(type == "object")' <<<"$function_call") || {
				echo "Gemini returned invalid arguments for tool $call_name" >&2
				exit 1
			}
			selected=false
			for tool_name in "${FUNCTION_TOOL_NAMES[@]}"; do
				if [[ "$tool_name" == "$call_name" ]]; then
					selected=true
					break
				fi
			done
			if [[ "$selected" != true ]]; then
				echo "Gemini requested an unregistered tool: $call_name" >&2
				exit 1
			fi
			tool_executable="$SCRIPT_DIRECTORY/tool_execs/$call_name.sh"
			tool_output_file="$ASSET_TEMP_DIR/tool-output"
			tool_status=0
			if [[ "$STOP_TOOL_EXECUTION" == true ]]; then
				gate_status=not_attempted
				tool_result=$(jq -cn '{error: "Not executed because an earlier function call was not approved"}')
			else
				if "$SCRIPT_DIRECTORY/confirm_exec.sh" --tool-call "$PROVIDER" "$call_name" \
					"$tool_executable" "$call_arguments" "$call_arguments" >"$tool_output_file"; then
					gate_status=approved
					tool_result=$(jq -cn --rawfile content "$tool_output_file" '{content: $content}')
				else
					tool_status=$?
					case "$tool_status" in
					124)
						gate_status=unavailable
						tool_result=$(jq -cn '{error: "Interactive confirmation was unavailable"}')
						STOP_TOOL_EXECUTION=true
						;;
					125)
						gate_status=declined
						tool_result=$(jq -cn '{error: "Execution was declined by the user"}')
						STOP_TOOL_EXECUTION=true
						;;
					*)
						gate_status=approved
						tool_result=$(jq -cn --arg status "$tool_status" \
							'{error: ("Tool executable exited with status " + $status)}')
						;;
					esac
				fi
			fi
			gate_record=$(jq -cn \
				--arg name "$call_name" \
				--arg status "$gate_status" \
				--argjson arguments "$call_arguments" \
				--argjson exit_status "$tool_status" \
				'{tool: $name, status: $status, arguments: $arguments, exit_status: $exit_status}')
			if [[ -n "${AGENT_SESSION_ID:-}" ]]; then
				db:insert_message human_gate "$gate_record" "$MESSAGE_METADATA" \
					"turn:$REQ_ID:gate:$call_id" "$REQ_ID"
			fi
			function_result=$(jq -cn \
				--arg name "$call_name" \
				--arg call_id "$call_id" \
				--arg result "$tool_result" \
				'{
					type: "function_result",
					name: $name,
					call_id: $call_id,
					result: [{type: "text", text: $result}]
				}')
			TOOL_HISTORY_JSON=$(jq -c --argjson result "$function_result" '. + [$result]' <<<"$TOOL_HISTORY_JSON")
			if [[ -n "${AGENT_SESSION_ID:-}" ]]; then
				db:insert_message tool_result "$function_result" "$MESSAGE_METADATA" \
					"turn:$REQ_ID:result:$call_id" "$REQ_ID"
			fi
		done < <(jq -c '.[]' <<<"$FUNCTION_CALLS")
		if [[ "$STOP_TOOL_EXECUTION" == true ]]; then
			echo "One or more Gemini tool calls were not executed" >&2
			exit 1
		fi
		INTERACTION_INDEX=$((INTERACTION_INDEX + 1))
	done
fi
printf '%s' "$REQUEST_JSON" >"$REQUEST_FILE"
build_request
printf '%s' "$REQ" >"$REQUEST_FILE"
RESPONSE_FILE="$ASSET_TEMP_DIR/response.md"
STREAM_OPTIONS=()
if [[ -n "$SCHEMA_NAME" ]]; then
	STREAM_OPTIONS+=(--structured-output)
fi

if [[ "$VERBOSE" == true ]]; then
	echo "Sending request $REQ_ID to $URL with body: $REQ"
fi

if [[ "$IMAGE_GEN" == true ]]; then
	generate_image
	exit 0
fi

if [[ "$BUFFERED" == true ]]; then
	RAW_RESPONSE_FILE="$ASSET_TEMP_DIR/raw-response"
	BUFFERED_OPTIONS=(--buffered --response-file "$RESPONSE_FILE")
	if [[ -n "${AGENT_SESSION_ID:-}" ]]; then
		db:init_session
		db:insert_message user "$MESSAGE" "$MESSAGE_METADATA" "turn:$REQ_ID:user" "$REQ_ID"
	fi
	if ! send_request >"$RAW_RESPONSE_FILE"; then
		if python3 "$SCRIPT_DIRECTORY/stream_response.py" --provider "$PROVIDER" "${BUFFERED_OPTIONS[@]}" <"$RAW_RESPONSE_FILE"; then
			echo "Request to $URL failed" >&2
		fi
		exit 1
	fi
	python3 "$SCRIPT_DIRECTORY/stream_response.py" --provider "$PROVIDER" "${BUFFERED_OPTIONS[@]}" <"$RAW_RESPONSE_FILE"
	if [[ -n "${AGENT_SESSION_ID:-}" && -s "$RAW_RESPONSE_FILE" ]]; then
		IFS= read -r -d '' RESPONSE <"$RAW_RESPONSE_FILE" || true
		db:insert_message assistant "$RESPONSE" "$MESSAGE_METADATA" "turn:$REQ_ID:assistant" "$REQ_ID"
	fi
	exit 0
fi

send_request | {
	if [[ -n "${AGENT_SESSION_ID:-}" ]]; then
		db:init_session
		db:insert_message user "$MESSAGE" "$MESSAGE_METADATA" "turn:$REQ_ID:user" "$REQ_ID"
	fi
	python3 "$SCRIPT_DIRECTORY/stream_response.py" --provider "$PROVIDER" --response-file "$RESPONSE_FILE" "${STREAM_OPTIONS[@]}"
}

if [[ -n "${AGENT_SESSION_ID:-}" && -s "$RESPONSE_FILE" ]]; then
	IFS= read -r -d '' RESPONSE <"$RESPONSE_FILE" || true
	db:insert_message assistant "$RESPONSE" "$MESSAGE_METADATA" "turn:$REQ_ID:assistant" "$REQ_ID"
fi
