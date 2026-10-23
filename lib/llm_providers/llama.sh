MODEL="${MODEL:-gemma4-31bunc}"
LOCATION="${LOCATION:-desktop}"

add_image() {
	REQUEST_JSON=$(jq -c \
		--rawfile image "$2" \
		'. + { images: ((.images // []) + [$image]) }' <<<"$REQUEST_JSON")
}

build_request() {
	URL="https://desktop.adriens-apis.io/llm/stream-multiplex/"
	case "$LOCATION" in
	local)
		URL="http://localhost:8000/llm/stream-multiplex/"
		;;
	desktop)
		;;
	remote)
		URL="https://gpu.adriens-apis.io/llm/stream-multiplex/"
		;;
	*)
		echo "Unknown location: $LOCATION" >&2
		return 1
		;;
	esac

	REQ=$(jq -cn \
		--arg model "$MODEL" \
		--arg schema_name "$SCHEMA_NAME" \
		--argjson schema "$SCHEMA_JSON" \
		--rawfile request "$REQUEST_FILE" \
		'{ requests: [($request | fromjson) + {
			chat_template_kwargs: { enable_thinking: true },
			temperature: 0.9,
			min_p: 0.8,
			max_tokens: 4096,
			thinking_budget_tokens: 2048
		} + (if $schema_name != "" then {response_format: {
			type: "json_schema",
			json_schema: {name: $schema_name, schema: $schema, strict: true}
		}} else {} end)], model: $model }')
}

send_request() {
	curl --fail-with-body -N -sS -X POST "$URL" \
		-H "Content-Type: application/json" \
		--data-binary "@$REQUEST_FILE"
}
