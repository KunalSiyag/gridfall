"""Workflow and config hygiene: YAML parses, workflows are well formed, actions are pinned.

usage: python3 tools/checks/workflows.py [-v]

For .github/**/*.yml|yaml and .pre-commit-config.yaml: valid YAML. For .github/workflows/*: a
`name`, triggers, jobs that each have `runs-on` (or a reusable `uses`) and `timeout-minutes`,
and every `uses:` pinned to a version tag or commit (never a branch such as @main). The pins in
.pre-commit-config.yaml additional_dependencies must match tools/requirements-dev.txt. Runs
actionlint as well when it is installed (tools/requirements-dev.txt ships actionlint-py).
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "workflows"
PIN_RE = re.compile(r"^[\w.-]+/[\w./-]+@(v\d+(\.\d+)*|[0-9a-f]{40})$")


def actionlint_cmd() -> list[str] | None:
    local = Path(sys.executable).parent / "actionlint"
    if local.exists():
        return [str(local)]
    found = shutil.which("actionlint")
    return [found] if found else None


def _uses(node) -> list[str]:
    out = []
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "uses" and isinstance(v, str):
                out.append(v)
            else:
                out += _uses(v)
    elif isinstance(node, list):
        for v in node:
            out += _uses(v)
    return out


def hook_pin_drift(root: Path, yaml) -> list[str]:
    """pre-commit additional_dependencies pins that differ from tools/requirements-dev.txt."""
    cfg_path = root / ".pre-commit-config.yaml"
    req_path = root / "tools/requirements-dev.txt"
    if not cfg_path.is_file() or not req_path.is_file():
        return []
    pins = {}
    for line in req_path.read_text(encoding="utf-8").split("\n"):
        line = line.split("#", 1)[0].strip()
        if "==" in line:
            name, ver = line.split("==", 1)
            pins[re.sub(r"[-_.]+", "-", name).lower()] = ver.strip()
    try:
        cfg = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError:
        return []
    out = []
    for repo in cfg.get("repos", []):
        for hook in repo.get("hooks", []):
            for dep in hook.get("additional_dependencies", []) or []:
                if "==" not in dep:
                    out.append(f".pre-commit-config.yaml: hook {hook.get('id')} dependency {dep} is not pinned")
                    continue
                name, ver = dep.split("==", 1)
                want = pins.get(re.sub(r"[-_.]+", "-", name).lower())
                if want is not None and want != ver:
                    out.append(f".pre-commit-config.yaml: hook {hook.get('id')} pins {dep}, tools/requirements-dev.txt has {want}")
    return out


def run(root: Path, use_actionlint: bool = True) -> common.Result:
    res = common.Result(NAME)
    try:
        import yaml
    except ImportError:
        res.skipped = "PyYAML is not installed (pip install -r tools/requirements-dev.txt)"
        return res
    files = [
        f
        for f in common.list_files(root, ("*.yml", "*.yaml"))
        if f.startswith(".github/") or f in (".pre-commit-config.yaml",)
    ]
    workflows = []
    for f in files:
        try:
            data = yaml.safe_load(common.read_text(root, f))
        except yaml.YAMLError as e:
            res.new.append(f"{f}: invalid YAML: {str(e).splitlines()[0]}")
            continue
        if f.startswith(".github/workflows/"):
            workflows.append(f)
            if not isinstance(data, dict):
                res.new.append(f"{f}: not a mapping")
                continue
            # PyYAML reads the bare key `on` as True.
            triggers = data.get("on", data.get(True))
            if not data.get("name"):
                res.new.append(f"{f}: no workflow name")
            if not triggers:
                res.new.append(f"{f}: no `on:` triggers")
            jobs = data.get("jobs") or {}
            if not jobs:
                res.new.append(f"{f}: no jobs")
            for jid, job in jobs.items():
                if not isinstance(job, dict):
                    res.new.append(f"{f}: job {jid} is not a mapping")
                    continue
                if "uses" not in job and "runs-on" not in job:
                    res.new.append(f"{f}: job {jid} has no runs-on")
                if "uses" not in job and "timeout-minutes" not in job:
                    res.new.append(f"{f}: job {jid} has no timeout-minutes")
            for u in _uses(data):
                if u.startswith(("./", "docker://")):
                    continue
                if not PIN_RE.match(u):
                    res.new.append(f"{f}: `uses: {u}` is not pinned to a version tag or commit")
        res.known.append(f)
    res.new += hook_pin_drift(root, yaml)
    cmd = actionlint_cmd() if use_actionlint else None
    if cmd and workflows:
        p = subprocess.run(cmd + ["-no-color", *workflows], cwd=root, capture_output=True, text=True)
        if p.returncode != 0:
            for line in (p.stdout + p.stderr).splitlines():
                if re.match(r"^\S+:\d+:\d+: ", line):
                    res.new.append(f"actionlint: {line}")
            if not res.new:
                res.new.append(f"actionlint failed: {(p.stdout + p.stderr).strip()[:300]}")
    elif workflows:
        res.warnings.append("actionlint not installed; only YAML structure was checked")
    res.stats = {"yaml_files": len(files), "workflows": len(workflows), "actionlint": bool(cmd)}
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--no-actionlint", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    return common.report(run(Path(a.root), not a.no_actionlint), a.verbose)


if __name__ == "__main__":
    sys.exit(main())
