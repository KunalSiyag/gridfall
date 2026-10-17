#!/usr/bin/env python3
"""Generate cohesive visual concept sheets for GridFall using GMI Cloud hy-image-v3.5-preview.

Produces 4 art-direction sheets in ``concepts/``:
  1. 01_environment_mood.png      - Isometric city mood board (Nominal vs Blackout Crisis)
  2. 02_crisis_buildings_sheet.png - 5 hero crisis landmark buildings for Blender modeling
  3. 03_resident_avatars_sheet.png - 5 AI model resident characters & HUD portrait designs
  4. 04_shader_and_hud_sheet.png   - Emissive power-grid shaders, blackout wave & HUD layout
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import pathlib
import sys
import time
from typing import Any, Dict, List

import aiohttp

API_URL = "https://console.gmicloud.ai/api/v1/ie/requestqueue/apikey/requests"
MODEL_ID = "hy-image-v3.5-preview"

PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
CONCEPTS_DIR = PROJECT_ROOT / "concepts"

STYLE_LOCK = (
    "Cohesive game art direction concept sheet for 'GridFall', a stylized isometric 3D "
    "sci-fi city crisis simulation in Godot 4.7. Clean geometric low-poly architectural forms "
    "with chamfered edges, matte dark basalt slate (#131722) and brushed titanium (#D6DFEB) "
    "surfaces, accented by sharp emissive neon strips in electric cyan (#00F0FF), solar amber "
    "(#FFB800), relay violet (#B44CFF), bio emerald (#10E88A), and blackout crimson (#FF2E54). "
    "Crisp studio concept art presentation on a dark blueprint grid background, high contrast, "
    "no watermarks, sharp clean edges."
)

CONCEPT_BRIEFS: List[Dict[str, str]] = [
    {
        "id": "01_environment_mood",
        "title": "Environment & Blackout Lighting Mood Board",
        "size": "1920x1080",
        "prompt": (
            f"{STYLE_LOCK} Split-screen isometric 3D city environment lookbook comparing two "
            "states of the same city block: LEFT SIDE shows 'Nominal Grid' at twilight with glowing "
            "cyan power conduits embedded in asphalt roads, warm illuminated office windows, and "
            "clean volumetric haze. RIGHT SIDE shows 'Stage 3 Blackout Crisis' where outer blocks "
            "are plunged into dark shadow, crimson emergency beacons pulse on street corners, and "
            "only the central Battery Depot and Substation radiate golden-cyan energy rings across "
            "wet reflective pavement."
        ),
    },
    {
        "id": "02_crisis_buildings_sheet",
        "title": "Crisis Landmark Buildings Turnaround Sheet",
        "size": "1920x1080",
        "prompt": (
            f"{STYLE_LOCK} Architectural 3D game asset turnaround sheet showing five distinct "
            "isometric city buildings arranged in a clean row on square 1x1 city plot bases: "
            "(1) Grid Substation with twin copper-cyan transformer coils and high-voltage pylons; "
            "(2) Battery Depot with stacked modular lithium cells and glowing amber charge meter bars; "
            "(3) Compute Exchange tower with liquid-cooled server racks and cyan-violet data strips; "
            "(4) Council Dome town hall with a hexagonal glass roof and glowing holographic voting ring; "
            "(5) Blackout Pod Shelter with reinforced concrete ribs, solar canopy, and emerald life-support glow."
        ),
    },
    {
        "id": "03_resident_avatars_sheet",
        "title": "Multi-Model AI Resident Characters & Portraits",
        "size": "1920x1080",
        "prompt": (
            f"{STYLE_LOCK} Character concept sheet featuring five stylized autonomous robot-citizen "
            "avatars standing in a lineup with matching bust portraits above each character: "
            "(1) ARGON in white-and-solar-gold civic coat with a warm golden halo visor; "
            "(2) DEEPSEEK in dark slate engineer gear with glowing electric-cyan optical visor and utility pack; "
            "(3) KIMI in sleek titanium diplomat attire with a violet holographic scarf and expressive purple visor; "
            "(4) QWEN in emerald-accented logistics vest carrying a portable battery core; "
            "(5) GROK in weathered charcoal jacket with a sharp crimson X-visor and high-voltage capacitor pack."
        ),
    },
    {
        "id": "04_shader_and_hud_sheet",
        "title": "Grid Shaders, VFX & Broadcast HUD Reference",
        "size": "1920x1080",
        "prompt": (
            f"{STYLE_LOCK} Technical shader and UI design sheet for a 3D strategy simulation: "
            "top half illustrates three Godot 3D shader effects on isometric city tiles: "
            "(A) pulsing cyan energy flow shader along road circuit lines, "
            "(B) building power-down dissolve shader where window emission fades from cyan to dark soot with red warning strobes, "
            "(C) cooperative energy transfer beam arcing between two plots. "
            "Bottom half shows a sleek dark glassmorphism broadcast HUD with a city-wide MW power bar, "
            "social feed cards, and horizontal Cooperation vs Hoarding telemetry meters."
        ),
    },
]


def resolve_gmi_api_key() -> str:
    """Resolve GMI API key from environment or local Factory BYOK settings without printing it."""
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

    raise RuntimeError(
        "GMI_API_KEY not found in environment or ~/.factory/settings.json"
    )


async def poll_request(
    session: aiohttp.ClientSession,
    headers: Dict[str, str],
    request_id: str,
    timeout_s: int = 180,
) -> Dict[str, Any]:
    """Poll GMI requestqueue until completion."""
    poll_url = f"{API_URL}/{request_id}"
    start = time.time()
    while time.time() - start < timeout_s:
        await asyncio.sleep(3.0)
        async with session.get(poll_url, headers=headers, timeout=30) as resp:
            if resp.status == 200:
                data = await resp.json()
                status = data.get("status")
                if status == "success":
                    return data
                if status in ("failed", "error"):
                    raise RuntimeError(f"GMI request {request_id} failed: {data}")
            elif resp.status == 429:
                await asyncio.sleep(5.0)
    raise TimeoutError(f"GMI request {request_id} timed out after {timeout_s}s")


async def generate_one_sheet(
    session: aiohttp.ClientSession,
    headers: Dict[str, str],
    brief: Dict[str, str],
    force: bool = False,
) -> Dict[str, Any]:
    """Generate and download one concept sheet PNG via hy-image-v3.5-preview."""
    out_path = CONCEPTS_DIR / f"{brief['id']}.png"
    if out_path.exists() and not force:
        print(f"[skip] {out_path.name} already exists ({out_path.stat().st_size} bytes)")
        return {"id": brief["id"], "path": str(out_path), "cached": True}

    payload = {
        "model": MODEL_ID,
        "payload": {
            "prompt": brief["prompt"],
            "size": brief["size"],
        },
    }
    t0 = time.time()
    print(f"[start] Generating {brief['id']} ({brief['title']}) via {MODEL_ID}...")
    async with session.post(API_URL, headers=headers, json=payload, timeout=120) as resp:
        if resp.status >= 400:
            body = await resp.text()
            raise RuntimeError(f"HTTP {resp.status} submitting {brief['id']}: {body[:300]}")
        data = await resp.json()

    if data.get("status") != "success":
        req_id = data.get("request_id")
        if not req_id:
            raise RuntimeError(f"Missing request_id for {brief['id']}: {data}")
        data = await poll_request(session, headers, req_id)

    outcome = data.get("outcome", {})
    media_urls = outcome.get("media_urls", [])
    if not media_urls or not media_urls[0].get("url"):
        raise RuntimeError(f"Missing media_urls in outcome for {brief['id']}: {outcome}")

    img_url = media_urls[0]["url"]
    async with session.get(img_url, timeout=60) as img_resp:
        img_resp.raise_for_status()
        img_bytes = await img_resp.read()

    CONCEPTS_DIR.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(img_bytes)
    elapsed = time.time() - t0
    print(f"[done]  Saved {out_path.name} ({len(img_bytes) // 1024} KB in {elapsed:.1f}s)")
    return {
        "id": brief["id"],
        "title": brief["title"],
        "path": str(out_path),
        "bytes": len(img_bytes),
        "elapsed_s": round(elapsed, 2),
        "model": MODEL_ID,
    }


async def run_all(force: bool = False) -> None:
    """Generate all 4 concept sheets concurrently and write manifest.json."""
    api_key = resolve_gmi_api_key()
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    CONCEPTS_DIR.mkdir(parents=True, exist_ok=True)

    async with aiohttp.ClientSession() as session:
        tasks = [generate_one_sheet(session, headers, brief, force=force) for brief in CONCEPT_BRIEFS]
        results = await asyncio.gather(*tasks)

    manifest_path = CONCEPTS_DIR / "manifest.json"
    manifest_path.write_text(
        json.dumps(
            {
                "project": "GridFall",
                "model": MODEL_ID,
                "style_lock": STYLE_LOCK,
                "sheets": results,
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"\nManifest written to {manifest_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate GridFall concept sheets via GMI Cloud.")
    parser.add_argument("--force", action="store_true", help="Regenerate even if PNG exists")
    args = parser.parse_args()
    asyncio.run(run_all(force=args.force))


if __name__ == "__main__":
    main()
