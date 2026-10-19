#!/usr/bin/env python3
"""Synthesise slice I's on-foot sound assets into sounds/fp/ (docs/fp/slices/I-audio.md section 7).

Everything is built from numpy noise, oscillators, pulse trains and modal resonators with fixed
seeds, so a re-run gives the same samples and byte-identical files. Two formats:

- WAV (16-bit PCM, imported uncompressed) for every sound the game starts often: footsteps,
  horns, UI cues, the engine loops and the siren. Starting an Ogg Vorbis playback costs about
  0.4 ms on the main thread (a decoder per start), a WAV about 1 us, and the audio budget is
  0.3 ms per frame.
- Ogg Vorbis (ffmpeg libvorbis -q 4, bit-exact) for the long loops started rarely: the beds,
  construction, fire, river, fountain and plant hum.

Loops are synthesised circularly (FFT-domain filters, events wrapped around the end, integer
cycle counts), so they loop without a seam. The matching .import files are written with the
loop flag (Ogg loop=true/false, WAV edit/loop_mode=2/1); an existing .import keeps everything
else (its uid and paths).

Levels: loops and beds are normalised to an RMS target and one-shots to a peak target, so the
mix lives in the game's volume_db tables (scripts/fp/audio/audio_bank.gd), not in the files.

usage: python3 tools/audio/synth_fp_sfx.py [--out sounds/fp] [--only a,b] [--wav-dir DIR] [--list]
"""
from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import zlib

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, fftconvolve, sosfilt

SR = 44100
BASE_SEED = 20261019
ROOT = pathlib.Path(__file__).resolve().parents[2]
SURFACES = ["asphalt", "sidewalk", "lot", "grass", "dirt", "bridge"]
STEP_VARIANTS = 6
SPLASH_VARIANTS = 4


# ------------------------------------------------------------------ helpers

def rng_for(name: str) -> np.random.Generator:
    return np.random.default_rng(BASE_SEED ^ zlib.crc32(name.encode()))


def secs(n: int) -> np.ndarray:
    return np.arange(n) / SR


def freqs(n: int) -> np.ndarray:
    return np.fft.rfftfreq(n, 1.0 / SR)


def rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(x)) + 1e-20))


def unit(x: np.ndarray) -> np.ndarray:
    return x / rms(x)


def db(v: float) -> float:
    return 10.0 ** (v / 20.0)


def circ_filter(x: np.ndarray, resp) -> np.ndarray:
    """Zero-phase circular filter: multiplies the spectrum by resp(f). Keeps loops seamless."""
    n = x.shape[0]
    g = resp(freqs(n))
    if x.ndim == 2:
        g = g[:, None]
    return np.fft.irfft(np.fft.rfft(x, axis=0) * g, n=n, axis=0)


def band(lo: float | None = None, hi: float | None = None, order: int = 2):
    def r(f: np.ndarray) -> np.ndarray:
        g = np.ones_like(f)
        if hi:
            g = g / np.sqrt(1.0 + (f / hi) ** (2 * order))
        if lo:
            ff = np.maximum(f, 1e-3)
            g = g / np.sqrt(1.0 + (lo / ff) ** (2 * order))
        return g
    return r


def bell(fc: float, q: float, gain_db: float):
    big = db(gain_db)

    def r(f: np.ndarray) -> np.ndarray:
        ff = np.maximum(f, 1e-3)
        return 1.0 + (big - 1.0) / (1.0 + (q * (ff / fc - fc / ff)) ** 2)
    return r


def chain(*rs):
    def r(f: np.ndarray) -> np.ndarray:
        g = np.ones_like(f)
        for x in rs:
            g = g * x(f)
        return g
    return r


def noise(rng: np.random.Generator, n: int, slope_db: float = 0.0, ch: int = 1) -> np.ndarray:
    """Circular coloured noise with unit RMS; slope_db per octave (-3 pink, -6 brown)."""
    w = rng.standard_normal((n, ch)) if ch > 1 else rng.standard_normal(n)
    f = freqs(n)
    f[0] = f[1]
    g = (f / 1000.0) ** (slope_db / 6.0206)
    g[0] = 0.0
    if ch > 1:
        g = g[:, None]
    return unit(np.fft.irfft(np.fft.rfft(w, axis=0) * g, n=n, axis=0))


def wander(rng: np.random.Generator, n: int, rate_hz: float) -> np.ndarray:
    """Smooth circular random control signal, unit RMS, mostly below rate_hz."""
    return unit(circ_filter(rng.standard_normal(n), lambda f: np.exp(-(f / rate_hz) ** 2)))


def add_at(buf: np.ndarray, sig: np.ndarray, start: int, wrap: bool = True) -> None:
    n = buf.shape[0]
    if not wrap:
        if start >= n:
            return
        m = min(sig.shape[0], n - start)
        if start < 0:
            sig = sig[-start:]
            m = min(sig.shape[0], n)
            start = 0
        buf[start:start + m] += sig[:m]
        return
    pos = start % n
    rest = sig
    while rest.shape[0] > 0:
        take = min(n - pos, rest.shape[0])
        buf[pos:pos + take] += rest[:take]
        rest = rest[take:]
        pos = 0


def pan(sig: np.ndarray, p: float) -> np.ndarray:
    """Mono to stereo, equal power; p in -1 (left) .. 1 (right)."""
    th = (p + 1.0) * np.pi / 4.0
    return np.stack([sig * np.cos(th), sig * np.sin(th)], axis=1)


def lowpass(x: np.ndarray, hz: float, order: int = 2) -> np.ndarray:
    return sosfilt(butter(order, min(hz, SR * 0.45), "low", fs=SR, output="sos"), x, axis=0)


def highpass(x: np.ndarray, hz: float, order: int = 2) -> np.ndarray:
    return sosfilt(butter(order, hz, "high", fs=SR, output="sos"), x, axis=0)


def bandpass(x: np.ndarray, lo: float, hi: float, order: int = 2) -> np.ndarray:
    return sosfilt(butter(order, [lo, min(hi, SR * 0.45)], "band", fs=SR, output="sos"), x, axis=0)


def env_ad(n: int, attack: float, decay: float) -> np.ndarray:
    t = secs(n)
    a = np.clip(t / max(attack, 1e-4), 0.0, 1.0)
    return a * a * (3 - 2 * a) * np.exp(-np.maximum(t - attack, 0.0) / decay)


def env_hann(n: int) -> np.ndarray:
    return np.hanning(n) if n > 2 else np.ones(n)


def modes(n: int, parts: list[tuple[float, float, float]], rng: np.random.Generator | None = None) -> np.ndarray:
    """Sum of damped sines: (freq Hz, decay s, amplitude)."""
    t = secs(n)
    out = np.zeros(n)
    for f, d, a in parts:
        ph = rng.uniform(0, 2 * np.pi) if rng is not None else 0.0
        out += a * np.exp(-t / d) * np.sin(2 * np.pi * f * t + ph)
    return out


def tone(freq_hz: np.ndarray, harmonics: list[float]) -> np.ndarray:
    """Band-limited additive tone following an instantaneous frequency curve."""
    ph = 2 * np.pi * np.cumsum(freq_hz) / SR
    out = np.zeros_like(freq_hz)
    for k, a in enumerate(harmonics, start=1):
        if a == 0.0:
            continue
        lim = np.clip((SR * 0.45 - k * freq_hz) / 2000.0, 0.0, 1.0)
        out += a * lim * np.sin(k * ph)
    return out


def reverb_ir(rng: np.random.Generator, t60: float, ch: int = 2, predelay: float = 0.012,
              damp_hz: float = 5000.0, length: float | None = None) -> np.ndarray:
    n = int((length or t60 * 1.1) * SR)
    t = secs(n)
    env = 10.0 ** (-3.0 * t / t60)
    ir = rng.standard_normal((n, ch)) * env[:, None]
    ir = lowpass(ir, damp_hz, 1)
    ir[: int(predelay * SR)] = 0.0
    return ir / np.sqrt(np.sum(ir ** 2) / ch)


def circ_conv(x: np.ndarray, ir: np.ndarray) -> np.ndarray:
    n = x.shape[0]
    h = np.zeros((n,) + ir.shape[1:])
    m = min(n, ir.shape[0])
    h[:m] = ir[:m]
    return np.fft.irfft(np.fft.rfft(x, axis=0) * np.fft.rfft(h, axis=0), n=n, axis=0)


def stereo_reverb(x: np.ndarray, rng: np.random.Generator, t60: float, wet: float,
                  damp_hz: float = 5000.0, circular: bool = True) -> np.ndarray:
    """x mono or stereo; returns stereo dry + wet."""
    if x.ndim == 1:
        x = np.stack([x, x], axis=1)
    ir = reverb_ir(rng, t60, 2, damp_hz=damp_hz)
    mono = x.mean(axis=1)
    if circular:
        w = np.stack([circ_conv(mono, ir[:, 0]), circ_conv(mono, ir[:, 1])], axis=1)
    else:
        w = np.stack([fftconvolve(mono, ir[:, 0])[: x.shape[0]], fftconvolve(mono, ir[:, 1])[: x.shape[0]]], axis=1)
    return x + w * wet


def norm_rms(x: np.ndarray, target_db: float, ceiling_db: float = -1.0) -> np.ndarray:
    y = x * (db(target_db) / rms(x))
    pk = np.max(np.abs(y))
    if pk > db(ceiling_db):
        # soft-limit the rare peaks instead of lowering the whole loop.
        lim = db(ceiling_db)
        y = np.where(np.abs(y) > lim * 0.7, np.sign(y) * (lim * 0.7 + (lim * 0.3) * np.tanh((np.abs(y) - lim * 0.7) / (lim * 0.3))), y)
    return y


def norm_peak(x: np.ndarray, target_db: float) -> np.ndarray:
    return x * (db(target_db) / (np.max(np.abs(x)) + 1e-12))


def norm_short(x: np.ndarray, target_db: float, window: float = 0.03, ceiling_db: float = -1.0) -> np.ndarray:
    """Scales so the loudest `window` of x has RMS target_db (perceived loudness of a transient),
    then lowers it if a peak would pass ceiling_db."""
    w = max(1, int(window * SR))
    e = np.convolve(np.square(x), np.ones(w) / w, mode="valid")
    y = x * (db(target_db) / (np.sqrt(np.max(e)) + 1e-12))
    pk = np.max(np.abs(y))
    return y * (db(ceiling_db) / pk) if pk > db(ceiling_db) else y


def fade_edges(x: np.ndarray, fin: float = 0.002, fout: float = 0.02) -> np.ndarray:
    n = x.shape[0]
    a = int(fin * SR)
    b = int(fout * SR)
    g = np.ones(n)
    if a > 0:
        g[:a] = np.linspace(0, 1, a)
    if b > 0:
        g[-b:] *= np.linspace(1, 0, b) ** 2
    return x * (g[:, None] if x.ndim == 2 else g)


def poisson_times(rng: np.random.Generator, rate: float, dur: float) -> np.ndarray:
    k = rng.poisson(rate * dur)
    return np.sort(rng.uniform(0, dur, k))


# ------------------------------------------------------------------ vehicles

def engine_pulses(rng: np.random.Generator, n: int, seconds: float, f_fire: float, cyl: list[float],
                  amp_jit: float, time_jit: float, hunt: float, hunt_cycles: int,
                  res: list[tuple[float, float, float]], burst: float) -> np.ndarray:
    """Exhaust pulse train with an integer number of firings per loop (seamless)."""
    cycles = int(round(seconds * f_fire))
    f = cycles / seconds
    buf = np.zeros(n)
    pl = int(0.07 * SR)
    t = secs(pl)
    shapes = []
    for c in range(len(cyl)):
        shift = 1.0 + 0.03 * (c - 1.5) / 1.5
        sh = np.zeros(pl)
        for fr, dec, a in res:
            sh += a * np.exp(-t / dec) * np.sin(2 * np.pi * fr * shift * t)
        nb = lowpass(rng.standard_normal(pl), 2400.0) * np.exp(-t / 0.0025) * burst
        shapes.append(sh + nb)
    amp = db(0)
    for k in range(cycles):
        disp = hunt / (2 * np.pi * hunt_cycles / seconds) * np.sin(2 * np.pi * hunt_cycles * k / cycles) if hunt > 0 else 0.0
        tk = k / f + disp + rng.normal(0, time_jit)
        a = cyl[k % len(cyl)] * (1.0 + amp_jit * rng.standard_normal()) * amp
        add_at(buf, shapes[k % len(cyl)] * a, int(round(tk * SR)))
    return buf


def synth_engine_idle() -> np.ndarray:
    rng = rng_for("engine_idle")
    seconds = 3.0
    n = int(seconds * SR)
    ex = engine_pulses(rng, n, seconds, 26.7, [1.0, 0.84, 0.95, 0.88], 0.07, 0.0005, 0.015, 2,
                       [(92.0, 0.018, 1.0), (176.0, 0.010, 0.55), (330.0, 0.006, 0.35), (610.0, 0.003, 0.18)], 0.35)
    ex = circ_filter(ex, chain(band(25.0, 1600.0, 2), bell(110.0, 1.2, 5.0)))
    # Valve-train tick and injector clatter: faint, bright, locked to the firing rate.
    tick = engine_pulses(rng, n, seconds, 26.7 * 2, [1.0, 0.7], 0.3, 0.0003, 0.0, 1,
                         [(2900.0, 0.0012, 1.0), (4300.0, 0.0008, 0.6)], 0.2)
    hiss = circ_filter(noise(rng, n, -3.0), chain(band(350.0, 3200.0, 2)))
    am = 1.0 + 0.25 * np.sin(2 * np.pi * 26.7 * secs(n))
    body = unit(ex) + 0.05 * unit(tick) + 0.08 * hiss * am
    return norm_rms(body, -20.0)


def synth_engine_run() -> np.ndarray:
    rng = rng_for("engine_run")
    seconds = 4.0
    n = int(seconds * SR)
    ex = engine_pulses(rng, n, seconds, 70.0, [1.0, 0.9, 0.96, 0.92], 0.12, 0.00025, 0.006, 3,
                       [(140.0, 0.010, 1.0), (285.0, 0.006, 0.6), (590.0, 0.004, 0.35), (1150.0, 0.002, 0.12)], 0.45)
    ex = circ_filter(ex, chain(band(45.0, 2200.0, 2), bell(150.0, 1.0, 4.0)))
    # Tyre and road roar dominates a city car at 30-50 km/h: broadband, hump near 900 Hz.
    tyre = circ_filter(noise(rng, n, -2.0), chain(band(250.0, 3000.0, 2), bell(900.0, 1.1, 7.0)))
    tyre *= 1.0 + 0.16 * wander(rng, n, 6.0)
    rumble = circ_filter(noise(rng, n, -6.0), band(20.0, 140.0, 2))
    body = 0.85 * unit(ex) + 1.0 * unit(tyre) + 0.45 * unit(rumble)
    return norm_rms(body, -20.0)


def horn(seconds: float, name: str) -> np.ndarray:
    rng = rng_for(name)
    n = int(seconds * SR)
    t = secs(n)
    out = np.zeros(n)
    for f0, a in [(408.0, 1.0), (512.0, 0.85)]:
        bend = 1.0 - 0.035 * np.exp(-t / 0.018)
        fr = f0 * bend * (1.0 + 0.002 * np.sin(2 * np.pi * 31.0 * t))
        out += a * tone(fr, [1.0 / (k ** 0.75) for k in range(1, 16)])
    out = np.tanh(1.6 * out / np.max(np.abs(out)))
    out = circ_filter(out, chain(band(300.0, 6000.0, 2), bell(2300.0, 2.5, 7.0), bell(3400.0, 3.0, 4.0)))
    env = np.clip(t / 0.012, 0, 1) * np.clip((seconds - t) / 0.05, 0, 1)
    out *= env
    out += 0.08 * rng.standard_normal(n) * np.exp(-t / 0.004)
    return norm_peak(fade_edges(out, 0.0, 0.01), -1.0)


def synth_siren_two_tone() -> np.ndarray:
    seconds = 4.4
    n = int(seconds * SR)
    t = secs(n)
    half = 0.55
    hi, lo = 587.0, 440.0
    # Tone schedule with 30 ms exponential glides between the two pitches.
    seg = np.floor(t / half).astype(int)
    target = np.where(seg % 2 == 0, lo, hi)
    since = t - seg * half
    prev = np.where(seg % 2 == 0, hi, lo)
    g = np.exp(-since / 0.012)
    fr = target * (1 - g) + prev * g
    # Make the loop hold a whole number of cycles so its phase closes.
    total = np.sum(fr) / SR
    fr *= round(total) / total
    out = tone(fr, [1.0, 0.18, 0.42, 0.1, 0.25, 0.06, 0.16, 0.04, 0.1, 0.03, 0.07])
    out = np.tanh(1.3 * unit(out) / 2.5)
    out = circ_filter(out, chain(band(380.0, 5200.0, 3), bell(1500.0, 1.5, 4.0), bell(3000.0, 2.0, 3.0)))
    return norm_rms(out, -18.0)


# ------------------------------------------------------------------ footsteps

STEP_STYLE = {
    # thump Hz, thump decay, thump amp, click centre Hz, click amp, grit rate/s, grit amp,
    # scuff amp, ring modes, swish amp, crunch rate/s, crunch amp, loudest-30-ms RMS dBFS
    "asphalt": dict(th=95, td=0.022, ta=0.8, cc=2600, ca=0.9, gr=900, ga=0.22, sc=0.30, ring=[], sw=0.0, cr=0, cra=0.0, loud=-15.0),
    "sidewalk": dict(th=110, td=0.020, ta=0.75, cc=3000, ca=1.0, gr=300, ga=0.10, sc=0.22, ring=[(880, 0.012, 0.25)], sw=0.0, cr=0, cra=0.0, loud=-15.0),
    "lot": dict(th=120, td=0.018, ta=0.7, cc=3400, ca=1.0, gr=200, ga=0.08, sc=0.25, ring=[(1750, 0.010, 0.22), (2950, 0.006, 0.12)], sw=0.0, cr=0, cra=0.0, loud=-15.0),
    "grass": dict(th=80, td=0.030, ta=0.65, cc=1800, ca=0.08, gr=0, ga=0.0, sc=0.0, ring=[], sw=0.55, cr=120, cra=0.12, loud=-19.0),
    "dirt": dict(th=85, td=0.026, ta=0.7, cc=2000, ca=0.25, gr=0, ga=0.0, sc=0.1, ring=[], sw=0.1, cr=520, cra=0.55, loud=-16.0),
    "bridge": dict(th=105, td=0.03, ta=0.85, cc=2500, ca=0.75, gr=250, ga=0.1, sc=0.2,
                   ring=[(148, 0.16, 0.35), (233, 0.12, 0.25), (415, 0.08, 0.16), (2650, 0.02, 0.05)], sw=0.0, cr=0, cra=0.0, loud=-14.0),
}


def contact(rng: np.random.Generator, n: int, st: dict, strength: float, j: float) -> np.ndarray:
    t = secs(n)
    out = np.zeros(n)
    # Sole impact: a damped low thump.
    out += 0.7 * st["ta"] * strength * np.exp(-t / (st["td"] * j)) * np.sin(2 * np.pi * st["th"] * j * t) * (1 - np.exp(-t / 0.0015))
    # Heel click: a very short bright burst.
    if st["ca"] > 0:
        c = rng.standard_normal(n) * np.exp(-t / 0.0011)
        c = bandpass(c, st["cc"] * 0.45 * j, min(st["cc"] * 2.2 * j, 16000.0))
        out += 0.6 * st["ca"] * strength * c / (np.max(np.abs(c)) + 1e-9)
    # Body: mid-band noise with a short decay.
    b = bandpass(rng.standard_normal(n), 180.0, 1600.0) * np.exp(-t / 0.028)
    out += 0.45 * strength * b / (np.max(np.abs(b)) + 1e-9)
    for f, d, a in st["ring"]:
        out += a * strength * np.exp(-t / d) * np.sin(2 * np.pi * f * j * t + rng.uniform(0, 6.28))
    return out


def grains(rng: np.random.Generator, n: int, rate: float, dur: float, lo: float, hi: float, env_decay: float) -> np.ndarray:
    out = np.zeros(n)
    for tk in poisson_times(rng, rate, dur):
        gl = int(rng.uniform(0.0004, 0.002) * SR)
        g = rng.standard_normal(gl) * np.exp(-secs(gl) / (gl / SR / 3.0))
        add_at(out, g * rng.pareto(2.5) * np.exp(-tk / env_decay), int(tk * SR), wrap=False)
    return bandpass(out, lo, hi)


def synth_step(surface: str, k: int) -> np.ndarray:
    name = "footstep_%s_%d" % (surface, k)
    rng = rng_for(name)
    st = STEP_STYLE[surface]
    right = k % 2 == 0
    n = int(0.38 * SR)
    out = np.zeros(n)
    j = rng.uniform(0.92, 1.08) * (0.97 if right else 1.0)
    heel_t = int(0.004 * SR)
    heel = contact(rng, n - heel_t, st, 1.0 * (1.06 if right else 1.0), j)
    out[heel_t:] += heel
    # Roll onto the toe 60-110 ms later: a softer second contact.
    toe_t = int(rng.uniform(0.06, 0.11) * SR)
    toe = contact(rng, n - toe_t, st, rng.uniform(0.35, 0.55), j * 1.12)
    out[toe_t:] += toe
    t = secs(n)
    if st["ga"] > 0:
        out += st["ga"] * unit(grains(rng, n, st["gr"], 0.07, 2500.0, 9000.0, 0.03) + 1e-12) * 0.25 * (t < 0.12)
    if st["sc"] > 0:
        sc_t = toe_t + int(rng.uniform(0.01, 0.03) * SR)
        sl = n - sc_t
        s = bandpass(rng.standard_normal(sl), 1800.0, 8000.0) * env_ad(sl, 0.006, 0.025)
        out[sc_t:] += st["sc"] * s / (np.max(np.abs(s)) + 1e-9) * 0.5
    if st["sw"] > 0:
        s = bandpass(rng.standard_normal(n), 1400.0, 7500.0) * env_ad(n, 0.016, 0.075)
        s *= 1.0 + 0.6 * np.abs(bandpass(rng.standard_normal(n), 20.0, 120.0)) / 0.3
        out += st["sw"] * s / (np.max(np.abs(s)) + 1e-9)
    if st["cra"] > 0:
        c = grains(rng, n, st["cr"], rng.uniform(0.10, 0.16), 900.0, 6500.0, 0.06)
        out += st["cra"] * c / (np.max(np.abs(c)) + 1e-9)
    out = lowpass(out, 11000.0, 2)
    return norm_short(fade_edges(out, 0.0005, 0.06), st["loud"] + rng.uniform(-1.2, 0.6))


def synth_splash(k: int) -> np.ndarray:
    """The wet layer of a step on soaked paving: a sole slapping a film of water, a spray of
    droplets and a puddle bubble or two. Played over the dry step, scaled by how wet it is."""
    rng = rng_for("footstep_splash_%d" % k)
    n = int(0.3 * SR)
    t = secs(n)
    out = np.zeros(n)
    # Slap: broadband burst, low-mid heavy, very fast attack.
    slap = bandpass(rng.standard_normal(n), 300.0, 4500.0) * env_ad(n, 0.002, rng.uniform(0.018, 0.03))
    out += 0.9 * slap / (np.max(np.abs(slap)) + 1e-9)
    # Spray: droplets thrown up and landing over the next 60-120 ms.
    spray = grains(rng, n, rng.uniform(500.0, 800.0), rng.uniform(0.06, 0.12), 2500.0, 11000.0, 0.05)
    out += 0.6 * spray / (np.max(np.abs(spray)) + 1e-9)
    # One or two bubbles from the displaced water.
    for _ in range(int(rng.integers(1, 3))):
        f0 = np.exp(rng.uniform(np.log(600.0), np.log(1600.0)))
        tau = rng.uniform(0.006, 0.014)
        bl = int(tau * 6 * SR) + 8
        bt = secs(bl)
        fr = f0 * (1.0 + 0.8 * bt / (tau * 6))
        b = np.sin(2 * np.pi * np.cumsum(fr) / SR) * np.exp(-bt / tau) * (1 - np.exp(-bt / 0.0008))
        add_at(out, 0.2 * b * rng.uniform(0.5, 1.0), int(rng.uniform(0.01, 0.06) * SR), wrap=False)
    out *= np.exp(-np.maximum(t - 0.18, 0.0) / 0.03)
    out = lowpass(out, 12000.0, 2)
    return norm_short(fade_edges(out, 0.0005, 0.05), -17.0 + rng.uniform(-1.0, 0.5))


# ------------------------------------------------------------------ places

def metal_hit(rng: np.random.Generator, f0: float, decay: float, amp: float) -> np.ndarray:
    n = int(min(decay * 6, 1.5) * SR)
    parts = [(f0 * r, decay * d, a) for r, d, a in [(1.0, 1.0, 1.0), (2.76, 0.6, 0.55), (5.40, 0.35, 0.35), (8.93, 0.2, 0.2), (1.58, 0.8, 0.3)]]
    s = modes(n, parts, rng)
    t = secs(n)
    s += 0.8 * highpass(rng.standard_normal(n), 2000.0) * np.exp(-t / 0.0015)
    return amp * s / (np.max(np.abs(s)) + 1e-9)


def synth_construction() -> np.ndarray:
    rng = rng_for("construction_loop")
    seconds = 16.0
    n = int(seconds * SR)
    t = secs(n)
    # Diesel generator: 1500 rpm four-cylinder, steady, behind the hoarding.
    gen = engine_pulses(rng, n, seconds, 50.0, [1.0, 0.92, 0.97, 0.9], 0.08, 0.0003, 0.004, 4,
                        [(100.0, 0.012, 1.0), (205.0, 0.007, 0.5), (420.0, 0.004, 0.25)], 0.3)
    gen = circ_filter(gen, band(40.0, 1400.0, 2))
    out = 0.55 * unit(gen)
    out += 0.25 * circ_filter(noise(rng, n, -3.0), band(300.0, 2500.0, 2))
    # Hammering: two workers, bursts of hits with pauses.
    for f0, amp, gap, pace in [(1180.0, 1.0, (1.6, 3.8), (0.42, 0.62)), (860.0, 0.55, (2.4, 5.0), (0.5, 0.8))]:
        tk = rng.uniform(0, 2.0)
        while tk < seconds:
            hits = rng.integers(3, 7)
            sp = rng.uniform(*pace)
            for h in range(hits):
                hit = metal_hit(rng, f0 * rng.uniform(0.97, 1.03), rng.uniform(0.05, 0.11), amp * rng.uniform(0.7, 1.0))
                if amp < 0.9:
                    hit = lowpass(hit, 3500.0)
                add_at(out, hit * 2.4, int((tk + h * sp + rng.normal(0, 0.02)) * SR))
            tk += hits * sp + rng.uniform(*gap)
    # A rebar or scaffold-tube clank, twice per loop.
    for tk in [3.3, 11.1]:
        add_at(out, metal_hit(rng, 520.0, 0.25, 2.2), int(tk * SR))
        add_at(out, metal_hit(rng, 690.0, 0.18, 1.2), int((tk + 0.09) * SR))
    # An angle grinder: one 2.6 s cut.
    gl = int(2.6 * SR)
    gt = secs(gl)
    gf = 3150.0 * (1.0 - 0.06 * np.clip(gt / 0.3, 0, 1) + 0.015 * np.sin(2 * np.pi * 2.3 * gt))
    grind = tone(gf, [1.0, 0.5, 0.3, 0.15]) + 0.9 * bandpass(rng.standard_normal(gl), 2500.0, 9000.0)
    grind *= env_ad(gl, 0.25, 9.0) * np.clip((2.6 - gt) / 0.35, 0, 1)
    add_at(out, 0.5 * grind / np.max(np.abs(grind)), int(6.2 * SR))
    # Reversing beeper on a site truck, far off: four beeps.
    for b in range(4):
        bl = int(0.42 * SR)
        beep = np.sin(2 * np.pi * 1030.0 * secs(bl)) * env_ad(bl, 0.01, 1.0) * np.clip((0.42 - secs(bl)) / 0.01, 0, 1)
        add_at(out, 0.12 * beep, int((13.0 + b * 0.84) * SR))
    out = circ_conv(out, reverb_ir(rng, 0.9, 1, damp_hz=4000.0)[:, 0]) * 0.25 + out
    return norm_rms(out, -20.0)


def synth_fire() -> np.ndarray:
    rng = rng_for("fire_crackle")
    seconds = 8.0
    n = int(seconds * SR)
    roar = circ_filter(noise(rng, n, -6.0), band(35.0, 420.0, 2)) * (1.0 + 0.35 * wander(rng, n, 0.8))
    whoosh = circ_filter(noise(rng, n, -3.0), band(500.0, 3200.0, 2)) * (1.0 + 0.5 * wander(rng, n, 1.5))
    out = 0.9 * unit(roar) + 0.22 * unit(whoosh)
    crack = np.zeros(n)
    # Crackles cluster: a slow random rate envelope drives a Poisson process.
    rate = 22.0 * np.clip(1.0 + 0.8 * wander(rng, n, 0.7), 0.15, 3.0)
    p = rate / SR
    hits = np.nonzero(rng.uniform(0, 1, n) < p)[0]
    for h in hits:
        gl = int(rng.uniform(0.0002, 0.0022) * SR) + 2
        g = rng.standard_normal(gl) * np.exp(-secs(gl) / (gl / SR / 2.5))
        add_at(crack, g * min(rng.pareto(1.8) + 0.2, 12.0), int(h))
    crack = circ_filter(crack, band(1300.0, 12000.0, 2))
    pops = np.zeros(n)
    for tk in poisson_times(rng, 1.4, seconds):
        pl = int(0.04 * SR)
        f0 = rng.uniform(280.0, 900.0)
        pops_s = modes(pl, [(f0, 0.008, 1.0), (f0 * 2.3, 0.004, 0.5)], rng) + 0.6 * rng.standard_normal(pl) * np.exp(-secs(pl) / 0.002)
        add_at(pops, pops_s * rng.uniform(0.4, 1.0), int(tk * SR))
    out += 0.55 * crack / rms(crack) * 0.35 + 0.35 * pops / (rms(pops) + 1e-9) * 0.25
    return norm_rms(out, -20.0)


def water(rng: np.random.Generator, n: int, seconds: float, calm: float, bubble_rate: float, splash: float) -> np.ndarray:
    wash = circ_filter(noise(rng, n, -3.0), band(160.0, 5000.0, 2)) * (1.0 + 0.3 * wander(rng, n, 0.5))
    out = 0.6 * unit(wash)
    # Lapping against the bank: soft low sloshes.
    slosh = np.zeros(n)
    for tk in poisson_times(rng, 0.9 * calm, seconds):
        sl = int(rng.uniform(0.35, 0.9) * SR)
        s = bandpass(rng.standard_normal(sl), 90.0, 520.0) * env_ad(sl, rng.uniform(0.06, 0.14), rng.uniform(0.12, 0.3))
        add_at(slosh, s * rng.uniform(0.5, 1.0), int(tk * SR))
    out += 0.9 * calm * slosh / (rms(slosh) + 1e-9) * 0.5
    # Bubbles: Minnaert resonances with the characteristic upward chirp.
    bub = np.zeros(n)
    for tk in poisson_times(rng, bubble_rate, seconds):
        f0 = np.exp(rng.uniform(np.log(380.0), np.log(2600.0)))
        tau = rng.uniform(0.004, 0.018) * (900.0 / f0) ** 0.5
        bl = int(tau * 6 * SR) + 8
        bt = secs(bl)
        fr = f0 * (1.0 + 0.9 * bt / (tau * 6))
        s = np.sin(2 * np.pi * np.cumsum(fr) / SR) * np.exp(-bt / tau) * (1 - np.exp(-bt / 0.0008))
        add_at(bub, s * rng.uniform(0.2, 1.0) ** 2, int(tk * SR))
    out += 0.5 * bub / (rms(bub) + 1e-9) * 0.4
    if splash > 0:
        sp = np.zeros(n)
        for tk in poisson_times(rng, 1400.0, seconds):
            gl = int(rng.uniform(0.0006, 0.004) * SR) + 2
            g = rng.standard_normal(gl) * np.exp(-secs(gl) / (gl / SR / 3.0))
            add_at(sp, g * rng.uniform(0.2, 1.0), int(tk * SR))
        sp = circ_filter(sp, band(900.0, 10000.0, 2))
        out += splash * sp / rms(sp)
    return out


def synth_river_loop() -> np.ndarray:
    rng = rng_for("river_loop")
    seconds = 12.0
    n = int(seconds * SR)
    return norm_rms(water(rng, n, seconds, 1.0, 16.0, 0.0), -20.0)


def synth_river_bed() -> np.ndarray:
    rng = rng_for("river_bed")
    seconds = 30.0
    n = int(seconds * SR)
    common = water(rng, n, seconds, 1.0, 12.0, 0.0)
    left = water(rng, n, seconds, 0.8, 9.0, 0.0)
    right = water(rng, n, seconds, 0.8, 9.0, 0.0)
    st = np.stack([0.65 * common + 0.55 * left, 0.65 * common + 0.55 * right], axis=1)
    st += 0.2 * circ_filter(noise(rng, n, -6.0, 2), band(20.0, 160.0, 2))
    return norm_rms(st, -20.0)


def synth_fountain() -> np.ndarray:
    rng = rng_for("fountain_loop")
    seconds = 6.0
    n = int(seconds * SR)
    out = water(rng, n, seconds, 0.35, 70.0, 0.9)
    return norm_rms(out, -20.0)


def synth_plant_hum() -> np.ndarray:
    rng = rng_for("plant_hum")
    seconds = 5.0
    n = int(seconds * SR)
    t = secs(n)
    hum = np.zeros(n)
    for k, a in [(1, 0.25), (2, 1.0), (4, 0.45), (6, 0.3), (8, 0.18), (10, 0.12), (12, 0.08)]:
        hum += a * np.sin(2 * np.pi * 50.0 * k * t + rng.uniform(0, 6.28))
    hum *= 1.0 + 0.05 * wander(rng, n, 0.6)
    whine = np.sin(2 * np.pi * 1200.0 * t) * 0.04 * (1.0 + 0.4 * wander(rng, n, 0.3))
    fan = circ_filter(noise(rng, n, -3.0), chain(band(180.0, 2200.0, 2), bell(600.0, 1.0, 3.0)))
    out = 0.8 * unit(hum) + whine * 5 + 0.7 * fan
    return norm_rms(out, -20.0)


# ------------------------------------------------------------------ beds

def bird_syllable(rng: np.random.Generator, f_start: float, f_end: float, dur: float, harm: float = 0.15,
                  trill: float = 0.0) -> np.ndarray:
    n = int(dur * SR)
    t = secs(n)
    u = t / dur
    fr = f_start * (f_end / f_start) ** (u ** rng.uniform(0.7, 1.4))
    if trill > 0:
        fr *= 1.0 + 0.08 * np.sin(2 * np.pi * trill * t)
    s = tone(fr, [1.0, harm, harm * 0.3])
    return s * np.sin(np.pi * np.clip(u, 0, 1)) ** rng.uniform(0.6, 1.4)


def bird_song(rng: np.random.Generator, kind: str) -> np.ndarray:
    parts: list[tuple[float, np.ndarray]] = []
    if kind == "sparrow":
        reps = rng.integers(3, 8)
        sp = rng.uniform(0.09, 0.14)
        base = rng.uniform(3600.0, 4600.0)
        for i in range(reps):
            parts.append((i * sp, bird_syllable(rng, base * 1.35, base * 0.85, rng.uniform(0.035, 0.06), 0.25)))
    elif kind == "warbler":
        tk = 0.0
        for _ in range(rng.integers(5, 11)):
            a = rng.uniform(1800.0, 3600.0)
            b = a * rng.uniform(0.75, 1.3)
            d = rng.uniform(0.06, 0.2)
            parts.append((tk, bird_syllable(rng, a, b, d, 0.1, rng.choice([0.0, 0.0, 38.0, 55.0]))))
            tk += d + rng.uniform(0.02, 0.09)
    elif kind == "tit":
        hi = rng.uniform(4800.0, 5400.0)
        lo = hi * rng.uniform(0.68, 0.74)
        tk = 0.0
        for _ in range(rng.integers(3, 6)):
            parts.append((tk, bird_syllable(rng, hi * 1.02, hi * 0.98, 0.11, 0.1)))
            parts.append((tk + 0.15, bird_syllable(rng, lo * 1.04, lo * 0.97, 0.12, 0.1)))
            tk += 0.34
    elif kind == "pigeon":
        tk = 0.0
        for i, (d, f) in enumerate([(0.35, 470.0), (0.6, 520.0), (0.3, 480.0), (0.3, 460.0), (0.45, 450.0)]):
            n = int(d * SR)
            tt = secs(n)
            fr = f * (1.0 + 0.04 * np.sin(np.pi * tt / d))
            s = tone(fr, [1.0, 0.35, 0.12]) * np.sin(np.pi * tt / d) ** 1.5
            s = lowpass(s + 0.2 * bandpass(rng.standard_normal(n), 300.0, 900.0) * np.sin(np.pi * tt / d), 1400.0)
            parts.append((tk, s))
            tk += d + (0.25 if i == 1 else 0.08)
    length = max(p[0] + p[1].shape[0] / SR for p in parts) + 0.05
    out = np.zeros(int(length * SR))
    for t0, s in parts:
        add_at(out, s, int(t0 * SR), wrap=False)
    return out


def synth_park_birds() -> np.ndarray:
    rng = rng_for("park_birds")
    seconds = 40.0
    n = int(seconds * SR)
    st = np.zeros((n, 2))
    birds = [("sparrow", -0.6, 1.0, (3.0, 8.0)), ("sparrow", 0.5, 0.7, (4.0, 10.0)), ("sparrow", 0.1, 0.45, (5.0, 12.0)),
             ("warbler", 0.35, 0.8, (6.0, 12.0)), ("warbler", -0.3, 0.4, (8.0, 16.0)),
             ("tit", -0.75, 0.6, (11.0, 19.0)), ("pigeon", 0.7, 0.35, (14.0, 24.0))]
    for kind, p, amp, gap in birds:
        tk = rng.uniform(0.0, gap[0])
        while tk < seconds:
            song = bird_song(rng, kind)
            if amp < 0.6:
                song = lowpass(song, 4500.0 + 6000.0 * amp)
            add_at(st, pan(song * amp, p + rng.normal(0, 0.06)), int(tk * SR))
            tk += song.shape[0] / SR + rng.uniform(*gap)
    st = stereo_reverb(st, rng, 1.1, 0.22, 6000.0)
    breeze = circ_filter(noise(rng, n, -4.0, 2), band(80.0, 1100.0, 2))
    breeze *= (0.6 + 0.4 * (1.0 + wander(rng, n, 0.15)))[:, None]
    leaves = circ_filter(noise(rng, n, -1.0, 2), band(2200.0, 7000.0, 2))
    leaves *= np.clip(wander(rng, n, 0.4), 0, None)[:, None] ** 2
    city = circ_filter(noise(rng, n, -6.0, 2), band(25.0, 220.0, 2))
    out = unit(st) + 0.35 * breeze + 0.10 * leaves + 0.25 * city
    return norm_rms(out, -20.0)


def synth_night_insects() -> np.ndarray:
    rng = rng_for("night_insects")
    seconds = 30.0
    n = int(seconds * SR)
    st = np.zeros((n, 2))
    for c in range(6):
        fc = rng.uniform(4200.0, 5200.0)
        period = rng.uniform(0.42, 0.68)
        pulses = int(rng.integers(3, 5))
        p_int = rng.uniform(0.028, 0.04)
        p_len = rng.uniform(0.012, 0.018)
        amp = rng.uniform(0.25, 1.0) ** 1.5
        pp = rng.uniform(-0.9, 0.9)
        tk = rng.uniform(0, period)
        pl = int(p_len * SR)
        pt = secs(pl)
        while tk < seconds:
            if rng.uniform() < 0.04:
                tk += rng.uniform(1.5, 4.0)     # a cricket falls silent for a moment
                continue
            for k in range(pulses):
                s = np.sin(2 * np.pi * fc * (1.0 + 0.01 * k) * pt) * np.sin(np.pi * pt / p_len) ** 2
                add_at(st, pan(s * amp * (0.8 + 0.2 * (k == 1)), pp), int((tk + k * p_int) * SR))
            tk += period * rng.uniform(0.97, 1.03)
    # A tree cricket's continuous trill far back, and a distant katydid rasp.
    tt = secs(n)
    trill = np.sin(2 * np.pi * 2900.0 * tt) * (0.5 + 0.5 * np.sin(2 * np.pi * 48.0 * tt)) ** 4
    trill *= 0.6 + 0.4 * (1 + wander(rng, n, 0.1)) / 2
    st += pan(0.08 * trill, -0.2)
    st = stereo_reverb(st, rng, 0.9, 0.3, 7000.0)
    air = circ_filter(noise(rng, n, -4.5, 2), band(30.0, 700.0, 2))
    out = unit(st) + 0.18 * air
    return norm_rms(out, -21.0)


def synth_traffic_hum() -> np.ndarray:
    rng = rng_for("traffic_hum")
    seconds = 40.0
    n = int(seconds * SR)
    # The steady wash of many distant cars, already dulled by distance.
    roar = circ_filter(noise(rng, n, -3.0, 2), chain(band(120.0, 2400.0, 2), bell(700.0, 0.8, 5.0)))
    roar *= (1.0 + 0.18 * wander(rng, n, 0.12))[:, None]
    rumble = circ_filter(noise(rng, n, -6.0, 2), band(22.0, 130.0, 2))
    out = 0.55 * roar + 0.5 * rumble
    passes = np.zeros((n, 2))
    tk = 0.0
    while tk < seconds:
        heavy = rng.uniform() < 0.18
        dur = rng.uniform(4.0, 8.0) * (1.4 if heavy else 1.0)
        pl = int(dur * SR)
        pt = secs(pl)
        u = pt / dur
        envp = np.exp(-((u - 0.5) / 0.2) ** 2)
        tyre = bandpass(rng.standard_normal(pl), 250.0, 2600.0)
        f_eng = (rng.uniform(42.0, 52.0) if heavy else rng.uniform(60.0, 90.0)) * (1.025 - 0.05 * u)
        eng = tone(f_eng, [1.0, 0.7, 0.45, 0.3, 0.2, 0.12])
        s = (tyre / rms(tyre) * (0.5 if heavy else 1.0) + eng / rms(eng) * (0.9 if heavy else 0.35)) * envp
        s = lowpass(s, rng.uniform(1500.0, 3500.0))
        direction = rng.choice([-1.0, 1.0])
        side = np.clip(direction * (u - 0.5) * 1.6, -0.9, 0.9)
        th = (side + 1.0) * np.pi / 4.0
        add_at(passes, np.stack([s * np.cos(th), s * np.sin(th)], axis=1) * rng.uniform(0.35, 1.0), int(tk * SR))
        tk += rng.uniform(1.6, 4.5)
    passes = stereo_reverb(passes, rng, 1.6, 0.45, 3500.0)
    out = out + 0.55 * passes / rms(passes)
    return norm_rms(out, -20.0)


def synth_rain() -> np.ndarray:
    """Steady city rain: the bright wash of distant drops, near drops ticking on paving, drips off
    awnings onto metal and plastic, plinks in puddles, gutter gurgle and wet tyres hissing past."""
    rng = rng_for("rain")
    seconds = 30.0
    n = int(seconds * SR)
    wash = circ_filter(noise(rng, n, -1.5, 2), chain(band(350.0, 11000.0, 2), bell(3200.0, 0.7, 3.0)))
    wash *= (1.0 + 0.12 * wander(rng, n, 0.08))[:, None]
    # Near drops: a few hundred tiny clicks per second across the stereo field.
    drops = np.zeros((n, 2))
    for tk in poisson_times(rng, 240.0, seconds):
        gl = int(rng.uniform(0.0005, 0.0028) * SR) + 2
        g = rng.standard_normal(gl) * np.exp(-secs(gl) / (gl / SR / 3.0))
        add_at(drops, pan(g * rng.uniform(0.1, 1.0) ** 2.5, rng.uniform(-1.0, 1.0)), int(tk * SR))
    drops = circ_filter(drops, band(1100.0, 10000.0, 2))
    # Drips off roofs and awnings onto metal and plastic: short resonant ticks, a few per second.
    drips = np.zeros((n, 2))
    for tk in poisson_times(rng, 3.0, seconds):
        f0 = np.exp(rng.uniform(np.log(900.0), np.log(3200.0)))
        dl = int(0.12 * SR)
        s = modes(dl, [(f0, rng.uniform(0.008, 0.03), 1.0), (f0 * rng.uniform(2.2, 2.9), 0.006, 0.4)], rng)
        s += 0.3 * rng.standard_normal(dl) * np.exp(-secs(dl) / 0.002)
        add_at(drips, pan(s * rng.uniform(0.15, 0.6), rng.uniform(-0.9, 0.9)), int(tk * SR))
    # Puddles: Minnaert bubbles, the rising chirp of a drop landing in standing water.
    plinks = np.zeros((n, 2))
    for tk in poisson_times(rng, 9.0, seconds):
        f0 = np.exp(rng.uniform(np.log(700.0), np.log(2400.0)))
        tau = rng.uniform(0.004, 0.012) * (900.0 / f0) ** 0.5
        bl = int(tau * 6 * SR) + 8
        bt = secs(bl)
        fr = f0 * (1.0 + 0.9 * bt / (tau * 6))
        s = np.sin(2 * np.pi * np.cumsum(fr) / SR) * np.exp(-bt / tau) * (1 - np.exp(-bt / 0.0008))
        add_at(plinks, pan(s * rng.uniform(0.2, 1.0) ** 2, rng.uniform(-0.8, 0.8)), int(tk * SR))
    runoff = circ_filter(noise(rng, n, -6.0, 2), band(60.0, 420.0, 2)) * (1.0 + 0.3 * wander(rng, n, 0.6))[:, None]
    # Wet tyres: a car hissing past now and then, far down the street.
    hiss = np.zeros((n, 2))
    tk = rng.uniform(0.0, 4.0)
    while tk < seconds:
        dur = rng.uniform(3.5, 6.5)
        pl = int(dur * SR)
        u = secs(pl) / dur
        s = bandpass(rng.standard_normal(pl), 900.0, 7000.0) * np.exp(-((u - 0.5) / 0.18) ** 2)
        side = np.clip(rng.choice([-1.0, 1.0]) * (u - 0.5) * 1.6, -0.9, 0.9)
        th = (side + 1.0) * np.pi / 4.0
        add_at(hiss, np.stack([s * np.cos(th), s * np.sin(th)], axis=1) * rng.uniform(0.4, 1.0), int(tk * SR))
        tk += dur * 0.6 + rng.uniform(3.0, 9.0)
    out = (unit(wash) + 0.5 * drops / rms(drops) + 0.3 * drips / rms(drips) + 0.22 * plinks / rms(plinks)
           + 0.3 * unit(runoff) + 0.25 * hiss / rms(hiss))
    out = stereo_reverb(out, rng, 0.8, 0.15, 6000.0)
    return norm_rms(out, -20.0)


# ------------------------------------------------------------------ UI

def bell_note(f: float, dur: float, index: float = 2.0, ratio: float = 1.4, decay: float = 0.4) -> np.ndarray:
    n = int(dur * SR)
    t = secs(n)
    idx = index * np.exp(-t / (decay * 0.5))
    s = np.sin(2 * np.pi * f * t + idx * np.sin(2 * np.pi * f * ratio * t))
    return s * np.exp(-t / decay) * np.clip(t / 0.002, 0, 1) * np.clip((dur - t) / 0.03, 0, 1)


def synth_chat_blip() -> np.ndarray:
    n = int(0.32 * SR)
    out = np.zeros(n)
    a = bell_note(1046.5, 0.2, 0.6, 2.0, 0.05)
    b = bell_note(1568.0, 0.28, 0.6, 2.0, 0.08)
    add_at(out, 0.8 * a, 0, wrap=False)
    add_at(out, 1.0 * b, int(0.06 * SR), wrap=False)
    out = stereo_reverb(out, rng_for("chat_blip"), 0.35, 0.12, 6000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.08), -1.0)


def synth_chat_blip_soft() -> np.ndarray:
    n = int(0.26 * SR)
    out = np.zeros(n)
    add_at(out, bell_note(784.0, 0.24, 0.4, 2.0, 0.06), 0, wrap=False)
    out = stereo_reverb(out, rng_for("chat_blip_soft"), 0.3, 0.1, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.08), -1.0)


def synth_alert_stinger() -> np.ndarray:
    n = int(1.3 * SR)
    out = np.zeros(n)
    add_at(out, bell_note(987.8, 1.0, 2.2, 1.4, 0.35), 0, wrap=False)
    add_at(out, bell_note(659.3, 1.1, 2.2, 1.4, 0.45), int(0.17 * SR), wrap=False)
    t = secs(n)
    out += 0.35 * np.sin(2 * np.pi * 110.0 * t) * np.exp(-t / 0.18) * np.clip(t / 0.01, 0, 1)
    out = stereo_reverb(out, rng_for("alert_stinger"), 0.8, 0.18, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.25), -1.0)


# ------------------------------------------------------------------ catalogue

## Sounds stored as WAV (started often; see the module docstring).
WAV_SOUNDS = {"engine_idle", "engine_run", "siren_two_tone", "horn_short", "horn_long", "chat_blip",
              "chat_blip_soft", "alert_stinger"}


def is_wav(name: str) -> bool:
    return name in WAV_SOUNDS or name.startswith("footstep_")


def catalogue() -> dict[str, tuple[object, bool]]:
    """name -> (builder, loops)."""
    c: dict[str, tuple[object, bool]] = {
        "engine_idle": (synth_engine_idle, True),
        "engine_run": (synth_engine_run, True),
        "horn_short": (lambda: horn(0.28, "horn_short"), False),
        "horn_long": (lambda: horn(0.95, "horn_long"), False),
        "siren_two_tone": (synth_siren_two_tone, True),
        "construction_loop": (synth_construction, True),
        "fire_crackle": (synth_fire, True),
        "river_loop": (synth_river_loop, True),
        "river_bed": (synth_river_bed, True),
        "fountain_loop": (synth_fountain, True),
        "plant_hum": (synth_plant_hum, True),
        "park_birds": (synth_park_birds, True),
        "night_insects": (synth_night_insects, True),
        "traffic_hum": (synth_traffic_hum, True),
        "rain": (synth_rain, True),
        "chat_blip": (synth_chat_blip, False),
        "chat_blip_soft": (synth_chat_blip_soft, False),
        "alert_stinger": (synth_alert_stinger, False),
    }
    for s in SURFACES:
        for k in range(1, STEP_VARIANTS + 1):
            c["footstep_%s_%d" % (s, k)] = ((lambda s=s, k=k: synth_step(s, k)), False)
    for k in range(1, SPLASH_VARIANTS + 1):
        c["footstep_splash_%d" % k] = ((lambda k=k: synth_splash(k)), False)
    return c


IMPORT_TEMPLATE = """[remap]

importer="oggvorbisstr"
type="AudioStreamOggVorbis"

[deps]

source_file="res://sounds/fp/{name}.ogg"

[params]

loop={loop}
loop_offset=0
bpm=0
beat_count=0
bar_beats=4
"""


WAV_IMPORT_TEMPLATE = """[remap]

importer="wav"
type="AudioStreamWAV"

[deps]

source_file="res://sounds/fp/{name}.wav"

[params]

force/8_bit=false
force/mono=false
force/max_rate=false
force/max_rate_hz=44100
edit/trim=false
edit/normalize=false
edit/loop_mode={mode}
edit/loop_begin=0
edit/loop_end=-1
compress/mode=0
"""


def write_import(path: pathlib.Path, name: str, loops: bool) -> None:
    imp = pathlib.Path(str(path) + ".import")
    wav = path.suffix == ".wav"
    key, val = ("edit/loop_mode=", "2" if loops else "1") if wav else ("loop=", "true" if loops else "false")
    if imp.exists():
        lines = imp.read_text().splitlines()
        out = [(key + val) if ln.startswith(key) else ln for ln in lines]
        imp.write_text("\n".join(out) + "\n")
    elif wav:
        imp.write_text(WAV_IMPORT_TEMPLATE.format(name=name, mode=val))
    else:
        imp.write_text(IMPORT_TEMPLATE.format(name=name, loop=val))


def encode(wav: pathlib.Path, ogg: pathlib.Path) -> None:
    # +bitexact must be an output option: before -i it only reaches the demuxer, and the Ogg muxer
    # then writes a random stream serial (and CRCs) into every page.
    cmd = ["ffmpeg", "-loglevel", "error", "-y", "-i", str(wav), "-c:a", "libvorbis", "-q:a", "4",
           "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", str(ogg)]
    subprocess.run(cmd, check=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default=str(ROOT / "sounds" / "fp"))
    ap.add_argument("--only", default="", help="comma-separated names (default: all)")
    ap.add_argument("--wav-dir", default="", help="keep the intermediate WAVs here (default: a temp dir, removed)")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    cat = catalogue()
    if args.list:
        for k, (_, loops) in cat.items():
            print(("loop " if loops else "shot ") + k)
        return 0
    if shutil.which("ffmpeg") is None:
        print("synth_fp_sfx: ffmpeg not found", file=sys.stderr)
        return 2
    names = [s for s in args.only.split(",") if s] or list(cat.keys())
    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(args.wav_dir) if args.wav_dir else pathlib.Path(tempfile.mkdtemp(prefix="gf_synth_"))
    tmp.mkdir(parents=True, exist_ok=True)
    total = 0
    try:
        for name in names:
            if name not in cat:
                print("synth_fp_sfx: unknown sound " + name, file=sys.stderr)
                return 2
            build, loops = cat[name]
            x = np.asarray(build(), dtype=np.float64)
            pcm = np.clip(np.round(x * 32767.0), -32768, 32767).astype(np.int16)
            if is_wav(name):
                dest = out_dir / (name + ".wav")
                wavfile.write(str(dest), SR, pcm)
            else:
                wav = tmp / (name + ".wav")
                wavfile.write(str(wav), SR, pcm)
                dest = out_dir / (name + ".ogg")
                encode(wav, dest)
            for stale in [out_dir / (name + ext) for ext in (".ogg", ".wav")]:
                if stale != dest and stale.exists():
                    stale.unlink()
                    pathlib.Path(str(stale) + ".import").unlink(missing_ok=True)
            write_import(dest, name, loops)
            size = dest.stat().st_size
            total += size
            ch = 2 if x.ndim == 2 else 1
            print("%-24s %s %s %5.2fs %dch rms %6.1f dBFS peak %6.1f dBFS %7d B" % (
                name, "loop" if loops else "shot", dest.suffix[1:], x.shape[0] / SR, ch,
                20 * np.log10(rms(x)), 20 * np.log10(np.max(np.abs(x)) + 1e-12), size))
    finally:
        if not args.wav_dir:
            shutil.rmtree(tmp, ignore_errors=True)
    print("synth_fp_sfx: %d files, %.2f MB" % (len(names), total / 1e6))
    return 0


if __name__ == "__main__":
    sys.exit(main())
