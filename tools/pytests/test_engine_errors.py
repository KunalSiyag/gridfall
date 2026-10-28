from pathlib import Path

import pytest

from tools.checks import engine_errors


def write_log(tmp_path: Path, *lines: str) -> Path:
    log = tmp_path / "step.log"
    log.write_text("\n".join(lines) + "\n")
    return log


def write_allowlist(tmp_path: Path, *lines: str) -> Path:
    path = tmp_path / "engine_errors.txt"
    path.write_text("\n".join(lines) + "\n")
    return path


def test_error_lines_finds_engine_and_user_errors_only(tmp_path):
    log = write_log(
        tmp_path,
        "Godot Engine v4.7.2",
        "ERROR: 40 resources still in use at exit.",
        "   at: cleanup (core/object/object.cpp:2536)",
        "USER ERROR: get_meta: key missing",
        "SCRIPT ERROR: already caught by the gate",
        "   ERROR: indented continuations do not count",
        "WARNING: not an error",
    )
    assert engine_errors.error_lines(log) == [
        "40 resources still in use at exit.",
        "get_meta: key missing",
    ]


def test_load_allowlist_parses_entries_and_comments(tmp_path):
    path = write_allowlist(
        tmp_path,
        "# seeded from the 2026-10-28 gate quick run",
        "",
        "substr|resources still in use at exit|dummy renderer shutdown noise",
        "regex|RID allocations of type '.+' were leaked at exit|same noise, varying type",
    )
    assert engine_errors.load_allowlist(path) == [
        ("substr", "resources still in use at exit", "dummy renderer shutdown noise"),
        ("regex", "RID allocations of type '.+' were leaked at exit", "same noise, varying type"),
    ]


@pytest.mark.parametrize(
    "line",
    [
        "no pipes at all",
        "substr|missing reason|",
        "regex||no pattern",
        "kind|text|reason",
        "substr|text",
        "regex|(|bad regex",
    ],
)
def test_load_allowlist_rejects_malformed_lines(tmp_path, line):
    path = write_allowlist(tmp_path, line)
    with pytest.raises(SystemExit):
        engine_errors.load_allowlist(path)


def test_covered_by_substr_and_regex(tmp_path):
    allowlist = [
        ("substr", "resources still in use", "shutdown noise"),
        ("regex", r"leaked at exit", "shutdown noise"),
    ]
    assert engine_errors.covered("40 resources still in use at exit.", allowlist)
    assert engine_errors.covered("5 RID allocations were leaked at exit.", allowlist)
    assert not engine_errors.covered("get_meta: key missing", allowlist)


def test_main_passes_when_every_error_is_allowlisted(tmp_path, monkeypatch):
    log = write_log(tmp_path, "ERROR: 40 resources still in use at exit.")
    monkeypatch.setattr(engine_errors, "BASELINE", write_allowlist(tmp_path, "substr|resources still in use|noise"))
    assert engine_errors.main([str(log)]) == 0


def test_main_fails_on_a_new_engine_error(tmp_path, capsys):
    log = write_log(
        tmp_path,
        "ERROR: Condition \"body == nullptr\" is true.",
        "ERROR: Condition \"body == nullptr\" is true.",
        "ERROR: 40 resources still in use at exit.",
    )
    allowlist = tmp_path / "engine_errors.txt"
    allowlist.write_text("substr|resources still in use|noise\n")
    import tools.checks.engine_errors as ee

    old = ee.BASELINE
    ee.BASELINE = allowlist
    try:
        assert ee.main([str(log)]) == 1
    finally:
        ee.BASELINE = old
    err = capsys.readouterr().err
    assert "engine error x2" in err
    assert "body == nullptr" in err
    assert "resources still in use" not in err


def test_main_collect_reports_counts_sorted(tmp_path, capsys):
    log = write_log(tmp_path, "ERROR: b", "ERROR: a", "ERROR: b", "USER ERROR: b")
    assert engine_errors.main(["--collect", str(log)]) == 0
    out = capsys.readouterr().out.splitlines()
    assert out[0].endswith("3  b")
    assert out[1].endswith("1  a")


def test_main_without_logs_is_a_usage_error():
    assert engine_errors.main([]) == 2


def test_missing_allowlist_means_nothing_is_covered(tmp_path, capsys):
    log = write_log(tmp_path, "ERROR: something")
    import tools.checks.engine_errors as ee

    old = ee.BASELINE
    ee.BASELINE = tmp_path / "absent.txt"
    try:
        assert ee.main([str(log)]) == 1
    finally:
        ee.BASELINE = old
    assert "something" in capsys.readouterr().err
