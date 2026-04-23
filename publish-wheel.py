#!/usr/bin/env python3
"""Publish a built wheel into this repo's PEP 503 "simple" index.

Stdlib-only. Usage:

    publish-wheel.py --wheel path/to/pkg-1.2.3-py3-none-any.whl

Resolves paths relative to this file, so it works no matter the CWD.
Refuses to overwrite an existing wheel (versions are immutable once
published). Does not git-commit — the caller handles git.
"""

from __future__ import annotations

import argparse
import html
import re
import shutil
import sys
from pathlib import Path


SIMPLE_DIR = Path(__file__).resolve().parent / "simple"


def normalize(name: str) -> str:
    """PEP 503 normalisation: runs of [-_.] collapse to single '-', lowercase."""
    return re.sub(r"[-_.]+", "-", name).lower()


def parse_wheel_filename(filename: str) -> tuple[str, str]:
    """Return (raw_name, version) from a wheel filename."""
    m = re.match(r"^([^-]+)-([^-]+)-", filename)
    if not m:
        sys.exit(f"Not a recognisable wheel filename: {filename}")
    return m.group(1), m.group(2)


def write_package_index(pkg_dir: Path) -> None:
    wheels = sorted(p.name for p in pkg_dir.iterdir() if p.suffix == ".whl")
    lines = [
        "<!DOCTYPE html>",
        "<html><head><meta name='pypi:repository-version' content='1.0'>",
        f"<title>Links for {pkg_dir.name}</title></head><body>",
        f"<h1>Links for {pkg_dir.name}</h1>",
    ]
    for w in wheels:
        lines.append(f'<a href="{html.escape(w)}">{html.escape(w)}</a><br>')
    lines.append("</body></html>\n")
    (pkg_dir / "index.html").write_text("\n".join(lines))


def write_root_index() -> None:
    pkgs = sorted(p.name for p in SIMPLE_DIR.iterdir() if p.is_dir())
    lines = [
        "<!DOCTYPE html>",
        "<html><head><meta name='pypi:repository-version' content='1.0'>",
        "<title>Simple index</title></head><body>",
        "<h1>Simple index</h1>",
    ]
    for p in pkgs:
        lines.append(f'<a href="{html.escape(p)}/">{html.escape(p)}</a><br>')
    lines.append("</body></html>\n")
    (SIMPLE_DIR / "index.html").write_text("\n".join(lines))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--wheel", required=True, type=Path)
    args = ap.parse_args()

    wheel: Path = args.wheel
    if not wheel.is_file():
        sys.exit(f"Not a file: {wheel}")
    if wheel.suffix != ".whl":
        sys.exit(f"Not a wheel: {wheel}")

    raw_name, version = parse_wheel_filename(wheel.name)
    pkg_name = normalize(raw_name)
    pkg_dir = SIMPLE_DIR / pkg_name
    pkg_dir.mkdir(parents=True, exist_ok=True)

    target = pkg_dir / wheel.name
    if target.exists():
        sys.exit(
            f"Refusing to overwrite existing wheel: {target.relative_to(SIMPLE_DIR.parent)} "
            f"(version {version} already published — wheels are immutable)"
        )

    shutil.copy2(wheel, target)
    write_package_index(pkg_dir)
    write_root_index()

    print(f"Published {pkg_name}=={version} -> {target.relative_to(SIMPLE_DIR.parent)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
