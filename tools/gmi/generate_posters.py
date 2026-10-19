#!/usr/bin/env python3
"""Generate GridFall's pre-baked offline poster set with GMI Cloud hy-image-v3.5-preview.

The prompts live in assets/posters/prompts.json, the same file the in-game poster director reads,
so a pre-baked file is found in game by the exact cache key of its prompt. Images carry no text:
Godot draws every name, slogan and headline over them.

Writes assets/posters/<name>.webp (WebP q85, 1024 px long edge for wide art and the Gazette, 512
for portrait notices and placards) and assets/posters/manifest.json:
    {file: {kind, pool, tags, prompt, size, model, elapsed_s, created}}

Usage:
    python3 tools/gmi/generate_posters.py --dry-run            # print the prompts, no network
    python3 tools/gmi/generate_posters.py                      # the one paid run (skips existing)
    python3 tools/gmi/generate_posters.py --only ad_cafe,placard_protest --force
    python3 tools/gmi/generate_posters.py --placeholders       # procedural stand-ins, no network

This is the only paid step of slice D: run it once and commit the outputs; gates never run it.
The API key is resolved like GmiClient (GMI_API_KEY, then ~/.factory/settings.json) and is never
printed or written anywhere.
"""
from __future__ import annotations

import argparse
import asyncio
import datetime
import io
import json
import os
import pathlib
import sys
import time
from typing import Any, Dict, List

API_URL = "https://console.gmicloud.ai/api/v1/ie/requestqueue/apikey/requests"
MODEL_ID = "hy-image-v3.5-preview"
MAX_CONCURRENT = 4
POLL_S = 3.0
DEADLINE_S = 180.0

PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
POSTER_DIR = PROJECT_ROOT / "assets" / "posters"
PROMPTS_PATH = POSTER_DIR / "prompts.json"
MANIFEST_PATH = POSTER_DIR / "manifest.json"


def resolve_gmi_api_key() -> str:
    """GMI_API_KEY, then the Factory BYOK settings; never printed."""
    env_key = os.environ.get("GMI_API_KEY", "").strip()
    if env_key:
        return env_key
    settings_path = pathlib.Path.home() / ".factory" / "settings.json"
    if settings_path.exists():
        try:
            data = json.loads(settings_path.read_text(encoding="utf-8"))
            for item in data.get("customModels", []):
                if isinstance(item, dict) and "gmi-serving.com" in str(item.get("baseUrl", "")):
                    key = str(item.get("apiKey", "")).strip()
                    if key:
                        return key
        except Exception:
            pass
    raise RuntimeError("GMI_API_KEY not found in environment or ~/.factory/settings.json")


def build_set(p: Dict[str, Any]) -> List[Dict[str, Any]]:
    """The pre-baked set: 5 campaigns, 9 ads, 4 Gazette photos, 3 hoardings, 4 notices, 1 placard."""
    lock = p["style_lock"]
    wide = p["sizes"]["wide"]
    tall = p["sizes"]["tall"]
    out: List[Dict[str, Any]] = []

    def add(name: str, kind: str, pool: str, tags: List[str], body: str, size: str, edge: int) -> None:
        out.append({"name": name, "kind": kind, "pool": pool, "tags": tags, "prompt": body + " " + lock, "size": size, "edge": edge})

    for mid, scenes in p["campaign"].items():
        add("campaign_" + mid, "campaign", "campaign_" + mid, [mid], scenes[0], wide, 1024)
    for pool, body in p["ad"].items():
        add(pool, "ad", pool, [pool[3:]], body, wide, 1024)
    for topic, body in p["gazette"].items():
        add("gazette_" + topic, "gazette", "gazette_" + topic, [topic], body, tall, 1024)
    for t, body in p["hoarding"].items():
        add("hoarding_" + t, "hoarding", "hoarding_" + t, [t], body, wide, 1024)
    for t, body in p["notice"].items():
        add("notice_" + t, "notice", "notice_" + t, [t], body, tall, 512)
    for t, body in p["placard"].items():
        add("placard_" + t, "placard", "placard", [t], body, tall, 512)
    return out


def to_webp(raw: bytes, edge: int) -> bytes:
    """Resize to the long edge (dimensions rounded to multiples of 4 for block compression), WebP q85."""
    from PIL import Image

    img = Image.open(io.BytesIO(raw)).convert("RGB")
    w, h = img.size
    s = edge / float(max(w, h))
    nw = max(4, int(round(w * s / 4.0)) * 4)
    nh = max(4, int(round(h * s / 4.0)) * 4)
    img = img.resize((nw, nh), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "WEBP", quality=85, method=6)
    return buf.getvalue()


def placeholder(item: Dict[str, Any]) -> bytes:
    """A soft two-tone gradient stand-in, used only when the live key is unavailable."""
    from PIL import Image

    w, h = (int(v) for v in item["size"].split("x"))
    s = item["edge"] / float(max(w, h))
    w, h = max(4, int(w * s) // 4 * 4), max(4, int(h * s) // 4 * 4)
    seed = sum(ord(c) for c in item["name"])
    a = ((seed * 37) % 160 + 40, (seed * 53) % 160 + 40, (seed * 71) % 160 + 40)
    b = tuple(min(255, c + 70) for c in a)
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            t = (x / w + y / h) * 0.5
            px[x, y] = tuple(int(a[k] + (b[k] - a[k]) * t) for k in range(3))
    buf = io.BytesIO()
    img.save(buf, "WEBP", quality=85)
    return buf.getvalue()


async def generate_one(session: Any, headers: Dict[str, str], item: Dict[str, Any], sem: asyncio.Semaphore, raw_dir: pathlib.Path | None) -> Dict[str, Any]:
    import aiohttp

    async with sem:
        t0 = time.time()
        print(f"[start] {item['name']} {item['size']}")
        payload = {"model": MODEL_ID, "payload": {"prompt": item["prompt"], "size": item["size"]}}
        async with session.post(API_URL, headers=headers, json=payload, timeout=aiohttp.ClientTimeout(total=120)) as resp:
            if resp.status >= 400:
                body = (await resp.text())[:140]
                raise RuntimeError(f"HTTP {resp.status} submitting {item['name']}: {body}")
            data = await resp.json()
        if data.get("status") != "success":
            rid = data.get("request_id")
            if not rid:
                raise RuntimeError(f"no request_id for {item['name']}")
            backoff = 5.0
            while True:
                if time.time() - t0 > DEADLINE_S:
                    raise TimeoutError(f"{item['name']} timed out")
                await asyncio.sleep(POLL_S)
                async with session.get(f"{API_URL}/{rid}", headers=headers, timeout=aiohttp.ClientTimeout(total=30)) as resp:
                    if resp.status == 429:
                        await asyncio.sleep(backoff)
                        backoff = min(backoff * 2.0, 30.0)
                        continue
                    if resp.status != 200:
                        continue
                    data = await resp.json()
                status = data.get("status")
                if status == "success":
                    break
                if status in ("failed", "error"):
                    raise RuntimeError(f"{item['name']} failed: {str(data)[:140]}")
        outcome = data.get("outcome") or {}
        url = ""
        for field in ("media_urls", "urls", "artifacts"):
            arr = outcome.get(field) or []
            if arr:
                first = arr[0]
                url = first.get("url", "") if isinstance(first, dict) else str(first)
                if url:
                    break
        if not url:
            raise RuntimeError(f"no media url for {item['name']}")
        # Public storage: no Authorization header on the download.
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=90)) as img_resp:
            img_resp.raise_for_status()
            raw = await img_resp.read()
        if raw_dir is not None:
            raw_dir.mkdir(parents=True, exist_ok=True)
            (raw_dir / f"{item['name']}.png").write_bytes(raw)
        out = POSTER_DIR / f"{item['name']}.webp"
        out.write_bytes(to_webp(raw, item["edge"]))
        elapsed = round(time.time() - t0, 1)
        print(f"[done]  {item['name']} {len(raw) // 1024} KB raw -> {out.stat().st_size // 1024} KB webp in {elapsed}s")
        return {"elapsed_s": elapsed}


def manifest_entry(item: Dict[str, Any], elapsed: float, model: str) -> Dict[str, Any]:
    return {
        "kind": item["kind"], "pool": item["pool"], "tags": item["tags"], "prompt": item["prompt"],
        "size": item["size"], "model": model, "elapsed_s": elapsed,
        "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def load_manifest() -> Dict[str, Any]:
    if MANIFEST_PATH.exists():
        return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    return {}


def save_manifest(m: Dict[str, Any]) -> None:
    MANIFEST_PATH.write_text(json.dumps(dict(sorted(m.items())), indent=2) + "\n", encoding="utf-8")


async def run_live(items: List[Dict[str, Any]], raw_dir: pathlib.Path | None) -> int:
    import aiohttp

    key = resolve_gmi_api_key()
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    sem = asyncio.Semaphore(MAX_CONCURRENT)
    manifest = load_manifest()
    failures = 0
    async with aiohttp.ClientSession() as session:
        tasks = [generate_one(session, headers, it, sem, raw_dir) for it in items]
        results = await asyncio.gather(*tasks, return_exceptions=True)
    for it, res in zip(items, results):
        if isinstance(res, Exception):
            failures += 1
            print(f"[fail]  {it['name']}: {str(res)[:140]}")
            continue
        manifest[f"{it['name']}.webp"] = manifest_entry(it, res["elapsed_s"], MODEL_ID)
    save_manifest(manifest)
    return failures


def main() -> None:
    ap = argparse.ArgumentParser(description="Generate GridFall's pre-baked poster set via GMI Cloud.")
    ap.add_argument("--dry-run", action="store_true", help="print the prompts only")
    ap.add_argument("--force", action="store_true", help="regenerate files that already exist")
    ap.add_argument("--only", default="", help="comma-separated names (campaign_argon, ad_cafe, ...)")
    ap.add_argument("--placeholders", action="store_true", help="write procedural stand-ins for missing files, no network")
    ap.add_argument("--raw-dir", default="", help="also keep the full-size PNGs here (outside the repo)")
    args = ap.parse_args()

    prompts = json.loads(PROMPTS_PATH.read_text(encoding="utf-8"))
    items = build_set(prompts)
    if args.only:
        wanted = {s.strip() for s in args.only.split(",") if s.strip()}
        items = [it for it in items if it["name"] in wanted]
    if not args.force:
        items = [it for it in items if not (POSTER_DIR / f"{it['name']}.webp").exists()]
    if args.dry_run:
        for it in items:
            print(f"{it['name']}.webp  kind={it['kind']} pool={it['pool']} size={it['size']} edge={it['edge']}\n    {it['prompt']}\n")
        print(f"{len(items)} images would be generated.")
        return
    if not items:
        print("Nothing to generate (every file exists; use --force to redo).")
        return
    if args.placeholders:
        manifest = load_manifest()
        for it in items:
            (POSTER_DIR / f"{it['name']}.webp").write_bytes(placeholder(it))
            manifest[f"{it['name']}.webp"] = manifest_entry(it, 0.0, "placeholder")
        save_manifest(manifest)
        print(f"Wrote {len(items)} placeholders.")
        return
    raw_dir = pathlib.Path(args.raw_dir) if args.raw_dir else None
    failures = asyncio.run(run_live(items, raw_dir))
    print(f"\n{len(items) - failures} of {len(items)} generated; manifest at {MANIFEST_PATH}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
