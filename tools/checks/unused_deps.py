"""Dependency hygiene: every requirement is pinned exactly and actually used.

usage: python3 tools/checks/unused_deps.py [-v]

For each tools/requirements*.txt entry: it must be pinned with `==`, and it must be used: some
Python file imports one of its modules, or (for command-line tools and plugins) its command or
plugin name appears in a config, workflow, hook or shell script. Also warns about third-party
imports that no requirements file declares (Blender's bpy/bmesh/mathutils and ACE-Step's own
environment are expected and listed in EXTERNAL).
"""
from __future__ import annotations

import argparse
import ast
import re
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "unused_deps"
REQ_GLOB = "tools/requirements*.txt"
# distribution -> (import names, command/plugin words looked up in configs and scripts)
KNOWN = {
    "gdtoolkit": (["gdtoolkit"], ["gdlint", "gdformat", "gdradon", "gdparse"]),
    "pre-commit": (["pre_commit"], ["pre-commit"]),
    "pytest": (["pytest"], ["pytest"]),
    "pytest-cov": (["pytest_cov"], ["--cov", "pytest-cov"]),
    "pyyaml": (["yaml"], []),
    "pillow": (["PIL"], []),
    "numpy": (["numpy"], []),
    "scipy": (["scipy"], []),
    "aiohttp": (["aiohttp"], []),
    "actionlint-py": (["actionlint"], ["actionlint"]),
    "coverage": (["coverage"], ["coverage"]),
}
# Provided by the program that runs the script, never pip-installed into the tools venv.
EXTERNAL = {"bpy", "bmesh", "mathutils", "bpy_extras", "gpu", "acestep", "loguru", "torch"}
CONFIG_PATTERNS = (
    "*.yml", "*.yaml", "*.toml", "*.ini", "*.cfg", "*.sh", "Dockerfile", "*.json", ".pre-commit-config.yaml",
)
REQ_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]*\])?\s*(==|>=|<=|~=|!=|>|<)?\s*([^\s;#]*)")


def canonical(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def parse_requirements(text: str) -> list[tuple[str, str, str, int]]:
    """(name, operator, version, line) for each requirement line (options and comments skipped)."""
    out = []
    for i, raw in enumerate(text.split("\n"), 1):
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("-"):
            continue
        m = REQ_RE.match(line)
        if m:
            out.append((m.group(1), m.group(3) or "", m.group(4) or "", i))
    return out


def imported_modules(src: str) -> set[str]:
    """Top-level module names a Python file imports (including imports inside functions)."""
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return set(re.findall(r"^\s*(?:from|import)\s+([A-Za-z_]\w*)", src, re.M))
    mods = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            mods.update(a.name.split(".")[0] for a in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            mods.add(node.module.split(".")[0])
    return mods


def run(root: Path) -> common.Result:
    res = common.Result(NAME)
    req_files = [f for f in common.list_files(root, ("*.txt",)) if common.matches(f, [REQ_GLOB])]
    if not req_files:
        res.skipped = f"no {REQ_GLOB}"
        return res
    py_files = common.list_files(root, ("*.py",))
    local = {Path(f).stem for f in py_files} | {Path(f).parent.name for f in py_files}
    imports: dict[str, set[str]] = {}
    for f in py_files:
        for mod in imported_modules(common.read_text(root, f)):
            imports.setdefault(mod, set()).add(f)
    config_text = "\n".join(
        common.read_text(root, f)
        for f in common.list_files(root, CONFIG_PATTERNS)
        if not f.startswith("tools/checks/baselines/") and not common.matches(f, [REQ_GLOB])
    )
    declared: set[str] = set()
    for rf in req_files:
        for name, op, ver, line in parse_requirements(common.read_text(root, rf)):
            canon = canonical(name)
            declared.add(canon)
            where = f"{rf}:{line} {name}"
            if op != "==" or not ver:
                res.new.append(f"{where} is not pinned exactly (use {name}==<version>)")
            mods, words = KNOWN.get(canon, ([name.replace("-", "_")], [name]))
            users = sorted({u for m in mods for u in imports.get(m, ())})
            word_hit = [w for w in words if re.search(r"(?<![\w-])" + re.escape(w) + r"(?![\w])", config_text)]
            if users or word_hit:
                res.known.append(f"{where}: " + (", ".join(users[:3]) if users else "used as " + word_hit[0]))
            else:
                res.new.append(f"{where} is never imported or invoked (remove it)")
    module_to_dist = {m: d for d, (ms, _) in KNOWN.items() for m in ms}
    stdlib = set(sys.stdlib_module_names)
    for mod, users in sorted(imports.items()):
        if mod in stdlib or mod in local or mod in EXTERNAL or mod == "tools" or mod == "__future__":
            continue
        dist = module_to_dist.get(mod, canonical(mod))
        if dist not in declared:
            res.warnings.append(f"{mod} is imported by {', '.join(sorted(users)[:3])} but not in any {REQ_GLOB}")
    res.stats = {"requirement_files": req_files, "requirements": len(declared)}
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    return common.report(run(Path(a.root)), a.verbose)


if __name__ == "__main__":
    sys.exit(main())
