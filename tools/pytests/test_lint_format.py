import json

from tools.checks import format as gdformat_check
from tools.checks import lint

GOOD = "extends Node\n\n\nfunc good_name() -> void:\n\tpass\n"
BAD = "extends Node\n\n\nfunc BadName() -> void:\n\tvar X := 1\n\tprint(X)\n"


def test_parse_output():
    text = "a.gd:3: Error: Function name \"X\" is not valid (function-name)\nnoise\nFailure: 1 problem found"
    assert lint.parse_output(text) == [
        {"path": "a.gd", "line": 3, "rule": "function-name", "msg": 'Function name "X" is not valid'}
    ]


def test_baseline_counts_and_new_findings(repo):
    root = repo({"a.gd": GOOD})
    f1 = {"path": "a.gd", "line": 1, "rule": "max-line-length", "msg": "too long"}
    res = lint.run(root, findings=[f1], update=True)
    assert res.ok and len(res.known) == 1
    res = lint.run(root, findings=[f1, dict(f1, line=9)])
    assert not res.ok and "x1 over baseline (lines 1, 9)" in res.new[0]
    res = lint.run(root, files=["a.gd"], findings=[], update=True)
    assert json.loads((root / "tools/checks/baselines/gdlint.json").read_text()) == {}


def test_real_gdlint_run(repo, capsys):
    root = repo({"good.gd": GOOD, "bad.gd": BAD})
    res = lint.run(root)
    rules = {f["rule"] for f in res.findings}
    assert "function-name" in rules and "function-variable-name" in rules
    assert not res.ok
    assert lint.main(["--root", str(root), "--update-baseline"]) == 0
    out = root / "f.json"
    assert lint.main(["--root", str(root), "--json", str(out), "bad.gd"]) == 0
    assert json.loads(out.read_text())
    assert lint.run_gdlint(root, []) == []


def test_gdformat_baseline_and_changed(repo, monkeypatch):
    root = repo({"good.gd": GOOD, "ugly.gd": "extends Node\nfunc  f( ):\n\tpass\n"})
    res = gdformat_check.run(root, all_files=True)
    assert [n.split(":")[0] for n in res.new] == ["ugly.gd"]
    res = gdformat_check.run(root, update=True)
    assert res.ok and res.known == ["ugly.gd"]
    res = gdformat_check.run(root, files=["good.gd", "ugly.gd", "other.txt"])
    assert res.ok and res.stats["checked"] == 1
    monkeypatch.setattr(gdformat_check.common, "changed_files", lambda r, b: ["good.gd"])
    assert gdformat_check.run(root, base="x").stats["checked"] == 1
    (root / "tools/checks/baselines/gdformat.json").write_text('["ugly.gd", "gone.gd"]')
    assert "deleted" in gdformat_check.run(root, all_files=True).warnings[0]
    assert gdformat_check.main(["--root", str(root), "--all"]) == 0
