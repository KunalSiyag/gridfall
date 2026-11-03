"""tools/demo_check.sh against a loopback stand-in for a web instance and for GMI's preflight (no
outside network): the headers it checks, the Brotli sidecars and the first-load byte count, the build
check (does the deployed pack hold the browser-header fix), the CORS verdict for the web client's
header set, the repo/gate report, and that it stays read-only."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "tools" / "demo_check.sh"
pytestmark = pytest.mark.skipif(shutil.which("curl") is None or shutil.which("bash") is None, reason="needs bash and curl")

PAGE = ('<!doctype html><script>const GODOT_CONFIG = {"executable":"releases/abc/index","fileSizes":'
        '{"releases/abc/index.pck":1000,"releases/abc/index.wasm":500}};</script>'
        '<script src="index.js"></script><link rel="manifest" href="index.manifest.json">')
# What api.gmi-serving.com answered to a key-free preflight on 2026-11-03.
MEASURED = "Content-Type, Authorization, X-Requested-With, x-gmi-request-id"
# A pack with and without the browser-header flag in its data/feature_flags.json (a build that has the
# fix holds the flag's name; every build older than it holds neither the file entry nor the name).
PACK_WITH_FIX = b'GDPC\x00\x01 res://data/feature_flags.json {"gmi_live": {"default": true}, "gmi_web_safe_headers": {"default": true}}'
PACK_BEFORE_FIX = b'GDPC\x00\x01 res://data/feature_flags.json {"gmi_live": {"default": true}, "carjack_throw": {"default": true}}'


class Site(BaseHTTPRequestHandler):
    """One configurable instance: class attributes are set per test by the `site` fixture."""

    cfg: dict = {}

    def log_message(self, *args):  # keep pytest output quiet
        pass

    def _send(self, code, headers, body=b""):
        try:
            self.send_response(code)
            for k, v in headers.items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):  # the client gave up (a timeout test)
            pass

    def do_GET(self):  # noqa: N802
        c = self.cfg
        if self.path == "/healthz":
            return self._send(c.get("health", 200), {}, c.get("health_body", b"ok"))
        if self.path == "/releases/abc/index.pck":
            if c.get("pack_status", 200) != 200:
                return self._send(c["pack_status"], {})
            time.sleep(c.get("pack_delay", 0))  # a slow link: the pack arrives after the client gave up
            return self._send(200, {}, c.get("pack", PACK_WITH_FIX))
        if self.path == "/":
            h = {"Cross-Origin-Opener-Policy": c.get("coop", "same-origin"),
                 "Cross-Origin-Embedder-Policy": c.get("coep", "require-corp"),
                 "Cache-Control": c.get("loader_cache", "no-cache")}
            # A knob set to None leaves that header out altogether (a missing header, not an empty one).
            return self._send(200, {k: v for k, v in h.items() if v is not None}, PAGE.encode())
        if self.path in ("/index.js", "/index.manifest.json"):
            return self._send(200, {}, b"x" * 40)
        return self._send(404, {})

    def do_HEAD(self):  # noqa: N802
        c = self.cfg
        sizes = {"/releases/abc/index.pck": 1000, "/releases/abc/index.wasm": 500, "/index.js": 40, "/index.manifest.json": 40}
        if self.path not in sizes or self.path in c.get("head_404", ()):
            return self._send(404, {})
        h = {"Cache-Control": "public, max-age=31536000, immutable", "_len": sizes[self.path]}
        if self.path.endswith((".pck", ".wasm")) and c.get("br", True):
            h["Content-Encoding"] = "br"
        if self.path.endswith(".pck") and not c.get("immutable", True):
            h["Cache-Control"] = "no-cache"
        self.send_response(200)
        for k, v in h.items():
            if k != "_len":
                self.send_header(k, v)
        self.send_header("Content-Length", str(h["_len"]))
        self.end_headers()

    def do_OPTIONS(self):  # noqa: N802
        c = self.cfg
        if "allow_headers" not in c:
            return self._send(404, {})
        asked = self.headers.get("Access-Control-Request-Headers", "")
        h = {"Access-Control-Allow-Origin": c.get("allow_origin", "*"),
             "Access-Control-Allow-Headers": c["allow_headers"],
             "Access-Control-Allow-Methods": c.get("methods", "GET, POST, PUT, DELETE, OPTIONS"),
             "X-Asked-Headers": asked}
        return self._send(c.get("preflight", 204), h)


@pytest.fixture
def site():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Site)
    Site.cfg = {"allow_headers": MEASURED}
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield srv, Site.cfg
    srv.shutdown()
    srv.server_close()


def last_line(out):
    return out.rstrip("\n").splitlines()[-1]


def run(site_srv, *, args=None, tmp_path=None, preflight=None, extra_env=None, script=None):
    port = site_srv.server_address[1]
    base = f"http://127.0.0.1:{port}"
    env = {k: v for k, v in os.environ.items() if k not in ("GMI_API_KEY", "GATE_TMP")}
    env["GMI_PREFLIGHT_URL"] = preflight or f"{base}/v1/chat/completions"
    env["GATE_TMP"] = str(tmp_path or REPO / "nonexistent-gate-dir")
    env["DEMO_CHECK_TIMEOUT"] = "5"
    env.update(extra_env or {})
    p = subprocess.run(["bash", str(script or SCRIPT), *(args if args is not None else [base])], capture_output=True,
                       text=True, env=env, timeout=120, cwd=tmp_path or REPO)
    return p.returncode, p.stdout, p.stderr


def test_a_healthy_instance_passes(site, tmp_path):
    rc, out, err = run(site[0], tmp_path=tmp_path)
    assert rc == 0, out + err
    assert "DEMO_CHECK: PASS" in out
    assert "/healthz 200 ok" in out
    assert "COOP same-origin" in out and "COEP require-corp" in out
    assert "releases/abc/index.pck content-encoding br" in out
    # 1000 + 500 + 40 + 40 compressed bytes, plus the page itself is not a counted file
    assert "first load, compressed (Brotli): 0.0 MB in 4 files" in out
    assert "CORS preflight OK" in out and "Allow-Headers: " + MEASURED in out
    assert "build: the pack holds 'gmi_web_safe_headers'" in out
    assert "GMI's side only" in out, "the preflight verdict says what it does not cover"
    # Neither verdict is worded as an observation of a browser: the pack and GMI's preflight are what was read.
    assert "this build's code sends only Authorization and Content-Type from a browser (read from the pack, not seen in a browser)" in out
    assert "GMI's preflight allows (authorization,content-type) from this origin" in out and "no browser call was observed" in out
    assert "a browser may send" not in out and "so a browser here sends" not in out
    assert "FAIL" not in out.replace("DEMO_CHECK: FAIL", "")


def test_the_cors_verdict_follows_the_web_client_header_set(site, tmp_path):
    """The measured GMI answer allows Authorization and Content-Type: OK. Without Authorization (or
    with only a wildcard, which never covers it) a browser blocks every call: BLOCKED."""
    srv, cfg = site
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 0 and "CORS preflight OK" in out
    for allow in ("Content-Type", "*", "Authorization", "X-Requested-With, x-gmi-request-id"):
        cfg["allow_headers"] = allow
        rc, out, _ = run(srv, tmp_path=tmp_path)
        assert rc == 1 and "CORS preflight BLOCKED" in out, allow
    cfg["allow_headers"] = "authorization, Content-Type"
    assert run(srv, tmp_path=tmp_path)[0] == 0
    cfg["allow_headers"] = "Authorization, *"
    assert run(srv, tmp_path=tmp_path)[0] == 0, "a wildcard covers Content-Type once Authorization is named"


def test_the_old_desktop_header_set_would_have_been_blocked(site, tmp_path):
    """The reason the web build drops User-Agent, X-Request-ID and X-Trace-ID: the preflight does
    not list them. The script asks only for what the web client sends, so it passes; a client that
    asked for the five would not."""
    srv, cfg = site
    cfg["allow_headers"] = MEASURED
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 0
    allowed = {h.strip().lower() for h in MEASURED.split(",")}
    assert {"user-agent", "x-request-id", "x-trace-id"}.isdisjoint(allowed)


def test_origin_method_and_status_are_part_of_the_verdict(site, tmp_path):
    srv, cfg = site
    for key, value, word in (("allow_origin", "https://elsewhere.example", "Allow-Origin"),
                             ("methods", "GET, OPTIONS", "POST not allowed"),
                             ("preflight", 403, "preflight status 403")):
        cfg.update({"allow_headers": MEASURED, "allow_origin": "*", "methods": "GET, POST", "preflight": 204})
        cfg[key] = value
        rc, out, _ = run(srv, tmp_path=tmp_path)
        assert rc == 1 and word in out, (key, out)


def test_the_preflight_carries_the_instance_as_origin_and_only_the_web_headers(site, tmp_path):
    srv, _ = site
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 0
    script = SCRIPT.read_text()
    assert 'WEB_REQUEST_HEADERS="authorization,content-type"' in script
    for banned in ("user-agent", "x-request-id", "x-trace-id"):
        assert banned not in script.split("WEB_REQUEST_HEADERS=")[1].split("\n")[0].lower()


def test_wrong_headers_and_missing_compression_fail(site, tmp_path):
    srv, cfg = site
    cfg["coop"] = "unsafe-none"
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 1 and "COOP is 'unsafe-none'" in out
    # require-corp is what lets the threaded build boot: another value or none at all must fail too.
    for coep in ("unsafe-none", "credentialless", None):
        cfg.update({"coop": "same-origin", "coep": coep})
        rc, out, _ = run(srv, tmp_path=tmp_path)
        assert rc == 1 and f"COEP is '{coep or 'missing'}' (want require-corp" in out, (coep, out)
        assert "COOP same-origin" in out, "only the COEP check failed"
    cfg.pop("coep")
    cfg.update({"coop": "same-origin", "loader_cache": "max-age=600"})
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 1 and "loader Cache-Control is 'max-age=600'" in out
    cfg.update({"loader_cache": "no-cache", "br": False})
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 1 and "content-encoding 'identity'" in out
    cfg.update({"br": True, "immutable": False})
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 1 and "cache-control 'no-cache'" in out
    cfg.update({"immutable": True, "health": 503})
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 1 and "/healthz answered 503" in out


def test_an_unreachable_instance_and_an_unreachable_preflight_are_failures(site, tmp_path):
    srv, _ = site
    rc, out, _ = run(srv, args=["http://127.0.0.1:9"], tmp_path=tmp_path)
    assert rc == 1
    assert "/healthz: no answer" in out and "loader page / answered nothing" in out
    assert "CORS preflight OK" in out, "the preflight is a separate check of GMI, not of the instance"
    rc, out, _ = run(srv, tmp_path=tmp_path, preflight="http://127.0.0.1:9/v1/chat/completions")
    assert rc == 1 and "CORS preflight: no answer" in out


def test_a_bare_run_says_which_instances_it_checked_and_to_pass_the_new_one(tmp_path):
    """The default URLs go stale with every deploy (a new instance gets a new URL), so a bare run
    says it is checking the old pair. A stand-in curl that always fails keeps the run offline: no
    request leaves this test."""
    shim = tmp_path / "bin"
    shim.mkdir()
    (shim / "curl").write_text("#!/bin/sh\nexit 7\n")
    (shim / "curl").chmod(0o755)
    env = {k: v for k, v in os.environ.items() if k not in ("GMI_API_KEY", "GATE_TMP")}
    env.update({"PATH": f"{shim}:{os.environ['PATH']}", "GATE_TMP": str(tmp_path), "DEMO_CHECK_TIMEOUT": "2"})
    p = subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, env=env, timeout=120, cwd=tmp_path)
    out = p.stdout
    assert p.returncode == 1, out
    assert "no URL given: checking the two default instances" in out and "After a deploy pass the new one" in out
    assert len(re.findall(r"^== https://ct-\S+\.caas-us1\.gmicloud\.ai$", out, re.M)) == 2, out
    assert "/healthz: no answer" in out
    given = subprocess.run(["bash", str(SCRIPT), "http://127.0.0.1:9"], capture_output=True, text=True, env=env,
                           timeout=120, cwd=tmp_path)
    assert "no URL given" not in given.stdout, "an explicit URL silences the note"


def test_each_url_is_checked_and_the_failure_is_named_per_instance(site, tmp_path):
    srv, _ = site
    good = f"http://127.0.0.1:{srv.server_address[1]}"
    rc, out, _ = run(srv, args=[good + "/", "http://127.0.0.1:9"], tmp_path=tmp_path)
    assert rc == 1
    assert out.count("\n== http://") == 2 and f"== {good}\n" in out, out


def make_checkout(tmp_path):
    """A throwaway git checkout holding a copy of the script (the script reports the repo it lives in),
    so the gate report does not depend on the state of the real working tree. Returns (script, HEAD)."""
    root = tmp_path / "checkout"
    (root / "tools").mkdir(parents=True)
    script = root / "tools" / "demo_check.sh"
    shutil.copy(SCRIPT, script)
    git = ["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@example.test", "-c", "commit.gpgsign=false"]
    subprocess.run([*git, "init", "-q"], check=True)
    subprocess.run([*git, "add", "-A"], check=True)
    subprocess.run([*git, "commit", "-q", "-m", "init"], check=True)
    head = subprocess.run([*git, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    return script, head


def write_gate(path, commit, result):
    path.parent.mkdir(exist_ok=True)
    path.write_text('{\n "mode": "quick",\n "commit": "%s",\n "result": "%s",\n "steps": []\n}\n' % (commit, result))


def test_the_repo_and_gate_report(site, tmp_path):
    srv, _ = site
    script, head = make_checkout(tmp_path)
    gates = tmp_path / "gates"
    gates.mkdir()
    rc, out, _ = run(srv, tmp_path=gates, script=script)
    assert "no gate result under" in out
    assert re.search(r"git revision [0-9a-f]{7,} on ", out) and "uncommitted" not in out
    old, new = gates / "gf-gate-old" / "results.json", gates / "gf-gate-new" / "results.json"
    write_gate(old, "0" * 40, "FAIL")
    write_gate(new, head, "PASS")
    now = time.time()
    os.utime(old, (now - 5 * 3600, now - 5 * 3600))
    os.utime(new, (now - 3 * 3600 - 120, now - 3 * 3600 - 120))
    rc, out, _ = run(srv, tmp_path=gates, script=script)
    assert "newest gate result: quick PASS, 3 h 2 min ago" in out, out
    assert "  ok    the gate ran on this revision" in out, "a clean tree on the gated commit is a plain ok"
    os.utime(new, (now - 100, now - 100))
    new.write_text(new.read_text().replace(head, "1" * 40))
    rc, out, _ = run(srv, tmp_path=gates, script=script)
    assert "the gate ran on 1111111" in out and rc == 0


def test_the_script_writes_nothing_into_the_checkout_it_reports_on(site, tmp_path):
    """A plain `git status` refreshes the index's stat cache and rewrites .git/index (taking
    index.lock) whenever a file's timestamp moved since the last refresh, so a "read-only" report
    could write into the repo and race a gate run in the same checkout. GIT_OPTIONAL_LOCKS=0 stops it."""
    srv, _ = site
    script, _ = make_checkout(tmp_path)
    root = script.parent.parent
    index = root / ".git" / "index"
    now = time.time()
    os.utime(index, (now - 3600, now - 3600))
    os.utime(script, (now - 60, now - 60))  # a tracked file whose cached timestamp is now stale
    before = (index.stat().st_mtime_ns, index.read_bytes())
    gates = tmp_path / "gates"
    gates.mkdir()
    _, out, _ = run(srv, tmp_path=gates, script=script)
    assert re.search(r"git revision [0-9a-f]{7,} on ", out), out
    assert (index.stat().st_mtime_ns, index.read_bytes()) == before, ".git/index was rewritten by the report"
    assert not (root / ".git" / "index.lock").exists()


def test_a_dirty_tree_is_not_reported_as_covered_by_the_gate(site, tmp_path):
    """The gate records the commit it ran on, not the working tree, so edits made after it (or
    before it, uncommitted) are not covered: the report warns instead of saying ok."""
    srv, _ = site
    script, head = make_checkout(tmp_path)
    gates = tmp_path / "gates"
    gates.mkdir()
    write_gate(gates / "gf-gate-x" / "results.json", head, "PASS")
    (script.parent.parent / "edited.txt").write_text("changed after the gate\n")
    rc, out, _ = run(srv, tmp_path=gates, script=script)
    assert "(uncommitted changes)" in out
    assert "  warn  the gate ran on this revision, but the tree has uncommitted changes" in out
    assert "  ok    the gate ran on this revision" not in out
    assert rc == 0, "a warning, not a failure"


def test_a_page_that_names_a_file_the_game_cannot_start_without_fails(site, tmp_path):
    """index.wasm, index.js and the .pck: a non-200 on any of them used to be a 'not counted' note
    and the run still said PASS; an extra file (the manifest) is still only a note."""
    srv, cfg = site
    for path, word in (("/releases/abc/index.wasm", "index.wasm"), ("/index.js", "index.js"),
                       ("/releases/abc/index.pck", "index.pck")):
        cfg["head_404"] = (path,)
        rc, out, _ = run(srv, tmp_path=tmp_path)
        assert rc == 1, (path, out)
        assert f"{word}: HTTP 404 (the page names it; the game cannot start without it)" in out, out
        assert "names no .pck" not in out, "a named but missing .pck is not 'no .pck at all'"
    cfg["head_404"] = ("/index.manifest.json",)
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 0 and "index.manifest.json: HTTP 404 (not counted)" in out, out
    cfg["head_404"] = ()
    assert run(srv, tmp_path=tmp_path)[0] == 0


def test_the_healthz_body_may_end_in_a_newline_and_a_wrong_body_is_shown(site, tmp_path):
    srv, cfg = site
    for body in (b"ok\n", b"ok\r\n", b"ok "):
        cfg["health_body"] = body
        rc, out, _ = run(srv, tmp_path=tmp_path)
        assert rc == 0 and "/healthz 200 ok" in out, (body, out)
    cfg["health_body"] = b"degraded\x01 mode"
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 1 and "/healthz answered 200 with 'degraded? mode' (want the body: ok)" in out, out


def test_an_image_built_before_the_browser_header_fix_fails_the_build_check(site, tmp_path):
    """GMI's preflight answer is the same for every request, so the CORS check alone says OK for the
    exact image that a browser would still block. The pack tells: the flag is in a build with the fix
    and in none without it. The old image must not pass."""
    srv, cfg = site
    cfg["pack"] = PACK_BEFORE_FIX
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 1, out
    assert "build: the pack has no 'gmi_web_safe_headers'" in out and "predates the browser-header fix" in out
    assert "also has no Test button" in out, "an old image has none, and the runbook sends the operator here to learn that"
    assert "CORS preflight OK" in out, "GMI's side is fine; the verdict still fails on the build"
    assert "DEMO_CHECK: FAIL (1 check(s))" in out
    cfg["pack"] = PACK_WITH_FIX
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 0 and "build: the pack holds 'gmi_web_safe_headers'" in out, out


def test_the_build_marker_can_be_changed_and_the_check_can_be_skipped_or_fail_soft(site, tmp_path):
    srv, cfg = site
    cfg["pack"] = PACK_BEFORE_FIX
    rc, out, _ = run(srv, tmp_path=tmp_path, extra_env={"DEMO_CHECK_BUILD_MARKER": "carjack_throw"})
    assert rc == 0 and "build: the pack holds 'carjack_throw'" in out, out
    cfg["pack"] = PACK_BEFORE_FIX
    rc, out, _ = run(srv, tmp_path=tmp_path, extra_env={"DEMO_CHECK_BUILD": "0"})
    assert rc == 0 and "warn  build: not read (DEMO_CHECK_BUILD=0)" in out and "not verified" in out, out
    assert last_line(out).startswith("DEMO_CHECK: NO BUILD CHECK (skipped on request"), \
        "an explicit skip is named on the last line, not reported as a pass"
    assert "DEMO_CHECK: PASS" not in out
    cfg["pack"] = PACK_WITH_FIX
    cfg["pack_status"] = 500
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert "warn  build: could not read releases/abc/index.pck" in out and "not verified" in out, out
    assert rc == 1 and last_line(out).startswith("DEMO_CHECK: INCOMPLETE (the build was not verified on 1 instance"), \
        "an unreadable pack is not a pass: the image this tool exists to catch would have passed"
    assert "DEMO_CHECK: PASS" not in out
    cfg["pack_status"] = 200
    cfg["pack"] = b"x" * 5000  # no marker: read to the end, a verdict
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 1 and "FAIL  build:" in out


def test_a_slow_pack_download_leaves_the_build_unverified_not_passed(site, tmp_path):
    """A pack that does not arrive within DEMO_CHECK_BUILD_TIMEOUT (a slow link at a demo) used to end in
    PASS although the build, the thing this tool exists to check, had not been read."""
    srv, cfg = site
    cfg["pack"] = PACK_BEFORE_FIX  # a known-bad image: the run must not call it good just because it was slow
    cfg["pack_delay"] = 4
    rc, out, _ = run(srv, tmp_path=tmp_path, extra_env={"DEMO_CHECK_BUILD_TIMEOUT": "1"})
    assert "warn  build: could not read releases/abc/index.pck (curl exit 28)" in out, out
    assert "raise DEMO_CHECK_BUILD_TIMEOUT" in out
    assert rc == 1 and last_line(out).startswith("DEMO_CHECK: INCOMPLETE (the build was not verified"), out
    assert "DEMO_CHECK: PASS" not in out


def test_an_unverified_build_next_to_a_real_failure_still_ends_in_fail(site, tmp_path):
    srv, cfg = site
    cfg.update({"pack_status": 500, "coop": "unsafe-none"})
    rc, out, _ = run(srv, tmp_path=tmp_path)
    assert rc == 1 and last_line(out) == "DEMO_CHECK: FAIL (1 check(s))", out
    assert "The build was also not verified on 1 instance(s)." in out


def test_the_marker_in_the_shipped_flags_is_what_the_check_looks_for():
    """The default marker is the flag the client's header switch is gated by."""
    script = SCRIPT.read_text()
    assert 'DEMO_CHECK_BUILD_MARKER:-gmi_web_safe_headers' in script
    flags = (REPO / "data" / "feature_flags.json").read_text()
    assert '"gmi_web_safe_headers"' in flags, "a build exported from this tree carries the marker"


def test_bad_arguments_exit_two_and_help_exits_zero_with_usage(site, tmp_path):
    srv, _ = site
    rc, out, err = run(srv, args=["not-a-url"], tmp_path=tmp_path)
    assert rc == 2 and "not a URL" in err and "usage:" in err
    rc, out, err = run(srv, args=["--help"], tmp_path=tmp_path)
    assert rc == 0 and "usage:" in out and not err


def test_the_script_is_read_only_and_keyless():
    text = SCRIPT.read_text()
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#") and line != "set -u -o pipefail")
    assert os.access(SCRIPT, os.X_OK) and text.startswith("#!/usr/bin/env bash")
    for banned in ("GMI_API_KEY", "settings.json", ".env", "--data", "--upload", " -T ", "--output", " -o ", "--remote-name",
                   "-X POST", "-X PUT", "-X DELETE", "--request POST", "--user", "-u ", "mktemp", "rm ", "tee "):
        assert banned not in code, banned
    assert code.count("--request OPTIONS") == 1, "one preflight, no other method but GET/HEAD"
    shell = re.sub(r"'[^']*'", "''", code)  # the awk, sed and printf programs are not redirections
    shell = re.sub(r"2>/dev/null|>/dev/null|2>&1|>&2|<<<|<\(", "", shell)
    assert not re.search(r">", shell), "the only redirections are to /dev/null and stderr"
    assert "Authorization" not in code.replace("authorization,content-type", "").replace("Authorization and Content-Type", ""), \
        "the script never sends an Authorization header itself"
