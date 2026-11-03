// Offline tests for tools/web_probe_kit.js: no browser, no network. The in-page wrapper runs
// against a fake WebGL context and a fake clock, so every count and every millisecond is exact.
//
// usage: node --test tools/tests/web_probe_kit.test.js   (tools/pytests/test_web_probe_kit.py runs it)
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const kit = require("../web_probe_kit.js");

const FRAMEBUFFER = 0x8D40;
const READ_FRAMEBUFFER = 0x8CA8;
const LINK_STATUS = 0x8B82;
const COMPILE_STATUS = 0x8B81;
const ACTIVE_UNIFORMS = 0x8B86;

const GL_METHODS = [
	"drawArrays", "drawElements", "drawRangeElements", "drawArraysInstanced", "drawElementsInstanced",
	"bindFramebuffer", "viewport", "blitFramebuffer", "useProgram", "linkProgram", "compileShader",
	"getProgramParameter", "getShaderParameter", "getProgramInfoLog", "getShaderInfoLog",
	"getUniformLocation", "getAttribLocation", "getUniformBlockIndex", "getActiveUniform",
	"getActiveUniforms", "getActiveAttrib", "getFragDataLocation", "texImage2D", "texImage3D",
	"texSubImage2D", "texSubImage3D", "compressedTexImage2D", "compressedTexImage3D",
	"compressedTexSubImage2D", "compressedTexSubImage3D", "texStorage2D", "texStorage3D",
	"generateMipmap", "bufferData", "bufferSubData", "readPixels", "getBufferSubData", "finish",
	"getError", "framebufferTexture2D", "framebufferTextureLayer", "framebufferRenderbuffer",
];

class FakePO {
	static supportedEntryTypes = ["longtask", "long-animation-frame", "mark"];
	static all = [];
	constructor(cb) {
		this.cb = cb;
		this.queue = [];
		FakePO.all.push(this);
	}
	observe(o) {
		this.type = o.type;
	}
	takeRecords() {
		const q = this.queue;
		this.queue = [];
		return q;
	}
	disconnect() {
		this.gone = true;
	}
}

// A page with a clock that the fake GL calls advance by costs[method] milliseconds.
function makeEnv(extra) {
	FakePO.all = [];
	const clock = { t: 1000 };
	const costs = {};
	const raf = [];
	const marks = [];
	class FakeGL {
		constructor() {
			this.calls = [];
			this.throwOn = null;
		}
	}
	for (const m of GL_METHODS) {
		FakeGL.prototype[m] = function (...args) {
			clock.t += costs[m] || 0;
			this.calls.push(m);
			if (this.throwOn === m) throw new Error("boom " + m);
			if (m === "getProgramParameter") return args[1] === LINK_STATUS;
			if (m === "getError") return 0;
			return m;
		};
	}
	class FakeGL1 {}
	FakeGL1.prototype.drawArrays = function () {};
	class FakeCanvas {
		constructor(connected) {
			this.isConnected = connected;
			this.width = 640;
			this.height = 360;
			this.clientWidth = 640;
			this.clientHeight = 360;
		}
		getContext(type) {
			if (!/webgl/.test(type)) return null;
			if (!this.gl) {
				this.gl = new FakeGL();
				this.gl.canvas = this;
				this.gl.drawingBufferWidth = 640;
				this.gl.drawingBufferHeight = 360;
				this.gl.getContextAttributes = () => ({ antialias: false });
			}
			return this.gl;
		}
	}
	const win = Object.assign({
		performance: { now: () => clock.t, mark: (name, o) => marks.push([name, o]) },
		requestAnimationFrame: (cb) => {
			if (typeof cb !== "function") throw new TypeError("not a function");
			raf.push(cb);
		},
		WebGL2RenderingContext: FakeGL,
		WebGLRenderingContext: FakeGL1,
		HTMLCanvasElement: FakeCanvas,
		PerformanceObserver: FakePO,
		devicePixelRatio: 2, innerWidth: 800, innerHeight: 600, crossOriginIsolated: true,
		SharedArrayBuffer: function () {}, navigator: { userAgent: "fake" },
	}, extra || {});
	// One rAF frame: every queued callback runs with the same timestamp.
	const frame = (ts) => {
		for (const cb of raf.splice(0)) cb(ts);
	};
	// Queues body for the next frame and runs that frame.
	const run = (ts, body) => {
		win.requestAnimationFrame(() => body());
		frame(ts);
	};
	return { win, clock, costs, marks, FakeGL, FakeGL1, FakeCanvas, frame, run };
}

const glOf = (env) => new env.FakeCanvas(true).getContext("webgl2");

test("the page half installs, wraps every method and restores them", () => {
	const env = makeEnv();
	const origDraw = env.FakeGL.prototype.drawElements;
	const origRaf = env.win.requestAnimationFrame;
	const origGetContext = env.FakeCanvas.prototype.getContext;
	const api = kit.installProbe(env.win, {});
	assert.equal(env.win.__gfProbe, api);
	assert.equal(kit.installProbe(env.win, {}), api, "a second install returns the first");
	assert.notEqual(env.FakeGL.prototype.drawElements, origDraw);
	assert.notEqual(env.win.requestAnimationFrame, origRaf);
	assert.notEqual(env.FakeCanvas.prototype.getContext, origGetContext);
	assert.equal(api.glOn(), true);
	api.setGl(false);
	assert.equal(env.FakeGL.prototype.drawElements, origDraw, "setGl(false) restores the WebGL methods");
	assert.notEqual(env.win.requestAnimationFrame, origRaf, "...and keeps the frame log");
	const gl = glOf(env);
	gl.drawElements(4, 6, 5123, 0);
	env.run(16.7, () => gl.drawElements(4, 6, 5123, 0));
	env.run(33.4, () => {});
	assert.equal(api.drain().frames.reduce((n, f) => n + f.dr, 0), 0, "off: nothing is counted");
	assert.equal(api.setGl(true), true);
	assert.notEqual(env.FakeGL.prototype.drawElements, origDraw);
	api.uninstall();
	assert.equal(env.FakeGL.prototype.drawElements, origDraw);
	assert.equal(env.win.requestAnimationFrame, origRaf);
	assert.equal(env.FakeCanvas.prototype.getContext, origGetContext);
	assert.equal(env.win.__gfProbe, undefined);
	assert.ok(FakePO.all.length === 3 && FakePO.all.every((p) => p.gone), "observers are disconnected");
});

test("a wrapper another script stacked on top is left in place on uninstall", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	const ours = env.FakeGL.prototype.drawElements;
	const theirs = function () {
		return ours.apply(this, arguments);
	};
	env.FakeGL.prototype.drawElements = theirs;
	api.setGl(false);
	assert.equal(env.FakeGL.prototype.drawElements, theirs);
	assert.equal(typeof env.FakeGL.prototype.drawArrays, "function", "the other methods were restored");
});

test("the config switches choose what is installed", () => {
	const env = makeEnv();
	const origDraw = env.FakeGL.prototype.drawElements;
	const api = kit.installProbe(env.win, { gl: false, ctx: false, longtask: false, loaf: false, marks: false });
	assert.equal(env.FakeGL.prototype.drawElements, origDraw, "gl:false leaves WebGL alone");
	assert.equal(api.glOn(), false);
	assert.equal(FakePO.all.length, 0, "no observer when every observer is off");
	env.run(10, () => {});
	env.run(26.7, () => {});
	env.run(43.4, () => {});
	const d = api.drain();
	assert.equal(d.frames.length, 3, "frames are still logged without the WebGL hook");
	assert.equal(d.glOn, false);
	assert.equal(d.v, kit.KIT_VERSION);
});

test("per-frame call census: draws, instanced draws, framebuffer binds, passes, program switches", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	const gl = glOf(env);
	const fboA = {};
	const fboB = {};
	const p1 = {};
	const p2 = {};
	gl.drawArrays(4, 0, 3); // before the first rAF: the boot frame, 0
	env.run(16.7, () => {
		gl.bindFramebuffer(FRAMEBUFFER, fboA);
		gl.viewport(0, 0, 1024, 1024);
		gl.useProgram(p1);
		for (let i = 0; i < 3; i++) gl.drawElements(4, 6, 5123, 0);
		gl.bindFramebuffer(FRAMEBUFFER, fboB);
		gl.viewport(0, 0, 512, 512);
		gl.drawArrays(4, 0, 3);
		gl.bindFramebuffer(READ_FRAMEBUFFER, fboA);
		gl.bindFramebuffer(FRAMEBUFFER, null);
		gl.viewport(0, 0, 640, 360);
		gl.useProgram(p2);
		for (let i = 0; i < 5; i++) gl.drawElementsInstanced(4, 6, 5123, 0, 10);
		gl.useProgram(p2);
		gl.useProgram(p1);
		gl.blitFramebuffer(0, 0, 1, 1, 0, 0, 1, 1, 16384, 9728);
	});
	env.run(33.4, () => gl.drawElements(4, 6, 5123, 0));
	env.run(50.1, () => {});
	const d = api.drain();
	assert.deepEqual(d.frames.map((f) => f.i), [0, 1, 2], "frame 3 is still in progress");
	assert.equal(d.frames[0].dr, 1);
	assert.equal(d.frames[0].t, -1);
	const f1 = d.frames[1];
	assert.equal(f1.t, 16.7);
	assert.equal(f1.dr, 9);
	assert.equal(f1.di, 5);
	assert.equal(f1.fb, 4, "every bindFramebuffer call, the read binding included");
	assert.equal(f1.pu, 4);
	assert.equal(f1.ps, 3, "null -> p1 -> p2 -> p1; repeating p2 is not a switch");
	assert.equal(f1.bl, 1);
	// A read-framebuffer bind starts no pass; a new viewport size on the same target does.
	assert.deepEqual(f1.passes, [[1, 1024, 1024, 3], [2, 512, 512, 1], [0, 640, 360, 5]]);
	assert.equal(d.frames[2].dr, 1);
	assert.deepEqual(d.frames[2].passes, [[0, 640, 360, 1]]);
	assert.equal(api.drain().frames.length, 0, "drain forgets what it returned");
});

test("a pass is one render target: cube faces, array layers, mip levels and atlas quadrants are separate passes", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	const gl = glOf(env);
	const COLOR0 = 0x8CE0;
	const DEPTH = 0x8D00;
	const FACE_X = 0x8515;
	const [cube, atlas, layers, rb] = [{}, {}, {}, {}];
	const [fboA, fboB, fboC] = [{}, {}, {}];
	const draw = (n) => {
		for (let i = 0; i < n; i++) gl.drawArrays(4, 0, 3);
	};
	env.run(16.7, () => {
		// One framebuffer, one viewport, six cube faces: six passes.
		gl.bindFramebuffer(FRAMEBUFFER, fboA);
		gl.viewport(0, 0, 32, 32);
		for (let f = 0; f < 6; f++) {
			gl.framebufferTexture2D(FRAMEBUFFER, COLOR0, FACE_X + f, cube, 0);
			draw(1);
		}
		// Attaching what is attached already, and attaching to the read framebuffer, change nothing.
		gl.framebufferTexture2D(FRAMEBUFFER, COLOR0, FACE_X + 5, cube, 0);
		gl.framebufferTexture2D(READ_FRAMEBUFFER, COLOR0, FACE_X, cube, 0);
		draw(2);
		// Two mip levels of one texture.
		gl.bindFramebuffer(FRAMEBUFFER, fboB);
		gl.framebufferTexture2D(FRAMEBUFFER, COLOR0, 3553, atlas, 0);
		draw(1);
		gl.framebufferTexture2D(FRAMEBUFFER, COLOR0, 3553, atlas, 1);
		draw(1);
		// Two layers of an array texture, then a depth renderbuffer attached twice.
		gl.bindFramebuffer(FRAMEBUFFER, fboC);
		gl.framebufferTextureLayer(FRAMEBUFFER, COLOR0, layers, 0, 0);
		draw(1);
		gl.framebufferTextureLayer(FRAMEBUFFER, COLOR0, layers, 0, 1);
		draw(1);
		gl.framebufferRenderbuffer(FRAMEBUFFER, DEPTH, 0x8D41, rb);
		draw(1);
		gl.framebufferRenderbuffer(FRAMEBUFFER, DEPTH, 0x8D41, rb);
		draw(1);
		// The quadrants of one atlas: one size at four origins, then back to the first; then the canvas.
		gl.bindFramebuffer(FRAMEBUFFER, fboB);
		for (let q = 0; q < 4; q++) {
			gl.viewport((q & 1) * 32, (q >> 1) * 32, 32, 32);
			draw(1);
		}
		gl.viewport(0, 0, 32, 32);
		draw(1);
		gl.bindFramebuffer(FRAMEBUFFER, null);
		gl.viewport(0, 0, 640, 360);
		draw(1);
	});
	env.run(33.4, () => {});
	const f = api.drain().frames[1];
	assert.equal(f.dr, 20);
	assert.deepEqual(f.passes, [
		[1, 32, 32, 1], [1, 32, 32, 1], [1, 32, 32, 1], [1, 32, 32, 1], [1, 32, 32, 1], [1, 32, 32, 3], // six faces
		[2, 32, 32, 1], [2, 32, 32, 1], // two mip levels
		[3, 32, 32, 1], [3, 32, 32, 1], [3, 32, 32, 2], // two layers, a renderbuffer
		[2, 32, 32, 1], [2, 32, 32, 1], [2, 32, 32, 1], [2, 32, 32, 1], [2, 32, 32, 1], // four quadrants, the origin again
		[0, 640, 360, 1],
	]);
	const pt = kit.summarizeWindow({ v: 1, now: 500, frames: [f], events: [], longtasks: [], loaf: [], marks: [], glOn: true }, {}).pass_table;
	assert.equal(pt.passes, 17);
});

test("passes beyond maxPasses are counted, not stored", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, { maxPasses: 2 });
	const gl = glOf(env);
	env.run(16.7, () => {
		for (let i = 1; i <= 4; i++) {
			gl.viewport(0, 0, 100 * i, 100);
			gl.drawElements(4, 6, 5123, 0);
		}
	});
	env.run(33.4, () => {});
	const f = api.drain().frames[1];
	assert.equal(f.dr, 4);
	assert.equal(f.passes.length, 2);
	assert.equal(f.pov, 2);
});

test("busy time is the callback time, summed over callbacks that share a timestamp", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	env.win.requestAnimationFrame(() => {
		env.clock.t += 4;
	});
	env.win.requestAnimationFrame(() => {
		env.clock.t += 2.5;
	});
	env.frame(100);
	env.clock.t += 14;
	env.run(116.7, () => {
		env.clock.t += 1;
	});
	env.run(133.4, () => {});
	const d = api.drain();
	assert.deepEqual(d.frames.map((f) => f.i), [0, 1, 2]);
	assert.equal(d.frames[1].busy, 6.5, "two callbacks, one frame");
	assert.equal(d.frames[2].busy, 1);
	assert.ok(d.frames[1].t0 >= 1000, "the callback start is on the page clock");
});

test("the frame callback keeps its argument and its exceptions", () => {
	const env = makeEnv();
	kit.installProbe(env.win, {});
	let seen = null;
	env.run(42, () => {});
	env.win.requestAnimationFrame((ts) => {
		seen = ts;
	});
	env.frame(58.7);
	assert.equal(seen, 58.7);
	env.win.requestAnimationFrame(() => {
		throw new Error("game bug");
	});
	assert.throws(() => env.frame(75.4), /game bug/);
	assert.throws(() => env.win.requestAnimationFrame(null), TypeError, "a bad callback reaches the browser's own check");
});

test("a wrapped call returns the original's value, keeps its receiver and propagates its error", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	const gl = glOf(env);
	assert.equal(gl.getError(), 0);
	assert.equal(gl.getProgramParameter({}, LINK_STATUS), true);
	assert.equal(gl.getProgramParameter({}, ACTIVE_UNIFORMS), false);
	assert.equal(gl.getShaderParameter({}, COMPILE_STATUS), "getShaderParameter");
	assert.deepEqual(gl.calls, ["getError", "getProgramParameter", "getProgramParameter", "getShaderParameter"]);
	gl.throwOn = "readPixels";
	assert.throws(() => gl.readPixels(0, 0, 1, 1, 6408, 5121, new Uint8Array(4)), /boom readPixels/);
	env.run(16.7, () => {});
	const d = api.drain();
	assert.equal(d.frames[0].k.readPixels[0], 1, "the call is recorded even though it threw");
});

test("program builds are grouped from the first compile to the link status and its lookups", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	const gl = glOf(env);
	const sh = {};
	const pr = {};
	const compileOne = () => {
		env.costs.compileShader = 2;
		gl.compileShader(sh);
		env.costs.getShaderParameter = 1;
		gl.getShaderParameter(sh, COMPILE_STATUS);
	};
	env.run(16.7, () => {
		compileOne();
		compileOne();
		env.costs.linkProgram = 3;
		gl.linkProgram(pr);
		env.costs.getProgramParameter = 40;
		gl.getProgramParameter(pr, LINK_STATUS);
		env.costs.getUniformLocation = 0.5;
		for (let i = 0; i < 3; i++) gl.getUniformLocation(pr, "u" + i);
		env.costs.getProgramParameter = 0.25;
		gl.getProgramParameter(pr, ACTIVE_UNIFORMS);
	});
	env.run(33.4, () => {
		env.costs.compileShader = 5;
		gl.compileShader(sh);
		env.costs.getShaderParameter = 1;
		gl.getShaderParameter(sh, COMPILE_STATUS);
		env.costs.linkProgram = 7;
		gl.linkProgram(pr);
		env.costs.getProgramParameter = 100;
		gl.getProgramParameter(pr, LINK_STATUS);
		// A lookup long after the link is not part of the build.
		env.clock.t += 400;
		env.costs.getUniformLocation = 9;
		gl.getUniformLocation(pr, "late");
	});
	env.run(50.1, () => {});
	env.run(66.8, () => {});
	const d = api.drain();
	const builds = d.events.filter((e) => e.kind === "build");
	assert.equal(builds.length, 2);
	assert.equal(builds[0].f, 1);
	assert.equal(builds[0].compile, 6, "two compiles and their status queries");
	assert.equal(builds[0].link, 3);
	assert.equal(builds[0].status, 40);
	assert.equal(builds[0].query, 1.75, "three lookups and one other program query");
	assert.equal(builds[0].ms, 50.75);
	assert.equal(builds[0].n, 10);
	assert.equal(builds[0].done, true);
	assert.equal(builds[1].f, 2);
	assert.equal(builds[1].compile, 6);
	assert.equal(builds[1].link, 7);
	assert.equal(builds[1].status, 100);
	assert.equal(builds[1].query, 0, "a lookup 400 ms later joins nothing");
	// The per-frame aggregates hold every call, and the build sits on the frame it started in.
	const f1 = d.frames[1];
	assert.equal(f1.k.progQuery[0], 4);
	assert.equal(f1.k.linkStatus[0], 1);
	assert.equal(f1.k.linkStatus[1], 40);
	assert.equal(f1.k.compile[0], 2);
	assert.deepEqual(f1.k.build, [1, 50.75, 50.75, 0]);
	assert.equal(d.frames[2].k.build[0], 1);
	assert.equal(d.frames[2].k.progQuery[0], 1, "the late lookup is still counted");
});

test("a build that is still open at drain time is closed once it has been idle for the gap", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	const gl = glOf(env);
	env.run(16.7, () => {
		env.costs.compileShader = 2;
		gl.compileShader({});
	});
	assert.equal(api.drain().events.filter((e) => e.kind === "build").length, 0, "a recent build stays open");
	env.clock.t += 300;
	const d = api.drain();
	const b = d.events.filter((e) => e.kind === "build");
	assert.equal(b.length, 1);
	assert.equal(b[0].done, false, "no link status was ever seen");
	assert.equal(b[0].compile, 2);
});

test("uploads: counts, bytes from typed arrays, image sources and buffer sizes", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	const gl = glOf(env);
	env.run(16.7, () => {
		env.costs.texImage2D = 1.5;
		gl.texImage2D(3553, 0, 6408, 4, 4, 0, 6408, 5121, new Uint8Array(64));
		gl.texImage2D(3553, 0, 6408, 6408, 5121, { width: 8, height: 8 });
		gl.texImage2D(3553, 0, 6408, 4, 4, 0, 6408, 5121, null);
		env.costs.texSubImage2D = 0.1;
		gl.texSubImage2D(3553, 0, 0, 0, 5, 5, 6408, 5121, new Uint8Array(100));
		gl.bufferData(34962, 1024, 35044);
		gl.bufferData(34962, new Float32Array(10), 35044);
		gl.bufferSubData(34962, 0, new Uint8Array(30));
		env.costs.readPixels = 4;
		gl.readPixels(0, 0, 2, 2, 6408, 5121, new Uint8Array(16));
		gl.generateMipmap(3553);
	});
	env.run(33.4, () => {});
	const d = api.drain();
	const f = d.frames[1];
	assert.equal(f.up, 7, "three texImage2D, one texSubImage2D, two bufferData and one bufferSubData");
	assert.equal(f.ub, 64 + 256 + 0 + 100 + 1024 + 40 + 30);
	assert.deepEqual(f.k.texImage2D, [3, 4.5, 1.5, 320]);
	assert.deepEqual(f.k.readPixels, [1, 4, 4, 16], "a readback is timed but is not an upload");
	// Every texImage2D, readPixels and generateMipmap is an event; the cheap sub-uploads are not.
	const kinds = d.events.map((e) => e.kind).sort();
	assert.deepEqual(kinds, ["generateMipmap", "readPixels", "texImage2D", "texImage2D", "texImage2D"]);
	assert.equal(d.events.find((e) => e.kind === "readPixels").bytes, 16);
});

test("uploads through Emscripten's glue: a heap view plus an offset is sized from the call, not the heap", () => {
	// Godot's web build hands WebGL2 its whole wasm heap with an offset (found on the live game: 360 MB
	// per call, 396 GB of "uploads" in 29 frames, when the heap's byteLength was taken for the size).
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	const gl = glOf(env);
	const heap = new Uint8Array(64 * 1024 * 1024);
	const RGBA = 6408, RED = 6403, RGB = 6407, UBYTE = 5121, FLOAT = 5126, TEX = 3553, ARRAY = 35866;
	const expected = {
		texImage2D: 64 * 64 * 4 + 32 * 16 * 1 + 8 * 8 * 16 + 4 * 4 * 2 + 64 + 256 + 0,
		texImage3D: 4 * 4 * 3 * 4,
		texSubImage2D: 16 * 16 * 4,
		texSubImage3D: 2 * 2 * 2 * 4,
		compressedTexImage2D: 8192,
		compressedTexSubImage2D: 8,
		bufferData: 256 + 1024,
		bufferSubData: 100,
		readPixels: 4 * 4 * 4,
	};
	env.run(16.7, () => {
		gl.texImage2D(TEX, 0, 32856, 64, 64, 0, RGBA, UBYTE, heap, 12345); // RGBA8
		gl.texImage2D(TEX, 0, 33321, 32, 16, 0, RED, UBYTE, heap, 99); // R8
		gl.texImage2D(TEX, 0, 34836, 8, 8, 0, RGBA, FLOAT, heap, 0); // RGBA32F
		gl.texImage2D(TEX, 0, 36194, 4, 4, 0, RGB, 33635, new Uint16Array(16)); // RGB565, packed
		gl.texImage2D(TEX, 0, 32856, 4, 4, 0, RGBA, UBYTE, 4096); // an offset into the unpack buffer
		gl.texImage2D(TEX, 0, 32856, 8, 8, 0, RGBA, UBYTE, { width: 8, height: 8 }); // WebGL2 image overload
		gl.texImage2D(TEX, 0, 32856, 8, 8, 0, RGBA, UBYTE, null); // storage only
		gl.texImage3D(ARRAY, 0, 32856, 4, 4, 3, 0, RGBA, UBYTE, heap, 7);
		gl.texSubImage2D(TEX, 0, 0, 0, 16, 16, RGBA, UBYTE, heap, 12);
		gl.texSubImage3D(ARRAY, 0, 0, 0, 1, 2, 2, 2, RGBA, UBYTE, heap, 5);
		gl.compressedTexImage2D(TEX, 0, 33776, 128, 128, 0, heap, 99, 8192); // srcLengthOverride
		gl.compressedTexSubImage2D(TEX, 0, 0, 0, 4, 4, 33776, heap, 7, 8);
		gl.bufferData(34962, heap, 35044, 5000, 256); // (srcOffset, length)
		gl.bufferData(34962, 1024, 35044); // an allocation
		gl.bufferSubData(34962, 0, heap, 7, 100);
		gl.readPixels(0, 0, 4, 4, RGBA, UBYTE, new Uint8Array(64));
	});
	env.run(33.4, () => {});
	const d = api.drain();
	const f = d.frames[1];
	for (const kind of Object.keys(expected)) {
		assert.equal(f.k[kind][3], expected[kind], kind);
	}
	assert.equal(f.ub, 16384 + 512 + 1024 + 32 + 64 + 256 + 0 + 192 + 1024 + 32 + 8192 + 8 + 256 + 1024 + 100);
	assert.ok(f.ub < 1024 * 1024, "nothing is sized by the 64 MB heap");
	// A format or type the kit does not know is 0 bytes, never NaN or the heap.
	env.run(50, () => gl.texImage2D(TEX, 0, 6408, 4, 4, 0, 0xFFFF, UBYTE, heap, 1));
	env.run(66.7, () => {});
	assert.equal(api.drain().frames[1].k.texImage2D[3], 0);
});

test("the long-task, long-animation-frame and mark observers feed drain()", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	const by = (type) => FakePO.all.find((p) => p.type === type);
	by("longtask").queue.push({ startTime: 500, duration: 120 });
	by("long-animation-frame").queue.push({ startTime: 500, duration: 130, blockingDuration: 80, renderStart: 560 });
	by("mark").queue.push({ name: "gf:lamp_pool", startTime: 600, detail: { n: 1 } });
	by("mark").queue.push({ name: "gf:probe:ignored", startTime: 601 });
	by("mark").queue.push({ name: "somebody-else", startTime: 602 });
	api.mark("street:start", { row: "street" });
	assert.deepEqual(env.marks[0], ["gf:probe:street:start", { detail: { row: "street" } }]);
	const d = api.drain();
	assert.deepEqual(d.longtasks, [{ t: 500, dur: 120 }]);
	assert.deepEqual(d.loaf, [{ t: 500, dur: 130, block: 80, rs: 60 }]);
	assert.deepEqual(d.marks.map((m) => m.name), ["gf:probe:street:start", "gf:lamp_pool"]);
	assert.deepEqual(d.marks[1].detail, { n: 1 });
	assert.equal(api.drain().marks.length, 0);
});

test("an observer type the browser lacks is skipped without an error", () => {
	class NoLoaf extends FakePO {
		static supportedEntryTypes = ["longtask"];
	}
	const env = makeEnv({ PerformanceObserver: NoLoaf });
	const api = kit.installProbe(env.win, {});
	assert.deepEqual(api.seen, { longtask: true, loaf: false, marks: false });
	const bare = makeEnv({ PerformanceObserver: undefined });
	assert.deepEqual(kit.installProbe(bare.win, {}).seen, { longtask: false, loaf: false, marks: false });
});

test("the game's canvas is recorded, a detached probe canvas is not; info() reports the setup", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	new env.FakeCanvas(false).getContext("webgl2");
	new env.FakeCanvas(true).getContext("2d");
	assert.equal(api.info().contexts, 0);
	assert.equal(api.info().drawing, null);
	new env.FakeCanvas(true).getContext("webgl2");
	globalThis.GODOT_THREADS_ENABLED = true;
	try {
		const info = api.info();
		assert.equal(info.contexts, 1);
		assert.deepEqual(info.canvas, { w: 640, h: 360, cw: 640, ch: 360 });
		assert.deepEqual(info.drawing, [640, 360]);
		assert.equal(info.dpr, 2);
		assert.equal(info.coi, true);
		assert.equal(info.sab, true);
		assert.equal(info.threads, true);
		assert.deepEqual(info.attrs, { antialias: false });
	} finally {
		delete globalThis.GODOT_THREADS_ENABLED;
	}
	assert.equal(api.info().threads, null, "no loader constant: unknown, not false");
});

test("installSource() is self-contained: it runs in a context that has nothing of this module", () => {
	const env = makeEnv();
	const sandbox = { window: env.win };
	vm.runInNewContext(kit.installSource({ evMinMs: 0.5 }), sandbox);
	assert.ok(env.win.__gfProbe, "the injected text installed the kit");
	assert.equal(env.win.__gfProbe.cfg.evMinMs, 0.5);
	const gl = glOf(env);
	env.run(16.7, () => gl.drawElements(4, 6, 5123, 0));
	env.run(33.4, () => {});
	assert.equal(env.win.__gfProbe.drain().frames[1].dr, 1);
});

test("hzSampler() is self-contained and returns rAF intervals", async () => {
	let now = 0;
	const sandbox = {
		performance: { now: () => now },
		requestAnimationFrame: (cb) => {
			now += 16.7;
			const ts = now;
			setImmediate(() => cb(ts));
		},
	};
	const intervals = await vm.runInNewContext("(" + kit.hzSampler.toString() + ")(400)", sandbox);
	assert.ok(intervals.length >= 20);
	assert.ok(intervals.every((x) => Math.abs(x - 16.7) < 1e-6));
});

// ---- rows -----------------------------------------------------------------------------------

test("stats() uses the probe's sorted[floor(n * p)] convention and ignores non-numbers", () => {
	assert.deepEqual(kit.stats([5, 1, 3, 2, 4, NaN, Infinity]), { n: 5, mean: 3, min: 1, p50: 3, p95: 5, p99: 5, max: 5 });
	assert.deepEqual(kit.stats([]), { n: 0, mean: null, min: null, p50: null, p95: null, p99: null, max: null });
	assert.equal(kit.percentile([1, 2, 3, 4], 0.5), 3);
	assert.equal(kit.percentile([], 0.5), null);
});

test("displayHz() reads the display rate from quiet rAF intervals", () => {
	const jitter = (base, n) => Array.from({ length: n }, (_, i) => base + ((i * 7) % 5) * 0.05);
	const at60 = jitter(16.6, 300).concat([2.1]);
	const r60 = kit.displayHz(at60);
	assert.equal(r60.nominal, 60);
	assert.equal(r60.min_ms, 2.1);
	assert.ok(r60.hz > 59 && r60.hz < 61, "a lone short interval does not set the rate");
	assert.equal(kit.displayHz(jitter(6.9, 700)).nominal, 144);
	assert.equal(kit.displayHz(jitter(8.3, 700)).nominal, 120);
	const slow = kit.displayHz(jitter(1000 / 7, 50));
	assert.equal(slow.nominal, null, "7 fps is not a display rate");
	assert.ok(slow.hz > 6.9 && slow.hz < 7.1);
	assert.deepEqual(kit.displayHz([16, 17]), { n: 2, min_ms: null, p02_ms: null, median_ms: null, hz: null, nominal: null });
});

function frameRec(i, t, busy, extra) {
	return Object.assign({
		i, t, t0: t + 1, busy, dr: 0, di: 0, fb: 0, pu: 0, ps: 0, up: 0, ub: 0, bl: 0, k: {}, passes: [], pov: 0,
	}, extra);
}

// Frame 5 is the slow one: its callbacks run 90 ms, so frame 6's timestamp comes 100 ms after frame 5's (a
// callback that runs long delays the frame after it, not its own timestamp) and frame 7 is on time again.
function syntheticWindow() {
	const frames = [frameRec(0, -1, 0, { dr: 3 })];
	let t = 0;
	for (let i = 1; i <= 10; i++) {
		t += i === 6 ? 100 : 20;
		const hitch = i === 5;
		frames.push(frameRec(i, t, hitch ? 90 : 5, {
			dr: hitch ? 40 : 10 + i, di: 2, fb: 4, ps: 6, pu: 8,
			passes: [[1, 1024, 1024, 4], [0, 640, 360, 6 + i], [2, 320, 180, 1], [3, 320, 180, 1]],
			k: hitch ? {
				link: [1, 3, 3, 0], linkStatus: [1, 60, 60, 0], build: [1, 63, 63, 0], readPixels: [2, 10, 6, 32],
			} : {},
		}));
	}
	const events = [
		{ t: 5, f: 1, kind: "build", ms: 30, compile: 10, link: 5, status: 15, query: 0, n: 6, done: true },
		{ t: 105, f: 5, kind: "build", ms: 63, compile: 0, link: 3, status: 60, query: 0, n: 2, done: true },
		{ t: 106, f: 5, kind: "readPixels", ms: 6, bytes: 16 },
		{ t: 107, f: 5, kind: "readPixels", ms: 4, bytes: 16 },
	];
	return {
		v: 1, now: 500, frames, events, glOn: true, droppedFrames: 0, droppedEvents: 0,
		longtasks: [{ t: 101, dur: 91 }], loaf: [{ t: 100, dur: 95, block: 41, rs: null }],
		marks: [{ t: 102, name: "gf:lamp_pool", detail: { n: 1 } }],
	};
}

test("summarizeWindow(): rates, census, first draw, builds after it and the pass table", () => {
	const out = kit.summarizeWindow(syntheticWindow(), {});
	assert.equal(out.frames, 11);
	assert.equal(out.first_draw_frame, 1, "frame 0 is the boot frame and does not count");
	assert.equal(out.secs, 0.26);
	assert.equal(out.fps, 34.62, "nine intervals over 0.26 s");
	assert.equal(out.interval_ms.max, 100);
	assert.equal(out.interval_ms.min, 20);
	assert.equal(out.interval_ms.p50, 20);
	assert.equal(out.busy_ms.max, 90);
	assert.equal(out.busy_ms.p50, 5);
	assert.equal(out.late_ms.p50, 1);
	assert.equal(out.census.draws.max, 40);
	assert.equal(out.census.fbo_binds.p50, 4);
	assert.equal(out.census.passes.p50, 4);
	assert.equal(out.census.program_switches.p50, 6);
	assert.equal(out.builds.all, 2);
	assert.equal(out.builds.n, 1, "the build in frame 1 is boot work, the one in frame 5 is not");
	assert.equal(out.builds.total_ms, 63);
	assert.equal(out.builds.ge_100, 0);
	assert.deepEqual(
		[out.builds.events, out.builds.event_max_ms, out.builds.events_ge_100, out.builds.events_ge_150],
		[1, 63, 0, 0], "one frame held builds: one event of 63 ms");
	assert.equal(out.builds.top[0].ms, 63);
	assert.equal(out.events.readPixels.n, 2);
	assert.equal(out.events.readPixels.max, 6);
	assert.equal(out.gl_kinds.readPixels.n, 2);
	assert.equal(out.gl_kinds.linkStatus.ms, 60);
	assert.equal(out.longtasks.n, 1);
	assert.equal(out.longtasks.max_ms, 91);
	assert.equal(out.longtasks.ge_100, 0);
	assert.equal(out.loaf.blocking_ms, 41);
	assert.deepEqual(out.marks, [{ t: 102, name: "gf:lamp_pool", detail: { n: 1 } }]);
	const pt = out.pass_table;
	assert.equal(pt.passes, 4);
	assert.deepEqual(pt.by_size["fbo 1024x1024"], { passes: 1, draws: 4 });
	assert.deepEqual(pt.by_size["canvas 640x360"].passes, 1);
	assert.deepEqual(pt.by_size["fbo 320x180"], { passes: 2, draws: 2 });
});

test("summarizeWindow(): a first draw seen in an earlier window moves the boot cutoff", () => {
	const out = kit.summarizeWindow(syntheticWindow(), { firstDrawFrame: 5 });
	assert.equal(out.first_draw_frame, 5);
	assert.equal(out.builds.n, 0, "frame 5 itself is the first drawn frame, not after it");
	const none = kit.summarizeWindow({ ...syntheticWindow(), frames: [] }, {});
	assert.equal(none.frames, 0);
	assert.equal(none.fps, 0);
	assert.equal(none.pass_table, null);
	assert.equal(none.first_draw_frame, null);
});


test("hitch attribution names what the slow frame spent its time on", () => {
	const out = kit.summarizeWindow(syntheticWindow(), {});
	assert.equal(out.hitches.threshold_ms, 40, "twice the median interval, 33.3 ms at least");
	assert.equal(out.hitches.n, 1, "frame 6 arrived late but ran nothing: it is not a row, frame 5 is");
	const h = out.hitches.worst[0];
	assert.equal(h.frame, 5);
	assert.equal(h.interval_ms, 100, "from frame 5's timestamp to frame 6's");
	assert.equal(h.busy_ms, 90);
	assert.equal(h.gl_ms, 73, "the build rolls up its own calls and is not added twice");
	assert.equal(h.other_ms, 17, "script, physics and everything else the wrapper cannot see");
	assert.equal(h.build_ms, 63);
	assert.deepEqual(h.top, [["linkStatus", 60, 1], ["readPixels", 10, 2], ["link", 3, 1]]);
	assert.deepEqual(h.marks, ["gf:lamp_pool"]);
	assert.deepEqual(h.longtask_ms, [91]);
	const custom = kit.attributeHitches(syntheticWindow().frames, [], [], { thresholdMs: 15, top: 2 });
	assert.equal(custom.n, 9, "every frame with a timed successor is over 15 ms (the last frame has none)");
	assert.equal(custom.worst.length, 2);
	assert.equal(custom.worst[0].frame, 5, "the worst first");
});

test("a hitch row is the frame that ran long: the frame that merely arrived late is not ranked above it", () => {
	// Frame 2's callbacks run 60 ms (a 50 ms link), so frame 3's timestamp is 80 ms after frame 2's. Frame 3 has
	// no work of its own. Pairing the 80 ms with frame 3 would put the empty frame first and the link nowhere.
	const frames = [
		frameRec(1, 20, 5), frameRec(2, 40, 60, { dr: 12, om: 4, k: { link: [1, 50, 50, 0], linkStatus: [1, 4, 4, 0], build: [1, 54, 54, 0] } }),
		frameRec(3, 120, 1), frameRec(4, 140, 1), frameRec(5, 160, 70, { dr: 9, k: { readPixels: [1, 60, 60, 16] } }),
	];
	const longtasks = [{ t: 41, dur: 70 }, { t: 105, dur: 55 }, { t: 300, dur: 99 }];
	const marks = [{ t: 45, name: "gf:near_frame_2" }, { t: 125, name: "gf:frame_3" }];
	const out = kit.attributeHitches(frames, longtasks, marks, {});
	assert.equal(out.n, 2, "frame 3 and frame 4 are not rows");
	const [first, last] = out.worst;
	assert.equal(first.frame, 2);
	assert.equal(first.interval_ms, 80, "to the next frame's timestamp: what frame 2 cost");
	assert.equal(first.busy_ms, 60);
	assert.equal(first.build_ms, 54);
	assert.deepEqual(first.top.map((x) => x[0]), ["link", "linkStatus"]);
	assert.equal(first.off_ms, 4, "its own work after its callbacks");
	assert.deepEqual(first.longtask_ms, [70, 55], "the long task of the callback and the one after it, inside the interval");
	assert.deepEqual(first.marks, ["gf:near_frame_2"]);
	// The window's last frame has no successor in it: its interval is unknown, its own busy time still counts.
	assert.equal(last.frame, 5);
	assert.equal(last.interval_ms, null);
	assert.equal(last.busy_ms, 70);
	assert.equal(last.top[0][0], "readPixels");
	assert.deepEqual(out.worst.map((r) => r.frame), [2, 5], "ranked by the larger of the interval and the busy time");
});

test("hitch rows through the page half: the frame that linked is the row, not the frame after it", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	const gl = glOf(env);
	const pr = {};
	const at = (ms) => {
		env.clock.t = 1000 + ms;
		return env.clock.t;
	};
	env.run(at(0), () => gl.drawArrays(4, 0, 3));
	env.run(at(16.7), () => gl.drawArrays(4, 0, 3));
	env.run(at(33.4), () => {
		link(env, gl, pr, 30, 50);
		gl.drawArrays(4, 0, 3);
	});
	env.run(at(150), () => gl.drawArrays(4, 0, 3));
	env.run(at(166.7), () => gl.drawArrays(4, 0, 3));
	env.run(at(183.4), () => {});
	const out = kit.summarizeWindow(api.drain(), {});
	assert.equal(out.hitches.n, 1);
	const h = out.hitches.worst[0];
	assert.equal(h.frame, 3, "frames 0-2 are before it; the link ran in the third rAF frame");
	assert.equal(h.build_ms, 80);
	assert.equal(h.top[0][0], "linkStatus");
	assert.ok(h.interval_ms > 100 && h.interval_ms < 120, "the interval after the link is the long one: " + h.interval_ms);
});

test("passTable() is built from the frame nearest the median draw count", () => {
	assert.equal(kit.passTable([frameRec(1, 20, 5)]), null, "no draws, no table");
	const frames = [1, 2, 3].map((i) => frameRec(i, i * 20, 5, { dr: i * 10, passes: [[0, 100 * i, 50, i * 10]] }));
	const t = kit.passTable(frames);
	assert.equal(t.frame, 2);
	assert.deepEqual(t.by_size, { "canvas 200x50": { passes: 1, draws: 20 } });
	const over = kit.passTable([frameRec(1, 20, 5, { dr: 1, passes: [[7, 8, 9, 1]], pov: 3 })]);
	assert.equal(over.overflow, 3);
	assert.deepEqual(over.by_size, { "fbo 8x9": { passes: 1, draws: 1 } });
});

test("rollupBuilds() sums the post-first-draw builds of every segment", () => {
	const roll = kit.rollupBuilds([
		{ builds: { n: 2, total_ms: 100, max_ms: 60, ge_100: 0, ge_150: 0, events: 1, event_max_ms: 100, events_ge_100: 1, events_ge_150: 0 } },
		{ builds: { n: 1, total_ms: 200, max_ms: 200, ge_100: 1, ge_150: 1, events: 1, event_max_ms: 200, events_ge_100: 1, events_ge_150: 1 } },
		{},
	]);
	assert.deepEqual(roll, {
		n: 3, total_ms: 300, max_ms: 200, ge_100: 1, ge_150: 1,
		events: 2, event_max_ms: 200, events_ge_100: 2, events_ge_150: 1, batched: 0,
	});
	assert.equal(kit.rollupBuilds([]).events, 0);
});

test("buildsAfter(): an event is a frame that held links, however many programs it linked", () => {
	// Five links of 40 ms in frame 3 (one 200 ms stall), two links of 30 ms in frame 4, one of 120 ms in frame 9.
	const frames = [0, 1, 2, 3, 4, 9].map((i) => ({ i, t: i * 20, t0: i * 20, busy: 1, dr: i > 0 ? 5 : 0, di: 0, fb: 0, pu: 0, ps: 0, up: 0, ub: 0, bl: 0, k: {}, passes: [], pov: 0 }));
	const link = (f, ms) => ({ t: f * 20, f, kind: "build", ms, compile: 0, link: ms, status: 0, query: 0, n: 3, done: true });
	const events = [link(3, 40), link(3, 40), link(3, 40), link(3, 40), link(3, 40), link(4, 30), link(4, 30), link(9, 120)];
	const out = kit.summarizeWindow({ v: 1, now: 500, frames, events, longtasks: [], loaf: [], marks: [], glOn: true, droppedFrames: 0, droppedEvents: 0 }, {});
	assert.equal(out.builds.n, 8, "eight programs");
	assert.equal(out.builds.total_ms, 380);
	assert.equal(out.builds.max_ms, 120, "the largest single link");
	assert.equal(out.builds.ge_100, 1);
	assert.equal(out.builds.events, 3, "in three frames");
	assert.equal(out.builds.event_max_ms, 200, "the worst frame spent 200 ms linking");
	assert.equal(out.builds.events_ge_100, 2);
	assert.equal(out.builds.events_ge_150, 1);
});

test("leanings() applies the thresholds of items 10 and 16 and says when it cannot tell", () => {
	const roll = (o) => Object.assign({ n: 0, total_ms: 0, max_ms: 0, ge_100: 0, ge_150: 0, events: 0, event_max_ms: 0, events_ge_100: 0, events_ge_150: 0 }, o);
	const zero = roll({});
	const lean = (r, opts) => kit.leanings(r, null, opts).item10_link_warmup.leaning;
	assert.equal(lean(roll({ n: 40, total_ms: 2500, max_ms: 90, events: 30, event_max_ms: 90 })), "build", ">= 2 s of links");
	assert.equal(lean(roll({ n: 3, total_ms: 450, max_ms: 160, events: 3, event_max_ms: 160, events_ge_100: 3, events_ge_150: 3 })), "build", "three events >= 150 ms");
	// Three programs of 160 ms in one frame are one stall of 480 ms, not three events.
	assert.equal(lean(roll({ n: 3, total_ms: 480, max_ms: 160, ge_150: 3, events: 1, event_max_ms: 480, events_ge_150: 1 })), "inconclusive", "one event, however many programs");
	assert.equal(lean(roll({ n: 9, total_ms: 500, max_ms: 90, events: 9, event_max_ms: 90 })), "drop");
	assert.equal(lean(zero), "drop");
	assert.equal(lean(roll({ n: 9, total_ms: 1500, max_ms: 120, events: 9, event_max_ms: 120, events_ge_100: 1 })), "inconclusive");
	// On a software renderer the milliseconds say nothing about a real GPU: the count stays, the leaning goes.
	const soft = kit.leanings(roll({ n: 196, total_ms: 14073, max_ms: 3051, ge_100: 15, ge_150: 12, events: 40, events_ge_150: 12 }), null, { hardware: false });
	assert.match(soft.item10_link_warmup.leaning, /^withheld: software renderer/);
	assert.equal(soft.item10_link_warmup.n, 196);
	assert.equal(lean(roll({ n: 40, total_ms: 2500, max_ms: 90, events: 30, event_max_ms: 90 }), { hardware: true }), "build");
	// A reused profile has a warm shader cache: it can confirm "build", never drop or stay inconclusive.
	assert.equal(lean(roll({ n: 40, total_ms: 2500, max_ms: 90, events: 30, event_max_ms: 90 }), { cold: false }), "build");
	assert.match(lean(roll({ n: 9, total_ms: 500, max_ms: 90, events: 9, event_max_ms: 90 }), { cold: false }), /^warm cache \(reused profile\)/);
	assert.match(lean(roll({ n: 9, total_ms: 1500, max_ms: 120, events: 9, event_max_ms: 120 }), { cold: false, coldWhy: "Mesa" }), /^warm cache \(Mesa\)/);
	assert.equal(lean(roll({ n: 9, total_ms: 500, max_ms: 90, events: 9, event_max_ms: 90 }), { cold: true }), "drop");
	assert.equal(kit.leanings(zero, null).item16_readback, undefined);
	const walk = (rp, ti) => kit.leanings(zero, { events: { readPixels: rp, texImage2D: ti } }).item16_readback;
	const none = { n: 0, per_s: 0, p95: 0 };
	assert.equal(walk({ n: 3, per_s: 0.2, p95: 1.2 }, { n: 1, per_s: 0.1, p95: 0.5 }).leaning, "close");
	assert.equal(walk({ n: 30, per_s: 2, p95: 1 }, none).leaning, "keep open", "too many calls");
	assert.equal(walk({ n: 1, per_s: 0.1, p95: 4 }, none).leaning, "keep open", "a slowish one");
	assert.equal(walk({ n: 1, per_s: 0.1, p95: 5 }, none).leaning, "build the cheap tier", "p95 of 5 ms or more");
	// A texImage2D every frame (the live game's, 4 per second at 2.5 fps) is not a poster readback.
	const live = walk(none, { n: 46, per_s: 4.03, p95: 0.015 });
	assert.match(live.leaning, /^no data: no readPixels and no poster composite/, "no readbacks at all measures nothing");
	assert.deepEqual(live.texImage2D, { n: 46, per_s: 4.03, p95_ms: 0.015 });
	assert.match(kit.leanings(zero, { events: {} }).item16_readback.leaning, /^no data/, "an empty window");
});

// ---- env knobs ------------------------------------------------------------------------------

test("parseKnobs(): the defaults are the probe's old behaviour", () => {
	const k = kit.parseKnobs({});
	assert.deepEqual(k.viewport, { width: 1600, height: 900 });
	assert.equal(k.dpr, 1);
	assert.equal(k.kit, true);
	assert.equal(k.glHook, true);
	assert.equal(k.headless, false, "headed unless asked, as before");
	assert.equal(k.chrome, "/usr/bin/google-chrome");
	assert.deepEqual(k.chromeArgs, []);
	assert.equal(k.profile, "");
	assert.equal(k.settleS, 30);
	assert.equal(k.windowS, 20);
	assert.equal(k.abS, 0);
	assert.deepEqual(k.rows, ["street", "walk", "sky", "orbit"]);
	assert.equal(k.save, "");
});

test("parseKnobs(): GF_FPS_VIEWPORT and GF_FPS_DPR", () => {
	const k = kit.parseKnobs({ GF_FPS_VIEWPORT: "1920x1080", GF_FPS_DPR: "1.5" });
	assert.deepEqual(k.viewport, { width: 1920, height: 1080 });
	assert.equal(k.dpr, 1.5);
	assert.deepEqual(kit.parseViewport(" 2560 X 1440 "), { width: 2560, height: 1440 });
	assert.deepEqual(kit.parseViewport("", { width: 1, height: 2 }), { width: 1, height: 2 });
	for (const bad of ["1920*1080", "1920", "axb", "0x0", "100x100", "9000x9000", "1920x1080x2"]) {
		assert.throws(() => kit.parseViewport(bad), /GF_FPS_VIEWPORT/, bad);
	}
	for (const bad of ["0", "abc", "9", "-1", "NaN"]) assert.throws(() => kit.parseDpr(bad, 1), /GF_FPS_DPR/, bad);
	assert.equal(kit.parseDpr("2", 1), 2);
});

test("parseKnobs(): switches, numbers, rows and Chrome arguments", () => {
	const k = kit.parseKnobs({
		GF_FPS_KIT: "0", GF_FPS_GLHOOK: "off", GF_FPS_HEADLESS: "yes", GF_FPS_CHROME: "/opt/google/chrome/chrome",
		GF_FPS_CHROME_ARGS: "--use-angle=swiftshader  --enable-unsafe-swiftshader", GF_FPS_USER_DATA_DIR: "/tmp/p",
		GF_FPS_SETTLE_S: "5", GF_FPS_WINDOW_S: "8", GF_FPS_ROWS: "orbit, street", GF_FPS_MEMORY: "0",
		GF_FPS_RAW: "1", GF_FPS_SAVE: "/tmp/s.json",
	});
	assert.equal(k.kit, false);
	assert.equal(k.glHook, false);
	assert.equal(k.headless, true);
	assert.equal(k.chrome, "/opt/google/chrome/chrome");
	assert.deepEqual(k.chromeArgs, ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"]);
	assert.equal(k.profile, "/tmp/p");
	assert.deepEqual([k.settleS, k.windowS, k.abS], [5, 8, 0]);
	assert.deepEqual(k.rows, ["street", "orbit"], "rows keep the probe's order, whatever the order given");
	assert.equal(k.memory, false);
	assert.equal(k.raw, true);
	assert.equal(k.save, "/tmp/s.json");
	assert.throws(() => kit.parseKnobs({ GF_FPS_GLHOOK: "maybe" }), /GF_FPS_GLHOOK/);
	assert.throws(() => kit.parseKnobs({ GF_FPS_ROWS: "street,moon" }), /moon/);
	assert.throws(() => kit.parseKnobs({ GF_FPS_WINDOW_S: "0" }), /GF_FPS_WINDOW_S/);
	assert.throws(() => kit.parseKnobs({ GF_FPS_SETTLE_S: "x" }), /GF_FPS_SETTLE_S/);
});

// ---- process memory and census comparison ---------------------------------------------------

const PS = [
	"  100     1  200000 /opt/google/chrome/chrome --user-data-dir=/tmp/prof1 --no-sandbox about:blank",
	"  101   100   50000 /opt/google/chrome/chrome --type=zygote --no-zygote-sandbox",
	"  102   101  300000 /opt/google/chrome/chrome --type=renderer --crashpad-handler-pid=9",
	"  103   100  150000 /opt/google/chrome/chrome --type=gpu-process --ozone-platform=headless",
	"  104   100   40000 /opt/google/chrome/chrome --type=utility --utility-sub-type=network.mojom.NetworkService",
	"  105   102   10000 /opt/google/chrome/chrome --type=renderer",
	"  200     1  999999 /opt/google/chrome/chrome --user-data-dir=/tmp/other --no-sandbox",
	"  201   200  999999 /opt/google/chrome/chrome --type=renderer",
	"  300     1    1000 bash",
	"not a process line",
].join("\n");

test("parsePs() and rssOfTree() total one Chrome profile's process tree", () => {
	const procs = kit.parsePs(PS);
	assert.equal(procs.length, 9, "the junk line is skipped");
	assert.deepEqual(procs[0], { pid: 100, ppid: 1, rssKb: 200000, args: "/opt/google/chrome/chrome --user-data-dir=/tmp/prof1 --no-sandbox about:blank" });
	const r = kit.rssOfTree(procs, "/tmp/prof1");
	assert.equal(r.processes, 6, "browser, zygote, two renderers, gpu, utility: not the other profile");
	assert.equal(r.browser_mb, 195.3);
	assert.equal(r.gpu_mb, 146.5);
	assert.deepEqual(r.renderer_mb, [293, 9.8]);
	assert.equal(r.utility_mb, 87.9, "zygote and utility");
	assert.equal(r.total_mb, 732.4);
	assert.equal(kit.rssOfTree(procs, "/tmp/other").processes, 2);
	assert.equal(kit.rssOfTree(procs, "/tmp/missing"), null);
	assert.deepEqual(kit.parsePs(""), []);
});

function census(draws, fbo, passes, sw, up) {
	const s = (v) => ({ p50: v });
	return { street: { census: { draws: s(draws), fbo_binds: s(fbo), passes: s(passes), program_switches: s(sw), use_program: s(up) } } };
}

test("compareCensus(): structure must match, the draw count may drift, zero draws never pass", () => {
	assert.equal(kit.compareCensus(census(1000, 12, 12, 80, 90), census(1050, 12, 12, 81, 90)).stable, true);
	// Structure is exact within two calls, however large the frame: 3 binds of 34 is no longer "10%".
	assert.equal(kit.compareCensus(census(1000, 34, 16, 80, 90), census(1000, 36, 16, 80, 90)).stable, true);
	assert.deepEqual(kit.compareCensus(census(1000, 34, 16, 80, 90), census(1000, 37, 16, 80, 90)).reasons, ["fbo_binds: 34 vs 37"]);
	// What two identical software-WebGL runs of the live build gave: 11% fewer draws from boot on.
	assert.equal(kit.compareCensus(census(878, 34, 16, 251, 356), census(782, 34, 16, 242, 347)).stable, true, "the measured noise floor");
	const drift = kit.compareCensus(census(1000, 12, 12, 80, 90), census(1300, 12, 12, 80, 90));
	assert.equal(drift.stable, false);
	assert.deepEqual(drift.reasons, ["draws: 1000 vs 1300"]);
	assert.equal(kit.compareCensus(census(1000, 12, 12, 80, 90), census(1000, 12, 12, 80, 90), { tol: 0.5 }).stable, true);
	assert.equal(kit.compareCensus(census(1000, 12, 12, 80, 90), census(1250, 12, 12, 80, 90), { tol: 0.5 }).stable, true, "a looser tolerance");
	const fbo = kit.compareCensus(census(1000, 12, 12, 80, 90), census(1000, 20, 20, 80, 90));
	assert.equal(fbo.stable, false);
	assert.equal(fbo.rows.filter((r) => !r.ok).length, 2);
	const zero = kit.compareCensus(census(0, 0, 0, 0, 0), census(0, 0, 0, 0, 0));
	assert.equal(zero.stable, false);
	assert.deepEqual(zero.reasons, ["no draw calls were counted"]);
	const missing = kit.compareCensus({}, census(1, 1, 1, 1, 1));
	assert.equal(missing.stable, false);
	assert.match(missing.reasons[0], /no census/);
	assert.equal(kit.compareCensus(census(1000, 12, 12, 80, 90), census(1000, 12, 12, 80, 90), { row: "sky" }).stable, false);
	const partial = census(1000, 12, 12, 80, 90);
	delete partial.street.census.passes;
	assert.deepEqual(kit.compareCensus(partial, census(1000, 12, 12, 80, 90)).reasons, ["passes missing"]);
});

test("compareCensus(): a row of too few frames is skipped, not failed", () => {
	const frames = (c, n) => {
		c.street.census.draws.n = n;
		return c;
	};
	// The software-WebGL orbit rows of two identical runs: eleven and nine frames, program switches 343 and 290.
	const a = frames(census(5696, 49, 21, 343, 405), 11);
	const b = frames(census(5623, 49, 21, 290, 352), 9);
	const short = kit.compareCensus(a, b);
	assert.equal(short.stable, null);
	assert.match(short.skipped, /^11 and 9 frames: fewer than 20/);
	assert.deepEqual(short.rows, []);
	assert.equal(kit.compareCensus(a, b, { minFrames: 5 }).stable, false, "compared when asked to: 343 vs 290 is 15.5%");
	const enough = kit.compareCensus(frames(census(1000, 12, 12, 80, 90), 30), frames(census(1000, 12, 12, 80, 90), 25));
	assert.equal(enough.stable, true);
	assert.equal(enough.skipped, null);
});

test("compareLinks(): the programs linked after the first draw agree between runs, within a few", () => {
	const links = (n, events) => ({ link_builds: { n, events } });
	const same = kit.compareLinks(links(206, 21), links(206, 21));
	assert.equal(same.stable, true);
	assert.deepEqual([same.n, same.events], [[206, 206], [21, 21]]);
	assert.equal(kit.compareLinks(links(206, 21), links(209, 22)).stable, true, "three programs of 206 is noise");
	const far = kit.compareLinks(links(206, 21), links(150, 21));
	assert.equal(far.stable, false);
	assert.deepEqual(far.reasons, ["n: 206 vs 150"]);
	assert.equal(kit.compareLinks(links(10, 2), links(14, 2)).stable, false, "four of ten is more than the floor of three");
	assert.equal(kit.compareLinks(links(0, 0), links(2, 1)).stable, true, "a couple of links against none");
	assert.equal(kit.compareLinks({}, links(1, 1)).stable, null, "no census to compare");
	assert.equal(kit.compareLinks(links(206, 21), links(150, 21), { tol: 0.5 }).stable, true, "a looser tolerance");
});

test("the CLI compares two result files and exits 0 only when the census is stable", () => {
	const fs = require("node:fs");
	const os = require("node:os");
	const path = require("node:path");
	const { spawnSync } = require("node:child_process");
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gf-kit-test-"));
	try {
		const a = path.join(dir, "a.json");
		const b = path.join(dir, "b.json");
		const c = path.join(dir, "c.json");
		fs.writeFileSync(a, JSON.stringify(census(1000, 12, 12, 80, 90)));
		fs.writeFileSync(b, JSON.stringify(census(1020, 12, 12, 80, 90)));
		fs.writeFileSync(c, JSON.stringify(census(1000, 30, 30, 80, 90)));
		const script = path.join(__dirname, "..", "web_probe_kit.js");
		const same = spawnSync("node", [script, "compare", a, b], { encoding: "utf8" });
		assert.equal(same.status, 0);
		assert.match(same.stdout, /CENSUS: STABLE/);
		const diff = spawnSync("node", [script, "compare", a, c], { encoding: "utf8" });
		assert.equal(diff.status, 1);
		assert.match(diff.stdout, /CENSUS: DIFFERENT/);
		assert.equal(spawnSync("node", [script], { encoding: "utf8" }).status, 2, "usage error");
		// "all" compares every row both results have; one differing row fails the run.
		const d = path.join(dir, "d.json");
		const e = path.join(dir, "e.json");
		const f = path.join(dir, "f.json");
		fs.writeFileSync(d, JSON.stringify({ street: census(1000, 12, 12, 80, 90).street, orbit: census(5000, 20, 20, 90, 95).street }));
		fs.writeFileSync(e, JSON.stringify({ street: census(1010, 12, 12, 80, 90).street, orbit: census(5100, 20, 20, 90, 95).street }));
		fs.writeFileSync(f, JSON.stringify({ street: census(1010, 12, 12, 80, 90).street, orbit: census(9000, 20, 20, 90, 95).street }));
		const all = spawnSync("node", [script, "compare", d, e, "0.1", "all"], { encoding: "utf8" });
		assert.equal(all.status, 0, all.stdout);
		assert.match(all.stdout, /-- street[\s\S]*-- orbit/);
		assert.equal(spawnSync("node", [script, "compare", d, f, "0.1", "all"], { encoding: "utf8" }).status, 1, "the orbit draw count moved 80%");
		assert.equal(spawnSync("node", [script, "compare", d, f, "0.1"], { encoding: "utf8" }).status, 0, "the default row is the street");
		assert.equal(spawnSync("node", [script, "compare", d, f, "0.1", "walk"], { encoding: "utf8" }).status, 1, "a row neither result has is not stable");
		// The link census is compared when both results carry it, and a difference fails the run.
		const withLinks = (c, n, events) => JSON.stringify(Object.assign({}, c, { link_builds: { n, events } }));
		const g = path.join(dir, "g.json");
		const h = path.join(dir, "h.json");
		const i = path.join(dir, "i.json");
		fs.writeFileSync(g, withLinks(census(1000, 12, 12, 80, 90), 206, 21));
		fs.writeFileSync(h, withLinks(census(1010, 12, 12, 80, 90), 206, 21));
		fs.writeFileSync(i, withLinks(census(1010, 12, 12, 80, 90), 120, 21));
		const linked = spawnSync("node", [script, "compare", g, h], { encoding: "utf8" });
		assert.equal(linked.status, 0, linked.stdout);
		assert.match(linked.stdout, /LINKS: STABLE \(programs linked after the first draw 206 vs 206, frames with links 21 vs 21\)/);
		const moved = spawnSync("node", [script, "compare", g, i], { encoding: "utf8" });
		assert.equal(moved.status, 1, "the census agrees, the links do not");
		assert.match(moved.stdout, /CENSUS: STABLE/);
		assert.match(moved.stdout, /LINKS: DIFFERENT n: 206 vs 120/);
		assert.match(same.stdout, /LINKS: not compared/, "results without a link census");
		// A row with too few frames is skipped; skipping every row compared nothing, which is not a pass.
		const j = path.join(dir, "j.json");
		const k = path.join(dir, "k.json");
		const few = (c, n) => {
			c.census.draws.n = n;
			return c;
		};
		fs.writeFileSync(j, JSON.stringify({ street: census(1000, 12, 12, 80, 90).street, orbit: few(census(5696, 49, 21, 343, 405).street, 11) }));
		fs.writeFileSync(k, JSON.stringify({ street: census(1000, 12, 12, 80, 90).street, orbit: few(census(5623, 49, 21, 290, 352).street, 9) }));
		const skipped = spawnSync("node", [script, "compare", j, k, "", "all"], { encoding: "utf8" });
		assert.equal(skipped.status, 0, skipped.stdout);
		assert.match(skipped.stdout, /-- orbit\nCENSUS: SKIPPED 11 and 9 frames/);
		assert.equal(spawnSync("node", [script, "compare", j, k, "", "orbit"], { encoding: "utf8" }).status, 1, "nothing was compared");
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

// ---- the game's side: flags and FIRSTUSE lines -----------------------------------------------

test("parseFlags(): the probe turns the game's marks on by default and writes any flag it is given", () => {
	assert.deepEqual(kit.parseFlags(undefined), { web_first_use_marks: true });
	assert.deepEqual(kit.parseFlags(""), { web_first_use_marks: true });
	assert.deepEqual(kit.parseFlags("none"), {});
	assert.deepEqual(kit.parseFlags("web_real_time_pace=1, web_first_use_marks=off"), { web_real_time_pace: true, web_first_use_marks: false });
	assert.deepEqual(kit.parseFlags("a=TRUE,,b=0"), { a: true, b: false });
	for (const bad of ["a", "a=2", "A b=1", "=1", "a=yes", "1a=1"]) assert.throws(() => kit.parseFlags(bad), /GF_FPS_FLAGS/, bad);
	assert.deepEqual(kit.parseKnobs({}).flags, { web_first_use_marks: true });
	assert.deepEqual(kit.parseKnobs({ GF_FPS_FLAGS: "x=1" }).flags, { x: true });
});

// The same line scripts/ops/first_use.gd documents and tools/tests/fp_first_use_test.gd checks.
const LINES = [
	'log FIRSTUSE {"tag":"lamp_pool","n":1}',
	'log FIRSTUSE {"tag":"lamp_pool","n":2}',
	'log FIRSTUSE {"tag":"play:rain.ogg","n":1,"ms":90,"len":30.0}',
	'log FIRSTUSE {"tag":"play:rain.ogg","n":2,"ms":0.2,"len":30.0}',
	'log FIRSTUSE {"tag":"play:footstep_asphalt_1.ogg","n":1,"ms":0.4,"len":0.5}',
	'log FIRSTUSE {"tag":"save:stringify","n":1,"ms":120.5}',
	"log GRIDFALL: not ours", 'log FIRSTUSE {"tag":', 'log FIRSTUSE {"n":1}', "pageerror FIRSTUSE not json",
];

test("parseFirstUse() takes the records of the game's console lines and nothing else", () => {
	const recs = kit.parseFirstUse(LINES);
	assert.equal(recs.length, 6, "the truncated line, the tagless one and the others are skipped");
	assert.deepEqual(recs[2], { tag: "play:rain.ogg", n: 1, ms: 90, len: 30 });
	assert.deepEqual(kit.parseFirstUse([]), []);
});

test("summarizeFirstUse() counts marks, keeps the first reading and puts streams per audio second", () => {
	const s = kit.summarizeFirstUse(kit.parseFirstUse(LINES));
	assert.deepEqual(s.marks, { lamp_pool: { n: 2 } });
	assert.equal(s.watches["save:stringify"].first_ms, 120.5);
	assert.equal(s.watches["save:stringify"].ms_per_s, null, "not a stream");
	const rain = s.watches["play:rain.ogg"];
	assert.equal(rain.first_ms, 90, "the cold reading, not the warm one");
	assert.equal(rain.max_ms, 90);
	assert.equal(rain.n, 2);
	assert.equal(rain.ms_per_s, 3);
	assert.deepEqual(s.streams.map((x) => x.tag), ["play:rain.ogg", "play:footstep_asphalt_1.ogg"], "worst per second first");
	assert.equal(s.item15_stream.max_ms_per_s, 3);
	assert.equal(s.item15_stream.long_streams, 1, "the rain bed; the footstep is not a bed");
	assert.equal(s.item15_stream.cost_of_a_30s_bed_ms, 90);
	assert.equal(s.item15_stream.leaning, "not triggered", "3 ms/s but a 30 s bed costs 90 ms, under 100");
	const slow = kit.summarizeFirstUse([{ tag: "play:a.ogg", n: 1, ms: 200, len: 30 }]);
	assert.equal(slow.item15_stream.leaning, "build");
	assert.equal(slow.item15_stream.longest_len_s, 30);
	const none = kit.summarizeFirstUse([]);
	assert.equal(none.item15_stream.streams, 0);
	assert.equal(none.item15_stream.leaning, "no stream of 5 s or more seen");
	// A short stream's fixed cost makes its rate huge (8 ms per audio second here) and decides nothing.
	const horn = kit.summarizeFirstUse([{ tag: "play:horn.ogg", n: 1, ms: 4, len: 0.5 }, { tag: "play:bed.ogg", n: 1, ms: 30, len: 30 }]);
	assert.equal(horn.item15_stream.max_ms_per_s_any, 8);
	assert.equal(horn.item15_stream.max_ms_per_s, 1);
	assert.equal(horn.item15_stream.leaning, "not triggered");
	const shortOnly = kit.summarizeFirstUse([{ tag: "play:horn.ogg", n: 1, ms: 4, len: 0.5 }]);
	assert.equal(shortOnly.item15_stream.leaning, "no stream of 5 s or more seen");
});

test("summarizeOverhead(): the median of the legs' busy p50, so a leg with a shader link does not decide", () => {
	const leg = (on, mean, p50, fps, draws) => ({
		gl_hook: on, fps, p50_ms: 1000 / fps, busy_ms: { mean, p50 }, draws: { p50: draws },
	});
	// The first hook-on leg held 21 shader builds (mean 60 ms) with the same typical frame.
	const o = kit.summarizeOverhead([
		leg(true, 60, 10, 30, 1000), leg(false, 10, 9.8, 30.5, 0), leg(true, 10.6, 10.1, 29.8, 1000),
		leg(false, 10.1, 9.9, 30.1, 0), leg(true, 10.5, 10.2, 29.9, 1000), leg(false, 10.2, 9.7, 30.2, 0),
	]);
	assert.equal(o.on.legs, 3);
	assert.equal(o.off.legs, 3);
	assert.equal(o.on.busy_p50_ms, 10.1);
	assert.equal(o.off.busy_p50_ms, 9.8);
	assert.equal(o.on.busy_mean_ms, 10.6, "the outlier leg's mean of 60 does not move the median");
	assert.equal(o.delta_busy_p50_ms, 0.3);
	assert.equal(o.delta_pct, 3.1);
	assert.equal(o.per_draw_us, 0.3, "0.3 ms over 1000 draws");
	assert.equal(o.on.draws_p50, 1000);
	assert.equal(o.on.spread_ms, 0.2);
	assert.equal(o.noise_ms, 0.2);
	assert.equal(o.within_noise, false, "0.3 ms is above the 0.2 ms spread of the legs");
	// An even number of legs takes the middle of the two, not the upper one.
	const two = kit.summarizeOverhead([leg(true, 1, 10, 30, 10), leg(true, 1, 12, 30, 10), leg(false, 1, 10, 30, 0), leg(false, 1, 10.5, 30, 0)]);
	assert.equal(two.on.busy_p50_ms, 11);
	assert.equal(two.off.busy_p50_ms, 10.25);
	assert.equal(two.delta_busy_p50_ms, 0.75);
	assert.equal(two.within_noise, true, "0.75 ms is inside the 2 ms spread of the hook-on legs");
	// One leg per side has no spread to compare with.
	const single = kit.summarizeOverhead([leg(true, 1, 10, 30, 10), leg(false, 1, 9, 30, 0)]);
	assert.equal(single.delta_busy_p50_ms, 1);
	assert.equal(single.within_noise, null);
	const none = kit.summarizeOverhead([]);
	assert.equal(none.delta_busy_p50_ms, null);
	assert.equal(none.per_draw_us, null);
	assert.equal(none.within_noise, null);
	assert.equal(none.on.legs, 0);
	assert.equal(none.on.busy_p50_ms, null);
});

test("attributeMarks() gives each mark the builds that start before the next mark: first sight builds, a repeat does not", () => {
	const marks = [
		{ t: 100, name: "gf:lamp_pool", detail: { tag: "lamp_pool", n: 1 } },
		{ t: 900, name: "gf:lamp_pool", detail: { tag: "lamp_pool", n: 2 } },
		{ t: 500, name: "gf:pause_menu", detail: { tag: "pause_menu", n: 1 } },
		{ t: 150, name: "gf:probe:row:street", detail: null },
		{ t: 160, name: "gf:play:rain.ogg", detail: { tag: "play:rain.ogg", n: 1, ms: 40, len: 30 } },
	];
	const builds = [
		{ t: 110, kind: "build", ms: 30 }, { t: 130, kind: "build", ms: 12 }, // lamp_pool, first sight
		{ t: 520, kind: "build", ms: 8 }, // pause_menu (a later mark, 900, ends nothing: it is another tag)
		{ t: 910, kind: "build", ms: 0 }, // not a build of lamp_pool's repeat? it is one, of 0 ms
		{ t: 99, kind: "build", ms: 500 }, // before any mark
		{ t: 5000, kind: "build", ms: 700 }, // more than a window after the last mark
	];
	const got = kit.attributeMarks(marks, builds);
	assert.deepEqual(got.map((m) => [m.tag, m.t, m.builds, m.build_ms]), [
		["lamp_pool", 100, 2, 42], ["pause_menu", 500, 1, 8], ["lamp_pool", 900, 1, 0],
	], "probe marks and stopwatch readings are not marks of sight; builds before the first mark and past the window belong to none");
	const roll = kit.rollupMarks(got);
	assert.equal(roll.lamp_pool.seen, 2);
	assert.equal(roll.lamp_pool.first_builds, 2);
	assert.equal(roll.lamp_pool.first_build_ms, 42);
	assert.equal(roll.lamp_pool.repeat_builds, 1);
	assert.equal(roll.pause_menu.repeat_builds, 0);
	assert.deepEqual(kit.attributeMarks([], builds), []);
	assert.deepEqual(kit.rollupMarks([]), {});
	assert.equal(kit.attributeMarks(marks, builds, { windowMs: 20 })[0].builds, 1, "a shorter window");
});

// ---- review fixes: event budgets, no-data leanings, wrapper purity, off-callback work ---------------

const TEX = (gl) => gl.texImage2D(3553, 0, 6408, 4, 4, 0, 6408, 5121, new Uint8Array(64));

// A program build as the engine makes it: link, then the status query.
function link(env, gl, pr, linkMs, statusMs) {
	env.costs.linkProgram = linkMs;
	gl.linkProgram(pr);
	env.costs.getProgramParameter = statusMs;
	gl.getProgramParameter(pr, LINK_STATUS);
}

test("the event budget is per kind: a flood of uploads cannot starve program builds, and drops are counted", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, { maxEvents: 100 });
	const gl = glOf(env);
	const pr = {};
	env.run(16.7, () => {
		gl.drawArrays(4, 0, 3);
		for (let i = 0; i < 150; i++) TEX(gl);
	});
	env.run(33.4, () => {
		for (let i = 0; i < 5; i++) link(env, gl, pr, 40, 60);
	});
	env.run(50.1, () => {});
	env.clock.t += 300;
	const d = api.drain();
	const by = (kind) => d.events.filter((e) => e.kind === kind);
	assert.equal(by("texImage2D").length, 100, "the flooded kind keeps its budget");
	assert.equal(by("build").length, 5, "the builds are all there: they have their own budget");
	assert.deepEqual(d.droppedBy, { texImage2D: 50 });
	assert.equal(d.droppedEvents, 50);
	assert.equal(d.frames[1].k.texImage2D[0], 150, "the per-frame aggregate counted every call");
	const out = kit.summarizeWindow(d, {});
	assert.equal(out.builds.n, 5);
	assert.deepEqual(out.dropped, { frames: 0, events: 50, by_kind: { texImage2D: 50 } });
	assert.equal(out.gl_kinds.texImage2D.n, 150, "gl_kinds comes from the aggregates and is whole");
	// A drain starts the budgets again.
	env.run(66.8, () => {
		for (let i = 0; i < 100; i++) TEX(gl);
	});
	env.run(83.5, () => {});
	const d2 = api.drain();
	assert.equal(d2.events.filter((e) => e.kind === "texImage2D").length, 100);
	assert.deepEqual(d2.droppedBy, {});
	assert.equal(d2.droppedEvents, 0);
	assert.equal(kit.summarizeWindow(d2, {}).dropped, undefined, "nothing dropped, nothing reported");
});

test("builds have a budget of their own, and past it the drop is reported and the leaning says no data", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, { maxBuildEvents: 2 });
	const gl = glOf(env);
	const pr = {};
	env.run(16.7, () => gl.drawArrays(4, 0, 3));
	env.run(33.4, () => {
		for (let i = 0; i < 5; i++) link(env, gl, pr, 40, 60);
	});
	env.run(50.1, () => {});
	env.clock.t += 300;
	const d = api.drain();
	assert.equal(d.events.filter((e) => e.kind === "build").length, 2);
	assert.deepEqual(d.droppedBy, { build: 3 });
	assert.equal(d.frames[2].k.build[0], 5, "the aggregate still saw five");
	const seg = kit.summarizeWindow(d, {});
	const roll = kit.rollupBuilds([seg]);
	const dropped = kit.rollupDropped([seg, { dropped: { frames: 1, events: 2, by_kind: { build: 1, texImage2D: 1 } } }, {}]);
	assert.deepEqual(dropped, { frames: 1, events: 5, by_kind: { build: 4, texImage2D: 1 } });
	assert.match(kit.leanings(roll, null, { dropped }).item10_link_warmup.leaning, /^no data: 4 build events were dropped/);
	// Drops of another kind do not touch item 10.
	assert.equal(kit.leanings(roll, null, { dropped: { frames: 0, events: 9, by_kind: { texImage2D: 9 } } }).item10_link_warmup.leaning, "inconclusive");
	assert.deepEqual(kit.rollupDropped([]), { frames: 0, events: 0, by_kind: {} });
});

// One upload a frame at 16.7 ms: 60 a second, however much of it the in-page lists could keep.
function steadyUploads(cfg, frames) {
	const env = makeEnv();
	const api = kit.installProbe(env.win, cfg);
	const gl = glOf(env);
	for (let i = 0; i < frames; i++) {
		env.clock.t += 16.7;
		env.run(env.clock.t, () => TEX(gl));
	}
	env.clock.t += 16.7;
	return api.drain();
}

test("event rates stay true when the frame log overflows: events are not trimmed with frames, so they use the whole window", () => {
	const d = steadyUploads({ maxFrames: 100 }, 250);
	assert.ok(d.droppedFrames > 0 && d.frames.length < 100, "the log kept only the newest frames: " + d.frames.length);
	assert.equal(d.events.filter((e) => e.kind === "texImage2D").length, 250, "no event was dropped, none trimmed");
	const out = kit.summarizeWindow(d, {});
	assert.equal(out.dropped.frames, d.droppedFrames);
	// 250 uploads in 251 frames of 16.7 ms is 59.6 a second. Over the span of the few frames kept it would be 5 times that.
	assert.ok(Math.abs(out.events.texImage2D.per_s - 59.6) < 1, "events: " + out.events.texImage2D.per_s);
	assert.ok(Math.abs(out.gl_kinds.texImage2D.per_s - 60) < 3, "gl_kinds counts the calls of the kept frames over their span: " + out.gl_kinds.texImage2D.per_s);
});

test("event rates stay true when a kind runs out of budget: its events stop where its budget did", () => {
	const d = steadyUploads({ maxFrames: 100, maxEvents: 100 }, 250);
	assert.equal(d.events.filter((e) => e.kind === "texImage2D").length, 100);
	assert.equal(d.droppedBy.texImage2D, 150);
	const out = kit.summarizeWindow(d, {});
	// 100 events cover the first 1.67 s of the window: 60 a second, not 100 over the kept frames' 0.8 s or over 4.2 s.
	assert.ok(Math.abs(out.events.texImage2D.per_s - 59.9) < 1, "events: " + out.events.texImage2D.per_s);
	// Without a frame overflow the same budget run reads the same, over the frames' own span.
	const flat = kit.summarizeWindow(steadyUploads({ maxEvents: 100 }, 250), {});
	assert.ok(Math.abs(flat.events.texImage2D.per_s - 59.9) < 1, "events: " + flat.events.texImage2D.per_s);
	// A drain starts the window again: the next one is measured from the drain.
	const env = makeEnv();
	const api = kit.installProbe(env.win, { maxFrames: 100 });
	const gl = glOf(env);
	for (let i = 0; i < 150; i++) {
		env.clock.t += 16.7;
		env.run(env.clock.t, () => TEX(gl));
	}
	api.drain();
	const since = env.clock.t;
	for (let i = 0; i < 30; i++) {
		env.clock.t += 16.7;
		env.run(env.clock.t, () => TEX(gl));
	}
	const second = api.drain();
	assert.ok(Math.abs(second.since - since) < 1, "drain() says when its window started: " + second.since + " vs " + since);
});

test("a build that starts before the last link's status is read is counted as batched work, after the first drawn frame", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	const gl = glOf(env);
	const progs = [{}, {}, {}, {}, {}];
	// The engine's start-up links one program without ever reading its status (the old build's boot log shows it),
	// and the next program's calls overlap it. Not batching, and before the first drawn frame, where no build is
	// counted.
	env.run(16.7, () => {
		gl.compileShader({});
		gl.compileShader({});
		gl.linkProgram({});
		for (let i = 0; i < 2; i++) {
			gl.compileShader({});
			gl.getShaderParameter({}, COMPILE_STATUS);
		}
		link(env, gl, {}, 1, 1);
	});
	env.run(33.4, () => gl.drawArrays(4, 0, 3));
	// What Godot does: one program at a time. Nothing is batched.
	env.run(50.1, () => {
		for (const p of progs) {
			env.costs.compileShader = 5;
			gl.compileShader({});
			env.costs.getShaderParameter = 1;
			gl.getShaderParameter({}, COMPILE_STATUS);
			link(env, gl, p, 3, 20);
		}
	});
	env.run(66.8, () => {});
	env.clock.t += 300; // the last build closes once it has been idle for the gap
	const seq = api.drain();
	assert.equal(seq.frames[1].bt, 3, "the start-up's three overlaps are on its frame");
	const segSeq = kit.summarizeWindow(seq, {});
	assert.equal(segSeq.first_draw_frame, 2);
	assert.equal(segSeq.builds.batched, 0, "...and are not counted: they come before the first drawn frame");
	assert.equal(segSeq.builds.n, 5, "five programs, five builds");
	// Compile all, link all, then ask: the shape that cannot be sized per program.
	env.run(83.5, () => {
		env.costs.compileShader = 5;
		for (const p of progs) gl.compileShader(p);
		env.costs.linkProgram = 3;
		for (const p of progs) gl.linkProgram(p);
		env.costs.getProgramParameter = 20;
		for (const p of progs) gl.getProgramParameter(p, LINK_STATUS);
	});
	env.run(100.2, () => {});
	env.clock.t += 300;
	const bat = api.drain();
	const seg = kit.summarizeWindow(bat, { firstDrawFrame: segSeq.first_draw_frame });
	assert.equal(seg.builds.batched, 4, "the second to the fifth link each began before the status of the one before");
	const sum = bat.events.filter((e) => e.kind === "build").reduce((x, e) => x + e.ms, 0);
	assert.equal(sum, 5 * 5 + 5 * 3 + 5 * 20, "every millisecond is still booked");
	assert.equal(kit.summarizeWindow(bat, {}).builds.batched, 0, "a window with no drawn frame of its own counts none");
	assert.equal(kit.rollupBuilds([seg, segSeq]).batched, 4);
	// A result that was batched is compared on its frames with links only: n is not per program there.
	const roll = (n, events, batched) => ({ link_builds: { n, events, batched } });
	assert.equal(kit.compareLinks(roll(100, 20, 0), roll(60, 20, 0)).stable, false);
	const cmp = kit.compareLinks(roll(100, 20, 0), roll(60, 20, 7));
	assert.equal(cmp.stable, true);
	assert.equal(cmp.batched, true);
	assert.equal(kit.compareLinks(roll(100, 20, 0), roll(100, 40, 7)).stable, false, "the frames with links still count");
});

test("leanings() says no data instead of answering from zeros", () => {
	const zero = { n: 0, total_ms: 0, max_ms: 0, ge_100: 0, ge_150: 0, events: 0, event_max_ms: 0, events_ge_100: 0, events_ge_150: 0 };
	const lean = (opts) => kit.leanings(zero, null, opts).item10_link_warmup.leaning;
	assert.equal(lean({}), "drop", "the census saw draws and no links: a real zero");
	assert.match(lean({ hooked: false }), /^no data: the WebGL census was off or saw no draws/);
	assert.match(lean({ hooked: false, hardware: false }), /^no data/, "nothing measured beats software");
	assert.match(lean({ hooked: false, cold: false }), /^no data/);
	const walk = { events: { readPixels: { n: 4, per_s: 0.1, p95: 1 } }, marks: [] };
	assert.equal(kit.leanings(zero, walk, {}).item16_readback.leaning, "close");
	assert.match(kit.leanings(zero, walk, { hooked: false }).item16_readback.leaning, /^no data/);
});

test("leanings(): the thresholds of item 10 and item 16 sit exactly where the backlog puts them", () => {
	const roll = (o) => Object.assign({ n: 5, total_ms: 0, max_ms: 0, ge_100: 0, ge_150: 0, events: 5, event_max_ms: 0, events_ge_100: 0, events_ge_150: 0 }, o);
	const lean = (o) => kit.leanings(roll(o), null, {}).item10_link_warmup.leaning;
	assert.equal(lean({ total_ms: 999.9, event_max_ms: 100 }), "drop");
	assert.equal(lean({ total_ms: 1000, event_max_ms: 100 }), "inconclusive", "1 s of links is no longer 'under 1 s'");
	assert.equal(lean({ total_ms: 500, event_max_ms: 100.1 }), "inconclusive", "one event over 100 ms");
	assert.equal(lean({ total_ms: 1999.9, event_max_ms: 120 }), "inconclusive");
	assert.equal(lean({ total_ms: 2000, event_max_ms: 120 }), "build", "2 s of links");
	assert.equal(lean({ total_ms: 500, event_max_ms: 160, events_ge_150: 2 }), "inconclusive");
	assert.equal(lean({ total_ms: 500, event_max_ms: 160, events_ge_150: 3 }), "build", "three events of 150 ms");
	const rp = (n, per_s, p95) => kit.leanings(roll({}), { events: { readPixels: { n, per_s, p95 } }, marks: [] }, {}).item16_readback.leaning;
	assert.equal(rp(5, 0.49, 2.99), "close");
	assert.equal(rp(5, 0.5, 2.99), "keep open", "0.5 calls per second");
	assert.equal(rp(5, 0.49, 3), "keep open", "a p95 of 3 ms");
	assert.equal(rp(5, 0.1, 4.99), "keep open");
	assert.equal(rp(5, 0.1, 5), "build the cheap tier");
});

test("leanings() on item 16: software, an empty window and a dropped readback are not 'close'", () => {
	const zero = { n: 0, total_ms: 0, max_ms: 0, ge_100: 0, ge_150: 0, events: 0, event_max_ms: 0, events_ge_100: 0, events_ge_150: 0 };
	const item16 = (walk, opts) => kit.leanings(zero, walk, opts).item16_readback;
	const read = { n: 3, per_s: 0.2, p95: 1.2 };
	// The software-GL walk of the live build: no readback, 2.71 texImage2D a second, and the verdict was "close".
	const soft = item16({ events: { texImage2D: { n: 20, per_s: 2.71, p95: 0.02 } }, marks: [] }, { hardware: false });
	assert.match(soft.leaning, /^withheld: software renderer \(per-second rates/);
	assert.match(item16({ events: { readPixels: read }, marks: [] }, { hardware: false }).leaning, /^withheld/, "readbacks seen, still software");
	assert.equal(item16({ events: { readPixels: read }, marks: [] }, {}).leaning, "close");
	// A real GPU, no readPixels, no poster composite in the window: nothing was measured.
	const empty = item16({ events: {}, marks: [{ t: 1, name: "gf:lamp_pool", detail: { tag: "lamp_pool" } }] }, {});
	assert.match(empty.leaning, /^no data: no readPixels and no poster composite/);
	assert.equal(empty.composites_in_window, 0);
	// ...with a composite in the window and still no readPixels, the composite does not read back: close.
	const composite = item16({ events: {}, marks: [{ t: 1, name: "gf:poster_composite", detail: { tag: "poster_composite", n: 1 } }] }, {});
	assert.equal(composite.leaning, "close");
	assert.equal(composite.composites_in_window, 1);
	assert.match(item16({ events: { readPixels: read }, marks: [] }, { dropped: { frames: 0, events: 7, by_kind: { readPixels: 7 } } }).leaning, /^no data: 7 readPixels events were dropped/);
	assert.equal(item16({ events: { readPixels: read } }, {}).leaning, "close", "a window without a marks list");
});

test("isSoftwareRenderer(): SwiftShader, llvmpipe, lavapipe, softpipe and WARP are software; a GPU is not", () => {
	const soft = [
		"ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver)",
		"ANGLE (Mesa, llvmpipe (LLVM 15.0.7, 256 bits), OpenGL 4.5)",
		"ANGLE (Mesa, Vulkan 1.3.255 (llvmpipe (LLVM 17.0.6, 256 bits) (0x00000000)), llvmpipe)",
		"ANGLE (Mesa, Vulkan 1.3.246 (lavapipe (LLVM 15.0.7, 256 bits) (0x0000C0DE)), lavapipe)",
		"ANGLE (Mesa, softpipe, OpenGL 4.5)",
		"ANGLE (Microsoft, Microsoft Basic Render Driver Direct3D11 vs_5_0 ps_5_0, D3D11)",
		"ANGLE (Microsoft, Microsoft Direct3D11 WARP vs_5_0 ps_5_0, D3D11)",
		"Apple Software Renderer", "no webgl2", "", null, undefined,
	];
	for (const r of soft) assert.equal(kit.isSoftwareRenderer(r), true, String(r));
	const gpu = [
		"ANGLE (AMD, AMD Radeon Graphics (radeonsi, renoir, LLVM 15.0.7, DRM 3.49, 6.5.0), OpenGL 4.6)",
		"ANGLE (Intel, Mesa Intel(R) UHD Graphics 620 (KBL GT2), OpenGL 4.6)",
		"ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0, D3D11)",
		"ANGLE (Apple, ANGLE Metal Renderer: Apple M2, Unspecified Version)",
	];
	for (const r of gpu) assert.equal(kit.isSoftwareRenderer(r), false, r);
});

test("coldCache(): a fresh profile is cold only where the driver's own cache does not outlive it", () => {
	const cold = (o) => kit.coldCache(Object.assign({ profileFresh: true, platform: "linux", mesaDisable: "" }, o));
	assert.equal(cold({ profileFresh: false }).cold, false);
	assert.match(cold({ profileFresh: false, mesaDisable: "true" }).why, /^reused Chrome profile/, "Mesa off does not make a used profile cold");
	const warm = cold({});
	assert.equal(warm.cold, false, "Linux, Mesa cache on: it outlives the profile");
	assert.match(warm.why, /MESA_SHADER_CACHE_DISABLE=true/);
	for (const v of ["true", "1", "TRUE", " on ", "yes"]) assert.equal(cold({ mesaDisable: v }).cold, true, v);
	for (const v of ["false", "0", "", undefined, null]) assert.equal(cold({ mesaDisable: v }).cold, false, String(v));
	assert.equal(cold({ platform: "win32" }).cold, true);
	assert.match(cold({ platform: "win32" }).why, /driver's own cache on win32 is not controlled/);
	assert.equal(cold({ platform: "darwin", mesaDisable: "false" }).cold, true, "Mesa's switch is Linux's");
});

test("the wrapper writes nothing to the page's objects: a frozen framebuffer binds, a non-handle reaches the native call", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	const gl = glOf(env);
	const [a, b, c] = [Object.freeze({}), Object.seal({}), Object.preventExtensions({})];
	env.run(16.7, () => {
		gl.bindFramebuffer(FRAMEBUFFER, a);
		gl.viewport(0, 0, 8, 8);
		gl.drawArrays(4, 0, 3);
		gl.bindFramebuffer(FRAMEBUFFER, b);
		gl.drawArrays(4, 0, 3);
		gl.bindFramebuffer(FRAMEBUFFER, c);
		gl.drawArrays(4, 0, 3);
		gl.bindFramebuffer(FRAMEBUFFER, a);
		gl.drawArrays(4, 0, 3);
		// Not a handle: the native call is where WebGL rejects it. The census neither throws nor moves.
		assert.doesNotThrow(() => gl.bindFramebuffer(FRAMEBUFFER, 5));
		assert.doesNotThrow(() => gl.bindFramebuffer(FRAMEBUFFER, "x"));
		gl.drawArrays(4, 0, 3);
	});
	env.run(33.4, () => {});
	for (const o of [a, b, c]) assert.deepEqual(Object.getOwnPropertyNames(o), [], "no expando on a handle");
	assert.deepEqual(gl.calls.filter((m) => m === "bindFramebuffer").length, 6, "all six calls reached the native method");
	const f = api.drain().frames[1];
	assert.deepEqual(f.passes.map((p) => p[3]), [1, 1, 1, 2], "a, b, c, then a again with the two draws after the junk binds");
	assert.equal(f.fb, 6);
	api.uninstall();
});

test("work outside a rAF callback is booked apart: it moves neither the first drawn frame nor the busy time", () => {
	const env = makeEnv();
	const api = kit.installProbe(env.win, {});
	const gl = glOf(env);
	const pr = {};
	// The loader's own rAF frames, with nothing drawn.
	env.run(16.7, () => {});
	env.run(33.4, () => {});
	env.run(50.1, () => {});
	// The engine's start-up runs in a task of its own: builds and a draw outside any callback.
	link(env, gl, pr, 100, 400);
	gl.drawArrays(4, 0, 3);
	// Frame 4 is the first real draw and holds one build of its own.
	env.run(2000, () => {
		link(env, gl, pr, 10, 10);
		gl.drawElements(4, 6, 5123, 0);
	});
	env.run(2016.7, () => gl.drawElements(4, 6, 5123, 0));
	link(env, gl, pr, 30, 20); // outside a callback again, after the first drawn frame
	env.run(2300, () => gl.drawElements(4, 6, 5123, 0));
	env.run(2316.7, () => {});
	env.clock.t += 300;
	const d = api.drain();
	assert.equal(d.frames[3].od, 1, "the start-up draw is booked as outside");
	assert.equal(d.frames[3].om, 500);
	assert.equal(d.frames[3].busy, 0, "...and is not in any callback's busy time");
	assert.equal(d.frames[4].od, 0);
	assert.equal(d.frames[4].om, 0, "frame 4's own build ran inside its callback");
	const builds = d.events.filter((e) => e.kind === "build");
	assert.deepEqual(builds.map((b) => [b.f, b.off]), [[3, true], [4, false], [5, true]]);
	const out = kit.summarizeWindow(d, {});
	assert.equal(out.first_draw_frame, 4, "frame 3's draw was the engine's start-up, not a frame");
	assert.equal(out.builds.n, 1, "only the build after the first drawn frame: not start-up, not the first frame's own");
	assert.equal(out.builds.total_ms, 50);
	assert.deepEqual(out.off_raf, { gl_ms: 550, draws: 1, builds: 2, build_ms: 550 });
	// Frame 5 ran 50 ms of GL after its callbacks: that is in its own interval (283 ms to frame 6's timestamp).
	const hit = out.hitches.worst.find((h) => h.frame === 5);
	assert.equal(hit.off_ms, 50, "what ran between frame 5's callbacks and frame 6's");
	assert.equal(hit.interval_ms, 283.3);
	assert.equal(hit.gl_ms, 0);
	assert.equal(hit.busy_ms, 0);
	assert.equal(out.hitches.worst.find((h) => h.frame === 6), undefined, "frame 6 only arrived late");
	// An off-callback build in the gap right after the first drawn frame comes after it.
	assert.equal(kit.summarizeWindow(d, { firstDrawFrame: 5 }).builds.n, 1, "booked to frame 5, outside: after it");
	assert.equal(kit.summarizeWindow(d, { firstDrawFrame: 6 }).builds.n, 0);
});

test("attributeMarks() counts only the game's FirstUse marks, not the boot clock's gf: stages", () => {
	// What the boot lane's marks look like next to a first-use sight (the reviewer's collision case).
	const marks = [
		{ t: 1000, name: "gf:view_setup", detail: null },
		{ t: 1050, name: "gf:site", detail: { tag: "site", n: 1 } },
		{ t: 1055, name: "gf:fp_setup", detail: null },
		{ t: 1090, name: "gf:load:overview", detail: null },
		{ t: 1100, name: "gf:veil_released" },
	];
	const builds = [{ t: 1060, kind: "build", ms: 120 }];
	const got = kit.attributeMarks(marks, builds);
	assert.deepEqual(got.map((m) => [m.tag, m.builds, m.build_ms]), [["site", 1, 120]], "the build stays with the site, whatever stage mark follows");
	assert.deepEqual(Object.keys(kit.rollupMarks(got)), ["site"]);
	assert.deepEqual(kit.attributeMarks([{ t: 1, name: "gf:x", detail: { tag: 5 } }, { t: 2, name: "gf:y", detail: "text" }], []), [], "a detail without a string tag");
});

test("summarizeFirstUse() leaves the session's first long stream out of the rate, which pays a one-off first-play cost", () => {
	const rec = (tag, ms, len) => ({ tag, n: 1, ms, len });
	// Two 25 s beds: the first (played first) reads 90 ms, 3.6 ms/s, alone enough for "build"; the second 50 ms.
	const two = kit.summarizeFirstUse([rec("play:nominal.ogg", 90, 25), rec("play:crisis.ogg", 50, 25)]);
	assert.equal(two.item15_stream.max_ms_per_s, 2, "the second bed decides");
	assert.equal(two.item15_stream.leaning, "not triggered");
	assert.equal(two.item15_stream.first_left_out, true);
	assert.deepEqual(two.item15_stream.first_long_stream, { tag: "play:nominal.ogg", ms_per_s: 3.6 });
	assert.equal(two.item15_stream.long_streams, 2);
	assert.equal(two.item15_stream.max_ms_per_s_any, 3.6, "the unfiltered worst stays listed");
	// It is the first PLAYED that is left out, not the slowest: here the slow one is second.
	const swapped = kit.summarizeFirstUse([rec("play:crisis.ogg", 50, 25), rec("play:nominal.ogg", 90, 25)]);
	assert.equal(swapped.item15_stream.max_ms_per_s, 3.6);
	assert.equal(swapped.item15_stream.leaning, "build");
	assert.equal(swapped.item15_stream.first_long_stream.tag, "play:crisis.ogg");
	// Short streams in between do not count as the first long one.
	const mixed = kit.summarizeFirstUse([rec("play:click.ogg", 9, 0.2), rec("play:a.ogg", 90, 25), rec("play:b.ogg", 40, 25)]);
	assert.equal(mixed.item15_stream.first_long_stream.tag, "play:a.ogg");
	assert.equal(mixed.item15_stream.max_ms_per_s, 1.6);
	// A single long stream cannot be discounted: it decides, and nothing is left out.
	const one = kit.summarizeFirstUse([rec("play:a.ogg", 200, 30)]);
	assert.equal(one.item15_stream.leaning, "build");
	assert.equal(one.item15_stream.first_left_out, false);
	assert.equal(kit.summarizeFirstUse([]).item15_stream.first_long_stream, null);
});

test("parseKnobs() refuses what it would otherwise ignore: unknown names, unknown flags, empty rows, contradictions", () => {
	assert.throws(() => kit.parseKnobs({ GF_FPS_VIEWPORTS: "1920x1080" }), /GF_FPS_VIEWPORTS is not a probe knob \(closest: GF_FPS_VIEWPORT/);
	assert.throws(() => kit.parseKnobs({ GF_FPS_DRP: "3" }), /GF_FPS_DRP is not a probe knob \(closest: GF_FPS_DPR/);
	assert.deepEqual(kit.parseKnobs({ HOME: "/x", GF_OTHER: "1", GF_FPS: "1" }).rows, ["street", "walk", "sky", "orbit"], "other variables are not ours");
	const blanks = Object.fromEntries(kit.KNOB_NAMES.map((n) => [n, ""]));
	assert.doesNotThrow(() => kit.parseKnobs(blanks), "every documented knob is accepted, blank");
	assert.equal(kit.KNOB_NAMES.length, 19);
	assert.equal(kit.parseKnobs({}).noOcclusion, false, "the occlusion check is off by default");
	assert.equal(kit.parseKnobs({ GF_FPS_NO_OCCLUSION: "1" }).noOcclusion, true);
	const known = ["web_first_use_marks", "web_real_time_pace", "streetscape"];
	assert.throws(() => kit.parseFlags("web_first_use_mark=1", known), /does not define: "web_first_use_mark" \(closest: web_first_use_marks/);
	assert.deepEqual(kit.parseFlags("web_real_time_pace=1", known), { web_real_time_pace: true });
	assert.deepEqual(kit.parseFlags("anything=1", null), { anything: true }, "no list, no check");
	assert.throws(() => kit.parseKnobs({ GF_FPS_FLAGS: "typo_flag=1" }, known), /GF_FPS_FLAGS/);
	assert.deepEqual(kit.parseKnobs({}, known).flags, { web_first_use_marks: true }, "the default is not checked against the list");
	assert.deepEqual(kit.parseKnobs({ GF_FPS_FLAGS: "none" }, known).flags, {}, "none writes an empty table");
	for (const spec of [",", " , ", ",,"]) assert.throws(() => kit.parseKnobs({ GF_FPS_ROWS: spec }), /names no row/, JSON.stringify(spec));
	assert.throws(() => kit.parseKnobs({ GF_FPS_AB: "6", GF_FPS_KIT: "0" }), /GF_FPS_AB .* needs GF_FPS_KIT and GF_FPS_GLHOOK/);
	assert.throws(() => kit.parseKnobs({ GF_FPS_AB: "6", GF_FPS_GLHOOK: "0" }), /GF_FPS_AB/);
	assert.equal(kit.parseKnobs({ GF_FPS_AB: "6" }).abS, 6);
	assert.equal(kit.parseKnobs({ GF_FPS_KIT: "0" }).abS, 0, "kit off without an A/B is fine");
});

test("parseKnobs(): bounds, defaults and the profile directory as an absolute path", () => {
	const path = require("node:path");
	assert.equal(kit.parseKnobs({ GF_FPS_AB: "120" }).abS, 120);
	assert.throws(() => kit.parseKnobs({ GF_FPS_AB: "121" }), /GF_FPS_AB/);
	assert.throws(() => kit.parseKnobs({ GF_FPS_AB: "-1" }), /GF_FPS_AB/);
	assert.equal(kit.parseKnobs({ GF_FPS_SETTLE_S: "900" }).settleS, 900);
	assert.throws(() => kit.parseKnobs({ GF_FPS_SETTLE_S: "901" }), /GF_FPS_SETTLE_S/);
	assert.equal(kit.parseKnobs({ GF_FPS_WINDOW_S: "600" }).windowS, 600);
	assert.throws(() => kit.parseKnobs({ GF_FPS_WINDOW_S: "601" }), /GF_FPS_WINDOW_S/);
	const d = kit.parseKnobs({});
	assert.equal(d.memory, true, "the memory readings are on unless switched off");
	assert.equal(d.raw, false, "the raw frames are kept only when asked");
	assert.equal(kit.parseKnobs({ GF_FPS_MEMORY: "0" }).memory, false);
	assert.equal(kit.parseKnobs({ GF_FPS_RAW: "1" }).raw, true);
	// Chrome's command line carries the path Playwright resolved; the process-tree match needs the same text.
	assert.equal(kit.parseKnobs({ GF_FPS_USER_DATA_DIR: "./relprof" }).profile, path.resolve("./relprof"));
	assert.equal(path.isAbsolute(kit.parseKnobs({ GF_FPS_USER_DATA_DIR: "relprof" }).profile), true);
	assert.equal(kit.parseKnobs({ GF_FPS_USER_DATA_DIR: "/tmp/p" }).profile, "/tmp/p");
});

test("stats() takes the median at floor(n * 0.5) and the p95 at floor(n * 0.95)", () => {
	const ten = Array.from({ length: 10 }, (_, i) => i + 1);
	assert.equal(kit.stats(ten).p50, 6, "index 5 of 10");
	assert.equal(kit.stats(ten).p95, 10);
	const twenty = Array.from({ length: 20 }, (_, i) => i + 1);
	assert.equal(kit.stats(twenty).p50, 11);
	assert.equal(kit.stats(twenty).p95, 20, "index 19 of 20, not 18");
	assert.equal(kit.stats(twenty).p99, 20);
	assert.equal(kit.percentile([1, 2, 3, 4], 0.5), 3);
	assert.equal(kit.percentile([], 0.5), null);
});

test("compareLinks() and compareCensus() look at the frames with links and at useProgram too", () => {
	const links = (n, events) => ({ link_builds: { n, events } });
	const events = kit.compareLinks(links(100, 5), links(100, 40));
	assert.equal(events.stable, false, "the same programs in far fewer frames is a different warm-up");
	assert.deepEqual(events.reasons, ["events: 5 vs 40"]);
	assert.equal(kit.compareLinks(links(100, 5), links(100, 7)).stable, true);
	const up = kit.compareCensus(census(1000, 12, 12, 80, 90), census(1000, 12, 12, 80, 200));
	assert.equal(up.stable, false);
	assert.deepEqual(up.reasons, ["use_program: 90 vs 200"]);
});

test("the CLI exits 2, not 1, for a bad tolerance, a bad row or a file it cannot read", () => {
	const fs = require("node:fs");
	const os = require("node:os");
	const path = require("node:path");
	const { spawnSync } = require("node:child_process");
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gf-kit-cli-"));
	try {
		const a = path.join(dir, "a.json");
		fs.writeFileSync(a, JSON.stringify(census(1000, 12, 12, 80, 90)));
		const script = path.join(__dirname, "..", "web_probe_kit.js");
		const run = (...args) => spawnSync("node", [script, "compare", ...args], { encoding: "utf8" });
		assert.equal(run(a, a).status, 0);
		const nan = run(a, a, "abc");
		assert.equal(nan.status, 2);
		assert.match(nan.stderr, /tolerance must be a fraction from 0 to 1, got "abc"/);
		assert.equal(run(a, a, "2").status, 2, "above 1");
		assert.equal(run(a, a, "-0.1").status, 2);
		const missing = run(a, path.join(dir, "nope.json"));
		assert.equal(missing.status, 2, "a missing file is not 'the results differ'");
		assert.match(missing.stderr, /cannot read .*nope\.json/);
		assert.doesNotMatch(missing.stderr, /at Object|node:internal/, "a message, not a stack");
		fs.writeFileSync(path.join(dir, "bad.json"), "{not json");
		assert.equal(run(a, path.join(dir, "bad.json")).status, 2);
		assert.equal(run(a, a, "0.1", "moon").status, 2);
		assert.match(run(a, a, "0.1", "moon").stderr, /row must be one of street, walk, sky, orbit, all/);
		assert.equal(run(a, a, "0", "street").status, 0, "a tolerance of 0 is allowed");
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

// ---- audio sections and the stripe metric ----------------------------------------------------------

test("parseAudioSections() keeps the slowest reading of each section over every AUDIOSEC line", () => {
	const r = kit.parseAudioSections([
		'log AUDIOSEC {"ms":{"emitters":0.4,"ambience":2.1}}',
		"unrelated",
		'AUDIOSEC {"ms":{"emitters":1.9,"falls":0.01}}',
		'AUDIOSEC {"ms":{"emitters":',
		"AUDIOSEC not json",
	]);
	assert.equal(r.lines, 2);
	assert.deepEqual(r.max, { emitters: 1.9, ambience: 2.1, falls: 0.01 });
	assert.deepEqual(r.worst, { section: "ambience", ms: 2.1 });
	assert.deepEqual(kit.parseAudioSections([]), { lines: 0, max: {}, worst: null });
});

function stripes(w, h, period, amp, tilt) {
	const a = new Float64Array(w * h);
	for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) a[y * w + x] = 100 + amp * Math.sin((2 * Math.PI * (y + tilt * x)) / period);
	return a;
}

test("dogRms(): a flat field reads zero and a slow gradient reads (almost) nothing", () => {
	const w = 90, h = 70;
	assert.ok(kit.dogRms(new Float64Array(w * h).fill(120), w, h) < 1e-9);
	const grad = new Float64Array(w * h);
	for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) grad[y * w + x] = 50 + 0.4 * x + 0.2 * y;
	assert.ok(kit.dogRms(grad, w, h) < 0.05, "a lighting ramp is not a stripe");
});

test("dogRms(): fine stripes read, tilted ones too (the row profile cannot see those), coarse ones do not", () => {
	const w = 120, h = 90;
	const flat = kit.dogRms(stripes(w, h, 8, 0, 0), w, h);
	const fine = kit.dogRms(stripes(w, h, 8, 3, 0), w, h);
	const tilted = kit.dogRms(stripes(w, h, 8, 3, 0.7), w, h);
	const coarse = kit.dogRms(stripes(w, h, 60, 3, 0), w, h);
	assert.ok(fine > 0.8 && tilted > 0.5 && flat < 1e-9, `${flat} ${fine} ${tilted}`);
	assert.ok(coarse < fine / 4, `a 60 px swell (${coarse}) is not an 8 px stripe (${fine})`);
	// More amplitude, more energy.
	assert.ok(kit.dogRms(stripes(w, h, 8, 6, 0.7), w, h) > 1.8 * tilted);
});

test("dogRms(): the margin is scored far less than the interior, and a crop smaller than it is refused", () => {
	const w = 70, h = 70;
	const inMargin = new Float64Array(w * h).fill(100);
	const inside = new Float64Array(w * h).fill(100);
	for (let x = 0; x < w; x++) { inMargin[x] = 255; inside[(h >> 1) * w + x] = 255; }
	assert.ok(kit.dogRms(inMargin, w, h, 12) < kit.dogRms(inside, w, h, 12) / 20, "a bright first row sits in the margin");
	assert.throws(() => kit.dogRms(new Float64Array(20 * 20), 20, 20, 12), /smaller than its margins/);
});

test("rowProfileRms(): horizontal stripes read near amp/sqrt(2), a flat field, a ramp and a broad swell do not", () => {
	const w = 80, h = 130;
	const flat = kit.rowProfileRms(new Float64Array(w * h).fill(120), w, h);
	const fine = kit.rowProfileRms(stripes(w, h, 8, 3, 0), w, h);
	const coarse = kit.rowProfileRms(stripes(w, h, 80, 3, 0), w, h);
	const ramp = new Float64Array(w * h);
	for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) ramp[y * w + x] = 50 + 0.5 * y + 0.2 * x;
	assert.ok(flat < 1e-9);
	assert.ok(Math.abs(fine - 3 / Math.SQRT2) < 0.3, `an 8-row stripe of amplitude 3 reads ${fine}`);
	assert.ok(coarse < fine / 3, `an 80-row swell (${coarse}) is not a stripe (${fine})`);
	assert.ok(kit.rowProfileRms(ramp, w, h) < 0.05, "a lighting ramp is not a stripe");
	assert.ok(kit.rowProfileRms(stripes(w, h, 8, 6, 0), w, h) > 1.8 * fine, "more amplitude, more energy");
});

test("rowProfileRms(): stripes tilted across the crop average out (use dogRms for those), a short crop is refused", () => {
	const w = 120, h = 130;
	const tilted = kit.rowProfileRms(stripes(w, h, 8, 3, 0.7), w, h);
	assert.ok(tilted < kit.rowProfileRms(stripes(w, h, 8, 3, 0), w, h) / 5, `tilted ${tilted}`);
	assert.throws(() => kit.rowProfileRms(new Float64Array(80 * 50), 80, 50), /smaller than its margins/);
});

test("stripeVerdict(): over the limit fails, at or under passes, no number fails", () => {
	assert.deepEqual(kit.stripeVerdict(1.9), { rms: 1.9, max: kit.STRIPE_MAX, ok: true });
	assert.equal(kit.stripeVerdict(kit.STRIPE_MAX).ok, true);
	for (const old of [2.75, 2.89, 2.99]) assert.equal(kit.stripeVerdict(old).ok, false, `${old}: the measured old normal bias (0.6) must fail`);
	for (const fixed of [0.71, 1.15, 1.19]) assert.equal(kit.stripeVerdict(fixed).ok, true, `${fixed}: the measured fixed bias (1.5) must pass`);
	assert.equal(kit.stripeVerdict(NaN).ok, false);
	assert.equal(kit.stripeVerdict(null).ok, false);
});

test("STRIPE_BAND lies below the horizon and inside the frame, clear of the HUD bar", () => {
	const b = kit.STRIPE_BAND;
	assert.ok(b.x0 >= 0 && b.x1 <= 1 && b.x0 < b.x1 && b.y0 > 0.5 && b.y1 <= 0.85 && b.y0 < b.y1);
});

test("GF_FPS_STRIPES is a knob: on by default, 0 turns the pose off, a typo is refused", () => {
	assert.equal(kit.parseKnobs({}).stripes, true);
	assert.equal(kit.parseKnobs({ GF_FPS_STRIPES: "0" }).stripes, false);
	assert.throws(() => kit.parseKnobs({ GF_FPS_STRIPES: "lots" }), /GF_FPS_STRIPES/);
	assert.ok(kit.KNOB_NAMES.includes("GF_FPS_STRIPES"));
});

test("GF_FPS_AUDIBLE is a knob: off by default, a switch, and a typo is refused", () => {
	assert.equal(kit.parseKnobs({}).audible, false);
	assert.equal(kit.parseKnobs({ GF_FPS_AUDIBLE: "1" }).audible, true);
	assert.throws(() => kit.parseKnobs({ GF_FPS_AUDIBLE: "loud" }), /GF_FPS_AUDIBLE/);
	assert.ok(kit.KNOB_NAMES.includes("GF_FPS_AUDIBLE"));
});
