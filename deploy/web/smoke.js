// GridFall web build smoke test: a real headless Chromium (SwiftShader WebGL2) against the
// dockerised Caddy serving build/web (docs/runbooks/web-deploy.md). Verifies: boot, the
// first-person city, the GMI Cloud key page (apply / remember / forget via localStorage), a
// bogus key actually being used for live calls (GMI_FAIL console lines, redacted; against a MOCK:
// it says nothing about CORS, see the NOTE in the ctx.route handler below), Save +
// reload keeping the IndexedDB save ("GRIDFALL: continuing the saved city"), quitting first
// person to the orbit overview and dropping back down without an uncaught exception
// (exit_fp once halted the web build on "invalid bus index -1"), and screenshots
// at every step; console.log and summary.json land in $GF_SMOKE_OUT (default: a gf-web-smoke
// folder in the system temp dir), shots under it in shots/.
//
// GF_SMOKE_OFFLINE=1 skips the key phases and installs no network mock: nothing is typed into
// the key page, no key is stored, nothing may reach api.gmi-serving.com (the mayors plan from
// the replay cache, then heuristics). Use it against a live deployment to prove the offline
// path without sending anything anywhere.
//
// usage: node deploy/web/smoke.js [url]      (default http://127.0.0.1:8080/)
// needs: a local Chrome/Chromium (CHROME path below), `npm i playwright-core` somewhere it can
//        be resolved, and the container running: docker run -p 8080:8080 gridfall-web
//
// The boot wait ends at the "GRIDFALL: boot complete" line (BootClock.finish: the first interactive
// frame plus three rendered ones, after the main-thread boot that follows the GPU banner), so the
// build under test must print it: against an image from before BootClock the run notices the GPU
// banner without BootClock's page marks and fails the boot checks at once instead of waiting out
// the 10 minutes. The run also checks that the game lifted the loader overlay itself
// (window.gfBootDone) instead of the page's 30 s timeout doing it, that startGame() resolved after
// the game's first frame (the engine ordering that timeout rests on), and that one GF_BOOT report
// line (stage timings, local console only) came with the boot.
//
// The run takes about 10 minutes (the ~186 MB .pck boots once, then reloads from the browser
// cache) and exits non-zero when any check fails.

const { chromium } = require("playwright-core");
const fs = require("fs");
const path = require("path");

const BASE_URL = process.argv[2] || "http://127.0.0.1:8080/";
const CHROME = "/usr/bin/google-chrome";
// Output goes outside the repo by default (nothing in this folder is committed).
const OUT = process.env.GF_SMOKE_OUT || path.join(require("os").tmpdir(), "gf-web-smoke");
const SHOTS = path.join(OUT, "shots");
fs.mkdirSync(SHOTS, { recursive: true });

const consoleLines = [];
const results = [];
function check(name, ok, detail = "") {
	results.push({ name, ok, detail });
	console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " (" + detail + ")" : ""}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Software WebGL can hold the main thread for seconds; a missed screenshot is not a failure.
async function shot(page, name) {
	try {
		await page.screenshot({ path: path.join(SHOTS, name), timeout: 120000 });
		console.log(`shot ${name}`);
	} catch (e) {
		console.log(`shot ${name} skipped (${String(e).split("\n")[0]})`);
	}
}

// The game is interactive: BootClock.finish prints this after the boot task and the first frames.
// The GPU banner and other GRIDFALL lines come before that task, so they are not a boot signal.
const BOOT_DONE_RE = /^GRIDFALL: boot complete$/;
const BOOT_REPORT_RE = /^GF_BOOT \{/;
const BANNER_RE = /GridFall GPU:/;
// How long to let a boot settle after its boot-complete line (audio beds, the first mayor turn).
const BOOT_SETTLE_MS = 25000;

// BootClock marks ready_begin (a gf:ready_begin entry on the page's timeline) before Main prints its
// GPU banner, so a banner without that mark is a build from before BootClock, which never prints the
// boot-complete line (or a page whose Content-Security-Policy blocks the marks).
let noBootClock = false;
async function bootClockMissing(page) {
	try {
		return !(await page.evaluate(() => performance.getEntriesByName("gf:ready_begin").length > 0));
	} catch (e) {
		return false;
	}
}

async function waitEngine(page, timeoutMs, extraSettleMs, since = 0) {
	const start = Date.now();
	let banner = false;
	while (Date.now() - start < timeoutMs) {
		const lines = consoleLines.slice(since);
		if (lines.some((l) => BOOT_DONE_RE.test(l.text))) {
			await sleep(extraSettleMs);
			return true;
		}
		if (!banner && lines.some((l) => BANNER_RE.test(l.text))) {
			banner = true;
			if (await bootClockMissing(page)) {
				noBootClock = true;
				await sleep(extraSettleMs);
				return false;
			}
		}
		await sleep(1000);
	}
	return false;
}

const KEY = "gmi_smoke_invalid_0000000000000000000000000000";
// Offline mode: no mock, no key ever typed, nothing may leave for api.gmi-serving.com.
const OFFLINE = process.env.GF_SMOKE_OFFLINE === "1";

(async () => {
	const browser = await chromium.launch({
		executablePath: CHROME,
		headless: true,
		args: [
			// Software WebGL2 so the test needs no GPU, exactly what a headless box has.
			"--use-angle=swiftshader",
			"--enable-unsafe-swiftshader",
			"--disable-dev-shm-usage",
			"--no-sandbox",
		],
	});
	const ctx = await browser.newContext({ viewport: { width: 1280, height: 720 } });
	const page = await ctx.newPage();
	page.on("console", (m) => {
		consoleLines.push({ type: m.type(), text: m.text() });
		if (m.type() === "error") console.log(`[console.error] ${m.text().slice(0, 300)}`);
	});
	page.on("pageerror", (e) => consoleLines.push({ type: "pageerror", text: String(e) }));
	// Bytes on the wire for the first load (encoded body sizes, so gzip counts as gzip).
	let wireBytes = 0;
	let countWire = true;
	page.on("requestfinished", async (req) => {
		if (!countWire) return;
		try {
			const s = await req.sizes();
			wireBytes += s.responseBodySize + s.responseHeadersSize;
		} catch (e) {}
	});
	// GMI calls go to a mock unless GF_SMOKE_OFFLINE=1: it records whether the Authorization
	// header carries the player's key (a boolean, never the value) and answers 401 so the game
	// takes its offline fallback. Offline mode installs no route and instead records that no
	// request to api.gmi-serving.com ever left the browser.
	const gmiCalls = [];
	const gmiRequests = [];
	page.on("request", (r) => {
		if (r.url().includes("api.gmi-serving.com")) gmiRequests.push(r.method() + " " + r.url());
	});
	if (!OFFLINE)
		await ctx.route("https://api.gmi-serving.com/**", async (route) => {
		const req = route.request();
		const auth = (await req.allHeaders())["authorization"] || "";
		gmiCalls.push({ method: req.method(), path: new URL(req.url()).pathname,
			hasAuth: auth.length > 0, playerKey: auth === `Bearer ${KEY}` });
		// NOTE: this allow-list is probably decorative, and nothing here has been observed to enforce it.
		// Read in playwright-core 1.64.0 (lib/coreBundle.js, the isInterceptedOptionsPreflight branch; the
		// same code is in 1.63.0 and 1.64.1, and in 1.57.0 it is lib/server/chromium/crNetworkManager.js;
		// which version this script resolves on the machine that runs it is not recorded, and no run was
		// made to check): Playwright answers an
		// intercepted CORS preflight itself and echoes whatever Access-Control-Request-Headers asked
		// for, so the OPTIONS branch below would never run and a header GMI does not allow would never be
		// refused. If so this smoke proves nothing about CORS: it would pass while the client sent
		// User-Agent, X-Request-ID and X-Trace-ID, which GMI's real preflight does not list (measured
		// 2026-11-03). The recorded smokes (2026-10-28, 2026-11-03) ran with GF_SMOKE_OFFLINE=1, where
		// no route is installed at all. Check the preflight and the deployed build with
		// tools/demo_check.sh and the key path with the in-game Test button (docs/runbooks/web-deploy.md,
		// "Verify the key path").
		const cors = { "access-control-allow-origin": "*",
			"access-control-allow-headers": "authorization, content-type" };
		if (req.method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors });
		return route.fulfill({ status: 401, headers: { ...cors, "content-type": "application/json" },
			body: JSON.stringify({ error: { message: "invalid api key (smoke mock)" } }) });
	});

	// --- phase 1: boot -----------------------------------------------------------
	const t0 = Date.now();
	await page.goto(BASE_URL, { waitUntil: "domcontentloaded", timeout: 60000 });
	const canvas = await page.waitForSelector("canvas", { timeout: 60000 });
	check("canvas present", canvas !== null);
	const booted = await waitEngine(page, 600000, BOOT_SETTLE_MS);
	check("engine booted (console activity)", booted,
		booted ? `${((Date.now() - t0 - BOOT_SETTLE_MS) / 1000).toFixed(0)}s to "GRIDFALL: boot complete"`
			: noBootClock ? "GPU banner without BootClock's gf:ready_begin mark: a build from before BootClock (or marks blocked by a CSP)"
				: 'no "GRIDFALL: boot complete" line');
	const reports = consoleLines.filter((l) => BOOT_REPORT_RE.test(l.text));
	let boot = null;
	try { boot = JSON.parse(reports[0].text.slice("GF_BOOT ".length)); } catch (e) {}
	check("one GF_BOOT report line with the stage marks", reports.length === 1 && boot !== null
		&& boot.v === 1 && Array.isArray(boot.marks) && boot.marks.length > 10,
		boot ? `${boot.marks.length} marks, ${(boot.total_ms / 1000).toFixed(1)}s first mark to last` : `${reports.length} lines`);
	// gf:veil_frames is BootClock's last mark, taken just before it calls the hook; gf:veil_released
	// is the page lifting the overlay (the page marks only its first release, so a hook call after
	// its timeout changes nothing). The hook's release lands right after the first (never before it);
	// the page's timeout lands before it (the frames were slow) or about 30 s after startGame().
	const veil = await page.evaluate(() => {
		const at = (n) => { const e = performance.getEntriesByName(n); return e.length ? e[0].startTime : null; };
		return {
			overlay: document.getElementById("status") !== null, frames: at("gf:veil_frames"), released: at("gf:veil_released"),
			first: at("gf:first_frame"), resolved: at("gf:start_game_resolved"),
		};
	});
	check("the game lifted the loader overlay (window.gfBootDone), not the timeout",
		!veil.overlay && veil.frames !== null && veil.released !== null
			&& veil.released >= veil.frames && veil.released - veil.frames < 5000,
		JSON.stringify(veil));
	// The engine ordering the page's 30 s veil timeout rests on: Godot's web main() runs the first
	// main-loop iteration (Main._ready and the first frame) inside callMain, so startGame() resolves
	// after the game's first frame and the timeout only has to cover the three veil frames. That is a
	// fact about the engine binary that no CI job can see (it needs a web build), so every full run
	// checks it: if a Godot update moves the boot task after the resolve, re-measure the timeout.
	check("startGame() resolved after the game's first frame (the premise of the page's veil timeout)",
		veil.first !== null && veil.resolved !== null && veil.resolved >= veil.first, JSON.stringify(veil));
	const coiCold = await page.evaluate(() => crossOriginIsolated);
	check("cross-origin isolated after cold load (threads)", coiCold === true,
		`crossOriginIsolated=${coiCold}`);
	await shot(page, "01-boot.png");
	countWire = false;
	console.log(`first load on the wire: ${(wireBytes / 1e6).toFixed(1)} MB`);
	check("first load fetched the game (wire bytes)", booted && wireBytes > 1e6, `${(wireBytes / 1e6).toFixed(1)} MB`);

	// Click the canvas once (pointer lock / audio unlock), walk a few steps.
	await page.mouse.click(640, 360);
	await sleep(1500);
	await page.keyboard.down("w");
	await sleep(3000);
	await page.keyboard.up("w");
	await page.keyboard.down("d");
	await sleep(2000);
	await page.keyboard.up("d");
	await sleep(2000);
	await shot(page, "02-city-walk.png");

	// --- phase 2: pause menu -> settings -> GMI Cloud tab --------------------------
	await page.keyboard.press("Escape");
	await sleep(1200);
	await shot(page, "03-pause.png");
	await page.keyboard.press("ArrowDown");
	await page.keyboard.press("ArrowDown");
	await page.keyboard.press("ArrowDown");
	await page.keyboard.press("ArrowDown");
	await page.keyboard.press("Enter"); // Settings (opens on the Camera tab)
	await sleep(1200);
	await shot(page, "04-settings.png");
	await page.keyboard.press("Shift+Tab"); // header pills sit before the page: GMI Cloud is last
	await page.keyboard.press("Enter");
	await sleep(1200);
	await shot(page, "05-gmi-tab.png");

	// --- offline mode: leave the key page empty, watch the mayors plan offline ------------
	if (OFFLINE) {
		await shot(page, "06-offline-key-empty.png");
		// An Esc inside the focused key field is swallowed, so move focus to Apply first (Tab
		// only moves focus, it applies nothing); then Esc closes the page and Esc resumes.
		await page.keyboard.press("Tab");
		await sleep(300);
		await page.keyboard.press("Escape");
		await sleep(600);
		await page.keyboard.press("Escape");
		await sleep(1500);
		for (let i = 0; i < 4; i++) {
			await page.keyboard.press("BracketRight");
			await sleep(300);
		}
		await shot(page, "10-resumed.png");
		console.log("waiting 120s of mayor turns; nothing may reach api.gmi-serving.com");
		const offlineDeadline = Date.now() + 120000;
		while (Date.now() < offlineDeadline) await sleep(5000);
		check("mayors ran offline (no api.gmi-serving.com request)", gmiRequests.length === 0,
			`${gmiRequests.length} requests seen`);
		check("no key stored on the device",
			(await page.evaluate(() => localStorage.getItem("gridfall.gmi_key"))) === null);
		await shot(page, "11-offline-mayors.png");
	}
	if (!OFFLINE) {
	// --- phase 3: apply a bogus key (Remember Off) ---------------------------------
	await page.keyboard.type(KEY, { delay: 20 });
	await sleep(500);
	await shot(page, "06-key-typed.png");
	await page.keyboard.press("Tab"); // input -> Apply
	await page.keyboard.press("Enter");
	await sleep(1200);
	const lsAfterApply = await page.evaluate(() => ({
		key: localStorage.getItem("gridfall.gmi_key"),
		consent: localStorage.getItem("gridfall.gmi_key.remember"),
	}));
	check("Apply with Remember off stores nothing", lsAfterApply.key === null && lsAfterApply.consent === null,
		JSON.stringify(lsAfterApply));
	await shot(page, "07-applied-norem.png");

	// --- phase 4: remember it ------------------------------------------------------
	await page.keyboard.press("Shift+Tab"); // Apply -> input
	await page.keyboard.press("Control+a");
	await page.keyboard.type(KEY, { delay: 20 });
	await page.keyboard.press("Tab"); // input -> Apply
	await page.keyboard.press("Tab"); // Apply -> Forget
	await page.keyboard.press("Tab"); // Forget -> Remember Off
	await page.keyboard.press("Tab"); // Off -> On
	await page.keyboard.press("Enter"); // toggle On
	await page.keyboard.press("Shift+Tab"); // On -> Off
	await page.keyboard.press("Shift+Tab"); // Off -> Forget
	await page.keyboard.press("Shift+Tab"); // Forget -> Apply
	await page.keyboard.press("Enter"); // Apply (Remember on)
	await sleep(1200);
	const lsRemember = await page.evaluate(() => ({
		key: localStorage.getItem("gridfall.gmi_key"),
		consent: localStorage.getItem("gridfall.gmi_key.remember"),
	}));
	check("Apply with Remember on stores the key", lsRemember.key !== null && lsRemember.key.startsWith("gmi_smoke")
		&& lsRemember.consent === "1", JSON.stringify(lsRemember));
	await shot(page, "08-remembered.png");

	// --- phase 5: forget -----------------------------------------------------------
	await page.keyboard.press("Tab"); // Apply -> Forget
	await page.keyboard.press("Enter");
	await sleep(800);
	const lsForgot = await page.evaluate(() => ({
		key: localStorage.getItem("gridfall.gmi_key"),
		consent: localStorage.getItem("gridfall.gmi_key.remember"),
	}));
	check("Forget clears the device copy", lsForgot.key === null && lsForgot.consent === null,
		JSON.stringify(lsForgot));
	await shot(page, "09-forgotten.png");

	// --- phase 6: leave it remembered for the live-call + reload test --------------
	await page.keyboard.press("Shift+Tab"); // Forget -> Apply
	await page.keyboard.press("Shift+Tab"); // Apply -> input
	await page.keyboard.type(KEY, { delay: 20 });
	await page.keyboard.press("Tab"); // input -> Apply
	await page.keyboard.press("Tab"); // -> Forget
	await page.keyboard.press("Tab"); // -> Off
	await page.keyboard.press("Tab"); // -> On
	await page.keyboard.press("Enter"); // On
	await page.keyboard.press("Shift+Tab");
	await page.keyboard.press("Shift+Tab");
	await page.keyboard.press("Shift+Tab"); // back to Apply
	await page.keyboard.press("Enter"); // Apply (remembered)
	await sleep(800);
	const lsFinal = await page.evaluate(() => localStorage.getItem("gridfall.gmi_key"));
	check("key remembered for the live-call phase", lsFinal !== null && lsFinal.startsWith("gmi_smoke"));

	// Focus is on Apply (not the field): the first Esc closes the settings page, the second
	// resumes the game. A third would pause it again and stop the mayors' clock.
	await page.keyboard.press("Escape");
	await sleep(600);
	await page.keyboard.press("Escape");
	await sleep(1500);
	// Software WebGL runs a few frames a second; "]" raises the game speed so the first mayor's
	// turn arrives inside the wait below.
	for (let i = 0; i < 4; i++) {
		await page.keyboard.press("BracketRight");
		await sleep(300);
	}
	await shot(page, "10-resumed.png");

	// --- phase 7: wait for the mayors to call with the bogus key --------------------
	// The first mayor's turn comes a couple of game minutes into day 1.
	console.log("waiting up to 240s for a live mayor call with the bogus key...");
	const failStart = consoleLines.length;
	const failDeadline = Date.now() + 240000;
	while (Date.now() < failDeadline) {
		if (consoleLines.slice(failStart).some((l) => /GMI_FAIL/i.test(l.text))) break;
		if (gmiCalls.some((c) => c.method === "POST") && Date.now() > failDeadline - 200000) break;
		await sleep(5000);
	}
	const gmiFails = consoleLines.filter((l) => /GMI_FAIL/i.test(l.text));
	const posts = gmiCalls.filter((c) => c.method === "POST");
	check("a live call reaches api.gmi-serving.com with the player's key",
		posts.length > 0 && posts.every((c) => c.playerKey),
		`${posts.length} POSTs to ${[...new Set(posts.map((c) => c.path))].join(",") || "-"}`);
	check("the rejected call falls back (GMI_FAIL console line)", gmiFails.length > 0,
		`${gmiFails.length} lines, first: ${gmiFails[0] ? gmiFails[0].text.slice(0, 140) : "none"}`);
	check("no raw key in any console line",
		!consoleLines.some((l) => l.text.includes(KEY)), "redaction held");
	await shot(page, "11-offline-fallback.png");
	} // end of the keyed (non-offline) phases

	// --- phase 8: save, reload, prove the save survived -----------------------------
	await page.keyboard.press("Escape");
	await sleep(1000);
	await page.keyboard.press("ArrowDown"); // Resume -> Save
	await page.keyboard.press("Enter");
	// Godot syncs user:// to IndexedDB asynchronously after the file closes.
	await sleep(6000);
	await shot(page, "12-saved.png");
	const lsBeforeReload = await page.evaluate(() => localStorage.getItem("gridfall.gmi_key"));

	const reloadStart = consoleLines.length;
	await page.reload({ waitUntil: "domcontentloaded" });
	const reloaded = await waitEngine(page, 600000, BOOT_SETTLE_MS, reloadStart);
	check("engine booted again after reload", reloaded);
	const coiReload = await page.evaluate(() => crossOriginIsolated);
	check("cross-origin isolated after reload (threads)", coiReload === true,
		`crossOriginIsolated=${coiReload}`);
	// The "continuing" line prints only after the IDBFS mount resolves, which can lag the
	// boot banner by many seconds on a loaded box; give it a grace window before judging.
	const continuingDeadline = Date.now() + 60000;
	let continuing = [];
	while (Date.now() < continuingDeadline) {
		continuing = consoleLines.slice(reloadStart).filter((l) => /GRIDFALL: continuing the saved city/i.test(l.text));
		if (continuing.length > 0) break;
		await sleep(2000);
	}
	check("reload continues the saved city (IndexedDB persisted)", continuing.length > 0,
		continuing[0] ? continuing[continuing.length - 1].text : "no line");
	const lsAfterReload = await page.evaluate(() => ({
		key: localStorage.getItem("gridfall.gmi_key"),
		consent: localStorage.getItem("gridfall.gmi_key.remember"),
	}));
	if (!OFFLINE)
		check("remembered key survived the reload",
			lsAfterReload.key === lsBeforeReload && lsAfterReload.consent === "1", JSON.stringify(lsAfterReload));
	await sleep(5000);
	await shot(page, "13-reloaded.png");

	// --- phase 9: quit to orbit and back (exit_fp / enter_fp must not throw) ----------
	// exit_fp() teardown once crashed the web build ("invalid bus index -1" in
	// sample_set_volumes_linear) and halted the game, so keep the round trip under test.
	// Pause menu order is Resume, Save, Load, New city, Settings, Planner view, Quit.
	// The pointer-lock NotAllowedError is an automation artifact: real keyboards count as
	// user gestures, but CDP-injected keys may not re-lock the pointer in headless Chrome.
	const crashRe = /bus index|SCRIPT ERROR|unreachable|uncaught/i;
	const artifactRe = /Pointer Lock/;
	const fpExitStart = consoleLines.length;
	await page.keyboard.press("Escape"); // pause menu (focus starts on Resume)
	await sleep(1200);
	for (let i = 0; i < 5; i++) {
		await page.keyboard.press("ArrowDown"); // Resume -> ... -> Planner view
		await sleep(150);
	}
	await page.keyboard.press("Enter");
	await sleep(4000); // exit_fp is call_deferred; let the teardown and audio settle
	await shot(page, "14-orbit.png");
	const fpExitBad = consoleLines.slice(fpExitStart).filter(
		(l) => (l.type === "pageerror" || crashRe.test(l.text)) && !artifactRe.test(l.text));
	check("quit to orbit (exit_fp) throws no uncaught exception", fpExitBad.length === 0,
		fpExitBad.slice(0, 2).map((e) => e.text.slice(0, 120)).join(" | ") || "clean");
	// Tab in the orbit view re-enters first person (main.gd _unhandled_input).
	const fpEnterStart = consoleLines.length;
	await page.keyboard.press("Tab");
	await sleep(4000);
	await shot(page, "15-back-on-street.png");
	const fpEnterBad = consoleLines.slice(fpEnterStart).filter(
		(l) => (l.type === "pageerror" || crashRe.test(l.text)) && !artifactRe.test(l.text));
	check("Tab back to the street (enter_fp) stays clean", fpEnterBad.length === 0,
		fpEnterBad.slice(0, 2).map((e) => e.text.slice(0, 120)).join(" | ") || "clean");

	// --- wrap up --------------------------------------------------------------------
	// Engine warnings (push_warning, and their "at:" lines) also arrive as console.error.
	const errors = consoleLines.filter(
		(l) => l.type === "error" && !/GMI_FAIL|favicon|AudioContext|^WARNING:|^\s+at: |status of 401/i.test(l.text));
	check("no unexpected console errors", errors.length === 0,
		errors.slice(0, 3).map((e) => e.text.slice(0, 120)).join(" | ") || "clean");
	fs.writeFileSync(
		path.join(OUT, "console.log"),
		consoleLines.map((l) => `[${l.type}] ${l.text}`).join("\n"));
	fs.writeFileSync(path.join(OUT, "summary.json"),
		JSON.stringify({ results, wireBytes, gmiCalls, boot }, null, 2));
	const bad = results.filter((r) => !r.ok).length;
	console.log(`\nSMOKE: ${bad === 0 ? "PASS" : "FAIL"} (${results.length - bad}/${results.length} checks)`);
	await browser.close();
	process.exit(bad === 0 ? 0 : 1);
})().catch((e) => {
	console.error("SMOKE: ERROR", e);
	fs.writeFileSync(path.join(OUT, "summary.json"), JSON.stringify(results, null, 2));
	process.exit(2);
});
