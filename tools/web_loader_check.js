// Browser check of the patched loader page (tools/web_export.py, patch_loader_html): Godot's real web
// shell with the patch applied and a stub Engine in place of godot.js, in headless Chrome on a fake
// clock. Proves the overlay stays up after startGame() resolves until the game calls
// window.gfBootDone(), that a game which never calls it loses the overlay at the page's timeout,
// that a throwing UI update (with or without the hook), a release that throws, an early hook call
// and a hidden tab (no frames) cannot leave it stuck,
// that a failed start shows the failure notice instead of a "starting" bar, that a start which never
// settles (a wasm that fails to download or compile, which godot.js has no reject path for, or a
// download that hangs before its first byte) shows the reload hint after START_STALL_MS instead of a
// bar or spinner that looks alive, and that the engine start waits for a frame so the starting state
// is drawn before the boot takes the main thread.
// The fake clock is paused after install, so only the scripted steps move it and the result does not
// depend on how busy the machine is. It cannot show the engine itself (stub) or a real GPU compositor.
//
// usage: NODE_PATH=<dir with playwright-core> node tools/web_loader_check.js
// env:   CHROME   Chrome binary (default /usr/bin/google-chrome); always run with --headless=new
//        TMPDIR   keep it short (under about 60 characters): Chrome puts a socket under it and aborts
//                 with "Socket path too long" past 107 characters in all
//        GF_SHELL path to a godot.html template to patch instead of the installed one (default:
//                 godot.html in web_release.zip of the export templates, version in .godot-version)
//        GF_CHECK_LAG_MS  real milliseconds a loaded machine would add: the page's body arrives that
//                 long after its headers, and the first step of every scenario waits that long after
//                 the navigation. The fake clock is paused, so the result must not change (default 0).
// needs: python3 (the patch under test is the repo's own), the Godot export templates, Chrome.
const { chromium } = require("playwright-core");
const { execFileSync } = require("child_process");
const http = require("http");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const CHROME = process.env.CHROME || "/usr/bin/google-chrome";
const LAG_MS = Number(process.env.GF_CHECK_LAG_MS || 0);
let TIMEOUT_MS = 0; // BOOT_VEIL_TIMEOUT_MS of the patched page (tools/web_export.py), read in main
let STALL_MS = 0; // START_STALL_MS of the patched page, read in main

// The shell as the export would ship it: the repo's patch over the template, placeholders filled.
function patchedShell() {
	const code = `
import pathlib, sys, zipfile
sys.path.insert(0, ${JSON.stringify(ROOT)})
from tools.web_export import patch_loader_html
shell = ${JSON.stringify(process.env.GF_SHELL || "")}
if shell:
    html = pathlib.Path(shell).read_text()
else:
    version = pathlib.Path(${JSON.stringify(ROOT)}, ".godot-version").read_text().strip()
    zipped = pathlib.Path.home() / ".local/share/godot/export_templates" / version / "web_release.zip"
    html = zipfile.ZipFile(zipped).read("godot.html").decode()
sys.stdout.write(patch_loader_html(html))
`;
	const html = execFileSync("python3", ["-I", "-c", code], { encoding: "utf8" });
	const config = { executable: "index", fileSizes: {}, serviceWorker: "", args: [] };
	const fill = {
		$GODOT_PROJECT_NAME: "GridFall", $GODOT_SPLASH_COLOR: "#131722", $GODOT_HEAD_INCLUDE: "",
		$GODOT_SPLASH_CLASSES: "show-image--false fullsize--false use-filter--true",
		$GODOT_SPLASH: "index.png", $GODOT_URL: "index.js", $GODOT_CONFIG: JSON.stringify(config),
		$GODOT_THREADS_ENABLED: "false",
	};
	return html.replace(/\$GODOT_[A-Z_]+/g, (name) => (name in fill ? fill[name] : name));
}

// A stand-in for godot.js with the same shape: startGame() downloads, then calls this.start(), and
// start() is where the boot happens (it resolves when the first frame is drawn). Scenario options:
// ticks (progress ticks, default half then all of 1000 bytes), never (init never settles, as in
// godot.js when the wasm fails to download or compile: it has no reject path), initMs (init takes
// this long after the last byte before start() is called).
const STUB_ENGINE = `
class Engine {
	constructor(config) { this.config = config; }
	static getMissingFeatures() { return (window.__scenario || {}).missing || []; }
	installServiceWorker() { return Promise.resolve(); }
	startGame(override) {
		const me = this;
		const s = window.__scenario || {};
		window.__progress = override.onProgress;
		return new Promise((resolve) => setTimeout(resolve, 50)).then(() => {
			for (const [loaded, total] of s.ticks || [[500, 1000], [1000, 1000]]) override.onProgress(loaded, total);
			if (s.never) return new Promise(() => {});
			if (!s.initMs) return me.start.apply(me);
			return new Promise((resolve) => setTimeout(resolve, s.initMs)).then(() => me.start.apply(me));
		});
	}
	start() {
		const s = window.__scenario || {};
		window.__events.push("engine.start");
		return new Promise((resolve, reject) => setTimeout(
			() => (s.reject ? reject(new Error("engine boom")) : (window.__events.push("engine.done"), resolve())),
			s.bootMs || 100));
	}
}
`;

function serve(html) {
	return new Promise((resolve) => {
		const server = http.createServer((req, res) => {
			const page = req.url.split("?")[0];
			if (page === "/") {
				// Headers first, body LAG_MS later: a navigation that waits only for "commit" returns
				// before the page has run.
				res.writeHead(200, { "content-type": "text/html" });
				res.flushHeaders();
				setTimeout(() => res.end(html), LAG_MS);
			} else if (page === "/index.js") res.writeHead(200, { "content-type": "text/javascript" }).end(STUB_ENGINE);
			else res.writeHead(204).end();
		});
		server.listen(0, "127.0.0.1", () => resolve(server));
	});
}

const results = [];
function check(name, ok, detail = "") {
	results.push(ok);
	console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " (" + detail + ")" : ""}`);
}

// What a player could see: the overlay, its label, the bar and spinner, the failure notice.
const snapshot = (page) => page.evaluate(() => {
	const el = (id) => document.getElementById(id);
	// offsetParent is null when the element or an ancestor is display: none.
	const shown = (id) => (el(id) ? el(id).offsetParent !== null : false);
	const spin = el("gf-spin") ? getComputedStyle(el("gf-spin")) : null;
	return {
		overlay: !!el("status"), overlayShown: shown("status"),
		label: el("gf-label") ? el("gf-label").textContent : null,
		starting: !!el("gf-bar") && el("gf-bar").className.includes("gf-starting"),
		bar: shown("gf-bar"), spin: shown("gf-spin"), hint: shown("gf-hint"),
		notice: shown("status-notice") ? el("status-notice").textContent : "",
		events: window.__events, timers: window.__timers,
		spinAnimation: spin ? spin.animationName : null,
		arc: spin ? spin.borderTopColor : null, ring: spin ? spin.borderRightColor : null,
		releases: window.__marks.filter((name) => name === "gf:veil_released").length,
	};
});

// One scenario on a fresh page with a fake clock; init runs in the page before the shell does.
async function scenario(browser, url, config, init, body) {
	const ctx = await browser.newContext({ viewport: { width: 1280, height: 720 } });
	const page = await ctx.newPage();
	const problems = { errors: [], pageErrors: [] };
	page.on("console", (m) => { if (m.type() === "error") problems.errors.push(m.text()); });
	page.on("pageerror", (e) => problems.pageErrors.push(String(e)));
	// install() leaves the fake clock running in real time, so a busy machine would move it past the
	// scripted steps; pauseAt() freezes it and only step() moves time from here on.
	await page.clock.install({ time: 0 });
	await page.clock.pauseAt(1);
	await page.addInitScript(({ config, init }) => {
		window.__scenario = config;
		window.__events = [];
		window.__timers = [];
		// The fake clock replaces performance.mark with a stand-in that keeps no entries, so count the calls.
		window.__marks = [];
		const clockMark = performance.mark.bind(performance);
		performance.mark = (name, ...rest) => { window.__marks.push(name); return clockMark(name, ...rest); };
		const realSetTimeout = window.setTimeout;
		window.setTimeout = (fn, ms, ...rest) => { window.__timers.push(ms); return realSetTimeout(fn, ms, ...rest); };
		if (init) new Function(init)();
	}, { config, init });
	// domcontentloaded: the shell's inline scripts are parser-blocking, so they have run by then
	// (the hook exists, the stub engine is booting); "commit" returns before the page has run.
	await page.goto(url, { waitUntil: "domcontentloaded" });
	if (LAG_MS) await new Promise((resolve) => setTimeout(resolve, LAG_MS));
	await body(page, problems);
	await ctx.close();
}

const step = (page, ms) => page.clock.runFor(ms);

(async () => {
	const shell = patchedShell();
	TIMEOUT_MS = Number((/const BOOT_VEIL_TIMEOUT_MS = (\d+);/.exec(shell) || [])[1]);
	// The scenarios below wait 10 s after startGame() and expect the overlay to still be up.
	if (!(TIMEOUT_MS >= 20000)) throw new Error("BOOT_VEIL_TIMEOUT_MS missing from the patched shell, or under 20 s");
	STALL_MS = Number((/const START_STALL_MS = (\d+);/.exec(shell) || [])[1]);
	if (!(STALL_MS >= 20000)) throw new Error("START_STALL_MS missing from the patched shell, or under 20 s");
	const server = await serve(shell);
	const url = `http://127.0.0.1:${server.address().port}/`;
	// --headless=new explicitly: the new mode is the full browser with no window.
	const browser = await chromium.launch({ executablePath: CHROME, headless: false, args: ["--headless=new", "--no-sandbox"] });
	const run = (config, init, body) => scenario(browser, url, config, init, body);

	// 1. The overlay outlives startGame() and the hook releases it.
	await run({}, "", async (page, problems) => {
		await step(page, 60);
		let s = await snapshot(page);
		check("100% of bytes: the label says Starting your city, the spinner is on, the bar is full",
			s.label === "Starting your city" && s.starting && s.spin && s.bar, JSON.stringify([s.label, s.starting, s.spin]));
		check("the engine start waits for frames (the starting state is drawn first)", s.events.length === 0, JSON.stringify(s.events));
		await step(page, 60);
		s = await snapshot(page);
		check("after two frames the engine starts", s.events[0] === "engine.start", JSON.stringify(s.events));
		await step(page, 200);
		s = await snapshot(page);
		check("startGame() resolved and the overlay is still up", s.events.includes("engine.done") && s.overlay);
		check(`exactly one veil timeout is armed, at ${TIMEOUT_MS / 1000} s`, s.timers.filter((t) => t === TIMEOUT_MS).length === 1, JSON.stringify(s.timers));
		await step(page, 10000);
		check("10 s later the overlay is still up", (await snapshot(page)).overlay);
		await page.evaluate(() => window.gfBootDone());
		check("window.gfBootDone() removes the overlay", !(await snapshot(page)).overlay);
		check("no console or page errors", problems.errors.length + problems.pageErrors.length === 0, JSON.stringify(problems));
	});

	// 2. A game that never calls the hook: the timeout releases the overlay.
	await run({}, "", async (page) => {
		await step(page, 400);
		check("startGame() resolved, no hook call yet", (await snapshot(page)).events.includes("engine.done"));
		await step(page, TIMEOUT_MS - 1000);
		check("just before the timeout the overlay is still up", (await snapshot(page)).overlay);
		await step(page, 1500);
		check(`the ${TIMEOUT_MS / 1000} s timeout releases it`, !(await snapshot(page)).overlay);
	});

	// 3. A hook call before startGame() resolves: released at once, and no timeout is armed later.
	await run({ bootMs: 500 }, "", async (page, problems) => {
		await step(page, 200);
		await page.evaluate(() => window.gfBootDone());
		check("an early window.gfBootDone() removes the overlay", !(await snapshot(page)).overlay);
		await step(page, 600);
		const s = await snapshot(page);
		check("startGame() resolving afterwards arms no timeout", s.events.includes("engine.done") && !s.timers.includes(TIMEOUT_MS), JSON.stringify(s.timers));
		check("no errors from the late resolve", problems.errors.length + problems.pageErrors.length === 0);
	});

	// 4. A UI update that throws: the boot goes ahead, the veil is still released by the hook.
	await run({}, "Object.defineProperty(Element.prototype, 'classList', { get() { throw new Error('classList boom'); } });", async (page, problems) => {
		await step(page, 400);
		let s = await snapshot(page);
		check("a throwing UI update does not stop the engine or startGame()", s.events.includes("engine.done") && s.overlay);
		check("the throw is logged, not uncaught", problems.errors.some((e) => e.includes("classList boom")) && problems.pageErrors.length === 0, JSON.stringify(problems));
		check("the timeout was still armed", s.timers.includes(TIMEOUT_MS));
		await page.evaluate(() => window.gfBootDone());
		check("the hook still releases the overlay", !(await snapshot(page)).overlay);
	});

	// 4b. The same throwing UI update and a game that never calls the hook: the timeout lifts the overlay.
	await run({}, "Object.defineProperty(Element.prototype, 'classList', { get() { throw new Error('classList boom'); } });", async (page) => {
		await step(page, 400);
		check("a throwing UI update and no hook: the overlay is up once startGame() resolved", (await snapshot(page)).overlay);
		await step(page, TIMEOUT_MS + 500);
		check("a throwing UI update and no hook: the timeout lifts the overlay", !(await snapshot(page)).overlay);
	});

	// 4c. The release itself throws (remove() fails): its timer is spent, so the hook hides the overlay by hand.
	await run({}, "Element.prototype.remove = function () { throw new Error('remove boom'); };", async (page, problems) => {
		await step(page, 400);
		await page.evaluate(() => window.gfBootDone());
		const s = await snapshot(page);
		check("a release that throws still hides the overlay", !s.overlayShown, JSON.stringify([s.overlay, s.overlayShown]));
		check("the failure is logged, not uncaught", problems.errors.some((e) => e.includes("remove boom")) && problems.pageErrors.length === 0, JSON.stringify(problems));
	});

	// 5. A failed start: the failure notice replaces the bar, and nothing releases it behind the error.
	await run({ reject: true }, "", async (page) => {
		await step(page, 400);
		let s = await snapshot(page);
		check("a failed start shows the error notice and hides the bar and spinner",
			s.overlay && s.notice.includes("engine boom") && !s.bar && !s.spin, JSON.stringify([s.notice, s.bar, s.spin]));
		await page.evaluate(() => window.gfBootDone());
		await step(page, 2 * TIMEOUT_MS);
		s = await snapshot(page);
		check("neither the hook nor a timeout removes the error", s.overlay && s.notice.includes("engine boom") && !s.timers.includes(TIMEOUT_MS));
	});

	// 6. A browser without the required features: the notice shows at once, the engine never starts.
	await run({ missing: ["threads"] }, "", async (page) => {
		await step(page, 400);
		const s = await snapshot(page);
		check("missing features show the notice without a bar", s.overlay && s.notice.includes("threads") && !s.bar && s.events.length === 0, JSON.stringify(s));
	});

	// 7. A hidden tab makes no frames: the engine start is not held for them.
	await run({}, "window.requestAnimationFrame = () => 0;", async (page) => {
		await step(page, 200);
		check("without frames the start is still held (under 250 ms)", (await snapshot(page)).events.length === 0);
		await step(page, 300);
		check("without frames the start goes ahead after 250 ms", (await snapshot(page)).events.includes("engine.start"));
	});

	// 8. A late progress tick cannot put the loading label back.
	await run({}, "", async (page) => {
		await step(page, 400);
		await page.evaluate(() => { window.__progress(900, 1000); window.__progress(1000, 1000); });
		check("a late progress tick keeps Starting your city", (await snapshot(page)).label === "Starting your city");
	});

	// 9. Reduced motion swaps the spin for an opacity pulse.
	for (const [motion, want] of [["no-preference", "gf-spin"], ["reduce", "gf-pulse"]]) {
		await run({}, "", async (page) => {
			await page.emulateMedia({ reducedMotion: motion });
			await step(page, 400);
			const s = await snapshot(page);
			check(`prefers-reduced-motion ${motion}: the spinner uses ${want}`, s.spinAnimation === want, s.spinAnimation);
		});
	}

	// 10. 99.5% of the bytes is not "Starting your city": the label waits for the last byte.
	await run({ ticks: [[995, 1000]], never: true }, "", async (page) => {
		await step(page, 60);
		let s = await snapshot(page);
		check("99.5% of the bytes still says Loading GridFall 99%", s.label === "Loading GridFall 99%" && !s.starting && !s.spin, JSON.stringify([s.label, s.starting, s.spin]));
		await page.evaluate(() => window.__progress(1000, 1000));
		s = await snapshot(page);
		check("the last byte switches to Starting your city", s.label === "Starting your city" && s.starting && s.spin, JSON.stringify([s.label, s.starting, s.spin]));
	});

	// 11. No progress tick for START_STALL_MS before the engine starts (godot.js never rejects a wasm
	// that fails to download): a hint shows, and any progress takes it back.
	await run({ ticks: [[630, 1000]], never: true }, "", async (page) => {
		await step(page, 60);
		let s = await snapshot(page);
		check("a download at 63% shows its percentage and no hint", s.label === "Loading GridFall 63%" && !s.hint, JSON.stringify([s.label, s.hint]));
		await step(page, STALL_MS - 1000);
		check("just before the stall limit there is still no hint", !(await snapshot(page)).hint);
		await step(page, 1500);
		s = await snapshot(page);
		check(`${STALL_MS / 1000} s without a progress tick shows the reload hint`, s.hint && s.overlay && s.notice === "", JSON.stringify([s.hint, s.notice]));
		await page.evaluate(() => window.__progress(700, 1000));
		s = await snapshot(page);
		check("a progress tick takes the hint back", !s.hint && s.label === "Loading GridFall 70%", JSON.stringify([s.hint, s.label]));
	});

	// 12. The bytes are in and init never settles (a wasm that fails to compile): the hint replaces
	// the spinner, so the ring does not turn for ever over a dead boot.
	await run({ never: true }, "", async (page) => {
		await step(page, 60);
		const s = await snapshot(page);
		check("bytes in, init pending: Starting your city with the spinner on", s.label === "Starting your city" && s.spin && !s.hint, JSON.stringify([s.label, s.spin, s.hint]));
		await step(page, STALL_MS - 1000);
		check("just before the stall limit the spinner still turns", (await snapshot(page)).spin);
		await step(page, 1500);
		const late = await snapshot(page);
		check("past the stall limit the hint shows and the spinner stops", late.hint && !late.spin && late.label === "Starting your city" && late.overlay, JSON.stringify([late.hint, late.spin, late.label]));
	});

	// 13. A slow init that does finish: the engine starting takes the hint back, and a last progress tick
	// (rAF can run it after the engine start) arms nothing, so a long boot is never flagged.
	await run({ initMs: STALL_MS + 5000, bootMs: 3 * STALL_MS }, "", async (page) => {
		await step(page, STALL_MS + 1000);
		check("a slow init past the stall limit shows the hint", (await snapshot(page)).hint);
		await step(page, 5000);
		let s = await snapshot(page);
		check("the engine starting takes the hint back and the spinner returns", s.events.includes("engine.start") && !s.hint && s.spin, JSON.stringify([s.events, s.hint, s.spin]));
		await page.evaluate(() => window.__progress(1000, 1000));
		await step(page, 2 * STALL_MS);
		s = await snapshot(page);
		check("a progress tick after the engine started arms no new stall watch", !s.hint && s.spin && !s.events.includes("engine.done"), JSON.stringify([s.hint, s.spin, s.events]));
	});

	// 14. Forced colors (high contrast) give every border one colour; the arc must still differ from the ring.
	await run({}, "", async (page) => {
		await page.emulateMedia({ forcedColors: "active" });
		await step(page, 400);
		const s = await snapshot(page);
		check("forced colors: the spinner arc differs from the rest of the ring", s.spin && s.arc !== s.ring, JSON.stringify([s.arc, s.ring]));
	});

	// 15. The timeout lifts the overlay first and the game's hook arrives later: one release, at the timeout.
	await run({}, "", async (page) => {
		await step(page, 400);
		await step(page, TIMEOUT_MS + 500);
		check("the timeout released the overlay (one gf:veil_released mark)", (await snapshot(page)).releases === 1);
		await page.evaluate(() => window.gfBootDone());
		check("a hook call after the timeout adds no second release mark", (await snapshot(page)).releases === 1);
	});

	// 16. Nothing arrives at all (a download hangs before its first byte, so no progress tick ever
	// comes): the watch starts with the page, so the hint still shows.
	await run({ ticks: [], never: true }, "", async (page) => {
		await step(page, 60);
		let s = await snapshot(page);
		check("no tick at all: the loading label stays, no hint yet, no spinner", s.label === "Loading GridFall…" && !s.hint && !s.spin, JSON.stringify([s.label, s.hint, s.spin]));
		await step(page, STALL_MS - 1000);
		check("just before the stall limit there is still no hint", !(await snapshot(page)).hint);
		await step(page, 1500);
		s = await snapshot(page);
		check(`${STALL_MS / 1000} s without any tick shows the reload hint`, s.hint && s.overlay && s.notice === "", JSON.stringify([s.hint, s.notice]));
	});

	await browser.close();
	server.close();
	const bad = results.filter((ok) => !ok).length;
	console.log(`\nLOADER_CHECK: ${bad === 0 ? "PASS" : "FAIL"} (${results.length - bad}/${results.length} checks)`);
	process.exit(bad === 0 ? 0 : 1);
})().catch((e) => {
	console.error("LOADER_CHECK: ERROR", e);
	process.exit(2);
});
