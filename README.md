# llm-cli

A Bash command-line client for sending prompts to the configured llama service,
Google Gemini, or xAI Grok. Responses can be streamed and rendered as Markdown
in the terminal. Optional features include file and image attachments, web
search, structured JSON output, image generation, and session history.

## Requirements

- Bash
- Python 3 and the Python packages in [`requirements.txt`](./requirements.txt)
- `curl`, `jq`, and `uuidgen`
- `tail` and `xargs` for the `read` tool
- `yq` to use JSON schemas
- `file` and `base64` when attaching images
- `secret-tool` to use Gemini or Grok
- `sqlite3` when session history is enabled
- `notify-send` for Grok image-generation notifications

Install the Python dependency from the repository root:

```bash
python3 -m pip install -r requirements.txt
```

Run the CLI directly, or add `bin/` to `PATH` and invoke `llm.sh`:

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
-l, --location LOCATION Select llama service location: local, desktop, remote
-i, --images PATH...    Attach one or more images
-f, --files PATH...     Attach one or more text files
-v, --verbose           Print request details
-h, --help              Show help
```

`--location` applies only to llama. `--stream false` is supported by Gemini and
Grok, but not llama. Search is available for Gemini and Grok; image generation
is Grok-only and cannot be combined with search, schemas, or attachments.
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
`/home/adrien/.config/llm-cli/output_schemas`; override it with
`LLM_CLI_SCHEMA_DIRECTORY`. Pass either a schema name or its `.yaml` filename.

### Providers

| Provider | Default model | Notes |
| --- | --- | --- |
| llama | `gemma4-31bunc` | Uses the llama service; supports `local`, `desktop`, or `remote` locations. |
| Gemini | `gemini-flash-latest` | Uses the Gemini Interactions API and can enable Google Search grounding. |
| Grok | `grok-4.7` | Uses the xAI API; supports web/X search. Image generation defaults to `grok-imagine-image-2.0`. |

Override a model with `--model`. Gemini and Grok keys are retrieved with
`secret-tool lookup service <provider> key api_key`.

### Llama endpoint configuration

Set the API base URL for each llama location you use. These environment
variables are required for the selected location; there are no fallback URLs:

| Location | Environment variable |
| --- | --- |
| `local` | `LLM_CLI_LLAMA_LOCAL_URL` |
| `desktop` (default) | `LLM_CLI_LLAMA_DESKTOP_URL` |
| `remote` | `LLM_CLI_LLAMA_REMOTE_URL` |

For example, export your actual service addresses in your shell configuration:

```bash
export LLM_CLI_LLAMA_LOCAL_URL='http://localhost:8000/llm'
export LLM_CLI_LLAMA_DESKTOP_URL='https://desktop.example.com/llm'
export LLM_CLI_LLAMA_REMOTE_URL='https://gpu.example.com/llm'
```

Values include the API base path (such as `/llm`), not `/stream-multiplex/`.
A trailing slash is optional. Both llama prompts and `llm manage` use these
variables; Gemini and Grok do not require them. Missing or empty values fail
with an error naming the required variable.

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

## Managing the llama service

The `manage` subcommand controls the llama service:

```bash
./bin/llm.sh manage status
./bin/llm.sh manage pause
./bin/llm.sh manage resume --location local
./bin/llm.sh manage swap --model gemma4-31bunc
```

Management commands default to the `desktop` location. Use `--location local`,
`desktop`, or `remote` to select the service.

## Tool utilities

Register a tool by name. Tool YAML files are searched in this order:
`~/.config/llm-cli/tools/`, `~/dev/llm-cli/.config/tools/`, and the checked-out
repository's `.config/tools/` directory. Only `type: function` tools require a
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

Top-level symlinks are retained for compatibility with the former script paths.

## Tests

Run the CLI integration tests with:

```bash
bash tests/test_ask.sh
```