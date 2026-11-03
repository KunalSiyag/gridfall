// Offline tests for tools/web_audio_probe.js: the verdict and the in-page tap, no browser.
//
// usage: node --test tools/tests/web_audio_probe.test.js   (tools/pytests/test_web_audio.py runs it)
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const { judge, initScript, PEAK_MIN, BOOT_WINDOW_S } = require("../web_audio_probe.js");

const ok = { booted: true, suspend: null, state: "running", peak_max: 0.3, first_peak_s: 2.5 };

test("a running context with sound inside the window passes", () => {
	assert.deepEqual(judge(ok), { code: 0, why: [] });
});

test("a silent destination fails with exit 1 (the shipped bug)", () => {
	const r = judge({ ...ok, peak_max: 0, first_peak_s: null });
	assert.equal(r.code, 1);
	assert.match(r.why[0], /silent/);
});

test("a peak under the threshold is silence", () => {
	assert.equal(judge({ ...ok, peak_max: PEAK_MIN / 2, first_peak_s: null }).code, 1);
});

test("sound that comes later than the window fails", () => {
	const r = judge({ ...ok, first_peak_s: BOOT_WINDOW_S + 5 });
	assert.equal(r.code, 1);
	assert.match(r.why[0], /after boot/);
});

test("a context that is not running fails even with a peak", () => {
	assert.equal(judge({ ...ok, state: "suspended" }).code, 1);
});

test("a phase that goes silent fails even when the global peak is fine (the boot stems alone satisfy it)", () => {
	const phases = [
		{ label: "street idle", peak: 0.5, samples: 160 },
		{ label: "walking", peak: 0.3, samples: 200 },
		{ label: "Planner view", peak: 0, samples: 300 },
	];
	const r = judge({ ...ok, phases });
	assert.equal(r.code, 1);
	assert.match(r.why[0], /silent in phase 'Planner view'/);
	assert.equal(r.why.length, 1);
	assert.equal(judge({ ...ok, phases: phases.slice(0, 2) }).code, 0);
});

test("a game that never booted is a probe failure, exit 2", () => {
	assert.equal(judge({ ...ok, booted: false }).code, 2);
});

test("suspend mode: banner shown, gesture resumes, banner hidden passes", () => {
	const s = { banner_shown: true, state_after_gesture: "running", banner_hidden_after_gesture: true };
	assert.equal(judge({ ...ok, suspend: s }).code, 0);
});

test("suspend mode: each missing piece is exit 3", () => {
	const good = { banner_shown: true, state_after_gesture: "running", banner_hidden_after_gesture: true };
	for (const bad of [{ banner_shown: false }, { state_after_gesture: "suspended" }, { banner_hidden_after_gesture: false }]) {
		assert.equal(judge({ ...ok, suspend: { ...good, ...bad } }).code, 3);
	}
});

test("every phase window is judged on its own peak", () => {
	const phases = ["a", "b", "c"].map((label) => ({ label, peak: PEAK_MIN / 2, samples: 10 }));
	assert.equal(judge({ ...ok, phases }).why.length, 3);
});

// ---- the in-page tap against a fake AudioContext ----------------------------------------------

function fakeWindow() {
	const timers = [];
	class Node {
		constructor() { this.out = []; }
		connect(n) { this.out.push(n); return n; }
	}
	class Analyser extends Node {
		constructor() { super(); this.fftSize = 0; this.level = 0; }
		getFloatTimeDomainData(buf) { buf.fill(0); buf[3] = this.level; }
	}
	class Ctx {
		constructor() {
			this.state = "running";
			this.sampleRate = 48000;
			this.destination = new Node();
			this.suspended = 0;
			this.resumed = 0;
			this.listeners = {};
		}
		createAnalyser() { return (this.analyser = new Analyser()); }
		createGain() { return new Node(); }
		addEventListener(t, f) { this.listeners[t] = f; }
		suspend() { this.suspended++; this.state = "suspended"; return Promise.resolve(); }
		resume() { this.resumed++; this.state = "running"; return Promise.resolve(); }
	}
	const win = { AudioContext: Ctx, performance: { now: () => 1000 }, addEventListener() {}, setInterval: (f) => timers.push(f) };
	return { win, timers, Ctx };
}

function run(opts) {
	const { win, timers } = fakeWindow();
	const sandbox = { window: win, performance: win.performance, setInterval: win.setInterval, Float32Array, Math, Promise };
	vm.createContext(sandbox);
	vm.runInContext("(" + initScript.toString() + ")(" + JSON.stringify(opts) + ")", sandbox);
	return { win, timers };
}

test("the tap routes the destination through an analyser and records the peak", () => {
	const { win, timers } = run({ suspend: false, peakMin: PEAK_MIN });
	const c = new win.AudioContext();
	const A = win.__gfAudio;
	assert.equal(A.ctxs.length, 1);
	// What the game connects to "destination" is the tap, not the real destination.
	assert.notEqual(c.destination, A.ctxs[0].real);
	assert.equal(A.ctxs[0].real.constructor.name, "Node");
	timers[0]();
	assert.equal(A.peak, 0);
	A.ctxs[0].an.level = 0.25;
	timers[0]();
	assert.equal(A.peak, 0.25);
	assert.notEqual(A.firstPeakAt, null);
});

test("hold mode suspends the context and refuses the page's resume until a gesture", async () => {
	const { win } = run({ suspend: true, peakMin: PEAK_MIN });
	const c = new win.AudioContext();
	assert.equal(c.suspended, 1);
	await c.resume();
	assert.equal(c.resumed, 0);
	win.__gfAudio.allow = true;
	await c.resume();
	assert.equal(c.resumed, 1);
});

test("the phase window reads the peak since its last read, then resets", () => {
	const { win, timers } = run({ suspend: false, peakMin: PEAK_MIN });
	new win.AudioContext();
	const A = win.__gfAudio;
	A.ctxs[0].an.level = 0.5;
	timers[0]();
	assert.deepEqual({ ...win.__gfAudioWindow() }, { peak: 0.5, samples: 1 });
	A.ctxs[0].an.level = 0;
	timers[0]();
	assert.deepEqual({ ...win.__gfAudioWindow() }, { peak: 0, samples: 1 });
	assert.equal(A.peak, 0.5);
});
