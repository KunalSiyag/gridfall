"""Tech debt markers: TODO, FIXME, HACK and XXX comments must link an issue.

usage: python3 tools/checks/todo_scan.py [--report debt.md] [--update-baseline] [files...]

Policy: write `TODO(#123): ...` (or FIXME/HACK/XXX, or a full issue URL in the parentheses).
Unlinked markers that predate the policy are in tools/checks/baselines/todo.json, counted per
(file, text); any other unlinked marker fails. --report writes a markdown debt report for the
CI job summary.
"""
from __future__ import annotations

import argparse
import io
import re
import sys
import tokenize
from collections import Counter
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "todo_scan"
BASELINE = "todo.json"
TAGS = ("TO" + "DO", "FIX" + "ME", "HA" + "CK", "X" + "XX")
MARK_RE = re.compile(r"\b(" + "|".join(TAGS) + r")\b(\((#\d+|https?://\S+/issues/\d+)\))?:?\s*(.*)")
PATTERNS = ("*.gd", "*.py", "*.sh", "*.gdshader", "*.yml", "*.yaml", "*.cfg", "Dockerfile")
EXCLUDE = ("tools/checks/baselines/**", "addons/**", "docs/api/**")


def comments(path: str, src: str) -> list[tuple[int, str]]:
    """(line, comment text) pairs; only comments are scanned, never code or strings."""
    if path.endswith(".gd"):
        return common.lex_gd(src).comments
    if path.endswith(".py"):
        out = []
        try:
            for tok in tokenize.generate_tokens(io.StringIO(src).readline):
                if tok.type == tokenize.COMMENT:
                    out.append((tok.start[0], tok.string))
            return out
        except (tokenize.TokenError, IndentationError, SyntaxError):
            pass
    marker = "//" if path.endswith(".gdshader") else "#"
    out = []
    for i, line in enumerate(src.split("\n"), 1):
        k = line.find(marker)
        if k >= 0:
            out.append((i, line[k:]))
    return out


def scan(root: Path, files: list[str]) -> list[dict]:
    items = []
    for f in files:
        for line, text in comments(f, common.read_text(root, f)):
            for m in MARK_RE.finditer(text):
                items.append(
                    {
                        "path": f,
                        "line": line,
                        "tag": m.group(1),
                        "issue": m.group(3) or "",
                        "text": " ".join(m.group(4).split())[:160],
                    }
                )
    return items


def key_of(item: dict) -> str:
    return f"{item['path']}::{item['tag']}: {item['text']}"


def markdown(items: list[dict]) -> str:
    tags = Counter(i["tag"] for i in items)
    linked = sum(1 for i in items if i["issue"])
    lines = [
        "## Tech debt",
        "",
        f"{len(items)} markers ({linked} linked to an issue, {len(items) - linked} unlinked): "
        + ", ".join(f"{t} {n}" for t, n in sorted(tags.items())),
        "",
    ]
    if items:
        areas = Counter("/".join(i["path"].split("/")[:2]) for i in items)
        lines += [common.markdown_table(["Area", "Markers"], sorted(areas.items(), key=lambda kv: -kv[1])), ""]
        rows = [[f"`{i['path']}:{i['line']}`", i["tag"], i["issue"] or "-", i["text"]] for i in items[:100]]
        lines += [common.markdown_table(["Where", "Tag", "Issue", "Text"], rows), ""]
    return "\n".join(lines)


def run(root: Path, files: list[str] | None = None, update: bool = False) -> common.Result:
    res = common.Result(NAME)
    all_files = common.list_files(root, PATTERNS, EXCLUDE)
    targets = sorted(set(files) & set(all_files)) if files is not None else all_files
    items = scan(root, targets)
    bpath = common.baseline_path(root, BASELINE)
    baseline: dict = common.load_json(bpath, {})
    unlinked = Counter(key_of(i) for i in items if not i["issue"])
    if update:
        if files is None:
            baseline = {}
        else:
            baseline = {k: v for k, v in baseline.items() if k.split("::")[0] not in set(targets)}
        baseline.update(unlinked)
        common.save_json(bpath, dict(sorted(baseline.items())))
    seen: Counter = Counter()
    for i in items:
        label = f"{i['path']}:{i['line']} {i['tag']}: {i['text']}"
        if i["issue"]:
            res.known.append(label + f" ({i['issue']})")
            continue
        k = key_of(i)
        seen[k] += 1
        if seen[k] > int(baseline.get(k, 0)):
            res.new.append(label + f" (link an issue: {i['tag']}(#123): ...)")
        else:
            res.known.append(label)
    res.stats = {
        "markers": len(items),
        "linked": sum(1 for i in items if i["issue"]),
        "unlinked": sum(1 for i in items if not i["issue"]),
        "by_tag": dict(sorted(Counter(i["tag"] for i in items).items())),
    }
    res.items = items  # type: ignore[attr-defined]
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--report", help="write a markdown debt report here")
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    res = run(Path(a.root), a.files or None, a.update_baseline)
    if a.report:
        Path(a.report).write_text(markdown(res.items) + "\n", encoding="utf-8")  # type: ignore[attr-defined]
    return common.report(res, a.verbose)


if __name__ == "__main__":
    sys.exit(main())
