"""tools/web_measure.py: the frame budget restated in busy ms and display Hz (offline, no browser)."""
import json

import pytest

from tools import web_measure as wm


def test_vsync_period_and_snap_to_the_next_boundary():
    assert wm.vsync_ms(60) == pytest.approx(16.667, abs=1e-3)
    assert wm.vsync_ms(144) == pytest.approx(6.944, abs=1e-3)
    # The reference case of the backlog: 34 ms busy shows 20 fps on 60 Hz, 31 ms shows 30.
    assert wm.snap_interval(34, 60) == pytest.approx(50.0)
    assert wm.snap_interval(31, 60) == pytest.approx(33.333, abs=1e-3)
    # Busy exactly on a boundary stays on it; anything above the floor shows at least one period.
    assert wm.snap_interval(2 * wm.vsync_ms(60), 60) == pytest.approx(33.333, abs=1e-3)
    assert wm.snap_interval(0.2, 144) == pytest.approx(6.944, abs=1e-3)


def test_cut_to_step_is_the_distance_above_the_previous_boundary():
    assert wm.cut_to_step(34, 60) == pytest.approx(0.667, abs=1e-3)
    assert wm.cut_to_step(31, 60) == pytest.approx(14.333, abs=1e-3)
    assert wm.cut_to_step(10, 60) == 0.0  # already on the first vsync: nothing to step down to


def test_whole_vsyncs_accepts_the_droids_rounded_percentiles_and_rejects_means():
    assert wm.whole_vsyncs(13.9, 144) == 2
    assert wm.whole_vsyncs(41.7, 144) == 6
    assert wm.whole_vsyncs(62.5, 144) == 9
    assert wm.whole_vsyncs(24.7, 144) is None  # 3.56 periods
    assert wm.whole_vsyncs(2.0, 144) is None  # less than one period
    assert wm.whole_vsyncs(0.0, 60) is None


def test_busy_bounds_use_the_exact_multiple_when_locked():
    low, high = wm.busy_bounds(41.7, 144)
    # 41.7 is a rounded 6 x 6.944: the bound is the exact 41.667, not the rounded value.
    assert (low, high) == (pytest.approx(34.722, abs=1e-3), pytest.approx(41.667, abs=1e-3))
    # An interval that is not a whole number of periods is only bounded by itself and one period.
    low, high = wm.busy_bounds(24.7, 144)
    assert (low, high) == (pytest.approx(24.7 - 6.944, abs=1e-3), 24.7)
    assert wm.busy_bounds(3.0, 144)[0] == 0.0


def test_step_segments_split_a_range_at_the_vsync_boundaries():
    one = wm.step_segments(34.722, 41.667, 60)
    assert [k for k, _, _ in one] == [3]
    assert one[0][1:] == (pytest.approx(34.722), pytest.approx(41.667))
    two = wm.step_segments(48.611, 55.556, 60)  # straddles 50 ms
    assert [k for k, _, _ in two] == [3, 4]
    assert two[0][2] == pytest.approx(50.0) and two[1][1] == pytest.approx(50.0)
    first = wm.step_segments(0.0, 5.0, 60)
    assert [k for k, _, _ in first] == [1]


def test_merge_ranges_joins_overlaps_and_touches_only():
    assert wm.merge_ranges([[3.0, 4.0], [0.0, 1.0], [0.5, 2.0]]) == [[0.0, 2.0], [3.0, 4.0]]
    assert wm.merge_ranges([[0.0, 1.0], [1.0, 2.0]]) == [[0.0, 2.0]]
    assert wm.merge_ranges([]) == []


def test_restate_row_day10_street_on_60hz_needs_between_1_and_8_ms_for_a_step():
    row = wm.restate_row("day-10 street, p50", 41.7, 144, 60)
    assert row["locked"] is True and row["vsyncs"] == pytest.approx(6.0, abs=0.01)
    assert row["busy_ms"] == [34.7, 41.7]
    assert row["target_interval_ms"] == [50.0] and row["target_fps"] == [20.0]
    assert row["cut_ms"] == [[1.4, 8.3]]
    # The same busy time on a 120 Hz display lands on 5 vsyncs exactly: 24 fps, not two values.
    again = wm.restate_row("day-10 street, p50", 41.7, 144, 120)
    assert again["target_interval_ms"] == [41.7] and again["target_fps"] == [24.0]


def test_restate_row_that_straddles_a_boundary_reports_both_pieces():
    row = wm.restate_row("street_tick", 56.2, 144, 60)  # busy in (48.6, 55.6]: 3 or 4 vsyncs
    assert row["locked"] is True
    assert row["target_interval_ms"] == [50.0, 66.7] and row["target_fps"] == [15.0, 20.0]
    # Just over 50 ms needs under 5.6 ms off; just under it needs 15.3 to 16.7 ms.
    assert row["cut_ms"] == [[0.0, 5.6], [15.3, 16.7]]


def test_restate_row_on_the_first_vsync_has_nothing_to_cut():
    row = wm.restate_row("day-1 street, p50", 13.9, 144, 60)
    assert row["target_interval_ms"] == [16.7] and row["target_fps"] == [60.0]
    assert row["cut_ms"] == [[0.0, 0.0]]
    # A faster display splits the same busy range over two vsync counts.
    fast = wm.restate_row("day-1 street, p50", 13.9, 144, 120)
    assert fast["target_fps"] == [60.0, 120.0] and fast["cut_ms"] == [[0.0, 5.6]]


def test_unlocked_rows_are_flagged_and_only_bounded():
    row = wm.restate_row("quiet street, p50", 24.7, 144, 60)
    assert row["locked"] is False
    assert row["busy_ms"] == [17.8, 24.7]
    assert row["target_interval_ms"] == [33.3] and row["cut_ms"] == [[1.1, 8.0]]


def test_budget_table_has_every_row_for_every_target_and_keeps_where():
    rows = wm.budget_table((60.0, 120.0))
    assert len(rows) == 2 * len(wm.BUDGET_ROWS)
    assert {r["target_hz"] for r in rows} == {60.0, 120.0}
    assert all(r["where"] for r in rows)
    live = [r for r in rows if r["name"] == "day-10 street, p50" and r["target_hz"] == 60.0]
    assert live and live[0]["target_fps"] == [20.0]
    assert wm.budget_table((60.0,), source_hz=60.0)[0]["source_hz"] == 60.0


def test_shown_fps_is_one_rate_or_the_rates_either_side_of_a_boundary():
    assert wm.shown_fps(50.2, 57.1, 60) == [15.0]
    assert wm.shown_fps(43.6, 50.5, 60) == [15.0, 20.0]  # 50 ms is inside the range
    assert wm.shown_fps(0.0, 0.0, 60) == [60.0]


def test_the_lane_table_adds_up_to_the_frame_it_splits():
    assert sum(ms for _, ms in wm.LANES) == pytest.approx(wm.LANE_FRAME_MS, abs=0.2)
    assert {name for name in wm.IN_FLIGHT_LANES} <= {name for name, _ in wm.LANES}


def test_lane_table_takes_each_lane_off_the_frames_busy_range():
    rows = {r["lane"]: r for r in wm.lane_table((60.0, 120.0, 144.0))}
    frame = rows["frame as measured"]
    assert frame["ms"] == 57.1 and frame["share_pct"] == 100.0 and frame["busy_ms"] == [50.2, 57.1]
    assert frame["fps"] == {"60": [15.0], "120": [17.1], "144": [16.0, 18.0]}
    # 13 ms of render CPU is the one CPU lane that steps a 60 Hz display by itself (15 -> 20 fps).
    assert rows["render CPU"]["fps"]["60"] == [20.0]
    assert rows["engine/browser floor (residual)"]["fps"]["60"] == [30.0]
    # A lane of a few ms may or may not cross the 50 ms boundary: both rates, never one of them.
    assert rows["traffic_feature"]["fps"]["60"] == [15.0, 20.0]
    assert rows["physics frames"]["fps"] == frame["fps"]
    flight = next(r for name, r in rows.items() if name.startswith("in-flight lanes"))
    assert flight["ms"] == 6.6 and flight["share_pct"] == 11.6 and flight["fps"]["60"] == [15.0, 20.0]


def test_lane_table_follows_the_frame_and_the_display_it_was_measured_on():
    fast = {r["lane"]: r for r in wm.lane_table((60.0,), frame_ms=13.9, source_hz=144)}
    assert fast["frame as measured"]["fps"] == {"60": [60.0]}
    assert fast["render CPU"]["busy_ms"] == [0.0, 0.9]  # 13.9 is two 144 Hz vsyncs: (6.9, 13.9] - 13.0
    assert wm.lane_table((60.0,), source_hz=60)[0]["busy_ms"] == [40.4, 57.1]  # one 60 Hz period wide


def probe_result(**over):
    result = {
        "env": {"display_hz": {"nominal": 60, "hz": 60.2}},
        "street": {"p50_ms": 33.3, "p95_ms": 50.0, "busy_ms": {"p50": 20.0}},
        "orbit": {"p50_ms": 16.7},
    }
    result.update(over)
    return result


def test_probe_rows_restate_the_measured_rows_at_the_measured_display_rate():
    rows = wm.probe_rows(probe_result(), (120.0,))
    names = [r["name"] for r in rows]
    assert names == ["street p50", "street p95", "street measured busy p50", "orbit p50"]
    p50 = rows[0]
    assert p50["source_hz"] == 60.0 and p50["busy_ms"] == [16.7, 33.3]
    assert p50["target_fps"] == [30.0, 40.0]
    busy = rows[2]
    assert busy["busy_ms"] == [20.0, 20.0] and busy["target_interval_ms"] == [25.0]
    assert busy["target_fps"] == [40.0] and busy["cut_ms"] == [[3.3, 3.3]]
    assert busy["where"] == "rAF callback time"


def test_probe_rows_fall_back_to_the_droids_display_and_skip_missing_rows():
    rows = wm.probe_rows({"street": {"p50_ms": 13.9}, "sky": None}, (60.0,))
    assert [r["name"] for r in rows] == ["street p50"]
    assert rows[0]["source_hz"] == wm.DROID_HZ
    assert wm.probe_rows({}, (60.0,)) == []


def test_format_table_has_a_header_the_rows_and_both_footnotes():
    text = wm.format_table(wm.budget_table((60.0,)))
    lines = text.splitlines()
    assert lines[0].startswith("row") and "cut for a step" in lines[0]
    assert set(lines[1]) == {"-"}
    row = next(line for line in lines if line.startswith("day-10 street, p50"))
    assert "50" in row and "20" in row and "1.4-8.3 ms" in row and "live 23.4 fps" in row
    straddle = next(line for line in lines if line.startswith("day-10 street_tick"))
    assert "0-5.6 | 15.3-16.7 ms" in straddle
    unlocked = next(line for line in lines if line.startswith("quiet street, p50"))
    assert "3.56?" in unlocked
    assert lines[-2].startswith("busy = ") and lines[-1].startswith("cut for a step = ")


def test_main_budget_prints_the_table_or_json(capsys):
    wm.main(["--budget", "--hz", "60"])
    out = capsys.readouterr().out
    assert out.startswith("row") and "day-10 street, p50" in out
    wm.main(["--budget", "--json", "--hz", "60", "--hz", "120"])
    rows = json.loads(capsys.readouterr().out)
    assert len(rows) == 2 * len(wm.BUDGET_ROWS)


def test_main_source_hz_changes_how_the_rows_are_read(capsys):
    wm.main(["--budget", "--json", "--hz", "60", "--source-hz", "60"])
    row = json.loads(capsys.readouterr().out)[0]
    assert row["source_hz"] == 60.0


def test_main_probe_report_reads_a_result_file(tmp_path, capsys):
    path = tmp_path / "result.json"
    path.write_text(json.dumps(probe_result()), encoding="utf-8")
    wm.main(["--probe-report", str(path), "--hz", "60"])
    out = capsys.readouterr().out
    assert "street p50" in out and "orbit p50" in out and "street measured busy p50" in out


def test_main_needs_a_url_unless_a_report_mode_is_asked_for(capsys):
    with pytest.raises(SystemExit) as raised:
        wm.main([])
    assert raised.value.code == 2
    assert "url is required" in capsys.readouterr().err


def test_main_headers_only_still_checks_the_url_and_fails_on_an_error_row(monkeypatch, capsys):
    rows = [{"path": "/", "accept": "br", "status": 200, "encoding": "br", "cache": "no-cache", "coop": "", "coep": ""}]
    monkeypatch.setattr(wm, "header_report", lambda base: rows)
    wm.main(["http://127.0.0.1:1/", "--headers-only"])
    assert "per-file encoding" in capsys.readouterr().out
    monkeypatch.setattr(wm, "header_report", lambda base: [{"path": "/", "accept": "br", "error": "boom"}])
    with pytest.raises(SystemExit) as raised:
        wm.main(["http://127.0.0.1:1/", "--headers-only"])
    assert raised.value.code == 1


def test_format_lanes_has_a_header_the_rows_and_both_footnotes():
    lines = wm.format_lanes(wm.lane_table((60.0,)), (60.0,)).splitlines()
    assert lines[0].startswith("lane") and "60Hz" in lines[0]
    frame = next(line for line in lines if line.startswith("frame as measured"))
    assert "57.1" in frame and "100%" in frame and "50.2-57.1" in frame
    render = next(line for line in lines if line.startswith("render CPU"))
    assert render.rstrip().endswith(" 20")
    traffic = next(line for line in lines if line.startswith("traffic_feature"))
    assert traffic.rstrip().endswith("15-20")
    assert lines[-2].startswith("fps = ") and lines[-1].startswith("A percentile")


def test_main_lanes_prints_the_table_or_json(capsys):
    wm.main(["--lanes"])
    out = capsys.readouterr().out
    assert out.startswith("lane") and "144Hz" in out
    wm.main(["--lanes", "--json", "--hz", "60"])
    rows = json.loads(capsys.readouterr().out)
    assert len(rows) == len(wm.LANES) + 2 and set(rows[0]["fps"]) == {"60"}


# The droid's rows, copied from docs/round4/web-perf-budget.md (its live post-deploy numbers, bench rows
# and early table): a slip in BUDGET_ROWS would restate a measurement that was never taken.
DROID_ROWS = [
    ("day-1 street, p50", 13.9),
    ("day-10 street, p50", 41.7),
    ("day-10 street, p95", 62.5),
    ("day-10 street_tick, p50", 56.2),
    ("day-10 street_day_end, p50", 61.0),
    ("quiet street, p50", 24.7),
    ("quiet street, p90", 32.7),
    ("orbit, p50", 22.9),
    ("orbit, p90", 37.7),
    ("busier street, p50", 43.0),
    ("busier street, p90", 101.0),
]
DROID_LANES = {
    "render CPU": 13.0, "traffic_feature": 3.5, "sim slice + CitySim wrapper": 3.8, "animals_feature": 1.6,
    "Weather": 1.5, "audio_feature": 1.2, "CityView": 1.1, "physics frames": 0.0, "everything else": 1.5,
    "engine/browser floor (residual)": 30.0,
}


def test_the_budget_rows_and_lanes_are_the_droids_numbers():
    assert [(name, ms) for name, ms, _ in wm.BUDGET_ROWS] == DROID_ROWS
    assert dict(wm.LANES) == DROID_LANES
    assert wm.LANE_FRAME_MS == 57.1 and wm.DROID_HZ == 144.0
    assert wm.IN_FLIGHT_LANES == ("traffic_feature", "animals_feature", "Weather")


def test_the_default_displays_are_the_ones_the_backlog_names():
    assert wm.DEFAULT_TARGETS == (60.0, 120.0)
    assert wm.LANE_TARGETS == (60.0, 120.0, 144.0)
    assert {r["target_hz"] for r in wm.budget_table()} == {60.0, 120.0}
    assert set(wm.lane_table()[0]["fps"]) == {"60", "120", "144"}


def test_main_source_hz_also_changes_the_lanes(capsys):
    wm.main(["--lanes", "--json", "--hz", "60", "--source-hz", "60"])
    rows = json.loads(capsys.readouterr().out)
    assert rows[0]["busy_ms"] == [40.4, 57.1]  # one 60 Hz period wide, as lane_table(source_hz=60)
    wm.main(["--lanes", "--json", "--hz", "60"])
    assert json.loads(capsys.readouterr().out)[0]["busy_ms"] != [40.4, 57.1], "the default is the droid's 144 Hz"


def test_probe_source_hz_says_where_the_rate_came_from():
    assert wm.probe_source_hz(probe_result()) == (60.0, "measured by the probe (nominal)")
    assert wm.probe_source_hz({"env": {"display_hz": {"nominal": None, "hz": 59.8}}}) == (59.8, "measured by the probe (hz)")
    rate, how = wm.probe_source_hz({"env": {"display_hz": None}})
    assert rate == wm.DROID_HZ and how.startswith("ASSUMED")
    assert wm.probe_source_hz(probe_result(), 120.0) == (120.0, "--source-hz")
    assert wm.probe_source_hz({}, 75.0)[0] == 75.0


def test_probe_rows_use_the_source_rate_given_and_say_when_it_is_assumed():
    # The reviewer's case: no display_hz in the result, a 33.3 ms median that is 2 vsyncs at 60 Hz.
    result = {"env": {"display_hz": None}, "street": {"p50_ms": 33.3}}
    assumed = wm.probe_rows(result, (60.0,))[0]
    assert assumed["source_hz"] == wm.DROID_HZ and assumed["where"] == "probe 144 Hz ASSUMED"
    given = wm.probe_rows(result, (60.0,), source_hz=60.0)[0]
    assert given["source_hz"] == 60.0 and given["where"] == "probe 60 Hz"
    assert given["locked"] is True and given["busy_ms"] == [16.7, 33.3]
    assert given["cut_ms"] == [[0.0, 16.7]]
    assert wm.probe_rows(probe_result(), (60.0,))[0]["where"] == "probe 60 Hz"


def test_probe_notes_name_the_rate_a_software_renderer_and_an_unknown_layout():
    notes = wm.probe_notes(probe_result(schema=wm.PROBE_SCHEMA, hardware=True))
    assert notes == ["display rate of the measured intervals: 60 Hz (measured by the probe (nominal))"]
    soft = wm.probe_notes(probe_result(schema=wm.PROBE_SCHEMA, hardware=False, renderer="ANGLE (Google, SwiftShader)"))
    assert any("software renderer (ANGLE (Google, SwiftShader))" in n and "do not transfer" in n for n in soft)
    assert any("no schema field" in n for n in wm.probe_notes(probe_result()))
    assert any(f"schema 9, this reader knows {wm.PROBE_SCHEMA}" in n for n in wm.probe_notes(probe_result(schema=9)))
    assumed = wm.probe_notes({"schema": wm.PROBE_SCHEMA})
    assert any("ASSUMED" in n and "144" in n for n in assumed)
    assert any("--source-hz" in n for n in wm.probe_notes(probe_result(schema=wm.PROBE_SCHEMA), 75.0))


def test_main_probe_report_prints_its_notes_and_keeps_json_clean(tmp_path, capsys):
    path = tmp_path / "result.json"
    path.write_text(json.dumps(probe_result(hardware=False, renderer="SwiftShader")), encoding="utf-8")
    wm.main(["--probe-report", str(path), "--hz", "60", "--source-hz", "60"])
    out = capsys.readouterr().out
    assert out.startswith("NOTE: display rate of the measured intervals: 60 Hz (--source-hz)")
    assert "NOTE: software renderer (SwiftShader)" in out and "street p50" in out
    wm.main(["--probe-report", str(path), "--hz", "60", "--json"])
    captured = capsys.readouterr()
    assert json.loads(captured.out)[0]["name"] == "street p50", "stdout is only the rows"
    assert "NOTE: software renderer" in captured.err
