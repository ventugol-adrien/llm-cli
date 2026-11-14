MODEL="${MODEL:-gemini-flash-latest}"

GOOGLE_SEARCH_TOOL='{"type":"google_search"}'

add_image() {
	local mime_type
	mime_type=$(file --brief --mime-type -- "$1")
	REQUEST_JSON=$(jq -c \
		--arg mime_type "$mime_type" \
		--rawfile image "$2" \
		'. + { images: ((.images // []) + [{ mime_type: $mime_type, data: $image }]) }' <<<"$REQUEST_JSON")
}

build_tools() {
	local tool
	for tool in "$@"; do
		REQ=$(jq -c --argjson tool "$tool" '.tools += [$tool]' <<<"$REQ")
	done
}

build_request() {
	URL="https://generativelanguage.googleapis.com/v1beta/interactions"
	local -a payload_args=(
		--model "$MODEL"
		--stream "$STREAM"
		--schema-name "$SCHEMA_NAME"
		--schema-json "$SCHEMA_JSON"
	)
	local tool
	if [[ "$SEARCH" == true ]]; then
		payload_args+=(--search)
	fi
	for tool in "${TOOL_DEFINITIONS[@]}"; do
		payload_args+=(--tool "$tool")
	done
	if ! REQ=$(python3 "$SCRIPT_DIRECTORY/build_gemini_payload.py" "$REQUEST_FILE" "${payload_args[@]}"); then
		return 1
	fi
}

send_request() {
	local api_key
	if ! api_key=$(secret-tool lookup service gemini key api_key) || [[ -z "$api_key" ]]; then
		echo "Could not read Gemini API key: secret-tool lookup service gemini key api_key" >&2
		return 1
	fi
	if [[ "$STREAM" == true && "$BUFFERED" != true ]]; then
		python3 -c 'import json, time; print("data: " + json.dumps({"requestStartedAt": time.monotonic()}) + "\n", flush=True)'
	fi
	printf 'X-goog-api-key: %s\n' "$api_key" |
		curl --fail-with-body -N -sS -X POST "$URL" \
			-H "Content-Type: application/json" \
			-H "Api-Revision: 2026-05-20" \
			-H @- \
			--data-binary "@$REQUEST_FILE"
}
