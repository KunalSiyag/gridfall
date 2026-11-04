# Skeptic check: lens "experience"

Repo: /home/kunalsiyag/Ambassador/Gmi_Cloud/gridfall-wt-integ, web/wave0, tip 720d4e0 (git log). Read-only. No Godot/Chrome run. Python used for counting and reading PNG/JSON.
Tags: [OBS] read or measured here, [INF] derived, [UNK] not knowable without running.
26 items checked (14 findings, 12 proposals). 14 hold as written, 12 need a correction (below).

## A. Findings that HOLD (verified)
- E-F01 core: luma re-measured with PIL: smoke 01-boot 0.089 (79% px < 40), 02 0.086, 10-resumed 0.087, A/B M-1-OLD 0.093, M-2-NEW 0.090; 11-offline-mayors 0.362, 13-reloaded 0.367. Spawn faces the hall: fp_mode.gd:289-322 (dir = hall - road tile, yaw = atan2(-dir.x,-dir.z), forward = +dir). First-visit seed 7: main.gd:413-418 returns {} with no save, CitySim.city_seed = 7 (city_sim.gd:97), sim.new_city(randi()) only on failed restore (main.gd:425) and new_game (:452).
- E-F02: main.gd:223 toast; hud_toasts.gd:12,17 (LIFE 4, MAX_TEXT_W 560); fp_mode.gd:141 Low-GPU toast; screenshot 01-boot shows both truncated; click-to-capture fp_mode.gd:365-372 with no hint (grep "Click to" finds only phone/reporter/map); pause_menu.gd:133-137 hides legend in Settings; tools/release/PLAYING.md:22 omits J G L K and /mayor.
- E-F04: world_scale.gd:108 (1200 s) vs sim_defs.gd:22 (12 s); main.gd:588 saves _orbit_speed once at enter_fp, :624 restores at exit_fp; city_hud.gd:650-652 Space/1-4; fp_mode.gd:382-384 [ ] only on foot. Unrelated: the existing web_real_time_pace flag (data/feature_flags.json:10, quality.gd:113-148) is about engine catch-up steps at low fps, it does NOT pace the Planner clock.
- E-F06: hud_chips.gd:127-131 mood = sentiment*10; city_hud.gd:823,873 Happy = tile happiness; overview_feature.gd:223,600 "every morning" copy stale vs mayor_turns.gd:2-9.
- E-F07: hud_style.gd:16-17 tokens; hud_chips.gd:185 faint 1x readout; project.godot:26-29 canvas_items/expand at 1600x900; content_scale_factor unused (grep scripts: none). I recomputed worst case TEXT_DIM over a folded card on a white backdrop: 2.22:1 (matches the lens). Note: at 1080p the scale is 1.2 (12 px -> 14 px), so the "9-11 px" figure applies only to 1280x720 streams.
- E-F08: activity_feed.gd:26-29 STATES offline amber; activity_feature.gd:371-378 offline whenever live_enabled is false; gmi_key_panel.gd intro; GMI tab 5th at pause_menu.gd:22-45.
- E-F09: hud_chips.gd:193-201 cap 0 and need > 0 -> ratio 1.5 -> "fail", text "0%"; legend pause_menu.gd:57-58.
- E-F10 numbers: project.godot has 59 actions, 35 with a joypad event, 54 physical keycodes, 0 logical (script count). The 24 without pad include time_skip, ai_feed, press_league, press_story, phone_toggle.
- E-F11, E-F12: honestly marked [UNK]; 11-offline-mayors.png shows the grid and crumpled crowns. PLAYING.md:22,42 documents F5/F9 for desktop only.
- E-F13: 86 flags counted; roughly 28-30 are combat/hit-feel/carjack (my count 28 + health); data/feature_flags.json has none for presenter/onboarding/a11y.
- E-F14: strengths plausible; not contradicted.
- E-P02: all cited facts hold (DEFAULT_SETTINGS gate fp_mode.gd:438-447). New folder must be registered in scripts/fp/fp_features.gd; boundaries.py slice rule means talk via game_bus. Effort M (core S) is realistic.
- E-P07: realistic. Cheaper first step: Window.content_scale_factor (unused today) scales both HUDs at once; layout overlap is the real work. M is right.
- E-P11: investigate-then-fix, honestly scoped. Holds.

## B. Corrections

### E-F01 (evidence wording) and E-P01 (design)
1. "Two independent runs both rained" is one deterministic outcome: smoke and A/B both boot seed 7 day 1 (weather.gd:88-95 is a pure hash of seed and day). The conclusion (every first-ever web visit opens in rain) is fine, but the sample size is 1, not 2.
2. The lens attributes the 4x brightness to "clear morning". 11-offline-mayors.png (Day 1 07:30, rain streaks visible, 8x) already has luma 0.362 while still raining. The gain comes from time of day. So the cheap, safe part of E-P01 is a 07:30 start offset (S); a Day-1 clear-weather override is cosmetic and touches a deterministic function that fp_streetscape_test.gd:865-880 and fp_first_use_sites_test.gd:140-160 exercise (rainy day found by scanning days from 1, which for seed 7 is day 1, so any override must be off in tests).
3. E-P01 verify is self-contradictory: it says the first card lands about 33 s later (0.09 - 0.0625 = 0.0275 of a 1200 s day, mayor_turns.gd:9,90-91) and also asserts MayorTurns.next_turn()['at'] "is below 0.05" on day 1. With a 0.0625 start, an at below 0.05 would already be due at boot. Pick one: keep SPAN as is (33 s) and drop the mayor_turns.gd change.
4. "Visible founding build" is [UNK]: founding builds land in the mayor's own district (spawn is City Hall in Central Plaza, Mei Kimura); Viktor Han goes first on day 1 and may be out of sight. The G route and beacon help but nothing here proves a build is on screen.
5. Day 1 pop 0 is only the first minutes: a real save's history (see E-P04) shows pop 400 at the end of day 1.
Revised effort: time offset S; weather override + spawn yaw + optional crane M total.

### E-F03 (fresh city "empty and quiet") and E-F05/E-P05 (ask the mayors)
The lens missed an existing Day-1 filler and an existing ask path. scripts/ai/chatter_minds.gd:38-62 has MAYORS_SYSTEM ("rival mayors argue in public while nobody lives in the city yet") and MAYORS_PLAYER_SYSTEM (the rival mayors answer a visitor's chat line), :9-10 "a mayor the player names answers in person", chat_feature.gd:276 tour_ask_mayor, MAYOR_REPLY_LINES 3. It is on the chat drawer (the collapsed ">" tab at the left edge of 01-boot.png), not on the main HUD, and it runs on the chat's fast models (chatter_minds.gd:24 MODEL_NAMES deepseek flash, gemini-3.5 flash lite, qwen flash), not on each mayor's own model, via GmiClient.live_json so nothing reaches session cache or saves (chatter_minds.gd:4-8). So:
- "No code path for asking a mayor a question" is false; "five mayors answer on their OWN models, side by side" is true and is still the better showcase.
- E-P05 should reuse ChatFacts (chat_facts.gd) and the live_json rule (never remember/lookup), and use a NEW role name so a replay lookup never returns a recorded turn (gmi_client.gd:530-546 is role|agent keyed, nearest day; a mayor|argon lookup returns a recorded decision, not an answer).
- First thing a Day-1 visitor can do is open the drawer and watch rivals argue; the coach card (E-P02) should point at it ("Enter: city chat").
Revised effort E-P05: M to M-L (new persona prompt x5, offline templates, card type in activity_feature, rate limit, tests).

### E-P03 presenter panel
- Effort M is optimistic: new feature folder + bus signals + brain_cues.gd + 9 controls + URL/flag plumbing + test, and each cue has traps below. Say M-L (3-4 days).
- "Spark incident near me ... within 3 tiles of ctx.player" is false as a verify: CitySim.trigger_disaster (city_sim.gd:3540-3635) RELOCATES the event: water_main to the nearest pump within 8 tiles, power_line to a road within 6, car_crash to a road within 6, fire to a flammable tile within 3 (no burning target if none), blackout only disables a plant within 6 tiles (else an inert radius-5 event), sewage_burst only disables a sewage plant within 5. On a young city several of these do nothing visible.
- Offline, recorded resident reactions exist only for power_line, sewage_burst, water_main (data/gmi_replay_cache.json react|*|<type> keys); fire/blackout fall to heuristics. Offer those three first.
- "Dawn bundle now" is gated by _support_due (city_brain.gd:197-217): chaos needs day >= 4 and pop > 80 (:205, :742), news day >= 2, council needs open proposals; forcing on an early city yields nothing visible.
- Any text built with S.* owned-meta in the street HUD is scanned by the branding test (see E-P06 item); "GMI calls" cannot appear there.
- ?presenter=1 does not exist: no URL parsing anywhere (JavaScriptBridge only in web_support.gd:62,71 and first_use.gd:117). Add S for a JS eval read of location.search (eval already used by web_support._eval).
- Free keys for the panel: F2, F3, F4, F6-F8, F10 (project.godot input map; F5/F9 save/load, F1 hide HUD; avoid F11/F12 browser).

### E-P04 demo city
- "Day-6 ... thousands of people" is wrong for the only history I can read: a real day-10 autosave (~/.local/share/godot/app_userdata/GridFall.../gridfall_save.json, saved 2026-10-26, seed 31767) has history pop 400 (day 1), 736 (4), 1,072 (6), 1,168 (7), 1,384 (8), 1,576 (9) and funds $8,769 at day 6 falling to $2,796 at day 9. The day-12 promo city had pop 3,264 (deck/visuals-and-demo.md:11). The lens's own verify (pop >= 1500) corresponds to day 9, not day 6. Either save day 8-9 or accept about 1,100 people.
- The named recipe is wrong: tools/gen_save_fixture.gd (55 lines, GENERATE.md) writes a sim-only fixture (new_city/apply_action/step_tick/to_dict; day 11, pop 144, no residents, brain or fp). A demo with residents to talk to must come from Main.grow_offline (main.gd:635) plus save_game, as the owner's own saves did.
- Size: the real day-10 save is 2.38 MB (brain 0.96, client.session_cache 0.88, sim 0.64, residents 0.16, 80 people). The session_cache must be stripped (it is recorded model output; D9) which lands near 1.5 MB; the "<= 2 MB" check is fine after that.
- Loading is cheap: Main.load_game(path) takes any path (main.gd:343), export include_filter already ships data/*.json (export_presets.cfg:10,40,74). Risk: SaveSlot.read has backup semantics, check it on a read-only res:// path (unread here, [UNK]).
Revised effort: M-L (about 3 days, mostly generation, schema pinning and web fps check).

### E-P06 scorecard
- Collision with the street-HUD branding test: hud_style.gd:29 BRAND_RE = (?i)(Argon|DeepSeek|Kimi|Qwen|Grok|GMI|gemini|MiniMax|model|latency|cache|heuristic); fp_reporter_test.gd:694-702 scans league and card owned texts with S.branded(); fp_activity_test.gd:16,320 (LEAK_RE) scans the feed; fp_hud_test.gd:110 scans the HUD. Column headers like "Latency" or "Model" fail; only S.badge text (meta-exempt) may name a model. Use "Reply" / "Orders" and bare numbers.
- The data is shallower than "already exists": mayor_state[mi].log keeps the last 12 entries (city_brain.gd:398-402), so averages are over 12 decisions, not the session; for source "cache"/"heuristic" latency is about 0 ms (gmi_client.gd:215-239 sets source and measures local time), so on replay the latency column reads 0.0 s and "accepted" counts replay actions plus heuristic top-ups (city_brain.gd:411-433). The scorecard is only meaningful live. The session-wide numbers live in client.stats (gmi_client.gd:50,598 avg_latency_ms, live_ok/live_fail/cache/heuristic): use those for the "calls this session" counter.
- League layout: the table's columns sum small (People 66, Jobs 58, Approval 76, Funds 76, Score 56, reporter_league.gd:20-24), so two more columns fit; the 860 px figure was not re-verified.
Revised effort: M stands (layout + labels), but add "live only" to the player-visible result.

### E-P08
Effort S understates: six changes across city_hud.gd (1253 lines, over the 1000-line gdlint cap and baselined), hud_chips, pause_menu, overview, main, plus a new Planner key bar and a banner. Revised S-M (1-2 days). The paused-on-entry default is the owner's open question (memory note 2026-11-02), so ship it behind the flag as stated. Also: exit_fp sets speed from _orbit_speed (main.gd:624); with the flag the code must also store that so Space resumes at 1x, not 0.

### E-P09 loader explainer and "Go live" pill
- The activity feed is non-interactive: every control in activity_feed.gd is MOUSE_FILTER_IGNORE (lines 49,53,64,74,241,245,340,347) and the pointer is captured while playing (fp_mode.gd:417-421). A clickable "Go live" pill cannot be clicked on foot. It must be a key hint (like the header's "J") or live in the pause menu.
- "REPLAY: recorded GMI answers" breaks the branding scan (BRAND_RE contains GMI; fp_activity_test.gd:16,320). Wording must avoid GMI/model/cache: e.g. "REPLAY: recorded answers" plus a key hint. GMI branding is only allowed on the GMI settings tab (pause_menu.gd:374, gmi_key_panel.gd:16).
- The loader-HTML half (tools/web_export.py) is unaffected and remains S.
Revised effort: loader S; in-game badge S-M after the redesign.

### E-P10 accessibility
- Key N collides: site_next = N in project.godot (overview "N B Next site" key bar, docs/fp/ARCHITECTURE.md:106). Pick another key (F-key or M-free letter after checking the action map above).
- 14 files with about a dozen colour call sites: M-L, not M. Showcase value is correctly low (3).

### E-P12 peaceful mode
A cheaper path exists and was not mentioned: FP features are flagged by registry id (feature_flags.gd:5-6, fp_features.gd) and GRIDFALL_FLAGS="actions=0,brawl=0,melee=0,carjack=0,action_hijack=0" works on desktop today with no code. Limits: flags are read at boot (no runtime toggle), the web has no environment (only the persisted user://feature_flags.json via FeatureFlags.save_user, feature_flags.gd:24-33), and I did not check that actions=0 leaves reporter (reads act_strike at reporter_feature.gd:315-320), health and carjack_throw (needs carjack and hit_feel, data/feature_flags.json) working [UNK]. So: desktop stage preset = XS and should be written into the run sheet now; the web/runtime toggle stays S-M because the hooks are spread over actions, brawl, melee, drive, hit_by_cars, fight_back.

## C. What the lens missed
1. Day-1 chat already stages rival mayors arguing and answering the visitor (chatter_minds.gd:38-62); the left-edge ">" drawer tab is the only affordance and the coach card should name Enter.
2. Branding scan constraints on ALL new street HUD text (hud_style.gd:29; tests fp_activity, fp_hud, fp_reporter): no GMI, model, latency, cache, heuristic or model names outside badges. This changes E-P03, E-P05, E-P06, E-P09 wording.
3. Street HUD is not clickable while the pointer is captured: any new affordance is key-driven or a modal.
4. Replay cache coverage (data/gmi_replay_cache.json): mayors days 1-12; chaos only days 4,6,8,10,12; operator one entry (day 10); citizens|voices one entry (day 3); resident reactions only for power_line / sewage_burst / water_main. Past day 12, or for other incident types, the offline demo falls to heuristics (nearest-day lookup, gmi_client.gd:530-546). Rehearse cues that stay inside the cache.
5. Web pointer lock needs a user gesture; fp_mode._update_mouse_mode (417-421) sets CAPTURED at boot with no click. Whether the first click is then consumed or becomes a punch on web is [UNK]; check in a real browser in the next Chrome slot (cheap, high payoff given E-P12 and the first-click design of E-P02).
6. Timeline: the sum of the 12 proposals is about 25-30 person-days; with the corrected efforts only about 4-5 fit before 12 Nov. Order I would defend: E-P02 core (card + capture pill + toast fix), E-P01 time offset, the cue set of E-P03 limited to act-now / skip-to-dusk / save / load / speed (no incidents), E-P05 only if live key is confirmed, E-P09 loader half, E-P12 as a run-sheet flag line. Defer E-P04 unless a Day 8-9 save is generated by Main.grow_offline in an existing worktree.
7. Memory constraint worth stating: at most 5 worktrees and no Godot/Chrome while a window is in use; every verify step above that needs pixels is queued, none run here.
