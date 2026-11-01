// Real-GPU web FPS probe: Chrome on a real display (or --headless=new with GF_FPS_HEADLESS=1),
// reports the WebGL renderer (must not be SwiftShader/llvmpipe on a real-GPU run) plus a
// shadow-piercing chrome://gpu dump, then steady-state requestAnimationFrame rate on the street, on
// foot, in sky view and in the orbit (Planner) view.
//
// The hitch-attribution kit (tools/web_probe_kit.js, docs/runbooks/web-probe-kit.md) rides along:
// an init script injected before the engine's first script wraps the WebGL calls that block (program
// builds, readbacks, texture and buffer uploads), counts draws, framebuffer binds and program
// switches per rAF frame, and logs long tasks and the game's FirstUse marks. Every row carries the
// main-thread busy ms, the call census and what the slow frames were spent on.
//
// GF_FPS_SAVE=<path to a gridfall_save.json> seeds that save into the browser's IndexedDB BEFORE
// the engine boots (via a same-origin page), so the game continues a grown city instead of a
// fresh day 1. The run fails if the "continuing the saved city" line never appears.
//
// Knobs (all optional; the defaults are the probe's setup before the kit, plus the walk and orbit rows):
//   GF_FPS_VIEWPORT=WxH   CSS viewport (default 1600x900)      GF_FPS_DPR=n   deviceScaleFactor (1)
//   GF_FPS_HEADLESS=1     --headless=new, muted, no display    GF_FPS_CHROME=<binary> (/usr/bin/google-chrome)
//   GF_FPS_CHROME_ARGS="--use-angle=swiftshader ..."           GF_FPS_USER_DATA_DIR=<dir> (default: a temp dir, removed)
//   GF_FPS_SETTLE_S=30    seconds before the first row         GF_FPS_WINDOW_S=20   seconds per row
//   GF_FPS_ROWS=street,walk,sky,orbit                          GF_FPS_AB=<s>  3 pairs of WebGL hook on/off legs, <s> s each, idle street
//   GF_FPS_KIT=0          no init script at all                GF_FPS_GLHOOK=0   frame log without the WebGL wrappers
//   GF_FPS_FLAGS="a=1,b=0" feature flags written to user://feature_flags.json (default web_first_use_marks=1, "none" = {}:
//                         a reused profile loses the flags an earlier run seeded; names are checked against data/feature_flags.json)
//   GF_FPS_MEMORY=0       skip process RSS / UA memory         GF_FPS_RAW=1      keep every window's raw frames in <outdir>
//
// Unknown GF_FPS_* names, bad values and contradictions (GF_FPS_AB without the hook) stop the run with exit 2.
// Exit codes: 0 done, 2 bad knob or crash, 3 the GF_FPS_SAVE city was not continued, 4 the Quit to orbit / Tab round
// trip logged an exception or never reached the orbit view, 5 the WebGL census was asked for and saw no draws.
//
// usage: DISPLAY=:1 NODE_PATH=<dir with playwright-core> node tools/web_fps_probe.js <url> <outdir>
//        (headless: env -u DISPLAY GF_FPS_HEADLESS=1 ... )
// See docs/runbooks/web-deploy.md (post-redeploy checklist) for when to run it and how
// GF_FPS_SAVE seeds a grown-city save before boot, and docs/runbooks/web-probe-kit.md for the kit.
const { chromium } = require("playwright-core");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
const kit = require("./web_probe_kit.js");
const URL_ = process.argv[2];
const OUT = process.argv[3] || "/tmp/gf-web-fps";
// The flag names the game defines, to catch a mistyped GF_FPS_FLAGS entry; null when the file is not at hand.
function gameFlagNames() {
	try {
		const spec = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "data", "feature_flags.json"), "utf8"));
		return Object.keys(spec.flags);
	} catch (e) {
		return null;
	}
}
// The shape of result.json: bumped when a key that tools/web_measure.py --probe-report reads moves.
const RESULT_SCHEMA = 1;
let K;
try {
K = kit.parseKnobs(process.env, gameFlagNames());
} catch (e) {
	console.error("GF_FPS_ERROR", String(e.message));
	process.exit(2);
}
const SAVE = K.save;
// Emscripten IDBFS layout as used by the Godot web export (verified against a live boot's
// IndexedDB dump on 2026-10-27; keep in sync if the engine's storage ever changes).
const IDB_DIR = "/userfs/godot/app_userdata/GridFall — GMI Cloud Multi-Model Crisis Sim";
const IDB = {
	db: "/userfs", version: 21, store: "FILE_DATA",
	dirs: ["/userfs/godot", "/userfs/godot/app_userdata", IDB_DIR],
	fileMode: 33206, dirMode: 16895,
};
fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const withTimeout = (promise, ms, fallback) => {
	let timer;
	const limit = new Promise((r) => { timer = setTimeout(() => r(fallback), ms); });
	return Promise.race([promise, limit]).finally(() => clearTimeout(timer));
};
const log = [];
let cleanup = async () => {};
(async () => {
	const profileDir = K.profile || fs.mkdtempSync(path.join(os.tmpdir(), "gf-fps-profile-"));
	const ownProfile = K.profile === "";
	// A profile that already holds files has a warm GPU shader cache, and on Linux Mesa's own cache outlives even a
	// fresh profile: the link rule (item 10) is for a cold one (kit.coldCache).
	const profileFresh = ownProfile || !fs.existsSync(profileDir) || fs.readdirSync(profileDir).length === 0;
	const mesaDisable = process.env.MESA_SHADER_CACHE_DISABLE || process.env.MESA_GLSL_CACHE_DISABLE || "";
	const cache = Object.assign({ profile_fresh: profileFresh, mesa_shader_cache_disable: mesaDisable || null },
		kit.coldCache({ profileFresh, platform: process.platform, mesaDisable }));
	const args = ["--ignore-gpu-blocklist", "--enable-gpu-rasterization", "--no-first-run",
		`--window-size=${K.viewport.width},${K.viewport.height}`, "--autoplay-policy=no-user-gesture-required"];
	// Headless Chrome with a real audio device would play the game: mute it.
	if (K.headless) args.push("--headless=new", "--mute-audio");
	args.push(...K.chromeArgs);
	const ctx = await chromium.launchPersistentContext(profileDir, {
		executablePath: K.chrome, headless: false, args,
		viewport: K.viewport, deviceScaleFactor: K.dpr,
	});
	cleanup = async () => {
		try { await ctx.close(); } catch (e) { /* already closed */ }
		if (ownProfile) fs.rmSync(profileDir, { recursive: true, force: true });
	};
	const finish = async (code) => {
		await cleanup();
		process.exit(code);
	};
	process.on("uncaughtException", (e) => { console.error("GF_FPS_ERROR", e); finish(2); });
	const page = ctx.pages()[0] || await ctx.newPage();
	page.on("console", (m) => log.push(m.type() + " " + m.text()));
	page.on("pageerror", (e) => log.push("pageerror " + String(e)));
	// Before the engine's first script: the kit's frame log, WebGL census and observers.
	if (K.kit) await page.addInitScript({ content: kit.installSource({ gl: K.glHook }) });

	// GPU truth: chrome://gpu renders inside shadow roots, so plain body.innerText sees nothing.
	let gpuText = "";
	try {
		const gpuPage = await ctx.newPage();
		await gpuPage.goto("chrome://gpu");
		await sleep(5000);
		gpuText = await gpuPage.evaluate(() => {
			// chrome://gpu renders inside shadow roots; neither innerText nor textContent
			// pierces them, so collect every shadow root's textContent explicitly.
			const chunks = [];
			const walk = (root) => {
				const t = (root.innerText || root.textContent || "").trim();
				if (t) chunks.push(t);
				for (const el of root.querySelectorAll ? Array.from(root.querySelectorAll("*")) : []) {
					if (el.shadowRoot) walk(el.shadowRoot);
				}
			};
			walk(document.body);
			return chunks.join("\n");
		}).catch(() => "");
		await gpuPage.close();
	} catch (e) {
		log.push("info chrome://gpu not readable: " + String(e).split("\n")[0]);
	}
	fs.writeFileSync(path.join(OUT, "chrome-gpu.txt"), gpuText);
	const flat = gpuText.replace(/\s+/g, " ");
	const glRendererLine = ((flat.match(/GL_RENDERER\s*:?\s*(.{0,100})/i) || ["", ""])[1] || "").trim();
	const webglHw = /WebGL\s*:?\s*Hardware accelerated/i.test(flat);

	// Files seeded into the browser's IndexedDB before the engine boots, from a same-origin page, so
	// its first mount already sees them (no unload-sync race with a running engine): the optional
	// grown-city save and the feature flags the kit needs (the web build reads no environment).
	const seedFiles = [];
	let saveBytes = 0;
	if (SAVE) {
		const raw = fs.readFileSync(SAVE);
		saveBytes = raw.length;
		seedFiles.push({ key: IDB_DIR + "/gridfall_save.json", b64: raw.toString("base64") });
	}
	// Always written, "{}" for GF_FPS_FLAGS=none: a reused profile otherwise keeps what an earlier run seeded.
	seedFiles.push({ key: IDB_DIR + "/feature_flags.json", b64: Buffer.from(JSON.stringify(K.flags)).toString("base64") });
	let seeded = null;
	if (seedFiles.length > 0) {
		const origin = new URL(URL_).origin;
		const seed = await ctx.newPage();
		await seed.goto(origin + "/healthz", { timeout: 60000 });
		seeded = await seed.evaluate(async ({ idb, files }) => {
			// Match Emscripten IDBFS entry shapes exactly: Date timestamps, Int8Array
			// contents, and real entries for the parent directories (a fresh profile
			// has no database at all).
			const db = await new Promise((res, rej) => {
				const r = indexedDB.open(idb.db, idb.version);
				// Emscripten IDBFS v21 schema: the store AND its "timestamp" index.
				// Without the index the engine logs "IndexedDB not available" and runs
				// on an ephemeral in-memory filesystem (no saves at all).
				r.onupgradeneeded = () => {
					const s = r.result.createObjectStore(idb.store);
					s.createIndex("timestamp", "timestamp", { unique: false });
				};
				r.onsuccess = () => res(r.result);
				r.onerror = () => rej(r.error);
			});
			if (!db.objectStoreNames.contains(idb.store)) return "no-store:" + Array.from(db.objectStoreNames).join(",");
			if (!db.transaction(idb.store).objectStore(idb.store).indexNames.contains("timestamp"))
				return "no-timestamp-index";
			const tx = db.transaction(idb.store, "readwrite");
			const store = tx.objectStore(idb.store);
			const now = new Date();
			for (const d of idb.dirs) store.put({ timestamp: now, mode: idb.dirMode }, d);
			for (const f of files) {
				const bytes = new Int8Array(Array.from(atob(f.b64), (c) => c.charCodeAt(0)));
				store.put({ timestamp: now, mode: idb.fileMode, contents: bytes }, f.key);
			}
			await new Promise((res, rej) => { tx.oncomplete = res; tx.onerror = () => rej(tx.error); });
			db.close();
			return true;
		}, { idb: IDB, files: seedFiles }).catch((e) => "error:" + String(e));
		await seed.close();
		log.push("info seeded " + seedFiles.length + " file(s) into IndexedDB: " + JSON.stringify(seeded)
			+ (SAVE ? " (save " + saveBytes + " bytes)" : "") + " flags " + JSON.stringify(K.flags));
	}

	// The display's refresh rate, from a quiet page before the engine loads: the game's own frames
	// are a multiple of it. Headless Chrome has no display and answers with its virtual 60 Hz.
	let hz = null;
	try {
		await page.goto(new URL(URL_).origin + "/healthz", { timeout: 60000 });
		hz = kit.displayHz(await page.evaluate(kit.hzSampler, 5000));
	} catch (e) {
		log.push("info display rate not measured: " + String(e).split("\n")[0]);
	}

	const t0 = Date.now();
	await page.goto(URL_, { timeout: 120000 });
	const renderer = await page.evaluate(() => {
		const c = document.createElement("canvas");
		const gl = c.getContext("webgl2");
		if (!gl) return "no webgl2";
		const ext = gl.getExtension("WEBGL_debug_renderer_info");
		return ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
	});
	let booted = false;
	while (Date.now() - t0 < 900000) {
		if (log.some((l) => /GRIDFALL:|GridFall GPU:/.test(l))) { booted = true; break; }
		await sleep(1000);
	}
	const bootS = (Date.now() - t0) / 1000;
	const fps = async (secs) => page.evaluate((s) => new Promise((res) => {
		const times = [];
		const end = performance.now() + s * 1000;
		const tick = (t) => { times.push(t); if (t < end) requestAnimationFrame(tick); else {
			const d = []; for (let i = 1; i < times.length; i++) d.push(times[i] - times[i - 1]);
			d.sort((a, b) => a - b);
			res({ frames: d.length, fps: d.length / s, p50_ms: d[Math.floor(d.length * 0.5)],
				p95_ms: d[Math.floor(d.length * 0.95)], max_ms: d[d.length - 1] });
		} };
		requestAnimationFrame(tick);
	}), secs);

	// ---- the kit's side: segments (everything between two drains) and rows -----------------------
	const segments = [];
	const runMarks = [];
	const runBuilds = [];
	let firstDraw = null;
	const callKit = (fn, arg) => page.evaluate(fn, arg).catch(() => null);
	const mark = (name, detail) => (K.kit
		? callKit(([n, d]) => window.__gfProbe && window.__gfProbe.mark(n, d), [name, detail === undefined ? null : detail])
		: Promise.resolve());
	const seg = async (label) => {
		if (!K.kit) return null;
		const d = await callKit(() => (window.__gfProbe ? window.__gfProbe.drain() : null));
		if (!d) return null;
		if (K.raw) fs.writeFileSync(path.join(OUT, `gl-raw-${segments.length}-${label}.json`), JSON.stringify(d));
		const s = kit.summarizeWindow(d, { firstDrawFrame: firstDraw });
		if (firstDraw === null && s.first_draw_frame !== null) firstDraw = s.first_draw_frame;
		runMarks.push(...d.marks);
		runBuilds.push(...d.events.filter((e) => e.kind === "build"));
		s.label = label;
		segments.push(s);
		return s;
	};
	// A row: what happened since the last drain is a "<label>_pre" segment (key presses, waits and
	// the first-use builds they cause), then the window itself.
	const rows = {};
	const row = async (label, secs) => {
		await seg(label + "_pre");
		await mark("row:" + label, { secs });
		const f = await fps(secs);
		const s = await seg(label);
		rows[label] = s ? Object.assign({}, f, {
			kit_frames: s.frames, kit_fps: s.fps, interval_ms: s.interval_ms, busy_ms: s.busy_ms, late_ms: s.late_ms,
			census: s.census, pass_table: s.pass_table, gl_kinds: s.gl_kinds, builds: s.builds, events: s.events,
			longtasks: s.longtasks, loaf: s.loaf, hitches: s.hitches, marks: s.marks, gl_on: s.gl_on,
			off_raf: s.off_raf, dropped: s.dropped || null,
			}) : f;
		return rows[label];
	};
	const rssNow = (label) => {
		if (!K.memory || (process.platform !== "linux" && process.platform !== "darwin")) return null;
		try {
			const out = execFileSync("ps", ["-eo", "pid=,ppid=,rss=,args="], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
			return Object.assign({ at: label }, kit.rssOfTree(kit.parsePs(out), profileDir));
		} catch (e) {
			return { at: label, error: String(e.message).slice(0, 120) };
		}
	};
	const memory = { rss: [], js_heap: null, uasm: null };
	const take = (label) => { const r = rssNow(label); if (r) memory.rss.push(r); };

	await seg("boot");
	await mark("phase:booted", { boot_s: bootS });
	take("boot");
	await sleep(K.settleS * 1000);
	await seg("settle");
	await page.mouse.click(Math.round(K.viewport.width / 2), Math.round(K.viewport.height / 2));
	await sleep(3000);
	const want = (r) => K.rows.includes(r);
	if (want("street")) {
		await row("street", K.windowS);
		await page.screenshot({ path: path.join(OUT, "street.png") }).catch(() => {});
	}
	// Alternating windows with the WebGL hook on and off: what the wrapper costs the main thread.
	let overhead = null;
	if (K.abS > 0 && K.kit && K.glHook) {
		const legs = [];
		for (const on of [true, false, true, false, true, false]) {
			await callKit((v) => window.__gfProbe.setGl(v), on);
			await seg("ab_switch");
			const f = await fps(K.abS);
			const s = await seg("ab_" + (on ? "on" : "off"));
			legs.push({ gl_hook: on, fps: f.fps, p50_ms: f.p50_ms, busy_ms: s ? s.busy_ms : null, draws: s ? s.census.draws : null });
		}
		await callKit((v) => window.__gfProbe.setGl(v), true);
		overhead = Object.assign({ legs }, kit.summarizeOverhead(legs));
	}
	if (want("walk")) {
		await page.keyboard.down("w");
		try { await row("walk", K.windowS); } finally { await page.keyboard.up("w"); }
	}
	if (want("sky")) {
		await page.keyboard.press("Tab");
		await sleep(15000);
		await row("sky", K.windowS);
		await page.screenshot({ path: path.join(OUT, "sky.png") }).catch(() => {});
		// Esc inside the overview only closes it (OverviewFeature._unhandled_input); the pause menu
		// the exit below navigates opens on the next Esc. Tab leaves the overview the same way.
		await page.keyboard.press("Tab");
		await sleep(2000);
	}
	// exit_fp / enter_fp round trip: Quit to orbit from the pause menu, then Tab back down.
	// exit_fp once halted the web build on "invalid bus index -1" (audio teardown); it only
	// reproduces with real audio buses, which this headed run has and headless smoke does not.
	const crashRe = /bus index|SCRIPT ERROR|unreachable|uncaught/i;
	const artifactRe = /Pointer Lock/; // CDP input is not a pointer-lock user gesture
	await seg("to_menu");
	const exitStart = log.length;
	await page.keyboard.press("Escape"); // pause menu (focus starts on Resume)
	await sleep(2000);
	for (let i = 0; i < 5; i++) {
		await page.keyboard.press("ArrowDown"); // Resume -> ... -> Quit to orbit
		await sleep(200);
	}
	await page.keyboard.press("Enter");
	await mark("phase:quit_to_orbit");
	await sleep(6000); // exit_fp is call_deferred; let teardown and audio settle
	await page.screenshot({ path: path.join(OUT, "orbit-exit.png") }).catch(() => {});
	const exitSeg = await seg("to_orbit");
	// The orbit (Planner) view: on the web the game always boots into first person, so this is the
	// only way into it. Its first seconds are the transition segment above.
	if (want("orbit")) {
		await row("orbit", K.windowS);
		await page.screenshot({ path: path.join(OUT, "orbit.png") }).catch(() => {});
	}
	// The exit's console lines run to here, the orbit dwell included: an exception raised while the orbit view
	// sat on screen belongs to the round trip.
	const enterStart = log.length;
	const exitBad = log.slice(exitStart, enterStart).filter((l) => crashRe.test(l) || (l.startsWith("pageerror") && !artifactRe.test(l)));
	await page.keyboard.press("Tab"); // orbit -> enter_fp
	await mark("phase:tab_to_street");
	await sleep(8000);
	await page.screenshot({ path: path.join(OUT, "street-return.png") }).catch(() => {});
	const enterBad = log.slice(enterStart).filter((l) => crashRe.test(l) || (l.startsWith("pageerror") && !artifactRe.test(l)));
	await seg("to_street");
	const firstuse = kit.parseFirstUse(log);
	// With the game's marks on, Quit to orbit logs one: its absence means the blind ArrowDown x5 + Enter did not
	// land on that button (the pause menu's order changed) and the orbit view was never reached. null: no marks.
	const quitMarked = firstuse.length === 0 ? null : firstuse.some((r) => r.tag === "quit_to_orbit");
	const exitFp = { exit_clean: exitBad.length === 0, enter_clean: enterBad.length === 0,
		quit_marked: quitMarked, orbit_reached: quitMarked,
		transition_ms: exitSeg ? { longtask_max: exitSeg.longtasks.max_ms, interval_max: exitSeg.interval_ms.max } : null,
		lines: exitBad.concat(enterBad).slice(0, 10) };

	// ---- what the browser says about the run ------------------------------------------------------
	const info = K.kit ? await callKit(() => (window.__gfProbe ? window.__gfProbe.info() : null)) : null;
	const pageInfo = await page.evaluate(() => ({
		dpr: window.devicePixelRatio, inner: [window.innerWidth, window.innerHeight], coi: !!window.crossOriginIsolated,
		sab: typeof SharedArrayBuffer !== "undefined",
		threads: typeof GODOT_THREADS_ENABLED !== "undefined" ? GODOT_THREADS_ENABLED : null,
		canvas: (() => { const c = document.querySelector("canvas"); return c ? { w: c.width, h: c.height, cw: c.clientWidth, ch: c.clientHeight } : null; })(),
		ua: navigator.userAgent,
	})).catch(() => ({}));
	if (K.memory) {
		take("end");
		memory.js_heap = await page.evaluate(() => (performance.memory
			? { used: performance.memory.usedJSHeapSize, total: performance.memory.totalJSHeapSize, limit: performance.memory.jsHeapSizeLimit }
			: null)).catch(() => null);
		// Needs cross-origin isolation (true behind the deployment's Caddy, not on a plain local
		// server) and can take up to about 20 s.
		if (pageInfo.coi) {
			const t1 = Date.now();
			memory.uasm = await withTimeout(page.evaluate(async () => {
				try {
					const r = await performance.measureUserAgentSpecificMemory();
					const top = r.breakdown.slice().sort((a, b) => b.bytes - a.bytes).slice(0, 6)
						.map((b) => ({ bytes: b.bytes, types: b.types, where: b.attribution.map((a) => a.url || a.scope).slice(0, 2) }));
					return { bytes: r.bytes, top };
				} catch (e) { return { error: String(e).slice(0, 200) }; }
			}), 120000, { error: "timeout after 120 s" });
			memory.uasm.secs = (Date.now() - t1) / 1000;
		} else {
			memory.uasm = { skipped: "not cross-origin isolated" };
		}
	}
	const env = {
		viewport: K.viewport, dpr: K.dpr, headless: K.headless, chrome: K.chrome, page: pageInfo,
		drawing_buffer: info ? info.drawing : null, context_attributes: info ? info.attrs : null,
		display_hz: hz, renderer, threads: pageInfo.threads, cross_origin_isolated: pageInfo.coi,
		cache,
		kit: { enabled: K.kit, gl_hook: K.glHook, version: kit.KIT_VERSION, seen: K.kit ? (await callKit(() => (window.__gfProbe ? window.__gfProbe.seen : null))) : null },
		flags: K.flags,
	};
	const bad = log.filter((l) => /Too many instances|FSR2|occlusion|SCRIPT ERROR|pageerror|^error/i.test(l));
	// Checked late: the "continuing" line lands after the GPU banner that ends the boot wait.
	const continued = log.some((l) => /continuing the saved city/i.test(l));
	const rolls = kit.rollupBuilds(segments);
	const walkRow = rows.walk || rows.street || null;
	// The log as it stands now: the memory call above can take a minute, and the game keeps printing meanwhile.
	const firstuseNow = kit.parseFirstUse(log);
	const fu = kit.summarizeFirstUse(firstuseNow);
	const markLinks = kit.rollupMarks(kit.attributeMarks(runMarks, runBuilds));
	const slim = (s) => ({
	label: s.label, frames: s.frames, secs: s.secs, fps: s.fps, busy_ms: s.busy_ms, interval_ms: s.interval_ms,
	builds: s.builds, longtasks: s.longtasks, loaf: s.loaf, marks: s.marks, uploads: s.events,
	off_raf: s.off_raf, dropped: s.dropped || null,
		hitches: { n: s.hitches.n, threshold_ms: s.hitches.threshold_ms, worst: s.hitches.worst.slice(0, 3) },
		draws: s.census.draws,
	});
	// true: the WebGL census saw draws; false: it was asked for and saw none (the hook never attached to the game's
	// context); null: not asked for (GF_FPS_KIT=0 or GF_FPS_GLHOOK=0), so the link and readback rules have no data.
	const censusAsked = K.kit && K.glHook;
	const kitOk = censusAsked ? (rows.street ? rows.street.census.draws.max > 0 : segments.some((s) => s.census.draws.max > 0)) : null;
	const hardware = !kit.isSoftwareRenderer(renderer);
	const dropped = kit.rollupDropped(segments);
	const result = { schema: RESULT_SCHEMA, url: URL_, renderer, gl_renderer_line: glRendererLine,
	hardware,
	chrome_gpu_hw: webglHw, booted, boot_s: bootS,
		save_seeded: SAVE ? seeded : null, save_continued: SAVE ? continued : null,
		env, street: rows.street || null, walk: rows.walk || null, sky: rows.sky || null, orbit: rows.orbit || null,
		exit_fp: exitFp, kit_ok: kitOk, dropped, link_builds: rolls, mark_links: markLinks,
		decides: kit.leanings(rolls, walkRow, { hardware, cold: cache.cold, coldWhy: cache.why, hooked: kitOk === true, dropped }), overhead,
		first_use: Object.assign({ records: firstuseNow.length }, fu), memory, segments: segments.map(slim), warnings: bad.slice(0, 40), warning_count: bad.length };
	fs.writeFileSync(path.join(OUT, "console.log"), log.join("\n"));
	fs.writeFileSync(path.join(OUT, "result.json"), JSON.stringify(result, null, 2));
	console.log("GF_FPS_RENDERER " + renderer);
	const f1 = (v, d = 1) => (v === null || v === undefined ? "-" : Number(v).toFixed(d));
	console.log("GF_FPS_ENV " + JSON.stringify({ viewport: K.viewport, dpr: K.dpr, canvas: pageInfo.canvas, hz: hz && (hz.nominal || hz.hz), threads: pageInfo.threads, coi: pageInfo.coi, hook: K.kit && K.glHook }));
	for (const name of ["street", "walk", "sky", "orbit"]) {
		const r = rows[name];
		if (!r) continue;
		const c = r.census;
		console.log(`GF_FPS_ROW ${name.padEnd(7)} fps ${f1(r.fps)} p50 ${f1(r.p50_ms)} p95 ${f1(r.p95_ms)} max ${f1(r.max_ms)}`
			+ (c ? ` | busy p50 ${f1(r.busy_ms.p50)} p95 ${f1(r.busy_ms.p95)} | draws ${f1(c.draws.p50, 0)} fbo ${f1(c.fbo_binds.p50, 0)}`
				+ ` passes ${f1(c.passes.p50, 0)} switches ${f1(c.program_switches.p50, 0)} | builds ${r.builds.n} (${f1(r.builds.total_ms)} ms)`
				+ ` | longtasks ${r.longtasks.n}` : ""));
	}
	console.log("GF_FPS_BUILDS " + JSON.stringify(rolls));
	if (overhead) {
		console.log("GF_FPS_OVERHEAD " + JSON.stringify({ delta_busy_p50_ms: overhead.delta_busy_p50_ms, delta_pct: overhead.delta_pct,
			noise_ms: overhead.noise_ms, within_noise: overhead.within_noise, per_draw_us: overhead.per_draw_us, legs: overhead.legs.length }));
	}
	console.log("GF_FPS_JSON " + JSON.stringify(result));
	if (kitOk === false) console.log("GF_FPS_WARN the WebGL census saw no draw calls: the hook did not attach to the game's context");
	// Uploads are dropped on any texture-heavy boot and decide nothing; builds and readbacks are the rules' inputs.
	if (dropped.frames) console.log("GF_FPS_WARN the in-page frame log was full: " + dropped.frames + " oldest frames dropped; per-frame figures cover the newest frames of the row, event rates the whole row, see result.dropped");
	if (rolls.batched) console.log("GF_FPS_WARN the engine batched its shader work (" + rolls.batched + " links or compiles began before the last link's status was read): link_builds.n, max_ms, ge_100 and ge_150 are not per program; total_ms and events still are");
	if (dropped.by_kind.build || dropped.by_kind.readPixels) console.log("GF_FPS_WARN in-page event lists were full: " + JSON.stringify(dropped.by_kind) + " events dropped, see result.dropped");
	if (SAVE && (seeded !== true || !continued)) await finish(3);
	if (!exitFp.exit_clean || !exitFp.enter_clean || exitFp.orbit_reached === false) await finish(4);
	if (kitOk === false) await finish(5);
	await finish(0);
})().catch(async (e) => {
	console.error("GF_FPS_ERROR", e);
	await cleanup();
	process.exit(2);
});
