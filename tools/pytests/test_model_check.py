"""Tests for tools/ops/model_check.py: the configured-model parser against the real sources and a
throwaway repo, and the exit codes with a fake fetch (no network): all present, one missing, 401,
network error, and the key never appearing in any output."""

from __future__ import annotations

import io
import json
import os
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.ops import model_check as mc  # noqa: E402

KEY = "gmi_SECRETKEY_0123456789abcdefXYZ"
REPO = Path(__file__).resolve().parents[2]

SIM_DEFS = '''extends RefCounted
const MAYORS := [
	{
		"id": "alpha", "name": "Alpha", "model": "vendor/alpha-1", "color": "#FFB800",
		"persona": "You are [Alpha] {braces} and # hashes inside a string do not matter.",
	},
	{
		"id": "beta", "name": "Beta", "color": "#00F0FF",
		"model": "vendor/beta-2",  # a comment with "quotes" and ] brackets
	},
]
const SUPPORT_AGENTS := {
	"news": {"name": "News", "model": "vendor/news-3", "color": "#FFD27F"},
	"chaos": {"name": "Chaos", "model": "vendor/alpha-1", "color": "#FF7A59"},
}
'''
RESIDENTS = 'class_name ResidentMinds\nconst MODELS := [\n\t"vendor/fast-a", "vendor/fast-b",  # fast ones\n\t"vendor/beta-2",\n]\n'
CHATTER = 'class_name ChatterMinds\nconst MODEL_NAMES := ["vendor/fast-a", "vendor/chat-c"]\nconst LATER := ["vendor/not-a-model"]\n'
CLIENT = 'class_name GmiClient\nconst CHAT_URL := "https://example.test/v1/chat/completions"\n'

FIXTURE = {
    "scripts/sim/sim_defs.gd": SIM_DEFS,
    "scripts/ai/resident_minds.gd": RESIDENTS,
    "scripts/ai/chatter_minds.gd": CHATTER,
    "scripts/ai/gmi_client.gd": CLIENT,
}
FIXTURE_IDS = ["vendor/alpha-1", "vendor/beta-2", "vendor/news-3", "vendor/fast-a", "vendor/fast-b", "vendor/chat-c"]


def listing(ids) -> str:
    return json.dumps({"object": "list", "data": [{"id": i, "object": "model"} for i in ids]})


def run_main(argv, env, fetch, root):
    out, err = io.StringIO(), io.StringIO()
    code = mc.main(argv, env=env, fetch=fetch, out=out, err=err, root=root)
    return code, out.getvalue(), err.getvalue()


@pytest.fixture
def fixture_root(repo):
    return repo(FIXTURE)


# ------------------------------------------------------------------ the configured models


def test_real_sources_list_every_configured_model():
    rows = mc.configured_models(REPO)
    roles = [r for row in rows for r in row["roles"]]
    text = (REPO / "scripts/sim/sim_defs.gd").read_text(encoding="utf-8")
    mayors = text.split("const MAYORS", 1)[1].split("\n]", 1)[0]
    support = text.split("const SUPPORT_AGENTS", 1)[1].split("\n}", 1)[0]
    assert len({row["id"] for row in rows}) == len(rows) > 5
    assert all("/" in row["id"] for row in rows)
    assert sum(r.startswith("mayor:") for r in roles) == len(re.findall(r'"id":\s*"', mayors)) > 0
    assert sum(r.startswith("support:") for r in roles) == len(re.findall(r'"model":', support)) > 0
    assert "resident" in roles and "chatter" in roles


def test_real_sources_match_the_quoted_ids_of_the_game():
    """An independent read: every vendor/model string inside the four constants is one of the rows."""
    text = (REPO / "scripts/sim/sim_defs.gd").read_text(encoding="utf-8")
    mayors = text.split("const MAYORS", 1)[1].split("\n]", 1)[0]
    support = text.split("const SUPPORT_AGENTS", 1)[1].split("\n}", 1)[0]
    quoted = set(re.findall(r'"model":\s*"([^"]+)"', mayors + support))
    ids = {row["id"] for row in mc.configured_models(REPO)}
    assert quoted and quoted <= ids


def test_models_url_follows_the_game_url():
    assert mc.models_url(REPO) == "https://api.gmi-serving.com/v1/models"


def test_fixture_parsing_handles_comments_strings_and_one_line_lists(fixture_root):
    rows = mc.configured_models(fixture_root)
    assert [r["id"] for r in rows] == FIXTURE_IDS
    by_id = {r["id"]: r["roles"] for r in rows}
    assert by_id["vendor/alpha-1"] == ["mayor:alpha", "support:chaos"]
    assert by_id["vendor/beta-2"] == ["mayor:beta", "resident"]
    assert by_id["vendor/fast-a"] == ["resident", "chatter"]
    assert "vendor/not-a-model" not in by_id
    assert mc.models_url(fixture_root) == "https://example.test/v1/models"


@pytest.mark.parametrize(
    "rel,content,message",
    [
        ("scripts/sim/sim_defs.gd", "const MAYORS := [\n", "not closed"),
        ("scripts/sim/sim_defs.gd", "const OTHER := 1\n", "no `const MAYORS`"),
        ("scripts/sim/sim_defs.gd", "const MAYORS := {}\n", "not a [ literal"),
        ("scripts/sim/sim_defs.gd", "const MAYORS := []\nconst SUPPORT_AGENTS := {}\n", "no mayor"),
        # Entries that are not dictionaries with a literal id and model: now named, no longer skipped.
        ("scripts/sim/sim_defs.gd", "const MAYORS := [1, 2]\nconst SUPPORT_AGENTS := {}\n", "MAYORS entry has no string-literal"),
        ("scripts/ai/resident_minds.gd", "const MODELS := []\n", "no model id"),
        ("scripts/ai/gmi_client.gd", "const OTHER := 1\n", "no `const CHAT_URL`"),
        ("scripts/ai/gmi_client.gd", 'const CHAT_URL := "https://x.test/other"\n', "/chat/completions"),
    ],
)
def test_unreadable_sources_are_a_check_error(repo, rel, content, message):
    root = repo({**FIXTURE, rel: content})
    with pytest.raises(mc.CheckError, match=re.escape(message)):
        mc.configured_models(root)
        mc.models_url(root)


def test_missing_support_models_and_files(repo, tmp_path):
    root = repo({**FIXTURE, "scripts/sim/sim_defs.gd": SIM_DEFS.split("const SUPPORT_AGENTS")[0] + "const SUPPORT_AGENTS := {\n}\n"})
    with pytest.raises(mc.CheckError, match="SUPPORT_AGENTS"):
        mc.configured_models(root)
    with pytest.raises(mc.CheckError, match="cannot read"):
        mc.configured_models(tmp_path / "nowhere")


def test_available_ids_reads_the_usual_shapes():
    assert mc.available_ids(listing(["a", "b"])) == {"a", "b"}
    assert mc.available_ids(json.dumps(["a", {"id": "b"}, {"no": "id"}, 3])) == {"a", "b"}
    assert mc.available_ids(json.dumps({"models": [{"id": "z"}]})) == {"z"}
    for bad in ("<html>", json.dumps({"data": "x"}), json.dumps(5)):
        with pytest.raises(mc.CheckError):
            mc.available_ids(bad)


# ------------------------------------------------------------------ exit codes


def test_all_present_exits_zero_and_prints_the_table(fixture_root):
    seen = {}

    def fetch(url, key, timeout):
        seen.update(url=url, key=key, timeout=timeout)
        return 200, listing(FIXTURE_IDS + ["vendor/extra"])

    code, out, err = run_main([], {"GMI_API_KEY": KEY}, fetch, fixture_root)
    assert code == 0 and err == ""
    assert seen["url"] == "https://example.test/v1/models" and seen["key"] == KEY
    lines = out.splitlines()
    assert lines[0].split() == ["MODEL", "ID", "ROLE", "AVAILABLE"]
    assert all(line.rstrip().endswith("yes") for line in lines[1 : 1 + len(FIXTURE_IDS)])
    assert "6 of 6 configured models are available." in out
    assert "mayor:alpha, support:chaos" in out


def test_one_missing_exits_one_and_names_it(fixture_root):
    ids = [i for i in FIXTURE_IDS if i != "vendor/news-3"]
    code, out, err = run_main([], {"GMI_API_KEY": KEY}, lambda *a: (200, listing(ids)), fixture_root)
    assert code == 1 and err == ""
    row = next(line for line in out.splitlines() if line.startswith("vendor/news-3"))
    assert row.rstrip().endswith("no") and "support:news" in row
    assert "5 of 6 configured models are available." in out and "Missing: vendor/news-3" in out


@pytest.mark.parametrize("status", [401, 403])
def test_a_rejected_key_exits_two(fixture_root, status):
    code, out, err = run_main([], {"GMI_API_KEY": KEY}, lambda *a: (status, f"bad key {KEY}"), fixture_root)
    assert code == 2 and out == ""
    assert f"HTTP {status}" in err and "rejected the key" in err


@pytest.mark.parametrize("status", [429, 500, 404])
def test_other_http_failures_exit_two(fixture_root, status):
    code, out, err = run_main([], {"GMI_API_KEY": KEY}, lambda *a: (status, ""), fixture_root)
    assert code == 2 and out == "" and f"HTTP {status}" in err


def test_a_network_error_exits_two(fixture_root):
    def fetch(url, key, timeout):
        raise OSError(f"connection refused while sending {key}")

    code, out, err = run_main([], {"GMI_API_KEY": KEY}, fetch, fixture_root)
    assert code == 2 and out == "" and "could not reach" in err


def test_a_bad_reply_or_source_exits_two(fixture_root, tmp_path):
    code, _, err = run_main([], {"GMI_API_KEY": KEY}, lambda *a: (200, "<html>no</html>"), fixture_root)
    assert code == 2 and "not JSON" in err
    code, _, err = run_main([], {"GMI_API_KEY": KEY}, lambda *a: (200, "{}"), tmp_path / "nowhere")
    assert code == 2 and "cannot read" in err and KEY not in err


def test_a_missing_key_exits_two_without_calling_out(fixture_root):
    def fetch(*a):
        raise AssertionError("must not call the network without a key")

    for env in ({}, {"GMI_API_KEY": "   "}):
        code, out, err = run_main([], env, fetch, fixture_root)
        assert code == 2 and out == "" and "no key found" in err and "GMI_API_KEY" in err


def test_the_key_comes_from_the_named_variable_only(fixture_root):
    seen = []
    fetch = lambda url, key, timeout: (seen.append(key), (200, listing(FIXTURE_IDS)))[1]  # noqa: E731
    code, _, _ = run_main(["--key-env", "MY_KEY"], {"MY_KEY": "  other_" + KEY + "  ", "GMI_API_KEY": "wrong"}, fetch, fixture_root)
    assert code == 0 and seen == ["other_" + KEY]
    code, _, err = run_main(["--key-env", "MY_KEY"], {"GMI_API_KEY": KEY}, fetch, fixture_root)
    assert code == 2 and "no key found" in err and "MY_KEY" not in err and KEY not in err


def test_plain_http_is_refused_except_for_localhost(fixture_root):
    calls = []
    fetch = lambda url, key, timeout: (calls.append(url), (200, listing(FIXTURE_IDS)))[1]  # noqa: E731
    code, _, err = run_main(["--models-url", "http://example.test/v1/models"], {"GMI_API_KEY": KEY}, fetch, fixture_root)
    assert code == 2 and "plain http" in err and calls == []
    for url in ("http://127.0.0.1:9/v1/models", "http://localhost/v1/models", "http://[::1]:8/m"):
        assert run_main(["--models-url", url], {"GMI_API_KEY": KEY}, fetch, fixture_root)[0] == 0
    code, _, err = run_main(["--models-url", "not a url"], {"GMI_API_KEY": KEY}, mc.http_get, fixture_root)
    assert code == 2 and KEY not in err


@pytest.mark.parametrize("url", [
    "http://127.0.0.1:80@evil.example/v1/models",       # urllib's userinfo is "127.0.0.1:80": the host is evil.example
    "http://localhost:80@evil.example/v1/models",
    "http://[::1]:80@evil.example/v1/models",
    "http://127.0.0.1\\@evil.example/v1/models",          # a backslash before the @
    "http://localhost@evil.example/v1/models",
    "http://127.0.0.1.evil.example/v1/models",           # a host that only starts like a loopback name
    "http://localhost.evil.example:80/v1/models",
    "https://api.gmi-serving.com@evil.example/v1/models",  # userinfo is refused over https too: it hides the real host
    "https://user:pw@api.gmi-serving.com/v1/models",
])
def test_the_url_cannot_hide_another_host_in_front_of_an_at_sign(url, fixture_root):
    """The loopback exception for plain http compared the start of the URL text, so a URL whose
    userinfo looked like localhost passed while the host was somewhere else, and the bearer key would
    have gone there in clear. The host is read the way urllib reads it, and userinfo is refused."""
    calls = []
    fetch = lambda u, key, timeout: (calls.append(u), (200, listing(FIXTURE_IDS)))[1]  # noqa: E731
    code, out, err = run_main(["--models-url", url], {"GMI_API_KEY": KEY}, fetch, fixture_root)
    assert code == 2 and calls == [] and out == "", (url, err)
    assert KEY not in err and "evil.example" not in err, "the refusal does not echo the URL"
    # Which wording depends on how this Python's urlsplit reads the URL (3.11.4+ rejects some bracketed hosts
    # outright); every one of them is a refusal that sends nothing.
    assert any(w in err for w in ("plain http", "user name or password", "not a valid URL")), err


@pytest.mark.parametrize("url", [
    "http://127.0.0.1:9/v1/models", "http://localhost/v1/models", "http://[::1]:8/m", "http://LOCALHOST:5/m",
    "https://api.gmi-serving.com/v1/models", "https://example.test:8443/v1/models?x=a@b",
])
def test_ordinary_urls_still_pass_the_url_check(url, fixture_root):
    """The @ check looks at the part before the path: an @ in a query string is not userinfo."""
    calls = []
    fetch = lambda u, key, timeout: (calls.append(u), (200, listing(FIXTURE_IDS)))[1]  # noqa: E731
    assert run_main(["--models-url", url], {"GMI_API_KEY": KEY}, fetch, fixture_root)[0] == 0
    assert calls == [url]


# ------------------------------------------------------------------ the key never shows


def test_the_key_never_appears_in_any_output(fixture_root):
    def echoing(status, body=""):
        return lambda url, key, timeout: (status, body.replace("@", key))

    def raising(exc):
        def fetch(url, key, timeout):
            raise exc

        return fetch

    scenarios = [
        echoing(200, listing(FIXTURE_IDS)),
        echoing(200, listing(FIXTURE_IDS[:-1])),
        echoing(401, "invalid key @"),
        echoing(500, "oops @"),
        echoing(200, "not json @"),
        raising(OSError(f"fail {KEY}")),
        raising(ValueError(f"bad {KEY}")),
        raising(OSError(f"Authorization: Bearer {KEY}")),
    ]
    for fetch in scenarios:
        _, out, err = run_main([], {"GMI_API_KEY": KEY}, fetch, fixture_root)
        assert KEY not in out and KEY not in err
    assert mc.scrub(f"x {KEY} y", KEY) == "x [REDACTED] y"
    assert mc.scrub("nothing", "") == "nothing"


@pytest.mark.parametrize("argv", [["--key", KEY], ["--key-env"], ["--bogus=" + KEY], ["--timeout", KEY]])
def test_the_key_is_never_taken_from_an_argument_nor_echoed(fixture_root, capsys, argv):
    with pytest.raises(SystemExit) as exc:
        run_main(argv, {"GMI_API_KEY": KEY}, lambda *a: (200, "{}"), fixture_root)
    shown = capsys.readouterr()
    assert exc.value.code == 2 and KEY not in shown.out + shown.err and "usage:" in shown.err


def test_a_key_pasted_as_the_variable_name_is_not_echoed(fixture_root):
    code, out, err = run_main(["--key-env", KEY], {}, lambda *a: (200, "{}"), fixture_root)
    assert code == 2 and KEY not in out + err


# ------------------------------------------------------------------ the real transport (loopback only)


class _Handler(BaseHTTPRequestHandler):
    seen: list = []

    def do_GET(self):  # noqa: N802
        _Handler.seen.append((self.path, self.headers.get("Authorization")))
        if self.path == "/v1/models":
            body = listing(["srv/one"]).encode()
            self.send_response(200)
        else:
            body = b'{"error":"nope"}'
            self.send_response(401)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


@pytest.fixture
def loopback():
    server = HTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    _Handler.seen = []
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()
    server.server_close()


def test_http_get_sends_the_bearer_key_and_maps_statuses(loopback):
    assert mc.http_get(loopback + "/v1/models", KEY, 5) == (200, listing(["srv/one"]))
    assert mc.http_get(loopback + "/other", KEY, 5) == (401, "")
    assert _Handler.seen == [("/v1/models", "Bearer " + KEY), ("/other", "Bearer " + KEY)]


def test_the_real_transport_end_to_end_and_on_a_dead_port(loopback, fixture_root):
    code, out, _ = run_main(["--models-url", loopback + "/v1/models"], {"GMI_API_KEY": KEY}, mc.http_get, fixture_root)
    assert code == 1 and "0 of 6" in out and KEY not in out
    dead = HTTPServer(("127.0.0.1", 0), _Handler)
    url = f"http://127.0.0.1:{dead.server_address[1]}/v1/models"
    dead.server_close()
    code, out, err = run_main(["--models-url", url, "--timeout", "2"], {"GMI_API_KEY": KEY}, mc.http_get, fixture_root)
    assert code == 2 and out == "" and "could not reach" in err and KEY not in err


def test_the_script_runs_from_the_command_line_without_a_key():
    env = {k: v for k, v in os.environ.items() if k not in ("GMI_API_KEY", "GMI_MODEL_CHECK_KEY")}
    done = subprocess.run(
        [sys.executable, str(REPO / "tools/ops/model_check.py"), "--key-env", "GMI_MODEL_CHECK_KEY"],
        capture_output=True, text=True, env=env, timeout=60, check=False,
    )
    assert done.returncode == 2 and "no key found" in done.stderr and done.stdout == ""


# ------------------------------------------------------------------ review findings: keys with odd characters, redirects,
# ------------------------------------------------------------------ cut-short replies, and models the parser cannot read


@pytest.mark.parametrize(
    "key",
    [
        "gmi_PROBEKEY_line1\nsecond_line_9876543210",
        "gmi_PROBEKEY_line1\r\nsecond_line_9876543210",
        "gmi_PROBEKEY with a space 9876543210",
        "gmi_PROBEKEY_tab\tsecond_9876543210",
        "gmi_PROBEKEY_é中_9876543210",
        "gmi_PROBEKEY_nul\x00_9876543210",
    ],
)
def test_a_key_with_a_line_break_or_odd_character_is_refused_before_any_request(fixture_root, key):
    """http.client rejects such a value with an error that quotes the header, key included, in a form
    (repr, escaped newline) that a literal replace of the key does not match. The key is refused up
    front with a fixed message, and nothing is sent."""
    calls = []

    def fetch(url, k, timeout):
        calls.append(url)
        return 200, listing(FIXTURE_IDS)

    code, out, err = run_main([], {"GMI_API_KEY": key}, fetch, fixture_root)
    assert code == 2 and out == "" and calls == []
    assert "one line" in err and "non-ASCII" in err
    for piece in ("PROBEKEY", "9876543210", "second_line", "中"):
        assert piece not in err, piece


def test_a_multiline_key_never_reaches_the_real_transport_or_the_output(loopback, fixture_root):
    """The review's repro, through the real http.client: nothing of the key is printed and nothing arrives."""
    key = "gmi_PROBEKEY_line1\nsecond_line_9876543210"
    code, out, err = run_main(["--models-url", loopback + "/v1/models"], {"GMI_API_KEY": key}, mc.http_get, fixture_root)
    assert code == 2 and "second_line" not in out + err and "PROBEKEY" not in out + err
    assert _Handler.seen == []


def test_an_unforeseen_value_error_is_reported_by_class_not_by_text(fixture_root):
    """If the request building still raises a ValueError that quotes the header (it must not once the
    key is validated, but the guarantee does not rest on that), only the class name is printed."""

    def fetch(url, key, timeout):
        raise ValueError(f"Invalid header value b'Bearer {key!s}'".replace(key, key.upper()))

    code, out, err = run_main([], {"GMI_API_KEY": KEY}, fetch, fixture_root)
    assert code == 2 and KEY.upper() not in err and KEY not in err and "ValueError" in err


def test_scrub_removes_every_spelling_of_the_key():
    key = "gmi_abé_c"
    for spelling in (key, repr(key)[1:-1], json.dumps(key)[1:-1], "Bearer " + key, key.encode("unicode_escape").decode()):
        assert "ab" not in mc.scrub(f"x {spelling} y", key), spelling
    assert mc.key_problem(KEY) == ""
    assert mc.key_problem("a b") and mc.key_problem("a\nb") and mc.key_problem("é")


def test_an_unexpected_exception_is_exit_two_without_a_traceback_or_its_text(fixture_root):
    def fetch(url, key, timeout):
        raise RuntimeError(f"boom {key}")

    code, out, err = run_main([], {"GMI_API_KEY": KEY}, fetch, fixture_root)
    assert code == 2 and out == "" and KEY not in err and "RuntimeError" in err and "Traceback" not in err


class _Wild(BaseHTTPRequestHandler):
    """The odd servers: a redirect to another server, a reply cut short, a malformed status line."""

    seen: list = []
    other_port = 0

    def do_GET(self):  # noqa: N802
        _Wild.seen.append((self.server.server_address[1], self.path, self.headers.get("Authorization")))
        if self.path == "/redir":
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{_Wild.other_port}/v1/models")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/cut":
            self.send_response(200)
            self.send_header("Content-Length", "100")
            self.end_headers()
            self.wfile.write(b"12345678")
            self.wfile.flush()
            self.close_connection = True
        elif self.path == "/garbage":
            self.wfile.write(b"this is not http\r\n\r\n")
            self.close_connection = True
        else:
            body = listing(["srv/one"]).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, *args):
        pass


@pytest.fixture
def wild():
    a, b = HTTPServer(("127.0.0.1", 0), _Wild), HTTPServer(("127.0.0.1", 0), _Wild)
    for srv in (a, b):
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    _Wild.seen = []
    _Wild.other_port = b.server_address[1]
    yield a.server_address[1], b.server_address[1]
    for srv in (a, b):
        srv.shutdown()
        srv.server_close()


def test_a_redirect_is_not_followed_so_the_key_goes_to_no_other_host(wild, fixture_root):
    port_a, port_b = wild
    code, out, err = run_main(
        ["--models-url", f"http://127.0.0.1:{port_a}/redir"], {"GMI_API_KEY": KEY}, mc.http_get, fixture_root
    )
    assert code == 2 and out == "" and "redirect" in err and "302" in err and KEY not in err
    assert [p for p, _, _ in _Wild.seen] == [port_a], "the second server was never contacted"
    assert not any(auth and "Bearer" in auth for p, _, auth in _Wild.seen if p == port_b)
    assert mc.http_get(f"http://127.0.0.1:{port_a}/redir", KEY, 5) == (302, "")


@pytest.mark.parametrize("path", ["/cut", "/garbage"])
def test_a_cut_short_or_malformed_reply_is_exit_two_not_a_traceback(wild, fixture_root, path):
    """IncompleteRead and BadStatusLine are HTTPExceptions, not OSErrors; they used to escape as a
    traceback with exit code 1, the code that means 'models missing'."""
    port_a, _ = wild
    code, out, err = run_main(
        ["--models-url", f"http://127.0.0.1:{port_a}{path}"], {"GMI_API_KEY": KEY}, mc.http_get, fixture_root
    )
    assert code == 2 and out == "" and "cut short or malformed" in err and KEY not in err
    assert "Traceback" not in err


def test_a_model_that_is_not_a_string_literal_is_an_error_not_a_silent_gap(repo):
    """A constant where a mayor's model, an agent's model or a list item should be would be dropped by a
    parser that only keeps what it can read: that model would then never be checked."""
    broken_mayor = SIM_DEFS.replace('"model": "vendor/alpha-1"', '"model": ALPHA_MODEL')
    broken_agent = SIM_DEFS.replace('"model": "vendor/news-3"', '"model": NEWS_MODEL')
    for sources, message in (
        ({"scripts/sim/sim_defs.gd": broken_mayor}, "MAYORS entry has no string-literal"),
        ({"scripts/sim/sim_defs.gd": broken_agent}, "SUPPORT_AGENTS entry has no string-literal"),
        ({"scripts/ai/resident_minds.gd": 'const MODELS := ["vendor/fast-a", FAST_B, "vendor/c"]\n'}, "MODELS` holds an item"),
        ({"scripts/ai/chatter_minds.gd": 'const MODEL_NAMES := ["vendor/fast-a", "vendor/" + "x"]\n'}, "MODEL_NAMES` holds an item"),
    ):
        root = repo({**FIXTURE, **sources})
        with pytest.raises(mc.CheckError, match=re.escape(message)):
            mc.configured_models(root)
    code, out, err = run_main([], {"GMI_API_KEY": KEY}, lambda *a: (200, listing(FIXTURE_IDS)), repo({**FIXTURE, "scripts/sim/sim_defs.gd": broken_mayor}))
    assert code == 2 and out == "" and "MAYORS" in err, "the run stops instead of checking fewer models"


def test_the_real_sources_still_give_fourteen_ids_with_the_strict_parser():
    """The strict parser accepts the shipped sources (no entry is a constant) and finds every model."""
    rows = mc.configured_models(REPO)
    assert len(rows) == 14
