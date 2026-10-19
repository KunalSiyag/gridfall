from tools.checks import dead_code

MAIN = """extends Node
signal used_sig
signal dead_sig
const USED := 1
const DEAD := 2


func _ready() -> void:
\tused_sig.emit()
\tprint(USED)
\tcall("by_string")
\tsetup(null)


func by_string() -> void:
\tvar inner_const_is_local := 1


func dead_func() -> void:
\tpass  # dead_func is mentioned in a comment only


func setup(_c) -> void:
\tpass


func _on_button_pressed() -> void:
\tpass
"""
SCENE = '[connection signal="pressed" from="B" to="." method="_on_button_pressed"]\n'


def test_finds_dead_definitions(repo, capsys):
    root = repo({"a.gd": MAIN, "s.tscn": SCENE})
    res = dead_code.run(root)
    names = sorted(n.split(" ")[2] for n in res.new)
    assert names == ["DEAD", "dead_func", "dead_sig"]
    assert res.stats["dead_by_kind"] == {"const": 1, "func": 1, "signal": 1}
    dead_code.run(root, update=True)
    assert dead_code.run(root).ok
    (root / "b.gd").write_text("func f():\n\tdead_func()\n\tprint(DEAD)\n")
    res = dead_code.run(root, extra_ignore={"f"})
    assert res.ok and "no longer dead" in res.warnings[0]
    assert dead_code.main(["--root", str(root), "-v"]) == 1
    out = capsys.readouterr().out
    assert "NEW: b.gd:1 func f is never referenced" in out and "known: a.gd:3 signal dead_sig" in out
