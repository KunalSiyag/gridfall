// Web audio probe: does the browser build make a sound, with the autoplay policy ON and the output
// NOT muted? Every earlier web check ran with --autoplay-policy=no-user-gesture-required and
// --mute-audio, or filtered the AudioContext console lines, and so could not tell a silent game
// from a playing one: the web build shipped silent for every player because a bus added at runtime
// disconnected Master from the AudioContext destination (docs/runbooks/web-deploy.md, "Web audio").
//
// An init script (before the engine's first script) wraps AudioContext, routes its destination
// through a pass-through gain with an AnalyserNode, and samples the peak of what reaches the
// destination every 30 ms. The probe boots the game, clicks once, walks, and judges the run:
//   exit 0  the context is running and the destination peak passed PEAK_MIN within BOOT_WINDOW_S of
//           the boot ("GRIDFALL: boot complete")
//   exit 1  silent (peak never reached PEAK_MIN in the window, or in one phase) or the context is not running
//           and, after that, the destination was audible in EVERY phase of the run (street idle, walking,
//           the pause menu, the Planner view, back in first person, walking again): a regression that
//           goes silent only after the first-person feature starts, after exit_fp or while moving
//           cannot hide behind the boot stems, which alone satisfy the global peak
//   exit 2  bad usage, the page never booted, or the probe crashed
//   exit 3  --suspend mode only: the "Sound is off - click or press any key" banner did not show
//           while the context was held suspended, or a gesture did not resume it and hide the banner
//
// usage: NODE_PATH=<dir with playwright-core> node tools/web_audio_probe.js <url> <outdir> [--suspend] [--gpu]
//   --suspend  holds the context suspended (the page's own resume() is refused until a real gesture) to
//              prove the banner and the gesture resume, a case a headless Chrome never hits by itself
//   --gpu      --enable-gpu --use-angle=default (default: SwiftShader, which is enough for audio)
// env: GF_AUDIO_CHROME=<binary> (default /usr/bin/google-chrome, else /opt/google/chrome/chrome)
//      GF_AUDIO_POLICY=<autoplay policy> (default document-user-activation-required)
//      GF_AUDIO_PROFILE=<dir> (default: a temp dir, removed)   GF_AUDIO_BOOT_S=<max boot wait, default 480>
// The output is <outdir>/audio-result.json and one AUDIO_PROBE line per phase.
"use strict";

const PEAK_MIN = 0.01;
const BOOT_WINDOW_S = 20;

// ---------------------------------------------------------------------------------------------
// Pure: the verdict from the phases. Tested by tools/tests/web_audio_probe.test.js.
// ---------------------------------------------------------------------------------------------

// res: { state, peak_max, first_peak_s (seconds after boot the destination first passed PEAK_MIN, or null),
//        phases (optional): [{ label, peak, samples }] the peak of each phase's own window }
// suspend: null, or { banner_shown, banner_hidden_after_gesture, state_after_gesture }
function judge(res) {
	const why = [];
	if (!res.booted) return { code: 2, why: ["the game never reached 'boot complete'"] };
	if (res.suspend) {
		const s = res.suspend;
		if (!s.banner_shown) why.push("no 'Sound is off' banner while the context was suspended");
		if (s.state_after_gesture !== "running") why.push("a gesture did not resume the context (" + s.state_after_gesture + ")");
		if (!s.banner_hidden_after_gesture) why.push("the banner stayed up after the context ran");
		return { code: why.length ? 3 : 0, why };
	}
	if (res.state !== "running") why.push("the AudioContext is " + res.state + ", not running");
	if (!(res.peak_max >= PEAK_MIN)) why.push("silent: destination peak " + Number(res.peak_max).toFixed(5) + " < " + PEAK_MIN);
	else if (res.first_peak_s === null || res.first_peak_s > BOOT_WINDOW_S) why.push("sound only came " + res.first_peak_s + " s after boot (limit " + BOOT_WINDOW_S + " s)");
	for (const p of res.phases || []) {
		if (!(p.peak >= PEAK_MIN)) why.push("silent in phase '" + p.label + "': peak " + Number(p.peak).toFixed(5) + " < " + PEAK_MIN);
	}
	return { code: why.length ? 1 : 0, why };
}

// ---------------------------------------------------------------------------------------------
// In-page half: serialised with toString() and run before the engine's first script.
// ---------------------------------------------------------------------------------------------

function initScript(opts) {
	const A = (window.__gfAudio = { ctxs: [], win: { peak: 0, samples: 0 }, peak: 0, firstPeakAt: null, samples: 0, nonzero: 0, held: !!opts.suspend, allow: false, log: [] });
	const note = (...a) => { if (A.log.length < 200) A.log.push([Math.round(performance.now()), ...a]); };
	const Native = window.AudioContext;
	if (!Native) return;
	window.AudioContext = class extends Native {
		constructor(...args) {
			super(...args);
			const an = this.createAnalyser();
			an.fftSize = 2048;
			const tap = this.createGain();
			tap.connect(this.destination);
			tap.connect(an);
			const real = this.destination;
			// Everything the game connects to "destination" now passes the tap first.
			Object.defineProperty(this, "destination", { get: () => tap, configurable: true });
			A.ctxs.push({ ctx: this, an, real });
			note("ctx_new", "state=" + this.state, "sr=" + this.sampleRate);
			this.addEventListener("statechange", () => note("statechange", this.state));
			if (A.held) {
				this.suspend().catch(() => {});
				const resume = this.resume.bind(this);
				this.resume = () => (A.allow ? resume() : Promise.resolve());
			}
		}
	};
	// A real gesture lets a held context resume (this listener runs before the page's own).
	for (const t of ["pointerdown", "keydown"]) {
		window.addEventListener(t, () => { A.allow = true; note("gesture", t); }, true);
	}
	const buf = new Float32Array(2048);
	setInterval(() => {
		for (const c of A.ctxs) {
			try {
				c.an.getFloatTimeDomainData(buf);
				let p = 0;
				for (let i = 0; i < buf.length; i++) { const v = Math.abs(buf[i]); if (v > p) p = v; }
				A.samples++;
				A.win.samples++;
				if (p > A.win.peak) A.win.peak = p;
				if (p > 0) A.nonzero++;
				if (p > A.peak) A.peak = p;
				if (p >= opts.peakMin && A.firstPeakAt === null) A.firstPeakAt = performance.now();
			} catch (e) { /* context closed */ }
		}
	}, 30);
	// The peak since the last call: one phase's window.
	window.__gfAudioWindow = () => { const w = A.win; A.win = { peak: 0, samples: 0 }; return w; };
	window.__gfAudioState = () => A.ctxs.map((c) => c.ctx.state);
}

// ---------------------------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------------------------

async function main() {
	const fs = require("fs");
	const os = require("os");
	const path = require("path");
	const args = process.argv.slice(2);
	const flags = args.filter((a) => a.startsWith("--"));
	const pos = args.filter((a) => !a.startsWith("--"));
	const suspend = flags.includes("--suspend");
	const gpu = flags.includes("--gpu");
	if (pos.length < 2 || flags.some((f) => !["--suspend", "--gpu"].includes(f))) {
		console.error("usage: node tools/web_audio_probe.js <url> <outdir> [--suspend] [--gpu]");
		return 2;
	}
	const [url, out] = pos;
	fs.mkdirSync(out, { recursive: true });
	const { chromium } = require("playwright-core");
	const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
	let chrome = process.env.GF_AUDIO_CHROME || "/usr/bin/google-chrome";
	if (!process.env.GF_AUDIO_CHROME && !fs.existsSync(chrome)) chrome = "/opt/google/chrome/chrome";
	const policy = process.env.GF_AUDIO_POLICY || "document-user-activation-required";
	const chromeArgs = ["--no-sandbox", "--disable-dev-shm-usage", "--headless=new", "--ignore-gpu-blocklist",
		"--no-first-run", "--autoplay-policy=" + policy];
	chromeArgs.push(...(gpu ? ["--enable-gpu", "--use-angle=default"] : ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"]));
	const profile = process.env.GF_AUDIO_PROFILE || fs.mkdtempSync(path.join(os.tmpdir(), "gf-audio-profile-"));
	const ownProfile = !process.env.GF_AUDIO_PROFILE;
	// --mute-audio is playwright's default for a launched browser: this probe is about what is audible.
	const ctx = await chromium.launchPersistentContext(profile, {
		executablePath: chrome, headless: false, args: chromeArgs, ignoreDefaultArgs: ["--mute-audio"],
		viewport: { width: 1280, height: 720 },
	});
	const cleanup = async () => {
		try { await ctx.close(); } catch (e) { /* closed */ }
		if (ownProfile) fs.rmSync(profile, { recursive: true, force: true });
	};
	const result = { url, policy, suspend, chrome, booted: false };
	try {
		// One page only: extra tabs (chrome://gpu, a seed page) leave the game page in the background,
		// where Chrome throttles its timers and the run hangs.
		const page = ctx.pages()[0] || (await ctx.newPage());
		await page.bringToFront();
		const logs = [];
		const t0 = Date.now();
		const stamp = () => ((Date.now() - t0) / 1000).toFixed(1);
		page.on("console", (m) => logs.push(stamp() + " [" + m.type() + "] " + m.text()));
		page.on("pageerror", (e) => logs.push(stamp() + " [pageerror] " + e.message));
		await page.addInitScript(initScript, { suspend, peakMin: PEAK_MIN });
		await page.goto(url, { waitUntil: "domcontentloaded", timeout: 120000 });
		const bootWaitS = Number(process.env.GF_AUDIO_BOOT_S || 480);
		while ((Date.now() - t0) / 1000 < bootWaitS && !logs.some((l) => /GRIDFALL: boot complete/.test(l))) await sleep(1000);
		result.booted = logs.some((l) => /GRIDFALL: boot complete/.test(l));
		result.boot_s = Number(stamp());
		if (!result.booted) {
			fs.writeFileSync(path.join(out, "console.log"), logs.join("\n"));
			fs.writeFileSync(path.join(out, "audio-result.json"), JSON.stringify(result, null, 2));
			console.log("AUDIO_PROBE boot failed after " + stamp() + " s");
			await cleanup();
			return 2;
		}
		const bootPage = await page.evaluate(() => performance.now());
		const read = () => page.evaluate(() => ({
			states: window.__gfAudioState ? window.__gfAudioState() : [],
			gf: typeof window.gfAudioState === "function" ? window.gfAudioState() : null,
			peak: window.__gfAudio.peak, first: window.__gfAudio.firstPeakAt, samples: window.__gfAudio.samples,
			nonzero: window.__gfAudio.nonzero,
			banner: (() => { const b = document.getElementById("gf-sound"); return !!b && b.classList.contains("gf-on") && getComputedStyle(b).display !== "none"; })(),
			active: navigator.userActivation ? navigator.userActivation.hasBeenActive : null,
		}));
		const phase = async (label) => {
			const r = await read();
			console.log("AUDIO_PROBE " + stamp() + " " + label + " " + JSON.stringify(r));
			return r;
		};
		await sleep(6000);
		const pre = await phase("boot+6s before any gesture");
		result.before_gesture = pre;
		if (suspend) {
			// Banner due AUDIO_GRACE_MS after the veil lifted: it was lifted at boot complete.
			let shown = pre.banner;
			for (let i = 0; i < 10 && !shown; i++) { await sleep(1000); shown = (await read()).banner; }
			await page.screenshot({ path: path.join(out, "banner.png") });
			await page.mouse.click(640, 360);
			let after = await read();
			for (let i = 0; i < 10 && (after.gf !== "running" || after.banner); i++) { await sleep(500); after = await read(); }
			await page.screenshot({ path: path.join(out, "banner-after-click.png") });
			result.suspend = { banner_shown: shown, state_after_gesture: after.gf, banner_hidden_after_gesture: !after.banner };
			console.log("AUDIO_PROBE suspend " + JSON.stringify(result.suspend));
		} else {
			// Each window is judged on its own peak (judge): the context's global peak is satisfied by the boot stems.
			const phases = [];
			const window_ = async (label, act, ms) => {
				await page.evaluate(() => window.__gfAudioWindow());
				if (act) await act();
				await sleep(ms);
				const w = await page.evaluate(() => window.__gfAudioWindow());
				phases.push({ label, peak: Math.round(w.peak * 1e4) / 1e4, samples: w.samples });
				console.log("AUDIO_PROBE " + stamp() + " phase " + JSON.stringify(phases[phases.length - 1]));
			};
			await page.mouse.click(640, 360);
			await sleep(1500);
			await phase("click+1.5s");
			await window_("street idle", null, 5000);
			await window_("walking", () => page.keyboard.down("w"), 6000);
			await page.keyboard.up("w");
			await window_("pause menu", () => page.keyboard.press("Escape"), 3000);
			// Resume, Save, Load, New city, Settings, Planner view: five steps down from Resume.
			for (let i = 0; i < 5; i++) { await page.keyboard.press("ArrowDown"); await sleep(150); }
			await page.screenshot({ path: path.join(out, "pause.png") }).catch(() => {});
			await window_("Planner view", () => page.keyboard.press("Enter"), 10000);
			await page.screenshot({ path: path.join(out, "planner.png") }).catch(() => {});
			await window_("back in first person", () => page.keyboard.press("Tab"), 8000);
			await window_("walking again", () => page.keyboard.down("w"), 5000);
			await page.keyboard.up("w");
			result.phases = phases;
		}
		const end = await phase("end");
		result.state = end.gf || (end.states[0] || "none");
		result.peak_max = end.peak;
		result.first_peak_s = end.first === null ? null : Math.round((end.first - bootPage) / 100) / 10;
		result.samples = end.samples;
		result.nonzero_samples = end.nonzero;
		result.log = await page.evaluate(() => window.__gfAudio.log);
		result.bus_warnings = logs.filter((l) => /audio bus .* not in the default layout|invalid bus index/.test(l));
		await page.screenshot({ path: path.join(out, "end.png") }).catch(() => {});
		fs.writeFileSync(path.join(out, "console.log"), logs.join("\n"));
		const verdict = judge(result);
		result.verdict = verdict;
		fs.writeFileSync(path.join(out, "audio-result.json"), JSON.stringify(result, null, 2));
		console.log("AUDIO_PROBE " + (verdict.code === 0 ? "PASS" : "FAIL") + " peak=" + Number(result.peak_max).toFixed(4)
			+ " first=" + (result.first_peak_s === null ? "never" : result.first_peak_s + "s after boot") + " state=" + result.state + (verdict.why.length ? " : " + verdict.why.join("; ") : ""));
		await cleanup();
		return verdict.code;
	} catch (e) {
		console.error("AUDIO_PROBE ERROR", e);
		await cleanup();
		return 2;
	}
}

module.exports = { judge, initScript, PEAK_MIN, BOOT_WINDOW_S };

if (require.main === module) {
	main().then((code) => process.exit(code));
}
