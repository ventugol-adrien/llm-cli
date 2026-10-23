#!/usr/bin/env python3

import argparse
import sys
from pathlib import Path

import yaml
from jinja2 import FileSystemLoader, StrictUndefined, TemplateError
from jinja2.sandbox import SandboxedEnvironment


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Render a YAML template with values from a YAML mapping."
    )
    parser.add_argument("template", type=Path, help="Jinja2 YAML template path")
    parser.add_argument("yaml", type=Path, help="YAML data path")
    args = parser.parse_args()

    try:
        data = yaml.safe_load(args.yaml.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, yaml.YAMLError) as error:
        print(f"Unable to read YAML data {args.yaml}: {error}", file=sys.stderr)
        return 1
    if not isinstance(data, dict):
        print(f"YAML data must contain a mapping: {args.yaml}", file=sys.stderr)
        return 1

    try:
        environment = SandboxedEnvironment(
            loader=FileSystemLoader(str(args.template.parent)),
            undefined=StrictUndefined,
            autoescape=False,
            trim_blocks=True,
            lstrip_blocks=True,
        )
        template = environment.get_template(args.template.name)
        rendered = template.render(**data)
        yaml.safe_load(rendered)
    except (OSError, TemplateError, yaml.YAMLError) as error:
        print(f"Unable to render YAML template {args.template}: {error}", file=sys.stderr)
        return 1

    sys.stdout.write(rendered)
    if not rendered.endswith("\n"):
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
