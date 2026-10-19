#!/usr/bin/env python3
"""Fetch the raw character sources into the shared cache and write the provenance record.

usage: python3 -I tools/characters/fetch.py [--cache DIR] [--avatars all|none|Name,Name]
                                            [--no-anims] [--no-quaternius] [--jobs N]

Rocketbox files come from jsDelivr at the pinned commit (3 tries with backoff), then from
raw.githubusercontent; each one must match the git blob SHA-1 in manifest.json. The Quaternius zips
come through the itch.io free-download flow and must match quaternius.json's sha256. Files already in
the cache with the right hash are not downloaded again. No credentials are needed or read.

Writes models/characters/LICENSES/* and models/characters/PROVENANCE.json in this repo; never copies a
raw source into the repo.
"""

import argparse
import concurrent.futures
import datetime
import hashlib
import http.cookiejar
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
OUT_DIR = os.path.join(REPO, "models", "characters")
UA = "Mozilla/5.0 (X11; Linux x86_64) gridfall-characters-fetch"
TRIES = 3


def now() -> str:
	return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def git_blob_sha1(path: str) -> str:
	h = hashlib.sha1()
	h.update(b"blob %d\0" % os.path.getsize(path))
	with open(path, "rb") as f:
		for chunk in iter(lambda: f.read(1 << 20), b""):
			h.update(chunk)
	return h.hexdigest()


def sha256(path: str) -> str:
	h = hashlib.sha256()
	with open(path, "rb") as f:
		for chunk in iter(lambda: f.read(1 << 20), b""):
			h.update(chunk)
	return h.hexdigest()


def download(url: str, dest: str, opener=None, timeout: float = 120.0) -> dict:
	"""Streams url to dest (through a .part file); returns the response metadata."""
	req = urllib.request.Request(url, headers={"User-Agent": UA})
	part = dest + ".part"
	os.makedirs(os.path.dirname(dest), exist_ok=True)
	op = opener.open if opener else urllib.request.urlopen
	with op(req, timeout=timeout) as r, open(part, "wb") as f:
		shutil.copyfileobj(r, f, 1 << 20)
		meta = {"last_modified": r.headers.get("Last-Modified", ""), "status": r.status}
	os.replace(part, dest)
	return meta


def fetch_rocketbox_file(entry: dict, commit: str, primary: str, fallback: str, cache: str, records: dict) -> str:
	path = entry["path"]
	dest = os.path.join(cache, "rocketbox", path)
	if os.path.isfile(dest) and os.path.getsize(dest) == entry["size"] and git_blob_sha1(dest) == entry["git_blob_sha1"]:
		records.setdefault(path, {"url": primary.format(commit=commit, path=path), "last_modified": "", "fetched": now()})
		return "cached"
	last_err = ""
	for base in (primary, fallback):
		url = base.format(commit=commit, path=urllib.parse.quote(path))
		for attempt in range(TRIES):
			try:
				meta = download(url, dest, timeout=600.0)
				got = git_blob_sha1(dest)
				if got != entry["git_blob_sha1"]:
					os.remove(dest)
					raise ValueError("git blob sha1 mismatch: %s" % got)
				records[path] = {"url": url, "last_modified": meta["last_modified"], "fetched": now()}
				return "fetched"
			except (urllib.error.URLError, OSError, ValueError) as e:
				last_err = "%s: %s" % (type(e).__name__, e)
				time.sleep(2.0 * (2 ** attempt))
	raise RuntimeError("could not fetch %s (%s)" % (path, last_err))


def _csrf(html: str) -> str:
	m = re.search(r'name="csrf_token" value="([^"]+)"', html)
	if not m:
		raise RuntimeError("itch: no csrf_token on the page")
	return m.group(1)


def itch_cdn_url(page: str, upload_id: int) -> str:
	"""The signed CDN URL of a free upload on an itch.io page (no login, no key)."""
	jar = http.cookiejar.CookieJar()
	opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

	def get(url: str, data: dict = None) -> str:
		body = urllib.parse.urlencode(data).encode() if data is not None else None
		req = urllib.request.Request(url, data=body, headers={"User-Agent": UA})
		with opener.open(req, timeout=60) as r:
			return r.read().decode("utf-8", "replace")

	html = get(page)
	dl_page = json.loads(get(page + "/download_url", {"csrf_token": _csrf(html)}))["url"]
	html = get(dl_page)
	if 'data-upload_id="%d"' % upload_id not in html:
		raise RuntimeError("itch: upload %d is no longer offered on %s" % (upload_id, page))
	res = json.loads(get("%s/file/%d?source=game_download" % (page, upload_id), {"csrf_token": _csrf(html)}))
	return res["url"]


def fetch_quaternius(name: str, pack: dict, cache: str, records: dict) -> str:
	dest = os.path.join(cache, "quaternius", pack["zip"])
	status = "cached"
	if not (os.path.isfile(dest) and os.path.getsize(dest) == pack["bytes"] and sha256(dest) == pack["sha256"]):
		last_err = ""
		for attempt in range(TRIES):
			try:
				meta = download(itch_cdn_url(pack["page"], pack["upload_id"]), dest, timeout=600.0)
				got = sha256(dest)
				if got != pack["sha256"]:
					os.remove(dest)
					raise ValueError("sha256 mismatch: %s" % got)
				# The signed URL expires; record the stable page and upload id instead.
				records[name] = {"url": "%s/file/%d" % (pack["page"], pack["upload_id"]), "last_modified": meta["last_modified"], "fetched": now()}
				status = "fetched"
				break
			except (urllib.error.URLError, OSError, ValueError, RuntimeError, KeyError) as e:
				last_err = "%s: %s" % (type(e).__name__, e)
				time.sleep(2.0 * (2 ** attempt))
		else:
			raise RuntimeError("could not fetch %s (%s)" % (name, last_err))
	records.setdefault(name, {"url": "%s/file/%d" % (pack["page"], pack["upload_id"]), "last_modified": pack["last_modified"], "fetched": now()})
	# Extract only the two members we use, to fixed names (never trust archive paths).
	out = os.path.join(cache, "quaternius", name)
	os.makedirs(out, exist_ok=True)
	with zipfile.ZipFile(dest) as z:
		for want, target in ((pack["glb"], os.path.basename(pack["glb"])), (pack["licence_file"], "License.txt")):
			hits = [i for i in z.infolist() if i.filename.endswith("]/" + want) or i.filename == want]
			if len(hits) != 1:
				raise RuntimeError("%s: expected one '%s' in the zip, found %d" % (name, want, len(hits)))
			with z.open(hits[0]) as src, open(os.path.join(out, target), "wb") as dst:
				shutil.copyfileobj(src, dst)
	return status


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("--cache", default=os.path.expanduser("~/.cache/gridfall/characters"))
	ap.add_argument("--avatars", default="all", help="all, none, or a comma-separated list of avatar names")
	ap.add_argument("--no-anims", action="store_true")
	ap.add_argument("--no-quaternius", action="store_true")
	ap.add_argument("--jobs", type=int, default=6)
	a = ap.parse_args()

	with open(os.path.join(HERE, "manifest.json")) as f:
		man = json.load(f)
	with open(os.path.join(HERE, "quaternius.json")) as f:
		qua = json.load(f)
	cache = os.path.abspath(a.cache)
	os.makedirs(cache, exist_ok=True)
	rec_path = os.path.join(cache, "fetch_records.json")
	records = {}
	if os.path.isfile(rec_path):
		with open(rec_path) as f:
			records = json.load(f)

	if a.avatars == "all":
		avatars = list(man["avatars"])
	elif a.avatars == "none":
		avatars = []
	else:
		avatars = [s.strip() for s in a.avatars.split(",") if s.strip()]
		unknown = [n for n in avatars if n not in man["avatars"]]
		if unknown:
			print("unknown avatars: %s" % unknown, file=sys.stderr)
			return 2

	def wanted(path: str) -> bool:
		if path == "LICENSE.md":
			return True
		if path.startswith("Assets/Animations/"):
			return not a.no_anims
		return any("/%s/" % n in path for n in avatars)

	files = [e for e in man["files"] if wanted(e["path"])]
	total = sum(e["size"] for e in files)
	print("rocketbox: %d files, %.1f MB at %s" % (len(files), total / 1e6, man["commit"][:7]))
	failed = []
	done_bytes = 0
	t0 = time.time()
	with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
		futs = {ex.submit(fetch_rocketbox_file, e, man["commit"], man["primary"], man["fallback"], cache, records): e for e in files}
		for i, fut in enumerate(concurrent.futures.as_completed(futs), 1):
			e = futs[fut]
			try:
				st = fut.result()
				done_bytes += e["size"]
			except RuntimeError as err:
				st = "FAILED"
				failed.append(str(err))
			if st != "cached" or i == len(files):
				print("  [%3d/%d] %-7s %s (%.1f MB/s)" % (i, len(files), st, e["path"], done_bytes / 1e6 / max(time.time() - t0, 1e-3)), flush=True)
			if i % 20 == 0:
				with open(rec_path, "w") as f:
					json.dump(records, f, indent=1, sort_keys=True)
	with open(rec_path, "w") as f:
		json.dump(records, f, indent=1, sort_keys=True)

	if not a.no_quaternius:
		for name, pack in qua["packs"].items():
			try:
				print("quaternius %s: %s" % (name, fetch_quaternius(name, pack, cache, records)), flush=True)
			except RuntimeError as err:
				failed.append(str(err))
		with open(rec_path, "w") as f:
			json.dump(records, f, indent=1, sort_keys=True)

	write_provenance(man, qua, cache, records)
	if failed:
		print("FETCH: FAIL %d\n  %s" % (len(failed), "\n  ".join(failed)), file=sys.stderr)
		return 1
	print("FETCH: OK cache=%s" % cache)
	return 0


def write_provenance(man: dict, qua: dict, cache: str, records: dict) -> None:
	"""Licence files and PROVENANCE.json for every source currently verified in the cache."""
	lic_dir = os.path.join(OUT_DIR, "LICENSES")
	os.makedirs(lic_dir, exist_ok=True)
	rb_lic = os.path.join(cache, "rocketbox", "LICENSE.md")
	if os.path.isfile(rb_lic):
		shutil.copyfile(rb_lic, os.path.join(lic_dir, "rocketbox-MIT.txt"))
	rb_files = []
	for e in man["files"]:
		r = records.get(e["path"])
		dest = os.path.join(cache, "rocketbox", e["path"])
		if r is None or not os.path.isfile(dest):
			continue
		rb_files.append({"path": e["path"], "bytes": e["size"], "git_blob_sha1": e["git_blob_sha1"],
			"url": r["url"], "last_modified": r["last_modified"], "fetched": r["fetched"]})
	prov = {
		"note": "Raw sources live in ~/.cache/gridfall/characters/ and are never committed. Rebuild with tools/characters/README.md.",
		"rocketbox": {
			"repo": "https://github.com/microsoft/Microsoft-Rocketbox",
			"commit": man["commit"],
			"licence": "MIT, Copyright (c) 2020 Microsoft",
			"licence_file": "LICENSES/rocketbox-MIT.txt",
			"url_primary": man["primary"],
			"url_fallback": man["fallback"],
			"files": rb_files,
		},
		"quaternius": {},
	}
	for name, pack in qua["packs"].items():
		z = os.path.join(cache, "quaternius", pack["zip"])
		lic = os.path.join(cache, "quaternius", name, "License.txt")
		r = records.get(name)
		if r is None or not os.path.isfile(z):
			continue
		target = "quaternius-%s-License.txt" % name
		if os.path.isfile(lic):
			shutil.copyfile(lic, os.path.join(lic_dir, target))
		prov["quaternius"][name] = {"page": pack["page"], "upload_id": pack["upload_id"], "zip": pack["zip"],
			"bytes": pack["bytes"], "sha256": pack["sha256"], "url": r["url"], "last_modified": r["last_modified"] or pack["last_modified"],
			"fetched": r["fetched"], "licence": qua["licence"], "licence_file": "LICENSES/" + target, "used": pack["glb"]}
	with open(os.path.join(OUT_DIR, "PROVENANCE.json"), "w") as f:
		json.dump(prov, f, indent=1)
		f.write("\n")


if __name__ == "__main__":
	sys.exit(main())
