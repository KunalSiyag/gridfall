"""Shared helpers for the GridFall ops report tools: locating the Godot user data directory and
reading the JSON-lines files written by scripts/ops/ops_sink.gd."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Iterator

REPO_ROOT = Path(__file__).resolve().parents[2]
# Characters Godot's OS::get_safe_dir_name() replaces with "_" in the app user dir name.
_UNSAFE = re.compile(r'[:*?"<>|/\\]')


def read_project_settings(project_file: Path) -> dict[str, str]:
    """Flat {"section/key": raw value} map of a project.godot file (values keep their quotes)."""
    out: dict[str, str] = {}
    section = ""
    if not project_file.is_file():
        return out
    for line in project_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            out[f"{section}/{key.strip()}" if section else key.strip()] = value.strip()
    return out


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1].replace('\\"', '"')
    return value


def user_data_dir(project_file: Path | None = None, env: dict[str, str] | None = None) -> Path:
    """Godot's user:// directory for this project on Linux (honours XDG_DATA_HOME and
    application/config/use_custom_user_dir)."""
    env = dict(os.environ) if env is None else env
    settings = read_project_settings(project_file or REPO_ROOT / "project.godot")
    base = Path(env.get("XDG_DATA_HOME") or Path(env.get("HOME", str(Path.home()))) / ".local" / "share")
    name = _UNSAFE.sub("_", _unquote(settings.get("application/config/name", ""))).strip() or "[unnamed project]"
    if _unquote(settings.get("application/config/use_custom_user_dir", "false")) == "true":
        custom = _UNSAFE.sub("_", _unquote(settings.get("application/config/custom_user_dir_name", ""))).strip()
        return base / (custom or name)
    return base / "godot" / "app_userdata" / name


def default_ops_file(file_name: str, env: dict[str, str] | None = None) -> Path:
    """user://ops/<file_name> for this project."""
    return user_data_dir(env=env) / "ops" / file_name


def iter_jsonl(path: Path, include_rotated: bool = True) -> Iterator[dict]:
    """Records of path (and its rotated <name>.1.jsonl first, when present); bad lines are skipped."""
    paths = []
    rotated = path.with_name(path.stem + ".1" + path.suffix)
    if include_rotated and rotated.is_file():
        paths.append(rotated)
    if path.is_file():
        paths.append(path)
    for p in paths:
        with p.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(rec, dict):
                    yield rec
