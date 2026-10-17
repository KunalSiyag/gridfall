#!/usr/bin/env python3
"""Generate GridFall dynamic soundtrack stems using local ACE-Step 1.5.

Invokes ``/home/kunalsiyag/Projects/ACE-Step-1.5`` with ``offload_to_cpu=True``
so it runs cleanly on a 4GB VRAM GPU (RTX 3050 Laptop GPU), outputting:
  - sounds/music/gridfall_nominal.wav         (Calm isometric synth-ambient grid pulse)
  - sounds/music/gridfall_blackout_crisis.wav (Tense blackout crisis synthwave pulse)
"""
from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import sys
import time
from typing import Dict, List

ACESTEP_ROOT = pathlib.Path("/home/kunalsiyag/Projects/ACE-Step-1.5")
PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
MUSIC_DIR = PROJECT_ROOT / "sounds" / "music"

TRACK_SPECS: List[Dict[str, object]] = [
    {
        "filename": "gridfall_nominal.wav",
        "caption": (
            "Futuristic isometric city builder ambient electronic soundtrack, warm analog synth "
            "pads, clean crystalline arpeggio pulse like a steady electrical power grid, deep "
            "calm sub bass, minimal soft electronic percussion, atmospheric sci-fi strategy game "
            "background music, instrumental"
        ),
        "lyrics": "[Instrumental]",
        "bpm": 96,
        "keyscale": "E minor",
        "timesignature": "4",
        "duration": 25.0,
        "seed": 101,
    },
    {
        "filename": "gridfall_blackout_crisis.wav",
        "caption": (
            "Tense cyberpunk power blackout crisis soundtrack, urgent dark pulsing synth bass, "
            "high voltage industrial synth arpeggios, dramatic warning tension, driving electronic "
            "percussion, emergency control room atmosphere, sci-fi strategy game crisis music, "
            "instrumental"
        ),
        "lyrics": "[Instrumental]",
        "bpm": 122,
        "keyscale": "E minor",
        "timesignature": "4",
        "duration": 25.0,
        "seed": 202,
    },
]


def main() -> None:
    """Initialize ACE-Step 1.5 with CPU offload and generate the GridFall music stems."""
    parser = argparse.ArgumentParser(description="Generate GridFall audio with ACE-Step 1.5")
    parser.add_argument("--force", action="store_true", help="Regenerate existing wav files")
    parser.add_argument("--with-lm", action="store_true", help="Also run 5Hz LM planner")
    args = parser.parse_args()

    for proxy_var in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
        os.environ.pop(proxy_var, None)

    sys.path.insert(0, str(ACESTEP_ROOT))
    os.chdir(str(ACESTEP_ROOT))

    from loguru import logger
    from acestep.handler import AceStepHandler
    from acestep.inference import GenerationConfig, GenerationParams, generate_music
    from acestep.llm_inference import LLMHandler

    MUSIC_DIR.mkdir(parents=True, exist_ok=True)
    pending = [
        spec for spec in TRACK_SPECS
        if args.force or not (MUSIC_DIR / str(spec["filename"])).exists()
    ]
    if not pending:
        logger.info("All GridFall music stems already exist in {}", MUSIC_DIR)
        return

    logger.info("Initializing ACE-Step 1.5 DiT handler (acestep-v15-turbo, offload_to_cpu=True)...")
    t0 = time.time()
    dit_handler = AceStepHandler()
    status_msg, success = dit_handler.initialize_service(
        project_root=str(ACESTEP_ROOT),
        config_path="acestep-v15-turbo",
        device="auto",
        offload_to_cpu=True,
        offload_dit_to_cpu=True,
        quantization="int8_weight_only",
    )
    if not success:
        raise RuntimeError(f"ACE-Step DiT initialization failed: {status_msg}")
    logger.info("DiT ready in {:.1f}s", time.time() - t0)

    llm_handler = LLMHandler()
    use_thinking = False
    if args.with_lm:
        logger.info("Initializing ACE-Step LLM handler (acestep-5Hz-lm-1.7B, offload_to_cpu=True)...")
        lm_status, lm_ok = llm_handler.initialize(
            checkpoint_dir=str(ACESTEP_ROOT / "checkpoints"),
            lm_model_path="acestep-5Hz-lm-1.7B",
            backend="pt",
            device="auto",
            offload_to_cpu=True,
            dtype=None,
        )
        if lm_ok:
            use_thinking = True
        else:
            logger.warning("LM init skipped ({}), continuing with direct DiT text2music", lm_status)

    tmp_save_dir = MUSIC_DIR / "_tmp_acestep"
    tmp_save_dir.mkdir(parents=True, exist_ok=True)

    for spec in pending:
        target_path = MUSIC_DIR / str(spec["filename"])
        logger.info("Generating {} ({}s, {} BPM)...", spec["filename"], spec["duration"], spec["bpm"])
        params = GenerationParams(
            task_type="text2music",
            thinking=use_thinking,
            caption=str(spec["caption"]),
            lyrics=str(spec["lyrics"]),
            bpm=int(spec["bpm"]),
            keyscale=str(spec["keyscale"]),
            timesignature=str(spec["timesignature"]),
            vocal_language="en",
            duration=float(spec["duration"]),
            inference_steps=8,
            guidance_scale=1.0,
            seed=int(spec["seed"]),
        )
        config = GenerationConfig(
            batch_size=1,
            audio_format="wav",
        )
        t_track = time.time()
        result = generate_music(
            dit_handler,
            llm_handler,
            params=params,
            config=config,
            save_dir=str(tmp_save_dir),
        )
        if not result.success or not result.audios:
            raise RuntimeError(f"Failed generating {spec['filename']}: {result.status_message}")

        gen_path = pathlib.Path(result.audios[0]["path"])
        shutil.move(str(gen_path), str(target_path))
        logger.info(
            "Saved {} ({} KB in {:.1f}s)",
            target_path.name,
            target_path.stat().st_size // 1024,
            time.time() - t_track,
        )

    shutil.rmtree(tmp_save_dir, ignore_errors=True)
    logger.info("All GridFall ACE-Step 1.5 audio tracks generated in {}", MUSIC_DIR)


if __name__ == "__main__":
    main()
