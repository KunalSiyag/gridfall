from tools.checks import duplicates

BLOCK = "".join(f"\tvar value_number_{i} := compute_something_long({i}, \"label {i}\")\n" for i in range(10))


def gd(name: str) -> str:
    return f"func {name}():\n" + BLOCK + "\treturn 0\n"


def test_duplicate_blocks_baseline(repo, capsys):
    root = repo({"a.gd": gd("a"), "b.gd": "# header\n" + gd("b"), "c.py": "x = 1  # c\n"})
    res = duplicates.run(root)
    assert len(res.new) == 1 and "a.gd:2-12" in res.new[0] and "b.gd:3-13" in res.new[0]
    assert res.stats["duplicated_lines"] > 0
    duplicates.run(root, update=True)
    assert duplicates.run(root).ok
    (root / "d.gd").write_text(gd("d"))
    assert not duplicates.run(root).ok
    assert duplicates.main(["--root", str(root)]) == 1
    assert "duplicated lines" in capsys.readouterr().out


def test_normalisation_drops_comments():
    a = duplicates.normalized("x.py", "a = 1  # one\n\n   b =  2\n")
    assert a == [(1, "a = 1"), (3, "b = 2")]
    assert duplicates.normalized("x.py", "def f(:\n  # c\n")[0] == (1, "def f(:")
    g = duplicates.normalized("x.gd", 'var a := "#x" # c\n')
    assert g == [(1, 'var a := "#x"')]


def test_repeated_identical_lines_are_one_copy(repo):
    root = repo({"a.gd": BLOCK * 1 + "\n".join(["\tvar same_line_repeated_here := 1234567890"] * 30) + "\n"})
    assert duplicates.run(root).ok
