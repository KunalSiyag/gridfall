"""Tests for tools/ops (error-to-issue pipeline and analytics report). Runs under pytest or
`python3 -m unittest tools/pytests/test_ops_reports.py`."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.ops import analytics_report, common, errors_to_issues  # noqa: E402


def _write_jsonl(path: Path, records: list) -> None:
    with path.open("w", encoding="utf-8") as fh:
        for r in records:
            fh.write((r if isinstance(r, str) else json.dumps(r)) + "\n")


def _err(fp: str, ts: float, occ: int = 1, session: str = "s1", **kw) -> dict:
    rec = {"fingerprint": fp, "ts": ts, "occurrence": occ, "session": session, "type": "error",
           "message": f"boom {fp}", "function": "_process", "file": "res://scripts/x.gd", "line": 7,
           "build": "dev godot-4.7.2 Linux", "context": {"day": int(ts)}, "breadcrumbs": [f"crumb {ts}"]}
    rec.update(kw)
    return rec


class FakeGh:
    def __init__(self, existing: list | None = None):
        self.calls: list[list[str]] = []
        self.existing = existing or []

    def __call__(self, cmd: list[str]) -> subprocess.CompletedProcess:
        self.calls.append(cmd)
        out = json.dumps(self.existing) if cmd[:3] == ["gh", "issue", "list"] else "https://github.com/x/y/issues/9"
        return subprocess.CompletedProcess(cmd, 0, stdout=out, stderr="")


class CommonTest(unittest.TestCase):
    def test_user_data_dir_from_project_name(self):
        with tempfile.TemporaryDirectory() as d:
            proj = Path(d) / "project.godot"
            proj.write_text('[application]\n\nconfig/name="Grid: Fall?"\n', encoding="utf-8")
            got = common.user_data_dir(proj, {"XDG_DATA_HOME": "/x", "HOME": "/h"})
            self.assertEqual(got, Path("/x/godot/app_userdata/Grid_ Fall_"))
            got = common.user_data_dir(proj, {"HOME": "/h"})
            self.assertEqual(got, Path("/h/.local/share/godot/app_userdata/Grid_ Fall_"))

    def test_custom_user_dir(self):
        with tempfile.TemporaryDirectory() as d:
            proj = Path(d) / "project.godot"
            proj.write_text('[application]\nconfig/name="G"\nconfig/use_custom_user_dir=true\n'
                            'config/custom_user_dir_name="gridfall"\n', encoding="utf-8")
            self.assertEqual(common.user_data_dir(proj, {"XDG_DATA_HOME": "/x"}), Path("/x/gridfall"))

    def test_repo_project_resolves(self):
        path = common.default_ops_file("errors.jsonl", {"XDG_DATA_HOME": "/x"})
        self.assertEqual(path.parts[:4], ("/", "x", "godot", "app_userdata"))
        self.assertEqual(path.name, "errors.jsonl")

    def test_iter_jsonl_skips_bad_lines_and_reads_rotated_first(self):
        with tempfile.TemporaryDirectory() as d:
            live = Path(d) / "errors.jsonl"
            _write_jsonl(Path(d) / "errors.1.jsonl", [{"n": 1}])
            _write_jsonl(live, ["not json", "[1, 2]", {"n": 2}, ""])
            self.assertEqual([r["n"] for r in common.iter_jsonl(live)], [1, 2])
            self.assertEqual([r["n"] for r in common.iter_jsonl(live, include_rotated=False)], [2])
            self.assertEqual(list(common.iter_jsonl(Path(d) / "missing.jsonl")), [])


class ErrorsToIssuesTest(unittest.TestCase):
    def records(self):
        return [
            _err("aaaa", 100.0, 1), _err("aaaa", 300.0, 30, context={"day": 9}),
            _err("aaaa", 200.0, 2, session="s2"),
            _err("bbbb", 150.0, 1, type="warning"),
            {"message": "no fingerprint"},
        ]

    def test_group_counts_first_last_and_latest_context(self):
        groups = errors_to_issues.group_errors(self.records())
        self.assertEqual([g["fingerprint"] for g in groups], ["aaaa", "bbbb"])
        a = groups[0]
        self.assertEqual(a["count"], 32)  # occurrence 30 in s1 + 2 in s2
        self.assertEqual(a["written"], 3)
        self.assertEqual(a["session_count"], 2)
        self.assertEqual((a["first_seen"], a["last_seen"]), (100.0, 300.0))
        self.assertEqual(a["context"], {"day": 9})
        self.assertEqual(a["breadcrumbs"], ["crumb 300.0"])
        self.assertEqual(groups[1]["type"], "warning")

    def test_report_lists_every_fingerprint(self):
        groups = errors_to_issues.group_errors(self.records())
        md = errors_to_issues.render_report(groups, "x.jsonl")
        self.assertIn("2 distinct error(s), 33 occurrence(s)", md)
        self.assertIn("`aaaa`", md)
        self.assertIn("crumb 300.0", md)
        self.assertIn("No errors recorded.", errors_to_issues.render_report([]))

    def test_issue_body_has_dedupe_marker(self):
        g = errors_to_issues.group_errors(self.records())[0]
        self.assertIn(f"<!-- {errors_to_issues.MARKER} aaaa -->", errors_to_issues.issue_body(g))
        self.assertTrue(errors_to_issues.issue_title(g).startswith("[error-tracker] boom aaaa"))

    def test_plan_creates_with_labels_or_comments_on_existing(self):
        groups = errors_to_issues.group_errors(self.records())
        gh = FakeGh(existing=[{"number": 5, "body": f"x <!-- {errors_to_issues.MARKER} aaaa -->"}])
        cmds = errors_to_issues.plan_issue_commands(groups, gh)
        self.assertEqual(cmds[0][:4], ["gh", "issue", "comment", "5"])
        self.assertEqual(cmds[1][:3], ["gh", "issue", "create"])
        self.assertEqual([cmds[1][i + 1] for i, a in enumerate(cmds[1]) if a == "--label"], ["bug", "from-error-tracker"])
        self.assertEqual(sum(1 for c in gh.calls if c[2] == "list"), 2)
        self.assertEqual(len(errors_to_issues.plan_issue_commands(groups, None, min_count=10)), 1)

    def test_main_dry_run_never_calls_gh(self):
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / "errors.jsonl"
            out = Path(d) / "report.md"
            _write_jsonl(src, self.records())
            gh = FakeGh()
            self.assertEqual(errors_to_issues.main([str(src), "--out", str(out), "--create-issues"], run=gh), 0)
            self.assertEqual(gh.calls, [])
            self.assertIn("# GridFall error report", out.read_text(encoding="utf-8"))

    def test_main_no_dry_run_runs_gh(self):
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / "errors.jsonl"
            _write_jsonl(src, self.records())
            gh = FakeGh()
            rc = errors_to_issues.main([str(src), "--out", str(Path(d) / "r.md"), "--create-issues", "--no-dry-run"], run=gh)
            self.assertEqual(rc, 0)
            self.assertEqual([c[2] for c in gh.calls], ["list", "list", "create", "create"])


class AnalyticsReportTest(unittest.TestCase):
    def records(self):
        def ev(session, seq, event, **props):
            return {"session": session, "seq": seq, "event": event, "props": props, "uptime_s": seq * 10.0}
        return [
            ev("s1", 1, "session_start"), ev("s1", 2, "enter_fp"), ev("s1", 3, "overview_open"),
            ev("s1", 4, "site_walk"), ev("s1", 5, "session_end", secs=120.0),
            ev("s2", 1, "session_start"), ev("s2", 2, "overview_open"), ev("s2", 3, "enter_fp"),
            ev("s3", 2, "enter_fp"), ev("s3", 1, "session_start"),
            {"event": ""},
        ]

    def test_summary_counts_and_ordered_funnel(self):
        s = analytics_report.summarize(self.records())
        self.assertEqual(s["events"], 10)
        self.assertEqual(s["sessions"], 3)
        self.assertEqual(s["by_event"]["enter_fp"], 3)
        self.assertEqual([f["sessions"] for f in s["funnel"]], [3, 3, 1, 1])
        self.assertAlmostEqual(s["funnel"][2]["rate"], 0.333)
        self.assertAlmostEqual(s["avg_session_s"], round((120.0 + 30.0 + 20.0) / 3, 1))

    def test_empty_input(self):
        s = analytics_report.summarize([])
        self.assertEqual((s["events"], s["sessions"], s["avg_session_s"]), (0, 0, 0.0))
        self.assertEqual([f["rate"] for f in s["funnel"]], [0.0] * 4)

    def test_main_markdown_and_json(self):
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / "analytics.jsonl"
            _write_jsonl(src, self.records())
            self.assertEqual(analytics_report.main([str(src), "--json"]), 0)
            md = analytics_report.render_markdown(analytics_report.summarize(self.records()))
            self.assertIn("| site_walk | 1 | 33% |", md)


if __name__ == "__main__":
    unittest.main()
