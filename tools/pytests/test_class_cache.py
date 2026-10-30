"""Tests for tools/refresh_class_cache.py."""
from __future__ import annotations

from tools import refresh_class_cache as rcc


def _entry(text: str, name: str) -> str:
    i = text.index(f'"class": &"{name}"')
    start = text.rfind("{", 0, i)
    end = text.index("}", i)
    return text[start : end + 1]


def test_parse_variants():
    cases = {
        "class_name Foo\nextends Node\n": ("Foo", "Node", False, False),
        "@tool\nclass_name Bar\nextends RefCounted\n": ("Bar", "RefCounted", False, True),
        "abstract class_name Baz\nextends Node3D\n": ("Baz", "Node3D", True, False),
        "extends VBoxContainer\nclass_name Quux\n": ("Quux", "VBoxContainer", False, False),
        "class_name Sub\nextends Foo\n": ("Sub", "Foo", False, False),
        "class_name Plain\n": ("Plain", "RefCounted", False, False),
    }
    for src, want in cases.items():
        info = rcc.parse_global_class(src, lambda b: b or "RefCounted")
        assert info is not None, src
        got = (info["name"], info["base"], info["abstract"], info["tool"])
        assert got == want, src


def test_parse_ignores_comments_and_inner_classes():
    src = (
        "extends Node\n"
        "# class_name NotReal\n"
        'var doc := "class_name AlsoNotReal"\n'
        "class_name Real\n"
        "class Inner:\n"
        "\tpass\n"
    )
    info = rcc.parse_global_class(src, lambda b: b or "RefCounted")
    assert info["name"] == "Real"
    assert rcc.parse_global_class("class Inner:\n\tpass\n", lambda b: b) is None


def test_render_format_matches_godot():
    entries = [
        {"name": "Alpha", "base": "Logger", "abstract": False, "tool": True, "path": "res://scripts/a.gd"},
        {"name": "Beta", "base": "Node", "abstract": False, "tool": False, "path": "res://scripts/b.gd"},
    ]
    assert rcc.render(entries) == (
        'list=[{\n"base": &"Logger",\n"class": &"Alpha",\n"icon": "",\n'
        '"is_abstract": false,\n"is_tool": true,\n"language": &"GDScript",\n'
        '"path": "res://scripts/a.gd"\n}, {\n"base": &"Node",\n"class": &"Beta",\n'
        '"icon": "",\n"is_abstract": false,\n"is_tool": false,\n"language": &"GDScript",\n'
        '"path": "res://scripts/b.gd"\n}]\n'
    )
    assert rcc.render([]) == "list=[]\n"


def test_refresh_add_removes_and_is_idempotent(repo):
    root = repo(
        {
            "scripts/a.gd": "class_name Alpha\nextends Node\n",
            "scripts/sub/b.gd": "class_name Beta\nextends Alpha\n",
        }
    )
    added, removed, changed, total = rcc.refresh(root)
    assert (added, removed, changed, total) == (["Alpha", "Beta"], [], True, 2)
    text = (root / rcc.CACHE_REL).read_text()
    assert '"base": &"Alpha"' in _entry(text, "Beta")
    # Second run is a no-op.
    assert rcc.refresh(root) == ([], [], False, 2)
    # Deleting a script drops its entry; adding one adds it.
    (root / "scripts/sub/b.gd").unlink()
    (root / "scripts/c.gd").write_text("class_name Gamma\n", encoding="utf-8")
    added, removed, changed, total = rcc.refresh(root)
    assert (added, removed, changed, total) == (["Gamma"], ["Beta"], True, 2)


def test_refresh_skips_hidden_dirs_and_bad_encoding(repo):
    root = repo(
        {
            "scripts/a.gd": "class_name Alpha\n",
            ".godot/editor/ghost.gd": "class_name Ghost\n",
            "scripts/bin.gd": None or b"\xff\xfe\x00bad",
        }
    )
    _, _, _, total = rcc.refresh(root)
    assert total == 1


def test_refresh_quoted_extends_resolves_to_global_class(repo):
    root = repo(
        {
            "scripts/base.gd": "class_name Base\nextends Node\n",
            "scripts/child.gd": 'class_name Child\nextends "res://scripts/base.gd"\n',
            "scripts/plain.gd": 'class_name Plainish\nextends "res://scripts/missing.gd"\n',
        }
    )
    rcc.refresh(root)
    text = (root / rcc.CACHE_REL).read_text()
    assert '"base": &"Base"' in _entry(text, "Child")
    assert '"base": &"RefCounted"' in _entry(text, "Plainish")


def test_main_quiet_and_error(repo, capsys):
    root = repo({"scripts/a.gd": "class_name Alpha\n"})
    assert rcc.main(["--root", str(root), "--quiet"]) == 0
    assert capsys.readouterr().out == ""
    assert rcc.main(["--root", str(root)]) == 0
    assert "in sync (1 classes)" in capsys.readouterr().out
    # Unwritable cache path -> exit 1.
    blocker = root / ".godot"
    (root / rcc.CACHE_REL).unlink()
    blocker.rmdir()
    blocker.write_text("not a dir")
    assert rcc.main(["--root", str(root)]) == 1
    assert "refresh_class_cache:" in capsys.readouterr().err
