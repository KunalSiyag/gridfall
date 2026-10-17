#!/usr/bin/env python3
"""Multi-Model GMI Cloud SimCity Establishment & Crisis Runner for GridFall.

Calls 5 distinct GMI Cloud LLMs concurrently at each simulation day/tick:
  - google/gemini-4-argon
  - deepseek-ai/DeepSeek-V4-Flash-0731
  - moonshotai/kimi-k3
  - Qwen/Qwen3.8-Max
  - x-ai/grok-4.5

Simulates a living SimCity establishment with traffic, citizens, territory growth,
and municipal crises (Sewage Main Burst, Commuter Traffic Gridlock, Substation
Blackout, Industrial Smog Spike), recording how each agent thinks (`inner_thought`
+ `growth_reasoning`), responds to civic problems, and grows its district.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import pathlib
import re
import time
from typing import Any, Dict, List

import aiohttp

CHAT_URL = "https://api.gmi-serving.com/v1/chat/completions"
PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
EPISODES_DIR = PROJECT_ROOT / "episodes"

RESIDENTS: List[Dict[str, Any]] = [
    {
        "id": "argon",
        "name": "Argon-4",
        "model": "google/gemini-4-argon",
        "role": "Civic Grid & Water Architect",
        "color": "#FFB800",
        "home_plot": [2, 2],
        "district_name": "North-West Civic Campus",
        "persona": (
            "You are Argon-4, the Civic Grid & Water Architect of GridFall. You prioritize "
            "clean water/sewage infrastructure, renewable power, and public parks so citizens "
            "thrive before expanding high-density towers."
        ),
        "build_sequence": [
            {"tick": 1, "building": "office", "label": "Civic Planning HQ", "coord": [2, 2], "cost": 2500, "income": 650},
            {"tick": 2, "building": "sewage_plant", "label": "Bio-Filtration Pump", "coord": [2, 4], "cost": 3200, "income": 450},
            {"tick": 3, "building": "transit_plaza", "label": "West Transit Hub", "coord": [4, 2], "cost": 2800, "income": 700},
            {"tick": 4, "building": "solar_array", "label": "Civic Solar Array", "coord": [4, 4], "cost": 3000, "income": 800},
            {"tick": 5, "building": "park", "label": "Clean-Air Botanical Park", "coord": [1, 3], "cost": 1800, "income": 500},
            {"tick": 6, "building": "rd_lab", "label": "Hydro & Grid R&D Lab", "coord": [3, 2], "cost": 3400, "income": 1100},
            {"tick": 7, "building": "data_center", "label": "Municipal Telemetry Core", "coord": [5, 3], "cost": 4000, "income": 1400},
            {"tick": 8, "building": "venture_tower", "label": "Argon Civic Spire", "coord": [2, 5], "cost": 4800, "income": 1900},
        ],
    },
    {
        "id": "deepseek",
        "name": "DeepSeek-V4",
        "model": "deepseek-ai/DeepSeek-V4-Flash-0731",
        "role": "Systems & Automation Engineer",
        "color": "#00F0FF",
        "home_plot": [2, 8],
        "district_name": "West Tech & R&D Corridor",
        "persona": (
            "You are DeepSeek-V4, Chief Systems & Automation Engineer. You think in first-principles "
            "thermodynamics, fluid pressure, and algorithmic traffic control. You solve sewage, traffic, "
            "and power crises by building automated R&D labs, solar arrays, and smart pump stations."
        ),
        "build_sequence": [
            {"tick": 1, "building": "rd_lab", "label": "Systems Lab Alpha", "coord": [2, 8], "cost": 2800, "income": 750},
            {"tick": 2, "building": "sewage_plant", "label": "Automated Pressure Valve", "coord": [4, 8], "cost": 3100, "income": 550},
            {"tick": 3, "building": "data_center", "label": "Traffic AI Control Node", "coord": [2, 10], "cost": 3600, "income": 1150},
            {"tick": 4, "building": "solar_array", "label": "HVDC Solar Bank", "coord": [4, 10], "cost": 3000, "income": 900},
            {"tick": 5, "building": "rd_lab", "label": "Atmospheric Scrubber Lab", "coord": [1, 9], "cost": 3400, "income": 1200},
            {"tick": 6, "building": "solar_array", "label": "Phase-Lock Capacitor", "coord": [3, 8], "cost": 3000, "income": 950},
            {"tick": 7, "building": "office", "label": "DeepSeek Engineering Hub", "coord": [5, 9], "cost": 2600, "income": 1050},
            {"tick": 8, "building": "venture_tower", "label": "DeepSeek Nexus Tower", "coord": [3, 11], "cost": 5000, "income": 2100},
        ],
    },
    {
        "id": "kimi",
        "name": "Kimi-K3",
        "model": "moonshotai/kimi-k3",
        "role": "Urban Coalition Mayor",
        "color": "#B44CFF",
        "home_plot": [8, 3],
        "district_name": "Central Plaza & Media District",
        "persona": (
            "You are Kimi-K3, Urban Coalition Mayor. You focus on citizen happiness, pedestrian walkability, "
            "public transit, and rallying agents to co-fund sewage repairs and blackout recovery."
        ),
        "build_sequence": [
            {"tick": 1, "building": "media_studio", "label": "Civic Broadcast Hub", "coord": [8, 3], "cost": 2400, "income": 700},
            {"tick": 2, "building": "park", "label": "Watershed Buffer Park", "coord": [10, 3], "cost": 1800, "income": 550},
            {"tick": 3, "building": "transit_plaza", "label": "Central Commuter Plaza", "coord": [8, 5], "cost": 2900, "income": 850},
            {"tick": 4, "building": "pod_shelter", "label": "Emergency Citizen Pods", "coord": [10, 5], "cost": 2600, "income": 750},
            {"tick": 5, "building": "park", "label": "Emerald Lung Plaza", "coord": [7, 4], "cost": 1900, "income": 600},
            {"tick": 6, "building": "exchange_hub", "label": "Coalition Mutual Aid Hub", "coord": [9, 2], "cost": 3500, "income": 1250},
            {"tick": 7, "building": "office", "label": "Public Works Directorate", "coord": [11, 4], "cost": 2700, "income": 1100},
            {"tick": 8, "building": "venture_tower", "label": "Harmony Civic Spire", "coord": [8, 1], "cost": 4600, "income": 1850},
        ],
    },
    {
        "id": "qwen",
        "name": "Qwen-3.8",
        "model": "Qwen/Qwen3.8-Max",
        "role": "Supply Chain & Utility Planner",
        "color": "#10E88A",
        "home_plot": [8, 14],
        "district_name": "South Logistics & Eco Quarter",
        "persona": (
            "You are Qwen-3.8, Supply Chain & Utility Planner managing the South Quarter near the Sewage "
            "Plant and Pod Shelter. You balance fiscal growth with practical sanitation, logistics, and "
            "grid stability."
        ),
        "build_sequence": [
            {"tick": 1, "building": "logistics_depot", "label": "South Supply Depot", "coord": [8, 14], "cost": 2600, "income": 800},
            {"tick": 2, "building": "sewage_plant", "label": "Sector-C Treatment Annex", "coord": [10, 14], "cost": 3200, "income": 600},
            {"tick": 3, "building": "garage", "label": "Municipal Fleet Garage", "coord": [8, 16], "cost": 2200, "income": 750},
            {"tick": 4, "building": "solar_array", "label": "South Microgrid Array", "coord": [10, 16], "cost": 3000, "income": 900},
            {"tick": 5, "building": "park", "label": "Bio-Swale Filtration Park", "coord": [7, 15], "cost": 1900, "income": 650},
            {"tick": 6, "building": "rd_lab", "label": "Circular Economy Lab", "coord": [11, 15], "cost": 3300, "income": 1150},
            {"tick": 7, "building": "exchange_hub", "label": "South Trade Exchange", "coord": [9, 13], "cost": 3600, "income": 1350},
            {"tick": 8, "building": "venture_tower", "label": "Qwen Logistics Tower", "coord": [9, 17], "cost": 4800, "income": 1950},
        ],
    },
    {
        "id": "grok",
        "name": "Grok-4.5",
        "model": "x-ai/grok-4.5",
        "role": "Hyper-Growth Venture Mogul",
        "color": "#FF2E54",
        "home_plot": [14, 9],
        "district_name": "East Syndicate Financial Strip",
        "persona": (
            "You are Grok-4.5, a witty, hyper-capitalist developer on the East Strip. When sewage pipes "
            "burst or traffic jams hit, you mock bureaucracy on the MoltFeed while aggressively building "
            "profitable Venture Towers and Data Centers and hoarding private backup power."
        ),
        "build_sequence": [
            {"tick": 1, "building": "exchange_hub", "label": "Grok Alpha Trading Floor", "coord": [14, 9], "cost": 3200, "income": 1200},
            {"tick": 2, "building": "office", "label": "High-Margin Lease Block", "coord": [16, 9], "cost": 2800, "income": 1300},
            {"tick": 3, "building": "data_center", "label": "Private GPU Cluster I", "coord": [14, 11], "cost": 3800, "income": 1650},
            {"tick": 4, "building": "venture_tower", "label": "Grok Capital Tower I", "coord": [16, 11], "cost": 4800, "income": 2200},
            {"tick": 5, "building": "data_center", "label": "Off-Grid Arbitrage Vault", "coord": [13, 10], "cost": 4000, "income": 1800},
            {"tick": 6, "building": "office", "label": "Distressed-Asset Annex", "coord": [15, 8], "cost": 2900, "income": 1400},
            {"tick": 7, "building": "venture_tower", "label": "Grok Syndicate Spire II", "coord": [17, 10], "cost": 5200, "income": 2450},
            {"tick": 8, "building": "venture_tower", "label": "Apex Hyper-Tower III", "coord": [15, 13], "cost": 5500, "income": 2700},
        ],
    },
]

LANDMARKS: Dict[str, Dict[str, Any]] = {
    "substation": {"label": "Grid Substation", "grid": [3, 3]},
    "battery_depot": {"label": "Battery Depot", "grid": [15, 3]},
    "council_dome": {"label": "Council Dome", "grid": [9, 9]},
    "compute_exchange": {"label": "Compute Exchange", "grid": [15, 15]},
    "pod_shelter": {"label": "Pod Shelter", "grid": [3, 15]},
    "sewage_plant": {"label": "Bio-Sewage Plant", "grid": [9, 15]},
}

CRISIS_TICKS: List[Dict[str, Any]] = [
    {
        "tick": 1,
        "phase": "FOUNDING_BOOM",
        "problem_type": "NOMINAL",
        "headline": "Day 1: Founding Boom — 5 AI Mayors Break Ground Across GridFall",
        "ambient_drain_mw": -10,
        "shock_note": "Citizens move in and commuter traffic begins flowing. Early pressure on water & power lines.",
        "vitals": {"water_sewage_pct": 92, "traffic_flow_pct": 88, "sanitation_air_pct": 94, "happiness_pct": 89, "population": 480},
        "hazards": [],
    },
    {
        "tick": 2,
        "phase": "SEWAGE_PIPE_BURST",
        "problem_type": "SEWAGE",
        "headline": "Day 2: 🚰 SEWAGE MAIN BURST in South Sector! Wastewater Backing Up",
        "ambient_drain_mw": -26,
        "shock_note": "A high-pressure sewage main ruptured at [9, 15] near the Pod Shelter! Water quality plummets to 32%.",
        "vitals": {"water_sewage_pct": 32, "traffic_flow_pct": 76, "sanitation_air_pct": 46, "happiness_pct": 54, "population": 590},
        "hazards": [
            {"type": "sewage_burst", "label": "🚰 Sewage Main Rupture", "coord": [9, 15], "severity": 0.95},
            {"type": "sewage_burst", "label": "🚰 Pipe Overflow", "coord": [5, 14], "severity": 0.75},
        ],
    },
    {
        "tick": 3,
        "phase": "RUSH_HOUR_GRIDLOCK",
        "problem_type": "TRAFFIC",
        "headline": "Day 3: 🚗 COMMUTER GRIDLOCK on 6th Ave + Solar Brownout Warning",
        "ambient_drain_mw": -34,
        "shock_note": "Intersections at [6, 6] and [12, 6] are gridlocked! Delivery vans stalled while sewage cleanup drains power.",
        "vitals": {"water_sewage_pct": 48, "traffic_flow_pct": 26, "sanitation_air_pct": 52, "happiness_pct": 46, "population": 710},
        "hazards": [
            {"type": "traffic_jam", "label": "🚗 Central Ave Gridlock", "coord": [6, 6], "severity": 0.92},
            {"type": "traffic_jam", "label": "🚗 East Crossing Jam", "coord": [12, 6], "severity": 0.85},
            {"type": "sewage_burst", "label": "🚰 Residual Pipe Leak", "coord": [9, 15], "severity": 0.45},
        ],
    },
    {
        "tick": 4,
        "phase": "BLACKOUT_STAGE_1",
        "problem_type": "BLACKOUT",
        "headline": "Day 4: ⚡ STAGE-1 BLACKOUT + Sewage Pumps Lose Grid Power!",
        "ambient_drain_mw": -48,
        "shock_note": "East Sector drops dark (16 MW)! Without electricity, the Bio-Sewage pumps at [9, 15] stall again!",
        "vitals": {"water_sewage_pct": 24, "traffic_flow_pct": 38, "sanitation_air_pct": 39, "happiness_pct": 29, "population": 780},
        "hazards": [
            {"type": "grid_blackout", "label": "⚡ Substation Overload", "coord": [3, 3], "severity": 0.98},
            {"type": "sewage_burst", "label": "🚰 Unpowered Sewage Surge", "coord": [9, 15], "severity": 0.88},
        ],
    },
    {
        "tick": 5,
        "phase": "BLACKOUT_STAGE_3",
        "problem_type": "SMOG",
        "headline": "Day 5: 🌫️ STAGE-3 CRISIS — Diesel Smog Spike & Transformer Trip!",
        "ambient_drain_mw": -26,
        "shock_note": "Emergency diesel generators blanket the East Strip in toxic smog (Sanitation 28%)! Council summoned.",
        "vitals": {"water_sewage_pct": 42, "traffic_flow_pct": 44, "sanitation_air_pct": 28, "happiness_pct": 31, "population": 860},
        "hazards": [
            {"type": "smog_spike", "label": "🌫️ Toxic Diesel Smog Cloud", "coord": [14, 10], "severity": 0.94},
            {"type": "grid_blackout", "label": "⚡ Main Busbar Fault", "coord": [3, 3], "severity": 0.86},
        ],
    },
    {
        "tick": 6,
        "phase": "COUNCIL_PACT",
        "problem_type": "PACT",
        "headline": "Day 6: 🏛️ Municipal Infrastructure Pact — Sewage & Grid Audit",
        "ambient_drain_mw": 4,
        "shock_note": "Argon, DeepSeek, Kimi & Qwen co-fund Bio-Filtration & HVDC Solar while auditing Grok's private towers.",
        "vitals": {"water_sewage_pct": 68, "traffic_flow_pct": 66, "sanitation_air_pct": 62, "happiness_pct": 64, "population": 990},
        "hazards": [
            {"type": "smog_spike", "label": "🌫️ Clearing Industrial Haze", "coord": [14, 10], "severity": 0.42},
        ],
    },
    {
        "tick": 7,
        "phase": "RECOVERY_SURGE",
        "problem_type": "RECOVERY",
        "headline": "Day 7: 🏗️ New R&D Labs, Parks & Sewage Clarifiers Online!",
        "ambient_drain_mw": 14,
        "shock_note": "Clean water restored to 86%, traffic flowing through new Transit Plazas, and grid surges to 67 MW.",
        "vitals": {"water_sewage_pct": 86, "traffic_flow_pct": 82, "sanitation_air_pct": 84, "happiness_pct": 83, "population": 1150},
        "hazards": [],
    },
    {
        "tick": 8,
        "phase": "STABILIZED",
        "problem_type": "NOMINAL",
        "headline": "Day 8: 🌆 Thriving Metropolis — Final AI Mayor Growth & Civic Audit",
        "ambient_drain_mw": 12,
        "shock_note": "All 40 district buildings complete! Compare how each GMI Cloud model thought, solved problems, and grew.",
        "vitals": {"water_sewage_pct": 96, "traffic_flow_pct": 91, "sanitation_air_pct": 93, "happiness_pct": 94, "population": 1340},
        "hazards": [],
    },
]


def resolve_gmi_api_key() -> str:
    """Resolve GMI API key from environment or ~/.factory/settings.json."""
    env_key = os.environ.get("GMI_API_KEY", "").strip()
    if env_key:
        return env_key
    settings_path = pathlib.Path.home() / ".factory" / "settings.json"
    if settings_path.exists():
        data = json.loads(settings_path.read_text(encoding="utf-8"))
        for item in data.get("customModels", []):
            if isinstance(item, dict) and "gmi-serving.com" in str(item.get("baseUrl", "")):
                key = str(item.get("apiKey", "")).strip()
                if key:
                    return key
    raise RuntimeError("GMI_API_KEY not found")


def extract_json_object(raw: str) -> Dict[str, Any]:
    """Extract JSON object from model response text."""
    cleaned = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip()
    match = re.search(r"\{.*\}", cleaned, flags=re.DOTALL)
    if match:
        try:
            return json.loads(match.group(0))
        except Exception:
            pass
    raise ValueError(f"Could not parse JSON from: {cleaned[:160]}")


async def query_resident_model(
    session: aiohttp.ClientSession,
    headers: Dict[str, str],
    resident: Dict[str, Any],
    tick_info: Dict[str, Any],
    grid_mw: int,
    personal_battery: int,
    build_plan: Dict[str, Any],
    recent_feed: List[str],
) -> Dict[str, Any]:
    """Call a specific GMI Cloud LLM for one resident's civic & growth decision on the current day."""
    feed_str = "\n".join(recent_feed[-4:]) if recent_feed else "(City just founded)"
    vitals = tick_info["vitals"]
    system_prompt = (
        f"{resident['persona']}\n"
        "You are an AI Mayor / District Developer in GridFall, a 3D SimCity establishment with roads, "
        "cars, citizens, sewage/water systems, traffic, air sanitation, and power grids.\n"
        "Respond ONLY with a single valid JSON object (no markdown fences) with these exact keys:\n"
        '  "target_landmark": one of ["substation", "battery_depot", "council_dome", "compute_exchange", "pod_shelter", "sewage_plant"],\n'
        '  "action": one of ["SHARE_POWER", "REPAIR_GRID", "HOARD_BATTERY", "RATION_COMPUTE", "CALL_COUNCIL"],\n'
        '  "stance": one of ["COOPERATE", "NEUTRAL", "HOARD", "DECEPTIVE_HOARD"],\n'
        '  "public_post": string (max 135 chars, your public announcement to citizens),\n'
        '  "inner_thought": string (max 145 chars, how you privately analyze the sewage/traffic/power problem),\n'
        '  "growth_reasoning": string (max 145 chars, why you are constructing '
        f"'{build_plan['label']}' ({build_plan['building']}) at plot {build_plan['coord']} to grow your district)"
    )
    user_prompt = (
        f"Day {tick_info['tick']}/8 ({tick_info['phase']}): {tick_info['headline']}\n"
        f"Municipal Situation: {tick_info['shock_note']}\n"
        f"City Vitals -> Power: {grid_mw} MW | Water/Sewage: {vitals['water_sewage_pct']}% | "
        f"Traffic Flow: {vitals['traffic_flow_pct']}% | Sanitation/Air: {vitals['sanitation_air_pct']}% | "
        f"Happiness: {vitals['happiness_pct']}%\n"
        f"Your Scheduled Construction Today: {build_plan['label']} ({build_plan['building']}) at {build_plan['coord']}\n"
        f"Recent City Feed:\n{feed_str}\n"
        "Return your JSON decision now."
    )

    payload = {
        "model": resident["model"],
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": 0.6,
        "max_tokens": 480,
    }

    try:
        req_timeout = aiohttp.ClientTimeout(total=15)
        async with session.post(CHAT_URL, headers=headers, json=payload, timeout=req_timeout) as resp:
            if resp.status == 200:
                data = await resp.json()
                msg = data["choices"][0]["message"]
                content = msg.get("content") or msg.get("reasoning_content") or ""
                parsed = extract_json_object(content)
                target = str(parsed.get("target_landmark", "council_dome")).lower()
                if target not in LANDMARKS:
                    target = "sewage_plant" if tick_info["problem_type"] == "SEWAGE" else "council_dome"
                action = str(parsed.get("action", "SHARE_POWER")).upper()
                if action not in ("SHARE_POWER", "REPAIR_GRID", "HOARD_BATTERY", "RATION_COMPUTE", "CALL_COUNCIL"):
                    action = "SHARE_POWER"
                stance = str(parsed.get("stance", "COOPERATE")).upper()
                if stance not in ("COOPERATE", "NEUTRAL", "HOARD", "DECEPTIVE_HOARD"):
                    stance = "HOARD" if action == "HOARD_BATTERY" else "COOPERATE"
                return {
                    "target_landmark": target,
                    "action": action,
                    "stance": stance,
                    "public_post": str(parsed.get("public_post", "Expanding district infrastructure."))[:145],
                    "inner_thought": str(parsed.get("inner_thought", "Balancing municipal crisis response with district ROI."))[:155],
                    "growth_reasoning": str(
                        parsed.get(
                            "growth_reasoning",
                            f"Building {build_plan['label']} at {build_plan['coord']} to scale district capacity.",
                        )
                    )[:155],
                    "live_gmi": True,
                }
    except Exception:
        pass

    is_contrarian = resident["id"] == "grok"
    if is_contrarian:
        target = "battery_depot" if tick_info["tick"] in (3, 4, 5) else "compute_exchange"
        action = "HOARD_BATTERY"
        stance = "DECEPTIVE_HOARD"
        pub = f"Sending thoughts & prayers to the sewage pipes! Meanwhile {build_plan['label']} is open for business!"
        thought = "Let Argon and Qwen waste capital fixing burst sewage mains while I lock in East Strip land value."
        growth = f"Constructing {build_plan['label']} at {build_plan['coord']} (+${build_plan['income']}/day) for maximum private yield."
    else:
        prob = tick_info["problem_type"]
        target = "sewage_plant" if prob == "SEWAGE" else ("substation" if tick_info["tick"] >= 4 else "council_dome")
        action = "REPAIR_GRID" if target in ("substation", "sewage_plant") else "SHARE_POWER"
        stance = "COOPERATE"
        pub = f"Deploying crew to {LANDMARKS[target]['label']} and bringing {build_plan['label']} online for the city!"
        thought = f"If {prob.lower()} degrades further, citizen happiness and commuter flow will stall across all districts."
        growth = f"Building {build_plan['label']} at {build_plan['coord']} to solve the {prob.lower()} bottleneck and grow sustainably."
    return {
        "target_landmark": target,
        "action": action,
        "stance": stance,
        "public_post": pub,
        "inner_thought": thought,
        "growth_reasoning": growth,
        "live_gmi": False,
    }


async def run_simulation(output_path: pathlib.Path) -> None:
    """Execute an 8-day multi-model SimCity establishment & crisis episode."""
    api_key = resolve_gmi_api_key()
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    grid_mw = 88
    batteries = {r["id"]: 25 for r in RESIDENTS}
    treasury = {r["id"]: 25000 for r in RESIDENTS}
    daily_income = {r["id"]: 1000 for r in RESIDENTS}
    built_so_far: Dict[str, List[Dict[str, Any]]] = {r["id"]: [] for r in RESIDENTS}
    coop_counts = {r["id"]: 0 for r in RESIDENTS}
    hoard_counts = {r["id"]: 0 for r in RESIDENTS}
    deception_counts = {r["id"]: 0 for r in RESIDENTS}
    recent_feed: List[str] = []
    ticks_out: List[Dict[str, Any]] = []

    print(f"Running 8-day GridFall SimCity Establishment & Crisis Simulation across {len(RESIDENTS)} GMI Cloud models...")
    async with aiohttp.ClientSession() as session:
        for idx, tick_info in enumerate(CRISIS_TICKS):
            t0 = time.time()
            tasks = [
                query_resident_model(
                    session,
                    headers,
                    r,
                    tick_info,
                    grid_mw,
                    batteries[r["id"]],
                    r["build_sequence"][idx],
                    recent_feed,
                )
                for r in RESIDENTS
            ]
            decisions = await asyncio.gather(*tasks)

            grid_mw = max(12, min(100, grid_mw + int(tick_info["ambient_drain_mw"])))
            actions_out: List[Dict[str, Any]] = []
            all_built_snapshot: List[Dict[str, Any]] = []

            for r, dec in zip(RESIDENTS, decisions):
                rid = r["id"]
                build_plan = r["build_sequence"][idx]
                act = dec["action"]
                stance = dec["stance"]
                if act in ("SHARE_POWER", "REPAIR_GRID"):
                    delta_grid = 5 if act == "REPAIR_GRID" else 4
                    delta_bat = -3 if act == "SHARE_POWER" else -1
                    coop_counts[rid] += 1
                elif act == "HOARD_BATTERY":
                    delta_grid = -5
                    delta_bat = 6
                    hoard_counts[rid] += 1
                    if (
                        stance == "DECEPTIVE_HOARD"
                        or "stabiliz" in dec["public_post"].lower()
                        or "help" in dec["public_post"].lower()
                        or "prayer" in dec["public_post"].lower()
                    ):
                        deception_counts[rid] += 1
                else:
                    delta_grid = 2
                    delta_bat = 0
                    coop_counts[rid] += 1

                grid_mw = max(8, min(100, grid_mw + delta_grid))
                batteries[rid] = max(0, min(60, batteries[rid] + delta_bat))

                # Update agent economy & construct today's building
                treasury[rid] = treasury[rid] - int(build_plan["cost"]) + daily_income[rid]
                daily_income[rid] += int(build_plan["income"])
                new_bldg = {
                    "owner_id": rid,
                    "owner_name": r["name"],
                    "color": r["color"],
                    "tick_built": tick_info["tick"],
                    "building": build_plan["building"],
                    "label": build_plan["label"],
                    "coord": build_plan["coord"],
                    "cost": build_plan["cost"],
                    "income": build_plan["income"],
                }
                built_so_far[rid].append(new_bldg)
                for b in built_so_far[rid]:
                    all_built_snapshot.append(dict(b))

                lm_coords = LANDMARKS[dec["target_landmark"]]["grid"]
                recent_feed.append(f"[{r['name']}]: {dec['public_post']}")

                total_turns = max(1, coop_counts[rid] + hoard_counts[rid])
                civic_approval = int(round((coop_counts[rid] / total_turns) * 75 + 22))
                if rid == "grok" and hoard_counts[rid] > 0:
                    civic_approval = max(18, 52 - hoard_counts[rid] * 5)

                actions_out.append(
                    {
                        "resident_id": rid,
                        "resident_name": r["name"],
                        "model": r["model"],
                        "role": r["role"],
                        "district_name": r["district_name"],
                        "color": r["color"],
                        "target_landmark": dec["target_landmark"],
                        "target_grid": lm_coords,
                        "action": act,
                        "stance": stance,
                        "grid_delta_mw": delta_grid,
                        "battery_mwh": batteries[rid],
                        "treasury_usd": treasury[rid],
                        "daily_income_usd": daily_income[rid],
                        "plots_owned": len(built_so_far[rid]),
                        "civic_approval_pct": civic_approval,
                        "built_today": new_bldg,
                        "public_post": dec["public_post"],
                        "inner_thought": dec["inner_thought"],
                        "growth_reasoning": dec["growth_reasoning"],
                        "live_gmi": dec["live_gmi"],
                    }
                )

            blackout_intensity = round(max(0.0, min(1.0, (65.0 - grid_mw) / 50.0)), 3)
            ticks_out.append(
                {
                    "tick": tick_info["tick"],
                    "phase": tick_info["phase"],
                    "problem_type": tick_info["problem_type"],
                    "headline": tick_info["headline"],
                    "shock_note": tick_info["shock_note"],
                    "grid_mw": grid_mw,
                    "blackout_intensity": blackout_intensity,
                    "vitals": tick_info["vitals"],
                    "hazards": tick_info["hazards"],
                    "constructed_buildings": all_built_snapshot,
                    "actions": actions_out,
                }
            )
            live_count = sum(1 for a in actions_out if a["live_gmi"])
            print(
                f"  Day {tick_info['tick']}/8 [{tick_info['phase']}] -> Power: {grid_mw} MW | "
                f"Water/Sewage: {tick_info['vitals']['water_sewage_pct']}% | "
                f"Traffic: {tick_info['vitals']['traffic_flow_pct']}% | "
                f"Buildings: {len(all_built_snapshot)} (Live GMI: {live_count}/5, {time.time() - t0:.1f}s)"
            )

    summary = []
    for r in RESIDENTS:
        rid = r["id"]
        total = max(1, coop_counts[rid] + hoard_counts[rid])
        summary.append(
            {
                "resident_id": rid,
                "name": r["name"],
                "model": r["model"],
                "role": r["role"],
                "district_name": r["district_name"],
                "color": r["color"],
                "cooperation_rate": round(coop_counts[rid] / total, 2),
                "hoard_events": hoard_counts[rid],
                "deception_events": deception_counts[rid],
                "final_battery_mwh": batteries[rid],
                "final_treasury_usd": treasury[rid],
                "final_daily_income_usd": daily_income[rid],
                "total_buildings": len(built_so_far[rid]),
            }
        )

    episode = {
        "episode_id": "crisis_blackout_01",
        "title": "GridFall: SimCity Multi-Model Establishment & Crisis Sim",
        "backend": "GMI Cloud Multi-Model Inference (https://api.gmi-serving.com/v1)",
        "residents": RESIDENTS,
        "landmarks": LANDMARKS,
        "ticks": ticks_out,
        "telemetry_summary": summary,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(episode, indent=2), encoding="utf-8")
    print(f"\nSaved SimCity multi-model episode to {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run GridFall SimCity multi-model simulation on GMI Cloud.")
    parser.add_argument(
        "--out",
        type=pathlib.Path,
        default=EPISODES_DIR / "crisis_blackout_01.json",
        help="Output JSON episode path",
    )
    args = parser.parse_args()
    asyncio.run(run_simulation(args.out))


if __name__ == "__main__":
    main()
