"""The Web preset and CLI must agree on which export template they require."""
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("mode,template", [([], "web_release.zip"), (["--debug"], "web_debug.zip")])
def test_web_cli_requires_threaded_template(tmp_path, mode, template):
    preset = (ROOT / "export_presets.cfg").read_text().split("[preset.2.options]", 1)[1]
    assert "variant/thread_support=true" in preset.splitlines()
    godot = tmp_path / "godot"
    version = (ROOT / ".godot-version").read_text().strip()
    godot.write_text("#!/bin/sh\nprintf '%s\\n' '" + version + "'\n")
    godot.chmod(0o755)
    templates = tmp_path / "templates"
    templates.mkdir()
    # Having only the old no-threads template must not satisfy the new preset.
    (templates / template.replace("web_", "web_nothreads_")).touch()
    result = subprocess.run(
        ["bash", str(ROOT / "tools/export.sh"), "web", *mode],
        cwd=ROOT, capture_output=True, text=True, timeout=30,
        env={**os.environ, "GODOT": str(godot), "GODOT_TEMPLATES_DIR": str(templates),
             "GATE_TMP": str(tmp_path / "gate")},
    )
    assert result.returncode == 3
    assert f"export: missing template {templates / template}" in result.stderr
