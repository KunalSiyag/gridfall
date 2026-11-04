# Skeptic check: lens "model-interaction"

Scope: read-only. Repo /home/kunalsiyag/Ambassador/Gmi_Cloud/gridfall-wt-integ at 720d4e0. No Godot/Chrome run. Tags: [O] observed (file:line or command), [I] inferred, [U] unknown.
Checked 26 items (17 findings, 9 proposals). Facts verified by python over data/gmi_replay_cache.json: 56 mayor turns, 0 grants, 3 turns name another mayor (argon d11, kimi d4, kimi d8), 3 name a resident (argon d11, kimi d8, qwen d6), grok NO votes clean_air_act x4 / green_energy_subsidy x2 / recycling x4, chaos 4 triggers all sewage_burst, action mix and post/thought lengths all match the lens.

## Corrections (things that are wrong, overstated or harder)

### C1 MI-F1 (shared breaker) is overstated; MI-P1 value is much lower than scored
- [O] circuit_breaker.gd: failures reset to 0 on ANY success; threshold is 4 CONSECUTIVE failures. gmi_client.gd:333-337 records success for every non-service failure (400/401/404/"no JSON"/bad body: service_fail false) and the fp_ops_test check says only network, 408, 429 and 5xx count.
- So one dead model among ~14 interleaved callers almost never produces 4 consecutive service failures (any other model landing in between resets it), and a retired model (404) never trips it at all.
- [O] The rotating roles already isolate a bad model: resident_minds.gd:57,90,105 (_bad_models, skip after 3 fails) and chatter_minds.gd:1343-1351 (_bad). Only fixed-model roles (5 mayors, 5 support agents) lack it.
- [O] A mayor model is called once per game day (FP day 1200 s, world_scale.gd:108). A per-model breaker with threshold 4 needs 4 failed DAYS (>= 80 min at 1x) to open, and its 30 s cool-down is far shorter than a day. For mayors it is inert. The realistic trip is a global 429 or outage, which per-model breakers do not fix.
- Revised: drop per-model breakers. Health pips from ledger last-outcomes are enough (S). Downgrade F1 to minor; P1 stability 8 -> 3, showcase 4 -> 3.

### C2 MI-F5 evidence is partly wrong
- [O] Cache days 6/7/9 council statements say "only one vote"/"only two votes": ordinary under-threshold deferrals, not overrides. No recorded Speaker override (enact with 2 yes, or defer with 3+) exists in the cache. Replay Speaker text is non-reactive anyway (nearest-day lookup, gmi_client.gd:529-545).
- [O] city_brain.gd:833-836: `rejected` means >= 4 votes cast and not enacted, regardless of the yes/no split, so a 4-yes proposal the Speaker declines shows as Rejected. The board must label by tally, not just outcome.
- Rest of F5 (names hidden in orbit city_hud.gd:~971, FP politics shows own votes only, activity_words.gd:114-125, "No ordinance changed" for deferrals :140) holds.

### C3 MI-F8 / MI-P8 chat attribution: smaller than "major", and P8 call cost is wrong
- [O] chatter_minds.gd header says residents and "sometimes a mayor" talk "in their own voices" by design; DeepSeek-V4.1-Flash and Qwen3.8-Flash are same-family siblings of 2 of the 5 mayors. Real but a moderate/minor issue.
- [O] P8 says own-model lines add "one call per round". A round panel is 2-3 mayors (chatter_minds.gd:248 `mayor_panel(-1, rng.randi_range(2, 3), rng)`) and a player-addressed one is 2 (:310). Own-model = 2-3 parallel calls per round to different models.
- [O] chat_panel_row.gd:142-145 draws chips as text lines (not Labels); a model chip is feasible, but the file is slice C (boundaries.json file_owners "scripts/fp/ui/chat_panel*.gd": "C") and the Label-based lint (S.owned_texts) will not see it.
- Revised: label-only variant S (as claimed); own-model variant M-L.

### C4 MI-F15 scope
- [O] FP surfaces ARE de-branded: activity_words.gd:164-168 (detail -> D.debrand), chat_feature.gd:562 (T.display), chat_feed.gd:81-82 (make -> T.display). Only orbit raw text leaks (city_hud.gd:752-758 banner, City Hall tab).
- [O] fp_orbit_names_test.gd:2-6: owner decided orbit keeps model brands "because the model is the point of the demo". So this is a one-line policy item, not a regression. Also city_sim.gd:3505 writes the grant "deal" line with brand `name`; orbit Feed shows "Argon-4 granted ...", chat de-brands it.

### C5 MI-P0 verification and claims
- [O] "FakeNet returning fenced/think-tagged JSON; assert repair flags" cannot work: FakeNet overrides `_post` wholesale and returns an already parsed dict (tools/tests/fp_ops_test.gd:14-20); extract_json/salvage/reasoning_content live inside `_post` (gmi_client.gd:420-427). Need a static `_parse_reply(text)` (or test the statics) first. +S.
- [O] "single choke point sees everything" is false for two paths: `live_json` returns before `_log` when offline (gmi_client.gd:250-252) and when the breaker is open (:253-256). Those resident/chatter calls never reach call_logged; the ledger must count them separately or health pips miss skips.
- [O] `tools/gate.sh quick` runs an EXPLICIT list (gate.sh ~line 202: sim_test ... brain_stale_answer_test ai_image_client_test ...) plus the glob `tools/tests/fp_*_test.gd` (:215). New `ai_ledger_test`, `ai_arena_test`, `ai_ask_all_test`, `ai_council_board_test`, `ai_timeline_test`, `ai_graph_test`, `ai_context_v2_test` are NOT run unless gate.sh is edited or they are named fp_*. tools/checks/test_map.py also needs an fp_*_test naming each new scripts/fp/<dir>/ (arena). Add to every proposal's file list: tools/gate.sh.
- Effort M holds.

### C6 MI-P2 (Arena) numbers and layout
- [O] One mayor call per game day: p50/p95 over "last 50" is degenerate for mayors (a 20-minute FP demo = 1-2 samples per mayor; orbit 4x = ~3 s/day only helps in orbit). Show last + mean + n for mayors; percentiles only for pooled roles/models.
- [O] latency_ms includes retries, backoff and queueing (gmi_client.gd:213-215) and runs under 10+ concurrent calls: it is time-to-answer under load, not model speed. Needs tokens (P0) to be fair.
- [O] League table has no spare width: COLS 26+226+176+66+58+76+76+56 = 760 plus 7x8 gaps = 816 of the 820 px inner width (reporter_league.gd:20-29, WIDTH 860 less 20 px margins). Three more columns means re-budgeting widths or widening; fp_reporter_test.gd:675,863 parses table_lines() and needs updating. FP columns: S-M.
- [O] Orbit right panel is 384 px (city_hud.gd:395-398, offset_left -392..-8): per-mayor rows with p50/p95, accept, repair, tokens, mix bar and 3 sparklines do not fit in a tab. Needs an overlay or card. Orbit part M-L. Overall M -> M-L.
- "Services & minds" page double counts: chatter MODEL_NAMES are 3 of the 6 resident MODELS; key the page by model with a role mix.

### C7 MI-P3 (Ask-all-five): effort and verification
- [O] Pieces: new scripts/fp/arena feature + fp_features.gd entry + modal + `/ask` hook in chat_feature.gd (slice C file, player_say :249-262) + orbit overlay + neutral prompt + budget + tests named fp_* for test_map. That is 3-4 days: M-L, not M. Needs its own flag (AGENTS.md "gate new behaviour").
- [O] "Plausibility flags" is a re-implementation: apply_action (city_sim.gd:3093-3131) mutates and there is no dry-run, so real refusals ("blocked by park at (14,2)") cannot be shown. Label it rough.
- [O] tools/tests/support/gated_client.gd live_json returns a FAILED "offline" result (:59-76): ranks are testable, content is not. Test must assert order only or subclass.
- [O] live_json feeds the global breaker/live_outcomes (gmi_client.gd:259-273), so a failed ask can flip the street badge (see M2). Prompt builders are pure (messages_for/open_lots/annexable_plots read-only, grep shows no rng) - the sim-equality check is valid.
- BYO key on web (gmi_client.gd:105 set_player_key, gmi_key_panel.gd): each ask spends 5 calls of the visitor's key; say so in the UI.

### C8 MI-P4 offline claim and S effort
- [O] Offline board is entirely unanimous, not "mostly": heuristic proposals are recycling/public_transit/free_clinics/water_conservation/trade_expo (city_brain.gd:~553) and the only heuristic NO is Grok on clean_air_act/curfew (:557), which no heuristic mayor proposes. Only the replay shows Grok's NOs.
- [O] fp_orbit_names_test.gd `_check_council_and_people` asserts City Hall text; _render_council changes must update it. Minimal (history + tally words + override flag) is S; the 5-seat grid is S-M.

### C9 MI-P5 verification and effort
- [O] The GATED permutation cannot drive a ledger: GATED overrides chat_json/live_json and never calls _log/call_logged, latency_ms 0 (gated_client.gd:37-76). Use a FakeNet-style `_post` override that awaits a gate instead.
- Swimlane + detail + journal + run_diff.py + pytest is M-L (3-4 d). A same-seed divergence diff of live runs is noisy by construction and has low demo value: cut it.

### C10 MI-P7 verification and a hidden blocker
- [O] "brain_live_test (heuristic) unchanged" is wrong: brain_live_test.gd:2 "two in-game days of real GMI calls", README:165, docs/fp/S0-foundation.md:1760 "The live tests ... are never run"; it is not in the gate list. Use brain_stale_answer_test + sim_determinism_test + the new prompt test to prove flag-off identity.
- [O] Hidden blocker: grant `to` accepts only lowercase ids (sim_defs.gd:362-366 mayor_index; schema city_brain.gd:273 "argon|deepseek|kimi|qwen|grok") while every other prompt line names mayors by display name (city_brain.gd:301) and no line maps Ada Okafor -> argon. P7's message_to/request fields hit the same gap. Fix first: add a roster line to the user prompt or let mayor_index accept display names/surnames (S).
- [O] 0 grants is real model behaviour at recording time (grant is in the initial commit ba1636e, same as the cache), but the display-name change came later (909b9df, 2026-10-18), so today's prompt is worse for targeting.
- Effect is unmeasurable headless; negative treasuries (screenshot 01: -$448..-$1,965) mean grants may stay rare. Keep default off; effort M code + live tuning time the owner may not have.

## Citation nits (claims hold, location wrong)
- SPAN 0.9 is mayor_turns.gd:9 and at() :90-91 (not :61, which is to_dict). Stagger switch is activity_feature.gd:68-69 (not 64-65). Grant schema is city_brain.gd:273 (not 274). day_feed.clear() (:696) runs BEFORE the news call; the local `feed` is then discarded.
- BRAND_RE is used only by S.branded (hud_style.gd:346); fp_activity_test.gd:19 enforces its own LEAK_RE (BRAND_RE minus "model").
- ResidentMinds.reacted: "went to help" lines go to sim._log category "response", which IS in the day_feed categories (city_brain.gd:~84), so reactions reach the Gazette; the finding (no listener) still holds.
- Approval also feeds chat (chatter_minds.gd:467,1054; chat_facts.gd:307,341), not only league/posters.

## Missing from the lens (ranked by demo value)
1. M1 Grant id mapping (above C10): likely a cause of the empty interaction channel today. S.
2. M2 Street badge false alarm: activity_feature.gd:376 `live_failure_ratio() > 0.5` has no minimum sample (live_failure_ratio :144-151 returns bad/size); one failed first call is 1/1 and shows red "Reconnecting". The alert rule is guarded (alerts.gd:~172 min_calls, data/alert_rules.json:10 min_calls 6). Mirror the guard. S, extend fp_activity_test. This is the stability item P1 should have been.
3. M3 Replay cache is stale and is the keyless/outage fallback: one commit (ba1636e, 2026-10-17), 467 KB, pre display names, pre wind/landfill/annex. Lookup is nearest day (gmi_client.gd:529-545) so past day 12 every mayor repeats day 12. Re-record with GRIDFALL_RECORD=1 (gmi_client.gd:87) before 12 Nov, ideally after P0 meta so latency is baked in. S, owner-run with a key, not headless.
4. M4 Runbook gmi-outage.md:28 tells the operator to lower LIVE_RESIDENTS on 429; it is read only by tools/tests/residents_live.gd:36 (and README). In game, residents cap at MAX_RESIDENTS 100 (residents.gd:20) = <= 10 batch calls/day; the real lever is the Live GMI toggle. Docs fix, S.
5. M5 Reuse: scripts/cinematic.gd:268-282 already draws a live-only "model - latency - action" ticker from mayor_decided entries (real: the 15.2/14.9/9.1 s in screenshot 05 are entry.latency_ms). A cheap race ticker for Arena/street. Note cinematic.gd:356 hard-codes the "LIVE" title (only live entries are shown, so honest).
6. M6 New-test plumbing (see C5) and static-check friction: tools/checks/complexity.py THRESHOLD 20, gdlint/gdformat baselines, feature_flags.py (every flag read via FeatureFlags.enabled or a registered feature id), rng_seed.py. New render code in city_hud.gd (1253 lines) must be split into small functions or it fails run_all.
7. M7 Schedule: 9 days to 12 Nov. The lens sums to ~7 M + 2 S items (9-23 days). A realistic cut: S-fixes (M1, M2, C3 label) + P0-lite (ledger + parse refactor) + League columns (FP) + P4-minimal + P3 (FP only, flagged). Drop P1 breakers, P5 journal/diff, P6 until P7 is proven live.
