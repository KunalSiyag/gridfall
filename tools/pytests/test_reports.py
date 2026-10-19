import json
import subprocess

import pytest

from tools import changelog, gen_api_docs
from tools.checks import build_timing, common, flaky_report, pr_review, quality_report


def results(mode="quick", commit="c1", **steps):
    return {
        "mode": mode,
        "commit": commit,
        "result": "PASS",
        "steps": [{"step": k, "result": v[0], "secs": v[1]} for k, v in steps.items()],
    }


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data))
    return str(path)


def test_build_timing(tmp_path, capsys):
    cur = write(tmp_path / "r.json", results(import_=("PASS", 100), parse=("PASS", 30), new=("PASS", 2), zero=("PASS", 1)))
    base = tmp_path / "b.json"
    assert build_timing.main([cur, "--baseline", str(base), "--update-baseline"]) == 0
    assert json.loads(base.read_text())["quick"]["parse"] == 30
    base.write_text(json.dumps({"quick": {"parse": 10, "import_": 100, "zero": 0}}))
    summary = tmp_path / "s.md"
    assert build_timing.main([cur, "--baseline", str(base), "--summary", str(summary)]) == 0
    assert build_timing.main([cur, "--baseline", str(base), "--fail-on-regression"]) == 1
    md = summary.read_text()
    assert "| parse | PASS | 30 | 10 | +200% | REGRESSION |" in md and "| new | PASS | 2 | - | new |" in md
    assert "Regressions over 50%: parse" in md and "| zero | PASS | 1 | 0 | - |" in md
    prev = write(tmp_path / "p.json", results(parse=("PASS", 29)))
    assert build_timing.main([cur, "--baseline", str(base), "--previous", prev, "--fail-on-regression"]) == 0
    assert "from the previous run" in capsys.readouterr().out
    bad_prev = tmp_path / "bad.json"
    bad_prev.write_text("[]")
    assert build_timing.main([cur, "--baseline", str(base), "--previous", str(bad_prev)]) == 0
    with pytest.raises(ValueError):
        build_timing.load_results(bad_prev)


def test_flaky_report(tmp_path, capsys):
    write(tmp_path / "logs/a/results.json", results(commit="c1", a=("PASS", 1), b=("PASS(flaky)", 1), c=("FAIL", 1)))
    write(tmp_path / "logs/b/results.json", results(commit="c1", a=("PASS", 1), b=("PASS", 1), c=("PASS", 1)))
    single = write(tmp_path / "one.json", results(commit="c2", a=("TIMEOUT", 1)))
    (tmp_path / "logs/junk/results.json").parent.mkdir()
    (tmp_path / "logs/junk/results.json").write_text("{}")
    out_json, summary = tmp_path / "f.json", tmp_path / "s.md"
    assert flaky_report.main([str(tmp_path / "logs"), single, "--json", str(out_json), "--summary", str(summary)]) == 0
    rows = {r["step"]: r for r in json.loads(out_json.read_text())}
    assert rows["a"] == {"step": "a", "runs": 3, "pass": 2, "flaky": 0, "fail": 1, "mixed_commits": 0, "flake_rate": 0.0}
    assert rows["b"]["flaky"] == 1 and rows["c"]["mixed_commits"] == 1
    md = summary.read_text()
    assert "3 gate runs, 2 flaky steps." in md and "| b | 2 | 1 | 1 | 0 | 50% |" in md
    assert "0 flaky steps" in flaky_report.markdown([], 0)


def test_quality_report(repo, tmp_path, capsys):
    root = repo(
        {
            "scripts/fp/npc/a.gd": "extends Node\n\nvar x := 1\n",
            "scripts/sim/b.gd": "extends Node\n",
            "scripts/top.gd": "x\n",
            "tools/checks/c.py": "x = 1\n",
            "tools/pytests/test_x.py": "def test_a():\n    pass\n\ndef test_b():\n    pass\n",
            "tools/tests/fp_a_test.gd": "extends SceneTree\n",
            "README.md": "x\n",
            "docs/x.py": "y = 2\n",
        }
    )
    assert quality_report.area_of("scripts/fp/npc/a.gd") == "scripts/fp/npc"
    assert quality_report.area_of("scripts/fp/a.gd") == "scripts/fp"
    assert quality_report.area_of("scripts/top.gd") == "scripts"
    assert quality_report.area_of("tools/x.py") == "tools"
    assert quality_report.area_of("x.py") == "(root)"
    checks = {
        "checks": {
            "gdlint": {"ok": True, "new": [], "known_count": 3, "stats": {"findings": 3, "by_rule": {"max-line-length": 3}}},
            "complexity": {"ok": False, "new": ["x"], "stats": {"functions": 4, "max": 30, "threshold": 20}},
            "feature_flags": {"ok": True, "new": [], "skipped": "no file"},
        }
    }
    cov = {"totals": {"percent_covered": 87.456}}
    gate = results(a=("PASS", 3), b=("PASS(flaky)", 4))
    out, md = tmp_path / "q/quality.json", tmp_path / "q.md"
    rc = quality_report.main(
        [
            "--root", str(root), "--from", write(tmp_path / "c.json", checks), "--coverage", write(tmp_path / "cov.json", cov),
            "--gate-results", write(tmp_path / "g.json", gate), "--out", str(out), "--markdown", str(md),
        ]
    )
    assert rc == 0
    r = json.loads(out.read_text())
    assert r["tests"] == {"godot_test_scripts": 1, "pytest_files": 1, "pytest_functions": 2, "test_map_gaps": None, "python_line_coverage_pct": 87.5}
    assert r["gate"] == {"mode": "quick", "result": "PASS", "steps": 2, "flaky": 1, "secs": 7}
    assert r["loc"]["scripts/fp/npc"] == {"files": 1, "gd": 2, "py": 0}
    assert r["loc_total"] == {"gd": 5, "py": 2 + 4}
    assert r["checks"]["complexity"] == {"ok": False, "new": 1, "baselined": 0, "skipped": ""}
    text = md.read_text()
    assert "## Code quality" in text and "87.5%" in text and "| feature_flags | SKIP | 0 | 0 |" in text
    assert "Gate quick" in text


def test_quality_report_runs_checks_itself(repo, tmp_path, monkeypatch):
    from tools.checks import run_all

    root = repo({"a.gd": "extends Node\n"})
    monkeypatch.setattr(run_all, "collect", lambda r: [(common.Result("todo_scan", stats={"markers": 0}), 0.0)])
    out = tmp_path / "q.json"
    assert quality_report.main(["--root", str(root), "--out", str(out)]) == 0
    r = json.loads(out.read_text())
    assert r["tech_debt"]["markers"] == 0 and "gate" not in r


BIG = "func big(x):\n" + "".join(f"\tif x == {i}:\n\t\tpass\n" for i in range(22)) + "\n"
TODO = "TO" + "DO"


def test_pr_review(repo, monkeypatch, tmp_path, capsys):
    root = repo(
        {
            "a.gd": "extends Node\n\n\n" + BIG + f"func dead_one():\n\tpass  # {TODO}: later\n",
            "b.gd": "extends Node\n\n\n" + BIG.replace("big", "known_big"),
            "c.gd": "extends Node\n\n\n" + BIG.replace("big", "untouched") + "func also_dead():\n\tpass\n",
            "tools/checks/baselines/complexity.json": json.dumps({"b.gd::known_big": 30}),
        }
    )
    big_start = 4
    added = {
        "a.gd": set(range(1, 60)),
        "b.gd": {big_start + 3},
        "c.gd": {1},
    }
    monkeypatch.setattr(common, "added_lines", lambda r, base: added)
    monkeypatch.setattr(
        pr_review.lint,
        "run_gdlint",
        lambda r, files: [
            {"path": "a.gd", "line": 1, "rule": "max-line-length", "msg": "too long"},
            {"path": "b.gd", "line": 1, "rule": "max-line-length", "msg": "not on an added line"},
        ],
    )
    data = pr_review.review(root, "main")
    bodies = [(c["path"], c["line"], c["body"]) for c in data["comments"]]
    assert ("a.gd", 1, "gdlint `max-line-length`: too long") in bodies
    assert any(p == "a.gd" and ln == big_start and "Cyclomatic complexity 23" in b and "above the threshold" in b for p, ln, b in bodies)
    assert not any(p == "b.gd" for p, _, _ in bodies)
    assert not any("untouched" in b for _, _, b in bodies)
    assert any(p == "a.gd" and "Unlinked" in b for p, _, b in bodies)
    assert any(p == "a.gd" and b.startswith("Dead code: func dead_one") for p, _, b in bodies)
    assert data["counts"]["notes"] >= 1 and "Elsewhere in changed files" in data["summary"]
    assert data["summary"].startswith(pr_review.MARKER)
    (root / "tools/checks/baselines/complexity.json").write_text(json.dumps({"b.gd::known_big": 10}))
    data = pr_review.review(root, "main", use_gdlint=False)
    assert any(c["path"] == "b.gd" and "grew from 10" in c["body"] for c in data["comments"])
    out, md = tmp_path / "review.json", tmp_path / "r.md"
    monkeypatch.setattr(common, "added_lines", lambda r, base: {})
    assert pr_review.main(["--root", str(root), "--base", "main", "--out", str(out), "--markdown", str(md)]) == 0
    assert json.loads(out.read_text())["comments"] == []
    assert "No new findings on the 0 changed files" in md.read_text()
    assert pr_review._touches(root, "a.gd", 999, {1}) is False


GD = '''class_name Thing
extends Node
## A thing in the city.
## Second line.

signal moved(to: Vector3)
enum Mode { A, B }
const SPEED := 4.0 # metres per second
const LONG := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30]
const _HIDDEN := 1
## Documented speed.
var speed: float = 1.0
@export var exported := 2
var undocumented := 3


## Moves it.
func move(to: Vector3,
		fast: bool = false) -> void:
	pass


static func make() -> Thing: return null


func _private() -> void:
	pass


class Inner:
	var x := 1
'''


def test_gen_api_docs(repo, capsys):
    root = repo({"scripts/a/thing.gd": GD, "scripts/a/empty.gd": "extends Node\n", "scripts/b/doc_only.gd": "## Just docs.\n"})
    info = gen_api_docs.parse_script(GD)
    assert info["class_name"] == "Thing" and info["extends"] == "Node"
    assert info["doc"] == ["A thing in the city.", "Second line."]
    pages = gen_api_docs.render(root)
    assert set(pages) == {"index.md", "scripts.a.md", "scripts.b.md"}
    page = pages["scripts.a.md"]
    for want in [
        "class_name `Thing` · extends `Node`",
        "- `moved(to: Vector3)`",
        "- `Mode { A, B }`",
        "- `SPEED = 4.0`: metres per second",
        "- `speed: float`: Documented speed.",
        "- `exported`",
        "- `func move(to: Vector3, fast: bool = false) -> void`: Moves it.",
        "- `static func make() -> Thing`",
        "- `Inner`",
        "(no public API documented)",
    ]:
        assert want in page, want
    assert "_HIDDEN" not in page and "undocumented" not in page and "_private" not in page
    assert "LONG = [1, 2" in page and "..." in page
    assert "Just docs." in pages["scripts.b.md"]
    assert gen_api_docs.main(["--root", str(root), "--check"]) == 1
    assert gen_api_docs.main(["--root", str(root)]) == 0
    assert gen_api_docs.main(["--root", str(root), "--check"]) == 0
    (root / "docs/api/old.md").write_text("x")
    (root / "docs/api/index.md").write_text("changed")
    (root / "docs/api/scripts.b.md").unlink()
    assert sorted(gen_api_docs.stale(root)) == [
        "docs/api/index.md out of date",
        "docs/api/old.md has no source directory",
        "docs/api/scripts.b.md missing",
    ]
    gen_api_docs.write(root)
    assert not (root / "docs/api/old.md").exists()
    assert "PASS" in capsys.readouterr().out


LOG = (
    "a1\x1ffeat(fp/A): crouch\x1f\x1e\n"
    "b2\x1ffix: crash on load\x1fBREAKING CHANGE: save format\x1e\n"
    "c3\x1fperf!: faster\x1f\x1e\n"
    "d4\x1fUpdate stuff\x1f\x1e\n"
    "e5\x1fwip: odd type\x1e\n"
)


def test_changelog(monkeypatch, tmp_path, capsys):
    calls = []

    def fake_git(*args, root=None):
        calls.append(args)
        if args[0] == "describe":
            raise subprocess.CalledProcessError(128, "git")
        return LOG

    monkeypatch.setattr(changelog, "git", fake_git)
    assert changelog.latest_tag(tmp_path) == ""
    items = changelog.commits("", tmp_path)
    assert items[0] == ("a1", "feat(fp/A): crouch", "") and items[4] == ("e5", "wip: odd type", "")
    text = changelog.section("1.0.0", "2025-01-01", items)
    assert text.startswith("## [1.0.0] - 2025-01-01")
    assert "### Breaking changes\n\n- crash on load (b2)\n- faster (c3)" in text
    assert "### Features\n\n- **fp/A**: crouch (a1)" in text
    assert "### Other changes\n\n- odd type (e5)\n- Update stuff (d4)" in text or "- Update stuff (d4)" in text
    assert "No changes." in changelog.section("x", "d", [])
    assert changelog.insert("", "## [1]\n").startswith("# Changelog")
    assert changelog.insert("# T\n\n## [0]\nold\n", "## [1]\n") == "# T\n\n## [1]\n\n## [0]\nold\n"
    assert changelog.insert("# T\n", "## [1]\n") == "# T\n\n## [1]\n"
    out = tmp_path / "CHANGELOG.md"
    assert changelog.main(["--root", str(tmp_path), "--version", "1.0.0", "--date", "2025-01-01", "--write", "CHANGELOG.md"]) == 0
    assert out.read_text().startswith("# Changelog")
    assert changelog.main(["--root", str(tmp_path), "--since", "v0.1.0"]) == 0
    assert ("log", "--no-merges", "--format=%h%x1f%s%x1f%b%x1e", "v0.1.0..HEAD") in calls
    assert "## [Unreleased]" in capsys.readouterr().out


def test_changelog_real_git_on_non_repo(tmp_path):
    assert changelog.latest_tag(tmp_path) == ""
