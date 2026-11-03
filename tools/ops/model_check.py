"""Checks that every GMI model id the game is configured with is still served to your key.

    GMI_API_KEY=... python3 tools/ops/model_check.py [--key-env NAME] [--models-url URL]

Run it from your own shell before a demo, not from the browser. It reads the key from a NAMED
environment variable (default GMI_API_KEY; the key is never taken from an argument, never printed,
logged or echoed, even in an error message), GETs the models list from the host the game calls
(GmiClient.CHAT_URL in scripts/ai/gmi_client.gd with /chat/completions swapped for /models) and
compares it with every model id configured in the source, read by regex so nothing is duplicated
here: the mayors and support agents (scripts/sim/sim_defs.gd MAYORS and SUPPORT_AGENTS), the
residents' models (scripts/ai/resident_minds.gd MODELS) and chatter's (chatter_minds.gd MODEL_NAMES).

Prints one row per configured id with its roles and whether the list has it. A listed model is
available to the account, not proven to answer in the mode the game asks for (JSON replies, the
per-model MODEL_EXTRAS); the Test key button in the game proves one live call.

Exit codes: 0 every configured model is listed, 1 at least one is missing, 2 the check itself
failed (no key, GMI rejected it, the network failed, an unreadable reply or source file).
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Iterable, Sequence, TextIO

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.ops.common import REPO_ROOT  # noqa: E402

DEFAULT_KEY_ENV = "GMI_API_KEY"
CLIENT_SOURCE = "scripts/ai/gmi_client.gd"
TIMEOUT_S = 20.0
EXIT_OK, EXIT_MISSING, EXIT_ERROR = 0, 1, 2

# A fetch takes (url, key, timeout_s) and returns (http_status, body_text). It raises OSError (which
# urllib's URLError and socket timeouts are) when the network fails.
Fetch = Callable[[str, str, float], "tuple[int, str]"]


class CheckError(Exception):
    """The check could not be completed (exit code 2). The message never holds the key."""


def _read(root: Path, rel: str) -> str:
    try:
        return (root / rel).read_text(encoding="utf-8")
    except OSError as e:
        raise CheckError(f"cannot read {rel}: {e.strerror or e}") from None


def _block(text: str, name: str, rel: str, opener: str) -> str:
    """The inside of `const NAME := <opener> ... <closer>` with its comments removed. Brackets are
    matched with strings and comments skipped, so a one-line list and a multi-line dictionary both work."""
    m = re.search(rf"^const\s+{name}\s*(?::[^=\n]*)?=\s*", text, re.M)
    if not m:
        raise CheckError(f"{rel}: no `const {name}` found")
    start = m.end()
    if text[start : start + 1] != opener:
        raise CheckError(f"{rel}: `const {name}` is not a {opener} literal")
    depth, in_str, out, i = 0, False, [], start
    while i < len(text):
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < len(text):
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_str = False
        elif c == "#":
            i = text.find("\n", i) if "\n" in text[i:] else len(text)
            continue
        elif c == '"':
            in_str = True
            out.append(c)
        elif c in "[{":
            depth += 1
            out.append(c)
        elif c in "]}":
            depth -= 1
            if depth == 0:
                return "".join(out)[1:]
            out.append(c)
        else:
            out.append(c)
        i += 1
    raise CheckError(f"{rel}: `const {name}` is not closed")


def _split_top(inner: str) -> list[str]:
    """The top-level comma-separated items of a block's inside (strings and nested brackets are
    respected), trimmed, without empty items (a trailing comma)."""
    items: list[str] = []
    depth, in_str, cur, i = 0, False, [], 0
    while i < len(inner):
        c = inner[i]
        if in_str:
            cur.append(c)
            if c == "\\" and i + 1 < len(inner):
                cur.append(inner[i + 1])
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            cur.append(c)
        elif c in "[{(":
            depth += 1
            cur.append(c)
        elif c in "]})":
            depth -= 1
            cur.append(c)
        elif c == "," and depth == 0:
            items.append("".join(cur))
            cur = []
        else:
            cur.append(c)
        i += 1
    items.append("".join(cur))
    return [item.strip() for item in items if item.strip()]


def mayor_models(root: Path) -> list[tuple[str, str]]:
    """[(model id, role)] for the five mayors: role is "mayor:<id>". An entry whose id or model is
    not a string literal is an error, not a silent gap: a model left out here is never checked."""
    rel = "scripts/sim/sim_defs.gd"
    out = []
    for item in _split_top(_block(_read(root, rel), "MAYORS", rel, "[")):
        ident = re.search(r'"id"\s*:\s*"([^"]+)"', item)
        model = re.search(r'"model"\s*:\s*"([^"]+)"', item)
        if not (ident and model):
            raise CheckError(f"{rel}: a MAYORS entry has no string-literal id and model "
                             "(a constant or an expression); the check cannot read it")
        out.append((model.group(1), f"mayor:{ident.group(1)}"))
    if not out:
        raise CheckError(f"{rel}: no mayor with an id and a model found in MAYORS")
    return out


def support_models(root: Path) -> list[tuple[str, str]]:
    """[(model id, role)] for the support agents: role is "support:<key>". An agent without a
    string-literal model is an error, not a silent gap."""
    rel = "scripts/sim/sim_defs.gd"
    out = []
    for item in _split_top(_block(_read(root, rel), "SUPPORT_AGENTS", rel, "{")):
        key = re.match(r'"(\w+)"\s*:\s*\{', item)
        model = re.search(r'"model"\s*:\s*"([^"]+)"', item)
        if not (key and model):
            raise CheckError(f"{rel}: a SUPPORT_AGENTS entry has no string-literal model "
                             "(a constant or an expression); the check cannot read it")
        out.append((model.group(1), f"support:{key.group(1)}"))
    if not out:
        raise CheckError(f"{rel}: no agent with a model found in SUPPORT_AGENTS")
    return out


def list_models(root: Path, rel: str, name: str, role: str) -> list[tuple[str, str]]:
    """[(model id, role)] from a `const NAME := ["a", "b", ...]` list in rel. Every item must be a
    string literal: a constant in the list would otherwise be dropped without a word."""
    ids = []
    for item in _split_top(_block(_read(root, rel), name, rel, "[")):
        literal = re.fullmatch(r'"([^"\n]+)"', item)
        if not literal:
            raise CheckError(f"{rel}: `const {name}` holds an item that is not a string literal; "
                             "the check cannot read it")
        ids.append(literal.group(1))
    if not ids:
        raise CheckError(f"{rel}: `const {name}` holds no model id")
    return [(i, role) for i in ids]


def configured_models(root: Path = REPO_ROOT) -> list[dict]:
    """Every configured id once, in first-seen order: [{"id": str, "roles": [str, ...]}]."""
    pairs = (mayor_models(root) + support_models(root)
             + list_models(root, "scripts/ai/resident_minds.gd", "MODELS", "resident")
             + list_models(root, "scripts/ai/chatter_minds.gd", "MODEL_NAMES", "chatter"))
    by_id: dict[str, dict] = {}
    for model_id, role in pairs:
        entry = by_id.setdefault(model_id, {"id": model_id, "roles": []})
        if role not in entry["roles"]:
            entry["roles"].append(role)
    return list(by_id.values())


def models_url(root: Path = REPO_ROOT) -> str:
    """The /v1/models URL on the host GmiClient calls (CHAT_URL with /chat/completions swapped)."""
    m = re.search(r'^const\s+CHAT_URL\s*:=\s*"([^"]+)"', _read(root, CLIENT_SOURCE), re.M)
    if not m:
        raise CheckError(f"{CLIENT_SOURCE}: no `const CHAT_URL` found")
    url = m.group(1)
    if not url.endswith("/chat/completions"):
        raise CheckError(f"{CLIENT_SOURCE}: CHAT_URL does not end in /chat/completions")
    return url[: -len("/chat/completions")] + "/models"


def available_ids(body: str) -> set[str]:
    """Model ids in an OpenAI-style list reply ({"data": [{"id": ...}]}, a bare list or {"models": [...]})."""
    try:
        doc = json.loads(body)
    except ValueError:
        raise CheckError("the models reply is not JSON") from None
    items = doc.get("data", doc.get("models")) if isinstance(doc, dict) else doc
    if not isinstance(items, list):
        raise CheckError("the models reply has no list of models")
    ids = set()
    for item in items:
        if isinstance(item, dict) and isinstance(item.get("id"), str):
            ids.add(item["id"])
        elif isinstance(item, str):
            ids.add(item)
    return ids


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Follows no redirect: urllib re-sends the Authorization header to the Location it is given,
    which would hand the key to another host (or to plain http). A 3xx is reported as a status."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def http_get(url: str, key: str, timeout_s: float) -> tuple[int, str]:
    """GET url with the bearer key; returns (status, body). A 4xx/5xx (and a 3xx, which is never
    followed) is a status, not an exception."""
    req = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + key, "Accept": "application/json", "User-Agent": "GridFall-model-check/1"})
    try:
        with _OPENER.open(req, timeout=timeout_s) as resp:  # noqa: S310 (https URL from the source)
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, ""


def _spellings(key: str) -> set[str]:
    """Every way the key could be written into an error message: as is, with its escapes shown the
    way repr() and json show them, and its bearer form."""
    out = {key, repr(key)[1:-1], json.dumps(key)[1:-1], key.encode("unicode_escape").decode("ascii")}
    return out | {"Bearer " + o for o in out}


def scrub(text: str, key: str) -> str:
    """text with the key removed in every spelling _spellings knows: nothing printed may carry it."""
    if not key:
        return text
    for spelling in sorted(_spellings(key), key=len, reverse=True):
        text = text.replace(spelling, "[REDACTED]")
    return text


def key_problem(key: str) -> str:
    """Why this value cannot be a key ("" when it can). A real key is printable ASCII without a space:
    anything else (a line break from a multi-line paste, a stray space, a non-ASCII letter) cannot go
    into a header, and the error python raises for it would quote the value. The message never does."""
    if re.search(r"[^\x21-\x7e]", key):
        return ("the key holds a space, line break, control or non-ASCII character; "
                "paste only the key itself, on one line")
    return ""


def render_table(rows: Iterable[dict], available: set[str]) -> str:
    """The comparison table: configured id, roles, available yes/no."""
    table = [("MODEL ID", "ROLE", "AVAILABLE")]
    for row in rows:
        table.append((row["id"], ", ".join(row["roles"]), "yes" if row["id"] in available else "no"))
    widths = [max(len(r[i]) for r in table) for i in range(3)]
    return "\n".join("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(r)).rstrip() for r in table)


_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


def check_models_url(url: str) -> None:
    """Raise CheckError for a URL the bearer key must not be sent to. The host is the one urllib
    would connect to (urlsplit's hostname), never a prefix of the text: "http://127.0.0.1:80@evil.test/"
    starts like a loopback address but its user-info is "127.0.0.1:80" and its host evil.test. So the
    plain-http exception is for loopback hosts only, and a user-info part (anything before an @ in the
    authority) is refused for every scheme, since it can make a URL read as a host it does not name.
    The message never repeats the URL."""
    try:
        parts = urllib.parse.urlsplit(url)
        host = parts.hostname
    except ValueError:
        raise CheckError("the models URL is not a valid URL") from None
    if "@" in parts.netloc:
        raise CheckError("the models URL has a user name or password part (text before an @); "
                         "refusing to send the key with it: it can hide the host that gets the key")
    if parts.scheme == "http" and host not in _LOOPBACK_HOSTS:
        raise CheckError("refusing to send the key over plain http (only localhost may use it)")


def run(root: Path, key: str, url: str, fetch: Fetch, timeout_s: float, out: TextIO) -> int:
    rows = configured_models(root)
    check_models_url(url)
    try:
        status, body = fetch(url, key, timeout_s)
    except OSError as e:
        raise CheckError(scrub(f"could not reach {url}: {e}", key)) from None
    except http.client.HTTPException:
        raise CheckError(f"could not read the reply from {url}: it was cut short or malformed") from None
    except ValueError as e:
        # Not str(e): a ValueError raised while building the request can quote the header, key included.
        raise CheckError(f"could not call {url}: {type(e).__name__}") from None
    if status in (401, 403):
        raise CheckError(f"GMI rejected the key (HTTP {status}); check the key in your environment")
    if 300 <= status < 400:
        raise CheckError(f"the models list answered HTTP {status} (a redirect); it is not followed, "
                         "so the key never goes to another address: check --models-url")
    if status != 200:
        raise CheckError(f"the models list answered HTTP {status}")
    available = available_ids(body)
    out.write(render_table(rows, available) + "\n")
    missing = [r["id"] for r in rows if r["id"] not in available]
    out.write(f"\n{len(rows) - len(missing)} of {len(rows)} configured models are available.\n")
    if missing:
        out.write("Missing: " + ", ".join(missing) + "\n")
        return EXIT_MISSING
    return EXIT_OK


class _Parser(argparse.ArgumentParser):
    """argparse that never repeats the arguments it rejects: someone who types the key where a
    variable name belongs would see it echoed back in the usual "unrecognized arguments" error."""

    def error(self, message: str):
        self.print_usage(sys.stderr)
        self.exit(EXIT_ERROR, "model_check: invalid arguments (the key is read from an environment "
                  "variable, never from an argument)\n")


def main(argv: Sequence[str] | None = None, env: dict | None = None, fetch: Fetch = http_get,
         out: TextIO | None = None, err: TextIO | None = None, root: Path = REPO_ROOT) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    env = os.environ if env is None else env
    ap = _Parser(description=__doc__.split("\n")[0], epilog="Exit: 0 all present, 1 missing, 2 error.",
                 allow_abbrev=False)
    ap.add_argument("--key-env", default=DEFAULT_KEY_ENV, metavar="NAME",
                    help="environment variable that holds the key (default %(default)s)")
    ap.add_argument("--models-url", default="", metavar="URL",
                    help="override the models URL (default: derived from GmiClient.CHAT_URL)")
    ap.add_argument("--timeout", type=float, default=TIMEOUT_S, help="seconds to wait (default %(default)s)")
    args = ap.parse_args(argv)
    key = str(env.get(args.key_env, "")).strip()
    try:
        if not key:
            # The variable's name is not repeated: a key pasted where the name belongs would be echoed.
            raise CheckError(f"no key found: set the environment variable named by --key-env (default {DEFAULT_KEY_ENV})")
        problem = key_problem(key)
        if problem:
            raise CheckError(problem)
        return run(root, key, args.models_url or models_url(root), fetch, args.timeout, out)
    except CheckError as e:
        err.write(f"model_check: {scrub(str(e), key)}\n")
        return EXIT_ERROR
    except Exception as e:  # noqa: BLE001 (the 0/1/2 contract holds for anything unforeseen)
        # The class name only: the text of an unforeseen error is not known to be free of the key.
        err.write(f"model_check: unexpected {type(e).__name__}; no result\n")
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
