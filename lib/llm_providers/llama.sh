MODEL="${MODEL:-}"
source "$SCRIPT_DIRECTORY/../lib/llama_urls.sh"

add_image() {
	local mime_type
	mime_type=$(file --brief --mime-type -- "$1")
	REQUEST_JSON=$(jq -c \
		--arg mime_type "$mime_type" \
		--rawfile image "$2" \
		'. + { images: ((.images // []) + [{mime_type: $mime_type, data: $image}]) }' <<<"$REQUEST_JSON")
}

build_request() {
	if [[ -n "${LLAMA_SOCKET:-}" ]]; then
		URL="http://localhost/v1/chat/completions"
	else
		URL="$(llama:base_url)/v1/chat/completions"
	fi

	REQ=$(jq -cn \
		--arg model "$MODEL" \
		--arg schema_name "$SCHEMA_NAME" \
		--argjson schema "$SCHEMA_JSON" \
		--rawfile request "$REQUEST_FILE" \
		'($request | fromjson) as $request |
		{
			messages: (
				$request.messages as $messages |
				$messages[:-1] + [
					$messages[-1] as $last |
					$last | .content = (
						if (($request.images // []) | length) + (($request.files // []) | length) > 0 then
							[{type: "text", text: $last.content}] +
							[($request.images // [])[] | {
								type: "image_url",
								image_url: {
									url: ("data:" + .mime_type + ";base64," + .data)
								}
							}] +
							[($request.files // [])[] | {
								type: "text",
								text: ("File: " + .path + "\n\n" + .content)
							}]
						else
							$last.content
						end
					)
				]
			),
			temperature: 0.6,
			stream: true,
			stream_options: {include_usage: true}
		} +
		(if $model != "" then {model: $model} else {} end) +
		(if $schema_name != "" then {response_format: {
			type: "json_schema",
			json_schema: {name: $schema_name, schema: $schema, strict: true}
		}} else {} end)')
}

send_request() {
	local -a socket_args=()
	if [[ -n "${LLAMA_SOCKET:-}" ]]; then
		socket_args=(--unix-socket "$LLAMA_SOCKET")
	fi
	curl --fail-with-body -N -sS "${socket_args[@]}" -X POST "$URL" \
		-H "Content-Type: application/json" \
		--data-binary "@$REQUEST_FILE"
}
