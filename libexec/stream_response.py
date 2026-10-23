#!/usr/bin/env python3

import argparse
import json
import sys
import time
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

from rich.console import Console
from rich.live import Live
from rich.markdown import Markdown
from rich.status import Status
from rich.style import Style
from rich.syntax import Syntax, SyntaxTheme
from rich.text import Text
from pygments.token import Keyword, Literal, Name


class SearchSuggestionParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[tuple[str, str]] = []
        self.url: str | None = None
        self.label: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "a":
            self.url = dict(attrs).get("href")
            self.label = []

    def handle_data(self, data: str) -> None:
        if self.url is not None:
            self.label.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self.url is not None:
            if self.url.startswith(("https://", "http://")):
                self.links.append((self.url, "".join(self.label).strip() or self.url))
            self.url = None
            self.label = []


class JsonOutputTheme(SyntaxTheme):
    def get_style_for_token(self, token_type: Any) -> Style:
        if token_type in Name.Tag:
            return Style(color="#0087ff")
        if token_type in Literal.String:
            return Style(color="#00af5f")
        if token_type in Keyword.Constant:
            return Style(color="#af5fff")
        if token_type in Literal.Number:
            return Style(color="#ff8700")
        return Style.null()

    def get_background_style(self) -> Style:
        return Style.null()


class TerminalWriter:
    def __init__(
        self,
        structured_output: bool = False,
        buffered: bool = False,
        provider: str = "llama",
        status_label: str | None = None,
    ) -> None:
        self.console = Console(highlight=False)
        self.structured_output = structured_output
        self.buffered = buffered
        self.status: Status | None = None
        self.thinking = False
        self.reasoning = ""
        self.response = ""
        self.live: Live | None = None
        self.usage: dict[str, int] = {}
        self.sources: list[tuple[str, str]] = []
        self.search_queries: list[str] = []
        self.search_suggestions: list[tuple[str, str]] = []
        self.url_retrievals: dict[str, str] = {}
        self.request_started_at = time.monotonic()
        self.first_token_at: float | None = None
        self.first_answer_at: float | None = None
        self.last_answer_at: float | None = None
        if self.console.is_terminal:
            self.status = self.console.status(
                status_label or f"Waiting for {provider}", spinner="dots"
            )
            self.status.start()

    def update_status(self, message: str, completed: bool = False) -> None:
        if self.status is None:
            return
        self.status.update(message)
        if completed:
            self.status.stop()
            self.status = None

    def stop_status(self) -> None:
        if self.status is not None:
            self.status.stop()
            self.status = None

    def show_search_activity(self, step: Any) -> None:
        if not isinstance(step, dict) or self.buffered or self.structured_output:
            return
        activity = {
            "google_search_call": ("Searching", "queries"),
            "url_context_call": ("Reading", "urls"),
        }.get(step.get("type"))
        if activity is None or not self.console.is_terminal or self.live is not None:
            return
        label, field = activity
        arguments = step.get("arguments")
        values = arguments.get(field) if isinstance(arguments, dict) else None
        details = ", ".join(value for value in values if isinstance(value, str)) if isinstance(values, list) else ""
        message = Text(f"{label}: {details}" if details else f"{label}...")
        if self.thinking:
            self.console.print()
            self.thinking = False
        if self.status is None:
            self.status = self.console.status(message, spinner="dots")
            self.status.start()
        else:
            self.status.update(message)

    def write_reasoning(self, text: str) -> None:
        self.reasoning += text
        if self.first_token_at is None:
            self.first_token_at = time.monotonic()
        if self.structured_output or self.buffered:
            return
        self.stop_status()
        self.thinking = True
        self.console.print(text, style="dim", end="", markup=False, soft_wrap=True)

    def record_output_timing(self) -> None:
        received_at = time.monotonic()
        if self.first_token_at is None:
            self.first_token_at = received_at
        if self.first_answer_at is None:
            self.first_answer_at = received_at
        self.last_answer_at = received_at

    def write_token(self, text: str) -> None:
        self.record_output_timing()
        self.update_status("Writing response", completed=True)
        if self.thinking:
            self.console.print()
            self.thinking = False

        self.response += text
        if self.structured_output or self.buffered:
            return

        markdown = Markdown(self.response)
        if not self.console.is_terminal:
            return

        if self.live is None:
            self.live = Live(markdown, console=self.console, auto_refresh=False)
            self.live.start(refresh=True)
        else:
            self.live.update(markdown, refresh=True)

    def add_grounding_sources(self, metadata: Any) -> None:
        if not isinstance(metadata, dict):
            return
        chunks = metadata.get("groundingChunks")
        if not isinstance(chunks, list):
            return
        known_uris = {uri for uri, _ in self.sources}
        for chunk in chunks:
            web = chunk.get("web") if isinstance(chunk, dict) else None
            if not isinstance(web, dict):
                continue
            uri = web.get("uri")
            title = web.get("title")
            if isinstance(uri, str) and uri and uri not in known_uris:
                self.sources.append(
                    (uri, title if isinstance(title, str) and title else uri)
                )
                known_uris.add(uri)

    def add_url_citations(self, annotations: Any) -> None:
        if not isinstance(annotations, list):
            return
        known_uris = {uri for uri, _ in self.sources}
        for annotation in annotations:
            if not isinstance(annotation, dict) or annotation.get("type") != "url_citation":
                continue
            uri = annotation.get("url")
            title = annotation.get("title")
            if isinstance(uri, str) and uri and uri not in known_uris:
                self.sources.append(
                    (uri, title if isinstance(title, str) and title else uri)
                )
                known_uris.add(uri)

    def add_gemini_search_metadata(self, step: Any) -> None:
        if not isinstance(step, dict):
            return
        self.add_url_citations(step.get("annotations"))
        for content in step.get("content") or []:
            if isinstance(content, dict):
                self.add_url_citations(content.get("annotations"))
        if step.get("type") == "google_search_call":
            arguments = step.get("arguments")
            queries = arguments.get("queries") if isinstance(arguments, dict) else None
            if isinstance(queries, list):
                for query in queries:
                    if isinstance(query, str) and query not in self.search_queries:
                        self.search_queries.append(query)
        elif step.get("type") == "google_search_result":
            if step.get("is_error"):
                print("Gemini Google Search reported an error", file=sys.stderr)
            for result in step.get("result") or []:
                html = result.get("search_suggestions") if isinstance(result, dict) else None
                if not isinstance(html, str):
                    continue
                parser = SearchSuggestionParser()
                parser.feed(html)
                parser.close()
                known_urls = {url for url, _ in self.search_suggestions}
                for url, title in parser.links:
                    if url not in known_urls:
                        self.search_suggestions.append((url, title))
                        known_urls.add(url)
        elif step.get("type") == "url_context_result":
            for result in step.get("result") or []:
                if isinstance(result, dict) and isinstance(result.get("url"), str):
                    status = result.get("status")
                    self.url_retrievals[result["url"]] = status if isinstance(status, str) else "unknown"

    def finish(self) -> None:
        if self.status is not None:
            self.status.stop()
            self.status = None
        if self.buffered:
            sys.stdout.write(self.response)
            return
        elif self.structured_output and self.response:
            try:
                structured_response = json.loads(self.response)
            except json.JSONDecodeError as error:
                print(f"Invalid structured output: {error}", file=sys.stderr)
                self.console.print(self.response, markup=False)
            else:
                self.response = json.dumps(
                    structured_response, ensure_ascii=False, indent=2
                )
                self.console.print(
                    Syntax(self.response, "json", theme=JsonOutputTheme()),
                    end="",
                )
        elif self.live is not None:
            self.live.stop()
        elif self.response:
            self.console.print(Markdown(self.response))
        elif self.thinking:
            self.console.print()

        if self.sources or self.url_retrievals:
            self.console.print("Sources:", style="bold", markup=False)
            for uri, title in self.sources:
                status = self.url_retrievals.get(uri)
                label = "cited"
                if status is not None:
                    label += "; retrieved" if status == "success" else f"; retrieval: {status}"
                self.console.print(f"- {title}: {uri} [{label}]", markup=False)
            cited_urls = {url for url, _ in self.sources}
            for url, status in self.url_retrievals.items():
                if url not in cited_urls:
                    label = "retrieved; not cited" if status == "success" else f"retrieval: {status}; not cited"
                    self.console.print(f"- {url} [{label}]", markup=False)

        if self.search_queries:
            self.console.print("Search queries:", style="bold", markup=False)
            for query in self.search_queries:
                self.console.print(f"- {query}", markup=False)
        if self.search_suggestions:
            self.console.print("Search suggestions (not evidence of retrieval):", style="bold", markup=False)
            for url, title in self.search_suggestions:
                self.console.print(f"- {title}: {url}", markup=False)

        if self.usage:
            ttft = "n/a"
            if self.first_token_at is not None:
                ttft = f"{self.first_token_at - self.request_started_at:.2f}s"
            tps = "n/a"
            if (
                self.first_answer_at is not None
                and self.last_answer_at is not None
                and self.last_answer_at > self.first_answer_at
                and "candidatesTokenCount" in self.usage
            ):
                duration = self.last_answer_at - self.first_answer_at
                tps = f"{self.usage['candidatesTokenCount'] / duration:.2f}"
            total = self.usage.get("totalTokenCount", "n/a")
            self.console.print(
                f"TTFT: {ttft} | TPS: {tps} | Total tokens: {total}",
                style="dim",
                markup=False,
            )


class GeminiInteractionCollector:
    def __init__(self) -> None:
        self.interaction: dict[str, Any] = {}
        self.steps: list[dict[str, Any]] = []
        self.steps_by_index: dict[int, dict[str, Any]] = {}
        self.step_ids_by_index: dict[int, str] = {}
        self.argument_fragments: dict[str, str] = {}
        self.thought = ""

    def _set_snapshot(self, steps: list[Any]) -> None:
        previous_steps = self.steps
        self.steps = []
        for index, step in enumerate(steps):
            if not isinstance(step, dict):
                continue
            previous = previous_steps[index] if index < len(previous_steps) else {}
            if previous.get("type") == step.get("type"):
                step = {**previous, **step}
                for field in ("content", "summary", "signature", "result", "arguments"):
                    if not step.get(field) and previous.get(field):
                        step[field] = previous[field]
            self.steps.append(step)

    def _upsert_step(self, step: Any, replace: bool = False) -> None:
        if not isinstance(step, dict):
            return
        step_id = step.get("id")
        if not isinstance(step_id, str) or not step_id:
            self.steps.append(step)
            return
        for index, existing in enumerate(self.steps):
            if existing.get("id") == step_id:
                if replace:
                    self.steps[index] = step
                else:
                    self.steps[index] = {**existing, **step}
                return
        self.steps.append(step)

    def consume(self, payload: dict[str, Any], terminal: TerminalWriter) -> None:
        interaction = payload.get("interaction")
        if isinstance(interaction, dict):
            self.interaction.update(interaction)
            steps = interaction.get("steps")
            if isinstance(steps, list):
                self._set_snapshot(steps)
        steps = payload.get("steps")
        if isinstance(steps, list):
            self._set_snapshot(steps)

        event_type = payload.get("event_type")
        step = payload.get("step")
        if event_type in ("step.start", "step.complete", "step.completed"):
            self._upsert_step(step, replace=event_type != "step.start")
            step_index = payload.get("index")
            step_id = step.get("id") if isinstance(step, dict) else None
            if type(step_index) is int and isinstance(step_id, str):
                self.step_ids_by_index[step_index] = step_id
            if type(step_index) is int and isinstance(step, dict):
                self.steps_by_index[step_index] = step

        if event_type != "step.delta":
            return

        delta = payload.get("delta")
        if not isinstance(delta, dict):
            return
        delta_type = delta.get("type")
        step_id = payload.get("step_id") or payload.get("stepId")
        step_index = payload.get("index")
        if not isinstance(step_id, str) and type(step_index) is int:
            step_id = self.step_ids_by_index.get(step_index)
        if not isinstance(step_id, str):
            step_id = delta.get("id")
        if not isinstance(step_id, str):
            step_id = ""

        indexed_step = self.steps_by_index.get(step_index) if type(step_index) is int else None
        if indexed_step is not None:
            if delta_type == "text" and isinstance(delta.get("text"), str):
                content = indexed_step.get("content") or []
                indexed_step["content"] = content
                content.append(dict(delta))
            elif delta_type == "thought_summary" and isinstance(delta.get("content"), dict):
                summary = indexed_step.get("summary") or []
                indexed_step["summary"] = summary
                summary.append(dict(delta["content"]))
            elif delta_type == "thought_signature" and isinstance(delta.get("signature"), str):
                indexed_step["signature"] = delta["signature"]
            elif delta_type in ("google_search_result", "url_context_result"):
                results = indexed_step.get("result") or []
                indexed_step["result"] = results + delta.get("result", [])
                for field in ("signature", "is_error"):
                    if field in delta:
                        indexed_step[field] = delta[field]
            elif delta_type in ("google_search_call", "url_context_call") and isinstance(delta.get("arguments"), dict):
                indexed_step["arguments"] = delta["arguments"]
            elif delta_type == "text_annotation_delta":
                content = indexed_step.get("content") or []
                indexed_step["content"] = content
                content.append({"type": "text", "text": "", "annotations": delta.get("annotations", [])})

        if delta_type in ("arguments_delta", "function_call_arguments"):
            fragment = next(
                (
                    delta.get(key)
                    for key in ("arguments", "arguments_delta", "text", "delta")
                    if isinstance(delta.get(key), str)
                ),
                None,
            )
            if isinstance(fragment, str) and step_id:
                self.argument_fragments[step_id] = (
                    self.argument_fragments.get(step_id, "") + fragment
                )
        elif delta_type == "function_call":
            function_step = dict(delta)
            function_step["type"] = "function_call"
            if step_id:
                function_step.setdefault("id", step_id)
            arguments = function_step.get("arguments")
            if isinstance(arguments, str) and step_id:
                self.argument_fragments[step_id] = (
                    self.argument_fragments.get(step_id, "") + arguments
                )
                function_step.pop("arguments")
            self._upsert_step(function_step)
        elif delta_type == "thought_summary":
            content = delta.get("content")
            text = content.get("text") if isinstance(content, dict) else None
            if isinstance(text, str):
                self.thought += text

    def build(self, terminal: TerminalWriter) -> dict[str, Any]:
        for step in self.steps:
            step_id = step.get("id")
            if step.get("type") != "function_call" or not isinstance(step_id, str):
                continue
            fragment = self.argument_fragments.get(step_id)
            arguments = step.get("arguments")
            if fragment:
                try:
                    streamed_arguments = json.loads(fragment)
                except json.JSONDecodeError as error:
                    raise RuntimeError(
                        f"Incomplete streamed arguments for function call {step_id}"
                    ) from error
                if not isinstance(streamed_arguments, dict):
                    raise RuntimeError(
                        f"Streamed arguments for function call {step_id} are not an object"
                    )
                step["arguments"] = streamed_arguments
            elif isinstance(arguments, str):
                try:
                    parsed_arguments = json.loads(arguments)
                except json.JSONDecodeError as error:
                    raise RuntimeError(
                        f"Incomplete arguments for function call {step_id}"
                    ) from error
                if not isinstance(parsed_arguments, dict):
                    raise RuntimeError(
                        f"Arguments for function call {step_id} are not an object"
                    )
                step["arguments"] = parsed_arguments

        if not self.steps and terminal.response:
            if self.thought:
                self.steps.append(
                    {
                        "type": "thought",
                        "summary": [{"type": "text", "text": self.thought}],
                    }
                )
            self.steps.append(
                {
                    "type": "model_output",
                    "content": [{"type": "text", "text": terminal.response}],
                }
            )
        elif not terminal.response:
            output_text = "".join(
                content.get("text", "")
                for step in self.steps
                if step.get("type") == "model_output"
                for content in (
                    step.get("content")
                    if isinstance(step.get("content"), list)
                    else []
                )
                if isinstance(content, dict)
                and isinstance(content.get("text"), str)
            )
            if output_text:
                terminal.write_token(output_text)

        if not terminal.response and not any(
            step.get("type") == "function_call" for step in self.steps
        ):
            raise RuntimeError("Gemini returned no answer text or function call")

        interaction = dict(self.interaction)
        interaction["steps"] = self.steps
        return interaction


def render_event(
    data: str,
    terminal: TerminalWriter,
    provider: str = "llama",
    collector: GeminiInteractionCollector | None = None,
) -> None:
    if not data or data == "[DONE]":
        return

    try:
        payload: Any = json.loads(data)
    except json.JSONDecodeError as error:
        print(f"Ignoring malformed stream event: {error}", file=sys.stderr)
        return

    if not isinstance(payload, dict):
        return

    if provider in ("gemini", "grok"):
        started_at = payload.get("requestStartedAt")
        if isinstance(started_at, (int, float)) and terminal.first_token_at is None:
            terminal.request_started_at = started_at

    if provider == "grok":
        response_output = payload.get("output")
        if payload.get("object") == "response" or isinstance(response_output, list):
            if error := payload.get("error"):
                raise RuntimeError(f"Grok API error: {error}")
            status = payload.get("status")
            if status in ("failed", "incomplete"):
                raise RuntimeError(f"Grok API error: {payload}")
            if isinstance(response_output, list):
                for item in response_output:
                    if (
                        not isinstance(item, dict)
                        or item.get("type") != "message"
                        or item.get("role") != "assistant"
                    ):
                        continue
                    content = item.get("content")
                    if not isinstance(content, list):
                        continue
                    for part in content:
                        if (
                            isinstance(part, dict)
                            and part.get("type") == "output_text"
                            and isinstance(part.get("text"), str)
                        ):
                            terminal.write_token(part["text"])
            usage = payload.get("usage")
            if isinstance(usage, dict):
                for source, target in (
                    ("output_tokens", "candidatesTokenCount"),
                    ("total_tokens", "totalTokenCount"),
                ):
                    count = usage.get(source)
                    if type(count) is int and count >= 0:
                        terminal.usage[target] = count
            return

        event_type = payload.get("type")
        if error := payload.get("error"):
            raise RuntimeError(f"Grok API error: {error}")
        if event_type in ("error", "response.failed", "response.incomplete"):
            raise RuntimeError(f"Grok API error: {payload}")
        if event_type in ("response.output_text.delta", "response.refusal.delta"):
            text = payload.get("delta")
            if isinstance(text, str) and text:
                terminal.write_token(text)
        elif event_type == "response.completed":
            usage = payload.get("response", {}).get("usage")
            if isinstance(usage, dict):
                for source, target in (
                    ("output_tokens", "candidatesTokenCount"),
                    ("total_tokens", "totalTokenCount"),
                ):
                    count = usage.get(source)
                    if type(count) is int and count >= 0:
                        terminal.usage[target] = count
        return

    if provider == "gemini":
        if collector is not None:
            collector.consume(payload, terminal)
        if error := payload.get("error"):
            message = error.get("message", error) if isinstance(error, dict) else error
            raise RuntimeError(f"Gemini API error: {message}")

        event_type = payload.get("event_type")
        if event_type == "error":
            raise RuntimeError(f"Gemini API error: {payload}")

        interaction = payload.get("interaction")
        if not isinstance(interaction, dict):
            interaction = payload
        terminal.add_gemini_search_metadata(payload.get("step"))
        if event_type == "step.start":
            terminal.show_search_activity(payload.get("step"))
        for step in interaction.get("steps") or []:
            terminal.add_gemini_search_metadata(step)
        usage = interaction.get("usage")
        if isinstance(usage, dict):
            for source, target in (
                ("total_output_tokens", "candidatesTokenCount"),
                ("total_tokens", "totalTokenCount"),
            ):
                count = usage.get(source)
                if type(count) is int and count >= 0:
                    terminal.usage[target] = count

        delta = payload.get("delta")
        if event_type == "step.delta" and isinstance(delta, dict):
            terminal.add_gemini_search_metadata(delta)
            terminal.show_search_activity(delta)
            delta_type = delta.get("type")
            if delta_type == "text":
                text = delta.get("text")
                if isinstance(text, str) and text:
                    terminal.write_token(text)
                    terminal.add_url_citations(delta.get("annotations"))
            elif delta_type == "thought_summary":
                content = delta.get("content")
                text = content.get("text") if isinstance(content, dict) else None
                if isinstance(text, str) and text:
                    terminal.write_reasoning(text)
            elif delta_type in ("arguments_delta", "function_call_arguments", "function_call"):
                if delta.get("arguments"):
                    terminal.record_output_timing()
            return

        if event_type == "step.start":
            step = payload.get("step")
            if isinstance(step, dict) and step.get("type") == "thought":
                for content in step.get("summary") or []:
                    if isinstance(content, dict) and isinstance(content.get("text"), str):
                        terminal.write_reasoning(content["text"])

        if event_type == "interaction.completed":
            status = interaction.get("status")
            if status and status != "completed" and not (
                status == "requires_action" and collector is not None
            ):
                raise RuntimeError(f"Gemini interaction ended with status: {status}")
            terminal.stop_status()
            summaries = "".join(
                content["text"]
                for step in interaction.get("steps") or []
                if isinstance(step, dict) and step.get("type") == "thought"
                for content in step.get("summary") or []
                if isinstance(content, dict) and isinstance(content.get("text"), str)
            )
            if summaries.startswith(terminal.reasoning):
                remainder = summaries[len(terminal.reasoning):]
                if remainder:
                    terminal.write_reasoning(remainder)
            return

        steps = interaction.get("steps")
        if isinstance(steps, list):
            for step in steps:
                if not isinstance(step, dict):
                    continue
                step_type = step.get("type")
                content_blocks = step.get("content")
                if step_type == "thought":
                    content_blocks = step.get("summary", [])
                if not isinstance(content_blocks, list):
                    continue
                for content in content_blocks:
                    if not isinstance(content, dict):
                        continue
                    text = content.get("text")
                    if not isinstance(text, str) or not text:
                        continue
                    if step_type == "thought":
                        terminal.write_reasoning(text)
                    elif step_type == "model_output":
                        terminal.write_token(text)
                        terminal.add_url_citations(content.get("annotations"))
        return

    reasoning = payload.get("reasoning")
    if isinstance(reasoning, str) and reasoning:
        terminal.write_reasoning(reasoning)

    token = payload.get("token")
    if isinstance(token, str) and token:
        terminal.write_token(token)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--provider", choices=("llama", "gemini", "grok"), default="llama"
    )
    parser.add_argument("--response-file", type=Path)
    parser.add_argument("--interaction-file", type=Path)
    parser.add_argument("--status-label")
    parser.add_argument("--structured-output", action="store_true")
    parser.add_argument("--buffered", action="store_true")
    args = parser.parse_args()
    terminal = TerminalWriter(
        structured_output=args.structured_output,
        buffered=args.buffered,
        provider=args.provider,
        status_label=args.status_label,
    )
    if args.interaction_file is not None and args.provider != "gemini":
        parser.error("--interaction-file is only supported by the Gemini provider")
    collector = GeminiInteractionCollector() if args.interaction_file is not None else None
    data_lines: list[str] = []
    raw_json_lines: list[str] = []

    try:
        for raw_line in sys.stdin:
            line = raw_line.rstrip("\r\n")
            if not line:
                if raw_json_lines:
                    raw_json_lines.append(line)
                else:
                    render_event(
                        "\n".join(data_lines), terminal, args.provider, collector
                    )
                    data_lines.clear()
            elif line.startswith("data:"):
                if raw_json_lines:
                    render_event(
                        "\n".join(raw_json_lines), terminal, args.provider, collector
                    )
                    raw_json_lines.clear()
                data = line[5:]
                data_lines.append(data[1:] if data.startswith(" ") else data)
            elif args.provider in ("gemini", "grok") and (
                raw_json_lines or line.lstrip().startswith("{")
            ):
                raw_json_lines.append(line)

        render_event("\n".join(data_lines), terminal, args.provider, collector)
        if raw_json_lines:
            render_event(
                "\n".join(raw_json_lines), terminal, args.provider, collector
            )
        interaction_result = collector.build(terminal) if collector else None
        if (
            args.provider in ("gemini", "grok")
            and not terminal.response
            and interaction_result is None
        ):
            raise RuntimeError(f"{args.provider.capitalize()} returned no answer text")
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1
    finally:
        terminal.finish()
    if args.response_file is not None:
        args.response_file.write_text(terminal.response, encoding="utf-8")
    if args.interaction_file is not None and interaction_result is not None:
        args.interaction_file.write_text(
            json.dumps(interaction_result, ensure_ascii=False), encoding="utf-8"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
