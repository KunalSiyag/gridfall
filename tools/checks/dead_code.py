"""Dead GDScript: functions, constants and signals that nothing in the repo refers to.

usage: python3 tools/checks/dead_code.py [--update-baseline] [-v]

A definition counts as used when its name appears anywhere else as an identifier: in GDScript
code or string literals (so `call("name")`, `has_method("name")`, `connect("sig", ...)` and
feature hooks named in data count), in scenes and resources (.tscn/.tres signal connections),
project.godot, JSON, Python and shell scripts. Comments do not count. Engine virtuals and the
FpFeature lifecycle overrides are never reported. Legacy dead code lives in
tools/checks/baselines/dead_code.json (`path::kind::name`); anything else fails.
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "dead_code"
BASELINE = "dead_code.json"
REF_PATTERNS = ("*.gd", "*.tscn", "*.tres", "*.godot", "*.cfg", "*.json", "*.py", "*.sh", "*.gdshader")
REF_EXCLUDE = ("tools/checks/baselines/**", "docs/api/**", "addons/**")

# Engine callbacks (Object, Node, Control, CanvasItem, MainLoop/SceneTree, Logger, editor plugins,
# physics bodies, skeleton modifiers, iterators) that Godot calls by name.
ENGINE_VIRTUALS = {
    "_init", "_ready", "_process", "_physics_process", "_enter_tree", "_exit_tree", "_input",
    "_unhandled_input", "_unhandled_key_input", "_shortcut_input", "_gui_input", "_notification",
    "_draw", "_to_string", "_get", "_set", "_get_property_list", "_property_can_revert",
    "_property_get_revert", "_validate_property", "_get_configuration_warnings", "_can_drop_data",
    "_drop_data", "_get_drag_data", "_has_point", "_make_custom_tooltip", "_get_minimum_size",
    "_structured_text_parser", "_integrate_forces", "_initialize", "_finalize", "_iter_init",
    "_iter_next", "_iter_get", "_log_error", "_log_message", "_static_init", "_run",
    "_get_tooltip", "_clips_input", "_post_import", "_enable_plugin", "_disable_plugin",
    "_has_main_screen", "_make_visible", "_get_plugin_name", "_handles", "_edit", "_forward_canvas_gui_input",
    "_forward_3d_gui_input", "_get_allowed_size_flags_horizontal", "_get_allowed_size_flags_vertical",
    "_sort_children", "_accessibility_get_contextual_info", "_get_accessibility_container_name",
    "_process_modification", "_process_modification_with_delta",
}
# FpFeature (scripts/fp/fp_feature.gd) lifecycle; FpMode calls these on every registered feature.
FEATURE_OVERRIDES = {
    "feature_id", "setup", "teardown", "on_world_rebuilt", "to_dict", "from_dict", "pick",
    "self_test", "photo_shots",
}
CONST_RE = re.compile(r"^(\s*)const\s+([A-Za-z_][A-Za-z0-9_]*)")
SIGNAL_RE = re.compile(r"^(\s*)signal\s+([A-Za-z_][A-Za-z0-9_]*)")


def definitions(path: str, lexed: common.Lexed) -> list[tuple[str, str, int]]:
    """(kind, name, line) for funcs, signals and constants outside function bodies."""
    out = []
    funcs = common.gd_functions(lexed)
    in_body = set()
    for fn in funcs:
        out.append(("func", fn.name, fn.start))
        in_body.update(range(fn.start + 1, fn.end + 1))
    for i, line in enumerate(lexed.code_lines, 1):
        if i in in_body:
            continue
        m = CONST_RE.match(line) or SIGNAL_RE.match(line)
        if m:
            out.append(("const" if line.lstrip().startswith("const") else "signal", m.group(2), i))
    return out


def reference_counts(root: Path, files: list[str], lexed: dict[str, common.Lexed]) -> Counter:
    counts: Counter = Counter()
    for f in files:
        if f in lexed:
            lx = lexed[f]
            counts.update(common.identifiers(lx.code))
            for _, s in lx.strings:
                counts.update(common.identifiers(s))
        else:
            counts.update(common.identifiers(common.read_text(root, f)))
    return counts


def ignored(kind: str, name: str) -> bool:
    if kind == "func" and (name in ENGINE_VIRTUALS or name in FEATURE_OVERRIDES):
        return True
    return False


def run(root: Path, update: bool = False, extra_ignore: set[str] | None = None) -> common.Result:
    res = common.Result(NAME)
    ref_files = common.list_files(root, REF_PATTERNS, REF_EXCLUDE)
    gd_files = [f for f in ref_files if f.endswith(".gd")]
    lexed = {f: common.lex_gd(common.read_text(root, f)) for f in gd_files}
    counts = reference_counts(root, ref_files, lexed)
    defs: list[tuple[str, str, str, int]] = []
    for f in gd_files:
        for kind, name, line in definitions(f, lexed[f]):
            defs.append((f, kind, name, line))
    def_counts = Counter(name for _, _, name, _ in defs)
    dead = {}
    for f, kind, name, line in defs:
        if ignored(kind, name) or (extra_ignore and name in extra_ignore):
            continue
        if counts[name] <= def_counts[name]:
            dead[f"{f}::{kind}::{name}"] = line
    bpath = common.baseline_path(root, BASELINE)
    baseline = set(common.load_json(bpath, []))
    if update:
        baseline = set(dead)
        common.save_json(bpath, sorted(baseline))
    for key, line in sorted(dead.items()):
        path, kind, name = key.split("::")
        label = f"{path}:{line} {kind} {name} is never referenced"
        (res.known if key in baseline else res.new).append(label)
    stale = sorted(baseline - set(dead))
    if stale:
        res.warnings.append(
            f"{len(stale)} baselined entries are no longer dead (prune with --update-baseline): "
            + ", ".join(stale[:5])
        )
    kinds = Counter(k.split("::")[1] for k in dead)
    res.stats = {
        "definitions": len(defs),
        "dead": len(dead),
        "dead_by_kind": dict(sorted(kinds.items())),
        "new": len(res.new),
    }
    res.dead = dead  # type: ignore[attr-defined]
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    return common.report(run(Path(a.root), a.update_baseline), a.verbose)


if __name__ == "__main__":
    sys.exit(main())
