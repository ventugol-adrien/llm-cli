#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIRECTORY=$(mktemp -d)
trap 'rm -rf "$TEST_DIRECTORY"' EXIT
export TEST_DIRECTORY
export HOME="$TEST_DIRECTORY/home"
unset AGENT_SESSION_ID
mkdir -p "$TEST_DIRECTORY/schemas"
printf '%s\n' \
	'type: object' \
	'properties:' \
	'  result:' \
	'    type: boolean' \
	'required:' \
	'  - result' \
	'additionalProperties: false' >"$TEST_DIRECTORY/schemas/boolean.yaml"
export LLM_CLI_SCHEMA_DIRECTORY="$TEST_DIRECTORY/schemas"

printf 'file content\nwith "quotes"\n' >"$TEST_DIRECTORY/notes.txt"
printf 'another file\n' >"$TEST_DIRECTORY/notes [1].txt"
read_arguments=$(jq -cn --arg first "$TEST_DIRECTORY/notes.txt" \
	--arg second "$TEST_DIRECTORY/notes [1].txt" '{paths:[$first,$second]}')
bash "$ROOT/libexec/tool_execs/read.sh" "$read_arguments" >"$TEST_DIRECTORY/read-output"
{
	printf '==> %s <==\nfile content\nwith "quotes"\n\n' "$TEST_DIRECTORY/notes.txt"
	printf '==> %s <==\nanother file\n' "$TEST_DIRECTORY/notes [1].txt"
} >"$TEST_DIRECTORY/read-expected"
cmp "$TEST_DIRECTORY/read-expected" "$TEST_DIRECTORY/read-output"
read_arguments=$(jq -cn --arg path "$TEST_DIRECTORY/notes [1].txt" '{paths:[$path]}')
bash "$ROOT/libexec/tool_execs/read.sh" "$read_arguments" >"$TEST_DIRECTORY/read-output"
cmp "$TEST_DIRECTORY/notes [1].txt" "$TEST_DIRECTORY/read-output"
read_arguments=$(jq -cn --arg path "$TEST_DIRECTORY/missing.txt" '{paths:[$path]}')
if bash "$ROOT/libexec/tool_execs/read.sh" "$read_arguments" \
	>"$TEST_DIRECTORY/read-output" 2>"$TEST_DIRECTORY/read-error"; then
	echo 'Expected read to fail for a missing file' >&2
	exit 1
fi
rg -q 'missing.txt' "$TEST_DIRECTORY/read-error"
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5x8AAAAASUVORK5CYII=' | base64 -d >"$TEST_DIRECTORY/image.png"

secret-tool() {
	[[ "$*" == 'lookup service gemini key api_key' || "$*" == 'lookup service grok key api_key' ]] || return 1
	if [[ "${MISSING_KEY:-}" == true ]]; then
		return 1
	fi
	printf '%s\n' 'test-key-not-a-real-secret'
}

notify-send() {
	printf '%s\n' "$@" >"$TEST_DIRECTORY/notification"
}

curl() {
	local url='' output='' body='' header=''
	local grok_header
	grok_header=$(printf '%s: %s %s' 'Authorization' 'Bearer' 'test-key-not-a-real-secret')
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-o)
			output="$2"
			shift 2
			;;
		--data-binary)
			body="${2#@}"
			shift 2
			;;
		-H)
			if [[ "$2" == '@-' ]]; then
				IFS= read -r header
			fi
			shift 2
			;;
		http*)
			url="$1"
			shift
			;;
		*)
			shift
			;;
		esac
	done
	if [[ -n "$output" ]]; then
		case "$url" in
		*/image.png) cp "$TEST_DIRECTORY/image.png" "$output" ;;
		*/notes.txt) cp "$TEST_DIRECTORY/notes.txt" "$output" ;;
		*) return 22 ;;
		esac
		return
	fi
	cp "$body" "$TEST_DIRECTORY/request.json"
	printf '%s' "$url" >"$TEST_DIRECTORY/url"
	if [[ "${HTTP_ERROR:-}" == true ]]; then
		printf '%s\n' '{' '  "error": {' '    "message": "test HTTP error"' '  }' '}'
		return 22
	fi
	if [[ "$url" == https://generativelanguage.googleapis.com/* ]]; then
		[[ "$header" == 'X-goog-api-key: test-key-not-a-real-secret' ]] || return 1
		if [[ "${INPUT_TEST_MODE:-false}" == true ]]; then
			if jq -e '.input[-1].type == "function_result"' "$TEST_DIRECTORY/request.json" >/dev/null; then
				printf 'data: %s\n\n' \
					'{"event_type":"step.delta","delta":{"type":"text","text":"Thanks for your answer."}}' \
					'{"event_type":"interaction.completed","interaction":{"status":"completed"}}'
			else
				printf 'data: %s\n\n' \
					'{"event_type":"step.start","index":0,"step":{"type":"function_call","id":"input-call","name":"input","arguments":{}}}' \
					'{"event_type":"step.delta","index":0,"delta":{"type":"arguments_delta","arguments":"{\"answer\":\"Which file should I read?\"}"}}' \
					'{"event_type":"step.stop","index":0}' \
					'{"event_type":"interaction.completed","interaction":{"status":"requires_action"}}'
			fi
			return
		fi
		if [[ "${TOOL_TEST_MODE:-false}" == true ]]; then
			local request_number=0
			if [[ -f "$TEST_DIRECTORY/tool_request_number" ]]; then
				request_number=$(<"$TEST_DIRECTORY/tool_request_number")
			fi
			request_number=$((request_number + 1))
			printf '%s' "$request_number" >"$TEST_DIRECTORY/tool_request_number"
			if jq -e '.input[-1].type == "function_result"' "$TEST_DIRECTORY/request.json" >/dev/null; then
				local response_step
				response_step=$(jq -cn \
					'{type:"model_output",content:[]}')
				printf 'data: %s\n\n' "$(jq -cn --argjson step "$response_step" \
					'{event_type:"step.start",index:0,step:$step}')"
				printf 'data: %s\n\n' \
					'{"event_type":"step.delta","index":0,"delta":{"type":"text","text":"I read the requested file."}}'
				printf 'data: %s' "$(jq -cn --argjson step "$response_step" \
					'{event_type:"interaction.completed",interaction:{status:"completed",steps:[$step],usage:{total_tokens:652,total_output_tokens:12}}}')"
			else
				printf 'data: %s\n\n' \
					'{"event_type":"step.start","index":0,"step":{"type":"thought","summary":[{"type":"text","text":"Checking the requested file."}]}}'
				printf 'data: %s\n\n' \
					'{"event_type":"step.delta","index":0,"delta":{"type":"thought_summary","content":{"type":"text","text":" I will use read."}}}'
				local function_step
				function_step=$(jq -cn \
					--arg id "read-call-$request_number" \
					'{type:"function_call",id:$id,name:"read",arguments:{}}')
				printf 'data: %s\n\n' "$(jq -cn --argjson step "$function_step" \
					'{event_type:"step.start",index:1,step:$step}')"
				for fragment in '{"paths":["' "$TEST_DIRECTORY/notes.txt" '"]}'; do
					printf 'data: %s\n\n' "$(jq -cn --arg fragment "$fragment" \
						'{event_type:"step.delta",index:1,delta:{type:"arguments_delta",arguments:$fragment}}')"
				done
				printf 'data: %s\n\n' '{"event_type":"step.stop","index":1}'
				printf 'data: %s' "$(jq -cn --argjson step "$function_step" \
					'{event_type:"interaction.completed",interaction:{status:"requires_action",steps:[{type:"thought",summary:[]},$step],usage:{total_tokens:893,total_output_tokens:24}}}')"
			fi
			return
		fi
		if ! jq -e '.stream' "$TEST_DIRECTORY/request.json" >/dev/null; then
			printf '%s' '{"id":"test-interaction","status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"**Hello** world"}]}],"usage":{"total_input_tokens":4,"total_output_tokens":2,"total_tokens":6}}'
			return
		fi
		if [[ "${BLOCKED:-}" == true ]]; then
			printf '%s\n\n' 'data: {"event_type":"error","error":{"code":"SAFETY","message":"Prompt blocked"}}'
			return
		fi
		printf '%s\r\n\r\n' 'data: {"event_type":"step.delta","delta":{"type":"thought_summary","content":{"type":"text","text":"Thinking..."}}}'
		if [[ "${SEARCH_RESPONSE:-false}" == true ]]; then
			printf 'data: %s\n\n' \
				'{"event_type":"step.start","index":0,"step":{"type":"google_search_call","id":"search-1","arguments":{"queries":["space news"]}}}' \
				'{"event_type":"step.start","index":1,"step":{"type":"google_search_result","call_id":"search-1","result":[]}}' \
				'{"event_type":"step.delta","index":1,"delta":{"type":"google_search_result","result":[{"search_suggestions":"<a href=\"https://www.google.com/search?q=space\">More space news</a>"}]}}' \
				'{"event_type":"step.start","index":2,"step":{"type":"model_output","content":[]}}' \
				'{"event_type":"step.delta","index":2,"delta":{"type":"text","text":"**Hello**"}}' \
				'{"event_type":"step.delta","index":2,"delta":{"type":"text_annotation_delta","annotations":[{"type":"url_citation","url":"https://example.com/space-news","title":"Space Flight Weekly Recap"}]}}'
		elif jq -e '.response_format.schema' "$TEST_DIRECTORY/request.json" >/dev/null 2>&1; then
			printf 'data: %s\n\n' "$(jq -cn --arg text '{"result":true}' '{event_type: "step.delta", delta: {type: "text", text: $text}}')"
		else
			printf '%s\n\n' 'data: {"event_type":"step.delta","delta":{"type":"text","text":"**Hello**"}}'
			printf '%s\n\n' 'data: {"event_type":"step.delta","delta":{"type":"text","text":" world"}}'
		fi
		printf '%s' 'data: {"event_type":"interaction.completed","interaction":{"status":"completed","usage":{"total_input_tokens":4,"total_output_tokens":3,"total_tokens":10}}}'
	elif [[ "$url" == https://api.x.ai/v1/images/generations ]]; then
		[[ "$header" == "$grok_header" ]] || return 1
		printf '%s' '{"data":[{"url":"https://imgen.x.ai/test-image.jpeg","mime_type":"image/jpeg"}],"usage":{"cost_in_usd_ticks":400000000}}'
	elif [[ "$url" == https://api.x.ai/v1/responses ]]; then
		[[ "$header" == "$grok_header" ]] || return 1
		if jq -e '.stream == false' "$TEST_DIRECTORY/request.json" >/dev/null 2>&1; then
			printf '%s' '{"id":"test-response","object":"response","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"**Hello** world"}]}],"usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}'
		elif jq -e '.text.format' "$TEST_DIRECTORY/request.json" >/dev/null 2>&1; then
			printf 'data: %s\n\n' "$(jq -cn --arg delta '{"result":true}' '{type: "response.output_text.delta", delta: $delta}')"
		else
			printf '%s\n\n' 'data: {"type":"response.output_text.delta","delta":"**Hello**"}' 'data: {"type":"response.output_text.delta","delta":" world"}'
		fi
		if ! jq -e '.stream == false' "$TEST_DIRECTORY/request.json" >/dev/null 2>&1; then
			printf '%s' 'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":6,"total_tokens":10}}}'
		fi
	else
		if jq -e '.requests[0].response_format' "$TEST_DIRECTORY/request.json" >/dev/null 2>&1; then
			printf 'data: %s\n\n' "$(jq -cn --arg token '{"result":true}' '{token: $token}')"
			printf '%s\n\n' 'data: [DONE]'
		else
			printf '%s\n\n' 'data: {"reasoning":"Thinking..."}' 'data: {"token":"**Hello**"}' 'data: {"token":" world"}' 'data: [DONE]'
		fi
	fi
}
export -f curl notify-send secret-tool

ask() {
	case "${1:-}" in
	llama | gemini | grok)
		bash "$ROOT/llm.sh" "$@"
		;;
	*)
		bash "$ROOT/llm.sh" llama "$@"
		;;
	esac
}

assert_request() {
	if ! jq -e "$1" "$TEST_DIRECTORY/request.json" >/dev/null; then
		jq . "$TEST_DIRECTORY/request.json" >&2
		return 1
	fi
}

expect_failure() {
	if ask "$@" </dev/null >"$TEST_DIRECTORY/output" 2>"$TEST_DIRECTORY/error"; then
		printf 'Expected failure: %s\n' "$*" >&2
		exit 1
	fi
}

ask --help </dev/null >"$TEST_DIRECTORY/output"
rg -q 'llm llama' "$TEST_DIRECTORY/output"
if rg -q -- '--gemini|--grok' "$TEST_DIRECTORY/output"; then
	echo 'Provider subcommands were still advertised as flags' >&2
	exit 1
fi
rg -q -- '--search' "$TEST_DIRECTORY/output"
rg -q -- '--image-gen' "$TEST_DIRECTORY/output"
rg -q -- '--buff' "$TEST_DIRECTORY/output"
rg -q -- '--schema' "$TEST_DIRECTORY/output"
rg -q -- '--tools' "$TEST_DIRECTORY/output"
bash "$ROOT/llm.sh" --help >"$TEST_DIRECTORY/output"
rg -q 'llama\|gemini\|grok' "$TEST_DIRECTORY/output"
printf 'piped "context"\n' | ask grok 'Hello' --verbose >"$TEST_DIRECTORY/output" 2>"$TEST_DIRECTORY/error"
[[ "$(<"$TEST_DIRECTORY/url")" == 'https://api.x.ai/v1/responses' ]]
assert_request '.model == "grok-4.7" and .stream == true and .store == false and (has("tools") | not) and .input[0].role == "system" and (.input[0].content | contains("CommonMark")) and .input[1].content[0] == {type: "input_text", text: "Hello\n\npiped \"context\"\n"}'
rg -q 'Hello.*world' "$TEST_DIRECTORY/output"
rg -q 'Total tokens: 10' "$TEST_DIRECTORY/output"
if rg -q 'test-key-not-a-real-secret' "$TEST_DIRECTORY/output" "$TEST_DIRECTORY/error"; then
	echo 'Verbose output leaked the Grok API key' >&2
	exit 1
fi
ask grok 'Hello' --model grok-custom </dev/null >"$TEST_DIRECTORY/output"
assert_request '.model == "grok-custom"'
ask grok --stream 'Hello' </dev/null >"$TEST_DIRECTORY/output"
assert_request '.stream == true'
ask grok --stream= 'Hello' </dev/null >"$TEST_DIRECTORY/output"
assert_request '.stream == true'
ask grok --stream false 'Non-streaming response' </dev/null >"$TEST_DIRECTORY/output"
assert_request '.stream == false and .input[-1].content[0].text == "Non-streaming response"'
rg -q 'Hello.*world' "$TEST_DIRECTORY/output"
if rg -q 'requestStartedAt|response.output_text.delta' "$TEST_DIRECTORY/output"; then
	echo 'Non-streaming Grok response was parsed as a stream' >&2
	exit 1
fi
ask grok --stream=false --buff 'Buffered non-streaming response' </dev/null >"$TEST_DIRECTORY/output"
assert_request '.stream == false'
[[ "$(<"$TEST_DIRECTORY/output")" == '**Hello** world' ]]
ask grok --buff 'Buffered Grok response' </dev/null >"$TEST_DIRECTORY/output"
assert_request '.model == "grok-4.7" and .stream == true and .input[-1].content[0].text == "Buffered Grok response"'
[[ "$(<"$TEST_DIRECTORY/output")" == '**Hello** world' ]]
if rg -q 'requestStartedAt' "$TEST_DIRECTORY/output"; then
	echo 'Buffered Grok response was preprocessed' >&2
	exit 1
fi
ask grok --search 'Latest news' </dev/null >"$TEST_DIRECTORY/output"
assert_request '.tools == [{type: "web_search"}, {type: "x_search"}]'
ask grok --schema boolean 'Structured' </dev/null >"$TEST_DIRECTORY/output"
assert_request '.text.format == {type: "json_schema", name: "boolean", schema: {type: "object", properties: {result: {type: "boolean"}}, required: ["result"], additionalProperties: false}, strict: true}'
rg -q '^\{$' "$TEST_DIRECTORY/output"
rg -q '^  "result": true$' "$TEST_DIRECTORY/output"
ask grok --image-gen 'A collage of London landmarks' </dev/null >"$TEST_DIRECTORY/output"
[[ "$(<"$TEST_DIRECTORY/url")" == 'https://api.x.ai/v1/images/generations' ]]
assert_request '.model == "grok-imagine-image-2.0" and .prompt == "A collage of London landmarks"'
[[ "$(<"$TEST_DIRECTORY/output")" == 'https://imgen.x.ai/test-image.jpeg' ]]
[[ "$(<"$TEST_DIRECTORY/notification")" == $'Grok image generated\nhttps://imgen.x.ai/test-image.jpeg' ]]
ask grok --image-gen 'Custom model prompt' --model grok-image-custom </dev/null >"$TEST_DIRECTORY/output"
assert_request '.model == "grok-image-custom" and .prompt == "Custom model prompt"'
expect_failure gemini --image-gen 'Unsupported'
expect_failure grok --image-gen --search 'Unsupported combination'
for location in desktop local remote; do
	ask 'Hello' --location "$location" --verbose </dev/null >"$TEST_DIRECTORY/output"
	rg -q 'Thinking\.\.\.' "$TEST_DIRECTORY/output"
	assert_request '.requests[0].messages[0].content | (contains("Prefer Bash") or contains("suggest Python") or contains("$(secret-tool lookup service gemini key api_key)")) | not'
	assert_request '.model == "gemma4-31bunc" and .requests[0].temperature == 0.9 and .requests[0].min_p == 0.8 and .requests[0].max_tokens == 4096 and .requests[0].thinking_budget_tokens == 2048 and .requests[0].chat_template_kwargs.enable_thinking == true'
	case "$location" in
	desktop) expected_url='https://desktop.adriens-apis.io/llm/stream-multiplex/' ;;
	local) expected_url='http://localhost:8000/llm/stream-multiplex/' ;;
	remote) expected_url='https://gpu.adriens-apis.io/llm/stream-multiplex/' ;;
	esac
	[[ "$(<"$TEST_DIRECTORY/url")" == "$expected_url" ]]
done
ask llama --buff 'Buffered llama response' </dev/null >"$TEST_DIRECTORY/output"
[[ "$(<"$TEST_DIRECTORY/output")" == '**Hello** world' ]]
if rg -q 'Thinking|TTFT:' "$TEST_DIRECTORY/output"; then
	echo 'Buffered llama response was preprocessed' >&2
	exit 1
fi

printf 'piped "context"\n' | ask gemini 'Hello' --verbose >"$TEST_DIRECTORY/output" 2>"$TEST_DIRECTORY/error"
[[ "$(<"$TEST_DIRECTORY/url")" == 'https://generativelanguage.googleapis.com/v1beta/interactions' ]]
assert_request '.input[0].text == "Hello\n\npiped \"context\"\n" and (.system_instruction | contains("CommonMark")) and .generation_config == {thinking_level: "high", thinking_summaries: "auto"} and .stream == true and .store == false and .tools == []'
if rg -q 'test-key-not-a-real-secret' "$TEST_DIRECTORY/output" "$TEST_DIRECTORY/error"; then
	echo 'Verbose output leaked the API key' >&2
	exit 1
fi
rg -q 'Hello.*world' "$TEST_DIRECTORY/output"
rg -q 'Thinking\.\.\.' "$TEST_DIRECTORY/output"
rg -q 'TTFT: [0-9]+\.[0-9]+s \| TPS: [0-9]+\.[0-9]+ \| Total tokens: 10' "$TEST_DIRECTORY/output"
[[ "$(rg -c '^TTFT:' "$TEST_DIRECTORY/output")" == 1 ]]
assert_request '(.system_instruction | contains("Prefer Bash")) and (.system_instruction | contains("suggest Python")) and (.system_instruction | contains("$(secret-tool lookup service gemini key api_key)"))'
ask gemini --stream false 'Non-streaming Gemini response' </dev/null >"$TEST_DIRECTORY/output"
[[ "$(<"$TEST_DIRECTORY/url")" == 'https://generativelanguage.googleapis.com/v1beta/interactions' ]]
assert_request '.input[0].text == "Non-streaming Gemini response" and .stream == false'
rg -q 'Hello.*world' "$TEST_DIRECTORY/output"
if rg -q 'requestStartedAt' "$TEST_DIRECTORY/output"; then
	echo 'Non-streaming Gemini response was parsed as a stream' >&2
	exit 1
fi
ask gemini --buff 'Buffered Gemini response' </dev/null >"$TEST_DIRECTORY/output"
assert_request '.input[0].text == "Buffered Gemini response"'
[[ "$(<"$TEST_DIRECTORY/output")" == '**Hello** world' ]]
if rg -q 'requestStartedAt|TTFT:' "$TEST_DIRECTORY/output"; then
	echo 'Buffered Gemini response was preprocessed' >&2
	exit 1
fi
head -c 200000 /dev/zero | tr '\0' x | ask gemini --schema boolean 'Large input' >"$TEST_DIRECTORY/output"
assert_request '(.input[0].text | length == 200013 and endswith(("x" * 200000))) and .response_format.schema.type == "object"'

export SEARCH_RESPONSE=true
ask gemini --search 'Latest space news' </dev/null >"$TEST_DIRECTORY/output"
assert_request '.tools == [{type: "google_search"}]'
rg -q 'Sources:' "$TEST_DIRECTORY/output"
rg -q 'Space Flight Weekly Recap: https://example.com/space-news' "$TEST_DIRECTORY/output"
rg -q 'TTFT: ' "$TEST_DIRECTORY/output"
source_line=$(rg -n '^Sources:' "$TEST_DIRECTORY/output" | cut -d: -f1)
metrics_line=$(rg -n '^TTFT:' "$TEST_DIRECTORY/output" | cut -d: -f1)
[[ "$source_line" -lt "$metrics_line" ]]
ask gemini 'Latest space news' --tools search </dev/null >"$TEST_DIRECTORY/output"
assert_request '.stream == true and .tools == [{type:"google_search"}]'
rg -q 'Space Flight Weekly Recap: https://example.com/space-news' "$TEST_DIRECTORY/output"
rg -q '\[cited\]' "$TEST_DIRECTORY/output"
rg -q 'More space news: https://www.google.com/search\?q=space' "$TEST_DIRECTORY/output"
rg -q 'Search queries:' "$TEST_DIRECTORY/output"
ask gemini 'Search or read notes' --tools search read </dev/null >"$TEST_DIRECTORY/output"
assert_request '.tools[0] == {type:"google_search"} and .tools[1].type == "function" and .tools[1].name == "read"'
unset SEARCH_RESPONSE

mkdir -p "$HOME/.config/llm-cli/tools"
printf '%s\n' 'type: function' 'name: missing_exec' 'description: Missing executable fixture' \
	'parameters: {type: object}' >"$HOME/.config/llm-cli/tools/missing_exec.yaml"
expect_failure gemini 'Use missing tool' --tools missing_exec
rg -q 'Tool executable not found:.*missing_exec.sh' "$TEST_DIRECTORY/error"
printf '%s\n' 'type: unknown' >"$HOME/.config/llm-cli/tools/unsupported.yaml"
expect_failure gemini 'Use unsupported tool' --tools unsupported
rg -q 'Unsupported tool type' "$TEST_DIRECTORY/error"
printf '%s\n' 'type: function' 'name: invalid_function' \
	>"$HOME/.config/llm-cli/tools/invalid_function.yaml"
expect_failure gemini 'Use invalid function' --tools invalid_function
rg -q 'requires a non-empty description' "$TEST_DIRECTORY/error"

ask gemini --schema boolean 'Structured' </dev/null >"$TEST_DIRECTORY/output"
assert_request '.response_format == {type: "text", mime_type: "application/json", schema: {type: "object", properties: {result: {type: "boolean"}}, required: ["result"], additionalProperties: false}}'
rg -q '^\{$' "$TEST_DIRECTORY/output"
rg -q '^  "result": true$' "$TEST_DIRECTORY/output"
if rg -q 'Thinking\.\.\.' "$TEST_DIRECTORY/output"; then
	echo 'Structured output included Gemini reasoning' >&2
	exit 1
fi

ask gemini 'Hello' --model models/gemini-2.5-flash </dev/null >"$TEST_DIRECTORY/output"
assert_request '.generation_config == {temperature: 0.9, thinking_budget: 2048, thinking_summaries: "auto"}'

ask gemini 'Hello' --model models/gemini-3.8-flash </dev/null >"$TEST_DIRECTORY/output"
assert_request '.generation_config.thinking_level == "high"'

for provider in llama gemini; do
	ask "$provider" 'Attachments' --images "$TEST_DIRECTORY/image.png" https://example.test/image.png --files "$TEST_DIRECTORY/notes.txt" https://example.test/notes.txt </dev/null >"$TEST_DIRECTORY/output"
	if [[ "$provider" == gemini ]]; then
		assert_request '(.input | length) == 5 and .input[1].type == "image" and .input[1].mime_type == "image/png" and .input[1] == .input[2] and (.input[4].text | contains("file content\nwith \"quotes\"\n"))'
	else
		assert_request '(.requests[0].images | length) == 2 and .requests[0].images[0] == .requests[0].images[1] and (.requests[0].files | length) == 2 and .requests[0].files[1].content == "file content\nwith \"quotes\"\n"'
	fi
done
ask --schema boolean 'Structured' </dev/null >"$TEST_DIRECTORY/output"
assert_request '.requests[0].response_format == {type: "json_schema", json_schema: {name: "boolean", schema: {type: "object", properties: {result: {type: "boolean"}}, required: ["result"], additionalProperties: false}, strict: true}}'
rg -q '^\{$' "$TEST_DIRECTORY/output"
rg -q '^  "result": true$' "$TEST_DIRECTORY/output"

export AGENT_SESSION_ID='test-session'
ask 'First question' </dev/null >"$TEST_DIRECTORY/output"
ask gemini 'Second question' </dev/null >"$TEST_DIRECTORY/output"
assert_request '[.input[].text] == ["User: First question", "Assistant: **Hello** world", "User: Second question"]'
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" 'SELECT count(*) FROM messages;')" == 4 ]]
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" 'SELECT content FROM messages ORDER BY id DESC LIMIT 1;')" == '**Hello** world' ]]
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(*) FROM messages WHERE json_extract(metadata, '$.model') = 'gemma4-31bunc';")" == 2 ]]
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(*) FROM messages WHERE json_extract(metadata, '$.model') = 'gemini-flash-latest';")" == 2 ]]

sqlite3 "$HOME/.local/share/llm-cli/.db" "INSERT INTO sessions (id) VALUES ('large-session'); INSERT INTO messages (session_id, role, content) VALUES ('large-session', 'user', replace(hex(zeroblob(140000)), '00', 'x'));"
export AGENT_SESSION_ID='large-session'
ask 'Continue session' </dev/null >"$TEST_DIRECTORY/output"
assert_request '(.requests[0].messages[1].content | length) == 140000 and .requests[0].messages[2].content == "Continue session"'

export HTTP_ERROR=true
expect_failure gemini 'HTTP failure'
rg -q 'Gemini API error: .*test HTTP error' "$TEST_DIRECTORY/error"
unset HTTP_ERROR
export BLOCKED=true
expect_failure gemini 'Blocked prompt'
rg -q 'Gemini API error: Prompt blocked' "$TEST_DIRECTORY/error"
unset BLOCKED
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(*) FROM messages WHERE session_id = 'test-session' AND role = 'assistant';")" == 2 ]]
unset AGENT_SESSION_ID

export MISSING_KEY=true
expect_failure gemini 'Missing key'
rg -q 'Could not read Gemini API key' "$TEST_DIRECTORY/error"
unset MISSING_KEY
expect_failure
expect_failure gemini
expect_failure 'Hello' --unknown
expect_failure 'Hello' --gemini
expect_failure 'Hello' --grok
expect_failure 'Hello' --model
expect_failure 'Hello' --location
expect_failure 'Hello' --images
expect_failure 'Hello' --files
expect_failure gemini 'Hello' --location local
expect_failure --search 'Hello'
expect_failure --schema missing 'Hello'
expect_failure llama --stream false 'Unsupported'
expect_failure grok --stream=invalid 'Invalid stream option'
expect_failure gemini 'Hello' --model 'bad/model'
expect_failure gemini 'Hello' --images "$TEST_DIRECTORY/missing.png"
expect_failure gemini 'Hello' --files https://example.test/missing.txt
script -qefc "bash '$ROOT/llm.sh' gemini 'Show stream status'" /dev/null \
	>"$TEST_DIRECTORY/output" 2>"$TEST_DIRECTORY/error"
if rg -q 'Response received' "$TEST_DIRECTORY/output"; then
	echo 'Redundant response status was displayed' >&2
	exit 1
fi
rg -q 'Hello.*world' "$TEST_DIRECTORY/output"

mkdir -p "$HOME/.config/llm-cli/tools"
sed 's/^description:.*/description: Reads files from user configuration/' \
	"$ROOT/.config/tools/read.yaml" >"$HOME/.config/llm-cli/tools/read.yaml"
export AGENT_SESSION_ID='tool-session'
export TOOL_TEST_MODE=true
for prompt in 'Read the notes' 'Read the notes again'; do
	if ! printf 'y\n' | script -qefc "bash '$ROOT/llm.sh' gemini '$prompt' --tools read" /dev/null \
		>"$TEST_DIRECTORY/output" 2>"$TEST_DIRECTORY/error"; then
		cat "$TEST_DIRECTORY/output" "$TEST_DIRECTORY/error" >&2
		exit 1
	fi
	if ! rg -q 'Gemini requested tool' "$TEST_DIRECTORY/output"; then
		cat "$TEST_DIRECTORY/output" "$TEST_DIRECTORY/error" >&2
		exit 1
	fi
	rg -q "$ROOT/libexec/tool_execs/read.sh" "$TEST_DIRECTORY/output"
	rg -q '"paths"' "$TEST_DIRECTORY/output"
	rg -q 'notes\.txt' "$TEST_DIRECTORY/output"
	if rg -q 'About to run:|Tool call|Approval required before execution|\[step\] Waiting for Gemini|Response received|Gemini completed the response|Gemini returned no answer text' \
		"$TEST_DIRECTORY/output"; then
		echo 'Tool-call confirmation included redundant status or metadata' >&2
		exit 1
	fi
	[[ "$(rg -c 'Total tokens: 893' "$TEST_DIRECTORY/output")" == 1 ]]
	[[ "$(rg -c 'Total tokens: 652' "$TEST_DIRECTORY/output")" == 1 ]]
	rg -q 'Checking the requested file' "$TEST_DIRECTORY/output"
	rg -q 'I will use read' "$TEST_DIRECTORY/output"
	rg -q '\[done\] Running read\.sh' "$TEST_DIRECTORY/output"
done
unset TOOL_TEST_MODE
assert_request '.stream == true'
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(*) FROM messages WHERE session_id = 'tool-session' AND role = 'user';")" == 2 ]]
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(*) FROM messages WHERE session_id = 'tool-session' AND role = 'assistant_step';")" == 6 ]]
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(*) FROM messages WHERE session_id = 'tool-session' AND role = 'tool_result';")" == 2 ]]
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(*) FROM messages WHERE session_id = 'tool-session' AND role = 'human_gate';")" == 2 ]]
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(DISTINCT json_extract(metadata, '$.event_key')) FROM messages WHERE session_id = 'tool-session';")" == 12 ]]
assert_request '
	([.input[] | select(.type == "function_call")] | length == 2) and
	([.input[] | select(.type == "function_result")] | length == 2) and
	([.input[] | select(.type == "user_input")] | length == 2) and
	([.input[] | select(.type == "human_gate")] | length == 0) and
	([.input[] | select(.type == "model_output") | .content[].text] == ["I read the requested file."]) and
	([.input[] | select(.type == "thought") | .summary | map(.text) | join("")] ==
		["Checking the requested file. I will use read.", "Checking the requested file. I will use read."]) and
	.tools[0].description == "Reads files from user configuration" and
	([.input[] | select(.type == "function_result") | .result[0].text | fromjson | .content] ==
		["file content\nwith \"quotes\"\n", "file content\nwith \"quotes\"\n"])
'
source "$ROOT/lib/db.sh"
duplicate_key=$(sqlite3 "$HOME/.local/share/llm-cli/.db" \
	"SELECT json_extract(metadata, '$.event_key') FROM messages WHERE session_id = 'tool-session' AND role = 'tool_result' ORDER BY id LIMIT 1;")
db:insert_message tool_result duplicate null "$duplicate_key" duplicate
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(*) FROM messages WHERE session_id = 'tool-session' AND role = 'tool_result';")" == 2 ]]
export TOOL_TEST_MODE=true
if printf 'n\n' | script -qefc "bash '$ROOT/llm.sh' gemini 'Decline reading the notes' --tools read" /dev/null \
	>"$TEST_DIRECTORY/output" 2>"$TEST_DIRECTORY/error"; then
	echo 'Expected the declined tool call to fail' >&2
	exit 1
fi
unset TOOL_TEST_MODE
rg -q 'Execution cancelled' "$TEST_DIRECTORY/output"
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(*) FROM messages WHERE session_id = 'tool-session' AND role = 'human_gate' AND json_extract(content, '$.status') = 'declined';")" == 1 ]]
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(*) FROM messages WHERE session_id = 'tool-session' AND role = 'tool_result';")" == 3 ]]
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(DISTINCT json_extract(metadata, '$.event_key')) FROM messages WHERE session_id = 'tool-session';")" == 17 ]]
sqlite3 "$HOME/.local/share/llm-cli/.db" \
	"UPDATE messages SET content = json_set(content, '$.signature', 'gemini-only-test-signature')
	 WHERE session_id = 'tool-session' AND role = 'assistant_step'
	 AND json_extract(content, '$.type') = 'thought';"
ask grok 'Critique the implementation' --files "$TEST_DIRECTORY/notes.txt" \
	</dev/null >"$TEST_DIRECTORY/output"
assert_request '
	.model == "grok-4.7" and .stream == true and .store == false and
	(.input | length == 16) and
	([.input[] | .type // .role] == [
		"system", "user", "assistant", "function_call", "function_call_output", "assistant",
		"user", "assistant", "function_call", "function_call_output", "assistant",
		"user", "assistant", "function_call", "function_call_output", "user"
	]) and
	([.input[] | select(.type == "function_call") | .arguments | fromjson | .paths] | length == 3) and
	([.input[] | select(.type == "function_call") | .call_id] ==
	 [.input[] | select(.type == "function_call_output") | .call_id]) and
	([.input[] | select(.type == "function_call_output") | .output | fromjson] == [
		{content:"file content\nwith \"quotes\"\n"},
		{content:"file content\nwith \"quotes\"\n"},
		{error:"Execution was declined by the user"}
	]) and
	([.input[] | select(.role == "assistant" and .content == "I read the requested file.")] | length == 2) and
	([.input[] | select(.role == "assistant" and .content == "Thinking summary:\nChecking the requested file. I will use read.")] | length == 3) and
	.input[-1].content[0] == {type:"input_text",text:"Critique the implementation"} and
	(.input[-1].content[1].text | contains("file content\nwith \"quotes\"\n")) and
	(tostring | contains("gemini-only-test-signature") | not) and
	(tostring | contains("human_gate") | not) and
	(has("tools") | not)
'
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(*) FROM messages WHERE session_id = 'tool-session';")" == 19 ]]
ask grok 'Continue the critique' </dev/null >"$TEST_DIRECTORY/output"
assert_request '
	(.input | length == 18) and
	.input[-3] == {role:"user",content:"Critique the implementation"} and
	.input[-2] == {role:"assistant",content:"**Hello** world"} and
	.input[-1].content[0].text == "Continue the critique" and
	([.input[] | select(.type == "function_call")] | length == 3) and
	([.input[] | select(.type == "function_call_output")] | length == 3)
'
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(*) FROM messages WHERE session_id = 'tool-session';")" == 21 ]]
unset AGENT_SESSION_ID

export INPUT_TEST_MODE=true
export AGENT_SESSION_ID=input-session
if ! printf '%s\n' 'y' '  notes\with "quotes".txt  ' |
	script -qefc "bash '$ROOT/llm.sh' gemini 'Ask me for a file' --tools input read" /dev/null \
	>"$TEST_DIRECTORY/output" 2>"$TEST_DIRECTORY/error"; then
	cat "$TEST_DIRECTORY/output" "$TEST_DIRECTORY/error" >&2
	exit 1
fi
rg -q 'Which file should I read\?' "$TEST_DIRECTORY/output"
rg -q 'Thanks for your answer' "$TEST_DIRECTORY/output"
if rg -q 'Running input\.sh' "$TEST_DIRECTORY/output"; then
	echo 'Input prompt must not run under an execution spinner' >&2
	exit 1
fi
assert_request '
	([.tools[].name] == ["input", "read"]) and
	.input[-1].type == "function_result" and .input[-1].name == "input" and
	(.input[-1].result[0].text | fromjson) == {content:"  notes\\with \"quotes\".txt  \n"}
'
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT count(*) FROM messages WHERE session_id = 'input-session';")" == 5 ]]
[[ "$(sqlite3 "$HOME/.local/share/llm-cli/.db" "SELECT json_extract(content, '$.status') FROM messages WHERE session_id = 'input-session' AND role = 'human_gate';")" == approved ]]
if printf 'n\n' | script -qefc "bash '$ROOT/llm.sh' gemini 'Ask again' --tools input" /dev/null \
	>"$TEST_DIRECTORY/output" 2>"$TEST_DIRECTORY/error"; then
	echo 'Expected declined input tool to fail' >&2
	exit 1
fi
rg -q 'Execution cancelled' "$TEST_DIRECTORY/output"
unset AGENT_SESSION_ID INPUT_TEST_MODE

python3 - "$ROOT/libexec/tool_execs/input.sh" <<'PYTHON'
import subprocess
import sys

for arguments, expected_error in (
	('{"answer":"Question?"}', "no readable terminal"),
	('{"answer":5}', "Usage: input.sh"),
):
	result = subprocess.run(
		[sys.argv[1], arguments], input="not terminal input\n", text=True,
		capture_output=True, start_new_session=True, timeout=5,
	)
	assert result.returncode != 0
	assert expected_error in result.stderr
	assert result.stdout == ""
PYTHON

(
	LOCATION=""
	source "$ROOT/lib/llm_providers/gemini.sh"
	REQ='{"tools":[]}'
	CUSTOM_TOOL='{"type":"function","name":"lookup","parameters":{"type":"object"}}'
	build_tools "$GOOGLE_SEARCH_TOOL" "$CUSTOM_TOOL"
	jq -e '.tools == [{type:"google_search"}, {type:"function",name:"lookup",parameters:{type:"object"}}]' <<<"$REQ" >/dev/null
)

PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PYTHON'
import io
import json
from unittest.mock import patch

from rich.console import Console
from stream_response import (
	GeminiInteractionCollector,
	TerminalWriter,
	render_event,
)

search_output = io.StringIO()
terminal = TerminalWriter(provider="gemini")
terminal.console = Console(file=search_output, width=160, color_system=None)
collector = GeminiInteractionCollector()
def search_event(payload):
	render_event(json.dumps(payload), terminal, "gemini", collector)

search_event({"event_type": "step.start", "index": 0, "step": {
	"type": "google_search_call", "id": "s1", "arguments": {"queries": ["shell style"]},
}})
search_event({"event_type": "step.start", "index": 1, "step": {
	"type": "google_search_result", "call_id": "s1", "result": [],
}})
suggestions = {"search_suggestions":
	'<style>hidden CSS</style><a href="https://google.com/search?q=shell&amp;x=1">'
	'<span>Shell &amp; style</span></a><a href="https://google.com/search?q=extra">Extra</a>'}
search_event({"event_type": "step.delta", "index": 1, "delta": {
	"type": "google_search_result", "result": [suggestions],
}})
search_event({"event_type": "step.start", "index": 2, "step": {
	"type": "model_output", "content": [],
}})
search_event({"event_type": "step.delta", "index": 2, "delta": {
	"type": "text", "text": "Answer once.",
}})
citations = [{"type": "url_citation", "url": f"https://example.test/{i}", "title": f"Source {i}"}
	for i in range(12)]
search_event({"event_type": "step.delta", "index": 2, "delta": {
	"type": "text_annotation_delta", "annotations": citations,
}})
search_event({"event_type": "step.delta", "delta": {
	"type": "url_context_result", "result": [
		{"url": "https://example.test/0", "status": "success"},
		{"url": "https://example.test/uncited", "status": "success"},
		{"url": "https://example.test/paywall", "status": "paywall"},
	],
}})
search_event({"event_type": "interaction.completed", "interaction": {
	"status": "completed", "steps": [
		{"type": "google_search_call", "id": "s1", "arguments": {"queries": ["shell style"]}},
		{"type": "google_search_result", "call_id": "s1", "result": []},
		{"type": "model_output", "content": [
			{"type": "text", "text": "Answer once.", "annotations": citations + [
				{"type": "url_citation", "url": "https://example.test/final", "title": "Final only"},
			]},
		]},
	],
}})
history = collector.build(terminal)
assert history["steps"][1]["result"] == [suggestions]
assert len(terminal.sources) == 13
terminal.finish()
rendered = search_output.getvalue()
assert rendered.count("Answer once.") == 1
for i in range(12):
	assert rendered.count(f"- Source {i}: https://example.test/{i} [") == 1
assert "https://example.test/0 [cited; retrieved]" in rendered
assert "https://example.test/uncited [retrieved; not cited]" in rendered
assert "https://example.test/paywall [retrieval: paywall; not cited]" in rendered
assert "Final only: https://example.test/final [cited]" in rendered
assert "Shell & style: https://google.com/search?q=shell&x=1" in rendered
assert "Extra: https://google.com/search?q=extra" in rendered
assert "hidden CSS" not in rendered

activity_output = io.StringIO()
activity_console = Console(file=activity_output, force_terminal=True, color_system=None, width=160)
with patch("stream_response.Console", return_value=activity_console):
	terminal = TerminalWriter(provider="gemini")
	terminal.write_reasoning("Thinking first.")
	assert terminal.status is None
	for kind, arguments, expected in (
		("google_search_call", {"queries": ["shell [style]"]}, "Searching: shell [style]"),
		("url_context_call", {"urls": ["https://example.test/source"]}, "Reading: https://example.test/source"),
	):
		render_event(json.dumps({"event_type": "step.delta", "delta": {
			"type": kind, "arguments": arguments,
		}}), terminal, "gemini")
		assert terminal.status is not None
		assert terminal.status.status.plain == expected
	terminal.write_reasoning("Thinking again.")
	assert terminal.status is None
	terminal.write_token("Final answer.")
	terminal.finish()

thinking_output = io.StringIO()
thinking_console = Console(
	file=thinking_output, force_terminal=True, color_system=None, width=120,
)
with patch("stream_response.Console", return_value=thinking_console):
	terminal = TerminalWriter(provider="gemini")
	assert terminal.status is not None
	for text in ("Partial thinking", " continues without a newline"):
		render_event(json.dumps({
			"event_type": "step.delta",
			"delta": {
				"type": "thought_summary",
				"content": {"type": "text", "text": text},
			},
		}), terminal, "gemini")
		assert text in thinking_output.getvalue()
		assert terminal.status is None, "Spinner would erase the partial thought line"
	assert terminal.response == ""
	assert terminal.reasoning == "Partial thinking continues without a newline"
	terminal.finish()
assert thinking_output.getvalue().count("Partial thinking") == 1

for thought_first in (True, False):
	terminal = TerminalWriter()
	output = io.StringIO()
	terminal.console = Console(file=output, width=120, color_system=None)
	render_event('{"requestStartedAt": 100}', terminal, "gemini")
	with patch("stream_response.time.monotonic", return_value=102):
		if thought_first:
			render_event(json.dumps({
				"event_type": "step.delta",
				"delta": {
					"type": "thought_summary",
					"content": {"type": "text", "text": "Thinking..."},
				},
			}), terminal, "gemini")
		else:
			render_event(json.dumps({
				"event_type": "step.delta",
				"delta": {"type": "text", "text": "First text"},
			}), terminal, "gemini")
	with patch("stream_response.time.monotonic", return_value=106):
		if thought_first:
			render_event(json.dumps({
				"event_type": "step.delta",
				"delta": {"type": "text", "text": "First text"},
			}), terminal, "gemini")
		render_event(json.dumps({
			"event_type": "step.delta",
			"delta": {"type": "text", "text": "Answer"},
		}), terminal, "gemini")
	with patch("stream_response.time.monotonic", return_value=108):
		render_event(json.dumps({
			"event_type": "step.delta",
			"delta": {"type": "text", "text": " done"},
		}), terminal, "gemini")
	render_event(json.dumps({
		"event_type": "interaction.completed",
		"interaction": {
			"status": "completed",
			"usage": {"total_output_tokens": 12, "total_tokens": 30},
		},
	}), terminal, "gemini")
	terminal.finish()
	expected_tps = "6.00" if thought_first else "2.00"
	assert f"TTFT: 2.00s | TPS: {expected_tps} | Total tokens: 30" in output.getvalue()
	assert "TTFT" not in terminal.response
	assert terminal.first_token_at == 102

for with_thought in (True, False):
	terminal = TerminalWriter(provider="gemini")
	output = io.StringIO()
	terminal.console = Console(file=output, width=120, color_system=None)
	collector = GeminiInteractionCollector()
	render_event('{"requestStartedAt":100}', terminal, "gemini", collector)
	if with_thought:
		with patch("stream_response.time.monotonic", return_value=101):
			render_event(json.dumps({
				"event_type": "step.start", "index": 0,
				"step": {"type": "thought", "summary": [
					{"type": "text", "text": "Checking the file."},
				]},
			}), terminal, "gemini", collector)
	with patch("stream_response.time.monotonic", return_value=102):
		render_event(json.dumps({
			"event_type": "step.delta", "index": 1,
			"delta": {"type": "arguments_delta", "arguments": '{"paths":'},
		}), terminal, "gemini", collector)
	with patch("stream_response.time.monotonic", return_value=106):
		render_event(json.dumps({
			"event_type": "step.delta", "index": 1,
			"delta": {"type": "arguments_delta", "arguments": '["notes.txt"]}'},
		}), terminal, "gemini", collector)
	render_event(json.dumps({
		"event_type": "interaction.completed",
		"interaction": {
			"status": "requires_action",
			"usage": {"total_output_tokens": 24, "total_tokens": 893},
		},
	}), terminal, "gemini", collector)
	terminal.finish()
	ttft = "1.00" if with_thought else "2.00"
	assert f"TTFT: {ttft}s | TPS: 6.00 | Total tokens: 893" in output.getvalue()
	assert "Response received" not in output.getvalue()
	if with_thought:
		assert output.getvalue().count("Checking the file.") == 1

collector = GeminiInteractionCollector()
tool_terminal = TerminalWriter(provider="gemini")
collector.consume({
	"event_type": "step.start",
	"index": 1,
	"step": {
		"id": "call-1",
		"type": "function_call",
		"name": "read",
		"arguments": {},
	},
}, tool_terminal)
collector.consume({
	"event_type": "step.delta",
	"index": 1,
	"delta": {
		"type": "arguments_delta",
		"arguments": '{"paths":["/tmp/notes.txt"]}',
	},
}, tool_terminal)
collector.consume({
	"event_type": "interaction.completed",
	"interaction": {
		"status": "requires_action",
		"steps": [{
			"id": "call-1",
			"type": "function_call",
			"name": "read",
			"arguments": {},
		}],
	},
}, tool_terminal)
streamed_interaction = collector.build(tool_terminal)
assert streamed_interaction["steps"][0]["arguments"] == {
	"paths": ["/tmp/notes.txt"],
}

structured_terminal = TerminalWriter(structured_output=True)
structured_output = io.StringIO()
structured_terminal.console = Console(
	file=structured_output, force_terminal=True, color_system="truecolor"
)
render_event(json.dumps({"token": json.dumps({
	"key": "text",
	"flag": True,
	"count": 42,
})}), structured_terminal)
structured_terminal.finish()
rendered = structured_output.getvalue()
assert '  \x1b[38;2;0;135;255m"key"\x1b[0m:' in rendered
assert '\x1b[38;2;0;175;95m"text"\x1b[0m' in rendered
assert '\x1b[38;2;175;95;255mtrue\x1b[0m' in rendered
assert '\x1b[38;2;255;135;0m42\x1b[0m' in rendered
PYTHON

printf 'All CLI backend tests passed.\n'
