"""Every serving config in deploy/web must send the cross-origin isolation headers.

usage: python3 tools/checks/web_headers.py [-v]

A threaded web export boots only in a cross-origin isolated context (SharedArrayBuffer), so
any config that can serve the export must answer with Cross-Origin-Opener-Policy: same-origin
and Cross-Origin-Embedder-Policy: require-corp on every response. The legacy nginx.conf lacked
both; a threaded build behind it could not start. Scans deploy/web for server configs
(Caddyfile, *.conf, *.vhost) and requires both headers in each.
"""
from __future__ import annotations

import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "web_headers"
CONFIG_NAMES = ("Caddyfile",)
CONFIG_GLOBS = ("*.conf", "*.vhost")
REQUIRED_HEADERS = (
    "Cross-Origin-Opener-Policy",
    "Cross-Origin-Embedder-Policy",
)


def serving_configs(root: Path) -> list[Path]:
    """Server configs under deploy/web, sorted for a stable report."""
    deploy = root / "deploy/web"
    if not deploy.is_dir():
        return []
    files = [p for p in deploy.rglob("*") if p.is_file() and p.name in CONFIG_NAMES]
    for glob in CONFIG_GLOBS:
        files += [p for p in deploy.rglob(glob) if p.is_file()]
    return sorted(set(files))


def run(root: Path) -> common.Result:
    res = common.Result(NAME)
    files = serving_configs(root)
    if not files:
        res.new.append("deploy/web: no serving config found (expected at least a Caddyfile)")
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = path.relative_to(root)
        for header in REQUIRED_HEADERS:
            if header not in text:
                res.new.append(
                    f"{rel}: missing {header} (a threaded build needs cross-origin isolation)"
                )
        res.known.append(str(rel))
    res.stats = {"serving_configs": len(files)}
    return res


def main(argv: list[str] | None = None) -> int:
    return common.cli(run, argv, __doc__.split("\n")[0])


if __name__ == "__main__":
    sys.exit(main())
