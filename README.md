# llm-cli

A Bash command-line client for sending prompts to the configured llama service,
Google Gemini, or xAI Grok. Responses can be streamed and rendered as Markdown
in the terminal. Optional features include file and image attachments, web
search, structured JSON output, image generation, and session history.

## Requirements

- Bash
- [`uv`](https://docs.astral.sh/uv/) (uses the pinned Python version and installs helper dependencies)
- `curl`, `jq`, and `uuidgen`
- `tail` and `xargs` for the `read` tool
- `yq` to use JSON schemas
- `file` and `base64` when attaching images
- `secret-tool` to use Gemini or Grok
- `sqlite3` when session history is enabled
- `notify-send` for Grok image-generation notifications

Set up the pinned Python environment and install dependencies from the
repository root:

```bash
uv sync
```

The launcher uses `.venv/bin` for Python helper scripts when that environment
exists. Run the CLI directly, or add `bin/` to `PATH` and invoke `llm.sh`:

```bash
./bin/llm.sh --help
```

Gemini and Grok credentials are read from the desktop secret store using these
attributes:

```text
service=gemini key=api_key
service=grok key=api_key
```

The Grok value should be the API token; the client adds the `Bearer` scheme.

## Usage

The default backend is llama:

```bash
./bin/llm.sh 'Explain the output of this command'
./bin/llm.sh gemini 'Summarize this paragraph'
./bin/llm.sh grok 'What changed in the latest release?'
```

Piped input is appended to the prompt:

```bash
cat notes.txt | ./bin/llm.sh gemini 'Summarize these notes'
```

Attach local files or images (or HTTP(S) URLs):

```bash
./bin/llm.sh 'Describe this picture' --images photo.png
./bin/llm.sh gemini 'Summarize the report' --files report.txt
```

Use provider-specific features:

```bash
./bin/llm.sh gemini --search 'Find recent news about the mission'
./bin/llm.sh grok --search 'Find recent posts about the announcement'
./bin/llm.sh grok --image-gen 'A watercolor illustration of a lighthouse'
```

### Prompt options

```text
--search                Enable Gemini Google Search or Grok web/X search
--image-gen             Generate an image with Grok
--buff                  Buffer the response before printing it
--stream [true|false]   Control streaming (default: true)
--schema NAME           Use NAME.yaml for structured JSON output
--tools NAME...         Register Gemini built-in or function tools
-m, --model MODEL       Override the provider model
-i, --image, --images PATH... Attach one or more images
-f, --files PATH...     Attach one or more text files
-v, --verbose           Print request details
-h, --help              Show help
```

`--stream false` is supported by Gemini and Grok, but not llama. Search is
available for Gemini and Grok; image generation is Grok-only and cannot be
combined with search, schemas, or attachments.
`--tools` is supported by Gemini and uses streaming requests to process
function calls. Interactive terminals show a spinner while waiting for model
responses, then display progress steps for execution. The confirmation view
shows the requesting provider and tool name, the executable path in muted
italic text, and only the function-arguments JSON object. Streamed responses
switch from the thinking spinner to the answer when response text arrives.
Gemini thinking summaries are shown as they arrive when supplied by the API;
the waiting spinner stops at the first summary chunk so it cannot overwrite
partial lines. Each streamed
interaction, including a function-call handoff, prints its timing and token
usage once; function-argument chunks contribute to tool-call timing. The
final answer is rendered only once. `--buff` keeps output buffered and omits
thinking and metrics, as it does for other requests.

Search output lists all returned citation URLs, search queries, and search
suggestion links without a result limit. Sources are labelled `cited` or,
when URL retrieval telemetry is available, `retrieved; not cited`; failed
retrievals retain their reported status. Uncited does not mean unused, and
suggestion links are not evidence that a page was read. Gemini does not expose
the full underlying Google results list. The spinner shows `Searching: <query>`
and `Reading: <URL>` when the API reports those operations, never inferred
from citations. Buffered output continues to contain only the answer.

Schemas must be YAML objects. The default schema directory is
`$HOME/.config/llm-cli/output_schemas`; override it with
`LLM_CLI_SCHEMA_DIRECTORY`. Pass either a schema name or its `.yaml` filename.

### Profiles and hooks

Select an environment profile before the subcommand:

```bash
./bin/llm.sh --profile coding gemini 'Review this function'
```

This sources `~/.config/llm-cli/profiles/coding.env`. Profiles are trusted,
Bash-compatible environment files. Plain `KEY=value` assignments are
automatically exported to hooks and child commands; explicit `export` also works.
Quote values containing spaces or shell metacharacters. Profiles are sourced as
Bash, so they can execute shell commands. They configure the environment, not
command-line defaults. For example:

```bash
LLM_CLI_SCHEMA_DIRECTORY="$HOME/.config/llm-cli/coding-schemas"
```

Without an explicit selection, `default.env` is loaded if present; its absence is
allowed. Set `PROFILE` to select a profile through the environment; `--profile`
overrides it. Names must contain only letters, digits, dots, underscores, or
hyphens, must not start with a hyphen, and are given without the `.env` suffix.
Explicitly selected profiles must exist. Unreadable or failing profiles always
stop the command, including an existing `default.env`.

Optional trusted Bash hooks are sourced directly from
`~/.config/llm-cli/hooks/`:

| Hook | When it runs |
| --- | --- |
| `on_start.sh` | After the profile is loaded, before dispatch. |
| `on_success.sh` | After the command exits successfully. |
| `on_error.sh` | After the command exits with a nonzero status. |
| `on_exit.sh` | Once at the end, including when another hook fails. |

Hooks receive the subcommand's arguments as `"$@"`, plus the exported variables
`LLM_CLI_COMMAND` (with `ask` normalized to `llama`), `LLM_CLI_PROFILE` (the
selected name, `default` when unspecified), and `LLM_CLI_EXIT_STATUS` (zero before dispatch, then the
command or hook's exit status). Exported changes made by `on_start.sh` reach the
command. Hooks are sourced, not executed, so they need not be executable.
The final `on_exit.sh` hook is sourced in a subshell to isolate its exit status.
Use `return` rather than `exit` to report a hook failure, and write hook notices
to stderr to avoid mixing them into the response.

Missing hooks are skipped. A failing hook stops that phase and makes a successful
invocation fail; an already-failed command retains its original exit status.
`on_error.sh` handles command failures, not failures in other hooks. Help,
invalid subcommands, and profile-loading failures do not run hooks.

`LLM_CLI_CONFIG` overrides the configuration root; `LLM_CLI_PROFILE_DIR` and
`LLM_CLI_HOOKS` override the two directories independently. Directories are
created when missing, and their configured paths are exported to child commands.

### Environment variable reference

This is the complete list of project-specific environment inputs and exported
context variables used by the runtime scripts. Internal shell variables and test-fixture
variables are not configuration options. Other environment variables can be
passed through a profile for custom hooks or tools, but the CLI does not
necessarily read them.

#### Overrides available in a profile

Use plain Bash assignments in `profiles/NAME.env`; `export` is optional.
Defaults describe an invocation without an override.

| Variable | Default | Effect and scope |
| --- | --- | --- |
| `LLAMA_URL` | `http://localhost:8080` | Shared llama base URL for prompts and management. The CLI appends the appropriate endpoint; do not include `/v1/chat/completions`. A trailing slash is optional. |
| `LLAMA_SOCKET` | Unset | Send llama prompts and router management requests over this Unix-domain socket instead of `LLAMA_URL`. |
| `LLM_MODEL_NAME` | `qwen3.5-4bunc` | Default llama router preset for prompts and management. `--model` overrides it; Gemini and Grok are unaffected. |
| `LLM_CLI_SCHEMA_DIRECTORY` | `$HOME/.config/llm-cli/output_schemas` | Directory containing YAML schemas selected with `--schema`. |
| `LLM_CLI_TOOL_DIR` | `$HOME/.config/llm-cli/tools` | First directory searched for tool definitions selected with `--tools`. The existing home development and repository fallback directories remain; see [Tool utilities](#tool-utilities). |
| `SYSTEM` | Built-in Markdown instructions and generated machine context | A nonempty value replaces the default system prompt, without appending machine context. Unset or empty retains the default. Gemini still appends its existing provider-specific Bash/Python and credential-handling instructions. |
| `AGENT_SESSION_ID` | Unset; history disabled | Nonempty session identifier enables SQLite history and reuses that session across requests. Unset or empty disables history. Sourcing [`lib/llm-cli.sh`](./lib/llm-cli.sh) generates and exports a UUID if the value is unset or empty. |
| `LLM_HISTORY_LIMIT` | Empty; all stored messages | Maximum stored message rows loaded into a request when history is enabled. Use a nonnegative integer; `0` loads no previous messages. This is not a token or turn limit and does not stop new messages being stored. |
| `LLM_CLI_HOOKS` | `$LLM_CLI_CONFIG/hooks` | Directory containing the four lifecycle `.sh` hooks. A profile can redirect subsequent hook loading. Directory creation happens before the profile is sourced, so a replacement directory set inside a profile must already exist. |

`LLAMA_URL` is unused by Gemini and Grok. Select a different llama server by
setting it in a named profile, rather than choosing a location.

Example profile:

```bash
LLAMA_URL='http://localhost:8080'
LLM_CLI_SCHEMA_DIRECTORY="$HOME/.config/llm-cli/output_schemas"
LLM_CLI_TOOL_DIR="$HOME/.config/llm-cli/coding-tools"
SYSTEM='You are a coding assistant. Give concise, actionable answers in Markdown.'
AGENT_SESSION_ID='coding'
LLM_HISTORY_LIMIT=20
```

When history is enabled, [`lib/db.sh`](./lib/db.sh) also sources every `*.env`
file directly under `$HOME/.local/share/llm-cli/`, after the selected profile
has loaded. These legacy files can overwrite profile settings, including
`AGENT_SESSION_ID` and `LLM_HISTORY_LIMIT`; avoid conflicting assignments.

#### Overrides that must be set before startup

These are consumed before the profile is opened. Setting them inside that
profile cannot change which profile was selected or recreate the initial
directory layout.

| Variable | Default | Effect |
| --- | --- | --- |
| `LLM_CLI_CONFIG` | `$HOME/.config/llm-cli` | Configuration root used to derive the initial profile and hook directories. It does not relocate schemas, tool definitions, or history. |
| `LLM_CLI_PROFILE_DIR` | `$LLM_CLI_CONFIG/profiles` | Directory searched for `NAME.env`. This is the supported name; `LLM_CLI_PROFILES` and `LLM_CLI_PROFILES_DIR` are not read. |
| `PROFILE` | `default` | Profile name without `.env`. A nonempty environment selection is required to exist; the implicit default is optional. `--profile NAME` takes precedence. |

`LLM_CLI_HOOKS` can also be set before startup; in that case the launcher creates
the directory if missing. An unset or empty incoming directory override uses
its default. Changing `LLM_CLI_CONFIG` alone inside a profile does not recompute
the already-initialized profile or hook paths.

```bash
LLM_CLI_CONFIG="$HOME/.config/llm-work" PROFILE=coding \
  ./bin/llm.sh gemini 'Review this function'
```

#### Exported runtime context, not profile settings

Treat these as information for hooks and child commands, not configuration to
overwrite:

| Variable | Value and behavior |
| --- | --- |
| `LLM_CLI_COMMAND` | Selected command: `llama`, `gemini`, `grok`, or `manage`; `ask` is normalized to `llama`. |
| `LLM_CLI_PROFILE` | Selected profile name, including `default` when its optional file is absent. |
| `LLM_CLI_EXIT_STATUS` | `0` before dispatch; subsequently the command or hook exit status. |
| `LLM_CLI_PROVIDER` | Prompt backend selected by the launcher, assigned **after** profile loading. A profile cannot use it to override the subcommand. It is an environment input only when invoking [`libexec/ask.sh`](./libexec/ask.sh) directly, where it defaults to `llama`; `manage` does not use it. |

The launcher also exports `LLM_CLI_CONFIG`, `LLM_CLI_PROFILE_DIR`, and
`LLM_CLI_HOOKS`. An internal child script invoked directly does not load
launcher profiles or run launcher hooks.

#### Names that do not provide environment overrides

The following command settings are initialized by the scripts, so putting them
in a profile does **not** establish CLI defaults:

| Variables | Set through |
| --- | --- |
| `MODEL` | `--model`; otherwise provider defaults apply. |
| `MESSAGE` | The prompt argument and piped input. |
| `SEARCH`, `IMAGE_GEN`, `BUFFERED`, `STREAM`, `SCHEMA`, `VERBOSE` | `--search`, `--image-gen`, `--buff`, `--stream`, `--schema`, `--verbose`. |
| `IMAGES`, `FILES`, `TOOL_NAMES`, `TOOL_DEFINITIONS` | `--images`, `--files`, `--tools` and loaded tool configurations. These are internal Bash arrays, not environment inputs. |
| `APP_HOME`, `DB` | Computed from `HOME` by the history helper, replacing incoming values. |
| `SYSTEM_CONTEXT` | Generated by the prompt handler when using the default `SYSTEM`; it is not a separate override. |
| `URL`, `API_URL`, `ENDPOINT` | Computed by the providers/management handler. Use `LLAMA_URL` for llama; Gemini and Grok endpoints are fixed. |

There are no project environment overrides for generation parameters such as
temperature, maximum tokens, or thinking budgets. Python helpers receive their
project configuration through command-line arguments and input files, not
separate environment variables.

There is also no API-key environment override: Gemini and Grok always use
`secret-tool lookup service <provider> key api_key`. Setting `GEMINI_API_KEY`,
`GOOGLE_API_KEY`, `GROK_API_KEY`, or `XAI_API_KEY` does not replace that lookup.

### Providers

| Provider | Default model | Notes |
| --- | --- | --- |
| llama | `qwen3.5-4bunc` | Uses the OpenAI-compatible chat completions API at `$LLAMA_URL/v1/chat/completions`; the base URL defaults to `http://localhost:8080`. Select another router preset with `LLM_MODEL_NAME` or `--model`. |
| Gemini | `gemini-flash-latest` | Uses the Gemini Interactions API and can enable Google Search grounding. |
| Grok | `grok-4.7` | Uses the xAI API; supports web/X search. Image generation defaults to `grok-imagine-image-2.0`. |

Override a model with `--model`. Gemini and Grok keys are retrieved with
`secret-tool lookup service <provider> key api_key`.

Gemini payloads are built and validated with the `google-genai` Interactions
SDK models in [`libexec/build_gemini_payload.py`](./libexec/build_gemini_payload.py);
curl still sends the requests and the existing renderer handles responses.
The SDK version in [`requirements.txt`](./requirements.txt) is required for these
models. A typed extension preserves the legacy `thinking_budget: 2048` setting;
newer models retain their existing thinking-level settings. Tool history and tool
definitions that the SDK cannot serialize without changes fail explicitly rather
than silently losing data.

### Llama endpoint configuration

Prompts and management commands use `LLAMA_URL`, defaulting to
`http://localhost:8080` when unset or empty. Set `LLAMA_SOCKET` to send llama
prompts and router management requests over a Unix-domain socket instead.
The CLI appends these paths:

| Operation | Endpoint path |
| --- | --- |
| Prompt | `/v1/chat/completions` |
| Management status | `/models` |
| Pause / unload | `/models/unload` |
| Resume / load / swap | `/models/load` |

A base-path prefix is allowed and applies to every endpoint. For example,
`LLAMA_URL='https://llama.example.com/api/'` sends prompts to
`https://llama.example.com/api/v1/chat/completions` and status requests to
`https://llama.example.com/api/models`.

**Migration:** `LLAMA_URL` is now a base URL, not a full chat-completions URL;
remove `/v1/chat/completions` from existing values. The location selector and
per-location URL variables have been removed. Use named profiles with different
`LLAMA_URL` values to switch servers.

For llama requests and management over the package-managed Unix socket, set
`LLAMA_SOCKET` in the profile:

```bash
LLAMA_SOCKET="${XDG_RUNTIME_DIR:-/tmp/llm-$(id -u)}/llama-shared.sock"
LLM_MODEL_NAME=qwen3.5-4bunc
```

## Session history

When `AGENT_SESSION_ID` is set, prompts and responses are stored in
`$HOME/.local/share/llm-cli/.db` and included in subsequent requests for that
session. Tool-enabled Gemini turns store their model steps, tool results, and
confirmation decisions in the same `messages` table. Event keys in message
metadata make those records idempotent; confirmation records are kept locally
but are not sent to providers. Grok replays the same session in order, including
Gemini answers, thinking summaries, function calls, and tool results. Tool
events are translated to xAI Responses history items; Gemini thought signatures
are omitted. This replays past tool activity, but does not enable new local
function calls for Grok (`--tools` remains Gemini-only).
Source [`lib/llm-cli.sh`](./lib/llm-cli.sh) to
generate a UUID when `AGENT_SESSION_ID` is unset:

```bash
source ./lib/llm-cli.sh
./bin/llm.sh 'Continue our conversation'
```

Without `AGENT_SESSION_ID`, requests are sent without stored conversation
history.

By default, system instructions include the local Linux kernel, operating
system, current user, CPU and GPU (when detected), and current working directory
as environment context. A nonempty `SYSTEM` replaces this default prompt and
does not include that automatically generated context.

## Managing the llama router

The `manage` subcommand uses native llama-server router endpoints:

```bash
./bin/llm.sh manage status
./bin/llm.sh manage pause --model qwen3.5-4bunc
./bin/llm.sh manage resume --model qwen3.5-4bunc
./bin/llm.sh manage swap --model gemma4-31bunc
```

`status` (alias `models`) lists all registered models and rejects `--model`. `pause` (alias `unload`) unloads the selected model; `resume` (alias `load`) and `swap` load it. Without `--model`, these commands use `LLM_MODEL_NAME`, defaulting to `qwen3.5-4bunc`. Names must match router presets, not GGUF paths.

Management commands use the same `LLAMA_SOCKET` or `LLAMA_URL` as llama prompts. For example,
after defining `LLAMA_URL` in `profiles/remote.env`, use
`./bin/llm.sh --profile remote manage status` to manage that server.

With router autoload enabled, selecting a model in a prompt is sufficient to load it:

```bash
llm llama --model gemma4-31bunc 'Explain this code'
```

`swap` preloads a model; it does not change the default for subsequent prompts. Set `LLM_MODEL_NAME` in your profile to change that default, or keep passing `--model`. `pause` unloads a model but does not disable autoload; the next request for it will load it again. With `--models-max 1`, loading another model evicts the previous one. Allow for loading latency and avoid swapping during active requests.

**Migration:** management no longer calls the custom Python service's `/status`, `/pause`, `/resume`, or `/change-model/` endpoints. Point it at the native router, including through the shared Unix socket. The old `--params`, `--context`, `--vram`, `--agents`, `--preserve-flux`, `--clear-cpu-encoder`, and `--no-restart` flags are rejected. Put model paths, projections, context sizes, and other load options in the router's `models.ini` presets. Model management no longer coordinates Flux resources.

## Tool utilities

Register a tool by name. Tool YAML files are searched in this order:

1. `LLM_CLI_TOOL_DIR`, defaulting to `$HOME/.config/llm-cli/tools` when unset or empty.
2. `$HOME/dev/llm-cli/.config/tools`.
3. The checked-out repository's `.config/tools` directory.

The first matching `NAME.yaml` is used. A profile can set `LLM_CLI_TOOL_DIR`
without removing the fallback directories. This configures definitions only;
tool executable paths remain unchanged. Only `type: function` tools require a
matching executable at `libexec/tool_execs/NAME.sh`; each function call is shown
by the confirmation runner before execution. Built-in `type: google_search`
tools run on Gemini and need no local executable or execution approval.

The included search configuration can be registered with `--tools search`,
or combined with local functions using `--tools search read`.

For example, the included `read` tool can be used with Gemini:

```bash
./bin/llm.sh gemini 'Summarize the notes in notes.txt' --tools read
```

Register `input` to let Gemini ask a follow-up question:

```bash
./bin/llm.sh gemini 'Ask me which file to summarize, then read it' --tools input read
```

The `input` tool uses `{"answer":"Question to ask the user"}` as its arguments
and returns the user's response verbatim (followed by a newline). After the
usual execution approval, it reads from the terminal in the foreground,
without an execution spinner. A terminal is required; tool results and approval
decisions are recorded using the same session history as other tools.

`read` receives the function arguments as a JSON object and prints the requested
file contents with `tail -n +1`, including filename headers for multiple files.
NUL-delimited arguments preserve spaces and special characters in paths.
Read errors are reported by `tail` and cause the tool to fail; any output already
read from other files may still be printed.

`write` receives `{"paths":["FILE",...],"content":"TEXT"}` and writes the same
content to each path, replacing existing file contents. Paths must be non-empty,
and their parent directories must already exist. Review the requested paths and
content before approving the tool call.

`rg` receives `{"pattern":"TEXT","paths":["TEXT",...]}` and searches every
line recursively for a match.

`tree` receives `{"path":"TEXT,"depth":"INT"}` and prints a tree representation
of the supplied dir, showing a clear file hierarchy. 

Gemini tool interactions remain stateless (`store: false`); the
CLI resends the complete interaction history, including tool calls and results.

Render a Jinja2 YAML template using values from a YAML mapping:

```bash
./libexec/render_yaml.py assets/templates/tool.yaml.j2 .config/tools/read.yaml
```

Rendered YAML is written to standard output. Missing template variables and
invalid rendered YAML are reported as errors.

Prompt for confirmation before running an executable and its arguments:

```bash
./libexec/confirm_exec.sh /path/to/executable --option value
```

The confirmation wrapper requires an interactive terminal. Declining the
prompt cancels execution.

## Repository layout

- [`bin/`](./bin/) — top-level CLI entry points
- [`lib/`](./lib/) — sourced helpers and session database functions
- [`lib/llm_providers/`](./lib/llm_providers/) — sourced provider implementations
- [`libexec/`](./libexec/) — internal executables, including the prompt handler,
  service-management subcommand, response renderer, YAML renderer, confirmation
  runner, and formatter
- [`tests/`](./tests/) — CLI and response-rendering tests

The launcher lives at `bin/llm.sh`; a `llm` symlink on `PATH` can point to it.

## Tests

Run the SDK payload tests with:

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_build_gemini_payload.py'
```

Run the CLI integration tests with:

```bash
bash tests/test_startup.sh
PATH="$PWD/.venv/bin:$PATH" bash tests/test_ask.sh
```