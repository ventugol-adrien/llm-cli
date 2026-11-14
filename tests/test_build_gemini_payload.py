import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

from google.genai import interactions

from libexec.build_gemini_payload import (
    INSTRUCTIONS,
    _build_configs,
    _build_input,
    build_payload,
)

SCRIPT = Path(__file__).resolve().parents[1] / "libexec/build_gemini_payload.py"


class GeminiPayloadTests(unittest.TestCase):
    def setUp(self) -> None:
        self.request: dict[str, Any] = {
            "messages": [
                {"role": "system", "content": "System instructions"},
                {"role": "user", "content": 'Hello\n"world"'},
            ]
        }

    def payload(self, **options: Any) -> dict[str, Any]:
        return build_payload(
            self.request,
            model=options.get("model", "gemini-flash-latest"),
            stream=options.get("stream", True),
            schema_name=options.get("schema_name", ""),
            schema=options.get("schema"),
            tools=options.get("tools", []),
        )

    def test_sdk_types_and_default_payload(self) -> None:
        self.assertIsInstance(_build_configs("gemini-flash-latest"), interactions.GenerationConfig)
        self.assertIsInstance(_build_input(self.request)[0], interactions.TextContent)
        self.assertEqual(self.payload(), {
            "model": "gemini-flash-latest",
            "input": [{"type": "text", "text": 'Hello\n"world"'}],
            "system_instruction": f"System instructions\n\n{INSTRUCTIONS}",
            "generation_config": {"thinking_level": "high", "thinking_summaries": "auto"},
            "stream": True,
            "store": False,
            "tools": [],
        })

    def test_model_configs_survive_sdk_serialization(self) -> None:
        for model in ("gemini-2.5-flash", "gemini-custom"):
            with self.subTest(model=model):
                payload = self.payload(model=f"models/{model}", stream=False)
                self.assertEqual(payload["model"], model)
                self.assertIs(payload["stream"], False)
                self.assertEqual(payload["generation_config"], {
                    "temperature": 0.9, "thinking_budget": 2048, "thinking_summaries": "auto",
                })
        for model in ("gemini-3-flash-preview", "gemini-3.5-flash"):
            with self.subTest(model=model):
                self.assertEqual(self.payload(model=model)["generation_config"], {
                    "temperature": 0.9, "thinking_level": "high", "thinking_summaries": "auto",
                })
        for model in ("gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash", "gemini-4"):
            with self.subTest(model=model):
                self.assertEqual(self.payload(model=model)["generation_config"], {
                    "thinking_level": "high", "thinking_summaries": "auto",
                })

    def test_history_attachments_and_multiple_system_messages(self) -> None:
        self.request["messages"].extend([
            {"role": "assistant", "content": "Hi"},
            {"role": "system", "content": "More instructions"},
            {"role": "user", "content": "Again"},
        ])
        image_data = "YWJj" * 700_000
        self.request["images"] = [{"mime_type": "image/png", "data": image_data}]
        self.request["files"] = [{"path": "notes.txt", "content": 'Text\n"quoted"'}]
        payload = self.payload()
        self.assertEqual(payload["input"], [
            {"type": "text", "text": 'User: Hello\n"world"'},
            {"type": "text", "text": "Assistant: Hi"},
            {"type": "text", "text": "User: Again"},
            {"type": "image", "mime_type": "image/png", "data": image_data},
            {"type": "text", "text": 'File: notes.txt\n\nText\n"quoted"'},
        ])
        self.assertEqual(
            payload["system_instruction"],
            f"System instructions\n\nMore instructions\n\n{INSTRUCTIONS}",
        )

    def test_schema_aliases_and_tools(self) -> None:
        schema = {"type": "object", "properties": {"x": {"type": "null", "default": None}}}
        tools = [
            {"type": "google_search"},
            {"type": "function", "name": "read", "description": "Read files", "parameters": schema},
        ]
        payload = self.payload(schema_name="example", schema=schema, tools=tools)
        self.assertEqual(payload["response_format"], {
            "type": "text", "mime_type": "application/json", "schema": schema,
        })
        self.assertEqual(payload["tools"], tools)
        self.assertNotIn("schema_", payload["response_format"])

    def test_tool_replay_is_lossless_and_does_not_duplicate_attachments(self) -> None:
        history = [
            {"type": "user_input", "content": [{"type": "text", "text": "Read"}]},
            {"type": "thought", "signature": "opaque-signature", "summary": []},
            {"type": "function_call", "name": "read", "id": "call1", "arguments": {"x": None}},
            {"type": "function_result", "name": "read", "call_id": "call1",
             "result": [{"type": "text", "text": "Done"}]},
            {"type": "model_output", "content": [{"type": "text", "text": "Answer",
             "annotations": [{"type": "url_citation", "url": "https://example.test", "title": "Source"}]}]},
        ]
        self.request["tool_history"] = history
        self.request["images"] = [{"mime_type": "image/png", "data": "YWJj"}]
        original = copy.deepcopy(self.request)
        self.assertEqual(self.payload()["input"], history)
        self.assertEqual(self.request, original)
        self.request["tool_history"] = []
        self.assertEqual(self.payload()["input"], [])

    def test_sdk_rejects_lossy_or_malformed_history_and_tools(self) -> None:
        for history in (
            [{"type": "function_call", "name": "read"}],
            [{"type": "future_step", "value": 1}],
            [{"type": "thought", "signature": "opaque", "future_metadata": True}],
        ):
            with self.subTest(history=history):
                self.request["tool_history"] = history
                with self.assertRaises(ValueError):
                    self.payload()
        del self.request["tool_history"]
        for tools in ([{"type": "unknown"}], [None], [{"type": "function", "name": 5}]):
            with self.subTest(tools=tools), self.assertRaises(ValueError):
                self.payload(tools=tools)

    def test_invalid_input_fails(self) -> None:
        for model in ("bad/model", "", "models/", "gemini-flash-latest\n"):
            with self.subTest(model=model), self.assertRaises(ValueError):
                self.payload(model=model)
        for request in (
            {}, {"messages": []}, {"messages": [None]},
            {"messages": [{"role": "user", "content": None}]},
            {**self.request, "images": {}}, {**self.request, "files": ""},
            {**self.request, "tool_history": {}},
        ):
            with self.subTest(request=request), self.assertRaises(ValueError):
                build_payload(request, "gemini-flash-latest", True, "", None, [])

    def test_cli_output_and_errors(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "request.json"
            path.write_text(json.dumps(self.request), encoding="utf-8")
            command = [sys.executable, str(SCRIPT), str(path),
                       "--model", "gemini-flash-latest", "--stream", "false"]
            result = subprocess.run(command + ["--search"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), self.payload(
                stream=False, tools=[{"type": "google_search"}],
            ))
            for options in (
                ["--stream", "invalid"],
                ["--schema-name", "example", "--schema-json", "null"],
                ["--tool", "{"],
                ["--tool", '{"type":"function","name":5}'],
            ):
                with self.subTest(options=options):
                    result = subprocess.run(command + options, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                    self.assertTrue(result.stderr)
                    self.assertNotIn("Traceback", result.stderr)
            path.write_text("{", encoding="utf-8")
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("Unable to read Gemini request", result.stderr)


if __name__ == "__main__":
    unittest.main()
