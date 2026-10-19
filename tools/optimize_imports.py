#!/usr/bin/env python3
"""Texture import settings for street-level VRAM (slice G2, docs/fp/slices/G2-renderperf.md §3).

Edits Godot texture `.import` files only: VRAM compression (S3TC/BPTC on desktop, RGTC for normal
maps) and mipmaps. Scene imports (`*.glb.import`) are never written, so HC's retarget settings
(`_subresources`, `retarget/*`, bone maps) and every other scene parameter stay byte-identical.

usage: python3 -I tools/optimize_imports.py (--check | --apply | --report) [--root DIR] [paths...]

  --check   list every non-compliant texture import; exit 1 if any is in scope
  --apply   rewrite the non-compliant ones (only the keys below; everything else is kept byte for byte)
  --report  estimated VRAM of every texture import, now and after --apply

Scope without paths: models/** (G2), except models/characters/** (HC), which only --report counts.
textures/real/** and env/** (G1) are listed by --check and --report but never rewritten and never
fail the check; their owner applies the settings with explicit paths. Paths (files or directories,
relative to the root or absolute) select exactly those files, models/characters/** included.
Idempotent: a second --apply changes nothing. Run a heavy `godot --headless --import` afterwards.
"""

from __future__ import annotations

import argparse
import os
import re
import struct
import sys

IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".tga", ".bmp", ".hdr", ".exr")
CHARACTERS = "models/characters/"
NORMAL_RE = re.compile(r"(_nor_gl|_nor_dx|_normal)\.[a-z]+$", re.IGNORECASE)

# Rules per tree, first match wins: (prefix, owner, {key: value}, normal-map aware).
# The values are exactly what Godot writes into [params].
RULES = [
	("models/", "G2", {"compress/mode": "2", "mipmaps/generate": "true"}, True),
	("textures/real/", "G1", {"compress/mode": "2", "mipmaps/generate": "true"}, True),
	("env/", "G1", {"mipmaps/generate": "true"}, False),
]
DEFAULT_SCOPE = ("models/",)


def rel(root: str, path: str) -> str:
	return os.path.relpath(os.path.abspath(path), root).replace(os.sep, "/")


def rule_for(rpath: str):
	for prefix, owner, keys, normal_aware in RULES:
		if rpath.startswith(prefix):
			return owner, keys, normal_aware
	return None


def wanted(rpath: str) -> dict:
	"""The [params] values a texture import at rpath must carry ({} when no rule covers it)."""
	r = rule_for(rpath)
	if r is None:
		return {}
	_owner, keys, normal_aware = r
	want = dict(keys)
	src = rpath[: -len(".import")]
	if normal_aware and NORMAL_RE.search(src):
		want["compress/normal_map"] = "1"
	return want


def is_texture_import(rpath: str) -> bool:
	return rpath.endswith(".import") and rpath[: -len(".import")].lower().endswith(IMAGE_EXTS)


def read_params(text: str) -> tuple[str, dict]:
	"""(importer, params) from an .import file's text."""
	importer = ""
	params = {}
	section = ""
	for line in text.splitlines():
		s = line.strip()
		if s.startswith("[") and s.endswith("]"):
			section = s[1:-1]
			continue
		if "=" not in s:
			continue
		k, v = s.split("=", 1)
		if section == "remap" and k == "importer":
			importer = v.strip('"')
		elif section == "params":
			params[k] = v
	return importer, params


def fix_text(text: str, want: dict) -> str:
	"""text with the [params] keys in want set; untouched lines keep their exact bytes."""
	lines = text.splitlines(keepends=True)
	nl = "\r\n" if text.endswith("\r\n") else "\n"
	seen = set()
	out = []
	section = ""
	params_end = -1
	for line in lines:
		s = line.strip()
		if s.startswith("[") and s.endswith("]"):
			section = s[1:-1]
			out.append(line)
			continue
		if section == "params" and "=" in s:
			k = s.split("=", 1)[0]
			if k in want:
				seen.add(k)
				eol = line[len(line.rstrip("\r\n")):] or nl
				line = "%s=%s%s" % (k, want[k], eol)
			out.append(line)
			params_end = len(out)
			continue
		out.append(line)
	missing = [k for k in want if k not in seen]
	if missing:
		if params_end < 0:
			if out and not out[-1].endswith(("\n", "\r")):
				out[-1] += nl
			out.append(nl + "[params]" + nl + nl)
			params_end = len(out)
		if not out[params_end - 1].endswith(("\n", "\r")):
			out[params_end - 1] += nl
		out[params_end:params_end] = ["%s=%s%s" % (k, want[k], nl) for k in missing]
	return "".join(out)


def collect(root: str, paths: list[str], explicit: bool) -> list[str]:
	"""Repo-relative texture .import paths under the given paths (default scope when not explicit)."""
	found = []
	starts = paths if explicit else ["models", "textures/real", "env"]
	for p in starts:
		ap = p if os.path.isabs(p) else os.path.join(root, p)
		if os.path.isfile(ap):
			cand = ap if ap.endswith(".import") else ap + ".import"
			if os.path.isfile(cand):
				found.append(rel(root, cand))
			continue
		for d, dirs, files in os.walk(ap):
			dirs[:] = sorted(x for x in dirs if not x.startswith("."))
			for f in sorted(files):
				if f.endswith(".import"):
					found.append(rel(root, os.path.join(d, f)))
	return sorted(set(r for r in found if is_texture_import(r)))


def image_info(path: str) -> tuple[int, int, bool]:
	"""(width, height, has_alpha) from the file header; (0, 0, False) when unknown."""
	try:
		with open(path, "rb") as f:
			head = f.read(64 * 1024)
	except OSError:
		return 0, 0, False
	if head[:8] == b"\x89PNG\r\n\x1a\n" and len(head) >= 26:
		w, h = struct.unpack(">II", head[16:24])
		color = head[25]
		return w, h, color in (4, 6) or b"tRNS" in head
	if head[:2] == b"\xff\xd8":
		i = 2
		while i + 9 < len(head):
			if head[i] != 0xFF:
				i += 1
				continue
			marker = head[i + 1]
			if marker in (0xC0, 0xC1, 0xC2, 0xC3):
				h, w = struct.unpack(">HH", head[i + 5:i + 9])
				return w, h, False
			seg = struct.unpack(">H", head[i + 2:i + 4])[0]
			i += 2 + seg
		return 0, 0, False
	if head[:10] == b"#?RADIANCE" or head[:6] == b"#?RGBE":
		m = re.search(rb"\n-Y (\d+) \+X (\d+)", head)
		if m:
			return int(m.group(2)), int(m.group(1)), False
	return 0, 0, False


def vram_bytes(src: str, params: dict, info: tuple[int, int, bool]) -> float:
	"""Estimated VRAM of one texture with these params (desktop: S3TC/RGTC, uncompressed RGBA8)."""
	w, h, alpha = info
	if w == 0:
		return 0.0
	hdr = src.lower().endswith((".hdr", ".exr"))
	mode = params.get("compress/mode", "0")
	if hdr:
		bpp = 8.0 if mode in ("0", "1") else 1.0
	elif mode == "2":
		normal = params.get("compress/normal_map", "0") == "1"
		bpp = 1.0 if (alpha or normal or params.get("compress/high_quality", "false") == "true") else 0.5
	else:
		bpp = 4.0
	mips = 4.0 / 3.0 if params.get("mipmaps/generate", "false") == "true" else 1.0
	return w * h * bpp * mips


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	g = ap.add_mutually_exclusive_group(required=True)
	g.add_argument("--check", action="store_true")
	g.add_argument("--apply", action="store_true")
	g.add_argument("--report", action="store_true")
	ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
	ap.add_argument("paths", nargs="*")
	a = ap.parse_args()
	root = os.path.abspath(a.root)
	explicit = bool(a.paths)
	files = collect(root, a.paths, explicit)
	bad_scope = 0
	changed = 0
	before = after = 0.0
	per_tree: dict = {}
	for r in files:
		ap_ = os.path.join(root, r)
		with open(ap_, "r", encoding="utf-8", newline="") as f:
			text = f.read()
		importer, params = read_params(text)
		if importer and importer != "texture":
			continue
		want = wanted(r)
		in_chars = r.startswith(CHARACTERS)
		# Without paths: G2's models/** only; characters are HC's (report only), G1's trees are listed.
		writable = explicit or (r.startswith(DEFAULT_SCOPE) and not in_chars)
		if a.report:
			src = os.path.join(root, r[: -len(".import")])
			info = image_info(src)
			b0 = vram_bytes(src, params, info)
			new = dict(params)
			new.update(want)
			b1 = vram_bytes(src, new, info)
			before += b0
			after += b1
			tree = "/".join(r.split("/")[:-1][:2])
			t = per_tree.setdefault(tree, [0, 0.0, 0.0])
			t[0] += 1
			t[1] += b0
			t[2] += b1
			continue
		diff = {k: v for k, v in want.items() if params.get(k) != v}
		if not diff:
			continue
		if a.check:
			if writable:
				bad_scope += 1
				print("NONCOMPLIANT %s %s" % (r, " ".join("%s=%s" % kv for kv in sorted(diff.items()))))
			elif not in_chars:
				owner = (rule_for(r) or ("?",))[0]
				print("NOTE (owner %s) %s %s" % (owner, r, " ".join("%s=%s" % kv for kv in sorted(diff.items()))))
			continue
		if a.apply and writable:
			new_text = fix_text(text, want)
			if new_text != text:
				with open(ap_, "w", encoding="utf-8", newline="") as f:
					f.write(new_text)
				changed += 1
	if a.report:
		print("%-28s %6s %12s %12s" % ("tree", "files", "now_MB", "after_MB"))
		for tree in sorted(per_tree):
			n, b0, b1 = per_tree[tree]
			print("%-28s %6d %12.1f %12.1f" % (tree, n, b0 / 1048576.0, b1 / 1048576.0))
		print("REPORT files=%d now_mb=%.1f after_mb=%.1f (upper bound: every file resident once)" % (len(files), before / 1048576.0, after / 1048576.0))
		return 0
	if a.check:
		print("CHECK %s noncompliant=%d files=%d" % ("FAIL" if bad_scope else "OK", bad_scope, len(files)))
		return 1 if bad_scope else 0
	print("APPLY changed=%d files=%d" % (changed, len(files)))
	return 0


if __name__ == "__main__":
	sys.exit(main())
