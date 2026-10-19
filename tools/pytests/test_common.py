from pathlib import Path

from tools.checks import common


def test_lex_blanks_strings_and_comments_keeping_layout():
    src = 'var a := "x # not a comment" # real\nvar b := r"\\d+"\nvar c := """multi\nline""" + &"sn" + \'q\\\'s\'\n'
    lx = common.lex_gd(src)
    assert len(lx.code) == len(src)
    assert lx.code.count("\n") == src.count("\n")
    assert [s for _, s in lx.strings] == ["x # not a comment", "\\d+", "multi\nline", "sn", "q\\'s"]
    assert lx.comments == [(1, "# real")]
    assert "not" not in lx.code_lines[0]
    assert lx.code_lines[3].startswith('    """')


def test_lex_unterminated_string_stops_at_newline():
    lx = common.lex_gd('var a := "open\nvar b := 1\n')
    assert "var b := 1" in lx.code_lines[1]


def test_gd_functions_with_inner_class_and_bodies():
    src = (
        "extends Node\n"
        "func a() -> void:\n"
        "\tif true:\n"
        "\t\tpass\n"
        "\n"
        "static func b(x: int) -> int: return x\n"
        "class Inner:\n"
        "\tfunc c():\n"
        "\t\tpass\n"
        "func d():\n"
        "\tpass\n"
    )
    funcs = common.gd_functions(common.lex_gd(src))
    assert [(f.qualname, f.start, f.end) for f in funcs] == [
        ("a", 2, 4),
        ("b", 6, 6),
        ("Inner.c", 8, 9),
        ("d", 10, 11),
    ]


def test_glob_matching():
    m = common.matches
    assert m("scripts/fp/a.gd", ["scripts/fp/*.gd"])
    assert not m("scripts/fp/ui/a.gd", ["scripts/fp/*.gd"])
    assert m("a/b/c.gd", ["*.gd"])
    assert m("a/b/c.gd", ["a/**"])
    assert m("x/y/b.gd", ["**/b.gd"]) and m("b.gd", ["**/b.gd"])
    assert m("tools/requirements-dev.txt", ["tools/requirements*.txt"])
    assert m("a/x1.gd", ["a/x[0-9].gd"]) and not m("a/xa.gd", ["a/x[!a-z].gd"])
    assert m("a/[.gd", ["a/[.gd"])
    assert m("a/b?.gd", ["a/b?.gd"])


def test_list_files_walk_and_git(repo):
    root = repo({"a.gd": "", "sub/b.py": "", ".godot/x.gd": "", "sub/__pycache__/c.pyc": ""})
    assert common.list_files(root) == ["a.gd", "sub/b.py"]
    assert common.list_files(root, ("*.gd",)) == ["a.gd"]
    assert common.list_files(root, exclude=("sub/**",)) == ["a.gd"]
    (root / ".gitignore").write_text("ignored.txt\n")
    (root / "ignored.txt").write_text("x")
    root2 = repo({"c.gd": ""}, git=True)
    files = common.list_files(root2)
    assert "c.gd" in files and "ignored.txt" not in files


def test_json_helpers_and_report(tmp_path, capsys):
    p = tmp_path / "b" / "x.json"
    common.save_json(p, {"b": 1, "a": [1]})
    assert p.read_text().endswith("\n")
    assert common.load_json(p, None) == {"a": [1], "b": 1}
    assert common.load_json(tmp_path / "missing.json", 7) == 7
    r = common.Result("demo", new=["n1"], known=["k1"], warnings=["w1"])
    assert common.report(r, verbose=True) == 1
    out = capsys.readouterr().out
    assert "demo: NEW: n1" in out and "demo: known: k1" in out and "warning: w1" in out
    assert r.to_dict()["ok"] is False
    assert common.report(common.Result("s", skipped="why")) == 0
    assert "| a |" in common.markdown_table(["a"], [["x|y"]])


def test_git_helpers_with_canned_output(monkeypatch, tmp_path):
    calls = []

    def fake_git(root, *args):
        calls.append(args)
        if args[0] == "rev-parse":
            return "" if args[3].startswith("missing") else "abc123\n"
        if args[0] == "merge-base":
            return "base456\n"
        if args[:2] == ("diff", "-U0"):
            return (
                "diff --git a/x.gd b/x.gd\n+++ b/x.gd\n@@ -1,0 +2,3 @@\n+a\n"
                "@@ -9 +12 @@\n+b\n+++ /dev/null\n"
            )
        if args[0] == "diff":
            return "x.gd\ngone.gd\n"
        if args[0] == "ls-files":
            return "new.gd\n"
        return ""

    (tmp_path / "x.gd").write_text("")
    (tmp_path / "new.gd").write_text("")
    monkeypatch.setattr(common, "git", fake_git)
    assert common.resolve_base(tmp_path, "0000000") == "base456"
    assert common.resolve_base(tmp_path, "feature") == "base456"
    assert common.changed_files(tmp_path, "feature") == ["new.gd", "x.gd"]
    assert common.added_lines(tmp_path, "feature") == {"x.gd": {2, 3, 4, 12}}
    monkeypatch.setattr(common, "git", lambda root, *a: "")
    assert common.resolve_base(tmp_path, None) == ""
    assert common.changed_files(tmp_path, None) == []
    assert common.added_lines(tmp_path, None) == {}


def test_real_git_helper_on_non_repo(tmp_path):
    assert common.git(tmp_path, "rev-parse", "HEAD") == ""
    assert common.read_text(tmp_path, "nope.txt") == ""
    assert common.indent_of("\t  x") == 6
    assert isinstance(common.REPO, Path)
