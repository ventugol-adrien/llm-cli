if [[ "$IMAGE_GEN" == true ]]; then
	MODEL="${MODEL:-grok-imagine-image-2.0}"
else
	MODEL="${MODEL:-grok-4.7}"
fi

if [[ -n "$LOCATION" ]]; then
	echo "--location is only supported by the llama backend" >&2
	exit 1
fi

add_image() {
	local mime_type
	mime_type=$(file --brief --mime-type -- "$1")
	REQUEST_JSON=$(jq -c \
		--arg mime_type "$mime_type" \
		--rawfile image "$2" \
		'. + { images: ((.images // []) + [{type: "input_image", image_url: ("data:" + $mime_type + ";base64," + $image)}]) }' <<<"$REQUEST_JSON")
}

build_request() {
	if [[ "$IMAGE_GEN" == true ]]; then
		URL="https://api.x.ai/v1/images/generations"
		REQ=$(jq -cn --arg model "$MODEL" --arg prompt "$MESSAGE" '{model: $model, prompt: $prompt}')
		return
	fi

	URL="https://api.x.ai/v1/responses"
	REQ=$(jq -c --arg model "$MODEL" --arg schema_name "$SCHEMA_NAME" --argjson schema "$SCHEMA_JSON" --argjson search "$SEARCH" --argjson stream "$STREAM" '
		def content_text:
			map(if .type == "text" then .text else tojson end) | join("");
		def replay_event:
			if .role == "human_gate" then
				empty
			elif .role == "user" or .role == "assistant" or .role == "system" then
				{role, content}
			elif .role == "assistant_step" or .role == "tool_result" then
				.content | fromjson |
				if .type == "function_call" then
					{type: "function_call", call_id: .id, name, arguments: (.arguments | tojson)}
				elif .type == "function_result" then
					{type: "function_call_output", call_id, output: (.result | content_text)}
				elif .type == "model_output" then
					{role: "assistant", content: (.content | content_text)}
				elif .type == "thought" then
					(.summary // [] | content_text) |
					select(length > 0) |
					{role: "assistant", content: ("Thinking summary:\n" + .)}
				else
					{role: "assistant", content: ("Previous interaction event:\n" + (del(.signature) | tojson))}
				end
			else
				error("Unsupported history role for Grok: " + .role)
			end;
		. as $request | {
			model: $model,
			stream: $stream,
			store: false,
			input: (
				[$request.messages[] | select(.role == "system")] +
				[($request.session_events // [])[] | replay_event] +
				[$request.messages[-1]]
			)
		} | if $search then . + {tools: [{type: "web_search"}, {type: "x_search"}]} else . end
		| if $schema_name != "" then . + {text: {format: {
			type: "json_schema",
			name: $schema_name,
			schema: $schema,
			strict: true
		}}} else . end | .input[-1].content = (
			[{type: "input_text", text: .input[-1].content}] +
			($request.images // []) +
			[($request.files // [])[] | {type: "input_text", text: ("File: " + .path + "\n\n" + .content)}]
		)' "$REQUEST_FILE")
}

send_request() {
	local api_key
	if ! api_key=$(secret-tool lookup service grok key api_key) || [[ -z "$api_key" ]]; then
		echo "Could not read Grok API key: secret-tool lookup service grok key api_key" >&2
		return 1
	fi
	if [[ "$STREAM" == true && "$BUFFERED" != true ]]; then
		python3 -c 'import json, time; print("data: " + json.dumps({"requestStartedAt": time.monotonic()}) + "\n", flush=True)'
	fi
	printf '%s: %s %s\n' 'Authorization' 'Bearer' "$api_key" |
		curl --fail-with-body -N -sS -X POST "$URL" \
			-H "Content-Type: application/json" \
			-H @- \
			--data-binary "@$REQUEST_FILE"
}

generate_image() {
	local api_key response image_url
	if ! command -v notify-send >/dev/null 2>&1; then
		echo "notify-send is required to notify when Grok image generation completes" >&2
		return 1
	fi
	if ! api_key=$(secret-tool lookup service grok key api_key) || [[ -z "$api_key" ]]; then
		echo "Could not read Grok API key: secret-tool lookup service grok key api_key" >&2
		return 1
	fi
	if ! response=$(printf '%s: %s %s\n' 'Authorization' 'Bearer' "$api_key" |
		curl --fail-with-body -sS -X POST "$URL" \
			-H "Content-Type: application/json" \
			-H @- \
			--data-binary "@$REQUEST_FILE"); then
		echo "Grok image generation request failed" >&2
		if [[ -n "$response" ]]; then
			printf '%s\n' "$response" >&2
		fi
		return 1
	fi
	if ! image_url=$(jq -er '.data[0].url | select(type == "string" and test("^https?://"))' <<<"$response"); then
		echo "Grok image generation response did not contain a valid image URL" >&2
		return 1
	fi
	if [[ "$BUFFERED" == true ]]; then
		printf '%s\n' "$response"
	else
		printf '%s\n' "$image_url"
	fi
	if ! notify-send "Grok image generated" "$image_url"; then
		echo "Failed to send Grok image generation notification" >&2
		return 1
	fi
}
