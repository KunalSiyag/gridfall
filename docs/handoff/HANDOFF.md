# GridFall handoff, 2026-11-05

Written so that another agent (or person) can pick the work up cold. The owner is a GMI Cloud and Factory AI
ambassador; the live webinar demo is **12 Nov 2026**. Feature freeze Sun 8 Nov 18:00, code freeze Tue 10 Nov 20:00,
keyed rehearsal Mon 9 Nov (owner).

## Goal and rules from the owner

- Goal: ship a GridFall that runs well and **shows different AI models interacting in a live, non-deterministic
  city** (five mayors on five GMI models, support agents, resident minds). Improve the overall game experience.
- On 2026-11-05 the owner said: **skip unit tests** (they check by playing), spend what usage is left on putting
  everything together before the presentation. The weekly budget is nearly spent: prefer small, direct steps and no
  big multi-agent workflows.
- Never push, open a PR, push a Docker image or change GMI without the owner's explicit yes (state tag, URL, cost).
- Never read, print or commit secrets (`GMI_API_KEY`, `~/.factory/settings.json`, `.env`); never enter the owner's real
  key anywhere. The owner presses the in-game Test button with their own key.
- Do not touch the owner's checkout `/home/kunalsiyag/Ambassador/Gmi_Cloud/gridfall` (branch `fp/next-item`, dirty).
  All work is in worktrees off `web/wave0`. At most **5 worktrees** at once including main.
- Prefer headless (no windows on the owner's screen); the owner dislikes popups. Xvfb is not installed.
- Commits: Conventional Commits; trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` when an agent
  made them. gdformat only on files you create (this machine's gdformat differs from the pinned one).
- Webinar deck rules: ambassador framing ("GMI Cloud and Factory AI Ambassador"); the deck and its notes never name
  the coding assistants other than Factory's Droid, and keep Droid in a good light; omit, never falsify.

## Where things are

| What | Where |
| --- | --- |
| Integration branch | `web/wave0` in worktree `/home/kunalsiyag/Ambassador/Gmi_Cloud/gridfall-wt-integ` |
| Tip at handoff | the docs commit after `f94098e merge web/smooth-freezes` (README and runbook update) |
| Batch D work in progress | branches `web/ledger-ui-fixes` (worktree `gridfall-wt-d1`), `web/council-fixes` (`gridfall-wt-d2`), `web/look-polish` (`gridfall-wt-d3`): one **WIP commit each, unreviewed and untested**, stopped on purpose |
| Web export | `gridfall-wt-integ/build/web/` release `5d4fda0e70e64ef5` (pack 119.8 MB), built from `f94098e` + docs |
| Docker image | `kunalsiyag1/gridfall-web:c4d734e`, built locally, **not pushed** (older tags on Docker Hub: `0528316` is the live third instance's image) |
| Live instances on GMI | `gridfall-web-0528316` (third, key path fixed): https://ct-688045aa-4105-487b-ac5f-cd92cdb2ed92-web.caas-us1.gmicloud.ai ; older `gridfall-83fe2e8` and `gridfall-web-0a6855f-d` untouched |
| Linux package | `tools/package_linux.sh`, `tools/bench_linux.sh`, `docs/runbooks/linux-standalone.md` (committed on `web/wave0`; GPU speed not measured, the owner runs the benchmark) |
| Runbooks | `docs/runbooks/` (web-deploy, web-probe-kit, ask-the-five, model-ledger, mayor-context-v2, linux-standalone, police-response, gmi-outage) |
| Audit notes | `docs/handoff/audit/` (running-health.md P1-P12, model-interaction.md P0-P8, experience.md, the `-check` files correct them) |
| Open findings | `docs/handoff/findings/` (batchA_unresolved.json, batchC_unresolved.json, owner playtest investigations) |
| Deck | Slides artifact https://claude.ai/artifact/KdPh2XBsL2NeNPJUhreyyg (20 slides, private); the old draft `URs6ZCGuzZ9F3xUFwoB9yC` should be deleted (needs the owner's yes). Slide source copy: `docs/handoff/deck-slides/` |
| Agent memory | `~/.claude/projects/-home-kunalsiyag-Ambassador-Gmi-Cloud-gridfall/memory/` (index `MEMORY.md`; `gridfall-web-perf-droid-handoff.md` is the long dated log; `handoff-files/` holds deck fact base with agent-attribution detail that must NOT go into slides or a public repo) |

Nothing from `web/wave0` has been pushed. The owner's `main` checkout is behind by well over a hundred commits.

## What is merged in `web/wave0` (all local)

Web audio fix (default bus layout), no shadow stripes on roads, Planner sliced sim with speed-scaled budget, web
quality tiers (Low default), shader warm-up behind the veil plus a "Preparing the Planner" overlay and warm-up for
grown cities, orbit tree chunks, hero wading and a working water shader on the Compatibility renderer, grab-and-pull
car entry (parked, moving, bus, truck, bike, scooter), hero feet fitted to the ground (`GroundProfile`, `FootFit`),
surface-aware footsteps and speed (`SurfaceFeel`), new grass/asphalt/concrete/sand looks, dead textures removed, AI
durability (replay horizon, save diet, tolerant JSON, hidden-tab pacing clamp, per-role breakers, model readiness line),
Ask the five, first-minute coach, model ledger + League columns + Arena tab + chat attribution, council vote board,
`mayor_context_v2` (flag **off**, never tried live), Linux package, README/runbooks. Flags are in
`data/feature_flags.json` (e.g. `model_ledger`, `arena_tab`, `mayor_voice_calls` off, `web_shader_warmup`,
`ground_foot_fit`, `surface_feel`, `hero_wade`, `web_sliced_planner`, `autosave_gap`, `day_drain_fast`).

## Not verified

- Nothing was run with a real GMI key in a real browser (the key Test button, CORS from the browser, `/v1/models`).
- The last full gate that passed was `quick` on the Batch B2 tip `86a09fb`; Batch C was merged after its units'
  own gates; the merged tip `f94098e` was **not** re-gated (stopped on request). Run `tools/gate.sh quick` then
  `full` before shipping if usage allows; a run is ~5-40 min and costs no tokens.
- The new League, Arena, council board and mayor-note UI were never seen in pixels by the units that built them.

## Known problems (owner will notice these)

1. **League table** truncates district names in 4 of 5 rows; chat PRESS OFFICE/OWN WORDS chips overflow into the
   timestamp for long names (Batch D `d1` WIP addresses these).
2. **Keyless council card contradicts itself** on replayed days (headline "Rejected X", votes all yes, quote says it
   passes) and a deferred proposal is recorded again on every council run (Batch D `d2` WIP).
3. Wet roads do not darken in rain; lawn banding arcs; shore edge is a straight line; SUV/van door camera hides the
   pull (Batch D `d3` WIP).
4. Planner entry and Tab back still freeze about 3 s (overlay now says so); 8x in the Planner is about half of
   whole-tick speed on a grown city; fresh-city warm-up gain is modest (+3 s boot for 15-28% fewer hitches).
5. Hero NPC pedestrians have no foot fit; hijack takes about 6 s on foot.
6. The owner once asked "what is this glitching I see in debug mode?" and never sent a screenshot.

## Suggested order for the remaining days

1. Owner runs the local image (`docker run --rm -p 8080:8080 kunalsiyag1/gridfall-web:c4d734e`), plays, tests the key.
2. Look at the three WIP branches (`git -C ... log -p -1`): keep what is good, merge into `web/wave0`
   (expect conflicts only in docs/api and flags; regenerate with `python tools/gen_api_docs.py`).
3. Re-export (`tools/export.sh web`, several minutes after a merge: Godot re-imports), `docker build`, and with the
   owner's yes push and add an instance (about $0.0475 an hour), then `tools/demo_check.sh <url>`.
4. Update the deck (see below) and fill the `[Your own ... here]` placeholders in its speaker notes (owner's words).
5. Re-record the replay cache on the rehearsal day if the owner wants fresh recorded answers
   (`GRIDFALL_RECORD=1`, see README).

## Deck status

20 slides, dark navy/amber, fonts Space Grotesk, IBM Plex Sans, JetBrains Mono. The owner wants it updated to bind
everything together: the architecture, how it was built (phases, the Droid mission, the verification process as process),
**what is used from GMI Cloud** (14 chat models by role, `hy-image-v3.5-preview`, AgentBox hosting), **Factory Droid**,
**`hy-image-v3.5-preview` concept sheets for character and building modelling** (concepts/01-04, Blender scripts
`tools/blender/make_gridfall_assets.py`, runtime posters), ACE-Step 1.5 music, Kenney and Poly Haven CC0 assets, the
new showcase features (Ask the five, League/Arena, council board), and the web vs native Linux delivery. Four HY concept
JPGs are already uploaded to the deck artifact as assets (`/_blob/540f4d491337932c4b547ee2473a734d` environment mood,
`/_blob/6a503f12e007731d219e221d7f93f299` crisis buildings, `/_blob/e6f1fce855faf2697c1e7fd1fd926036` resident avatars,
`/_blob/17ac1e7971598cc12377fdbf61f205d5` shader and HUD sheet). Slide format rules are in the artifact's
`artifact-type/reference/format.md`; edit the Slides artifact only through its own files (`project/deck.json`,
`project/slides/<id>.html`). Several stale numbers (line counts at commit 83fe2e8, "23 feature folders") need
refreshing against the current tree. Fact base with sources: the agent memory folder `handoff-files/deck-facts/`.

## How to run things

```bash
source ~/.venvs/gridfall-tools/bin/activate
tools/gate.sh quick          # parse + unit tests; GATE_RETRIES=1 to retry flaky steps; logs in /tmp/claude-1000/gf-gate-*
tools/export.sh web          # build/web (takes the heavy-run lock; never wrap it in flock)
docker build -t kunalsiyag1/gridfall-web:<rev> -f deploy/web/Dockerfile .
node deploy/web/smoke.js http://127.0.0.1:8080/      # needs Chrome; ~10 min
tools/demo_check.sh https://<public-host>            # read-only check of a deployed instance
python tools/checks/run_all.py; python tools/gen_api_docs.py --check; python -m pytest tools/pytests
```

A stale `build/web` pack on disk makes three `tools/pytests/test_web_audio.py` pack tests fail; rebuild or move it.
Heavy runs share one lock; tool calls die after 10 minutes, so run long jobs with `nohup` and poll.
