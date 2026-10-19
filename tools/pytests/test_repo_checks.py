import json

from tools.checks import agents_md, boundaries, large_files, test_map, todo_scan

CFG = {
    "layers": [{"name": "sim-core", "from": ["scripts/sim/**"], "forbid": ["scripts/views/**"], "why": "headless"}],
    "slices": {
        "root": "scripts/fp",
        "owners": {"chat": "S4", "npc": "S2"},
        "file_owners": {"scripts/fp/fp_npc_glue.gd": "S2"},
        "shared": ["scripts/fp/*.gd"],
    },
    "allow": [{"from": "scripts/fp/chat/ok.gd", "to": "scripts/fp/npc/**", "why": "documented API"}],
}


def boundary_repo(repo, extra=None):
    files = {
        "tools/checks/boundaries.json": json.dumps(CFG),
        "scripts/sim/core.gd": 'extends Node\nconst V = preload("res://scripts/views/view.gd")\n',
        "scripts/views/view.gd": "class_name View\nextends Node\n",
        "scripts/fp/fp_core.gd": "class_name FpCore\n",
        "scripts/fp/npc/brain.gd": "class_name NpcBrain\nvar c := FpCore.new()\n",
        "scripts/fp/chat/talk.gd": "var b: NpcBrain\n# NpcBrain in a comment is no dependency\n",
        "scripts/fp/chat/ok.gd": "var b: NpcBrain\n",
        "scripts/fp/fp_npc_glue.gd": "var b: NpcBrain\n",
    }
    files.update(extra or {})
    return repo(files)


def test_boundaries_layers_slices_allow_and_baseline(repo, capsys):
    root = boundary_repo(repo)
    graph = boundaries.dependency_graph(root)
    assert graph["scripts/sim/core.gd"] == {"scripts/views/view.gd"}
    assert graph["scripts/fp/npc/brain.gd"] == {"scripts/fp/fp_core.gd"}
    res = boundaries.run(root)
    edges = sorted(n.split(" (")[0] for n in res.new)
    assert edges == [
        "scripts/fp/chat/talk.gd -> scripts/fp/npc/brain.gd",
        "scripts/sim/core.gd -> scripts/views/view.gd",
    ]
    assert any("layer sim-core: headless" in n for n in res.new)
    assert boundaries.slice_of("scripts/fp/fp_npc_glue.gd", CFG) == "S2"
    assert boundaries.slice_of("scripts/fp/fp_core.gd", CFG) is None
    assert boundaries.slice_of("scripts/other/x.gd", CFG) is None
    assert boundaries.slice_of("scripts/fp/posters/p.gd", CFG) == "posters"
    boundaries.run(root, update=True)
    assert boundaries.run(root).ok
    (root / "scripts/sim/core.gd").write_text("extends Node\n")
    res = boundaries.run(root)
    assert res.ok and "gone" in res.warnings[0]
    assert boundaries.main(["--root", str(root), "--graph"]) == 0
    assert "scripts/fp/npc/brain.gd -> scripts/fp/fp_core.gd" in capsys.readouterr().out


def test_boundaries_skips_without_config(repo):
    root = repo({"a.gd": "extends Node\n"})
    res = boundaries.run(root)
    assert res.skipped and res.ok
    assert boundaries.main(["--root", str(root)]) == 0


def test_large_files(repo, capsys):
    root = repo({"small.txt": "x", "big.bin": b"0" * 3000, "huge.bin": b"0" * 6000, "ok.bin": b"0" * 5000})
    (root / "tools/checks/baselines").mkdir(parents=True)
    (root / "tools/checks/baselines/large_files.json").write_text('{"ok.bin": "needed"}')
    mb = 1024 * 1024
    res = large_files.run(root, max_mb=4500 / mb, warn_mb=2000 / mb)
    assert res.new == [f"huge.bin: {6000 / mb:.1f} MB > {4500 / mb:g} MB (compress it, split it or keep it out of git)"]
    assert len(res.known) == 1 and "allowed: needed" in res.known[0]
    assert len(res.warnings) == 1 and res.warnings[0].startswith("big.bin")
    assert res.stats["largest"][0]["path"] == "huge.bin"
    assert large_files.run(root, files=["small.txt", "missing.bin"]).stats["files"] == 1
    assert large_files.main(["--root", str(root), "small.txt"]) == 0
    assert large_files.main(["--root", str(root), "--max-mb", "0.004"]) == 1
    assert "huge.bin" in capsys.readouterr().out


TAG = "TO" + "DO"


def test_todo_scan_policy_and_report(repo, tmp_path):
    root = repo(
        {
            "a.gd": f'var s := "{TAG}: in a string"\n# {TAG}(#12): linked\n# {TAG}: legacy item\n',
            "b.py": f"x = 1  # FIX" + f"ME: py comment\ny = '{TAG}: str'\n",
            "c.sh": f"echo hi # HA" + "CK(https://github.com/o/r/issues/3): url\n",
            "s.gdshader": f"// {TAG} shader thing\n",
            "bad.py": f"def f(:\n  # {TAG}: broken python\n",
        }
    )
    res = todo_scan.run(root)
    texts = sorted(n.split(" (link")[0] for n in res.new)
    assert texts == [
        f"a.gd:3 {TAG}: legacy item",
        "b.py:1 FIX" + "ME: py comment",
        f"bad.py:2 {TAG}: broken python",
        f"s.gdshader:1 {TAG}: shader thing",
    ]
    assert res.stats["linked"] == 2 and res.stats["markers"] == 6
    todo_scan.run(root, update=True)
    assert todo_scan.run(root).ok
    (root / "a.gd").write_text(f"# {TAG}: legacy item\n# {TAG}: legacy item\n")
    res = todo_scan.run(root, files=["a.gd"])
    assert len(res.new) == 1
    todo_scan.run(root, files=["a.gd"], update=True)
    assert todo_scan.run(root).ok
    report = tmp_path / "debt.md"
    assert todo_scan.main(["--root", str(root), "--report", str(report)]) == 0
    md = report.read_text()
    assert "## Tech debt" in md and "| `c.sh:1` | HA" + "CK |" in md
    assert "0 markers" in todo_scan.markdown([])


AGENTS = """# Agents
## Setup
Run `tools/gate.sh quick` and `python3 tools/checks/run_all.py --fast`.
Read `docs/notes.md`, `res://scripts/a.gd`, `scripts/*.gd` and `scripts/<slice>/` and `{x}`.
Ignore `https://example.com/tools/x` and `--flag` and `env FOO=tools/gate.sh`.
```
`tools/not_checked_in_fence.sh`
```
## Testing
`tools/missing.sh` and `scripts/nothing_*.gd` and `README.md:12`.
## Rules
"""


def test_agents_md(repo):
    root = repo(
        {
            "AGENTS.md": AGENTS,
            "tools/gate.sh": "",
            "tools/checks/run_all.py": "",
            "docs/notes.md": "",
            "scripts/a.gd": "",
            "README.md": "",
        }
    )
    res = agents_md.run(root)
    assert sorted(n.split(": `")[1].split("`")[0] for n in res.new) == ["scripts/nothing_*.gd", "tools/missing.sh"]
    assert res.stats["headings"] == 4
    res = agents_md.run(root, required=("deploy",))
    assert any("no section heading matches /deploy/" in n for n in res.new)
    (root / "E.md").write_text("  \n")
    assert agents_md.run(root, "E.md").new == ["E.md is empty"]
    assert agents_md.run(root, "N.md").new == ["N.md is missing"]
    assert agents_md.main(["--root", str(root), "--file", "README.md", "--require", "x"]) == 1
    assert agents_md.candidate_paths("echo 'unbalanced", {"echo"}) == []
    assert agents_md.strip_fences("a\n~~~\nb\n~~~\nc") == "a\n\n\n\nc"


REGISTRY = """const FEATURES := [
\t{"id": "chat", "path": "res://scripts/fp/chat/fp_chat.gd"},
\t{"id": "perf", "path": "res://scripts/fp/perf/fp_perf.gd"},
\t{"id": "npc", "path": "res://scripts/fp/npc/fp_npc.gd"},
]
"""


def test_test_map(repo, capsys):
    root = repo(
        {
            "scripts/fp/fp_features.gd": REGISTRY,
            "scripts/fp/chat/fp_chat.gd": "class_name FpChat\n",
            "scripts/fp/perf/fp_perf.gd": "extends Node\n",
            "scripts/fp/npc/fp_npc.gd": "extends Node\n",
            "scripts/fp/npc/brain.gd": "extends Node\n",
            "scripts/fp/sim/s.gd": "extends Node\n",
            "tools/tests/fp_chat_test.gd": "var c := FpChat.new()\n",
            "tools/tests/fp_npc_test.gd": 'var p := "res://scripts/fp/npc/brain.gd"\nvar f := "npc"\n',
        }
    )
    assert test_map.features(root)[0] == ("chat", "scripts/fp/chat/fp_chat.gd")
    res = test_map.run(root)
    keys = sorted(n.split(": ")[0] for n in res.new)
    assert keys == ["feature::perf", "slice::perf", "slice::sim"]
    assert res.stats["covered"] == 4
    test_map.run(root, update=True)
    assert test_map.run(root).ok
    (root / "tools/tests/fp_perf_test.gd").write_text('var id := "perf"\n')
    res = test_map.run(root)
    assert res.ok and "feature::perf" in res.warnings[0]
    assert test_map.main(["--root", str(root), "-v"]) == 0
    assert "slice::chat: fp_chat_test.gd" in capsys.readouterr().out
