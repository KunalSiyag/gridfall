"""Summarises GridFall's local product analytics (user://ops/analytics.jsonl, written by
scripts/ops/analytics.gd when GRIDFALL_ANALYTICS=1 or the analytics flag is on): events per type,
sessions and their length, and the onboarding funnel session_start -> enter_fp -> overview_open ->
site_walk (share of sessions reaching each step, in order).

    python3 tools/ops/analytics_report.py [analytics.jsonl] [--json]
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Iterable, Sequence

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.ops.common import default_ops_file, iter_jsonl  # noqa: E402

FUNNEL = ("session_start", "enter_fp", "overview_open", "site_walk")


def summarize(records: Iterable[dict], funnel: Sequence[str] = FUNNEL) -> dict:
    """{"events": total, "by_event": {event: n}, "sessions": n, "avg_session_s": float,
    "funnel": [{"step", "sessions", "rate"}]}. A session reaches a step when the step's event
    follows the previous step's (by seq)."""
    by_event: Counter[str] = Counter()
    sessions: dict[str, list[dict]] = {}
    total = 0
    for rec in records:
        event = str(rec.get("event") or "")
        if not event:
            continue
        total += 1
        by_event[event] += 1
        sessions.setdefault(str(rec.get("session") or "?"), []).append(rec)
    lengths = []
    reached = [0] * len(funnel)
    for recs in sessions.values():
        recs.sort(key=lambda r: int(r.get("seq") or 0))
        ends = [float(r.get("props", {}).get("secs", 0) or 0) for r in recs if r.get("event") == "session_end"]
        uptime = max((float(r.get("uptime_s") or 0) for r in recs), default=0.0)
        lengths.append(max(ends + [uptime]))
        step = 0
        for r in recs:
            if step < len(funnel) and r.get("event") == funnel[step]:
                reached[step] += 1
                step += 1
    base = reached[0] if reached else 0
    return {
        "events": total,
        "by_event": dict(by_event.most_common()),
        "sessions": len(sessions),
        "avg_session_s": round(sum(lengths) / len(lengths), 1) if lengths else 0.0,
        "funnel": [{"step": s, "sessions": n, "rate": round(n / base, 3) if base else 0.0}
                   for s, n in zip(funnel, reached)],
    }


def render_markdown(summary: dict, source: str = "") -> str:
    out = ["# GridFall analytics report", ""]
    if source:
        out.append(f"Source: `{source}`")
    out += [f"{summary['events']} event(s) in {summary['sessions']} session(s); "
            f"average session {summary['avg_session_s']} s.", "", "## Events", "", "| Event | Count |", "|---|---|"]
    out += [f"| {e} | {n} |" for e, n in summary["by_event"].items()]
    out += ["", "## Funnel", "", "| Step | Sessions | Of started |", "|---|---|---|"]
    out += [f"| {f['step']} | {f['sessions']} | {f['rate'] * 100:.0f}% |" for f in summary["funnel"]]
    return "\n".join(out) + "\n"


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("path", nargs="?", help="analytics.jsonl (default: this project's user://ops/analytics.jsonl)")
    ap.add_argument("--json", action="store_true", help="print the summary as JSON")
    args = ap.parse_args(list(argv) if argv is not None else None)
    path = Path(args.path) if args.path else default_ops_file("analytics.jsonl")
    summary = summarize(iter_jsonl(path))
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        sys.stdout.write(render_markdown(summary, str(path)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
