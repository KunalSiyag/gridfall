"""Findings on a pull request's changed lines, as JSON for the PR review workflow.

usage: python3 tools/checks/pr_review.py --base REF [--out review.json] [--markdown FILE]

Runs gdlint, complexity, the TODO policy and dead code on the files changed since --base and
keeps what is new: gdlint findings and unlinked TODOs on added lines, functions over the
complexity threshold that are not baselined (or grew) and touch added lines, and new dead
definitions in changed files. Writes {"comments": [{path, line, body}], "summary": markdown,
"counts": {...}}; .github/workflows/pr-review.yml posts it with actions/github-script.
Exit 0 always (the CI checks job is the gate; this is advice on the diff).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common, complexity, dead_code, lint, todo_scan  # noqa: E402

MARKER = "<!-- gridfall-pr-review -->"


def review(root: Path, base: str | None, use_gdlint: bool = True) -> dict:
    added = common.added_lines(root, base)
    changed = sorted(added)
    gd = [f for f in changed if f.endswith(".gd")]
    comments: list[dict] = []
    notes: list[str] = []

    if use_gdlint and gd:
        for f in lint.run_gdlint(root, gd):
            if f["line"] in added.get(f["path"], set()):
                comments.append({"path": f["path"], "line": f["line"], "body": f"gdlint `{f['rule']}`: {f['msg']}"})

    cx = complexity.run(root, gd)
    baseline = common.load_json(common.baseline_path(root, complexity.BASELINE), {})
    for key, score in cx.scores.items():  # type: ignore[attr-defined]
        if score <= cx.stats["threshold"]:
            continue
        path = key.split("::")[0]
        start = cx.where[key]  # type: ignore[attr-defined]
        if start not in added.get(path, set()) and not _touches(root, path, start, added.get(path, set())):
            continue
        known = baseline.get(key)
        if known is not None and score <= int(known):
            continue
        what = "grew from " + str(known) if known is not None else f"is above the threshold of {cx.stats['threshold']}"
        comments.append(
            {
                "path": path,
                "line": start,
                "body": f"Cyclomatic complexity {score} ({complexity.grade(score)}) {what}. Consider splitting `{key.split('::', 1)[1]}`.",
            }
        )

    todo = todo_scan.run(root, changed)
    for item in todo.items:  # type: ignore[attr-defined]
        if not item["issue"] and item["line"] in added.get(item["path"], set()):
            comments.append(
                {"path": item["path"], "line": item["line"], "body": f"Unlinked `{item['tag']}`: reference an issue, e.g. `{item['tag']}(#123): ...`."}
            )

    dead = dead_code.run(root)
    for label in dead.new:
        path, rest = label.split(":", 1)
        line = int(rest.split(" ", 1)[0])
        if path in added:
            if line in added[path]:
                comments.append({"path": path, "line": line, "body": f"Dead code: {rest.split(' ', 1)[1]}."})
            else:
                notes.append(f"`{path}:{line}` {rest.split(' ', 1)[1]}")

    comments.sort(key=lambda c: (c["path"], c["line"]))
    counts = {"files": len(changed), "gd_files": len(gd), "comments": len(comments), "notes": len(notes)}
    lines = [MARKER, "## Automated review", ""]
    if not comments and not notes:
        lines.append(f"No new findings on the {len(changed)} changed files (gdlint, complexity, TODO policy, dead code).")
    else:
        lines.append(f"{len(comments)} findings on changed lines across {len(changed)} files.")
        lines.append("")
        lines += [f"- `{c['path']}:{c['line']}` {c['body']}" for c in comments[:50]]
        if notes:
            lines += ["", "Elsewhere in changed files:", ""] + [f"- {n}" for n in notes[:20]]
    lines += ["", "Run `python3 tools/checks/run_all.py` locally for the full set of checks."]
    return {"comments": comments, "summary": "\n".join(lines) + "\n", "counts": counts}


def _touches(root: Path, path: str, start: int, added: set[int]) -> bool:
    """True when an added line falls inside the function starting at start."""
    for fn in common.gd_functions(common.lex_gd(common.read_text(root, path))):
        if fn.start == start:
            return any(fn.start <= ln <= fn.end for ln in added)
    return False


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--base", required=True)
    ap.add_argument("--out", default="review.json")
    ap.add_argument("--markdown")
    ap.add_argument("--no-gdlint", action="store_true")
    a = ap.parse_args(argv)
    data = review(Path(a.root), a.base, not a.no_gdlint)
    Path(a.out).write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
    if a.markdown:
        with open(a.markdown, "a", encoding="utf-8") as fh:
            fh.write(data["summary"])
    print(data["summary"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
