"""Fixtures for the tools/checks tests: throwaway repos built from a {path: content} map."""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest


def write_tree(root: Path, files: dict) -> Path:
    for rel, content in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            p.write_bytes(content)
        else:
            p.write_text(content, encoding="utf-8")
    return root


@pytest.fixture
def repo(tmp_path):
    """Returns a builder: repo({path: text}) -> root (plain directory, no git)."""

    def build(files: dict, git: bool = False) -> Path:
        root = tmp_path / "repo"
        root.mkdir(exist_ok=True)
        write_tree(root, files)
        if git:
            # Index only: no commits, so no identity is needed.
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
        return root

    return build
