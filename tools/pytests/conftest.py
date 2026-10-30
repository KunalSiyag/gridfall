"""Fixtures for the tools/checks tests: throwaway repos built from a {path: content} map."""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

# Pre-commit exports GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE while a push hook runs pytest;
# left set, they redirect the fixtures' throwaway-repo git calls at the outer repository.
for _git_key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
    os.environ.pop(_git_key, None)


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
            # Index only: no commits, so no identity is needed. Scrub the repo-locating vars
            # (pre-push sets GIT_DIR/GIT_WORK_TREE): they would redirect these calls at the
            # developer's real repository.
            from tools.checks.common import git_env

            subprocess.run(["git", "init", "-q", str(root)], check=True, env=git_env())
            subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, env=git_env())
        return root

    return build
