"""The browser probe kit (tools/web_probe_kit.js, tools/web_fps_probe.js): its offline node tests run
under pytest, and the probe's header and the runbook name every env knob the kit reads."""
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
KIT = ROOT / "tools/web_probe_kit.js"
PROBE = ROOT / "tools/web_fps_probe.js"
RUNBOOK = ROOT / "docs/runbooks/web-probe-kit.md"
needs_node = pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")


def knobs_read() -> set[str]:
    """The GF_FPS_* variables parseKnobs() reads from the environment."""
    return set(re.findall(r"env\.(GF_FPS_[A-Z_]+)", KIT.read_text(encoding="utf-8")))


@needs_node
def test_probe_kit_node_tests_pass():
    # The TAP reporter is named, not left to node's default: that one changes with the node version and
    # with whether stdout is a terminal, and the summary lines checked below are TAP's.
    result = subprocess.run(
        ["node", "--test", "--test-reporter=tap", "tools/tests/web_probe_kit.test.js"],
        cwd=ROOT, capture_output=True, text=True, timeout=300,
    )
    assert result.returncode == 0, result.stdout[-3000:] + result.stderr[-1000:]
    assert re.search(r"^# fail 0$", result.stdout, re.M)
    assert not re.search(r"^# pass 0$", result.stdout, re.M)


@needs_node
@pytest.mark.parametrize("script", [KIT, PROBE])
def test_probe_scripts_parse(script):
    result = subprocess.run(["node", "--check", str(script)], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr


def test_the_probe_header_documents_every_knob():
    header = "\n".join(
        line for line in PROBE.read_text(encoding="utf-8").splitlines()[:40] if line.startswith("//")
    )
    documented = set(re.findall(r"GF_FPS_[A-Z_]+", header))
    missing = knobs_read() - documented
    assert not missing, f"web_fps_probe.js header does not mention {sorted(missing)}"


def test_the_runbook_documents_every_knob():
    text = RUNBOOK.read_text(encoding="utf-8")
    missing = {k for k in knobs_read() if k not in text}
    assert not missing, f"docs/runbooks/web-probe-kit.md does not mention {sorted(missing)}"


def test_the_kit_reads_the_knobs_the_brief_asks_for():
    assert {"GF_FPS_VIEWPORT", "GF_FPS_DPR", "GF_FPS_KIT", "GF_FPS_GLHOOK"} <= knobs_read()


def gd_sources() -> dict[str, str]:
    return {str(p.relative_to(ROOT)): p.read_text(encoding="utf-8") for p in (ROOT / "scripts").rglob("*.gd")}


def test_every_first_use_mark_in_the_game_is_in_the_runbook_and_the_other_way_round():
    in_code: dict[str, list[str]] = {}
    for name, text in gd_sources().items():
        for tag in re.findall(r'FirstUse\.mark\("([a-z_]+)"\)', text):
            in_code.setdefault(tag, []).append(name)
    listed = re.search(r"Marks \(first sight\):(.*?)Stopwatches:", RUNBOOK.read_text(encoding="utf-8"), re.S)
    assert listed, "the runbook lists the marks as 'Marks (first sight): ... Stopwatches:'"
    documented = set(re.findall(r"`([a-z_]+)`", listed.group(1)))
    assert set(in_code) == documented, f"in code {sorted(in_code)}, in the runbook {sorted(documented)}"
    # one call site per tag: a tag that fires from two places cannot say which one it was
    assert all(len(sites) == 1 for sites in in_code.values()), in_code


def test_every_first_use_stopwatch_is_stopped_where_it_is_started():
    for name, text in gd_sources().items():
        if name == "scripts/ops/first_use.gd":
            continue
        assert text.count("FirstUse.begin(") == text.count("FirstUse.end("), name


def test_first_use_emit_prints_the_line_and_makes_the_user_timing_mark():
    # Both outputs are what the probe reads; the desktop cannot observe JavaScriptBridge, so the
    # call is held to its place in _emit() here (fp_first_use_test reads the printed line itself).
    text = (ROOT / "scripts/ops/first_use.gd").read_text(encoding="utf-8")
    emit = text[text.index("static func _emit("):]
    assert "print(line_of(rec))" in emit
    assert "JavaScriptBridge.eval(mark_js(rec), true)" in emit
    assert 'PREFIX := "gf:"' in text and "performance.mark(%s,{detail:%s})" in text


def test_fp_bench_labels_the_pipeline_counters_for_the_renderer_it_ran_on():
    # _measure() needs a whole first-person world; its two wirings are held here and the helper by
    # fp_bench_pipelines_test: the slow-frame rows go through pipelines_for(), and every row names
    # the rendering method its counters belong to.
    text = (ROOT / "tools/tests/fp_bench.gd").read_text(encoding="utf-8")
    measure = text[text.index("func _measure("):text.index("\nfunc ", text.index("func _measure(") + 1)]
    assert "var method := RenderingServer.get_current_rendering_method()" in measure
    assert "pipelines_for(method, _pipeline_delta(p, pipes))" in measure
    assert re.search(r"_hitch\(dt, g, c, shown,", measure)
    assert '"rendering_method": method' in measure


def test_the_default_flags_exist_and_the_probe_reads_the_games_flag_names():
    flags = json.loads((ROOT / "data/feature_flags.json").read_text(encoding="utf-8"))["flags"]
    script = (
        "const k = require('./tools/web_probe_kit.js');"
        "console.log(JSON.stringify(Object.keys(k.DEFAULT_FLAGS)))"
    )
    defaults = json.loads(subprocess.run(["node", "-e", script], cwd=ROOT, capture_output=True, text=True, check=True).stdout)
    assert defaults and set(defaults) <= set(flags), "a default flag the game does not define"
    # the probe's own check, fed the real names: every flag of the game is accepted, a typo is not
    names = list(flags)
    check = (
        "const k = require('./tools/web_probe_kit.js');"
        f"const names = {json.dumps(names)};"
        "for (const n of names) k.parseFlags(n + '=1', names);"
        "try { k.parseFlags('web_first_use_mark=1', names); console.log('accepted'); } catch (e) { console.log('refused'); }"
    )
    out = subprocess.run(["node", "-e", check], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    assert out.strip() == "refused"
    assert "gameFlagNames" in PROBE.read_text(encoding="utf-8")


def test_the_probe_writes_the_keys_web_measure_reads_and_the_schema_it_expects():
    from tools import web_measure

    text = PROBE.read_text(encoding="utf-8")
    assert re.search(rf"const RESULT_SCHEMA = {web_measure.PROBE_SCHEMA};", text), "web_measure.PROBE_SCHEMA is the probe's"
    assert "schema: RESULT_SCHEMA" in text
    # the keys probe_rows() and probe_notes() read: each is written by the probe
    for key in ("hardware", "renderer", "display_hz", "env", "p50_ms", "busy_ms"):
        assert re.search(rf"\b{key}\b\s*[:,]", text), f"web_fps_probe.js no longer writes {key}"
