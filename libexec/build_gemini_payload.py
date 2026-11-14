#!/usr/bin/env python3

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, NoReturn

from google.genai import interactions
from pydantic import SerializeAsAny, TypeAdapter, ValidationError

INSTRUCTIONS = (
    "Prefer Bash for scripts and command-line solutions. When Bash is not appropriate, "
    "suggest Python and briefly explain why. In Gemini API examples, use "
    "$(secret-tool lookup service gemini key api_key) instead of a literal API key or "
    "API-key placeholder. Place this command substitution inside double quotes so Bash "
    "expands it when the example is run. Never print or expose the actual API key."
)
STEP_ADAPTER = TypeAdapter(list[interactions.Step])
TOOL_ADAPTER = TypeAdapter(list[interactions.Tool])


class BudgetGenerationConfig(interactions.GenerationConfig):
    # The REST API's legacy budget is absent from the SDK's declared fields.
    thinking_budget: int


class GeminiPayload(interactions.CreateModelInteraction):
    generation_config: SerializeAsAny[interactions.GenerationConfig] | None = None


def _fail(message: str) -> NoReturn:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def _validated_model(model: str) -> str:
    raw_model = model
    if model.startswith("models/"):
        model = model[len("models/") :]
    if not re.fullmatch(r"[a-zA-Z0-9._-]+", model):
        raise ValueError(f"Invalid Gemini model: {raw_model}")
    return model


def _build_configs(model_name: str) -> interactions.GenerationConfig:
    """Determine thinking and generation configurations based on model name."""
    model_name = _validated_model(model_name)
    if model_name == "gemini-flash-latest" or model_name.startswith(
        ("gemini-3.6", "gemini-3.7", "gemini-3.8", "gemini-4")
    ):
        return interactions.GenerationConfig(
            thinking_level="high", thinking_summaries="auto"
        )
    if model_name.startswith("gemini-3"):
        return interactions.GenerationConfig(
            thinking_level="high", thinking_summaries="auto", temperature=0.9
        )
    return BudgetGenerationConfig(
        thinking_budget=2048, thinking_summaries="auto", temperature=0.9
    )


def _message_text(message: dict[str, Any], prefix: str = "") -> str:
    content = message.get("content")
    if not isinstance(content, str):
        raise ValueError("Gemini message content must be a string")
    return prefix + content


def _messages(request: dict[str, Any]) -> list[dict[str, Any]]:
    messages = request.get("messages")
    if not isinstance(messages, list):
        raise ValueError("Gemini request is missing a messages array")
    for message in messages:
        if not isinstance(message, dict) or not isinstance(message.get("role"), str):
            raise ValueError("Gemini messages must be objects with string roles")
        _message_text(message)
    return messages


def _build_input(
    request: dict[str, Any],
) -> list[interactions.Content] | list[interactions.Step]:
    tool_history = request.get("tool_history")
    if tool_history is not None:
        if not isinstance(tool_history, list):
            raise ValueError("Gemini tool history must be an array")
        return STEP_ADAPTER.validate_python(tool_history)

    non_system = [
        message for message in _messages(request) if message["role"] != "system"
    ]
    if not non_system:
        raise ValueError("Gemini request requires a non-system message")
    parts: list[interactions.Content] = []
    for message in non_system:
        prefix = ""
        if len(non_system) > 1:
            prefix = "Assistant: " if message["role"] == "assistant" else "User: "
        parts.append(interactions.TextContent(text=_message_text(message, prefix)))

    images = request.get("images", [])
    files = request.get("files", [])
    if not isinstance(images, list) or not isinstance(files, list):
        raise ValueError("Gemini images and files must be arrays")

    for image in images:
        if not isinstance(image, dict):
            raise ValueError("Gemini image attachment must be an object")
        if not isinstance(image.get("data"), str) or not isinstance(
            image.get("mime_type"), str
        ):
            raise ValueError("Gemini image attachment requires string data and mime_type")
        parts.append(interactions.ImageContent.model_validate(image))

    for item in files:
        if not isinstance(item, dict):
            raise ValueError("Gemini file attachment must be an object")
        path = item.get("path")
        content = item.get("content")
        if not isinstance(path, str) or not isinstance(content, str):
            raise ValueError("Gemini file attachment requires string path and content")
        parts.append(interactions.TextContent(text=f"File: {path}\n\n{content}"))
    return parts


def _system_instruction(request: dict[str, Any]) -> str:
    parts = [
        _message_text(message)
        for message in _messages(request)
        if message["role"] == "system"
    ]
    parts.append(INSTRUCTIONS)
    return "\n\n".join(parts)


def build_payload(
    request: dict[str, Any],
    model: str,
    stream: bool,
    schema_name: str,
    schema: Any,
    tools: list[dict[str, Any]],
) -> dict[str, Any]:
    response_format = None
    if schema_name:
        if not isinstance(schema, dict):
            raise ValueError("Gemini response schema must be a JSON object")
        response_format = interactions.TextResponseFormat(
            mime_type="application/json", schema_=schema
        )
    payload = GeminiPayload(
        model=_validated_model(model),
        input=_build_input(request),
        system_instruction=_system_instruction(request),
        generation_config=_build_configs(model),
        stream=stream,
        store=False,
        tools=TOOL_ADAPTER.validate_python(tools),
        response_format=response_format,
    )
    result = payload.model_dump(mode="json", by_alias=True)
    # SDK open unions can accept malformed data as UNKNOWN or omit extra fields.
    # Never silently rewrite replayed steps (especially thought signatures).
    if request.get("tool_history") is not None and result["input"] != request["tool_history"]:
        raise ValueError("Gemini tool history cannot be serialized losslessly by the SDK")
    if result["tools"] != tools:
        raise ValueError("Gemini tools cannot be serialized losslessly by the SDK")
    return result


def _parse_bool(value: str) -> bool:
    if value not in ("true", "false"):
        _fail(f"Expected true or false, got {value!r}")
    return value == "true"


def _load_json(value: str, label: str) -> Any:
    try:
        return json.loads(value)
    except json.JSONDecodeError as error:
        _fail(f"Invalid {label}: {error}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Build a Gemini Interactions API payload.")
    parser.add_argument("request", type=Path, help="Request JSON written by ask.sh")
    parser.add_argument("--model", required=True)
    parser.add_argument("--stream", required=True)
    parser.add_argument("--schema-name", default="")
    parser.add_argument("--schema-json", default="null")
    parser.add_argument("--search", action="store_true")
    parser.add_argument("--tool", action="append", default=[])
    args = parser.parse_args()

    try:
        request = json.loads(args.request.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        _fail(f"Unable to read Gemini request {args.request}: {error}")
    if not isinstance(request, dict):
        _fail(f"Gemini request must be a JSON object: {args.request}")

    tools = [interactions.GoogleSearch().model_dump(by_alias=True)] if args.search else []
    tools.extend(_load_json(raw_tool, "tool definition") for raw_tool in args.tool)
    try:
        payload = build_payload(
            request,
            model=args.model,
            stream=_parse_bool(args.stream),
            schema_name=args.schema_name,
            schema=_load_json(args.schema_json, "schema"),
            tools=tools,
        )
    except ValidationError as error:
        details = "; ".join(
            f"{'.'.join(map(str, item['loc']))}: {item['msg']}"
            for item in error.errors(include_input=False, include_url=False)
        )
        _fail(f"Invalid Gemini payload: {details}")
    except ValueError as error:
        _fail(str(error))
    json.dump(payload, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
