import json

import pytest

from tools.checks import common, feature_flags, run_all, unused_deps, workflows

REGISTRY = 'const FEATURES := [\n\t{"id": "chat", "path": "res://scripts/fp/chat/fp_chat.gd"},\n]\n'


def test_feature_flags(repo, capsys):
    flags = {"_comment": "meta", "flags": {"chat": {"default": True}, "used": {}, "stale": {}}}
    root = repo(
        {
            "data/feature_flags.json": json.dumps(flags),
            "scripts/fp/fp_features.gd": REGISTRY,
            "scripts/a.gd": (
                'if FeatureFlags.enabled("used"):\n\tpass\n'
                "if FeatureFlags.enabled(&'missing'): pass\n"
                '# FeatureFlags.enabled("stale") in a comment does not count\n'
            ),
            "tools/tests/t.gd": 'FeatureFlags.enabled("unknown_probe")\n',
        }
    )
    res = feature_flags.run(root)
    assert sorted(res.new) == [
        'FeatureFlags.enabled("missing") at scripts/a.gd:3 has no entry in data/feature_flags.json',
        "flag stale is defined in data/feature_flags.json but never read (remove it or use it)",
    ]
    assert res.known == ["used: scripts/a.gd:1"]
    assert res.stats == {"flags": 3, "read_in_code": 1, "feature_ids": 1}
    assert feature_flags.main(["--root", str(root)]) == 1
    assert feature_flags.flag_names({"a": 1, "$schema": "x"}) == ["a"]
    assert feature_flags.flag_names([1]) == []
    (root / "data/feature_flags.json").write_text("{bad")
    assert "invalid JSON" in feature_flags.run(root).new[0]
    (root / "data/feature_flags.json").unlink()
    assert feature_flags.run(root).skipped


def test_unused_deps(repo, tmp_path):
    root = repo(
        {
            "tools/requirements.txt": "# comment\n-r other.txt\nnumpy==1.0\nloose>=2\nunused-lib==3.0\nPillow[extra]==1.0\n",
            "tools/requirements-dev.txt": "pytest==8.0\ngdtoolkit==4.0\n",
            "tools/a.py": "import numpy\nfrom PIL import Image\nimport bpy\nimport requests\nfrom . import sibling\n",
            "tools/b.py": "def f(:\nimport scipy\n",
            "tools/run.sh": "gdlint scripts\n",
            "pyproject.toml": "[tool.pytest.ini_options]\n",
        }
    )
    res = unused_deps.run(root)
    assert sorted(res.new) == [
        "tools/requirements.txt:4 loose is never imported or invoked (remove it)",
        "tools/requirements.txt:4 loose is not pinned exactly (use loose==<version>)",
        "tools/requirements.txt:5 unused-lib is never imported or invoked (remove it)",
    ]
    known = "\n".join(res.known)
    assert "numpy: tools/a.py" in known and "gdtoolkit: used as gdlint" in known and "pytest: used as pytest" in known
    warned = " ".join(res.warnings)
    assert "requests is imported" in warned and "scipy is imported" in warned and "bpy" not in warned
    assert unused_deps.parse_requirements("x == 1 ; python_version>'3'\n") == [("x", "==", "1", 1)]
    assert unused_deps.canonical("Py_YAML.x") == "py-yaml-x"
    assert unused_deps.main(["--root", str(root)]) == 1
    empty = tmp_path / "empty"
    empty.mkdir()
    assert unused_deps.run(empty).skipped


GOOD = """name: ci
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v7
      - uses: ./.github/actions/local
      - uses: docker://alpine:3
      - uses: owner/repo/path@0123456789abcdef0123456789abcdef01234567
  reuse:
    uses: ./.github/workflows/other.yml
"""
BAD = """on: {}
jobs:
  a:
    steps:
      - uses: actions/checkout@main
  b: 3
"""


def wf_repo(repo, extra=None):
    files = {
        ".github/workflows/good.yml": GOOD,
        ".github/dependabot.yml": "version: 2\n",
        ".pre-commit-config.yaml": (
            "repos:\n- repo: local\n  hooks:\n  - id: gdlint\n    additional_dependencies: [gdtoolkit==4.0, loose]\n"
        ),
        "tools/requirements-dev.txt": "gdtoolkit==4.5  # pinned\n",
        "other.yml": "not: [checked\n",
    }
    files.update(extra or {})
    return repo(files)


def test_workflows_structure_pins_and_drift(repo):
    root = wf_repo(repo, {".github/workflows/bad.yml": BAD, ".github/workflows/list.yml": "- 1\n", ".github/x.yml": "a: [b\n"})
    res = workflows.run(root, use_actionlint=False)
    new = "\n".join(res.new)
    for want in [
        "bad.yml: no workflow name",
        "bad.yml: no `on:` triggers",
        "bad.yml: job a has no runs-on",
        "bad.yml: job a has no timeout-minutes",
        "bad.yml: job b is not a mapping",
        "`uses: actions/checkout@main` is not pinned",
        "list.yml: not a mapping",
        ".github/x.yml: invalid YAML",
        "hook gdlint pins gdtoolkit==4.0, tools/requirements-dev.txt has 4.5",
        "hook gdlint dependency loose is not pinned",
    ]:
        assert want in new, want
    assert "good.yml" not in new and "other.yml" not in new
    assert "actionlint not installed" in res.warnings[0]
    root2 = wf_repo(repo, {".github/workflows/bad.yml": "name: x\non: push\njobs: {}\n"})
    assert any("no jobs" in n for n in workflows.run(root2, use_actionlint=False).new)


def test_workflows_actionlint(repo, monkeypatch, tmp_path):
    if workflows.actionlint_cmd() is None:
        pytest.skip("actionlint is not installed")
    root = wf_repo(repo)
    (root / ".pre-commit-config.yaml").write_text("repos: []\n")
    assert workflows.run(root).ok
    (root / ".github/workflows/good.yml").write_text(GOOD.replace("runs-on: ubuntu-latest", "runs-on: ${{ bogus.x }}"))
    res = workflows.run(root)
    assert any(n.startswith("actionlint: ") for n in res.new)
    fake = tmp_path / "fake_actionlint"
    fake.write_text("#!/bin/sh\necho broken >&2\nexit 2\n")
    fake.chmod(0o755)
    monkeypatch.setattr(workflows, "actionlint_cmd", lambda: [str(fake)])
    (root / ".github/workflows/good.yml").write_text(GOOD)
    assert workflows.run(root).new == ["actionlint failed: broken"]
    assert workflows.main(["--root", str(root), "--no-actionlint"]) == 0


def test_workflows_without_yaml(monkeypatch, repo):
    import builtins

    real = builtins.__import__

    def fake_import(name, *a, **k):
        if name == "yaml":
            raise ImportError(name)
        return real(name, *a, **k)

    monkeypatch.setattr(builtins, "__import__", fake_import)
    assert workflows.run(repo({})).skipped


def test_hook_pin_drift_edge_cases(repo, tmp_path):
    import yaml

    root = repo({".pre-commit-config.yaml": "a: [b\n", "tools/requirements-dev.txt": "x==1\n"})
    assert workflows.hook_pin_drift(root, yaml) == []
    assert workflows.hook_pin_drift(tmp_path, yaml) == []


def test_run_all_selection_outputs_and_crash(repo, monkeypatch, tmp_path, capsys):
    root = repo({"a.gd": "# TO" + "DO: x\n", "tools/checks/boundaries.json": "{}"})
    out_json = tmp_path / "o/r.json"
    summary = tmp_path / "s.md"
    debt = tmp_path / "debt.md"
    rc = run_all.main(
        [
            "--root", str(root), "--only", "todo_scan,large_files,boundaries",
            "--json", str(out_json), "--summary", str(summary), "--debt-report", str(debt),
        ]
    )
    assert rc == 1
    out = capsys.readouterr().out
    assert "CHECKS: FAIL (1 failed)" in out and "todo_scan        | FAIL" in out
    data = json.loads(out_json.read_text())
    assert set(data["checks"]) == {"todo_scan", "large_files", "boundaries"}
    assert "### todo_scan: new findings" in summary.read_text()
    assert "## Tech debt" in debt.read_text()
    assert run_all.main(["--root", str(root), "--only", "large_files", "--debt-report", str(debt)]) == 0
    names = [r.name for r, _ in run_all.collect(root, fast=True, skip={"workflows", "api_docs", "complexity", "dead_code", "duplicates", "unused_deps", "agents_md", "test_map", "feature_flags", "boundaries", "todo_scan"})]
    assert names == ["large_files"]

    def boom(r):
        raise RuntimeError("kaput")

    monkeypatch.setattr(run_all, "registry", lambda base: [("boom", boom)])
    res, _ = run_all.collect(root, verbose=True)[0]
    assert res.new == ["check crashed: RuntimeError('kaput')"]
    assert "SKIP" in run_all.summary_markdown([(common.Result("x", skipped="why"), 0.1)])
