#!/usr/bin/env python3
"""Write the workflow-provided version into pubspec.yaml."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def parse(raw: str) -> tuple[str, int]:
    v = raw.strip().lstrip("vV")
    if not re.fullmatch(r"\d+\.\d+\.\d+", v):
        raise SystemExit(
            f"Invalid version '{raw}'. Use semantic version like 1.0.0"
        )
    major, minor, patch = (int(p) for p in v.split("."))
    for part, name in ((minor, "minor"), (patch, "patch")):
        if part >= 100:
            raise SystemExit(
                f"{name} version component {part} >= 100 would collide with "
                "the next component in the numeric version code; bump the "
                "major version instead"
            )
    code = major * 10000 + minor * 100 + patch
    if code < 1:
        code = 1
    return v, code


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: stamp_version.py 1.2.3")
    version, code = parse(sys.argv[1])
    pubspec = ROOT / "pubspec.yaml"
    text = pubspec.read_text(encoding="utf-8")
    text = re.sub(r"^version:.*$", f"version: {version}+{code}", text, count=1, flags=re.M)
    pubspec.write_text(text, encoding="utf-8")
    print(f"stamped version {version} code {code}")


if __name__ == "__main__":
    main()
