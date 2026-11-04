// Web hitch probe: what the first minute and a half of play feels like on the web build.
//
// Boots the page in Chrome (use --headless=new with a real GPU, see GF_HP_ARGS), waits for the loader veil to drop
// (the page's gf:veil_released mark), then plays a fixed 90 s script with synthetic keys and mouse (walk, look around,
// Tab overview and back, the pause menu, sprint) while the kit (tools/web_probe_kit.js) records every requestAnimationFrame
// and every WebGL program build. A small census of its own records each linked program's defines and body hashes, so the
// run can say which programs the boot and the shader warm-up built (before the veil) and which a player still waited for
// (after it).
//
// result.json:
//   boot            wall seconds to the veil, GF_BOOT's total_ms / first_frame step / marks of the warm-up stage
//   warmup          the game's own WARMUP report line (programs warmed, stages, ms), null when the flag is off
//   programs        total / before_veil / after_veil, with link+compile ms, and after_veil's top programs and defines
//   hitches         intervals of the after-veil window over 34 / 50 / 100 / 250 ms, the biggest ones with their cause
//                   (programs built in that frame, FirstUse marks, long tasks)
//   frames          p50 / p95 / p99 / max of the after-veil intervals
//
// Knobs: GF_HP_VIEWPORT=1600x900  GF_HP_CHROME=/opt/google/chrome/chrome  GF_HP_ARGS="extra chrome args"
//        GF_HP_FLAGS="a=1,b=0" (feature flags seeded into user://feature_flags.json; default web_first_use_marks=1)
//        GF_HP_SAVE=<gridfall_save.json> (seed a grown city)  GF_HP_SECS=90  GF_HP_ORBIT=1 (after the script: Planner view
//        for 20 s and back, with draws / vertices / frame time of the Planner)  GF_HP_USER_DATA_DIR=<dir>
//        GF_HP_TAB_S=10 (seconds the Tab overview stays open, 0 = no Tab)
//        GF_HP_TUNING='{"budget_ms":3000,"states":["lit","unlit"]}' (the warm-up's user://warmup_tuning.json)
// usage: NODE_PATH=<dir with playwright-core> node tools/web_hitch_probe.js <url> <outdir>
const { chromium } = require("playwright-core");
const fs = require("fs");
const os = require("os");
const path = require("path");
const kit = require("./web_probe_kit.js");

const URL_ = process.argv[2];
const OUT = process.argv[3] || "/tmp/gf-web-hitch";
const env = process.env;
const viewport = (() => {
	const m = /^(\d+)x(\d+)$/.exec(env.GF_HP_VIEWPORT || "1600x900");
	return m ? { width: +m[1], height: +m[2] } : { width: 1600, height: 900 };
})();
const SECS = Number(env.GF_HP_SECS || 90);
const CHROME = env.GF_HP_CHROME || "/opt/google/chrome/chrome";
const flagsText = env.GF_HP_FLAGS === undefined ? "web_first_use_marks=1" : env.GF_HP_FLAGS;
const FLAGS = {};
for (const part of flagsText.split(",").map((s) => s.trim()).filter((s) => s && s !== "none")) {
	const [k, v] = part.split("=");
	FLAGS[k] = v !== "0" && v !== "false";
}
const SAVE = env.GF_HP_SAVE || "";
const ORBIT = env.GF_HP_ORBIT === "1";
const IDB_DIR = "/userfs/godot/app_userdata/GridFall — GMI Cloud Multi-Model Crisis Sim";
const IDB = { db: "/userfs", version: 21, store: "FILE_DATA", dirs: ["/userfs/godot", "/userfs/godot/app_userdata", IDB_DIR], fileMode: 33206, dirMode: 16895 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
fs.mkdirSync(OUT, { recursive: true });
const logLines = [];

// In the page, before the engine: a census of every linked program (defines and body hashes of its shaders, the
// wait the link and the status queries cost) and, per rAF frame, the draws, vertices and callback time.
function censusInit() {
	if (window.__hp) return;
	const P = window.__hp = { progs: [], shaders: new WeakMap(), progMap: new WeakMap(), frames: [], cur: null, on: false };
	const GL2 = window.WebGL2RenderingContext && WebGL2RenderingContext.prototype;
	if (!GL2) return;
	const hash = (s) => { let h = 5381; for (let k = 0; k < s.length; k++) h = ((h << 5) + h + s.charCodeAt(k)) | 0; return (h >>> 0).toString(16); };
	const wrap = (name, fn) => { const o = GL2[name]; if (typeof o !== "function") return; GL2[name] = function () { const c = P.cur; if (c) fn(c, arguments); return o.apply(this, arguments); }; };
	const tri = (c, n) => { c.draws++; c.verts += n; };
	wrap("drawElements", (c, a) => tri(c, a[1]));
	wrap("drawArrays", (c, a) => tri(c, a[2]));
	wrap("drawElementsInstanced", (c, a) => tri(c, a[1] * a[4]));
	wrap("drawArraysInstanced", (c, a) => tri(c, a[2] * a[3]));
	wrap("drawRangeElements", (c, a) => tri(c, a[3]));
	const sp = GL2.shaderSource, cs = GL2.compileShader, gsp = GL2.getShaderParameter, at = GL2.attachShader, lp = GL2.linkProgram, gpp = GL2.getProgramParameter;
	GL2.shaderSource = function (sh, src) {
		try {
			const defs = [], body = [];
			for (const l of src.split("\n")) { if (/^\s*#define\s/.test(l)) defs.push(l.replace(/^\s*#define\s+/, "").trim()); else body.push(l); }
			P.shaders.set(sh, { len: src.length, defs, body: hash(body.join("\n")), vs: /gl_Position/.test(src), cmp: 0 });
		} catch (e) { /* census only */ }
		return sp.apply(this, arguments);
	};
	GL2.compileShader = function (sh) { return cs.apply(this, arguments); };
	GL2.getShaderParameter = function (sh, pn) {
		const t = performance.now(); const r = gsp.apply(this, arguments); const m = P.shaders.get(sh);
		if (m && pn === this.COMPILE_STATUS) m.cmp += performance.now() - t;
		return r;
	};
	GL2.attachShader = function (pr, sh) { let p = P.progMap.get(pr); if (!p) { p = { sh: [], t: 0 }; P.progMap.set(pr, p); } p.sh.push(sh); return at.apply(this, arguments); };
	GL2.linkProgram = function (pr) { const p = P.progMap.get(pr); if (p) p.t = performance.now(); return lp.apply(this, arguments); };
	GL2.getProgramParameter = function (pr, pn) {
		const t = performance.now(); const r = gpp.apply(this, arguments); const p = P.progMap.get(pr);
		if (p && pn === this.LINK_STATUS && !p.done) {
			p.done = true;
			const vs = p.sh.map((s) => P.shaders.get(s)).filter(Boolean);
			const v = vs.find((s) => s.vs), f = vs.find((s) => !s.vs);
			P.progs.push({ at: Math.round(t), ms: +(performance.now() - t + vs.reduce((a, s) => a + s.cmp, 0)).toFixed(2),
				vb: v && v.body, fb: f && f.body, defs: (v && v.defs || []).filter((d) => /^(MODE_|BASE_PASS|USE_|DISABLE_|APPLY_|RENDER_|LIGHT_USE|SHADOWS_|DO_SIDE|ALPHA_|NORMAL_MAP|SKY_|FINAL_|AT_)/.test(d)).map((d) => d.split(" ")[0]) });
		}
		return r;
	};
	// GPU time per frame from EXT_disjoint_timer_query_webgl2 (null when the browser has none or the result was disjoint).
	P.gl = null; P.ext = null; P.pend = [];
	const og = HTMLCanvasElement.prototype.getContext;
	HTMLCanvasElement.prototype.getContext = function (type) {
		const c = og.apply(this, arguments);
		if (c && type === "webgl2" && !P.gl && this.id === "canvas") { P.gl = c; try { P.ext = c.getExtension("EXT_disjoint_timer_query_webgl2"); } catch (e) { P.ext = null; } }
		return c;
	};
	const poll = () => {
		const gl = P.gl, ext = P.ext;
		if (!gl || !ext) return;
		while (P.pend.length) {
			const e = P.pend[0];
			let avail = false;
			try { avail = gl.getQueryParameter(e.q, gl.QUERY_RESULT_AVAILABLE); } catch (x) { P.pend.shift(); continue; }
			if (!avail) break;
			P.pend.shift();
			if (!gl.getParameter(ext.GPU_DISJOINT_EXT)) e.f.gpu = gl.getQueryParameter(e.q, gl.QUERY_RESULT) / 1e6;
			try { gl.deleteQuery(e.q); } catch (x) { /* gone */ }
		}
		if (P.pend.length > 8) { const e = P.pend.shift(); try { gl.deleteQuery(e.q); } catch (x) { /* gone */ } }
	};
	const oraf = window.requestAnimationFrame.bind(window);
	window.requestAnimationFrame = function (cb) {
		return oraf(function (ts) {
			if (!P.on) return cb(ts);
			poll();
			const f = { t: ts, cb: 0, draws: 0, verts: 0, gpu: null };
			let q = null;
			if (P.gl && P.ext) { try { q = P.gl.createQuery(); P.gl.beginQuery(P.ext.TIME_ELAPSED_EXT, q); } catch (e) { q = null; } }
			P.cur = f;
			const t0 = performance.now();
			try { return cb(ts); } finally {
				f.cb = performance.now() - t0; P.cur = null;
				if (q) { try { P.gl.endQuery(P.ext.TIME_ELAPSED_EXT); P.pend.push({ q, f }); } catch (e) { /* no query */ } }
				if (P.frames.length < 100000) P.frames.push(f);
			}
		});
	};
}

const pct = (arr, p) => (arr.length ? arr[Math.min(arr.length - 1, Math.floor(arr.length * p))] : null);
const r1 = (x) => (x === null || x === undefined ? null : Math.round(x * 10) / 10);

(async () => {
	const profile = env.GF_HP_USER_DATA_DIR || fs.mkdtempSync(path.join(os.tmpdir(), "gf-hp-profile-"));
	const ownProfile = !env.GF_HP_USER_DATA_DIR;
	const args = ["--ignore-gpu-blocklist", "--enable-gpu-rasterization", "--no-first-run", "--headless=new", "--mute-audio",
		"--enable-gpu", "--use-angle=default", "--no-sandbox", "--disable-dev-shm-usage", "--autoplay-policy=no-user-gesture-required",
		`--window-size=${viewport.width},${viewport.height}`, ...(env.GF_HP_ARGS || "").split(/\s+/).filter(Boolean)];
	const ctx = await chromium.launchPersistentContext(profile, { executablePath: CHROME, headless: false, args, viewport, deviceScaleFactor: 1 });
	const cleanup = async () => {
		try { await ctx.close(); } catch (e) { /* closed */ }
		if (ownProfile) fs.rmSync(profile, { recursive: true, force: true });
	};
	process.on("uncaughtException", async (e) => { console.error("GF_HP_ERROR", e); await cleanup(); process.exit(2); });
	try {
		const page = ctx.pages()[0] || await ctx.newPage();
		await page.bringToFront();
		page.on("console", (m) => logLines.push(m.text()));
		page.on("pageerror", (e) => logLines.push("pageerror " + String(e)));
		await page.addInitScript({ content: "(" + censusInit.toString() + ")();" });
		await page.addInitScript({ content: kit.installSource({ gl: true }) });
		// Seed the flags (and a save) into IndexedDB from a same-origin page before the engine boots.
		const files = [{ key: IDB_DIR + "/feature_flags.json", b64: Buffer.from(JSON.stringify(FLAGS)).toString("base64") }];
		// GF_HP_TUNING='{"budget_ms":3000,"states":["lit","unlit"]}' seeds user://warmup_tuning.json (ShaderWarmup.tuning()).
		if (env.GF_HP_TUNING) files.push({ key: IDB_DIR + "/warmup_tuning.json", b64: Buffer.from(env.GF_HP_TUNING).toString("base64") });
		if (SAVE) files.push({ key: IDB_DIR + "/gridfall_save.json", b64: fs.readFileSync(SAVE).toString("base64") });
		await page.goto(new URL(URL_).origin + "/healthz", { timeout: 60000 });
		const seeded = await page.evaluate(async ({ idb, files }) => {
			const db = await new Promise((res, rej) => {
				const r = indexedDB.open(idb.db, idb.version);
				r.onupgradeneeded = () => { const s = r.result.createObjectStore(idb.store); s.createIndex("timestamp", "timestamp", { unique: false }); };
				r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
			});
			const tx = db.transaction(idb.store, "readwrite"); const store = tx.objectStore(idb.store); const now = new Date();
			for (const d of idb.dirs) store.put({ timestamp: now, mode: idb.dirMode }, d);
			for (const f of files) store.put({ timestamp: now, mode: idb.fileMode, contents: new Int8Array(Array.from(atob(f.b64), (c) => c.charCodeAt(0))) }, f.key);
			await new Promise((res, rej) => { tx.oncomplete = res; tx.onerror = () => rej(tx.error); });
			db.close();
			return true;
		}, { idb: IDB, files }).catch((e) => "error:" + e);
		console.error("GF_HP_STEP seeded " + JSON.stringify(seeded) + " flags " + JSON.stringify(FLAGS) + (SAVE ? " save" : ""));
		const t0 = Date.now();
		await page.goto(URL_, { timeout: 120000 });
		console.error("GF_HP_STEP game page loaded");
		// Start the frame census when the page has its first frame; the veil mark is what the game does for the player.
		await page.evaluate(() => { window.__hp.on = true; });
		let veil = null;
		// The loader as the player sees it (GF_HP_LOADER=1, 100 ms polls): every change of the label, the bar's fill and its
		// travelling stripe, with the page time, and the longest stretch the page did not answer (a blocked main thread).
		const loaderLog = [];
		let lastAnswer = null, longestSilence = 0;
		while (Date.now() - t0 < 600000) {
			const r = await page.evaluate(() => {
				const e = performance.getEntriesByName("gf:veil_released");
				const lab = document.getElementById("gf-label"), fill = document.getElementById("gf-fill"), bar = document.getElementById("gf-bar");
				return { veil: e.length ? e[0].startTime : null, t: performance.now(), label: lab ? lab.textContent : null, fill: fill ? fill.style.width : null, indet: !!bar && bar.className.includes("gf-indet") };
			}).catch(() => null);
			if (r) {
				if (lastAnswer !== null) longestSilence = Math.max(longestSilence, r.t - lastAnswer);
				lastAnswer = r.t;
				const prev = loaderLog[loaderLog.length - 1];
				if (env.GF_HP_LOADER === "1" && (!prev || prev.label !== r.label || prev.fill !== r.fill || prev.indet !== r.indet)) loaderLog.push({ t: Math.round(r.t), label: r.label, fill: r.fill, indet: r.indet });
				veil = r.veil;
				if (veil !== null) break;
			}
			await sleep(env.GF_HP_LOADER === "1" ? 100 : 500);
		}
		if (veil === null) throw new Error("the veil never dropped in 600 s");
		const bootWallS = (Date.now() - t0) / 1000;
		console.error("GF_HP_STEP veil dropped at page t=" + Math.round(veil) + " ms, wall " + bootWallS.toFixed(1) + " s");
		const cx = Math.round(viewport.width / 2), cy = Math.round(viewport.height / 2);
		const act = async (name) => { await page.evaluate((n) => window.__gfProbe && window.__gfProbe.mark(n), "act:" + name).catch(() => {}); };
		const hold = async (key, ms) => { await page.keyboard.down(key); await sleep(ms); await page.keyboard.up(key); };
		const look = async (dx, dy, steps, ms) => { for (let i = 0; i < steps; i++) { await page.mouse.move(cx + dx * i, cy + dy * i); await sleep(ms); } await page.mouse.move(cx, cy); };
		const startWall = Date.now();
		const until = (s) => sleep(Math.max(0, startWall + s * 1000 - Date.now()));
		// The script is timed from the veil; each step waits for its slot so a slow frame does not shift the rest.
		await act("click"); await page.mouse.click(cx, cy); await until(6);
		await act("walk1"); await page.keyboard.down("w"); await look(6, 0, 30, 60); await look(-6, 2, 30, 60); await page.keyboard.up("w"); await until(24);
		// GF_HP_TAB_S=<s>: how long the Tab overview stays open (default 10; 0 skips it, to see what else happens at that time).
		const tabS = Number(env.GF_HP_TAB_S === undefined ? 10 : env.GF_HP_TAB_S);
		if (tabS > 0) { await act("tab_overview"); await page.keyboard.press("Tab"); await until(24 + tabS); await act("tab_back"); await page.keyboard.press("Tab"); }
		await until(40);
		await act("walk2"); await page.keyboard.down("w"); await page.keyboard.down("Shift"); await look(10, 0, 25, 60);
		await page.keyboard.up("Shift"); await look(-8, -3, 25, 60); await page.keyboard.up("w"); await until(58);
		await act("pause"); await page.keyboard.press("Escape"); await until(64);
		await act("resume"); await page.keyboard.press("Escape"); await until(68);
		await act("walk3"); await page.keyboard.down("w"); await look(0, 5, 20, 60); await look(0, -5, 20, 60); await hold("a", 1500); await look(8, 0, 30, 60);
		await page.keyboard.up("w"); await until(SECS);
		await act("end");
		await page.screenshot({ path: path.join(OUT, "street.png") }).catch(() => {});
		let orbit = null, orbitZoom = null, toOrbit = null, toStreet = null, speeds = null;
		if (ORBIT) {
			// The Planner view (pause menu: Esc, Down x5, Enter), 20 s, then Tab back: its frames are the Planner's numbers.
			await act("to_orbit_begin");
			const drainA = await page.evaluate(() => { const f = window.__hp.frames; window.__hp.frames = []; return f.length; });
			await page.keyboard.press("Escape"); await sleep(1500);
			for (let i = 0; i < 5; i++) { await page.keyboard.press("ArrowDown"); await sleep(150); }
			await page.evaluate(() => { window.__hp.frames = []; window.__hp.t_enter = performance.now(); });
			await page.keyboard.press("Enter");
			// With the "Preparing the Planner view" overlay (planner_prepare_overlay) the move takes longer than 10 s on a
			// grown city: wait for the page's gf:prepare_done mark (up to 60 s) when the overlay showed, 10 s when it did not.
			await sleep(10000);
			const shown = await page.evaluate(() => performance.getEntriesByName("gf:prepare_shown").length > 0);
			if (shown) {
				for (let k = 0; k < 100; k++) {
					if (await page.evaluate(() => performance.getEntriesByName("gf:prepare_done").length > 0)) break;
					await sleep(500);
				}
				await sleep(3000);
			}
			toOrbit = await page.evaluate(() => ({ frames: window.__hp.frames, t0: window.__hp.t_enter }));
			await page.evaluate(() => { window.__hp.frames = []; });
			await act("orbit_window");
			await sleep(20000);
			orbit = await page.evaluate(() => window.__hp.frames);
			await page.screenshot({ path: path.join(OUT, "orbit.png") }).catch(() => {});
			// A zoomed-in view (wheel up over the middle of the city), 10 s of frames and a screenshot.
			await page.mouse.move(cx, cy);
			for (let i = 0; i < 10; i++) { await page.mouse.wheel(0, -120); await sleep(150); }
			await sleep(3000);
			await page.evaluate(() => { window.__hp.frames = []; });
			await sleep(10000);
			orbitZoom = await page.evaluate(() => window.__hp.frames);
			await page.screenshot({ path: path.join(OUT, "orbit_zoom.png") }).catch(() => {});
			// GF_HP_SPEEDS: game days per window at each speed button (the buttons sit at x = 1071 + 41 * k, y = 24 at
			// 1600x900: pause, 1x, 2x, 4x, 8x). Days are the gf:day_N marks the game makes with the marks flag on.
			if (env.GF_HP_SPEEDS) {
				const spd = { 1: 1112, 2: 1153, 4: 1194, 8: 1235 };
				const secs = Number(env.GF_HP_SPEED_S || 20);
				speeds = {};
				for (const sp of env.GF_HP_SPEEDS.split(",").map(Number)) {
					if (!spd[sp]) continue;
					await page.mouse.click(Math.round(spd[sp] * viewport.width / 1600), Math.round(24 * viewport.height / 900));
					await sleep(1500);
					const t0 = await page.evaluate(() => performance.now());
					await sleep(secs * 1000);
					const t1 = await page.evaluate(() => performance.now());
					const days = await page.evaluate(({ a, b }) => performance.getEntriesByType("mark").filter((m) => /^gf:day_\d+(_p\d+)?$/.test(m.name) && m.startTime >= a && m.startTime <= b).map((m) => [Math.round(m.startTime), Number((/_p(\d+)$/.exec(m.name) || [0, 0])[1])]), { a: t0, b: t1 });
					const times = days.map((d) => d[0]);
					const gaps = times.slice(1).map((t, i) => t - times[i]);
					speeds["x" + sp] = { secs: Math.round((t1 - t0) / 100) / 10, days: days.length, first_day_at_s: days.length ? Math.round((times[0] - t0) / 100) / 10 : null, longest_gap_s: gaps.length ? Math.round(Math.max(...gaps) / 100) / 10 : null, drained_pieces: days.length ? days[days.length - 1][1] - days[0][1] : 0 };
				}
				await page.mouse.click(Math.round(1112 * viewport.width / 1600), Math.round(24 * viewport.height / 900));
			}
			await page.evaluate(() => { window.__hp.frames = []; window.__hp.t_tab = performance.now(); });
			await act("tab_to_street"); await page.keyboard.press("Tab");
			{
				// The "Back to the street" overlay (when on) ends with the gf:prepare_done mark after the one the Planner left.
				await sleep(8000);
				const n = await page.evaluate(() => performance.getEntriesByName("gf:prepare_shown").length);
				if (n >= 2) {
					for (let k = 0; k < 100; k++) {
						if (await page.evaluate((m) => performance.getEntriesByName("gf:prepare_done").length >= m, n)) break;
						await sleep(500);
					}
					await sleep(2000);
				}
			}
			toStreet = await page.evaluate(() => ({ frames: window.__hp.frames, t0: window.__hp.t_tab }));
			await page.screenshot({ path: path.join(OUT, "street_return.png") }).catch(() => {});
			void drainA;
		}
		// ---- collect ----
		const d = await page.evaluate(() => window.__gfProbe.drain());
		const hp = await page.evaluate(() => ({ progs: window.__hp.progs, frames: window.__hp.on ? window.__hp.frames : [] }));
		const marks = await page.evaluate(() => performance.getEntriesByType("mark").filter((m) => /^gf:/.test(m.name)).map((m) => ({ name: m.name, t: m.startTime, detail: m.detail || null })));
		const gl = await page.evaluate(() => {
			const c = document.querySelector("canvas"); const g = c && c.getContext("webgl2");
			if (!g) return "no webgl2"; const e = g.getExtension("WEBGL_debug_renderer_info");
			return e ? g.getParameter(e.UNMASKED_RENDERER_WEBGL) : g.getParameter(g.RENDERER);
		}).catch(() => "?");

		// frames after the veil: intervals between consecutive rAF timestamps
		const fr = d.frames.filter((f) => f.t >= veil).map((f) => ({ t: f.t, i: f.i }));
		const iv = [];
		for (let k = 1; k < fr.length; k++) iv.push({ t: fr[k].t, dt: fr[k].t - fr[k - 1].t, from: fr[k - 1].t });
		const endT = veil + SECS * 1000;
		const win = iv.filter((x) => x.t <= endT + 100);
		const sorted = win.map((x) => x.dt).sort((a, b) => a - b);
		const builds = d.events.filter((e) => e.kind === "build");
		const firstUse = kit.parseFirstUse(logLines);
		const gt = (n) => win.filter((x) => x.dt > n).length;
		const progs = hp.progs;
		const warmB = marks.find((m) => m.name === "gf:warmup_begin");
		const warmE = marks.find((m) => m.name === "gf:warmup_end");
		const before = progs.filter((p) => p.at < veil), after = progs.filter((p) => p.at >= veil && p.at <= endT);
		const sum = (a) => a.reduce((s, p) => s + p.ms, 0);
		const warmed = warmB && warmE ? progs.filter((p) => p.at >= warmB.t && p.at <= warmE.t) : [];
		const bootLine = logLines.map((l) => /GF_BOOT (\{.*\})/.exec(l)).filter(Boolean).map((m) => JSON.parse(m[1]))[0] || null;
		const warmLine = logLines.map((l) => /WARMUP (\{.*\})/.exec(l)).filter(Boolean).map((m) => { try { return JSON.parse(m[1]); } catch (e) { return null; } }).filter(Boolean);
		// the slowest intervals with what ran in them
		const top = win.slice().sort((a, b) => b.dt - a.dt).slice(0, 14).map((x) => {
			const inBuilds = progs.filter((p) => p.at >= x.from && p.at <= x.t + 1);
			const near = marks.filter((m) => m.t >= x.from - 50 && m.t <= x.t + 1 && !/^gf:probe/.test(m.name)).map((m) => m.name);
			const acts = d.marks.filter((m) => m.t >= x.from - 3000 && m.t <= x.t && /act:/.test(m.name)).map((m) => m.name.replace("gf:probe:", "")).slice(-1);
			return { at_s: r1((x.t - veil) / 1000), ms: r1(x.dt), programs: inBuilds.length, program_ms: r1(sum(inBuilds)), marks: near.slice(0, 6), last_action: acts[0] || null };
		});
		// Frames over 100 ms split by cause: a program build that filled at least half of the interval ("compile"), or
		// something else (the machine, GC, a long task): on a shared box the second kind is noise the warm-up cannot touch.
		const slow100 = win.filter((x) => x.dt > 100).map((x) => {
			const inB = progs.filter((p) => p.at >= x.from && p.at <= x.t + 1);
			const pms = sum(inB);
			return { at_s: r1((x.t - veil) / 1000), ms: r1(x.dt), programs: inB.length, program_ms: r1(pms), compile: pms >= 0.5 * x.dt };
		});
		const after_defs = {};
		for (const p of after) { const k = p.defs.filter((x) => !/^(USE_RADIANCE_MAP|BASE_PASS|DISABLE_REFLECTION_PROBE|DISABLE_LIGHTMAP|DISABLE_LIGHT_AREA|SHADOWS_DISABLED)$/.test(x)).sort().join("+") || "(plain)"; after_defs[k] = (after_defs[k] || 0) + 1; }
		const result = {
			schema: 1, url: URL_, renderer: gl, viewport, flags: FLAGS, save: SAVE ? path.basename(SAVE) : null, secs: SECS,
			boot: {
				veil_page_ms: r1(veil), wall_s: r1(bootWallS), game_total_ms: bootLine ? bootLine.total_ms : null,
				marks: bootLine ? Object.fromEntries(bootLine.marks.filter((m) => /^(ready_end|pre_draw|first_frame|veil_frames|warmup_begin|warmup_end)$/.test(m[0])).map((m) => [m[0], m[1]])) : null,
				page_marks: Object.fromEntries(marks.filter((m) => /^gf:(bytes_done|veil_released|warmup_begin|warmup_end|first_frame|start_game_resolved)$/.test(m.name)).map((m) => [m.name, r1(m.t)])),
			},
			warmup: warmLine.length ? warmLine[warmLine.length - 1] : null,
			programs: {
				total: progs.length, before_veil: before.length, before_veil_ms: r1(sum(before)), warmed_in_stage: warmed.length, warmed_ms: r1(sum(warmed)),
				after_veil: after.length, after_veil_ms: r1(sum(after)), after_defs: after_defs,
			},
			frames: { n: win.length, p50: r1(pct(sorted, 0.5)), p95: r1(pct(sorted, 0.95)), p99: r1(pct(sorted, 0.99)), max: r1(sorted[sorted.length - 1]) },
			hitches: { gt34: gt(34), gt50: gt(50), gt100: gt(100), gt250: gt(250), gt500: gt(500), gt100_compile: slow100.filter((x) => x.compile).length, gt100_other: slow100.filter((x) => !x.compile).length, slow100, top },
			first_use: firstUse.filter((r) => r.ms === undefined).map((r) => r.tag + "#" + r.n),
			longtasks_gt100: d.longtasks.filter((l) => l.dur >= 100).length,
			warnings: logLines.filter((l) => /^pageerror|SCRIPT ERROR|USER ERROR|WARNING/.test(l)).slice(0, 10).map((l) => l.slice(0, 200)),
		};
		const orbitStats = (fr) => {
			const cb = fr.map((f) => f.cb).sort((a, b) => a - b);
			const gp = fr.filter((f) => f.gpu !== null && f.gpu !== undefined).map((f) => f.gpu).sort((a, b) => a - b);
			const dr = fr.map((f) => f.draws).sort((a, b) => a - b);
			const vt = fr.map((f) => f.verts).sort((a, b) => a - b);
			const ivs = []; for (let k = 1; k < fr.length; k++) ivs.push(fr[k].t - fr[k - 1].t); ivs.sort((a, b) => a - b);
			return { frames: fr.length, cb_p50: r1(pct(cb, 0.5)), cb_p99: r1(pct(cb, 0.99)), interval_p50: r1(pct(ivs, 0.5)), interval_p99: r1(pct(ivs, 0.99)), interval_max: r1(ivs[ivs.length - 1]),
				draws_p50: pct(dr, 0.5), verts_p50: pct(vt, 0.5), gpu_p50: r1(pct(gp, 0.5)), gpu_p99: r1(pct(gp, 0.99)), gpu_samples: gp.length };
		};
		// A view change: the intervals after the key press, and the programs built in the window.
		const change = (c) => {
			const fr = c.frames; const ivs = []; for (let k = 1; k < fr.length; k++) ivs.push({ dt: fr[k].t - fr[k - 1].t, t: fr[k].t });
			const t1 = fr.length ? fr[fr.length - 1].t : c.t0;
			const pr = progs.filter((p) => p.at >= c.t0 && p.at <= t1);
			const first = ivs.length ? ivs.reduce((m, x) => (x.dt > m.dt ? x : m), ivs[0]) : { dt: 0 };
			return { frames: fr.length, interval_max: r1(first.dt), gt100: ivs.filter((x) => x.dt > 100).length, gt250: ivs.filter((x) => x.dt > 250).length,
				programs: pr.length, program_ms: r1(sum(pr)), program_max_ms: r1(pr.reduce((m, p) => Math.max(m, p.ms), 0)) };
		};
		if (toOrbit) result.to_orbit = change(toOrbit);
		if (toStreet) result.to_street = change(toStreet);
		if (orbit) result.orbit = orbitStats(orbit);
		if (speeds) result.speeds = speeds;
		if (env.GF_HP_LOADER === "1") result.loader = { changes: loaderLog.length, longest_silence_ms: Math.round(longestSilence), log: loaderLog };
		if (orbitZoom) result.orbit_zoom = orbitStats(orbitZoom);
		result.render_info = logLines.filter((l) => /^RENDERINFO /.test(l)).map((l) => { try { return JSON.parse(l.slice(11)); } catch (e) { return null; } }).filter(Boolean);
		fs.writeFileSync(path.join(OUT, "result.json"), JSON.stringify(result, null, 1));
		fs.writeFileSync(path.join(OUT, "programs.json"), JSON.stringify({ veil, progs }));
		fs.writeFileSync(path.join(OUT, "console.log"), logLines.join("\n"));
		console.log("GF_HP_RESULT " + JSON.stringify({ boot: result.boot, warmup: result.warmup, programs: Object.assign({}, result.programs, { after_defs: undefined }), frames: result.frames, hitches: Object.assign({}, result.hitches, { top: undefined, slow100: undefined }), orbit: result.orbit, orbit_zoom: result.orbit_zoom, to_orbit: result.to_orbit, to_street: result.to_street, speeds: result.speeds, loader: result.loader && { changes: result.loader.changes, longest_silence_ms: result.loader.longest_silence_ms } }));
	} catch (e) {
		console.error("GF_HP_ERROR", e);
		fs.writeFileSync(path.join(OUT, "console.log"), logLines.join("\n"));
		await cleanup();
		process.exit(2);
	}
	await cleanup();
	process.exit(0);
})();
