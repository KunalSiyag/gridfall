#!/usr/bin/env python3
"""Synthesise slice I's on-foot sound assets into sounds/fp/ (docs/fp/slices/I-audio.md section 7).

Everything is built from numpy noise, oscillators, pulse trains and modal resonators with fixed
seeds, so a re-run gives the same samples and byte-identical files. Two formats:

- WAV (16-bit PCM, imported uncompressed) for every sound the game starts often: footsteps,
  horns, crashes, knocked props, car doors, blows, dogs, pigeons and cats, UI cues, the engine loops and the siren. Starting an Ogg Vorbis playback costs about
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


# ------------------------------------------------------------------ impacts

def clip_parts(parts: list[tuple[float, float, float]], top: float = 16000.0) -> list[tuple[float, float, float]]:
    """Drops the modes above top, so a bright resonance never folds back past Nyquist."""
    return [p for p in parts if p[0] < top]


def thud(rng: np.random.Generator, n: int, f0: float, f1: float, decay: float) -> np.ndarray:
    """A heavy body striking something: a damped sine falling from f0 to f1 Hz."""
    t = secs(n)
    fr = f1 + (f0 - f1) * np.exp(-t / (decay * 0.5))
    ph = 2 * np.pi * np.cumsum(fr) / SR + rng.uniform(0, 2 * np.pi)
    return np.sin(ph) * np.exp(-t / decay) * (1 - np.exp(-t / 0.0008))


def crack(rng: np.random.Generator, n: int, decay: float, lo: float, hi: float) -> np.ndarray:
    """The first instant of contact: a band of noise dying within a few milliseconds."""
    c = bandpass(rng.standard_normal(n), lo, hi) * np.exp(-secs(n) / decay)
    return c / (np.max(np.abs(c)) + 1e-9)


def crunch(rng: np.random.Generator, n: int, rate: float, decay: float, lo: float, hi: float) -> np.ndarray:
    """Sheet metal and plastic buckling: a burst of crackles thinning out over decay (s)."""
    out = np.zeros(n)
    for tk in poisson_times(rng, rate, min(n / SR, decay * 5.0)):
        w = np.exp(-tk / decay)
        if rng.uniform() > w:
            continue
        gl = int(rng.uniform(0.0004, 0.004) * SR) + 2
        g = rng.standard_normal(gl) * np.exp(-secs(gl) / (gl / SR / 3.0))
        add_at(out, g * min(rng.pareto(2.0) + 0.2, 6.0), int(tk * SR), wrap=False)
    out = bandpass(out, lo, hi)
    return out / (np.max(np.abs(out)) + 1e-9)


def knock(rng: np.random.Generator, parts: list[tuple[float, float, float]], pitch: float, click: float) -> np.ndarray:
    """A hollow object struck once: its modes (Hz, decay s, amplitude) at pitch, and a click."""
    longest = max(d for _, d, _ in parts)
    n = int(min(longest * 7.0, 1.2) * SR)
    s = modes(n, clip_parts([(f * pitch, d, a) for f, d, a in parts]), rng)
    s *= 1 - np.exp(-secs(n) / 0.0005)
    s += click * crack(rng, n, 0.0012, 1500.0, 9000.0)
    return s / (np.max(np.abs(s)) + 1e-9)


def shards(rng: np.random.Generator, n: int, count: int, t0: float, spread: float) -> np.ndarray:
    """Broken glass raining down: tiny bright resonances, most of them soon after t0 (s)."""
    out = np.zeros(n)
    for _ in range(count):
        tk = t0 + rng.exponential(spread)
        f = np.exp(rng.uniform(np.log(2400.0), np.log(8500.0)))
        d = rng.uniform(0.006, 0.03)
        gl = int(d * 5 * SR) + 8
        parts = [(f, d, 1.0), (f * rng.uniform(1.5, 2.4), d * 0.6, 0.5), (f * rng.uniform(2.6, 3.8), d * 0.4, 0.3)]
        s = modes(gl, clip_parts(parts), rng) + 0.3 * rng.standard_normal(gl) * np.exp(-secs(gl) / 0.0006)
        add_at(out, s * rng.uniform(0.15, 1.0) ** 2, int(tk * SR), wrap=False)
    return out / (np.max(np.abs(out)) + 1e-9)


def scrape(rng: np.random.Generator, n: int, start: float, length: float, lo: float, hi: float, ridges: float) -> np.ndarray:
    """Something dragged or rolled over asphalt: rough noise pulsing at ridges (Hz)."""
    out = np.zeros(n)
    sl = int(length * SR)
    t = secs(sl)
    s = bandpass(rng.standard_normal(sl), lo, hi) * env_ad(sl, 0.015, length * 0.35)
    s *= 0.55 + 0.45 * np.abs(np.sin(np.pi * ridges * t + rng.uniform(0, np.pi))) ** 3
    add_at(out, s / (np.max(np.abs(s)) + 1e-9), int(start * SR), wrap=False)
    return out


## A car body's panels, struck: inharmonic, damped within a tenth of a second.
PANEL = [(182.0, 0.09, 1.0), (311.0, 0.07, 0.8), (468.0, 0.05, 0.6), (757.0, 0.04, 0.45), (1234.0, 0.03, 0.3), (1851.0, 0.02, 0.2)]
## A plastic wheelie bin's hollow body and its lid.
BIN_BODY = [(165.0, 0.06, 1.0), (241.0, 0.05, 0.7), (396.0, 0.035, 0.5), (611.0, 0.025, 0.35), (983.0, 0.015, 0.25)]
BIN_LID = [(1310.0, 0.012, 1.0), (2090.0, 0.008, 0.6), (3270.0, 0.005, 0.3)]
## Small plastic and trim bits a crash throws about.
DEBRIS = [(820.0, 0.012, 1.0), (1370.0, 0.009, 0.6), (2240.0, 0.006, 0.35)]


def synth_crash_heavy() -> np.ndarray:
    """The player's car hitting a wall or a car hard: a bumper cracking, the body's thud, metal
    buckling and ringing, glass raining down and bits of trim skittering away."""
    rng = rng_for("crash_heavy")
    n = int(1.5 * SR)
    out = np.zeros(n)
    out += 0.55 * crack(rng, n, 0.003, 900.0, 9000.0)
    out += 0.75 * thud(rng, n, 72.0, 44.0, 0.14)
    out += 0.4 * thud(rng, n, 128.0, 82.0, 0.08)
    out += 0.35 * lowpass(rng.standard_normal(n), 220.0) * env_ad(n, 0.002, 0.12) / 0.2
    out += 0.9 * crunch(rng, n, 1100.0, 0.08, 700.0, 7500.0)
    add_at(out, 0.5 * knock(rng, PANEL, rng.uniform(0.97, 1.03), 0.2), int(0.004 * SR), wrap=False)
    add_at(out, 0.3 * knock(rng, PANEL, rng.uniform(1.15, 1.25), 0.0), int(0.05 * SR), wrap=False)
    out += 0.3 * shards(rng, n, 44, 0.03, 0.11)
    out += 0.16 * shards(rng, n, 14, 0.32, 0.16)
    for k in range(6):
        tk = rng.uniform(0.12, 0.85)
        add_at(out, 0.18 * (1.0 - tk) * knock(rng, DEBRIS, rng.uniform(0.7, 1.4), 0.4), int(tk * SR), wrap=False)
    out += 0.08 * scrape(rng, n, 0.06, 0.5, 900.0, 5000.0, 9.0)
    out = stereo_reverb(out, rng, 0.7, 0.12, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.12), -1.0)


def synth_crash_light() -> np.ndarray:
    """A bump: the car nudging a wall, a post or another car's bumper."""
    rng = rng_for("crash_light")
    n = int(0.65 * SR)
    out = np.zeros(n)
    out += 1.0 * thud(rng, n, 96.0, 70.0, 0.05)
    out += 0.45 * crack(rng, n, 0.012, 500.0, 3000.0)
    add_at(out, 0.5 * knock(rng, [(423.0, 0.02, 1.0), (781.0, 0.015, 0.6), (1352.0, 0.01, 0.4)], 1.0, 0.3), 0, wrap=False)
    out += 0.25 * crunch(rng, n, 260.0, 0.03, 1000.0, 6000.0)
    add_at(out, 0.22 * knock(rng, [(f, d * 0.5, a) for f, d, a in PANEL], 1.2, 0.0), int(0.003 * SR), wrap=False)
    out += 0.1 * scrape(rng, n, 0.01, 0.12, 1500.0, 6000.0, 14.0)
    out = stereo_reverb(out, rng, 0.5, 0.08, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.08), -1.0)


def synth_prop_clatter() -> np.ndarray:
    """A plastic bin knocked flying: the hit, its lid clacking, the fall onto the road, a bounce
    or two and a short roll."""
    rng = rng_for("prop_clatter")
    n = int(1.1 * SR)
    out = np.zeros(n)
    add_at(out, 1.0 * knock(rng, BIN_BODY, 1.0, 0.5), 0, wrap=False)
    add_at(out, 0.4 * knock(rng, BIN_LID, rng.uniform(0.95, 1.05), 0.6), int(rng.uniform(0.06, 0.09) * SR), wrap=False)
    land = rng.uniform(0.28, 0.34)
    add_at(out, 0.85 * knock(rng, BIN_BODY, 0.93, 0.7), int(land * SR), wrap=False)
    add_at(out, 0.35 * knock(rng, BIN_LID, rng.uniform(0.9, 1.0), 0.8), int((land + 0.012) * SR), wrap=False)
    tk = land
    for amp in [0.45, 0.25]:
        tk += rng.uniform(0.11, 0.18)
        add_at(out, amp * knock(rng, BIN_BODY, rng.uniform(0.9, 1.05), 0.5), int(tk * SR), wrap=False)
    grit = crunch(rng, int(0.05 * SR), 320.0, 0.02, 1500.0, 7000.0)
    add_at(out, 0.25 * grit, int(land * SR), wrap=False)
    out += 0.07 * scrape(rng, n, tk + 0.04, 0.4, 700.0, 4500.0, 6.0)
    out = stereo_reverb(out, rng, 0.5, 0.1, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.1), -1.0)


def synth_prop_clang() -> np.ndarray:
    """A metal mailbox, parking meter, bike rack or bench knocked over: the clang of the hit, its
    fall onto the road, a bounce and a rattle."""
    rng = rng_for("prop_clang")
    n = int(1.2 * SR)
    out = np.zeros(n)
    out += 0.6 * thud(rng, n, 112.0, 80.0, 0.04)
    add_at(out, 1.0 * metal_hit(rng, 418.0, 0.22, 1.0), 0, wrap=False)
    land = rng.uniform(0.3, 0.36)
    add_at(out, 0.8 * metal_hit(rng, 523.0, 0.18, 1.0), int(land * SR), wrap=False)
    add_at(out, 0.3 * crunch(rng, int(0.06 * SR), 380.0, 0.025, 1800.0, 8000.0), int(land * SR), wrap=False)
    tk = land
    for amp in [0.4, 0.22]:
        tk += rng.uniform(0.09, 0.14)
        add_at(out, amp * metal_hit(rng, 523.0 * rng.uniform(1.02, 1.1), 0.1, 1.0), int(tk * SR), wrap=False)
    rattle = grains(rng, int(0.3 * SR), 160.0, 0.2, 2000.0, 8000.0, 0.08)
    add_at(out, 0.15 * rattle / (np.max(np.abs(rattle)) + 1e-9), int(land * SR), wrap=False)
    out += 0.06 * scrape(rng, n, tk + 0.03, 0.35, 1200.0, 6500.0, 10.0)
    out = stereo_reverb(out, rng, 0.6, 0.1, 5500.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.1), -1.0)


## A car door's handle and its latch: small, stiff plastic and steel parts.
HANDLE = [(1720.0, 0.007, 1.0), (2630.0, 0.005, 0.6), (4180.0, 0.003, 0.35)]
LATCH = [(980.0, 0.018, 1.0), (1530.0, 0.012, 0.7), (2710.0, 0.008, 0.45), (4350.0, 0.005, 0.25)]
## The door's own skin and frame: smaller, stiffer and better damped than the whole body.
DOOR_PANEL = [(f * 1.45, d * 0.7, a) for f, d, a in PANEL]


def synth_car_door_open() -> np.ndarray:
    """The player's car door opening: the handle pulled, the latch letting go with a clunk, the
    rubber seal peeling off and the door check clicking twice as the door swings wide."""
    rng = rng_for("car_door_open")
    n = int(0.75 * SR)
    out = np.zeros(n)
    add_at(out, 0.45 * knock(rng, HANDLE, 1.0, 0.4), 0, wrap=False)
    free = int(rng.uniform(0.07, 0.09) * SR)
    add_at(out, 0.9 * knock(rng, LATCH, rng.uniform(0.97, 1.03), 0.6), free, wrap=False)
    add_at(out, 0.55 * thud(rng, int(0.2 * SR), 150.0, 110.0, 0.035), free, wrap=False)
    sl = int(0.25 * SR)
    seal = bandpass(rng.standard_normal(sl), 180.0, 1400.0) * env_ad(sl, 0.012, 0.06)
    add_at(out, 0.35 * seal / (np.max(np.abs(seal)) + 1e-9), free + int(0.01 * SR), wrap=False)
    for tk, amp in [(0.36, 0.22), (0.55, 0.16)]:
        add_at(out, amp * knock(rng, LATCH, rng.uniform(0.62, 0.7), 0.3), int(tk * SR), wrap=False)
    out = stereo_reverb(out, rng, 0.45, 0.08, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.06), -1.0)


def synth_car_door_close() -> np.ndarray:
    """The slam: the door's weight meeting the body (a low, cushioned thud and the cabin's air
    pushed out), the latch catching twice, the skin ringing briefly and the trim rattling."""
    rng = rng_for("car_door_close")
    n = int(0.9 * SR)
    out = np.zeros(n)
    out += 1.0 * thud(rng, n, 92.0, 58.0, 0.07)
    out += 0.45 * thud(rng, n, 170.0, 120.0, 0.035)
    out += 0.4 * lowpass(rng.standard_normal(n), 260.0) * env_ad(n, 0.003, 0.05) / 0.2
    add_at(out, 0.5 * knock(rng, LATCH, 1.0, 0.8), int(0.002 * SR), wrap=False)
    second = int(rng.uniform(0.012, 0.018) * SR)
    add_at(out, 0.35 * knock(rng, LATCH, rng.uniform(1.08, 1.14), 0.6), second, wrap=False)
    add_at(out, 0.28 * knock(rng, DOOR_PANEL, rng.uniform(0.98, 1.02), 0.0), int(0.003 * SR), wrap=False)
    rattle = grains(rng, int(0.12 * SR), 220.0, 0.06, 2500.0, 9000.0, 0.03)
    add_at(out, 0.06 * rattle / (np.max(np.abs(rattle)) + 1e-9), int(0.01 * SR), wrap=False)
    out = stereo_reverb(out, rng, 0.6, 0.12, 4500.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.1), -1.0)


# ------------------------------------------------------------------ bodies

def synth_punch_hit() -> np.ndarray:
    """A fist or a shove landing on someone: the dull thump of the body, the slap of knuckles on
    cloth and a rustle of clothes."""
    rng = rng_for("punch_hit")
    n = int(0.4 * SR)
    out = np.zeros(n)
    out += 1.0 * thud(rng, n, 150.0, 95.0, 0.035)
    out += 0.45 * thud(rng, n, 260.0, 180.0, 0.018)
    out += 0.45 * crack(rng, n, 0.006, 300.0, 2500.0)
    sl = int(0.12 * SR)
    cloth = bandpass(rng.standard_normal(sl), 900.0, 6000.0) * env_ad(sl, 0.004, 0.03)
    add_at(out, 0.12 * cloth / (np.max(np.abs(cloth)) + 1e-9), int(0.004 * SR), wrap=False)
    out = stereo_reverb(out, rng, 0.35, 0.08, 4500.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.06), -1.0)


def synth_punch_whoosh() -> np.ndarray:
    """An arm swung fast: the air it tears, a band of noise rising as the swing speeds up and
    falling as it ends, with the sleeve's flutter."""
    rng = rng_for("punch_whoosh")
    n = int(0.32 * SR)
    t = secs(n)
    src = rng.standard_normal(n)
    out = np.zeros(n)
    for k, (lo, hi) in enumerate([(250.0, 700.0), (450.0, 1300.0), (800.0, 2200.0), (500.0, 1500.0)]):
        out += bandpass(src, lo, hi) * np.exp(-0.5 * ((t - (0.05 + 0.035 * k)) / 0.03) ** 2)
    out *= 0.75 + 0.25 * np.sin(2 * np.pi * 38.0 * t + rng.uniform(0, 2 * np.pi))
    return norm_peak(fade_edges(out, 0.002, 0.05), -1.0)


## A hardwood bat's body, struck: a dry, short knock.
BAT_WOOD = [(612.0, 0.03, 1.0), (1349.0, 0.02, 0.6), (2214.0, 0.012, 0.35), (3390.0, 0.007, 0.2)]


def synth_bat_hit() -> np.ndarray:
    """A bat landing on someone: the wood's dry knock over the dull thump of the body."""
    rng = rng_for("bat_hit")
    n = int(0.45 * SR)
    out = np.zeros(n)
    out += 0.9 * thud(rng, n, 135.0, 85.0, 0.04)
    add_at(out, 0.8 * knock(rng, BAT_WOOD, rng.uniform(0.97, 1.03), 0.7), 0, wrap=False)
    out += 0.3 * crack(rng, n, 0.004, 600.0, 5000.0)
    out = stereo_reverb(out, rng, 0.4, 0.08, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.06), -1.0)


def synth_pipe_hit() -> np.ndarray:
    """A steel pipe landing on someone: the body's thump and the pipe ringing on after it."""
    rng = rng_for("pipe_hit")
    n = int(0.9 * SR)
    out = np.zeros(n)
    out += 0.85 * thud(rng, n, 140.0, 90.0, 0.04)
    add_at(out, 0.55 * metal_hit(rng, 1180.0, 0.16, 1.0), 0, wrap=False)
    add_at(out, 0.25 * metal_hit(rng, 1910.0, 0.1, 1.0), int(0.001 * SR), wrap=False)
    out = stereo_reverb(out, rng, 0.5, 0.1, 6000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.1), -1.0)


def synth_bottle_smash() -> np.ndarray:
    """A glass bottle breaking over someone: the crack of the glass, a thump and shards
    tinkling down onto the pavement."""
    rng = rng_for("bottle_smash")
    n = int(0.9 * SR)
    out = np.zeros(n)
    out += 0.7 * crack(rng, n, 0.003, 1500.0, 11000.0)
    out += 0.5 * thud(rng, n, 150.0, 100.0, 0.03)
    out += 0.7 * shards(rng, n, 40, 0.004, 0.05)
    out += 0.35 * shards(rng, n, 18, 0.2, 0.12)
    out = stereo_reverb(out, rng, 0.5, 0.1, 7000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.12), -1.0)


def synth_body_fall() -> np.ndarray:
    """Someone knocked down: the body meeting the pavement (a heavy, soft thud), an arm or the
    head following it down and a short scuff of clothes along the ground."""
    rng = rng_for("body_fall")
    n = int(1.0 * SR)
    out = np.zeros(n)
    out += 1.0 * thud(rng, n, 85.0, 52.0, 0.09)
    out += 0.5 * thud(rng, n, 170.0, 110.0, 0.04)
    out += 0.3 * lowpass(rng.standard_normal(n), 300.0) * env_ad(n, 0.003, 0.06) / 0.2
    out += 0.35 * crack(rng, n, 0.01, 250.0, 2500.0)
    second = int(rng.uniform(0.12, 0.16) * SR)
    add_at(out, 0.45 * thud(rng, int(0.3 * SR), 120.0, 80.0, 0.04), second, wrap=False)
    add_at(out, 0.2 * crack(rng, int(0.1 * SR), 0.006, 400.0, 3000.0), second, wrap=False)
    out += 0.12 * scrape(rng, n, 0.03, 0.35, 500.0, 4000.0, 5.0)
    grit = crunch(rng, int(0.08 * SR), 300.0, 0.03, 1500.0, 7000.0)
    add_at(out, 0.12 * grit, int(0.01 * SR), wrap=False)
    out = stereo_reverb(out, rng, 0.5, 0.1, 4500.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.12), -1.0)


# ------------------------------------------------------------------ dogs

## A medium dog's mouth open to bark (a vocal tract about 15 cm long): formants (Hz, bandwidth Hz,
## gain), and the same tract lowered and drawn back to growl.
DOG_FORMANTS = [(650.0, 180.0, 1.0), (1650.0, 260.0, 0.55), (2800.0, 360.0, 0.3), (3900.0, 480.0, 0.16)]
GROWL_FORMANTS = [(430.0, 150.0, 1.0), (1150.0, 220.0, 0.5), (2300.0, 320.0, 0.25), (3300.0, 420.0, 0.12)]
## The three barks: peak pitch (Hz), length (s), roughness (0..1) and the share of it the pitch takes
## to reach its peak.
BARKS = [(470.0, 0.19, 0.35, 0.22), (540.0, 0.13, 0.5, 0.3), (610.0, 0.16, 0.25, 0.18)]


def resonate(x: np.ndarray, formants: list[tuple[float, float, float]], direct: float) -> np.ndarray:
    """x through parallel formant resonators (Hz, bandwidth Hz, gain), plus `direct` of x itself."""
    out = direct * x
    for f, bw, g in formants:
        out = out + g * bandpass(x, f - bw / 2.0, f + bw / 2.0, 1)
    return out


def bark(rng: np.random.Generator, f_peak: float, dur: float, rough: float, rise: float) -> np.ndarray:
    """One bark of dur seconds: the voice jumps up to f_peak Hz within `rise` of it and falls away,
    rough with period doubling and breathy at the onset, through the open mouth (DOG_FORMANTS)."""
    n = int((dur + 0.02) * SR)
    t = secs(n)
    u = np.clip(t / dur, 0.0, 1.0)
    shape = np.where(u < rise, 0.72 + 0.28 * np.sin(0.5 * np.pi * u / rise),
                     1.0 - 0.42 * np.clip((u - rise) / (1.0 - rise), 0.0, 1.0) ** 1.3)
    f0 = f_peak * shape * (1.0 + 0.02 * wander(rng, n, 40.0))
    src = tone(f0, [1.0 / k ** 0.9 for k in range(1, 25)])
    src *= 1.0 + rough * np.sin(np.pi * np.cumsum(f0) / SR + rng.uniform(0, 2 * np.pi))
    breath = bandpass(rng.standard_normal(n), 700.0, 6500.0)
    breath *= 0.35 * rms(src) / rms(breath) * (0.5 + np.exp(-t / 0.02))
    env = env_ad(n, 0.01, dur * 0.42) * np.clip((dur - t) / 0.03, 0.0, 1.0)
    out = resonate(src * env, DOG_FORMANTS, 0.15) + resonate(breath * env, DOG_FORMANTS, 0.3)
    return out / (np.max(np.abs(out)) + 1e-9)


def synth_dog_bark(k: int) -> np.ndarray:
    """A medium dog's bark (one of BARKS): a short burst of rough voice that jumps up in pitch and
    falls away, with the street's slap after it."""
    rng = rng_for("dog_bark_%d" % k)
    f_peak, dur, rough, rise = BARKS[k - 1]
    out = np.zeros(int(0.55 * SR))
    add_at(out, bark(rng, f_peak, dur, rough, rise), int(0.003 * SR), wrap=False)
    out = stereo_reverb(out, rng, 0.45, 0.1, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.08), -1.0)


def synth_dog_growl() -> np.ndarray:
    """A dog's warning growl: a low, rough voice (about 100 Hz, jittered, with period doubling)
    fluttering into a "grrr", through the lowered mouth (GROWL_FORMANTS) with a snarl's breath,
    swelling and easing over a second."""
    rng = rng_for("dog_growl")
    dur = 1.1
    n = int(1.4 * SR)
    t = secs(n)
    f0 = 100.0 * (1.0 + 0.06 * wander(rng, n, 3.0) + 0.03 * wander(rng, n, 70.0))
    f0 *= 1.0 + 0.12 * np.exp(-((t - 0.3) / 0.25) ** 2)
    src = tone(f0, [1.0 / k for k in range(1, 60)])
    src *= 1.0 + 0.6 * np.sin(np.pi * np.cumsum(f0) / SR)
    flutter = 0.5 + 0.5 * np.sin(2 * np.pi * 27.0 * t + 2.0 * wander(rng, n, 3.0))
    env = np.clip(t / 0.09, 0.0, 1.0) ** 2 * np.clip((dur - t) / 0.2, 0.0, 1.0)
    env *= (0.8 + 0.2 * wander(rng, n, 2.5)) * (0.4 + 0.6 * flutter ** 2)
    voiced = resonate(src * env, GROWL_FORMANTS, 0.25)
    breath = bandpass(rng.standard_normal(n), 250.0, 3500.0) * env
    out = voiced + 0.3 * rms(voiced) / rms(breath) * resonate(breath, GROWL_FORMANTS, 0.4)
    out = stereo_reverb(out, rng, 0.45, 0.08, 4500.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.1), -1.0)


def synth_dog_whine() -> np.ndarray:
    """A dog's whine: two high, nasal whimpers (a short one, then a long one) arching up and back
    down around 1 kHz, with a tremble and a little breath."""
    rng = rng_for("dog_whine")
    out = np.zeros(int(1.05 * SR))
    for t0, dur, lo, hi in [(0.0, 0.2, 820.0, 1150.0), (0.27, 0.55, 880.0, 1320.0)]:
        m = int(dur * SR)
        tt = secs(m)
        u = tt / dur
        fr = lo + (hi - lo) * np.sin(np.pi * np.clip(u, 0.0, 1.0) ** 0.6)
        fr *= 1.0 + 0.012 * np.sin(2 * np.pi * 7.0 * tt + rng.uniform(0, 2 * np.pi)) + 0.01 * wander(rng, m, 12.0)
        s = tone(fr, [1.0, 0.4, 0.18, 0.1, 0.05])
        s = s + 0.5 * bandpass(s, 2300.0, 3300.0, 1)
        b = bandpass(rng.standard_normal(m), 1500.0, 6000.0)
        s = s + 0.05 * rms(s) / rms(b) * b
        add_at(out, s * np.sin(np.pi * np.clip(u, 0.0, 1.0)) ** 0.7, int((0.005 + t0) * SR), wrap=False)
    out = stereo_reverb(out, rng, 0.45, 0.1, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.1), -1.0)


def synth_dog_snap() -> np.ndarray:
    """A dog's bite: a snarl rising into the snap of its jaws (teeth meeting and the mouth's hollow
    knock) and the tug at the trouser leg it caught."""
    rng = rng_for("dog_snap")
    out = np.zeros(int(0.5 * SR))
    sn = int(0.15 * SR)
    tt = secs(sn)
    fr = (170.0 + 160.0 * tt / 0.15) * (1.0 + 0.04 * wander(rng, sn, 40.0))
    rise = np.clip(tt / 0.1, 0.0, 1.0) ** 2 * np.clip((0.15 - tt) / 0.005, 0.0, 1.0)
    snarl = tone(fr, [1.0 / k for k in range(1, 30)]) * (1.0 + 0.5 * np.sin(np.pi * np.cumsum(fr) / SR))
    snarl = resonate(snarl * rise, DOG_FORMANTS, 0.15)
    b = bandpass(rng.standard_normal(sn), 500.0, 5000.0) * rise
    snarl = snarl + 0.4 * rms(snarl) / rms(b) * b
    add_at(out, 0.55 * snarl / (np.max(np.abs(snarl)) + 1e-9), 0, wrap=False)
    at = sn - int(0.004 * SR)
    m = int(0.2 * SR)
    jaws = modes(m, [(1050.0, 0.012, 1.0), (2250.0, 0.007, 0.6), (3400.0, 0.004, 0.4)], rng)
    snap = crack(rng, m, 0.0018, 2500.0, 10000.0) + 0.6 * jaws / (np.max(np.abs(jaws)) + 1e-9)
    add_at(out, snap / (np.max(np.abs(snap)) + 1e-9), at, wrap=False)
    cl = int(0.12 * SR)
    cloth = bandpass(rng.standard_normal(cl), 1200.0, 7000.0) * env_ad(cl, 0.006, 0.035)
    add_at(out, 0.25 * cloth / (np.max(np.abs(cloth)) + 1e-9), at + int(0.01 * SR), wrap=False)
    out = stereo_reverb(out, rng, 0.35, 0.08, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.06), -1.0)

# ------------------------------------------------------------------ pigeons

## A rock pigeon's coos ("coo, roo-c'too-coo"): notes of (start s, length s, pitch at the start, a
## third of the way in and at the end Hz, roll 0..1). It coos with the beak shut into its blown-up
## crop, so the voice is low, nearly pure and muffled, and a rolling note trembles at about 25 Hz.
COOS = [
    [(0.0, 0.3, 400.0, 455.0, 430.0, 0.1), (0.42, 0.24, 430.0, 470.0, 450.0, 0.8),
     (0.7, 0.14, 470.0, 505.0, 480.0, 0.2), (0.88, 0.5, 470.0, 445.0, 380.0, 0.35)],
    [(0.0, 0.22, 380.0, 430.0, 415.0, 0.7), (0.26, 0.13, 440.0, 480.0, 455.0, 0.2),
     (0.44, 0.58, 445.0, 425.0, 360.0, 0.4)],
]
## A pigeon's wingbeat taking off (Hz) and the whistle of its outer primaries on the downstroke (Hz).
WING_HZ = (8.5, 10.0)
WHISTLE_HZ = (1050.0, 1350.0)


def coo_note(rng: np.random.Generator, dur: float, f_a: float, f_m: float, f_b: float, roll: float) -> np.ndarray:
    """One note of a coo: the pitch arching from f_a up to f_m and down to f_b, rolling (a tremble
    of pitch and level) by `roll`, through the crop's muffle with a little breath."""
    n = int(dur * SR)
    t = secs(n)
    u = t / dur
    fr = np.where(u < 0.35, f_a + (f_m - f_a) * np.sin(0.5 * np.pi * np.minimum(u / 0.35, 1.0)),
                  f_m + (f_b - f_m) * np.clip((u - 0.35) / 0.65, 0.0, 1.0) ** 1.4)
    trem = np.sin(2 * np.pi * rng.uniform(22.0, 28.0) * t + rng.uniform(0, 2 * np.pi))
    fr = fr * (1.0 + 0.015 * roll * trem + 0.006 * wander(rng, n, 15.0))
    s = tone(fr, [1.0, 0.3, 0.1, 0.04]) * (1.0 - 0.6 * roll * (0.5 + 0.5 * trem))
    b = bandpass(rng.standard_normal(n), 250.0, 900.0)
    s = s + 0.06 * rms(s) / rms(b) * b
    env = np.sin(np.pi * np.clip(u, 0.0, 1.0)) ** 0.7 * np.clip(t / 0.02, 0.0, 1.0)
    return lowpass(s * env, 1100.0)


def synth_pigeon_coo(k: int) -> np.ndarray:
    """A rock pigeon's coo (one of COOS): low, soft, tremulous notes, "coo, roo-c'too-coo"."""
    rng = rng_for("pigeon_coo_%d" % k)
    notes = COOS[k - 1]
    out = np.zeros(int((max(t0 + d for t0, d, *_ in notes) + 0.45) * SR))
    for t0, d, f_a, f_m, f_b, roll in notes:
        add_at(out, coo_note(rng, d, f_a, f_m, f_b, roll), int((0.005 + t0) * SR), wrap=False)
    out = stereo_reverb(out, rng, 0.45, 0.1, 4000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.1), -1.0)


def wing_beat(rng: np.random.Generator, clap: bool) -> np.ndarray:
    """One downstroke: the rush of air through the feathers (a band of noise swelling and dying
    within 50 ms) with the outer primaries' whistle; on a clap, the wingtips striking over the
    back first."""
    n = int(0.09 * SR)
    t = secs(n)
    env = np.exp(-0.5 * ((t - 0.028) / 0.011) ** 2)
    air = bandpass(rng.standard_normal(n), 300.0, 3800.0)
    out = 0.8 * env * air / (np.max(np.abs(air)) + 1e-9)
    f_w = rng.uniform(*WHISTLE_HZ) * (1.0 + 0.12 * t / 0.09)
    out += 0.08 * env * np.sin(2 * np.pi * np.cumsum(f_w) / SR)
    if clap:
        out += 0.9 * crack(rng, n, 0.003, 700.0, 7000.0) + 0.3 * thud(rng, n, 380.0, 260.0, 0.008)
    return out


def wings(rng: np.random.Generator, n: int, t0: float, claps: int, beats: int, amp: float) -> np.ndarray:
    """One bird taking off t0 s into a buffer of n samples: `claps` beats clapping, then `beats`
    more fading as it climbs away, at its wingbeat (WING_HZ) slowing a little."""
    out = np.zeros(n)
    hz = rng.uniform(*WING_HZ)
    tk = t0
    for k in range(claps + beats):
        fade = np.exp(-max(k - claps, 0) / max(0.45 * beats, 1.0)) * rng.uniform(0.8, 1.0)
        add_at(out, amp * fade * wing_beat(rng, k < claps), int(tk * SR), wrap=False)
        tk += rng.uniform(0.93, 1.07) / hz
        hz *= 0.985
    return out


def synth_pigeon_flap() -> np.ndarray:
    """A pigeon fluttering off a couple of metres: two claps of its wings and a few quick beats."""
    rng = rng_for("pigeon_flap")
    out = wings(rng, int(0.9 * SR), 0.005, 2, 4, 1.0)
    out = stereo_reverb(out, rng, 0.4, 0.08, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.08), -1.0)


def synth_pigeon_takeoff() -> np.ndarray:
    """A flock going up together: a dozen birds' claps and beats overlapping into one clatter, the
    nearest first, and the rush of air they stir dying away as they climb."""
    rng = rng_for("pigeon_takeoff")
    n = int(2.0 * SR)
    t = secs(n)
    out = np.zeros(n)
    for b in range(12):
        t0 = 0.005 + 0.3 * (b / 11.0) ** 0.7 + rng.uniform(0.0, 0.05)
        claps = int(rng.integers(1, 4))
        out += wings(rng, n, t0, claps, int(rng.integers(6, 11)), rng.uniform(0.45, 1.0))
    rush = bandpass(rng.standard_normal(n), 150.0, 1600.0)
    rush *= np.clip(t / 0.08, 0.0, 1.0) ** 2 * np.exp(-np.maximum(t - 0.25, 0.0) / 0.45)
    head = int(0.6 * SR)
    out += 0.25 * rms(out[:head]) / rms(rush[:head]) * rush
    out = stereo_reverb(out, rng, 0.5, 0.12, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.15), -1.0)

# ------------------------------------------------------------------ cats

## A house cat's meows ("mi-aa-ow"): length (s), pitch at the start, peak and end (Hz), and where
## the peak falls (share of the length). The mouth opens from "i" to "a" by the peak and closes to
## a rounded "ow", so the first formant rises and falls and the second slides down (CAT_VOWELS).
MEOWS = [(0.62, 560.0, 760.0, 470.0, 0.35), (0.38, 640.0, 840.0, 660.0, 0.45), (0.95, 500.0, 700.0, 420.0, 0.3)]
## Formants (Hz) of a cat's short vocal tract (about 7 cm) shut to "i", wide open on "a" and
## rounded to "ow", with their bandwidths (Hz) and gains.
CAT_VOWELS = [(900.0, 2500.0, 4300.0), (1500.0, 2150.0, 4000.0), (950.0, 1500.0, 3600.0)]
CAT_FORMANT_BW = [(280.0, 1.0), (360.0, 0.6), (520.0, 0.3)]
## A purr: the larynx buzzing PURR_HZ (Hz, a little faster breathing in) through breaths of
## PURR_BREATHS s (out, in).
PURR_HZ = (24.0, 26.5)
PURR_BREATHS = (1.0, 0.75)


def vowel_gain(f: np.ndarray, fm: list[np.ndarray]) -> np.ndarray:
    """The mouth's gain at f Hz with its formants at fm (one curve per formant)."""
    g = np.zeros_like(f)
    for fc, (bw, a) in zip(fm, CAT_FORMANT_BW):
        g = g + a / (1.0 + ((f - fc) / (0.5 * bw)) ** 2)
    return g


def meow(rng: np.random.Generator, dur: float, f_a: float, f_m: float, f_b: float, at: float) -> np.ndarray:
    """One meow of dur seconds: the voice arching from f_a up to f_m (at that share of it) and down
    to f_b, its harmonics shaped by the mouth opening and closing (CAT_VOWELS), with a breath."""
    n = int(dur * SR)
    t = secs(n)
    u = t / dur
    rise = np.minimum(u / at, 1.0)
    fall = np.clip((u - at) / (1.0 - at), 0.0, 1.0)
    f0 = np.where(u < at, f_a + (f_m - f_a) * np.sin(0.5 * np.pi * rise), f_m + (f_b - f_m) * fall ** 1.2)
    f0 = f0 * (1.0 + 0.008 * wander(rng, n, 25.0) + 0.006 * np.sin(2 * np.pi * 6.0 * t))
    w_open = np.where(u < at, np.sin(0.5 * np.pi * rise), 1.0 - fall ** 0.8)
    shut, wide, round_ = CAT_VOWELS
    fm = [np.where(u < at, s + (w - s) * w_open, r + (w - r) * w_open) for s, w, r in zip(shut, wide, round_)]
    ph = 2 * np.pi * np.cumsum(f0) / SR
    s = np.zeros(n)
    for k in range(1, 16):
        fk = k * f0
        s += np.where(fk < 0.45 * SR, vowel_gain(fk, fm) / k ** 0.5, 0.0) * np.sin(k * ph)
    b = bandpass(rng.standard_normal(n), 1500.0, 7500.0)
    s = s + 0.06 * rms(s) / rms(b) * b
    env = np.clip(t / 0.05, 0.0, 1.0) ** 2 * np.clip((dur - t) / (0.25 * dur), 0.0, 1.0) ** 1.5
    return s * env * (0.85 + 0.15 * w_open)


def synth_cat_meow(k: int) -> np.ndarray:
    """A house cat's meow (one of MEOWS): "mi-aa-ow", arching up and back down around 600 Hz."""
    rng = rng_for("cat_meow_%d" % k)
    dur, f_a, f_m, f_b, at = MEOWS[k - 1]
    out = np.zeros(int((dur + 0.4) * SR))
    add_at(out, meow(rng, dur, f_a, f_m, f_b, at), int(0.005 * SR), wrap=False)
    out = stereo_reverb(out, rng, 0.4, 0.08, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.08), -1.0)


def purr_pulse(rng: np.random.Generator) -> np.ndarray:
    """One beat of a purr: the vocal folds snapping apart, a dull knock in the chest and throat
    (a damped low resonance) with a little rasp of air."""
    n = int(0.03 * SR)
    t = secs(n)
    knock = np.sin(2 * np.pi * rng.uniform(140.0, 170.0) * t) * np.exp(-t / 0.007)
    knock += 0.5 * np.sin(2 * np.pi * rng.uniform(330.0, 380.0) * t) * np.exp(-t / 0.004)
    rasp = bandpass(rng.standard_normal(n), 300.0, 2200.0) * np.exp(-t / 0.003)
    return knock + 0.5 * rasp / (np.max(np.abs(rasp)) + 1e-9)


def synth_cat_purr() -> np.ndarray:
    """A contented cat's purr, close to the hand stroking it: about 25 beats a second of a dull,
    raspy rumble, swelling on each breath out and softer and a little faster on each breath in."""
    rng = rng_for("cat_purr")
    n = int(3.8 * SR)
    out = np.zeros(n)
    tk = 0.01
    ph = 0
    while tk < 3.6:
        b_len = PURR_BREATHS[ph % 2]
        hz = PURR_HZ[ph % 2]
        lvl = 1.0 if ph % 2 == 0 else 0.55
        t_end = min(tk + b_len, 3.6)
        start = tk
        while tk < t_end:
            u = (tk - start) / b_len
            amp = lvl * np.sin(np.pi * np.clip(u, 0.0, 1.0)) ** 0.6 * rng.uniform(0.8, 1.0)
            add_at(out, amp * purr_pulse(rng), int(tk * SR), wrap=False)
            tk += rng.uniform(0.95, 1.05) / hz
        tk = t_end + 0.06
        ph += 1
    t = secs(n)
    air = lowpass(bandpass(rng.standard_normal(n), 200.0, 3000.0), 1500.0)
    out = out + 0.05 * rms(out) / rms(air) * air * (0.6 + 0.4 * wander(rng, n, 1.5) ** 2)
    out = lowpass(out, 2500.0) * np.clip((3.75 - t) / 0.15, 0.0, 1.0)
    out = stereo_reverb(out, rng, 0.3, 0.05, 4000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.003, 0.1), -1.0)


def synth_cat_hiss() -> np.ndarray:
    """A frightened cat's hiss: a spit (a sharp burst of breath through the teeth) and a long hard
    rush of air through the bared teeth (noise 2 to 10 kHz, ringing at the mouth's openings),
    wavering, with a low growl under it."""
    rng = rng_for("cat_hiss")
    dur = 1.2
    n = int(1.5 * SR)
    t = secs(n)
    air = rng.standard_normal(n)
    rush = bandpass(air, 2000.0, 10000.0) + 0.7 * bandpass(air, 3200.0, 4200.0, 1) + 0.5 * bandpass(air, 5600.0, 7000.0, 1)
    rush += 0.25 * bandpass(rng.standard_normal(n), 700.0, 2000.0)
    env = np.clip(t / 0.02, 0.0, 1.0) * np.clip((dur - t) / 0.35, 0.0, 1.0) ** 1.3
    env *= (0.85 + 0.15 * wander(rng, n, 5.0)) * (1.0 + 0.6 * np.exp(-t / 0.08))
    out = rush * env / (np.max(np.abs(rush)) + 1e-9)
    add_at(out, 0.9 * crack(rng, int(0.06 * SR), 0.012, 1200.0, 11000.0), int(0.004 * SR), wrap=False)
    f0 = 95.0 * (1.0 + 0.05 * wander(rng, n, 4.0))
    growl = tone(f0, [1.0 / k for k in range(1, 30)]) * (1.0 + 0.5 * np.sin(np.pi * np.cumsum(f0) / SR))
    growl = bandpass(growl, 150.0, 1500.0) * env
    out = out + 0.12 * rms(out) / rms(growl) * growl
    out = stereo_reverb(out, rng, 0.35, 0.06, 6000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.08), -1.0)


def synth_cat_chatter() -> np.ndarray:
    """A cat watching a bird it cannot reach: its jaw chattering a dozen times a second, each a
    click of teeth and a tiny bleat ("ek-ek-ek"), in two runs."""
    rng = rng_for("cat_chatter")
    out = np.zeros(int(1.3 * SR))
    m = int(0.045 * SR)
    tt = secs(m)
    for start, count in [(0.005, 7), (0.72, 5)]:
        tk = start
        for k in range(count):
            fr = rng.uniform(1000.0, 1250.0) * (1.0 - 0.15 * tt / 0.045)
            bleat = tone(fr, [1.0, 0.5, 0.25, 0.1]) * np.sin(np.pi * np.clip(tt / 0.035, 0.0, 1.0))
            click = crack(rng, m, 0.0015, 2500.0, 9000.0)
            amp = (1.0 - 0.4 * k / count) * rng.uniform(0.8, 1.0)
            add_at(out, amp * (0.6 * bleat + 0.5 * click), int(tk * SR), wrap=False)
            tk += rng.uniform(0.075, 0.09)
    out = stereo_reverb(out, rng, 0.35, 0.08, 5000.0, circular=False).mean(axis=1)
    return norm_peak(fade_edges(out, 0.0005, 0.08), -1.0)
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
              "chat_blip_soft", "alert_stinger", "crash_heavy", "crash_light", "prop_clatter", "prop_clang",
              "car_door_open", "car_door_close", "punch_hit", "punch_whoosh", "body_fall", "dog_bark_1",
              "dog_bark_2", "dog_bark_3", "dog_growl", "dog_whine", "dog_snap", "pigeon_coo_1", "pigeon_coo_2",
              "pigeon_flap", "pigeon_takeoff", "cat_meow_1", "cat_meow_2", "cat_meow_3", "cat_purr",
              "cat_hiss", "cat_chatter", "bat_hit", "pipe_hit", "bottle_smash"}


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
        "crash_heavy": (synth_crash_heavy, False),
        "crash_light": (synth_crash_light, False),
        "prop_clatter": (synth_prop_clatter, False),
        "prop_clang": (synth_prop_clang, False),
        "car_door_open": (synth_car_door_open, False),
        "car_door_close": (synth_car_door_close, False),
        "punch_hit": (synth_punch_hit, False),
        "punch_whoosh": (synth_punch_whoosh, False),
        "body_fall": (synth_body_fall, False),
        "bat_hit": (synth_bat_hit, False),
        "pipe_hit": (synth_pipe_hit, False),
        "bottle_smash": (synth_bottle_smash, False),
        "dog_growl": (synth_dog_growl, False),
        "dog_whine": (synth_dog_whine, False),
        "dog_snap": (synth_dog_snap, False),
        "pigeon_flap": (synth_pigeon_flap, False),
        "pigeon_takeoff": (synth_pigeon_takeoff, False),
        "cat_purr": (synth_cat_purr, False),
        "cat_hiss": (synth_cat_hiss, False),
        "cat_chatter": (synth_cat_chatter, False),
    }
    for k in range(1, len(BARKS) + 1):
        c["dog_bark_%d" % k] = ((lambda k=k: synth_dog_bark(k)), False)
    for k in range(1, len(COOS) + 1):
        c["pigeon_coo_%d" % k] = ((lambda k=k: synth_pigeon_coo(k)), False)
    for k in range(1, len(MEOWS) + 1):
        c["cat_meow_%d" % k] = ((lambda k=k: synth_cat_meow(k)), False)
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
