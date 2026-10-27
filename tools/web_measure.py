#!/usr/bin/env python3
"""Measure a live (or local) GridFall web deployment: per-file encoding and first-load bytes.

Reusable after every deploy: it asks the origin what it actually serves, then boots the game in a
headless Chromium and reports the bytes that crossed the wire and how long the first frame took.

usage:
  tools/web_measure.py https://<host>/                 # headers + browser first load
  tools/web_measure.py https://<host>/ --headers-only  # curl-level check, no browser
  tools/web_measure.py http://127.0.0.1:8080/ --browser-timeout 900

needs: python3 (stdlib only), and for the browser half the same setup as deploy/web/smoke.js
(Chrome plus a resolvable playwright-core; set NODE_PATH if it lives outside the repo).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ASSET_RE = re.compile(r'"(?:executable|serviceWorker)":"([^"]+)"|"fileSizes":\{([^}]*)\}')


def fetch(url: str, headers: dict) -> tuple:
    request = urllib.request.Request(url, headers=headers, method="GET")
    with urllib.request.urlopen(request, timeout=120) as response:
        body = response.read()
        return response.status, dict(response.headers), body


def head(url: str, encoding: str) -> dict:
    status, headers, body = fetch(url, {"Accept-Encoding": encoding, "Range": "bytes=0-0"})
    # HTTP field names are case-insensitive; converting HTTPMessage to dict loses that lookup.
    headers = {name.lower(): value for name, value in headers.items()}
    return {
        "status": status,
        "encoding": headers.get("content-encoding", "identity"),
        "cache": headers.get("cache-control", ""),
        "coop": headers.get("cross-origin-opener-policy", ""),
        "coep": headers.get("cross-origin-embedder-policy", ""),
        "type": headers.get("content-type", ""),
        "content_range": headers.get("content-range", ""),
        "probe_bytes": len(body),
    }


def asset_paths(html: str) -> list[str]:
    """The asset URLs a loader page names: srcs, hrefs and the fileSizes keys.

    The executable value is a basename (the engine appends `.pck`/`.wasm`), so it is not a URL;
    the fileSizes keys are.
    """
    found = list(re.findall(r'(?:src|href)="([^"]+)"', html))
    found += re.findall(r'"([^"]*\.(?:pck|wasm|js|json|html|png))":\d+', html)
    out = [""]
    for path in found:
        if path.startswith(("http:", "https:", "data:", "#")):
            continue
        cleaned = path.lstrip("/")
        if cleaned not in out:
            out.append(cleaned)
    return out


def targets(base: str) -> list[str]:
    """The loader page plus every asset the page itself names."""
    status, headers, body = fetch(base, {})
    return asset_paths(body.decode("utf-8", "replace"))


def header_report(base: str) -> list:
    rows = []
    for path in targets(base):
        url = base.rstrip("/") + "/" + path
        for encoding in ("br", "gzip", "identity"):
            try:
                info = head(url, encoding)
            except Exception as error:  # noqa: BLE001 - a probe failure is a finding, not a crash
                rows.append({"path": path or "/", "accept": encoding, "error": str(error)[:120]})
                continue
            rows.append({"path": path or "/", "accept": encoding, **info})
    return rows


def browser_load(base: str, timeout_ms: int, node_path: str) -> dict:
    """Boot the page in headless Chromium and report wire bytes plus time to the first frame."""
    script = Path(tempfile.mkdtemp(prefix="gf-measure-")) / "load.js"
    script.write_text(MEASURE_JS)
    env = dict(os.environ)
    if node_path:
        env["NODE_PATH"] = node_path
    env["GF_MEASURE_URL"] = base
    env["GF_MEASURE_TIMEOUT"] = str(timeout_ms)
    result = subprocess.run(
        ["node", str(script)], env=env, capture_output=True, text=True, timeout=timeout_ms / 1000 + 120,
    )
    if result.returncode != 0:
        return {"error": (result.stderr or result.stdout).strip()[-400:]}
    for line in reversed(result.stdout.splitlines()):
        if line.startswith("GF_MEASURE "):
            return json.loads(line[len("GF_MEASURE "):])
    return {"error": "no measurement line", "stdout": result.stdout[-400:]}


MEASURE_JS = r"""
const { chromium } = require("playwright-core");
const URL_ = process.env.GF_MEASURE_URL;
const TIMEOUT = Number(process.env.GF_MEASURE_TIMEOUT || 600000);
const CHROME = process.env.GF_MEASURE_CHROME || "/usr/bin/google-chrome";

(async () => {
	const browser = await chromium.launch({
		executablePath: CHROME, headless: true,
		args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader",
			"--disable-dev-shm-usage", "--no-sandbox"],
	});
	const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
	const files = [];
	let bytes = 0;
	page.on("response", async (r) => {
		const h = r.headers();
		try {
			const s = await r.request().sizes();
			bytes += s.responseBodySize + s.responseHeadersSize;
			files.push({ url: r.url().replace(URL_.replace(/\/$/, ""), ""), status: r.status(),
				encoding: h["content-encoding"] || "identity", wire: s.responseBodySize });
		} catch (e) {}
	});
	const t0 = Date.now();
	await page.goto(URL_, { waitUntil: "domcontentloaded", timeout: 60000 });
	let firstFrameMs = null;
	const deadline = Date.now() + TIMEOUT;
	while (Date.now() < deadline) {
		const drawn = await page.evaluate(() => {
			const c = document.querySelector("canvas");
			if (!c) return false;
			try {
				const gl = c.getContext("webgl2") || c.getContext("webgl");
				if (!gl) return false;
				// The engine clears to the page background until it renders; sample a few pixels.
				const px = new Uint8Array(4 * 16);
				gl.readPixels(0, 0, 4, 4, gl.RGBA, gl.UNSIGNED_BYTE, px);
				return px.some((v, i) => i % 4 !== 3 && v > 8);
			} catch (e) { return false; }
		}).catch(() => false);
		if (drawn) { firstFrameMs = Date.now() - t0; break; }
		await new Promise((r) => setTimeout(r, 500));
	}
	const byEncoding = {};
	for (const f of files) byEncoding[f.encoding] = (byEncoding[f.encoding] || 0) + f.wire;
	const big = files.filter((f) => f.wire > 100000).sort((a, b) => b.wire - a.wire);
	console.log("GF_MEASURE " + JSON.stringify({
		first_frame_ms: firstFrameMs, wire_bytes: bytes,
		by_encoding: byEncoding, big_files: big, files: files.length,
	}));
	await browser.close();
})().catch((e) => { console.error("GF_MEASURE ERROR", e); process.exit(2); });
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    parser.add_argument("--headers-only", action="store_true")
    parser.add_argument("--browser-timeout", type=int, default=600000)
    parser.add_argument("--node-path", default=os.environ.get("NODE_PATH", ""))
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    base = args.url.rstrip("/") + "/"
    rows = header_report(base)
    print("== per-file encoding (probe: 1 byte via Range) ==")
    for row in rows:
        if "error" in row:
            print(f"  {row['path']:<44} {row['accept']:<9} ERROR {row['error']}")
            continue
        print(f"  {row['path']:<44} {row['accept']:<9} {row['status']} enc={row['encoding']:<8} "
              f"cache={row['cache']:<38} coop={row['coop'] or '-'} coep={row['coep'] or '-'}")
    result = {"headers": rows}
    if not args.headers_only:
        print("== browser first load ==")
        result["browser"] = browser_load(base, args.browser_timeout, args.node_path)
        print(json.dumps(result["browser"], indent=2)[:2000])
    if args.json:
        print("GF_MEASURE_JSON " + json.dumps(result))
    if any("error" in row for row in rows):
        sys.exit(1)


if __name__ == "__main__":
    main()
