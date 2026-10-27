// Real-GPU web FPS probe: headed Chrome on a real display, reports the WebGL renderer (must not be
// SwiftShader/llvmpipe) plus a shadow-piercing chrome://gpu dump, then steady-state
// requestAnimationFrame rate on the street and in sky view.
//
// GF_FPS_SAVE=<path to a gridfall_save.json> seeds that save into the browser's IndexedDB BEFORE
// the engine boots (via a same-origin page), so the game continues a grown city instead of a
// fresh day 1. The run fails if the "continuing the saved city" line never appears.
//
// usage: DISPLAY=:1 NODE_PATH=<dir with playwright-core> node tools/web_fps_probe.js <url> <outdir>
// See docs/runbooks/web-deploy.md (post-redeploy checklist) for when to run it and how
// GF_FPS_SAVE seeds a grown-city save before boot.
const { chromium } = require("playwright-core");
const fs = require("fs");
const path = require("path");
const URL_ = process.argv[2];
const OUT = process.argv[3] || "/tmp/gf-web-fps";
const SAVE = process.env.GF_FPS_SAVE || "";
// Emscripten IDBFS layout as used by the Godot web export (verified against a live boot's
// IndexedDB dump on 2026-10-27; keep in sync if the engine's storage ever changes).
const IDB_DIR = "/userfs/godot/app_userdata/GridFall \u2014 GMI Cloud Multi-Model Crisis Sim";
const IDB = {
	db: "/userfs", version: 21, store: "FILE_DATA",
	dirs: ["/userfs/godot", "/userfs/godot/app_userdata", IDB_DIR],
	saveKey: IDB_DIR + "/gridfall_save.json",
	fileMode: 33206, dirMode: 16895,
};
fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = [];
(async () => {
	const browser = await chromium.launch({
		executablePath: "/usr/bin/google-chrome",
		headless: false,
		args: ["--ignore-gpu-blocklist", "--enable-gpu-rasterization", "--no-first-run",
			"--window-size=1600,900", "--autoplay-policy=no-user-gesture-required"],
	});
	const ctx = await browser.newContext({ viewport: { width: 1600, height: 900 } });
	const page = await ctx.newPage();
	page.on("console", (m) => log.push(m.type() + " " + m.text()));
	page.on("pageerror", (e) => log.push("pageerror " + String(e)));

	// GPU truth: chrome://gpu renders inside shadow roots, so plain body.innerText sees nothing.
	const gpuPage = await ctx.newPage();
	await gpuPage.goto("chrome://gpu");
	await sleep(5000);
	const gpuText = await gpuPage.evaluate(() => {
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
	fs.writeFileSync(path.join(OUT, "chrome-gpu.txt"), gpuText);
	await gpuPage.close();
	const flat = gpuText.replace(/\s+/g, " ");
	const glRendererLine = ((flat.match(/GL_RENDERER\s*:?\s*(.{0,100})/i) || ["", ""])[1] || "").trim();
	const webglHw = /WebGL\s*:?\s*Hardware accelerated/i.test(flat);

	// Optional grown-city save: seed IndexedDB from a same-origin page before the engine boots,
	// so its first mount already sees the file (no unload-sync race with a running engine).
	let saveSeeded = false;
	let saveBytes = 0;
	if (SAVE) {
		const raw = fs.readFileSync(SAVE);
		saveBytes = raw.length;
		const origin = new URL(URL_).origin;
		const seed = await ctx.newPage();
		await seed.goto(origin + "/healthz", { timeout: 60000 });
		saveSeeded = await seed.evaluate(async ({ idb, b64 }) => {
			// Match Emscripten IDBFS entry shapes exactly: Date timestamps, Int8Array
			// contents, and real entries for the parent directories (a fresh profile
			// has no database at all).
			const bytes = new Int8Array(Array.from(atob(b64), (c) => c.charCodeAt(0)));
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
			store.put({ timestamp: now, mode: idb.fileMode, contents: bytes }, idb.saveKey);
			await new Promise((res, rej) => { tx.oncomplete = res; tx.onerror = () => rej(tx.error); });
			db.close();
			return true;
		}, { idb: IDB, b64: raw.toString("base64") }).catch((e) => "error:" + String(e));
		await seed.close();
		log.push("info GF_FPS_SAVE seed " + JSON.stringify(saveSeeded) + " (" + saveBytes + " bytes)");
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
	await sleep(30000);
	await page.mouse.click(800, 450);
	await sleep(3000);
	const street = await fps(20);
	await page.screenshot({ path: path.join(OUT, "street.png") }).catch(() => {});
	await page.keyboard.press("Tab");
	await sleep(15000);
	const sky = await fps(20);
	await page.screenshot({ path: path.join(OUT, "sky.png") }).catch(() => {});
	// exit_fp / enter_fp round trip: Quit to orbit from the pause menu, then Tab back down.
	// exit_fp once halted the web build on "invalid bus index -1" (audio teardown); it only
	// reproduces with real audio buses, which this headed run has and headless smoke does not.
	const crashRe = /bus index|SCRIPT ERROR|unreachable|uncaught/i;
	const artifactRe = /Pointer Lock/; // CDP input is not a pointer-lock user gesture
	const exitStart = log.length;
	await page.keyboard.press("Escape"); // pause menu (focus starts on Resume)
	await sleep(2000);
	for (let i = 0; i < 5; i++) {
		await page.keyboard.press("ArrowDown"); // Resume -> ... -> Quit to orbit
		await sleep(200);
	}
	await page.keyboard.press("Enter");
	await sleep(6000); // exit_fp is call_deferred; let teardown and audio settle
	await page.screenshot({ path: path.join(OUT, "orbit-exit.png") }).catch(() => {});
	const exitBad = log.slice(exitStart).filter((l) => crashRe.test(l) || (l.startsWith("pageerror") && !artifactRe.test(l)));
	const enterStart = log.length;
	await page.keyboard.press("Tab"); // orbit -> enter_fp
	await sleep(8000);
	await page.screenshot({ path: path.join(OUT, "street-return.png") }).catch(() => {});
	const enterBad = log.slice(enterStart).filter((l) => crashRe.test(l) || (l.startsWith("pageerror") && !artifactRe.test(l)));
	const exitFp = { exit_clean: exitBad.length === 0, enter_clean: enterBad.length === 0,
		lines: exitBad.concat(enterBad).slice(0, 10) };
	const bad = log.filter((l) => /Too many instances|FSR2|occlusion|SCRIPT ERROR|pageerror|^error/i.test(l));
	// Checked late: the "continuing" line lands after the GPU banner that ends the boot wait.
	const continued = log.some((l) => /continuing the saved city/i.test(l));
	const result = { url: URL_, renderer, gl_renderer_line: glRendererLine,
		hardware: !/swiftshader|llvmpipe|software/i.test(renderer),
		chrome_gpu_hw: webglHw, booted, boot_s: bootS,
		save_seeded: SAVE ? saveSeeded : null, save_continued: SAVE ? continued : null,
		street, sky, exit_fp: exitFp, warnings: bad.slice(0, 40), warning_count: bad.length };
	fs.writeFileSync(path.join(OUT, "console.log"), log.join("\n"));
	fs.writeFileSync(path.join(OUT, "result.json"), JSON.stringify(result, null, 2));
	console.log("GF_FPS_RENDERER " + renderer);
	console.log("GF_FPS_JSON " + JSON.stringify(result));
	await browser.close();
	if (SAVE && (saveSeeded !== true || !continued)) process.exit(3);
	if (!exitFp.exit_clean || !exitFp.enter_clean) process.exit(4);
})().catch((e) => { console.error("GF_FPS_ERROR", e); process.exit(2); });
