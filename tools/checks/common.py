"""Shared helpers for the repo checks: paths, file lists, baselines, a GDScript lexer, results."""
from __future__ import annotations

import functools
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASELINE_DIR = Path("tools/checks/baselines")
SKIP_DIRS = {".git", ".godot", "__pycache__", ".pytest_cache", "node_modules", "build", ".venv", "venv"}
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


@dataclass
class Result:
    """Outcome of one check. `new` entries fail the check; `known` are baselined or informational."""

    name: str
    new: list[str] = field(default_factory=list)
    known: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    stats: dict = field(default_factory=dict)
    skipped: str = ""

    @property
    def ok(self) -> bool:
        return not self.new

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "ok": self.ok,
            "skipped": self.skipped,
            "new": self.new,
            "known_count": len(self.known),
            "warnings": self.warnings,
            "stats": self.stats,
        }


def report(result: Result, verbose: bool = False, out=None) -> int:
    """Prints a result in a stable, grep-friendly form and returns the process exit code."""
    out = out or sys.stdout
    if result.skipped:
        print(f"{result.name}: SKIP ({result.skipped})", file=out)
        return 0
    for w in result.warnings:
        print(f"{result.name}: warning: {w}", file=out)
    if verbose:
        for k in result.known:
            print(f"{result.name}: known: {k}", file=out)
    for n in result.new:
        print(f"{result.name}: NEW: {n}", file=out)
    status = "PASS" if result.ok else "FAIL"
    print(f"{result.name}: {status} ({len(result.new)} new, {len(result.known)} baselined)", file=out)
    return 0 if result.ok else 1


def list_files(root: Path, patterns: tuple[str, ...] = (), exclude: tuple[str, ...] = ()) -> list[str]:
    """Repo-relative POSIX paths of tracked plus untracked-not-ignored files (git), else a walk."""
    files: list[str] = []
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            capture_output=True,
            check=True,
        ).stdout.decode("utf-8", "surrogateescape")
        if not (root / ".git").exists():
            raise FileNotFoundError(root)
        files = sorted({f for f in out.split("\0") if f and (root / f).is_file()})
    except (OSError, subprocess.CalledProcessError):
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for fn in filenames:
                rel = os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, "/")
                files.append(rel)
        files.sort()
    if patterns:
        files = [f for f in files if matches(f, patterns)]
    if exclude:
        files = [f for f in files if not matches(f, exclude)]
    return files


@functools.lru_cache(maxsize=512)
def glob_regex(pat: str) -> re.Pattern:
    """Git-style glob: `*` and `?` stay inside one path segment, `**` spans segments."""
    out, i = [], 0
    while i < len(pat):
        if pat.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pat.startswith("**", i):
            out.append(".*")
            i += 2
        elif pat[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pat[i] == "?":
            out.append("[^/]")
            i += 1
        elif pat[i] == "[":
            j = pat.find("]", i + 1)
            if j < 0:
                out.append(re.escape(pat[i]))
                i += 1
            else:
                out.append("[" + pat[i + 1 : j].replace("!", "^", 1) + "]")
                i = j + 1
        else:
            out.append(re.escape(pat[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def matches(path: str, patterns: tuple[str, ...] | list[str]) -> bool:
    """True when path matches a glob; a pattern without `/` is matched against the basename."""
    for pat in patterns:
        target = path.rsplit("/", 1)[-1] if "/" not in pat else path
        if glob_regex(pat).match(target):
            return True
    return False


def read_text(root: Path, rel: str) -> str:
    try:
        return (root / rel).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def baseline_path(root: Path, name: str) -> Path:
    return root / BASELINE_DIR / name


def load_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def save_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=1, sort_keys=True) + "\n", encoding="utf-8")


def git(root: Path, *args: str) -> str:
    """stdout of a git command, or "" when it fails (not a repo, unknown ref)."""
    try:
        return subprocess.run(
            ["git", "-C", str(root), *args], capture_output=True, text=True, check=True
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return ""


def resolve_base(root: Path, base: str | None) -> str:
    """A usable diff base: the given ref, else merge-base with origin/main or main; "" if none."""
    candidates = []
    if base and set(base) != {"0"}:
        candidates.append(base)
    candidates += ["origin/main", "main"]
    for ref in candidates:
        sha = git(root, "rev-parse", "--verify", "--quiet", ref + "^{commit}").strip()
        if not sha:
            continue
        mb = git(root, "merge-base", sha, "HEAD").strip()
        return mb or sha
    return ""


def changed_files(root: Path, base: str | None) -> list[str]:
    """Files added, copied, modified or renamed since base (committed and working tree)."""
    ref = resolve_base(root, base)
    if not ref:
        return []
    out = git(root, "diff", "--name-only", "--diff-filter=ACMR", ref)
    out += git(root, "ls-files", "--others", "--exclude-standard")
    return sorted({f for f in out.splitlines() if f and (root / f).is_file()})


def added_lines(root: Path, base: str | None) -> dict[str, set[int]]:
    """{path: {line numbers added or changed since base}} from a zero-context diff."""
    ref = resolve_base(root, base)
    if not ref:
        return {}
    out = git(root, "diff", "-U0", "--diff-filter=ACMR", ref)
    result: dict[str, set[int]] = {}
    cur = None
    for line in out.splitlines():
        if line.startswith("+++ "):
            cur = line[6:] if line.startswith("+++ b/") else None
            if cur:
                result.setdefault(cur, set())
        elif line.startswith("@@") and cur:
            m = re.search(r"\+(\d+)(?:,(\d+))?", line)
            if m:
                start, count = int(m.group(1)), int(m.group(2) or "1")
                result[cur].update(range(start, start + count))
    return result


@dataclass
class Lexed:
    """A GDScript source with strings and comments blanked out, plus what was blanked.

    `code` has the same length and line layout as the source, so positions line up with `src`.
    """

    src: str
    code: str
    strings: list[tuple[int, str]]
    comments: list[tuple[int, str]]

    @property
    def code_lines(self) -> list[str]:
        return self.code.split("\n")

    @property
    def src_lines(self) -> list[str]:
        return self.src.split("\n")


def lex_gd(src: str) -> Lexed:
    """Blanks GDScript strings (", ', triple-quoted, r"", &"", ^"") and # comments."""
    out = list(src)
    strings: list[tuple[int, str]] = []
    comments: list[tuple[int, str]] = []
    i, n, line = 0, len(src), 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c == "#":
            j = src.find("\n", i)
            j = n if j < 0 else j
            comments.append((line, src[i:j]))
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        if c in "\"'":
            quote = src[i : i + 3] if src[i : i + 3] in ('"""', "'''") else c
            raw = i > 0 and src[i - 1] == "r" and (i < 2 or not (src[i - 2].isalnum() or src[i - 2] == "_"))
            j = i + len(quote)
            start_line = line
            buf = []
            while j < n:
                if src[j] == "\\" and not raw and j + 1 < n:
                    buf.append(src[j : j + 2])
                    if src[j + 1] == "\n":
                        line += 1
                    j += 2
                    continue
                if src.startswith(quote, j):
                    break
                if src[j] == "\n":
                    if len(quote) == 1:
                        break
                    line += 1
                buf.append(src[j])
                j += 1
            strings.append((start_line, "".join(buf)))
            for k in range(i + len(quote), min(j, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = min(j + len(quote), n) if j < n and src.startswith(quote, j) else j
            continue
        i += 1
    return Lexed(src, "".join(out), strings, comments)


def indent_of(line: str) -> int:
    """Indent width with a tab counted as 4 columns."""
    width = 0
    for ch in line:
        if ch == "\t":
            width += 4
        elif ch == " ":
            width += 1
        else:
            break
    return width


FUNC_RE = re.compile(r"^(\s*)(?:static\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
CLASS_RE = re.compile(r"^(\s*)class\s+([A-Za-z_][A-Za-z0-9_]*)")
CLASS_NAME_RE = re.compile(r"^class_name\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)


@dataclass
class GdFunc:
    name: str
    qualname: str
    start: int  # 1-based line of `func`
    end: int  # 1-based last line of the body
    indent: int


def gd_functions(lexed: Lexed) -> list[GdFunc]:
    """Named functions with their body line ranges, qualified by inner class (`Inner.method`)."""
    lines = lexed.code_lines
    funcs: list[GdFunc] = []
    classes: list[tuple[int, str]] = []
    for idx, line in enumerate(lines):
        if not line.strip():
            continue
        ind = indent_of(line)
        while classes and ind <= classes[-1][0]:
            classes.pop()
        cm = CLASS_RE.match(line)
        if cm:
            classes.append((ind, cm.group(2)))
            continue
        fm = FUNC_RE.match(line)
        if not fm:
            continue
        end = idx
        for j in range(idx + 1, len(lines)):
            nxt = lines[j]
            if not nxt.strip():
                continue
            if indent_of(nxt) <= ind:
                break
            end = j
        qual = ".".join([c[1] for c in classes] + [fm.group(2)])
        funcs.append(GdFunc(fm.group(2), qual, idx + 1, end + 1, ind))
    return funcs


def identifiers(text: str) -> list[str]:
    return IDENT_RE.findall(text)


def markdown_table(headers: list[str], rows: list[list]) -> str:
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(c).replace("|", "\\|") for c in r) + " |")
    return "\n".join(out)
