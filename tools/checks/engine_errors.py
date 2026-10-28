#!/usr/bin/env python3
"""Fail a Godot log on engine-level ERROR lines the gate's SCRIPT ERROR grep cannot see.

usage: python3 tools/checks/engine_errors.py [--collect] LOG [LOG...]

Godot prints engine errors as `ERROR: <text>` and game push_error()s as `USER ERROR: <text>`
at the start of a line; neither fails a headless run and the gate only ever grepped for
SCRIPT ERROR, so real bugs (e.g. get_meta on a missing key, #67/#72) slipped through green.

Default mode scans each LOG and exits 1 listing every ERROR:/USER ERROR: line that no entry
in tools/checks/baselines/engine_errors.txt covers. --collect instead prints every distinct
error line across the logs with a count, for seeding or auditing the allowlist. Exit codes:
0 clean, 1 uncovered engine errors, 2 usage, 3 a broken allowlist or unreadable log -- the
gate reports 2/3 as FAIL(engine-check), never FAIL(engine-error), so a broken checker is
not mistaken for game errors.

Allowlist format, one entry per line: `substr|<literal>|<reason>` or `regex|<pattern>|<reason>`.
The reason is mandatory. Blank lines and lines starting with # are comments. A substr entry covers a line when the literal appears in the
error text (after the `ERROR: ` / `USER ERROR: ` prefix); a regex entry when the pattern
searches it.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

BASELINE = Path(__file__).with_name("baselines") / "engine_errors.txt"

## A log line that opens an engine- or user-level error.
ERROR_LINE = re.compile(r"^(?:USER )?ERROR: (.*)$")


def load_allowlist(path: Path | None = None) -> list[tuple[str, str, str]]:
    """Parse (kind, pattern, reason) entries; rejects malformed lines loudly."""
    path = path or BASELINE
    out: list[tuple[str, str, str]] = []
    if not path.is_file():
        return out
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|", 2)
        if len(parts) != 3 or parts[0] not in ("substr", "regex") or not parts[1] or not parts[2]:
            raise ValueError(f"{path}:{lineno}: want 'substr|text|reason' or 'regex|pattern|reason'")
        if parts[0] == "regex":
            try:
                re.compile(parts[1])  # fail at load, not mid-gate
            except re.error as exc:
                raise ValueError(f"{path}:{lineno}: bad regex: {exc}") from exc
        out.append((parts[0], parts[1], parts[2]))
    return out


def error_lines(log: Path) -> list[str]:
    """The ERROR:/USER ERROR: payloads of one log, prefixes stripped."""
    found: list[str] = []
    with log.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = ERROR_LINE.match(line.rstrip("\n"))
            if m:
                found.append(m.group(1).strip())
    return found


def covered(text: str, allowlist: list[tuple[str, str, str]]) -> bool:
    for kind, pattern, _reason in allowlist:
        if kind == "substr" and pattern in text:
            return True
        if kind == "regex" and re.search(pattern, text):
            return True
    return False


def main(argv: list[str]) -> int:
    collect = "--collect" in argv
    logs = [Path(a) for a in argv if a != "--collect"]
    if not logs:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        counts: dict[str, int] = {}
        for log in logs:
            for text in error_lines(log):
                counts[text] = counts.get(text, 0) + 1
        if collect:
            for text in sorted(counts, key=lambda t: (-counts[t], t)):
                print(f"{counts[text]:6d}  {text}")
            return 0
        allowlist = load_allowlist()
    except (OSError, ValueError) as exc:
        print(f"engine_errors: broken checker inputs: {exc}", file=sys.stderr)
        return 3
    new = {text: n for text, n in counts.items() if not covered(text, allowlist)}
    if not new:
        return 0
    for text in sorted(new, key=lambda t: (-new[t], t)):
        print(f"engine error x{new[text]}: {text}", file=sys.stderr)
    print(
        f"engine_errors: {sum(new.values())} engine ERROR line(s) not in {BASELINE} "
        "(add a 'substr|text|reason' entry with --collect's output if they are noise)",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
