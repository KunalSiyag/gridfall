// Screenshots of the river on a web build, with a pixel check that it is not a flat slab.
//
// Boots the build in Chrome, seeds a save whose hero stands where you say (a pose per shot), hides the
// HUD (F1) and saves the canvas as <outdir>/<name>.png. For every shot it prints the mean colour, the
// luminance spread and the number of distinct colours of a patch of the picture (default: the lower
// half), and fails (exit 1) when --min-std is given and the spread is under it. The river that rendered
// as a pale concrete slab on the web (water depth read with the Forward+ formula under
// gl_compatibility) had a spread of 2.4 of 255 over 900x300 px; real water is above 15.
//
// usage: NODE_PATH=<dir with playwright-core> node tools/web_water_shots.js <url> <outdir> <save.json>
//          [--chrome /opt/google/chrome/chrome] [--swiftshader] [--settle-ms 14000] [--min-std 8]
//          [--patch x,y,w,h] [--day N] <pose> [<pose> ...]
// Weather is not part of the pose: the game recomputes it from the seed and the sim day when it loads
// (Weather.from_dict ignores the saved state), so a seeded save's saved weather has no effect. Pick the sky
// with --day N (the save's own day, often overcast, otherwise); for the a3 save (seed 31767) day 11 is
// clear, 9 is rain and 10 is overcast. GRIDFALL's daily_state(seed, day) tells you for any other save.
// pose: name:x,z,yaw,pitch,first|third[,tick_in_day][,walk_ms]   (yaw and pitch in degrees; tick 1 is noon,
//       2 is dusk when --settle-ms is short; walk_ms holds W that long before the shot)
// A GPU run (no --swiftshader) needs a machine with a real GPU; headless Chrome uses it through ANGLE.
// Example: ... bank:27.44,7,-90,-4,first,1 wade:27.625,7,-90,-10,third,1
const { chromium } = require("playwright-core");
const fs = require("fs");
const os = require("os");
const path = require("path");

const IDB_DIR = "/userfs/godot/app_userdata/GridFall — GMI Cloud Multi-Model Crisis Sim";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** The save with the hero moved to a pose: {x, z, yaw, pitch, mode, tick}. */
function withPose(save, p) {
	const d = JSON.parse(JSON.stringify(save));
	d.fp.player = Object.assign(d.fp.player, {
		pos: [p.x, p.y || 0.0, p.z], yaw: p.yaw, pitch: p.pitch, cam_yaw: p.yaw, cam_pitch: p.pitch,
		camera_mode: p.mode, crouched: false,
	});
	d.sim.tick_in_day = p.tick;
	if (p.day > 0) d.sim.day = p.day;
	return JSON.stringify(d);
}

/** Mean RGB, luminance spread and distinct colours of a patch of a PNG, measured in the page. */
async function patchStats(page, png, box) {
	return page.evaluate(async ({ b64, box }) => {
		const img = new Image();
		img.src = "data:image/png;base64," + b64;
		await img.decode();
		const [x, y, w, h] = box || [0, Math.floor(img.height / 2), img.width, Math.floor(img.height / 2)];
		const c = document.createElement("canvas");
		c.width = w; c.height = h;
		const g = c.getContext("2d");
		g.drawImage(img, x, y, w, h, 0, 0, w, h);
		const px = g.getImageData(0, 0, w, h).data;
		let n = 0, sr = 0, sg = 0, sb = 0, sl = 0, sl2 = 0;
		const seen = new Set();
		for (let i = 0; i < px.length; i += 4) {
			const l = 0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2];
			n++; sr += px[i]; sg += px[i + 1]; sb += px[i + 2]; sl += l; sl2 += l * l;
			seen.add((px[i] << 16) | (px[i + 1] << 8) | px[i + 2]);
		}
		const m = sl / n;
		return { mean: [sr / n, sg / n, sb / n].map((v) => +v.toFixed(1)), std: +Math.sqrt(sl2 / n - m * m).toFixed(2), colours: seen.size };
	}, { b64: png.toString("base64"), box });
}

async function main() {
	const argv = process.argv.slice(2);
	const opt = { chrome: "/opt/google/chrome/chrome", settle: 14000, minStd: 0, day: 0, patch: null, swift: false };
	const pos = [];
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i];
		if (a === "--chrome") opt.chrome = argv[++i];
		else if (a === "--settle-ms") opt.settle = +argv[++i];
		else if (a === "--min-std") opt.minStd = +argv[++i];
		else if (a === "--day") opt.day = +argv[++i];
		else if (a === "--patch") opt.patch = argv[++i].split(",").map(Number);
		else if (a === "--swiftshader") opt.swift = true;
		else pos.push(a);
	}
	const [url, outdir, savePath, ...poses] = pos;
	if (!url || !outdir || !savePath || poses.length === 0) {
		console.error("usage: node tools/web_water_shots.js <url> <outdir> <save.json> [options] <name:x,z,yaw,pitch,mode[,tick][,walk_ms]> ...");
		process.exit(2);
	}
	fs.mkdirSync(outdir, { recursive: true });
	const base = JSON.parse(fs.readFileSync(savePath, "utf8"));
	let failed = false;
	for (const spec of poses) {
		const [name, rest] = spec.split(":");
		const f = rest.split(",");
		const pose = { x: +f[0], z: +f[1], yaw: +f[2], pitch: +f[3], mode: f[4] || "first", tick: +(f[5] || 1), day: opt.day };
		const walk = +(f[6] || 0);
		const prof = fs.mkdtempSync(path.join(os.tmpdir(), "gf-water-"));
		const args = ["--headless=new", "--no-sandbox", "--disable-dev-shm-usage", "--mute-audio", "--ignore-gpu-blocklist"]
			.concat(opt.swift ? ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"] : ["--enable-gpu", "--use-angle=default"]);
		const ctx = await chromium.launchPersistentContext(prof, { executablePath: opt.chrome, headless: false, args, viewport: { width: 1280, height: 720 } });
		try {
			const seed = await ctx.newPage();
			await seed.goto(new URL(url).origin + "/healthz", { timeout: 60000 });
			const save = withPose(base, pose);
			await seed.evaluate(async ({ dir, save }) => {
				const db = await new Promise((res, rej) => {
					const q = indexedDB.open("/userfs", 21);
					q.onupgradeneeded = () => { const s = q.result.createObjectStore("FILE_DATA"); s.createIndex("timestamp", "timestamp", { unique: false }); };
					q.onsuccess = () => res(q.result); q.onerror = () => rej(q.error);
				});
				const tx = db.transaction("FILE_DATA", "readwrite");
				const st = tx.objectStore("FILE_DATA");
				const now = new Date();
				for (const d of ["/userfs/godot", "/userfs/godot/app_userdata", dir]) st.put({ timestamp: now, mode: 16895 }, d);
				const enc = (t) => new Int8Array(new TextEncoder().encode(t).buffer.slice(0));
				st.put({ timestamp: now, mode: 33206, contents: enc(save) }, dir + "/gridfall_save.json");
				st.put({ timestamp: now, mode: 33206, contents: enc("{}") }, dir + "/feature_flags.json");
				await new Promise((res, rej) => { tx.oncomplete = res; tx.onerror = () => rej(tx.error); });
				db.close();
			}, { dir: IDB_DIR, save });
			await seed.close();
			const page = await ctx.newPage();
			const log = [];
			page.on("console", (m) => log.push(m.text()));
			page.on("pageerror", (e) => log.push("PAGEERROR " + e));
			await page.goto(url, { timeout: 180000 });
			const t0 = Date.now();
			while (Date.now() - t0 < 300000 && !log.some((l) => /^GRIDFALL: boot complete$/.test(l))) await sleep(500);
			const gl = await page.evaluate(() => {
				const c = document.createElement("canvas").getContext("webgl2");
				const e = c && c.getExtension("WEBGL_debug_renderer_info");
				return c ? (e ? c.getParameter(e.UNMASKED_RENDERER_WEBGL) : c.getParameter(c.RENDERER)) : "no webgl2";
			});
			await sleep(opt.settle);
			await page.mouse.click(640, 360);
			await sleep(1500);
			await page.keyboard.press("F1");
			await sleep(800);
			if (walk > 0) { await page.keyboard.down("w"); await sleep(walk); await page.keyboard.up("w"); await sleep(300); }
			const png = await page.locator("canvas").first().screenshot();
			fs.writeFileSync(path.join(outdir, name + ".png"), png);
			const s = await patchStats(page, png, opt.patch);
			console.log(JSON.stringify({ shot: name, renderer: gl, ...s, errors: log.filter((l) => /PAGEERROR|SCRIPT ERROR/.test(l) && !/Pointer Lock/.test(l)).length }));
			if (opt.minStd > 0 && s.std < opt.minStd) { failed = true; console.error(`FAIL ${name}: luminance spread ${s.std} < ${opt.minStd}`); }
		} finally {
			await ctx.close();
			fs.rmSync(prof, { recursive: true, force: true });
		}
	}
	process.exit(failed ? 1 : 0);
}

main().catch((e) => { console.error("ERR", e); process.exit(2); });
