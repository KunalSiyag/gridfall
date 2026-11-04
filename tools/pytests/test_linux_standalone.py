"""The standalone Linux tooling, offline and without a window: tools/package_linux.sh (run on a fake export
directory, never a real export) and the launcher it writes, tools/bench_linux.sh (argument handling and
the refusal without a display) and tools/bench_table.py (the comparison table, from canned FPBENCH logs)."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
from pathlib import Path

import pytest

from tools import bench_table as bt

REPO = Path(__file__).resolve().parents[2]
PACKAGE = REPO / "tools" / "package_linux.sh"
BENCH = REPO / "tools" / "bench_linux.sh"
needs_unix = pytest.mark.skipif(
    shutil.which("bash") is None or shutil.which("tar") is None or shutil.which("gzip") is None,
    reason="needs bash, tar and gzip",
)
CANARY = "gmi-canary-key-0123456789"
FAKE_GAME = '#!/bin/sh\necho "GAME ARGS: $*"\necho "GAME VIEW=${GRIDFALL_VIEW:-} OFFLINE=${GRIDFALL_OFFLINE:-}"\n'
# A game that dies at once on Vulkan, as one without a usable driver does.
FAIL_ON_VULKAN = '#!/bin/sh\necho "GAME ARGS: $*"\ncase "$*" in *vulkan*) exit 1 ;; esac\nexit 0\n'


def run(cmd, env_extra=None, drop=(), **kw):
    env = {k: v for k, v in os.environ.items() if k not in drop}
    env.update(env_extra or {})
    return subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=120, **kw)


def fake_export(tmp_path: Path, game: str = FAKE_GAME, pck: bytes = b"GDPC default_bus_layout data/gmi_replay_cache.json") -> Path:
    out = tmp_path / "exp"
    (out / "linux").mkdir(parents=True)
    exe = out / "linux" / "gridfall.x86_64"
    exe.write_text(game)
    exe.chmod(0o755)
    (out / "linux" / "gridfall.pck").write_bytes(pck)
    return out


def package(out: Path, *args, env_extra=None):
    env = {"EXPORT_DIR": str(out), "GMI_API_KEY": CANARY, "SOURCE_DATE_EPOCH": "1700000000"}
    env.update(env_extra or {})
    return run(["bash", str(PACKAGE), "--skip-export", *args], env_extra=env)


def unpack(out: Path, tmp_path: Path) -> Path:
    archive = next(out.glob("gridfall-linux-x86_64-*.tar.gz"))
    dest = tmp_path / "unpacked"
    dest.mkdir()
    with tarfile.open(archive) as tf:
        tf.extractall(dest, filter="data")
    (folder,) = list(dest.iterdir())
    return folder


@needs_unix
def test_package_help_and_bad_arguments():
    res = run(["bash", str(PACKAGE), "--help"])
    assert res.returncode == 0
    assert "usage: tools/package_linux.sh" in res.stderr and "EXPORT_DIR" in res.stderr
    assert res.stderr.rstrip().endswith("(printed only when the export fails)."), res.stderr[-120:]
    bad = run(["bash", str(PACKAGE), "--nope"])
    assert bad.returncode == 2 and "unknown argument" in bad.stderr
    level = run(["bash", str(PACKAGE), "--skip-export"], env_extra={"GZIP_LEVEL": "12"})
    assert level.returncode == 2 and "GZIP_LEVEL" in level.stderr


@needs_unix
def test_package_writes_a_named_archive_with_a_matching_checksum(tmp_path):
    out = fake_export(tmp_path)
    res = package(out)
    assert res.returncode == 0, res.stderr
    version = (REPO / "VERSION").read_text().strip()
    archive = next(out.glob("gridfall-linux-x86_64-*.tar.gz"))
    assert re.fullmatch(r"gridfall-linux-x86_64-%s-[0-9a-f]{7,}|gridfall-linux-x86_64-%s-nogit" % (re.escape(version), re.escape(version)), archive.name[: -len(".tar.gz")])
    assert str(archive) in res.stdout.splitlines()[0]
    line = (out / (archive.name + ".sha256")).read_text().split()
    assert line[0] == hashlib.sha256(archive.read_bytes()).hexdigest() and line[1] == archive.name
    with tarfile.open(archive) as tf:
        members = {m.name: m for m in tf.getmembers()}
    stem = archive.name[: -len(".tar.gz")]
    top = {n.split("/")[1] for n in members if n.count("/") >= 1 and n != stem}
    assert top == {"gridfall.x86_64", "gridfall.pck", "run-gridfall.sh", "README-linux.txt", "LICENSE", "VERSION", "THIRD-PARTY-LICENSES"}
    licences = [n for n in members if "/THIRD-PARTY-LICENSES/" in n and members[n].isfile()]
    assert any(n.endswith("characters/rocketbox-MIT.txt") for n in licences), licences
    assert any(n.endswith("fonts/license.txt") for n in licences) and any(n.endswith("real-models/polyhaven.txt") for n in licences)
    assert any(n.endswith("models/car-kit.txt") for n in licences)
    assert members[f"{stem}/run-gridfall.sh"].mode & 0o111 and members[f"{stem}/gridfall.x86_64"].mode & 0o111
    assert not members[f"{stem}/gridfall.pck"].mode & 0o111
    assert {m.uid for m in members.values()} == {0} and {m.mtime for m in members.values()} == {1700000000}
    assert not list(out.glob(".package-linux.*")), "the staging folder is removed"


@needs_unix
def test_package_is_deterministic_and_carries_no_key(tmp_path):
    out = fake_export(tmp_path)
    assert package(out).returncode == 0
    first = next(out.glob("*.tar.gz")).read_bytes()
    assert package(out).returncode == 0
    assert next(out.glob("*.tar.gz")).read_bytes() == first
    folder = unpack(out, tmp_path)
    for path in folder.rglob("*"):
        if path.is_file():
            assert CANARY.encode() not in path.read_bytes(), path.name
    assert (folder / "VERSION").read_text().splitlines()[0] == (REPO / "VERSION").read_text().strip()
    readme = (folder / "README-linux.txt").read_text()
    for needle in ("GMI_API_KEY", "Vulkan 1.2", "NVIDIA driver 470", "--renderer opengl3", "Esc, Settings", "x86_64"):
        assert needle in readme, needle
    # The game, not the launcher, reads ~/.factory/settings.json; the README must say so and name --offline.
    assert ".factory/settings.json" in readme and "guaranteed offline" in readme and "console.gmicloud.ai" in readme
    assert "no SSAO" not in readme and "full quality" not in readme
    assert (folder / "LICENSE").read_text() == (REPO / "LICENSE").read_text()


@needs_unix
def test_the_readme_quick_start_works_with_the_archive_and_checksum_beside_it(tmp_path):
    out = fake_export(tmp_path)
    assert package(out).returncode == 0
    work = tmp_path / "presenter"
    work.mkdir()
    for f in out.glob("gridfall-linux-x86_64-*"):
        if f.is_file():
            shutil.copy(f, work)
    script = "set -e; sha256sum -c gridfall-linux-x86_64-*.tar.gz.sha256 >/dev/null; tar xzf gridfall-linux-x86_64-*.tar.gz; cd gridfall-linux-x86_64-*/; test -x ./run-gridfall.sh; ./run-gridfall.sh --dry-run"
    res = run(["bash", "-c", script], {"GRIDFALL_HAS_VULKAN": "1"}, cwd=work)
    assert res.returncode == 0, res.stderr
    readme = next(work.glob("gridfall-linux-x86_64-*/README-linux.txt")).read_text()
    assert "cd gridfall-linux-x86_64-*/" in readme
    assert "cd gridfall-linux-x86_64-*/" in (REPO / "docs" / "runbooks" / "linux-standalone.md").read_text()


@needs_unix
def test_package_refuses_a_missing_pack_and_warns_about_a_thin_one(tmp_path):
    out = fake_export(tmp_path)
    (out / "linux" / "gridfall.pck").unlink()
    res = package(out)
    assert res.returncode == 1 and "missing" in res.stderr and not list(out.glob("*.tar.gz"))
    thin = fake_export(tmp_path / "thin", pck=b"GDPC nothing useful")
    res = package(thin)
    assert res.returncode == 0
    assert "does not mention default_bus_layout" in res.stderr and "gmi_replay_cache" in res.stderr


@needs_unix
def test_launcher_maps_options_to_engine_flags(tmp_path):
    out = fake_export(tmp_path)
    assert package(out).returncode == 0
    folder = unpack(out, tmp_path)
    launcher = str(folder / "run-gridfall.sh")
    vulkan = {"GRIDFALL_HAS_VULKAN": "1"}

    helped = run(["bash", launcher, "--help"])
    assert helped.returncode == 0 and "--renderer" in helped.stdout and "GMI_API_KEY" in helped.stdout and "--fullscreen" in helped.stdout
    # The help is the whole header comment, not a fixed line range: it ends on the last sentence.
    assert helped.stdout.rstrip().endswith("See README-linux.txt."), helped.stdout[-120:]
    assert ".factory/settings.json" in helped.stdout and "SSAO, soft shadows, MSAA" not in helped.stdout

    dry = run(["bash", launcher, "--dry-run"], vulkan)
    assert dry.returncode == 0
    assert "--rendering-driver vulkan --rendering-method forward_plus" in dry.stdout
    assert "--windowed" not in dry.stdout and "--fullscreen" not in dry.stdout
    gl = run(["bash", launcher, "--dry-run", "--renderer", "opengl3", "--fullscreen"], vulkan)
    assert "--rendering-driver opengl3 --rendering-method gl_compatibility" in gl.stdout and "--fullscreen" in gl.stdout
    assert "--renderer=vulkan" not in gl.stdout
    eq = run(["bash", launcher, "--dry-run", "--renderer=vulkan", "--windowed", "--", "--audio-driver", "ALSA"], vulkan)
    assert "forward_plus" in eq.stdout and "--windowed" in eq.stdout and eq.stdout.strip().endswith("--audio-driver ALSA")

    novk = run(["bash", launcher, "--dry-run"], {"GRIDFALL_HAS_VULKAN": "0"})
    assert "gl_compatibility" in novk.stdout and "no Vulkan loader or driver found" in novk.stderr
    forced = run(["bash", launcher, "--dry-run", "--renderer", "vulkan"], {"GRIDFALL_HAS_VULKAN": "0"})
    assert "forward_plus" in forced.stdout, "an explicit choice is never second-guessed"

    for bad in (["--renderer", "metal"], ["--renderer"], ["--bogus"]):
        res = run(["bash", launcher, "--dry-run", *bad], vulkan)
        assert res.returncode == 2, bad


@needs_unix
def test_launcher_passes_the_environment_and_falls_back_when_vulkan_dies(tmp_path):
    out = fake_export(tmp_path)
    assert package(out).returncode == 0
    folder = unpack(out, tmp_path)
    launcher = str(folder / "run-gridfall.sh")
    ran = run(["bash", launcher, "--orbit", "--offline"], {"GRIDFALL_HAS_VULKAN": "1"}, drop=("GRIDFALL_VIEW", "GRIDFALL_OFFLINE"))
    assert ran.returncode == 0
    assert "forward_plus" in ran.stdout and "VIEW=orbit OFFLINE=1" in ran.stdout
    plain = run(["bash", launcher], {"GRIDFALL_HAS_VULKAN": "1"}, drop=("GRIDFALL_VIEW", "GRIDFALL_OFFLINE"))
    assert "VIEW= OFFLINE=" in plain.stdout, "the launcher sets nothing on its own"

    out2 = fake_export(tmp_path / "two", game=FAIL_ON_VULKAN)
    assert package(out2).returncode == 0
    folder2 = unpack(out2, tmp_path / "two")
    auto = run(["bash", str(folder2 / "run-gridfall.sh")], {"GRIDFALL_HAS_VULKAN": "1"})
    assert auto.returncode == 0
    assert auto.stdout.count("GAME ARGS") == 2 and "gl_compatibility" in auto.stdout.splitlines()[-1]
    assert "trying the OpenGL 3 renderer once" in auto.stderr
    pinned = run(["bash", str(folder2 / "run-gridfall.sh"), "--renderer", "vulkan"], {"GRIDFALL_HAS_VULKAN": "1"})
    assert pinned.returncode == 1 and pinned.stdout.count("GAME ARGS") == 1, "a pinned renderer is not retried"


@needs_unix
def test_bench_refuses_without_a_display_and_checks_its_arguments():
    res = run(["bash", str(BENCH)], drop=("DISPLAY", "WAYLAND_DISPLAY"))
    assert res.returncode == 2 and "no DISPLAY or WAYLAND_DISPLAY" in res.stderr
    assert "--compare" in res.stderr
    helped = run(["bash", str(BENCH), "--help"])
    assert helped.returncode == 0 and "Opens a WINDOW" in helped.stderr and "1600x900" in helped.stderr
    for bad in (["--nope"], ["--out"], ["--compare", "only-one.log"]):
        assert run(["bash", str(BENCH), *bad], {"DISPLAY": ":99"}).returncode == 2, bad


@needs_unix
def test_bench_dry_run_prints_both_renderer_commands(tmp_path):
    env = {"GATE_TMP": str(tmp_path), "GMI_API_KEY": CANARY}
    res = run(["bash", str(BENCH), "--dry-run"], env, drop=("DISPLAY", "WAYLAND_DISPLAY"))
    assert res.returncode == 0, res.stderr
    cmds = [c for c in res.stdout.splitlines() if "fp_bench.gd" in c]
    assert len(cmds) == 2
    assert "--rendering-method forward_plus" in cmds[0] and "--rendering-method gl_compatibility" in cmds[1]
    for c in cmds:
        assert "--resolution 1600x900" in c and "--disable-vsync" in c and "GRIDFALL_OFFLINE=1" in c and "-u GMI_API_KEY" in c
        assert CANARY not in c
    assert CANARY not in res.stderr
    kept = run(["bash", str(BENCH), "--dry-run", "--vsync", "--out", str(tmp_path / "o")], env)
    assert "--disable-vsync" not in kept.stdout and str(tmp_path / "o") in kept.stdout


def bench_row(label, fps, p50, p99, method, slow=0, hitches=None):
    return "FPBENCH " + json.dumps({
        "label": label, "frames": 240, "fps": fps, "avg_ms": round(1000 / fps, 2), "p50_ms": p50, "p99_ms": p99,
        "max_ms": p99 * 1.5, "viewport": "1600x900", "rendering_method": method, "hitches_over_33ms": slow,
        "hitches": hitches or [],
    })


def canned_log(method, scale, device):
    rows = [
        "Godot Engine v4.7.2.stable.official.ed1daf0bf",
        device,
        "FPBENCH grown day=6 pop=900 active=2000 in 5000 ms",
        bench_row("street_eye_nohud", 120.0 * scale, 8.0 / scale, 12.0 / scale, method, 0),
        bench_row("street_tps_nohud", 90.0 * scale, 11.0 / scale, 20.0 / scale, method, 2,
                  [{"ms": 40.0, "pipelines": {"mesh": 3}}, {"ms": 35.0, "pipelines": {}}] if method == "forward_plus"
                  else [{"ms": 40.0, "pipelines": "n/a (gl_compatibility: RenderingDevice counters)"}]),
        "FPBENCH " + json.dumps({"label": "street_eye_hud_ab", "hud_gpu_ms": 0.3}),
        "FPBENCH: DONE",
    ]
    return "\n".join(rows) + "\n"


FP_DEVICE = "Vulkan 1.3.280 - Forward+ - Using Device #0: AMD - AMD Radeon RX 7600"
GL_DEVICE = "OpenGL API 4.6 (Core Profile) Mesa 24.0 - Compatibility - Using Device: AMD - AMD Radeon RX 7600"


def test_parse_log_keeps_measured_rows_and_the_device_line():
    log = bt.parse_log("\x1b[1m" + canned_log("forward_plus", 1.0, FP_DEVICE))
    assert list(log["rows"]) == ["street_eye_nohud", "street_tps_nohud"], "the HUD probe row has no percentiles"
    assert log["device"].endswith("AMD Radeon RX 7600") and log["done"] and log["method"] == "forward_plus"
    junk = bt.parse_log("FPBENCH {not json\nFPBENCH [1]\nFPBENCH {\"label\": \"x\"}\n")
    assert junk["rows"] == {} and junk["device"] is None and not junk["done"]


def test_compile_hitches_count_pipelines_only_where_the_engine_reports_them():
    fp = bt.parse_log(canned_log("forward_plus", 1.0, FP_DEVICE))["rows"]
    gl = bt.parse_log(canned_log("gl_compatibility", 1.0, GL_DEVICE))["rows"]
    assert bt.compile_hitches(fp["street_tps_nohud"]) == 1
    assert bt.compile_hitches(fp["street_eye_nohud"]) == 0
    assert bt.compile_hitches(gl["street_tps_nohud"]) is None and bt.compile_hitches(gl["street_eye_nohud"]) is None
    assert bt.compile_hitches({"hitches": [{"pipelines": "n/a"}]}) is None


def test_table_lines_up_rows_and_says_which_renderer_is_faster():
    a = bt.parse_log(canned_log("forward_plus", 1.0, FP_DEVICE))
    b = bt.parse_log(canned_log("gl_compatibility", 0.5, GL_DEVICE))
    text = bt.format_table(a, b)
    assert "AMD Radeon RX 7600" in text and "forward_plus" in text and "gl_compatibility" in text
    row = next(line for line in text.splitlines() if line.startswith("street_eye_nohud"))
    cells = [c.split() for c in row.split("|")]
    assert cells[1] == ["8.00", "12.00", "120.0"] and cells[2] == ["16.00", "24.00", "60.0"] and cells[3] == ["2.00"]
    assert "forward_plus 1; gl_compatibility n/a" in text
    assert text.splitlines()[-1].startswith("VERDICT: Forward+ (Vulkan) is 100% faster than Compatibility")
    faster_gl = bt.format_table(b, a)
    assert "VERDICT: Compatibility (OpenGL 3) is 100% faster" in faster_gl.splitlines()[-1]


def test_verdict_calls_a_tie_inside_five_percent_and_handles_no_common_rows():
    a = bt.parse_log(canned_log("forward_plus", 1.0, FP_DEVICE))
    b = bt.parse_log(canned_log("gl_compatibility", 0.98, GL_DEVICE))
    assert "within 5%" in bt.verdict(bt.compare(a, b))
    other = {"rows": {"other_row": {"fps": 60.0, "p50_ms": 16.7, "p99_ms": 20.0}}, "device": None, "done": False}
    assert bt.compare(a, other) == []
    assert "no row was measured by both" in bt.verdict([])
    text = bt.format_table(a, other)
    assert "(device line not found in the log)" in text and "[run did not finish]" in text
    assert "rows only one run measured, left out: other_row, street_eye_nohud, street_tps_nohud" in text


def test_main_prints_exit_codes_for_missing_and_empty_logs(tmp_path, capsys):
    good = tmp_path / "fp.log"
    good.write_text(canned_log("forward_plus", 1.0, FP_DEVICE))
    other = tmp_path / "gl.log"
    other.write_text(canned_log("gl_compatibility", 0.8, GL_DEVICE))
    empty = tmp_path / "empty.log"
    empty.write_text("Godot Engine\nFPBENCH: first person did not start\n")
    assert bt.main([str(good), str(other)]) == 0
    assert "VERDICT" in capsys.readouterr().out
    assert bt.main([str(good), str(empty)]) == 1
    assert "no FPBENCH rows" in capsys.readouterr().err
    assert bt.main([str(good), str(tmp_path / "missing.log")]) == 2
    assert bt.main([str(good)]) == 2 and bt.main(["--help"]) == 2


@needs_unix
def test_bench_compare_mode_needs_no_display(tmp_path):
    (tmp_path / "a.log").write_text(canned_log("forward_plus", 1.0, FP_DEVICE))
    (tmp_path / "b.log").write_text(canned_log("gl_compatibility", 0.5, GL_DEVICE))
    res = run(["bash", str(BENCH), "--compare", str(tmp_path / "a.log"), str(tmp_path / "b.log")], drop=("DISPLAY", "WAYLAND_DISPLAY"))
    assert res.returncode == 0, res.stderr
    assert "VERDICT: Forward+ (Vulkan) is 100% faster" in res.stdout


def test_caveats_flag_wrong_window_size_warnings_and_capped_hitch_detail():
    clean = bt.parse_log(canned_log("forward_plus", 1.0, FP_DEVICE))
    assert bt.caveats(clean, "forward_plus") == []
    small = canned_log("gl_compatibility", 0.5, GL_DEVICE).replace('"viewport": "1600x900"', '"viewport": "1280x720"')
    small += "FPBENCH: WARNING street_eye_nohud drew 3 of 240 frames (window hidden?)\n"
    log = bt.parse_log(small)
    notes = bt.caveats(log, "gl_compatibility")
    assert any("1280x720" in n for n in notes) and any("window hidden" in n for n in notes)
    capped = bt.parse_log(canned_log("forward_plus", 1.0, FP_DEVICE))
    capped["rows"]["street_tps_nohud"]["hitches"] = [{"ms": 40.0, "pipelines": {}}] * bt.MAX_HITCHES
    assert any("cap of 12" in n for n in bt.caveats(capped, "forward_plus"))
    text = bt.format_table(capped, log)
    assert "CAVEAT gl_compatibility" in text and "CAVEAT forward_plus" in text
    assert "native-against-native" in text and "FSR2 0.77" in text


def test_verdict_does_not_claim_compatibility_lacks_ssao():
    a = bt.parse_log(canned_log("forward_plus", 0.5, FP_DEVICE))
    b = bt.parse_log(canned_log("gl_compatibility", 1.0, GL_DEVICE))
    text = bt.verdict(bt.compare(a, b))
    assert "SSAO" not in text and "the look differs" in text
