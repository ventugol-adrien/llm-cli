#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIRECTORY=$(mktemp -d)
trap 'rm -rf "$TEST_DIRECTORY"' EXIT
export TEST_DIRECTORY HOME="$TEST_DIRECTORY/home"
unset LLM_CLI_CONFIG LLM_CLI_PROFILE_DIR LLM_CLI_HOOKS LLM_CLI_PROVIDER
unset PROFILE
unset PROFILE_MARKER HOOK_MARKER SUCCESS_MARKER HOOK_LOCAL_MARKER
unset EXPLICIT_PROFILE_MARKER PROFILE_QUOTED PROFILE_EMPTY
export TEST_COMMAND_STATUS=0
LAUNCHER_OPTIONS=()

mkdir -p "$TEST_DIRECTORY/cli with spaces/bin" "$TEST_DIRECTORY/cli with spaces/libexec"
cp "$ROOT/bin/llm.sh" "$TEST_DIRECTORY/cli with spaces/bin/llm.sh"
LAUNCHER="$TEST_DIRECTORY/cli with spaces/bin/llm.sh"
cat >"$TEST_DIRECTORY/cli with spaces/libexec/ask.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -e
printf 'command:%s:%s:%s\n' "${LLM_CLI_PROVIDER:-manage}" \
	"${PROFILE_MARKER:-}" "${HOOK_MARKER:-}" >>"$TEST_DIRECTORY/events"
printf '%s\0' "$@" >"$TEST_DIRECTORY/arguments"
printf '%s' "${LLM_CLI_PROFILE_DIR:-}" >"$TEST_DIRECTORY/profile-directory"
printf '%s' "${HOOK_LOCAL_MARKER:-}" >"$TEST_DIRECTORY/hook-local-marker"
printf '%s\0' "${PROFILE_MARKER:-}" "${EXPLICIT_PROFILE_MARKER:-}" \
	"${PROFILE_QUOTED:-}" "${PROFILE_EMPTY+x}" >"$TEST_DIRECTORY/profile-values"
exit "$TEST_COMMAND_STATUS"
SCRIPT
cp "$TEST_DIRECTORY/cli with spaces/libexec/ask.sh" "$TEST_DIRECTORY/cli with spaces/libexec/manage.sh"
chmod +x "$TEST_DIRECTORY/cli with spaces/libexec/ask.sh" "$TEST_DIRECTORY/cli with spaces/libexec/manage.sh"

run() {
	local expected_status="$1"
	local status=0
	shift
	: >"$TEST_DIRECTORY/events"
	if bash "${LAUNCHER_OPTIONS[@]}" "$LAUNCHER" "$@" >"$TEST_DIRECTORY/output" 2>"$TEST_DIRECTORY/error"; then
		status=0
	else
		status=$?
	fi
	if [[ "$status" != "$expected_status" ]]; then
		cat "$TEST_DIRECTORY/output" "$TEST_DIRECTORY/error" >&2
		printf 'Expected status %s, got %s for: %s\n' "$expected_status" "$status" "$*" >&2
		exit 1
	fi
}

assert_events() {
	printf '%s' "$1" >"$TEST_DIRECTORY/expected-events"
	cmp "$TEST_DIRECTORY/expected-events" "$TEST_DIRECTORY/events"
}

run 0 llama 'Hello'
[[ -d "$HOME/.config/llm-cli/profiles" && -d "$HOME/.config/llm-cli/hooks" ]]
assert_events $'command:llama::\n'
[[ "$(<"$TEST_DIRECTORY/profile-directory")" == "$HOME/.config/llm-cli/profiles" ]]

export LLM_CLI_CONFIG="$TEST_DIRECTORY/config root"
export LLM_CLI_PROFILE_DIR="$TEST_DIRECTORY/custom profiles"
export LLM_CLI_HOOKS="$TEST_DIRECTORY/custom hooks"
run 0 --help
[[ -d "$LLM_CLI_CONFIG" && -d "$LLM_CLI_PROFILE_DIR" && -d "$LLM_CLI_HOOKS" ]]
grep -Fq -- '--profile NAME' "$TEST_DIRECTORY/output"
assert_events ''

cat >"$LLM_CLI_PROFILE_DIR/coding.env" <<'SCRIPT'
printf 'profile\n' >>"$TEST_DIRECTORY/events"
PROFILE_MARKER='from profile'
export EXPLICIT_PROFILE_MARKER='explicit export'
PROFILE_QUOTED='spaces "quotes" $literal'
PROFILE_EMPTY=
SCRIPT
printf 'exit 99\n' >"$LLM_CLI_PROFILE_DIR/unused.env"
printf 'exit 99\n' >"$LLM_CLI_PROFILE_DIR/coding.sh"
printf 'exit 99\n' >"$LLM_CLI_PROFILE_DIR/default.sh"

cat >"$LLM_CLI_HOOKS/on_start.sh" <<'SCRIPT'
printf 'start:%s:%s\n' "$LLM_CLI_COMMAND" "$LLM_CLI_EXIT_STATUS" >>"$TEST_DIRECTORY/events"
printf '%s\0' "$@" >"$TEST_DIRECTORY/hook-arguments"
printf '%s' "$LLM_CLI_PROFILE" >"$TEST_DIRECTORY/active-profile"
export HOOK_MARKER='from hook'
HOOK_LOCAL_MARKER='hook local'
SCRIPT
cat >"$LLM_CLI_HOOKS/on_success.sh" <<'SCRIPT'
printf 'success:%s:%s\n' "$LLM_CLI_COMMAND" "$LLM_CLI_EXIT_STATUS" >>"$TEST_DIRECTORY/events"
export SUCCESS_MARKER='from success'
SCRIPT
cat >"$LLM_CLI_HOOKS/on_error.sh" <<'SCRIPT'
printf 'error:%s:%s\n' "$LLM_CLI_COMMAND" "$LLM_CLI_EXIT_STATUS" >>"$TEST_DIRECTORY/events"
SCRIPT
cat >"$LLM_CLI_HOOKS/on_exit.sh" <<'SCRIPT'
printf 'exit:%s:%s:%s\n' "$LLM_CLI_COMMAND" "$LLM_CLI_EXIT_STATUS" \
	"${SUCCESS_MARKER:-}" >>"$TEST_DIRECTORY/events"
SCRIPT
printf 'exit 98\n' >"$LLM_CLI_HOOKS/on_unknown.sh"

for command in llama ask gemini grok manage; do
	canonical="$command"
	[[ "$command" != ask ]] || canonical=llama
	run 0 --profile coding "$command" 'Hello "world"' --model 'a model'
	assert_events "profile
start:$canonical:0
command:$canonical:from profile:from hook
success:$canonical:0
exit:$canonical:0:from success
"
	printf '%s\0' 'Hello "world"' --model 'a model' >"$TEST_DIRECTORY/expected-arguments"
	cmp "$TEST_DIRECTORY/expected-arguments" "$TEST_DIRECTORY/arguments"
	cmp "$TEST_DIRECTORY/expected-arguments" "$TEST_DIRECTORY/hook-arguments"
	[[ "$(<"$TEST_DIRECTORY/active-profile")" == coding ]]
	[[ "$(<"$TEST_DIRECTORY/profile-directory")" == "$LLM_CLI_PROFILE_DIR" ]]
	[[ ! -s "$TEST_DIRECTORY/hook-local-marker" ]]
	printf '%s\0' 'from profile' 'explicit export' 'spaces "quotes" $literal' x \
		>"$TEST_DIRECTORY/expected-profile-values"
	cmp "$TEST_DIRECTORY/expected-profile-values" "$TEST_DIRECTORY/profile-values"
done

LAUNCHER_OPTIONS=(-a)
run 0 --profile coding gemini 'Preserve allexport'
[[ "$(<"$TEST_DIRECTORY/hook-local-marker")" == 'hook local' ]]
printf 'set +a\n' >"$LLM_CLI_PROFILE_DIR/shell-options.env"
run 0 --profile shell-options gemini 'Restore allexport changed by profile'
[[ "$(<"$TEST_DIRECTORY/hook-local-marker")" == 'hook local' ]]
LAUNCHER_OPTIONS=()

run 0 gemini 'No profile'
assert_events $'start:gemini:0\ncommand:gemini::from hook\nsuccess:gemini:0\nexit:gemini:0:from success\n'
[[ "$(<"$TEST_DIRECTORY/active-profile")" == default ]]
cp "$LLM_CLI_PROFILE_DIR/coding.env" "$LLM_CLI_PROFILE_DIR/default.env"
run 0 gemini 'Default profile'
assert_events $'profile\nstart:gemini:0\ncommand:gemini:from profile:from hook\nsuccess:gemini:0\nexit:gemini:0:from success\n'
[[ "$(<"$TEST_DIRECTORY/active-profile")" == default ]]
rm "$LLM_CLI_PROFILE_DIR/default.env"
PROFILE=coding run 0 gemini 'Environment profile'
[[ "$(<"$TEST_DIRECTORY/active-profile")" == coding ]]
assert_events $'profile\nstart:gemini:0\ncommand:gemini:from profile:from hook\nsuccess:gemini:0\nexit:gemini:0:from success\n'
PROFILE=unused run 0 --profile coding gemini 'Flag overrides environment'
[[ "$(<"$TEST_DIRECTORY/active-profile")" == coding ]]
PROFILE=missing run 1 gemini Hello
grep -Fq 'missing.env' "$TEST_DIRECTORY/error"
PROFILE='../outside' run 1 gemini Hello
grep -Fq 'Invalid profile name' "$TEST_DIRECTORY/error"
run 1 --profile default gemini Hello
grep -Fq 'default.env' "$TEST_DIRECTORY/error"
for args in --help unknown; do
	expected=0
	[[ "$args" == --help ]] || expected=1
	run "$expected" "$args"
	assert_events ''
done
run 0 --profile unused --help
assert_events ''
run 1 --profile
grep -Fq -- '--profile requires' "$TEST_DIRECTORY/error"
grep -Fq '.env suffix' "$TEST_DIRECTORY/error"
run 1 --profile '../outside' gemini Hello
assert_events ''
run 1 --profile missing gemini Hello
grep -Fq 'missing.env' "$TEST_DIRECTORY/error"
assert_events ''

cat >"$LLM_CLI_PROFILE_DIR/broken.env" <<'SCRIPT'
false
printf 'must not run\n' >>"$TEST_DIRECTORY/events"
SCRIPT
run 1 --profile broken gemini Hello
grep -Fq 'Failed to source' "$TEST_DIRECTORY/error"
assert_events ''
cp "$LLM_CLI_PROFILE_DIR/broken.env" "$LLM_CLI_PROFILE_DIR/default.env"
run 1 gemini Hello
assert_events ''
rm "$LLM_CLI_PROFILE_DIR/default.env"

export TEST_COMMAND_STATUS=23
run 23 --profile coding gemini Hello
assert_events $'profile\nstart:gemini:0\ncommand:gemini:from profile:from hook\nerror:gemini:23\nexit:gemini:23:\n'
cat >>"$LLM_CLI_HOOKS/on_error.sh" <<'SCRIPT'
return 7
printf 'must not run\n' >>"$TEST_DIRECTORY/events"
SCRIPT
run 23 gemini Hello
grep -Fq 'on_error.sh (exit 7)' "$TEST_DIRECTORY/error"
assert_events $'start:gemini:0\ncommand:gemini::from hook\nerror:gemini:23\nexit:gemini:23:\n'

cat >>"$LLM_CLI_HOOKS/on_exit.sh" <<'SCRIPT'
return 9
SCRIPT
run 23 gemini Hello
grep -Fq 'on_exit.sh (exit 9)' "$TEST_DIRECTORY/error"
assert_events $'start:gemini:0\ncommand:gemini::from hook\nerror:gemini:23\nexit:gemini:23:\n'
export TEST_COMMAND_STATUS=0
run 9 gemini Hello
assert_events $'start:gemini:0\ncommand:gemini::from hook\nsuccess:gemini:0\nexit:gemini:0:from success\n'

cat >>"$LLM_CLI_HOOKS/on_success.sh" <<'SCRIPT'
false
printf 'must not run\n' >>"$TEST_DIRECTORY/events"
SCRIPT
run 1 gemini Hello
assert_events $'start:gemini:0\ncommand:gemini::from hook\nsuccess:gemini:0\nexit:gemini:1:from success\n'
cat >>"$LLM_CLI_HOOKS/on_start.sh" <<'SCRIPT'
false
printf 'must not run\n' >>"$TEST_DIRECTORY/events"
SCRIPT
run 1 gemini Hello
assert_events $'start:gemini:0\nexit:gemini:1:\n'

export LLM_CLI_HOOKS="$TEST_DIRECTORY/invalid hooks"
mkdir -p "$LLM_CLI_HOOKS/on_start.sh"
run 1 gemini Hello
grep -Fq 'not a readable file' "$TEST_DIRECTORY/error"
assert_events ''

printf 'All profile and hook tests passed.\n'
