// Browser hitch-attribution kit for the GridFall web build (docs/runbooks/web-probe-kit.md).
// tools/web_fps_probe.js injects installProbe() before the game's first script and turns what it
// records into rows; everything here that does not need a browser is tested offline by
// tools/tests/web_probe_kit.test.js (node --test).
//
// 1. installProbe(window, cfg): runs inside the page. It wraps the WebGL calls that block or that
//    stand for hidden work, aggregates them per rAF frame, and records long tasks and the game's
//    FirstUse marks. A frame is whatever happens between two rAF timestamps. Draws, framebuffer
//    binds and program switches are only counted (timing a 2 us call with a 100 us clock says
//    nothing); the calls that can block the main thread are timed. setGl(false) restores every
//    WebGL method, so "off" costs nothing.
// 2. summarizeWindow() and friends: pure functions from drain() output to the rows of the probe.
// 3. Env knobs, the display-rate estimate, a ps parser for process RSS and a census comparison.
//
// usage of the CLI:  node tools/web_probe_kit.js compare <result-a.json> <result-b.json> [tolerance]
"use strict";

const path = require("path");

// The page half reports v: 1 in drain(); the tests keep the two equal.
const KIT_VERSION = 1;

// ---------------------------------------------------------------------------------------------
// In-page half. Must stay self-contained: it is serialised with toString() and run in the page.
// ---------------------------------------------------------------------------------------------

function installProbe(win, cfg) {
	"use strict";
	if (win.__gfProbe) return win.__gfProbe;
	const perf = win.performance;
	const C = {
		gl: true, raf: true, longtask: true, loaf: true, marks: true, ctx: true,
		// maxEvents is a budget per kind: a flood of one (4,500 texture uploads in the boot frame) must
		// not starve another (a readback); program builds have a budget of their own.
		evMinMs: 0.3, maxEvents: 6000, maxBuildEvents: 20000, maxFrames: 12000, maxPasses: 96, buildGapMs: 250,
	};
	if (cfg) for (const k of Object.keys(cfg)) C[k] = cfg[k];
	const READ_FBO = 0x8CA8, LINK_STATUS = 0x8B82, COMPILE_STATUS = 0x8B81;
	// Kinds whose every call is kept as an event; the others only when they take >= evMinMs. The
	// per-frame aggregates always hold every call.
	const ALWAYS = {
		readPixels: 1, getBufferSubData: 1, finish: 1, texImage2D: 1, texImage3D: 1,
		compressedTexImage2D: 1, compressedTexImage3D: 1, generateMipmap: 1,
	};
	const UPLOAD = {
		texImage2D: 1, texImage3D: 1, texSubImage2D: 1, texSubImage3D: 1, compressedTexImage2D: 1,
		compressedTexImage3D: 1, compressedTexSubImage2D: 1, compressedTexSubImage3D: 1,
		texStorage: 1, bufferData: 1, bufferSubData: 1,
	};
	const NO_PASS = [0, 0, 0, 0];
	const S = {
		frame: 0, ts: -1, cur: null, bld: null, fbo: 0, fbObj: null, vpx: 0, vpy: 0, vpw: 0, vph: 0, pass: null, dirtyPass: true,
		prog: null, nextFbo: 1, frames: [], events: [], longtasks: [], loaf: [], marks: [],
		droppedFrames: 0, droppedEvents: 0, droppedBy: {}, evN: {}, depth: 0, saved: [], glOn: false, since: perf.now(),
		rafOn: false, ctxOn: false, ctxs: [], obs: [], rafOrig: null, getContextOrig: null,
		// Framebuffer ids live here, not on the page's objects: a frozen handle must still bind. atts: what is
		// attached to each framebuffer, by attachment point.
		fboIds: new WeakMap(), atts: new WeakMap(),
	};

	function newFrame(ts, t0) {
		return {
			i: S.frame++, t: ts, t0: t0, busy: 0, dr: 0, di: 0, fb: 0, pu: 0, ps: 0, up: 0, ub: 0,
			bl: 0, k: {}, passes: [], pov: 0,
			// Builds that began before the last link's status was read (see build()).
			bt: 0,
			// What ran outside any rAF callback after this frame's callbacks (the engine's own
			// start-up, a proxied call from a worker): timed GL ms and draws. A frame is booked all
			// the work between its timestamp and the next one's, so busy leaves this out.
			om: 0, od: 0,
		};
	}
	S.cur = newFrame(-1, perf.now());

	function beginFrame(ts, t0) {
		if (S.bld !== null && t0 - S.bld.last > C.buildGapMs) closeBuild();
		S.frames.push(S.cur);
		if (S.frames.length > C.maxFrames) {
			const drop = S.frames.length - C.maxFrames + 1000;
			S.frames.splice(0, drop);
			S.droppedFrames += drop;
		}
		S.cur = newFrame(ts, t0);
		S.pass = null;
		S.dirtyPass = true;
	}

	// The newest event of a kind that has used its budget is dropped, and counted: the drain reports it. Frames
	// go the other way (the oldest are dropped), so past the caps the two cover different stretches of the
	// window: summarizeWindow() takes the rates of the events over their own stretch (drain() says when the
	// window started).
	function pushEvent(e) {
		const n = S.evN[e.kind] || 0;
		if (n >= (e.kind === "build" ? C.maxBuildEvents : C.maxEvents)) {
			S.droppedEvents++;
			S.droppedBy[e.kind] = (S.droppedBy[e.kind] || 0) + 1;
		} else {
			S.evN[e.kind] = n + 1;
			S.events.push(e);
		}
	}

	function rec(kind, ms, bytes, t0) {
		const f = S.cur;
		let e = f.k[kind];
		if (e === undefined) e = f.k[kind] = [0, 0, 0, 0];
		e[0]++;
		e[1] += ms;
		if (ms > e[2]) e[2] = ms;
		e[3] += bytes;
		if (UPLOAD[kind] === 1) {
			f.up++;
			f.ub += bytes;
		}
		if (S.depth === 0) f.om += ms;
		if (ALWAYS[kind] === 1 || ms >= C.evMinMs) pushEvent({ t: t0, f: f.i, kind: kind, ms: ms, bytes: bytes });
	}

	// A program build is the run of compile, link and query calls the engine makes to get one
	// shader variant ready: it ends with the link-status query and the uniform lookups after it.
	// Its per-frame aggregate lives on the frame it started in, kept up to date as the calls come.
	function build(kind, ms, t0) {
		let b = S.bld;
		if (b !== null) {
			const startsNew = kind === "compile" || kind === "link" || kind === "compileStatus";
			const gap = t0 - b.last > C.buildGapMs;
			// The grouping below fits an engine that finishes one program before it starts the next (compile,
			// status, link, status: Godot's compatibility renderer, whose 4.7.2 web template makes no use of
			// KHR_parallel_shader_compile). A link or a compile while the last link's status is unread means
			// the engine batches (compile all, link all, then ask): the calls and the milliseconds still add up,
			// but a build is then no longer one program. It is counted on the frame (bt) and summarizeWindow()
			// reports the ones after the first drawn frame: the engine's start-up links one program of its own
			// without ever reading its status, which is not batching and is not in the builds that are counted.
			if (!gap && b.linked && !b.done && (kind === "link" || kind === "compile")) S.cur.bt++;
			if (gap || (b.done && startsNew) || (kind === "link" && b.linked)) {
				closeBuild();
				b = null;
			}
		}
		if (b === null) {
			if (kind === "progQuery" || kind === "linkStatus") return;
			const f = S.cur;
			if (f.k.build === undefined) f.k.build = [0, 0, 0, 0];
			f.k.build[0]++;
			b = S.bld = {
				t: t0, f: f.i, agg: f.k.build, ms: 0, compile: 0, link: 0, status: 0, query: 0, n: 0,
				done: false, linked: false, last: t0, off: S.depth === 0,
			};
		}
		b.n++;
		b.ms += ms;
		b.agg[1] += ms;
		if (b.ms > b.agg[2]) b.agg[2] = b.ms;
		// Uniform lookups after the link join the build but do not keep it open: a lone query
		// later in the frame is not part of any shader build.
		if (kind === "progQuery") {
			b.query += ms;
			return;
		}
		b.last = t0 + ms;
		if (kind === "compile" || kind === "compileStatus") b.compile += ms;
		else if (kind === "link") {
			b.link += ms;
			b.linked = true;
		} else {
			b.status += ms;
			b.done = true;
		}
	}

	function closeBuild() {
		const b = S.bld;
		S.bld = null;
		if (b === null) return;
		pushEvent({
			t: b.t, f: b.f, kind: "build", ms: b.ms, bytes: 0, compile: b.compile, link: b.link,
			status: b.status, query: b.query, n: b.n, done: b.done, off: b.off,
		});
	}

	// Bytes a call moves. Emscripten's WebGL2 glue never passes an exactly sized view: it passes its whole
	// heap plus an offset (texImage2D(..., HEAPU8, pixels), bufferData(target, HEAPU8, usage, data, size)),
	// and the byteLength of that heap is hundreds of megabytes. So a pixel upload is sized from its
	// dimensions, format and type, a buffer or compressed upload from its (srcOffset, length) arguments.
	const COMPONENTS = {
		0x1903: 1, 0x8227: 2, 0x1907: 3, 0x1908: 4, 0x1906: 1, 0x1909: 1, 0x190A: 2, 0x1902: 1, 0x84F9: 1,
		0x8D94: 1, 0x8228: 2, 0x8D98: 3, 0x8D99: 4,
	};
	const TYPE_BYTES = { 0x1401: 1, 0x1400: 1, 0x1403: 2, 0x1402: 2, 0x140B: 2, 0x8D61: 2, 0x1405: 4, 0x1404: 4, 0x1406: 4 };
	const PACKED_BYTES = { 0x8363: 2, 0x8033: 2, 0x8034: 2, 0x8368: 4, 0x8C3B: 4, 0x8C3E: 4, 0x84FA: 4, 0x8DAD: 8 };
	// Argument positions [width, height, depth, format, type, data] of the uncompressed uploads (depth -1:
	// none) and of the data argument of the compressed ones.
	const TEX_ARGS = {
		texImage2D: [3, 4, -1, 6, 7, 8], texImage3D: [3, 4, 5, 7, 8, 9],
		texSubImage2D: [4, 5, -1, 6, 7, 8], texSubImage3D: [5, 6, 7, 8, 9, 10],
	};
	const COMPRESSED_ARGS = { compressedTexImage2D: 6, compressedTexImage3D: 7, compressedTexSubImage2D: 7, compressedTexSubImage3D: 9 };
	function pixelBytes(format, type) {
		if (PACKED_BYTES[type] !== undefined) return PACKED_BYTES[type];
		const c = COMPONENTS[format];
		const b = TYPE_BYTES[type];
		return c !== undefined && b !== undefined ? c * b : 0;
	}
	// The part of a view a WebGL2 call reads: length elements (bytes for an ArrayBuffer or DataView) from
	// srcOffset, or the rest of the view when length is 0.
	function viewBytes(a, srcOffset, length) {
		const bpe = a.BYTES_PER_ELEMENT || 1;
		const total = typeof a.byteLength === "number" ? a.byteLength / bpe : 0;
		const n = length > 0 ? length : total - (srcOffset > 0 ? srcOffset : 0);
		return n > 0 ? Math.min(n, total) * bpe : 0;
	}
	// An image, canvas, video, ImageData or ImageBitmap.
	function sourceBytes(a) {
		return typeof a.width === "number" && typeof a.height === "number" ? a.width * a.height * 4 : 0;
	}
	function bytesTex(name) {
		const p = TEX_ARGS[name];
		return function (args) {
			// The short overloads (a TexImageSource right after the type) end in the source.
			const a = args.length > p[5] ? args[p[5]] : args[args.length - 1];
			if (a === null || a === undefined) return 0; // storage only, no data
			if (typeof a === "object" && typeof a.byteLength !== "number") return sourceBytes(a);
			const n = args[p[0]] * args[p[1]] * (p[2] < 0 ? 1 : args[p[2]]) * pixelBytes(args[p[3]], args[p[4]]);
			return n > 0 && isFinite(n) ? n : 0;
		};
	}
	function bytesCompressed(name) {
		const i = COMPRESSED_ARGS[name];
		return function (args) {
			const a = args[i];
			if (a !== null && typeof a === "object") return viewBytes(a, args[i + 1], args[i + 2]);
			return typeof a === "number" ? a : 0; // an imageSize: the data is in the pixel-unpack buffer
		};
	}
	function bytesReadPixels(args) {
		const n = args[2] * args[3] * pixelBytes(args[4], args[5]);
		return n > 0 && isFinite(n) ? n : 0;
	}
	// bufferData(target, size, usage) allocates size bytes; the data overloads read (srcOffset, length).
	function bytesBufferData(args) {
		const a = args[1];
		if (typeof a === "number") return a;
		return a !== null && typeof a === "object" ? viewBytes(a, args[3], args[4]) : 0;
	}
	function bytesBufferSub(args) {
		const a = args[2];
		return a !== null && typeof a === "object" ? viewBytes(a, args[3], args[4]) : 0;
	}

	function timed(kind, orig, bytesOf) {
		const inBuild = kind === "compile" || kind === "link" || kind === "progQuery";
		return function () {
			const t0 = perf.now();
			try {
				return orig.apply(this, arguments);
			} finally {
				const ms = perf.now() - t0;
				rec(kind, ms, bytesOf === null ? 0 : bytesOf(arguments), t0);
				if (inBuild) build(kind, ms, t0);
			}
		};
	}
	function statusQuery(orig, pname, hitKind) {
		return function (obj, p) {
			const t0 = perf.now();
			try {
				return orig.apply(this, arguments);
			} finally {
				const ms = perf.now() - t0;
				const kind = p === pname ? hitKind : "progQuery";
				rec(kind, ms, 0, t0);
				build(kind, ms, t0);
			}
		};
	}
	function counted(orig, instanced) {
		return function () {
			const f = S.cur;
			f.dr++;
			if (S.depth === 0) f.od++;
			if (instanced) f.di++;
			if (S.dirtyPass) {
				S.dirtyPass = false;
				if (f.passes.length >= C.maxPasses) {
					f.pov++;
					S.pass = NO_PASS;
				} else {
					S.pass = [S.fbo, S.vpw, S.vph, 0];
					f.passes.push(S.pass);
				}
			}
			S.pass[3]++;
			return orig.apply(this, arguments);
		};
	}

	// Changing what is attached to the bound draw framebuffer starts a new pass: the faces of a cube map, the
	// mip levels and the layers of an array are rendered through one framebuffer at one viewport size.
	// Re-attaching what is already there changes nothing. objAt: the position of the texture or renderbuffer
	// in the call; extraOf: the rest that tells two attachments apart (target, level, layer).
	function attachment(orig, objAt, extraOf) {
		return function (target, point) {
			const fbo = S.fbObj;
			if (target !== READ_FBO && fbo !== null) {
				const obj = arguments[objAt];
				const extra = extraOf(arguments);
				let m = S.atts.get(fbo);
				if (m === undefined) {
					m = {};
					S.atts.set(fbo, m);
				}
				const old = m[point];
				if (old === undefined || old.o !== obj || old.x !== extra) {
					m[point] = { o: obj, x: extra };
					S.dirtyPass = true;
				}
			}
			return orig.apply(this, arguments);
		};
	}

	// method -> wrapper factory; each gets the original function.
	const TABLE = {
		drawArrays: (o) => counted(o, false),
		drawElements: (o) => counted(o, false),
		drawRangeElements: (o) => counted(o, false),
		drawArraysInstanced: (o) => counted(o, true),
		drawElementsInstanced: (o) => counted(o, true),
		bindFramebuffer: (o) => function (target, fb) {
			S.cur.fb++;
			if (target !== READ_FBO) {
				let id = 0;
				if (typeof fb === "object" && fb !== null) {
					id = S.fboIds.get(fb);
					if (id === undefined) {
						id = S.nextFbo++;
						S.fboIds.set(fb, id);
					}
				} else if (fb !== null && fb !== undefined) {
					id = S.fbo; // not a handle: the native call rejects it, nothing changed
				}
				if (id !== S.fbo) {
					S.fbo = id;
					S.fbObj = id === 0 ? null : fb;
					S.dirtyPass = true;
				}
			}
			return o.apply(this, arguments);
		},
		viewport: (o) => function (x, y, w, h) {
			// The origin counts too: the quadrants of an atlas are one size.
			if (w !== S.vpw || h !== S.vph || x !== S.vpx || y !== S.vpy) {
				S.vpx = x;
				S.vpy = y;
				S.vpw = w;
				S.vph = h;
				S.dirtyPass = true;
			}
			return o.apply(this, arguments);
		},
		framebufferTexture2D: (o) => attachment(o, 3, (a) => a[2] + ":" + a[4]),
		framebufferTextureLayer: (o) => attachment(o, 2, (a) => a[3] + ":" + a[4]),
		framebufferRenderbuffer: (o) => attachment(o, 3, () => "rb"),
		blitFramebuffer: (o) => function () {
			S.cur.bl++;
			return o.apply(this, arguments);
		},
		useProgram: (o) => function (p) {
			const f = S.cur;
			f.pu++;
			if (p !== S.prog) {
				S.prog = p;
				f.ps++;
			}
			const t0 = perf.now();
			try {
				return o.apply(this, arguments);
			} finally {
				rec("useProgram", perf.now() - t0, 0, t0);
			}
		},
		linkProgram: (o) => timed("link", o, null),
		compileShader: (o) => timed("compile", o, null),
		getProgramParameter: (o) => statusQuery(o, LINK_STATUS, "linkStatus"),
		getShaderParameter: (o) => statusQuery(o, COMPILE_STATUS, "compileStatus"),
		getProgramInfoLog: (o) => timed("progQuery", o, null),
		getShaderInfoLog: (o) => timed("progQuery", o, null),
		getUniformLocation: (o) => timed("progQuery", o, null),
		getAttribLocation: (o) => timed("progQuery", o, null),
		getUniformBlockIndex: (o) => timed("progQuery", o, null),
		getActiveUniform: (o) => timed("progQuery", o, null),
		getActiveUniforms: (o) => timed("progQuery", o, null),
		getActiveAttrib: (o) => timed("progQuery", o, null),
		getFragDataLocation: (o) => timed("progQuery", o, null),
		texImage2D: (o) => timed("texImage2D", o, bytesTex("texImage2D")),
		texImage3D: (o) => timed("texImage3D", o, bytesTex("texImage3D")),
		texSubImage2D: (o) => timed("texSubImage2D", o, bytesTex("texSubImage2D")),
		texSubImage3D: (o) => timed("texSubImage3D", o, bytesTex("texSubImage3D")),
		compressedTexImage2D: (o) => timed("compressedTexImage2D", o, bytesCompressed("compressedTexImage2D")),
		compressedTexImage3D: (o) => timed("compressedTexImage3D", o, bytesCompressed("compressedTexImage3D")),
		compressedTexSubImage2D: (o) => timed("compressedTexSubImage2D", o, bytesCompressed("compressedTexSubImage2D")),
		compressedTexSubImage3D: (o) => timed("compressedTexSubImage3D", o, bytesCompressed("compressedTexSubImage3D")),
		texStorage2D: (o) => timed("texStorage", o, null),
		texStorage3D: (o) => timed("texStorage", o, null),
		generateMipmap: (o) => timed("generateMipmap", o, null),
		bufferData: (o) => timed("bufferData", o, bytesBufferData),
		bufferSubData: (o) => timed("bufferSubData", o, bytesBufferSub),
		readPixels: (o) => timed("readPixels", o, bytesReadPixels),
		getBufferSubData: (o) => timed("getBufferSubData", o, bytesBufferSub),
		finish: (o) => timed("finish", o, null),
		getError: (o) => timed("getError", o, null),
	};

	function installGl() {
		if (S.glOn) return;
		for (const name of ["WebGL2RenderingContext", "WebGLRenderingContext"]) {
			const Ctor = win[name];
			const proto = Ctor && Ctor.prototype;
			if (!proto) continue;
			for (const m of Object.keys(TABLE)) {
				const orig = proto[m];
				if (typeof orig !== "function") continue;
				const wrapped = TABLE[m](orig);
				S.saved.push([proto, m, orig, wrapped]);
				proto[m] = wrapped;
			}
		}
		S.glOn = true;
	}
	function uninstallGl() {
		for (const s of S.saved) {
			// A page that wrapped the method after us keeps its wrapper; only undo our own.
			if (s[0][s[1]] === s[3]) s[0][s[1]] = s[2];
		}
		S.saved = [];
		S.glOn = false;
	}

	function installRaf() {
		if (S.rafOn || typeof win.requestAnimationFrame !== "function") return;
		const orig = win.requestAnimationFrame;
		S.rafOrig = orig;
		win.requestAnimationFrame = function (cb) {
			if (typeof cb !== "function") return orig.call(win, cb);
			return orig.call(win, function (ts) {
				const t0 = perf.now();
				if (ts !== S.ts) {
					S.ts = ts;
					beginFrame(ts, t0);
				}
				S.depth++;
				try {
					return cb.apply(this, arguments);
				} finally {
					S.depth--;
					S.cur.busy += perf.now() - t0;
				}
			});
		};
		S.rafWrapped = win.requestAnimationFrame;
		S.rafOn = true;
	}
	function uninstallRaf() {
		if (S.rafOn && win.requestAnimationFrame === S.rafWrapped) win.requestAnimationFrame = S.rafOrig;
		S.rafOn = false;
	}

	// The game's own canvas is the first connected one that asks for WebGL; the probe's renderer
	// check makes a detached canvas, which this skips.
	function installCtx() {
		const Cv = win.HTMLCanvasElement;
		if (S.ctxOn || !Cv || !Cv.prototype || typeof Cv.prototype.getContext !== "function") return;
		const orig = Cv.prototype.getContext;
		S.getContextOrig = orig;
		S.getContextWrapped = Cv.prototype.getContext = function (type) {
			const c = orig.apply(this, arguments);
			if (c && /webgl/.test(String(type)) && this.isConnected && S.ctxs.indexOf(c) < 0 && S.ctxs.length < 4) S.ctxs.push(c);
			return c;
		};
		S.ctxOn = true;
	}
	function uninstallCtx() {
		const Cv = win.HTMLCanvasElement;
		if (S.ctxOn && Cv.prototype.getContext === S.getContextWrapped) Cv.prototype.getContext = S.getContextOrig;
		S.ctxOn = false;
	}

	function observe(type, onEntry) {
		try {
			const PO = win.PerformanceObserver;
			if (!PO || (PO.supportedEntryTypes || []).indexOf(type) < 0) return false;
			const po = new PO(function (list) {
				for (const e of list.getEntries()) onEntry(e);
			});
			po.observe({ type: type, buffered: true });
			S.obs.push({ po: po, cb: onEntry });
			return true;
		} catch (err) {
			return false;
		}
	}

	const seen = {
		longtask: C.longtask && observe("longtask", function (e) {
			S.longtasks.push({ t: e.startTime, dur: e.duration });
		}),
		loaf: C.loaf && observe("long-animation-frame", function (e) {
			S.loaf.push({
				t: e.startTime, dur: e.duration, block: e.blockingDuration || 0,
				rs: e.renderStart ? e.renderStart - e.startTime : null,
			});
		}),
		marks: C.marks && observe("mark", function (e) {
			// The probe's own marks are pushed directly (below); the game's start with "gf:".
			if (e.name.indexOf("gf:") === 0 && e.name.indexOf("gf:probe:") !== 0) S.marks.push({ t: e.startTime, name: e.name, detail: e.detail === undefined ? null : e.detail });
		}),
	};

	const api = {
		v: 1,
		cfg: C,
		seen: seen,
		glOn: function () { return S.glOn; },
		setGl: function (on) {
			if (on) installGl();
			else uninstallGl();
			return S.glOn;
		},
		uninstall: function () {
			uninstallGl();
			uninstallRaf();
			uninstallCtx();
			for (const o of S.obs) o.po.disconnect();
			S.obs = [];
			delete win.__gfProbe;
		},
		mark: function (name, detail) {
			const full = "gf:probe:" + name;
			try { perf.mark(full, { detail: detail === undefined ? null : detail }); } catch (err) { /* no User Timing */ }
			S.marks.push({ t: perf.now(), name: full, detail: detail === undefined ? null : detail });
		},
		// Everything recorded since the last drain, then forgets it. The frame in progress stays.
		drain: function () {
			for (const o of S.obs) {
				try { for (const e of o.po.takeRecords()) o.cb(e); } catch (err) { /* observer gone */ }
			}
			if (S.bld !== null && perf.now() - S.bld.last > C.buildGapMs) closeBuild();
			const out = {
				v: 1, now: perf.now(), frames: S.frames, events: S.events,
				longtasks: S.longtasks, loaf: S.loaf, marks: S.marks, droppedFrames: S.droppedFrames,
				droppedEvents: S.droppedEvents, droppedBy: S.droppedBy, glOn: S.glOn, frame: S.cur.i, since: S.since,
			};
			S.since = out.now;
			S.frames = [];
			S.events = [];
			S.longtasks = [];
			S.loaf = [];
			S.marks = [];
			S.droppedFrames = 0;
			S.droppedEvents = 0;
			S.droppedBy = {};
			S.evN = {};
			return out;
		},
		info: function () {
			const c = S.ctxs[0] || null;
			const cv = c ? c.canvas : null;
			let attrs = null;
			try { attrs = c && c.getContextAttributes ? c.getContextAttributes() : null; } catch (err) { /* lost */ }
			return {
				dpr: win.devicePixelRatio, inner: [win.innerWidth, win.innerHeight],
				coi: !!win.crossOriginIsolated, sab: typeof win.SharedArrayBuffer !== "undefined",
				// A top-level const of the Godot loader page: a global binding, not a window property.
				threads: typeof GODOT_THREADS_ENABLED !== "undefined" ? GODOT_THREADS_ENABLED : null,
				canvas: cv ? { w: cv.width, h: cv.height, cw: cv.clientWidth, ch: cv.clientHeight } : null,
				drawing: c ? [c.drawingBufferWidth, c.drawingBufferHeight] : null,
				attrs: attrs, contexts: S.ctxs.length, ua: win.navigator ? win.navigator.userAgent : "",
			};
		},
	};
	win.__gfProbe = api;
	if (C.ctx) installCtx();
	if (C.raf) installRaf();
	if (C.gl) installGl();
	return api;
}
// The text of an init script that installs the kit (page.addInitScript({ content })).
function installSource(cfg) {
	return "(" + installProbe.toString() + ")(window, " + JSON.stringify(cfg || {}) + ");";
}

// Runs in the page: rAF timestamps for ms milliseconds, as intervals. Used for the display rate
// on a quiet page before the game boots.
function hzSampler(ms) {
	return new Promise(function (resolve) {
		const times = [];
		const end = performance.now() + ms;
		const tick = function (t) {
			times.push(t);
			if (t < end) requestAnimationFrame(tick);
			else {
				const d = [];
				for (let i = 1; i < times.length; i++) d.push(times[i] - times[i - 1]);
				resolve(d);
			}
		};
		requestAnimationFrame(tick);
	});
}

// ---------------------------------------------------------------------------------------------
// Env knobs
// ---------------------------------------------------------------------------------------------

function blank(spec) {
	return spec === undefined || spec === null || String(spec).trim() === "";
}

function parseViewport(spec, fallback) {
	if (blank(spec)) return fallback;
	const m = /^\s*(\d{2,5})\s*[xX]\s*(\d{2,5})\s*$/.exec(String(spec));
	if (!m) throw new Error(`GF_FPS_VIEWPORT must look like 1920x1080, got "${spec}"`);
	const width = Number(m[1]);
	const height = Number(m[2]);
	if (width < 160 || height < 120 || width > 7680 || height > 4320) {
		throw new Error(`GF_FPS_VIEWPORT ${width}x${height} is outside 160x120 .. 7680x4320`);
	}
	return { width, height };
}

function parseNumber(spec, fallback, lo, hi, name) {
	if (blank(spec)) return fallback;
	const v = Number(spec);
	if (!Number.isFinite(v) || v < lo || v > hi) throw new Error(`${name} must be a number in ${lo}..${hi}, got "${spec}"`);
	return v;
}

function parseDpr(spec, fallback) {
	return parseNumber(spec, fallback, 0.25, 4, "GF_FPS_DPR");
}

function parseBool(spec, fallback, name) {
	if (blank(spec)) return fallback;
	const v = String(spec).trim().toLowerCase();
	if (["1", "true", "on", "yes"].includes(v)) return true;
	if (["0", "false", "off", "no"].includes(v)) return false;
	throw new Error(`${name || "a switch"} must be 0 or 1, got "${spec}"`);
}

// Edit distance, for "did you mean" on a mistyped knob or flag.
function distance(a, b) {
	let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
	for (let i = 1; i <= a.length; i++) {
		const row = [i];
		for (let j = 1; j <= b.length; j++) row[j] = Math.min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
		prev = row;
	}
	return prev[b.length];
}

function closest(name, list, n) {
	return list.slice().sort((x, y) => distance(name, x) - distance(name, y)).slice(0, n);
}

// GF_FPS_FLAGS="a=1,b=0": feature flags the probe writes to user://feature_flags.json before the engine boots
// (the web build has no environment to read them from). "none" writes an empty file, so a reused profile
// loses the flags an earlier run left in it. known: the names in data/feature_flags.json (null: unchecked);
// a name the game does not define would be ignored without a word.
const DEFAULT_FLAGS = { web_first_use_marks: true };

function parseFlags(spec, known) {
	if (blank(spec)) return Object.assign({}, DEFAULT_FLAGS);
	if (String(spec).trim() === "none") return {};
	const out = {};
	for (const item of String(spec).split(",")) {
		const entry = item.trim();
		if (entry === "") continue;
		const m = /^([a-z][a-z0-9_]*)\s*=\s*(0|1|true|false|on|off)$/i.exec(entry);
		if (!m) throw new Error(`GF_FPS_FLAGS entry "${entry}" must look like name=1 or name=0`);
		if (Array.isArray(known) && !known.includes(m[1])) {
			throw new Error(`GF_FPS_FLAGS names a flag data/feature_flags.json does not define: "${m[1]}" (closest: ${closest(m[1], known, 3).join(", ")})`);
		}
		out[m[1]] = ["1", "true", "on"].includes(m[2].toLowerCase());
	}
	return out;
}

const ROWS = ["street", "walk", "sky", "orbit"];

function parseRows(spec, fallback) {
	if (blank(spec)) return fallback;
	const rows = String(spec).split(",").map((s) => s.trim()).filter(Boolean);
	if (rows.length === 0) throw new Error(`GF_FPS_ROWS "${spec}" names no row (${ROWS.join(", ")})`);
	for (const r of rows) {
		if (!ROWS.includes(r)) throw new Error(`GF_FPS_ROWS entry "${r}" is not one of ${ROWS.join(", ")}`);
	}
	return ROWS.filter((r) => rows.includes(r));
}

const KNOB_NAMES = [
	"VIEWPORT", "DPR", "KIT", "GLHOOK", "HEADLESS", "CHROME", "CHROME_ARGS", "USER_DATA_DIR", "SETTLE_S",
	"WINDOW_S", "AB", "MEMORY", "RAW", "ROWS", "FLAGS", "SAVE",
].map((n) => "GF_FPS_" + n);

// env: process.env (or a test's table). knownFlags: the flag names of data/feature_flags.json, or null. Every
// problem throws: a knob that is mistyped, misspelled or contradicts another would otherwise leave the
// run measuring something other than what was asked.
function parseKnobs(env, knownFlags) {
	for (const k of Object.keys(env)) {
		if (k.indexOf("GF_FPS_") === 0 && !KNOB_NAMES.includes(k)) {
			throw new Error(`${k} is not a probe knob (closest: ${closest(k, KNOB_NAMES, 2).join(", ")})`);
		}
	}
	const knobs = {
		viewport: parseViewport(env.GF_FPS_VIEWPORT, { width: 1600, height: 900 }),
		dpr: parseDpr(env.GF_FPS_DPR, 1),
		kit: parseBool(env.GF_FPS_KIT, true, "GF_FPS_KIT"),
		glHook: parseBool(env.GF_FPS_GLHOOK, true, "GF_FPS_GLHOOK"),
		headless: parseBool(env.GF_FPS_HEADLESS, false, "GF_FPS_HEADLESS"),
		chrome: blank(env.GF_FPS_CHROME) ? "/usr/bin/google-chrome" : String(env.GF_FPS_CHROME),
		chromeArgs: blank(env.GF_FPS_CHROME_ARGS) ? [] : String(env.GF_FPS_CHROME_ARGS).trim().split(/\s+/),
		// Absolute: Chrome's command line carries the resolved path, and the memory readings find the
		// browser's process tree by it.
		profile: blank(env.GF_FPS_USER_DATA_DIR) ? "" : path.resolve(String(env.GF_FPS_USER_DATA_DIR)),
		settleS: parseNumber(env.GF_FPS_SETTLE_S, 30, 0, 900, "GF_FPS_SETTLE_S"),
		windowS: parseNumber(env.GF_FPS_WINDOW_S, 20, 1, 600, "GF_FPS_WINDOW_S"),
		abS: parseNumber(env.GF_FPS_AB, 0, 0, 120, "GF_FPS_AB"),
		memory: parseBool(env.GF_FPS_MEMORY, true, "GF_FPS_MEMORY"),
		raw: parseBool(env.GF_FPS_RAW, false, "GF_FPS_RAW"),
		rows: parseRows(env.GF_FPS_ROWS, ROWS.slice()),
		flags: parseFlags(env.GF_FPS_FLAGS, knownFlags),
		save: blank(env.GF_FPS_SAVE) ? "" : String(env.GF_FPS_SAVE),
	};
	if (knobs.abS > 0 && (!knobs.kit || !knobs.glHook)) {
		throw new Error("GF_FPS_AB compares the WebGL hook on and off: it needs GF_FPS_KIT and GF_FPS_GLHOOK left on");
	}
	return knobs;
}

// ---------------------------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------------------------

const r1 = (v) => Math.round(v * 10) / 10;
const r2 = (v) => Math.round(v * 100) / 100;
const r3 = (v) => Math.round(v * 1000) / 1000;

// The probe's convention (tools/web_fps_probe.js before the kit): sorted[floor(n * p)].
function percentile(sorted, p) {
	if (sorted.length === 0) return null;
	return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))];
}

function stats(values) {
	const v = values.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
	if (v.length === 0) return { n: 0, mean: null, min: null, p50: null, p95: null, p99: null, max: null };
	let sum = 0;
	for (const x of v) sum += x;
	return {
		n: v.length, mean: r3(sum / v.length), min: r3(v[0]), p50: r3(percentile(v, 0.5)),
		p95: r3(percentile(v, 0.95)), p99: r3(percentile(v, 0.99)), max: r3(v[v.length - 1]),
	};
}

const NOMINAL_HZ = [24, 25, 30, 48, 50, 60, 72, 75, 90, 100, 120, 144, 165, 180, 240, 360];

// Display rate from quiet rAF intervals. The minimum is reported, but a lone double-callback can
// make it far too short, so the rate comes from the 2nd percentile.
function displayHz(intervals) {
	const v = intervals.filter((x) => x > 0.5 && x < 1000).sort((a, b) => a - b);
	if (v.length < 10) return { n: v.length, min_ms: null, p02_ms: null, median_ms: null, hz: null, nominal: null };
	const p02 = v[Math.floor(v.length * 0.02)];
	const hz = 1000 / p02;
	let nominal = null;
	for (const n of NOMINAL_HZ) {
		if (Math.abs(hz - n) / n < 0.04) nominal = n;
	}
	return {
		n: v.length, min_ms: r3(v[0]), p02_ms: r3(p02), median_ms: r3(percentile(v, 0.5)), hz: r1(hz), nominal,
	};
}

function groupEvents(events) {
	const by = {};
	for (const e of events) (by[e.kind] || (by[e.kind] = [])).push(e);
	return by;
}

// The frame of the window nearest the median draw count, as {"WxH": {passes, draws}}: what the
// frame is made of (shadow atlas, main pass, glow chain, sky radiance) when RENDER_TOTAL_DRAW_
// CALLS_IN_FRAME counts only the scene's own draws.
function passTable(frames) {
	const drawn = frames.filter((f) => f.dr > 0);
	if (drawn.length === 0) return null;
	const sorted = drawn.slice().sort((a, b) => a.dr - b.dr);
	const rep = sorted[Math.floor(sorted.length / 2)];
	const out = { frame: rep.i, draws: rep.dr, passes: rep.passes.length, by_size: {} };
	for (const p of rep.passes) {
		const key = p[0] === 0 ? "canvas" : "fbo";
		const size = `${p[1]}x${p[2]}`;
		const k = `${key} ${size}`;
		const e = out.by_size[k] || (out.by_size[k] = { passes: 0, draws: 0 });
		e.passes++;
		e.draws += p[3];
	}
	if (rep.pov > 0) out.overflow = rep.pov;
	return out;
}

// Frames that ran long, each with what the timed GL calls cost in it and what is left over
// (script, physics, everything the wrapper cannot see). A row is one frame and says what that frame
// cost the page: its own busy time, GL and builds (the work that ran between its timestamp and the next
// frame's) and interval_ms, the time from its timestamp to the NEXT frame's. A callback that runs long
// delays the timestamp of the frame after it, never its own, so the interval has to be read on the
// frame that caused it: pairing it with the frame that merely arrived late leaves the cause off the row.
// interval_ms is null for the last frame of a window (its successor is in the next window). Its gap
// to busy_ms tells main-thread work (the two match) from waiting on the GPU or the vsync (interval
// far above busy).
function attributeHitches(frames, longtasks, marks, opts) {
	const o = Object.assign({ thresholdMs: 0, top: 8 }, opts);
	const ints = [];
	for (let k = 1; k < frames.length; k++) {
		if (frames[k - 1].i + 1 === frames[k].i && frames[k].t >= 0 && frames[k - 1].t >= 0) ints.push(frames[k].t - frames[k - 1].t);
	}
	ints.sort((a, b) => a - b);
	const med = percentile(ints, 0.5) || 0;
	const threshold = o.thresholdMs > 0 ? o.thresholdMs : Math.max(2 * med, 33.3);
	const rows = [];
	for (let k = 0; k < frames.length; k++) {
		const f = frames[k];
		if (f.t < 0) continue;
		const next = k + 1 < frames.length && frames[k + 1].i === f.i + 1 && frames[k + 1].t >= 0 ? frames[k + 1] : null;
		const interval = next !== null ? next.t - f.t : null;
		if ((interval === null || interval < threshold) && f.busy < threshold) continue;
		let gl = 0;
		const kinds = [];
		for (const kind of Object.keys(f.k)) {
			if (kind === "build") continue;
			gl += f.k[kind][1];
			kinds.push([kind, r2(f.k[kind][1]), f.k[kind][0]]);
		}
		// Timed GL that ran outside this frame's callbacks (booked to it, after them) is not part of
		// its busy time but is part of its interval: off_ms.
		const off = f.om || 0;
		gl = Math.max(0, gl - off);
		kinds.sort((a, b) => b[1] - a[1]);
		// The frame's span: from its timestamp to the later of its callbacks' end and the next timestamp
		// (a timestamp is a vsync time and can precede the end of a long callback).
		const end = Math.max(f.t0 + f.busy, next !== null ? next.t : 0);
		const near = marks.filter((m) => m.t >= f.t && m.t <= end).map((m) => m.name);
		const lt = longtasks.filter((l) => l.t < end && l.t + l.dur > f.t0).map((l) => r1(l.dur));
		rows.push({
			frame: f.i, t: r1(f.t), interval_ms: interval === null ? null : r1(interval), busy_ms: r2(f.busy), gl_ms: r2(gl),
			other_ms: r2(Math.max(0, f.busy - gl)), off_ms: r2(off), build_ms: f.k.build ? r2(f.k.build[1]) : 0,
			top: kinds.slice(0, 3), draws: f.dr, marks: near.slice(0, 4), longtask_ms: lt,
		});
	}
	const cost = (r) => Math.max(r.interval_ms === null ? 0 : r.interval_ms, r.busy_ms);
	rows.sort((a, b) => cost(b) - cost(a));
	return { threshold_ms: r1(threshold), n: rows.length, worst: rows.slice(0, o.top) };
}

// Builds after the first drawn frame, as programs (n, ge_100, ge_150 count single links, as long as the engine
// finishes one program before the next: builds.batched says when it did not) and as events:
// the frame is what stalls, whatever number of programs it linked, so an event is a frame that held
// builds and costs the sum of them. Backlog item 10's rule counts events.
// A build made outside a rAF callback is booked to the frame whose callbacks ended before it: it comes after
// that frame (the first drawn one included), not inside it.
function buildsAfter(builds, firstDrawFrame) {
	const list = firstDrawFrame === null ? [] : builds.filter((b) => b.f > firstDrawFrame || (b.off === true && b.f >= firstDrawFrame));
	const ms = list.map((b) => b.ms);
	let total = 0;
	for (const x of ms) total += x;
	const perFrame = {};
	for (const b of list) perFrame[b.f] = (perFrame[b.f] || 0) + b.ms;
	const ev = Object.keys(perFrame).map((k) => perFrame[k]);
	return {
		n: list.length, total_ms: r2(total), max_ms: r2(ms.length ? Math.max(...ms) : 0),
		ge_100: ms.filter((x) => x >= 100).length, ge_150: ms.filter((x) => x >= 150).length,
		events: ev.length, event_max_ms: r2(ev.length ? Math.max(...ev) : 0),
		events_ge_100: ev.filter((x) => x >= 100).length, events_ge_150: ev.filter((x) => x >= 150).length,
	};
}

// d is what drain() returned. opts.firstDrawFrame is the first frame that drew anything in the
// run so far (null before the first draw; this window's own when it holds it).
function summarizeWindow(d, opts) {
	const o = Object.assign({ firstDrawFrame: null, hitchMs: 0, hitchTop: 8 }, opts);
	const fr = d.frames;
	const ints = [];
	const busy = [];
	const late = [];
	let first = o.firstDrawFrame;
	for (let k = 0; k < fr.length; k++) {
		const f = fr[k];
		busy.push(f.busy);
		if (f.t >= 0 && f.t0 >= f.t) late.push(f.t0 - f.t);
		if (k > 0 && fr[k - 1].i + 1 === f.i && f.t >= 0 && fr[k - 1].t >= 0) ints.push(f.t - fr[k - 1].t);
		// The engine's start-up draws outside any callback: the first drawn frame is a real one.
		if (first === null && f.dr - (f.od || 0) > 0 && f.i > 0) first = f.i;
	}
	// The boot frame (before the first rAF) has no timestamp; rates come from the timed frames.
	const timed = fr.filter((f) => f.t >= 0);
	const span = timed.length > 1 ? (timed[timed.length - 1].t - timed[0].t) / 1000 : 0;
	const col = (key) => fr.map((f) => f[key]);
	const out = {
		frames: fr.length, secs: r3(span), fps: span > 0 ? r2((timed.length - 1) / span) : 0,
		interval_ms: stats(ints), busy_ms: stats(busy), late_ms: stats(late),
		first_draw_frame: first, gl_on: d.glOn,
		census: {
			draws: stats(col("dr")), instanced: stats(col("di")), fbo_binds: stats(col("fb")),
			passes: stats(fr.map((f) => f.passes.length)), program_switches: stats(col("ps")),
			use_program: stats(col("pu")), uploads: stats(col("up")), upload_bytes: stats(col("ub")),
			blits: stats(col("bl")),
		},
		pass_table: passTable(fr),
	};
	const kinds = {};
	for (const f of fr) {
		for (const kind of Object.keys(f.k)) {
			const e = f.k[kind];
			const a = kinds[kind] || (kinds[kind] = { n: 0, ms: 0, max_ms: 0, bytes: 0, frames: 0 });
			a.n += e[0];
			a.ms += e[1];
			if (e[2] > a.max_ms) a.max_ms = e[2];
			a.bytes += e[3];
			a.frames++;
		}
	}
	for (const kind of Object.keys(kinds)) {
		const a = kinds[kind];
		a.ms = r2(a.ms);
		a.max_ms = r2(a.max_ms);
		a.per_s = span > 0 ? r2(a.n / span) : null;
	}
	out.gl_kinds = kinds;
	const by = groupEvents(d.events);
	const builds = by.build || [];
	out.builds = Object.assign(buildsAfter(builds, first), {
		all: builds.length, batched: first === null ? 0 : fr.reduce((x, f) => (f.i > first ? x + (f.bt || 0) : x), 0),
		top: builds.slice().sort((a, b) => b.ms - a.ms).slice(0, 8).map((b) => ({
			t: r1(b.t), f: b.f, ms: r2(b.ms), compile: r2(b.compile), link: r2(b.link), status: r2(b.status), query: r2(b.query),
		})),
	});
	// The rate of a kind's events is over the stretch they cover. That is the span of the frames, unless frames
	// were dropped (the oldest go; the events are not trimmed with them): then the events cover the whole window,
	// since the previous drain. A kind whose budget ran out stops at the last event it kept (the newest are
	// dropped), so its stretch ends there. gl_kinds (the frames' own aggregates) has the rate of every call.
	const wholeWindow = d.droppedFrames > 0 && Number.isFinite(d.since) && Number.isFinite(d.now);
	const evFrom = wholeWindow ? d.since : timed.length > 0 ? timed[0].t : 0;
	const evTo = wholeWindow ? d.now : timed.length > 0 ? timed[timed.length - 1].t : 0;
	const ev = {};
	for (const kind of Object.keys(by)) {
		if (kind === "build") continue;
		const ms = by[kind].map((e) => e.ms);
		const ranOut = d.droppedBy && d.droppedBy[kind] > 0;
		const to = ranOut ? by[kind].reduce((m, e) => Math.max(m, e.t), evFrom) : evTo;
		const sec = (to - evFrom) / 1000;
		ev[kind] = Object.assign(stats(ms), { per_s: sec > 0 ? r2(ms.length / sec) : null });
	}
	out.events = ev;
	// Work outside every rAF callback: the busy time above cannot see it, the long tasks and the next
	// interval can. The builds counted here are all of them, boot included.
	out.off_raf = {
		gl_ms: r2(fr.reduce((x, f) => x + (f.om || 0), 0)), draws: fr.reduce((x, f) => x + (f.od || 0), 0),
		builds: builds.filter((b) => b.off === true).length,
		build_ms: r2(builds.filter((b) => b.off === true).reduce((x, b) => x + b.ms, 0)),
	};
	out.longtasks = {
		n: d.longtasks.length, total_ms: r1(d.longtasks.reduce((s, l) => s + l.dur, 0)),
		max_ms: r1(d.longtasks.reduce((m, l) => Math.max(m, l.dur), 0)), ge_100: d.longtasks.filter((l) => l.dur >= 100).length,
	};
	out.loaf = {
		n: d.loaf.length, blocking_ms: r1(d.loaf.reduce((s, l) => s + l.block, 0)),
		max_ms: r1(d.loaf.reduce((m, l) => Math.max(m, l.dur), 0)),
	};
	out.marks = d.marks.map((m) => ({ t: r1(m.t), name: m.name, detail: m.detail }));
	out.hitches = attributeHitches(fr, d.longtasks, d.marks, { thresholdMs: o.hitchMs, top: o.hitchTop });
	if (d.droppedFrames || d.droppedEvents) {
		out.dropped = { frames: d.droppedFrames || 0, events: d.droppedEvents || 0, by_kind: Object.assign({}, d.droppedBy) };
	}
	return out;
}

// The game's console lines (scripts/ops/first_use.gd): FIRSTUSE {"tag":"play:rain.ogg","n":1,"ms":2.31,"len":30.0}
function parseFirstUse(lines) {
	const out = [];
	for (const line of lines) {
		const m = /FIRSTUSE (\{.*\})\s*$/.exec(String(line));
		if (!m) continue;
		try {
			const rec = JSON.parse(m[1]);
			if (rec && typeof rec.tag === "string") out.push(rec);
		} catch (err) {
			// a truncated console line is not a record
		}
	}
	return out;
}

// Streams this long are the beds and loops that item 15's rule is about.
const LONG_STREAM_S = 5;

// Marks by tag (how often seen), stopwatch readings by tag (the first one is the cold one) and,
// for streams, the first play() put per second of audio: what backlog item 15 asks for.
function summarizeFirstUse(recs) {
	const marks = {};
	const watches = {};
	for (const r of recs) {
		if (typeof r.ms !== "number") {
			const m = marks[r.tag] || (marks[r.tag] = { n: 0 });
			m.n = Math.max(m.n, r.n || 1);
			continue;
		}
		const w = watches[r.tag] || (watches[r.tag] = { n: 0, first_ms: r.ms, max_ms: 0, len_s: null, ms_per_s: null, order: Object.keys(watches).length });
		w.n = Math.max(w.n, r.n || 1);
		w.max_ms = r3(Math.max(w.max_ms, r.ms));
		if (typeof r.len === "number" && r.len > 0 && w.len_s === null) {
			w.len_s = r.len;
			w.ms_per_s = r3(w.first_ms / r.len);
		}
	}
	const streams = Object.keys(watches).filter((t) => watches[t].len_s !== null)
		.map((t) => Object.assign({ tag: t }, watches[t])).sort((a, b) => b.ms_per_s - a.ms_per_s);
	// Item 15's rule is about the beds: a short stream's fixed cost per play() inflates its ms per second, so
	// only streams of LONG_STREAM_S or more decide the leaning (the rate of every stream stays in `streams`).
	// The first long stream of a session also pays a one-off first-play cost: a scratch export of the web template
	// read 10 to 20 ms more for the first 20 s stream than for the next ones (zero-filled WAVs, not the game's
	// Ogg, not re-measured on the game). So with two long streams or more the first is left out of the rate.
	const long = streams.filter((x) => x.len_s >= LONG_STREAM_S);
	const inOrder = long.slice().sort((a, b) => a.order - b.order);
	const counted = inOrder.length >= 2 ? inOrder.slice(1) : inOrder;
	const worst = counted.reduce((m, x) => Math.max(m, x.ms_per_s), 0);
	const longest = streams.reduce((m, x) => Math.max(m, x.len_s), 0);
	let leaning = "not triggered";
	if (long.length === 0) leaning = `no stream of ${LONG_STREAM_S} s or more seen`;
	else if (worst >= 3 && worst * 30 >= 100) leaning = "build";
	return {
		marks, watches, streams: streams.slice(0, 12),
		item15_stream: {
			streams: streams.length, long_streams: long.length, max_ms_per_s: worst,
			max_ms_per_s_any: streams.length ? streams[0].ms_per_s : 0, longest_len_s: longest,
			cost_of_a_30s_bed_ms: r1(worst * 30), leaning,
			first_long_stream: inOrder.length ? { tag: inOrder[0].tag, ms_per_s: inOrder[0].ms_per_s } : null,
			first_left_out: inOrder.length >= 2,
		},
	};
}

// Which shader builds followed each of the game's marks. A mark stands for "this is on screen for the
// first time (or again)" and is made before the frame renders, so its builds start in that frame or the
// next few: a build counts for the latest mark before it, within windowMs. This is the kit's own sanity
// check, first sight above 0 and a repeat at 0 (stopwatch readings carry ms and are not marks of sight).
// Only FirstUse's marks count: each carries its record as detail, with a string tag. Other gf: marks (the
// boot clock's stages, the loader's) have no detail and would otherwise end a sight's window early and
// show up as sights of their own.
// marks: [{t, name, detail}], builds: the "build" events of the whole run (not one window: a build can
// land in the window after its mark).
function attributeMarks(marks, builds, opts) {
	const o = Object.assign({ windowMs: 1000 }, opts);
	const seen = marks
		.filter((m) => m.name.indexOf("gf:") === 0 && m.name.indexOf("gf:probe:") !== 0)
		.filter((m) => m.detail && typeof m.detail.tag === "string" && typeof m.detail.ms !== "number")
		.sort((a, b) => a.t - b.t);
	return seen.map((m, i) => {
		const end = Math.min(i + 1 < seen.length ? seen[i + 1].t : Infinity, m.t + o.windowMs);
		const mine = builds.filter((b) => b.t >= m.t && b.t < end);
		return { tag: m.detail.tag, t: r1(m.t), n: m.detail.n ? m.detail.n : null, builds: mine.length, build_ms: r2(mine.reduce((x, b) => x + b.ms, 0)) };
	});
}

// attributeMarks() by tag, in time order, with the first sight apart from the repeats.
function rollupMarks(attributed) {
	const by = {};
	for (const m of attributed) (by[m.tag] || (by[m.tag] = [])).push(m);
	const out = {};
	for (const tag of Object.keys(by)) {
		const list = by[tag];
		out[tag] = {
			seen: list.length, first_builds: list[0].builds, first_build_ms: list[0].build_ms,
			repeat_builds: list.slice(1).reduce((x, m) => x + m.builds, 0), occurrences: list.slice(0, 6),
		};
	}
	return out;
}

// What the in-page buffers dropped over a run (frames past the log's size, events past a kind's budget),
// summed over the segments. A kind with drops has a short list: its percentiles and, for builds, its counts
// are not the whole run's (the per-frame aggregates, gl_kinds, still are).
function rollupDropped(segments) {
	const t = { frames: 0, events: 0, by_kind: {} };
	for (const s of segments) {
		const d = s && s.dropped;
		if (!d) continue;
		t.frames += d.frames || 0;
		t.events += d.events || 0;
		for (const k of Object.keys(d.by_kind || {})) t.by_kind[k] = (t.by_kind[k] || 0) + d.by_kind[k];
	}
	return t;
}

// Link builds after the first drawn frame, summed over the segments of a run (a frame belongs to one
// segment, so the events add up).
function rollupBuilds(segments) {
	const t = { n: 0, total_ms: 0, max_ms: 0, ge_100: 0, ge_150: 0, events: 0, event_max_ms: 0, events_ge_100: 0, events_ge_150: 0, batched: 0 };
	for (const s of segments) {
		const b = s.builds;
		if (!b) continue;
		t.batched += b.batched || 0;
		t.n += b.n;
		t.total_ms += b.total_ms;
		t.max_ms = Math.max(t.max_ms, b.max_ms);
		t.ge_100 += b.ge_100;
		t.ge_150 += b.ge_150;
		t.events += b.events || 0;
		t.event_max_ms = Math.max(t.event_max_ms, b.event_max_ms || 0);
		t.events_ge_100 += b.events_ge_100 || 0;
		t.events_ge_150 += b.events_ge_150 || 0;
	}
	t.total_ms = r2(t.total_ms);
	return t;
}

// A software rasterizer or a virtual adapter: the milliseconds it gives say nothing about a real GPU. Covers
// SwiftShader, llvmpipe, lavapipe (Mesa's software Vulkan), softpipe, Windows' WARP ("Microsoft Basic Render
// Driver") and a context that never came up (no renderer string).
const SOFTWARE_RENDERER = /swiftshader|llvmpipe|lavapipe|softpipe|software|basic render driver|\bwarp\b|no webgl/i;

function isSoftwareRenderer(renderer) {
	return !renderer || SOFTWARE_RENDERER.test(String(renderer));
}

// Whether the shader caches a run starts with are cold. Chrome's own lives in the profile (a fresh profile
// has none), but on Linux the driver's (Mesa's) lives on disk outside it and is warm from the first run on:
// only MESA_SHADER_CACHE_DISABLE=true (older Mesa: MESA_GLSL_CACHE_DISABLE) makes a fresh profile cold.
// Other platforms' driver caches cannot be switched off from here; they are recorded, not assumed warm.
// o: { profileFresh, platform, mesaDisable (the variable's value) }
function coldCache(o) {
	const mesaOff = /^(1|true|on|yes)$/i.test(String(o.mesaDisable || "").trim());
	if (!o.profileFresh) return { cold: false, why: "reused Chrome profile" };
	if (o.platform === "linux" && !mesaOff) {
		return { cold: false, why: "Mesa's on-disk shader cache outlives the profile (set MESA_SHADER_CACHE_DISABLE=true for a cold run)" };
	}
	return {
		cold: true,
		why: o.platform === "linux" ? "fresh profile, Mesa cache disabled" : `fresh profile (the driver's own cache on ${o.platform || "this platform"} is not controlled)`,
	};
}

// The thresholds of backlog items 10 and 16, applied to what the kit measured. Both are leanings for a
// human, not verdicts, and each says "no data" or "withheld" rather than answer from zeros. Item 10's
// thresholds are milliseconds, which only a real GPU run gives: the count n of programs linked is the same
// on the one backend it was checked on (SwiftShader), but the time per link does not carry over (software
// WebGL, a JIT, is far from Mesa, which is far from ANGLE/D3D11), so on a software renderer the leaning is
// withheld. Both link rules count events (frames that held links), not programs. The rule is for a cold
// shader cache (coldCache): a run that reused its profile, or a Linux one whose Mesa cache was on, only
// under-estimates the links, so a "build" stands and anything else is left to a cold run. Item 16 keys on
// readPixels, the poster composite's blocking call (a texImage2D every frame can come from anything else);
// it is listed beside it for information. Its rule is per second and so depends on the frame rate: it is
// withheld on a software renderer too, and a window with no readback and no poster composite measured
// nothing.
// o: { hardware, cold, coldWhy, hooked (the WebGL census saw draws), dropped (rollupDropped()) }
function leanings(roll, walk, opts) {
	const o = Object.assign({ hardware: true, cold: true, coldWhy: "reused profile", hooked: true, dropped: null }, opts);
	const lost = (kind) => (o.dropped && o.dropped.by_kind && o.dropped.by_kind[kind]) || 0;
	const noCensus = "no data: the WebGL census was off or saw no draws (GF_FPS_KIT / GF_FPS_GLHOOK)";
	const out = {};
	let link = "inconclusive";
	if (roll.total_ms >= 2000 || roll.events_ge_150 >= 3) link = "build";
	else if (roll.event_max_ms <= 100 && roll.total_ms < 1000) link = "drop";
	if (!o.cold && link !== "build") link = `warm cache (${o.coldWhy}): only a cold-cache run can drop it`;
	let lean10 = link;
	if (!o.hooked) lean10 = noCensus;
	else if (lost("build") > 0) lean10 = `no data: ${lost("build")} build events were dropped (the in-page list was full; see dropped)`;
	else if (!o.hardware) lean10 = "withheld: software renderer, milliseconds do not transfer (the count n does)";
	out.item10_link_warmup = Object.assign({}, roll, { leaning: lean10 });
	if (walk && walk.events) {
		const rp = walk.events.readPixels || { n: 0, p95: 0, per_s: 0 };
		const ti = walk.events.texImage2D || { n: 0, p95: 0, per_s: 0 };
		const composites = (walk.marks || []).filter((m) => m.name === "gf:poster_composite").length;
		let leaning = "keep open";
		if ((rp.p95 || 0) < 3 && (rp.per_s || 0) < 0.5) leaning = "close";
		else if ((rp.p95 || 0) >= 5) leaning = "build the cheap tier";
		if (!o.hooked) leaning = noCensus;
		else if (lost("readPixels") > 0) leaning = `no data: ${lost("readPixels")} readPixels events were dropped (see dropped)`;
		else if (!o.hardware) leaning = "withheld: software renderer (per-second rates scale with the frame rate; only per-frame counts carry over)";
		else if (rp.n === 0 && composites === 0) leaning = "no data: no readPixels and no poster composite in the window (a walk that never faced a poster measures nothing)";
		out.item16_readback = {
			readPixels: { n: rp.n, per_s: rp.per_s, p95_ms: rp.p95 }, texImage2D: { n: ti.n, per_s: ti.per_s, p95_ms: ti.p95 },
			composites_in_window: composites, leaning,
		};
	}
	return out;
}

// Alternating windows with the WebGL hook on and off (GF_FPS_AB): what the wrapper costs the main
// thread. legs: [{gl_hook, fps, p50_ms, busy_ms: stats, draws: stats}]. The busy time is the rAF
// callback time, which the frame log keeps with the hook off, so the two sides compare like with like.
// A side is the median over its legs of each leg's busy p50: a leg that held a shader link or a hitch
// moves its mean, not its median. noise_ms is the spread between the legs of one side (the larger of
// the two sides); a delta inside it is not a measurement, within_noise says so.
function summarizeOverhead(legs) {
	const med = (xs) => {
		const v = xs.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
		if (v.length === 0) return null;
		const m = v.length >> 1;
		return v.length % 2 === 1 ? v[m] : (v[m - 1] + v[m]) / 2;
	};
	const spread = (xs) => {
		const v = xs.filter((x) => Number.isFinite(x));
		return v.length > 1 ? Math.max(...v) - Math.min(...v) : null;
	};
	const rn = (v) => (v === null ? null : r3(v));
	const side = (on) => {
		const L = legs.filter((l) => l.gl_hook === on);
		const p50s = L.map((l) => (l.busy_ms ? l.busy_ms.p50 : NaN));
		return {
			legs: L.length, busy_p50_ms: rn(med(p50s)), spread_ms: rn(spread(p50s)),
			busy_mean_ms: rn(med(L.map((l) => (l.busy_ms ? l.busy_ms.mean : NaN)))), fps: rn(med(L.map((l) => l.fps))),
			p50_ms: rn(med(L.map((l) => l.p50_ms))), draws_p50: med(L.map((l) => (l.draws ? l.draws.p50 : NaN))),
		};
	};
	const on = side(true);
	const off = side(false);
	const d = on.busy_p50_ms !== null && off.busy_p50_ms !== null ? r3(on.busy_p50_ms - off.busy_p50_ms) : null;
	const noise = Math.max(on.spread_ms || 0, off.spread_ms || 0);
	const measured = on.spread_ms !== null || off.spread_ms !== null;
	return {
		on, off, delta_busy_p50_ms: d,
		delta_pct: d !== null && off.busy_p50_ms > 0 ? r1((100 * d) / off.busy_p50_ms) : null,
		noise_ms: r3(noise), within_noise: d !== null && measured ? Math.abs(d) <= noise : null,
		per_draw_us: d !== null && on.draws_p50 > 0 ? r2((d * 1000) / on.draws_p50) : null,
	};
}

// Two probe results are comparable when the call census of a row agrees. The structure of a frame, its
// framebuffer binds and passes, was identical in all three software-WebGL runs of one build checked (agree
// within two calls here). What it draws moves
// with the scene's ambient content: two identical software-WebGL runs of the live build differed by 11% in
// draws, the same 96 calls in every frame from boot on (and a first-use wave of 21 program links moved from
// one window to the next), so draws, program switches and useProgram calls get a relative tolerance. A row
// of fewer than minFrames frames has no stable median (a software-WebGL orbit window holds nine to eleven)
// and is skipped, not failed.
const CENSUS_STRUCTURE = ["fbo_binds", "passes"];
const CENSUS_CONTENT = ["draws", "program_switches", "use_program"];

function compareCensus(a, b, opts) {
	const o = Object.assign({ tol: 0.15, row: "street", minFrames: 20 }, opts);
	const rows = [];
	const reasons = [];
	const ca = a && a[o.row] && a[o.row].census;
	const cb = b && b[o.row] && b[o.row].census;
	if (!ca || !cb) return { stable: false, skipped: null, rows, reasons: [`row "${o.row}" has no census in one of the results`] };
	const framesA = ca.draws ? ca.draws.n : undefined;
	const framesB = cb.draws ? cb.draws.n : undefined;
	if (Number.isFinite(framesA) && Number.isFinite(framesB) && Math.min(framesA, framesB) < o.minFrames) {
		return { stable: null, skipped: `${framesA} and ${framesB} frames: fewer than ${o.minFrames} have no stable median`, rows, reasons };
	}
	for (const key of CENSUS_STRUCTURE.concat(CENSUS_CONTENT)) {
		const x = ca[key] ? ca[key].p50 : null;
		const y = cb[key] ? cb[key].p50 : null;
		if (x === null || y === null || x === undefined || y === undefined) {
			rows.push({ key, a: x, b: y, ok: false });
			reasons.push(`${key} missing`);
			continue;
		}
		const diff = Math.abs(x - y);
		const rel = Math.max(x, y) > 0 ? diff / Math.max(x, y) : 0;
		const ok = diff <= 2 || (CENSUS_CONTENT.includes(key) && rel <= o.tol);
		rows.push({ key, a: x, b: y, rel: r3(rel), ok });
		if (!ok) reasons.push(`${key}: ${x} vs ${y}`);
	}
	const drawsA = ca.draws ? ca.draws.p50 : 0;
	const drawsB = cb.draws ? cb.draws.p50 : 0;
	if (!(drawsA > 0) || !(drawsB > 0)) reasons.push("no draw calls were counted");
	return { stable: reasons.length === 0, skipped: null, rows, reasons };
}

// The link census of two results (backlog item 10's input: programs linked after the first drawn frame, and
// the frames that held links): the count held between three runs of one build on one backend (SwiftShader;
// other backends are untested), which the milliseconds do not. Within max(3, tol of the larger) of each other
// is stable; a result without a link census (a run with the kit off) is not comparable.
function compareLinks(a, b, opts) {
	const o = Object.assign({ tol: 0.1 }, opts);
	const la = a && a.link_builds;
	const lb = b && b.link_builds;
	if (!la || !lb || !Number.isFinite(la.n) || !Number.isFinite(lb.n)) return { stable: null, reasons: ["no link census in one of the results"] };
	const reasons = [];
	// n counts builds, and a build is one program only when the engine finishes a program before it starts the
	// next (a result's `batched` says it did not): then only the frames with links are compared.
	const batched = (la.batched || 0) > 0 || (lb.batched || 0) > 0;
	for (const key of batched ? ["events"] : ["n", "events"]) {
		const x = la[key];
		const y = lb[key];
		if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
		if (Math.abs(x - y) > Math.max(3, o.tol * Math.max(x, y))) reasons.push(`${key}: ${x} vs ${y}`);
	}
	return { stable: reasons.length === 0, n: [la.n, lb.n], events: [la.events, lb.events], batched, reasons };
}

// ---------------------------------------------------------------------------------------------
// Process memory from ps (Linux and macOS): the browser, its renderers and its GPU process.
// ---------------------------------------------------------------------------------------------

// Lines of `ps -eo pid=,ppid=,rss=,args=` -> [{pid, ppid, rssKb, args}].
function parsePs(text) {
	const out = [];
	for (const line of String(text).split("\n")) {
		const m = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/.exec(line);
		if (m) out.push({ pid: Number(m[1]), ppid: Number(m[2]), rssKb: Number(m[3]), args: m[4] });
	}
	return out;
}

// RSS in MB of the Chrome tree whose browser process carries --user-data-dir=<profile>.
function rssOfTree(procs, profile) {
	const needle = `--user-data-dir=${profile}`;
	const roots = procs.filter((p) => p.args.includes(needle) && !/--type=/.test(p.args));
	if (roots.length === 0) return null;
	const inTree = new Set(roots.map((p) => p.pid));
	let grew = true;
	while (grew) {
		grew = false;
		for (const p of procs) {
			if (!inTree.has(p.pid) && inTree.has(p.ppid)) {
				inTree.add(p.pid);
				grew = true;
			}
		}
	}
	const out = { browser_mb: 0, gpu_mb: 0, renderer_mb: [], utility_mb: 0, total_mb: 0, processes: 0 };
	for (const p of procs) {
		if (!inTree.has(p.pid)) continue;
		const mb = p.rssKb / 1024;
		const type = (/--type=([\w-]+)/.exec(p.args) || [null, "browser"])[1];
		out.processes++;
		out.total_mb += mb;
		if (type === "browser") out.browser_mb += mb;
		else if (type === "gpu-process") out.gpu_mb += mb;
		else if (type === "renderer") out.renderer_mb.push(r1(mb));
		else out.utility_mb += mb;
	}
	out.renderer_mb.sort((a, b) => b - a);
	out.browser_mb = r1(out.browser_mb);
	out.gpu_mb = r1(out.gpu_mb);
	out.utility_mb = r1(out.utility_mb);
	out.total_mb = r1(out.total_mb);
	return out;
}

module.exports = {
	KIT_VERSION, installProbe, installSource, hzSampler, parseViewport, parseDpr, parseBool, parseNumber,
	parseRows, parseFlags, DEFAULT_FLAGS, parseFirstUse, summarizeFirstUse, parseKnobs, KNOB_NAMES, ROWS, percentile, stats, displayHz, passTable, attributeHitches, summarizeWindow,
	rollupBuilds, rollupDropped, attributeMarks, rollupMarks, leanings, isSoftwareRenderer, coldCache, summarizeOverhead, compareCensus, compareLinks, parsePs, rssOfTree,
};

if (require.main === module) {
	// Exit codes: 0 comparable and stable, 1 the results differ (or nothing was compared), 2 bad usage or a
	// file that cannot be read: the two must not look alike to a script.
	const [cmd, fileA, fileB, tol, which] = process.argv.slice(2);
	const usage = (why) => {
		console.error((why ? why + "\n" : "") + "usage: node tools/web_probe_kit.js compare <result-a.json> <result-b.json> [tolerance [street|walk|sky|orbit|all]]");
		process.exit(2);
	};
	if (cmd !== "compare" || !fileA || !fileB) usage("");
	const tolerance = tol ? Number(tol) : null;
	if (tolerance !== null && !(Number.isFinite(tolerance) && tolerance >= 0 && tolerance <= 1)) usage(`tolerance must be a fraction from 0 to 1, got "${tol}"`);
	if (which !== undefined && which !== "all" && !ROWS.includes(which)) usage(`row must be one of ${ROWS.join(", ")}, all; got "${which}"`);
	const fs = require("fs");
	const load = (file) => {
		try {
			return JSON.parse(fs.readFileSync(file, "utf8"));
		} catch (err) {
			return usage(`cannot read ${file}: ${err.message}`);
		}
	};
	const a = load(fileA);
	const b = load(fileB);
	// "all": every row both results have; the default is the idle street, whose census is structural.
	const rows = which === "all" ? ROWS.filter((r) => a[r] && b[r]) : [which || "street"];
	const opts = tolerance !== null ? { tol: tolerance } : {};
	let differs = false;
	let compared = 0;
	for (const row of rows) {
		const res = compareCensus(a, b, Object.assign({ row }, opts));
		console.log(`-- ${row}`);
		for (const r of res.rows) console.log(`${r.ok ? "ok  " : "DIFF"} ${r.key.padEnd(18)} ${String(r.a).padStart(8)} ${String(r.b).padStart(8)}`);
		if (res.skipped) {
			console.log("CENSUS: SKIPPED " + res.skipped);
			continue;
		}
		compared++;
		console.log(res.stable ? "CENSUS: STABLE" : "CENSUS: DIFFERENT " + res.reasons.join("; "));
		differs = differs || !res.stable;
	}
	// The link census is one number for the whole run, compared when both results carry it.
	const links = compareLinks(a, b, opts.tol ? { tol: opts.tol } : {});
	if (links.stable === null) console.log("LINKS: not compared (" + links.reasons.join("; ") + ")");
	else {
		console.log(`LINKS: ${links.stable ? "STABLE" : "DIFFERENT " + links.reasons.join("; ")} (programs linked after the first draw ${links.n[0]} vs ${links.n[1]}${links.batched ? ", NOT compared: the link calls were batched" : ""}, frames with links ${links.events[0]} vs ${links.events[1]})`);
		differs = differs || !links.stable;
	}
	process.exit(!differs && compared > 0 ? 0 : 1);
}
