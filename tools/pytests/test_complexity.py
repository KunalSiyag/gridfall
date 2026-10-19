from tools.checks import complexity

SRC = """extends Node


func simple() -> int:
\treturn 1


func branches(a: int, b: bool) -> int:
\tif a > 1 and b:
\t\treturn 1
\telif a < 0 or not b:
\t\treturn 2
\tfor i in range(a):
\t\twhile i > 0 && b:
\t\t\ti -= 1
\tvar s := "if and or"  # if and or
\treturn 3 if b else 4


func matching(x) -> int:
\tmatch x:
\t\t1, 2:
\t\t\treturn 1
\t\t3 when x > 0:
\t\t\treturn 3
\t\t_:
\t\t\treturn 0
\treturn -1


func one_liner(b: bool) -> int: return 1 if b else 0
"""


def test_scores():
    got = {fn.name: s for fn, s in complexity.function_scores(SRC)}
    assert got == {"simple": 1, "branches": 9, "matching": 4, "one_liner": 2}


def test_grades():
    assert [complexity.grade(s) for s in (1, 6, 11, 21, 31, 41)] == list("ABCDEF")


def test_threshold_baseline_and_growth(repo, capsys):
    root = repo({"a.gd": SRC})
    res = complexity.run(root, threshold=3)
    assert len(res.new) == 2 and res.stats["over_threshold"] == 2
    complexity.run(root, threshold=3, update=True)
    assert complexity.run(root, threshold=3).ok
    (root / "a.gd").write_text(SRC.replace("\treturn -1", "\tif x and x:\n\t\tpass\n\treturn -1"))
    res = complexity.run(root, files=["a.gd"], threshold=3)
    assert res.ok and "grew from 4" in res.warnings[0]
    complexity.run(root, files=["a.gd"], threshold=3, update=True)
    assert complexity.main(["--root", str(root), "--threshold", "3", "--top", "2"]) == 0
    assert "branches" in capsys.readouterr().out


def test_duplicate_qualnames_get_line_suffix(repo):
    root = repo({"a.gd": "func f():\n\tpass\nfunc f():\n\tpass\n"})
    assert sorted(complexity.run(root).scores) == ["a.gd::f", "a.gd::f@3"]
