#!/usr/bin/env python3
"""Fail when the standalone desktop and mobile Remote wire contracts diverge."""

import argparse
from pathlib import Path
import sys


def compare(local: Path, desktop: Path, pattern: str) -> list[str]:
    if not desktop.is_dir():
        return [f"Missing desktop contract directory: {desktop}"]
    local_files = {path.relative_to(local): path for path in local.rglob(pattern)}
    desktop_files = {path.relative_to(desktop): path for path in desktop.rglob(pattern)}
    errors = []
    for name in sorted(local_files.keys() | desktop_files.keys()):
        if name not in local_files:
            errors.append(f"Missing from iOS: {name}")
        elif name not in desktop_files:
            errors.append(f"Missing from desktop: {name}")
        elif local_files[name].read_bytes() != desktop_files[name].read_bytes():
            errors.append(f"Contract differs: {name}")
    if not local_files:
        errors.append(f"Missing iOS contract files: {local}")
    return errors


def main() -> int:
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "desktop", nargs="?", type=Path, default=repo.parent / "repoprompt-ce",
        help="Desktop checkout (default: sibling repoprompt-ce)",
    )
    args = parser.parse_args()
    protocol = repo / "Packages/RepoPromptRemoteProtocol"
    errors = compare(
        protocol / "Sources/RepoPromptRemoteProtocol",
        args.desktop / "Sources/RepoPromptRemoteProtocol",
        "*.swift",
    )
    errors += compare(
        protocol / "Tests/RepoPromptRemoteProtocolTests/Fixtures",
        args.desktop / "Tests/RepoPromptRemoteProtocolTests/Fixtures",
        "*.json",
    )
    if errors:
        print("Remote compatibility check failed:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1
    print("Desktop and iOS Remote protocol sources and fixtures match.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
