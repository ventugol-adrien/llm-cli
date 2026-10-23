MODEL="${MODEL:-gemini-flash-latest}"

if [[ -n "$LOCATION" ]]; then
	echo "--location is only supported by the llama backend" >&2
	exit 1
fi

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
	local model_name="${MODEL#models/}"
	local thinking_config='{"thinking_budget":2048,"thinking_summaries":"auto"}'
	local generation_config='{"temperature":0.9}'
	local instructions='Prefer Bash for scripts and command-line solutions. When Bash is not appropriate, suggest Python and briefly explain why. In Gemini API examples, use $(secret-tool lookup service gemini key api_key) instead of a literal API key or API-key placeholder. Place this command substitution inside double quotes so Bash expands it when the example is run. Never print or expose the actual API key.'
	if [[ ! "$model_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
		echo "Invalid Gemini model: $MODEL" >&2
		return 1
	fi
	case "$model_name" in
	gemini-2.5-*)
		;;
	gemini-3.6* | gemini-3.7* | gemini-3.8* | gemini-4* | gemini-flash-latest)
		thinking_config='{"thinking_level":"high","thinking_summaries":"auto"}'
		generation_config='{}'
		;;
	gemini-3*)
		thinking_config='{"thinking_level":"high","thinking_summaries":"auto"}'
		;;
	esac
	URL="https://generativelanguage.googleapis.com/v1beta/interactions"
	REQ=$(jq -c \
		--arg model "$model_name" \
		--arg instructions "$instructions" \
		--argjson thinking_config "$thinking_config" \
		--argjson generation_config "$generation_config" \
		--argjson stream "$STREAM" \
		--arg schema_name "$SCHEMA_NAME" \
		--argjson schema "$SCHEMA_JSON" '
		. as $request |
		{
			model: $model,
			input: (
				if ($request.tool_history | type) == "array" then
					$request.tool_history
				else
					(
						[$request.messages[] | select(.role != "system")] |
						if length > 1 then
							map({
								type: "text",
								text: (if .role == "assistant" then "Assistant: " else "User: " end) + .content
							})
						else
							[{type: "text", text: .[0].content}]
						end
					) + (
						[($request.images // [])[] | {
							type: "image",
							mime_type: .mime_type,
							data: .data
						}] +
						[($request.files // [])[] | {
							type: "text",
							text: ("File: " + .path + "\n\n" + .content)
						}]
					)
				end
			),
			system_instruction: (
				([$request.messages[] | select(.role == "system") | .content] + [$instructions])
				| join("\n\n")
			),
			generation_config: ($generation_config + $thinking_config),
			stream: $stream,
			store: false,
			tools: []
		} |
		if $schema_name != "" then
			.response_format = {
				type: "text",
				mime_type: "application/json",
				schema: $schema
			}
		else
			.
		end' "$REQUEST_FILE")
		if [[ "$SEARCH" == true ]]; then
			build_tools "$GOOGLE_SEARCH_TOOL"
		fi
		if [[ ${#TOOL_DEFINITIONS[@]} -gt 0 ]]; then
			build_tools "${TOOL_DEFINITIONS[@]}"
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
