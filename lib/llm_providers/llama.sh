MODEL="${MODEL:-gemma4-31bunc}"
LOCATION="${LOCATION:-desktop}"
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../llama_urls.sh"

add_image() {
	REQUEST_JSON=$(jq -c \
		--rawfile image "$2" \
		'. + { images: ((.images // []) + [$image]) }' <<<"$REQUEST_JSON")
}

build_request() {
	local base_url
	base_url=$(llama:base_url "$LOCATION") || return 1
	URL="$base_url/stream-multiplex/"

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
