#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parent.parent
INDEXES = [
    ROOT / "README.md",
    ROOT / "doc" / "README.md",
    ROOT / "doc" / "src" / "README.md",
    ROOT / "plan" / "README.md",
]
LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")


def iter_markdown_files() -> list[Path]:
    ignored = {".build", ".git", ".swiftpm", ".onereader", "dist"}
    return sorted(
        path
        for path in ROOT.rglob("*.md")
        if not ignored.intersection(path.relative_to(ROOT).parts)
    )


def validate_links(path: Path) -> list[str]:
    errors: list[str] = []
    content = path.read_text(encoding="utf-8")
    for raw_target in LINK_RE.findall(content):
        target = raw_target.split("#", 1)[0].strip()
        if not target or "://" in target or target.startswith("mailto:"):
            continue
        resolved = (path.parent / unquote(target)).resolve()
        try:
            resolved.relative_to(ROOT.resolve())
        except ValueError:
            errors.append(f"{path.relative_to(ROOT)}: link escapes repository: {raw_target}")
            continue
        if not resolved.exists():
            errors.append(f"{path.relative_to(ROOT)}: missing link target: {raw_target}")
    return errors


def validate_index_coverage(files: list[Path]) -> list[str]:
    errors: list[str] = []
    indexed_text = "\n".join(path.read_text(encoding="utf-8") for path in INDEXES)
    required = [
        path
        for path in files
        if (
            path.parent == ROOT / "doc"
            or path.parent == ROOT / "plan"
            or path.parent == ROOT / "doc" / "src"
        )
        and path.name != "README.md"
    ]
    for path in required:
        if path.name not in indexed_text:
            errors.append(f"{path.relative_to(ROOT)}: not referenced by a top-level index")
    return errors


def main() -> int:
    missing_indexes = [path for path in INDEXES if not path.exists()]
    if missing_indexes:
        for path in missing_indexes:
            print(f"missing required index: {path.relative_to(ROOT)}", file=sys.stderr)
        return 1

    files = iter_markdown_files()
    errors: list[str] = []
    for path in files:
        errors.extend(validate_links(path))
    errors.extend(validate_index_coverage(files))

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print(f"documentation index validation passed ({len(files)} Markdown files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

