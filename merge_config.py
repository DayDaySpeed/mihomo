#!/usr/bin/env python3
"""Merge ssrdog.yaml (public) with secrets.yaml (private) into a single Mihomo config."""

from __future__ import annotations

import sys
from pathlib import Path

import yaml


def deep_merge(base: dict, overlay: dict) -> dict:
    result = dict(base)
    for key, value in overlay.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def merge_configs(base_path: Path, secrets_path: Path) -> dict:
    with base_path.open(encoding="utf-8") as f:
        base = yaml.safe_load(f) or {}
    with secrets_path.open(encoding="utf-8") as f:
        secrets = yaml.safe_load(f) or {}

    prepend_rules = secrets.pop("prepend-rules", None) or []
    merged = deep_merge(base, secrets)

    if prepend_rules:
        rules = list(merged.get("rules") or [])
        insert_at = min(1, len(rules))
        merged["rules"] = rules[:insert_at] + list(prepend_rules) + rules[insert_at:]

    return merged


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print(f"usage: {sys.argv[0]} <base.yaml> <secrets.yaml> [output.yaml]", file=sys.stderr)
        return 1

    base_path = Path(sys.argv[1])
    secrets_path = Path(sys.argv[2])
    output_path = Path(sys.argv[3]) if len(sys.argv) == 4 else None

    if not base_path.is_file():
        print(f"error: base config not found: {base_path}", file=sys.stderr)
        return 1

    if not secrets_path.is_file():
        print(f"error: secrets file not found: {secrets_path}", file=sys.stderr)
        print(f"hint: cp secrets.yaml.example {secrets_path} and fill in your values", file=sys.stderr)
        return 1

    merged = merge_configs(base_path, secrets_path)
    text = yaml.dump(merged, allow_unicode=True, default_flow_style=False, sort_keys=False)

    if output_path:
        output_path.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
