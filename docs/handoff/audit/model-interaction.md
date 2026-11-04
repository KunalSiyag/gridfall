# Lens: model-interaction (the product thesis)

Scope: read-only audit of /home/kunalsiyag/Ambassador/Gmi_Cloud/gridfall-wt-integ at 720d4e0 (branch web/wave0). No Godot, Chrome or network was run. Tags: [O] observed in code or data (file:line or command given), [I] inferred from code, [U] unknown. Paths below are relative to the repo root unless absolute. Replay-cache numbers come from `python3` over `data/gmi_replay_cache.json` (read only).

Conventions used by proposals: effort S <1 day, M 1-3 days, L >3 days. Value scores are 0-10 (showcase = how much the 12 Nov audience gets out of it; stability = how much it protects a live run).

---------------------------------------------------------------------------------------------------

## 0. One-paragraph verdict

The simulation already contains a real multi-model society (14 distinct text models plus 1 image model, 3 call tiers, a validated action layer, a Gazette that feeds back into everyone). What the audience can see of that is thin: one mayor card at a time on the street, a global "Live / Reconnecting / Offline" badge, a per-call source tag, and (orbit only) a raw 60-line log. Nearly everything that makes models DIFFERENT or makes interaction HAPPEN is either not recorded (tokens, JSON repair, per-model latency/failure aggregates, district time series, prompts, vote history, provenance) or recorded but not drawn (acceptance rate, council vote names, Speaker overrides, incident reactions). Separately, the recorded run shows the interaction itself is sparse (0 grants in 56 mayor turns, 3 of 56 turns even name another mayor), because the prompt never shows a mayor the council's reasoning, the operator's advice, the chaos reasoning, the league rank, or gives them a directed channel. The cheapest high-value path: (1) one ModelLedger fed by the single `call_logged` signal, (2) per-model circuit breakers so one flaky model does not turn the whole city to replay, (3) Arena scoreboard + health lights, (4) "Ask all five" counterfactual panel, (5) council vote board, (6) timeline, (7) interaction graph, with (8) a flag-gated prompt upgrade so there is something to graph.

---------------------------------------------------------------------------------------------------

## 1. End-to-end map of where models act

### 1.1 Cast (14 text models + 1 image model) [O: command over sim_defs.gd, resident_minds.gd, chatter_minds.gd]

| Tier | Agent | Model id | Source | Trigger | Output the sim consumes |
|---|---|---|---|---|---|
| Mayor | Ada Okafor (argon) | google/gemini-4-argon | sim_defs.gd:216-243 | once per game day; dawn in orbit/tests, staggered over 0.9 of the day in street mode (mayor_turns.gd:61, activity_feature.gd:64-65) | JSON: thought, public_post, mood, <=7 actions, propose_ordinance, votes (city_brain.gd:277) |
| Mayor | Viktor Han (deepseek) | deepseek-ai/DeepSeek-V4-Flash-0731 | same | same | same |
| Mayor | Mei Kimura (kimi) | moonshotai/kimi-k3 | same | same | same |
| Mayor | Rosa Quintero (qwen) | Qwen/Qwen3.8-Max | same | same | same |
| Mayor | Duke Granger (grok) | x-ai/grok-4.5 | same | same | same |
| Support | Citizen Voices | MiniMaxAI/MiniMax-M3 | sim_defs.gd:246 | only while residents are off (`not sim.work_based()`, city_brain.gd:199-201) | complaint counts per district (city_brain.gd:605-619) |
| Support | Gazette | XiaomiMiMo/MiMo-V2.6-Flash | :247 | day >= 2, every day (city_brain.gd:202-203) | headline/stories/editorial; headline feeds mayors, residents, chat topics, posters |
| Support | Council Speaker | openai/gpt-6-luna | :248 | proposals pending AND (day % 3 == 0 OR any proposal with >= 3 votes) (city_brain.gd:212-214) | enact/repeal lists; sim.enact_ordinance only if >= 2 yes votes (city_brain.gd:827) |
| Support | Chaos Director | deepseek-ai/DeepSeek-V4-Pro | :249 | day >= 4 and >= 2 days since last (city_brain.gd:204-205) | disaster type + (x,y) -> sim.trigger_disaster (city_brain.gd:742-746) |
| Support | Grid Operator | google/gemini-3.8-flash | :250 | power or water > 90% of capacity, or day % 5 == 0 (city_brain.gd:206-211) | 5-district priority -> sim.grid_priority (load shedding, city_sim.gd:1634) |
| Support | Street Inspector | MiniMaxAI/MiniMax-M3 | :251 | on demand (player click / "Ask someone here"), 20 s gap (chat_feature.gd:INSPECT_GAP_MS) | speaker/says/diagnosis/suggestion (UI only) |
| Residents | ~1 per 10 people | 6 models rotate by batch of 10: DeepSeek-V4.1-Flash, gemini-3.5-flash-lite, MiniMax-M3, DeepSeek-V4-Flash-0731, Qwen3.8-Flash, GLM-5.3-Flash | resident_minds.gd:15-18, :126, :169 | daily plans (batched) + incident reactions | commute/spend/evening/intent/mood/approve_mayor/complaint/message -> traffic, wages, sales tax, migration, mayor letters (residents.gd:1003-1034) |
| Chatter | ambient chat, player replies, talk, mayors-in-chat | rotates 3 flash models (chatter_minds.gd:16, :1343-1351) | chatter_minds.gd | ~1 round / 60 s, player lines, talk lines | text only (+ talk mood_delta/memory) |
| Image | campaign/shop/notice posters | hy-image-v3.5-preview | gmi_image_client.gd:16 | mayor_decided -> campaign refresh at most every 3 days (poster_director.gd:16, :139) | texture on a wall; leaf node, nothing feeds back |

Overlap worth knowing: the DeepSeek mayor's model (DeepSeek-V4-Flash-0731) also thinks for residents, MiniMax-M3 is both Citizen Voices, Street Inspector and a resident model.

### 1.2 What a mayor sees in its prompt [O: city_brain.gd:280-329]
Own district summary and ASCII map; city summary; open lots; annexable plots; yesterday's own action results WITH rejection reasons; own last 2 thoughts; the other mayors' latest `public_post` only (not their thoughts, actions or results); citizen complaint counts; up to 6 named resident letters from the last day; today's Gazette headline (one line); pending proposals with votes cast so far BY NAME; active ordinances; player decree.

A mayor does NOT see [O]: the Council Speaker's statement or why a proposal was deferred (last_council is never read by `_mayor_user_prompt`), the Grid Operator's note/advice, the Chaos Director's reason or narration, the league ranking (`ReporterDesk.standings` is called only by the FP league UI: reporter_feature.gd:571), anyone's actions or thoughts, any ask/offer/DM channel. `grant` is listed as an action (city_brain.gd:274) with no guidance on when to use it.

### 1.3 Feedback edges that exist [O unless tagged]
1. mayor post -> other mayors' next prompt (city_brain.gd:299-304). Same-day only when staggered (street mode); in orbit all five prompts are built in the same frame(s) before any answer lands (city_brain.gd:115-131) so they read yesterday's posts [I].
2. mayor post/proposal/vote/grant/event -> `day_feed` (city_brain.gd:377, 403, 82-88) -> Gazette (city_brain.gd:694-701) -> headline -> mayors (:318), residents (resident_minds.gd:263-264), chat topics (chat_feature.gd:516-525), posters (poster_director.gd). `day_feed` is cleared after the news call (city_brain.gd:696) so the Gazette's provenance is lost [O].
3. mayor proposals + votes -> `proposals` (city_brain.gd:372-385) -> Speaker (808-841) -> `sim.ordinances` (fixed effects in sim_defs.gd:180-191). Mayors see prior votes by name; with staggered rotating order, later voters can herd [I].
4. residents' `message_to_mayor` / complaints / protests -> mayor prompt (city_brain.gd:305-312; residents.gd:487-494 messages_for) and posters (poster_director.gd:386-404 protest flyers).
5. mayor post -> resident context `said_yesterday` (resident_minds.gd:255-262) -> resident approve_mayor / mood -> `district_mood` -> league "approval" and mayors' "YOUR RESIDENTS" JSON (city_brain.gd:309). Approval has no mechanical consequence (no election or budget effect) [O: grep of approve usage; only league, posters, prompt].
6. Chaos Director -> sim event -> `ResidentMinds._react` (resident_minds.gd:403-473) -> residents help/report/evacuate -> repair progress; incident lifetime depends on resident models. The `reacted` signal has NO listener [O: grep of scripts/], so reactions are visible only as chat `say` lines and one "went to help" log line (resident_minds.gd:470, 507).
7. Grid Operator -> `sim.grid_priority` -> unpowered tiles -> `district_summary.counts.unpowered` -> mayors' prompts. Operator advice itself never reaches mayors (see 1.2).
8. Mayor grant -> `sim._act_grant` (city_sim.gd:3496-3508) -> "deal" log -> Gazette feed and one chat "City" line (chat_feature.gd:623-634). No ledger of deals.
9. Contested resources: annex plots (first answer wins; second gets "claimed or does not border your district", city_sim.gd:471-492), shared power/water/sewage/landfill capacity, coal pollution across borders, load-shedding order. In orbit the five answers apply in LANDING order, so latency decides ties [I].
10. Player decree -> all mayors (city_brain.gd:104-107, 326-327), once per day via chat `/mayor` (chat_feature.gd:251-255). Whether mayors comply is not tracked.
11. Image model: mayor post -> slogan -> image prompt -> poster. No model attribution on the poster; stats are global (`GmiImageClient.stats`, DAY_CAP 6, SESSION_CAP 30, MAX_IN_FLIGHT 2: gmi_image_client.gd:28-30).

### 1.4 Determinism picture [O/I]
Seeded and deterministic: sim RNG, resident RNG (resident_minds.gd:71 `_rng.seed = sim.city_seed + 99`), heuristic fallbacks (`_heuristic_chaos` uses `sim.rng`, city_brain.gd:753-765), turn order rotation (mayor_turns.gd:134-138). Non-deterministic: every live model answer, and the wall-clock landing order/timing of async calls (orbit apply order, who is mid-flight when a day ends, 75 s gate city_brain.gd:26, 96-101). Replay is deterministic canned output: `_cache_lookup` returns the entry with the NEAREST DAY for the same role|agent regardless of the prompt (gmi_client.gd:529-545), so a replayed mayor does not react to the current state (hence `_replay_top_up`, city_brain.gd:411-431).

---------------------------------------------------------------------------------------------------

## 2. What the recorded run (replay cache) actually shows [O: python over data/gmi_replay_cache.json]

179 keys; 56 mayor turns (argon 10, deepseek 11, kimi 11, qwen 12, grok 12; days 1-12), 6 council rulings, 6 Gazette pages, 5 chaos decisions, 1 operator, 1 citizens, 532 resident plan entries, 74 reaction entries. Recorded before wind farms/landfill/annex existed (README, city_brain.gd:409-410), so treat as "what the personas do", not as current prompt behaviour. Entries store only `{day, data}`: no latency, tokens or model (gmi_client.gd:523-526).

Real, measurable differences between the mayors:
- Actions per turn: grok 6.6, kimi 5.6, deepseek 5.2, qwen 4.8, argon 4.7.
- Action mix: grok road 16 / zone 31 / build 18 / tax 10; deepseek road 3 (!) / zone 25 / build 20 (sewage 6, police 4); kimi zone 36 (R 33, C 2, I 1) despite a "commerce" persona; qwen build 21 (park 9, solar 4) + 7 emergencies; argon park 7, road 10, zero emergencies. The "road-grid optimizer" built 3 road orders in 11 turns, grok 16: persona claims and behaviour diverge, which is a showcase story.
- Mood word: grok "aggressive" 12/12; argon "methodical" 7/10.
- Public post length: deepseek 83 chars vs 143-155 for the others; thought length: kimi 293 vs deepseek 128.
- Votes: grok votes NO on clean_air_act x4, green_energy_subsidy x2, recycling x4 (yes x2); kimi/qwen/deepseek vote yes almost everywhere.
- Proposals: argon 6 (recycling x3, public_transit x2, green_energy_subsidy), deepseek 3, kimi 3, qwen 2, grok 0.
- Speaker (gpt-6-luna): day 3 passes clean_air + green_energy; day 5 passes public_transit and REPEALS green_energy; days 6/7/9 defer recycling ("only one/two votes"); day 11 passes recycling and repeals public_transit. It actively manages the ordinance set.
- Chaos Director: 4 of 5 decisions triggered, all 4 were `sewage_burst` (days 4, 8, 10, 12 at (18,18), (19,0), (22,25), (18,24)); never another type.
- Gazette editorial day 4: "Grok's coal boom meets Argon's recycling plan" - proof the post -> Gazette -> headline chain moves content between models.

What is conspicuously absent:
- grants: 0 of 56 turns.
- turns naming another mayor: 3 of 56 (4 name-pairs: argon->grok day 11; kimi->argon,grok day 4; kimi->deepseek day 8).
- turns naming a resident: 3 of 56.
So "models interact" is currently true through shared resources, votes, the Gazette and residents, but conversational/negotiated interaction is near zero in the data. [Caveat U: prompts changed since recording; live behaviour today is unmeasured.]

Confounds [O]: persona text is part of each mayor's identity (sim_defs.gd:220-241), districts differ in geography (center block vs corners vs river), and residents' approval/mood are produced by a model chosen per batch per day (`_model(_rot + b)` then `_rot += 1` per day, resident_minds.gd:126, 169) so a resident's mind changes model across days. Therefore "district outcome by mayor model" is NOT a clean model comparison. The clean comparison is the same-state counterfactual (proposal P3 below), with a neutral-persona toggle.

Screenshots (observed): /tmp/claude-1000/-home-kunalsiyag-Ambassador-Gmi-Cloud-gridfall/4eb46f6b-fccd-4256-83c9-4c39144a74d2/scratchpad/deck/img/01_planner_chaos_director.jpg shows the replay state of the orbit HUD: top bar "GMI: idle - live 0 cache 673 heur 205 avg 0.0s [REPLAY]", every mayor card "cache 0.0s", all five treasuries negative (-$448 .. -$1,965). 04_mayor_card_model.jpg shows "Actions accepted 46 - rejected 6" (87%) and one REJECTED road ("blocked by park at (14,2)"). 05_ticker_live_models.jpg (cinematic trailer capture) shows real live latencies: kimi-k3 15.2 s, gemini-4-argon 14.9 s, Qwen3.8-Max 9.1 s. 08_street_hud_ai_activity_fire.jpg shows the street AI activity feed.

---------------------------------------------------------------------------------------------------

## 3. (a) What a viewer can SEE vs what is invisible

### 3.1 Visible today
Orbit (scripts/ui/city_hud.gd):
- Top bar: day, pop, jobs, funds, happiness, events, RCI, utilities, GMI status line with GLOBAL "live/cache/heur/avg latency" (city_hud.gd:848), `Live GMI` toggle.
- Five mayor cards in the dock: treasury, pop, happy, status "thinking on GMI..." then "source latency mood", latest post (city_hud.gd:866-886).
- Right tabs (hard-coded indices 4=log, 5=feed, 6=people, city_hud.gd:792-797; new tabs must append at index 7): Mayor (ONE selected mayor: model id, treasury, taxes, accepted/rejected totals, thought, post, per-action OK/NO with the sim's reason, city_hud.gd:888-913), Gazette, City Hall (statement, active ordinances, proposals as "N yes N no" with no names, city_hud.gd:971; operator order + note; chaos reason; resident voices), Inspect, GMI Log (last 60 calls: role/agent, source, ms, model file, error, 140-char summary, city_hud.gd:1020-1033), Feed (sim log), People (resident detail incl. "via <model>", and the one per-model scoreboard in the game: `minds.model_stats` ok/total + avg seconds, city_hud.gd:1097-1100).
Street (FP):
- AI activity feed (top right, J cycles): per decision a card with who, model BADGE, source tag LIVE/REPLAY/FALLBACK/OFFLINE, headline of what was done, private thought, "politics" line (first 2 of proposal/votes) or first refusal, place + G route (activity_*.gd). Header badge Live/Reconnecting/Offline (activity_feed.gd:28-31, 79-110; activity_feature.gd:366, 372-380). "X is deciding..." / "Next up: Y in N min" line (activity_feature.gd:383-407).
- Beacons + compass/minimap pings in agent colour; chat ticker with mayor posts, council ruling, Gazette headline, operator note, "Breaking" chaos line, deals; posters (campaign billboards in own district, Gazette at bus shelters, ordinance notices, protest flyers).
- Mayors' league (L): rank by people/jobs/approval/funds with model badge (reporter_league.gd). Cached `orders` and `refused` per mayor are computed (reporter_desk.gd:193-194) but NOT shown (COLS reporter_league.gd:20-29).

### 3.2 Invisible or illegible
- Disagreement: per-mayor vote names/splits (orbit shows counts only; FP card shows at most 2 of the mayor's own votes; no tally). Speaker overrides (passes with 2 yes at city_brain.gd:827; defers with 3+ yes, e.g. cache days 6/7/9) look like unexplained "No ordinance changed" cards.
- Deals/grants: one chat line, one feed line; no ledger, no who-helped-whom.
- Model reliability: per-model latency, failure, retries, refusal, JSON repair, truncation: not aggregated anywhere except residents. The street only has a global badge; replay shows "0.0s".
- Influence/provenance: which posts, letters, headline a mayor read; which feed lines the Gazette used; which resident letter moved which action.
- Run-to-run difference: nothing stored; prompts are never recorded (only tools/tests/dump_prompts.gd writes them); `log_records` holds 300 records (gmi_client.gd:28) and each carries no wall-clock time.
- Reaction detail: `ResidentMinds.reacted` has no listener (see 1.3.6).
- Support-agent history: only `last_*` dictionaries, each overwritten (city_brain.gd:36-38).
- Why a mayor failed: first refusal reason only in FP, shown only if there is no politics line (activity_feature.gd:_on_mayor_decided).
- Image model participation: no badge/provenance on posters.
- Chat attribution is wrong in a way viewers cannot detect: lines credited to a mayor in the chat are written by one of the 3 flash models, not by that mayor's own model (chatter_minds.gd:1268-1280, :1343-1351), while the card says e.g. "Mei Kimura" [O].

### 3.3 Cadence problem for a live demo [I from constants]
FP day = 1200 s (world_scale.gd:108); turns spread over 0.9 of it (mayor_turns.gd:61): one mayor every 0.18 day = 216 s at 1x, 27 s at 8x. Orbit day = 12 s (sim_defs.gd:22): all five at once. So the orbit view is the "race" view; FP is the "story" view. A side-by-side comparison on foot at 1x takes ~18 minutes per round unless a parallel counterfactual exists.

### 3.4 Presentation constraints that new UI must respect
- FP HUD lint: owned text must not contain brand/system words (`BRAND_RE` hud_style.gd:29, covers Argon|DeepSeek|Kimi|Qwen|Grok|GMI|gemini|MiniMax|model|latency|cache|heuristic; enforced in fp_activity_test.gd:19, 317-331). Model names go in `S.badge` only; headings must avoid those words (use "Speed", "Orders", "Health").
- All 26 letter keys are bound in project.godot [input] (including backhoe keys), F1/F5/F9 are used; F2-F4 and F6-F8 are free [O: parsed project.godot]. New FP surfaces should hang off the League modal (L) as pages or take F2.
- boundaries.json: scripts/ai and scripts/sim must not import scripts/fp, scripts/ui or scripts/world, so the ledger lives in scripts/ai and widgets live in a new scripts/fp/arena/ feature (integration slice like activity/reporter, fp_features.gd:18-29) or in scripts/ui for orbit.
- AGENTS.md: gameplay-changing behaviour behind a flag in data/feature_flags.json; analytics/error log opt-in and local; never call the network outside GmiClient.

---------------------------------------------------------------------------------------------------

## 4. (b) Which model differences are real and measurable with what the game already records

Single choke point: every model call (mayor, support, residents, chatter, talk) goes through `GmiClient.chat_json` or `live_json` and ends in `_log` -> `call_logged(slim)` (gmi_client.gd:204-275, 603-614). A ledger subscribed to that one signal sees everything.

Recorded now:
| Datum | Where | Granularity | Notes |
|---|---|---|---|
| role, agent, model, day, source (live/cache/heuristic/failed), latency_ms, attempts, error, summary(140), raw(600), seq, request_id, trace_id | `GmiClient.log_records` (ring 300) / `call_logged` | per call | latency_ms covers retries+backoff; cache/heuristic show latency of the failed live attempt or 0 |
| live_ok/live_fail/cache/heuristic/latency_ms_sum/retries/breaker_open/breaker_skip | `GmiClient.stats` (gmi_client.gd:50) | GLOBAL only | `avg_latency_ms()` is global |
| last 20 live outcomes | `live_outcomes` | GLOBAL | feeds the single breaker/alerts |
| models that refused temperature | `temperature_of` | per model | Kimi-K3 takes only 1.0 (README) |
| per mayor: actions_ok, actions_rejected, treasury, pop, jobs, happiness, annexed, last_income/upkeep | `sim.mayors[mi]` (city_sim.gd:269-290, 3123-3127) | cumulative + current | acceptance rate is derivable per mayor |
| per mayor turn: thought, post, mood, per-action {ok, reason}, proposal, votes, source, latency, error, model, focus | `brain.mayor_state[mi].log` (12 entries, saved) | per turn | rejection reasons are the "mistake profile" |
| resident models: ok/fail/ms | `ResidentMinds.model_stats` (resident_minds.gd:96-107, saved :585) | per model | shown only in orbit People tab |
| per resident: model, source, plan_day, approve, mood | residents.gd:1016-1023 | per resident | batch model rotates daily |
| citywide pop/funds/happiness/jobs per day | `sim.history` (120 days, city_sim.gd:719-731) | CITY only | no per-district series |
| district approval/mood/leaving/complaints/protests | `Residents.district_mood(d)` (residents.gd:461-484) | current only | no history |
| image: live_submits/live_ok/live_fail/cache/prebaked/procedural, last_error | `GmiImageClient.stats` | global | |

NOT recorded (gaps):
1. Tokens/usage and cost: `usage` and `finish_reason` are parsed away (gmi_client.gd:413-428). Truncation by max_tokens (mayors 1500, residents 3600) is invisible. [U: whether every GMI model returns `usage`.]
2. JSON validity/repair per model: `extract_json` silently strips `<think>` and fences and fixes trailing commas (gmi_client.gd:503-520), `salvage_array` rescues truncated arrays (462-501), and `reasoning_content` is used when `content` is empty (421-422). None of this is flagged; "no JSON in reply" is only an error string. These are exactly the observable behavioural differences between hybrid-reasoning models.
3. Per-model aggregates for mayors/support/chatter (latency percentiles, failure classes, retries, replay share).
4. Replay latency: recorded entries carry no meta, so every replay shows 0.0s.
5. Snapshot staleness: a mayor decides on the prompt snapshot at send time and applies on landing; the age at landing (ticks/day boundary) is not stored, though it directly explains rejections for slow models.
6. District time series (pop, treasury, approval, annexed, orders/refused) and any per-model outcome trend.
7. Vote history and Speaker ruling history (only `last_council` + each mayor's last 12 `votes`).
8. Provenance (what each prompt contained) and the Gazette's source lines.
9. Prompts and prompt hashes; wall-clock timestamps.
10. Per-model health: ONE circuit breaker for all models (gmi_client.gd:54, 208, 298-302, 333-337); docs/runbooks/gmi-outage.md says "One model failing: the breaker is shared, so one dead model can trip it for all." Four consecutive service failures (any models) open it for 30 s and every call goes to cache/heuristic.

---------------------------------------------------------------------------------------------------

## 5. (c) Emergent vs scripted

Emergent (a model decides; the validated sim then makes it real): mayor actions/coordinates/taxes/grants/votes/proposals/posts; the Speaker's enact/repeal (partly overrides the vote count); the Chaos Director's type/place/narration; the Operator's priority permutation; the Gazette's framing; residents' commute/spend/evening/leave/protest and incident reactions (which decide how long an incident lives); chat and talk text (flavour; talk mood_delta/memory minor); poster slogan/art (leaf).

Scripted or heuristic (not model behaviour): the schedule of support agents (city_brain.gd:197-215); staggered turn order and span; max 7 actions; ordinance effects; the Speaker's hard rule (>= 2 yes to enact, >= 4 votes to reject, city_brain.gd:827, 835); `_replay_top_up` borrowing one heuristic build and one annex (city_brain.gd:411-431); `_heuristic_mayor` with hard-coded personalities (clean energy for argon/qwen/kimi, favourite big projects per mayor, flavour strings, proposal on day % 6 == 0, only grok votes no and only on clean_air_act/curfew; city_brain.gd:462, 492, 546-557); `_heuristic_chaos` 35% seeded; `_heuristic_operator` by population; `_heuristic_council` majority >= 3; resident heuristic planner; chat offline lines (SIGN_OFF per mayor, templates). Offline therefore is scripted theatre, and replay is recorded-but-non-reactive theatre. Both are honest only if labelled, and the street feed already labels them (LIVE/REPLAY/FALLBACK/OFFLINE).

Where non-determinism genuinely changes outcomes: (1) which model's answer lands first (orbit apply order, contested annex plots, treasury grants); (2) stale snapshots; (3) how many residents the active resident model mobilises to an incident; (4) timeouts turning a model's turn into a fallback (75 s day gate, 70 s mayor call timeout); (5) the Speaker/Chaos choices. None of these is displayed as "this happened because of timing".

---------------------------------------------------------------------------------------------------

## 6. Findings (ids F1-F16)

F1 [major] Shared circuit breaker couples all models (gmi_client.gd:54, 208, 298-302, 333-337; docs/runbooks/gmi-outage.md). One flaky/rate-limited model can flip the whole city to replay for 30 s during a live demo.
F2 [major] No per-model aggregates for mayors/support/chatter; the only per-model scoreboard is residents' `model_stats` in the orbit People tab (city_hud.gd:1097).
F3 [major] Offline/replay shows 0.0s and non-reactive mayors; replay entries have no meta (gmi_client.gd:523-526); screenshot 01 shows five bankrupt "steady" mayors. A keyless web visitor is in exactly this state (web-deploy.md: "no server-side key by design").
F4 [major] Mayor-to-mayor interaction is thin: 0 grants/56 turns, 3/56 turns name a mayor; mayors never see council statement, operator advice, chaos reasoning or rank (city_brain.gd:280-329); no directed channel.
F5 [major] Council disagreement is invisible: vote names hidden in orbit (city_hud.gd:971) and truncated in FP (activity_words.gd politics), Speaker overrides unexplained, no ruling history.
F6 [major] Missing data for model comparison: tokens/usage, finish_reason, JSON repair flags, prompt hash, staleness, district history (section 4).
F7 [major] Persona x model x district x resident-model confound: outcome trends per district cannot be attributed to a model; need a same-state, neutral-persona counterfactual (resident model rotation: resident_minds.gd:126, 169).
F8 [major] Chat lines credited to a mayor are written by flash models, not the mayor's model (chatter_minds.gd:1268-1280, 1343-1351).
F9 [minor] League computes `orders`/`refused` but never shows them (reporter_desk.gd:193-194; reporter_league.gd:20-29).
F10 [minor] `ResidentMinds.reacted` has no listener; incident reactions and who-helped are invisible beyond chat lines.
F11 [minor] `log_records` ring (300) overflows within a few live game days (every resident batch, chatter round and talk line is a record) and has no timestamp; Gazette provenance (`day_feed`) and support-agent history are discarded (city_brain.gd:696, 36-38).
F12 [minor] Orbit and FP differ in whether mayors can react to each other within a day: only staggered street mode shows same-day cross-talk (city_brain.gd:115-131 vs 299-304).
F13 [minor] Demo cadence: one decision per 216 s at 1x on foot (mayor_turns.gd:61, world_scale.gd:108).
F14 [minor] Constraint: FP lint forbids model/latency words in owned text; all letters are bound; ai-core cannot import UI (section 3.4).
F15 [minor] Naming consistency leak: chaos narration and operator note are not de-branded (city_brain.gd:741, 794; shown raw by the city_hud.gd:752-758 banner and the City Hall tab, city_hud.gd:972-986). Replay day-4 narration reads "Grok-4.5's industrial quarter"; day 8 "DeepSeek-V4". This is the same class of issue the owner just fixed for orbit mayor names (83fe2e8). A policy call: for a model showcase brand mentions may be desired, but they should be consistent.
F16 [idea] Approval has no stakes (no election/recall/budget effect) and rank is not fed back, so rivalry exists only as persona prose. Cheapest stake: show rank in the prompt (P7); larger: periodic budget bonus by approval (L, gameplay).
Also [minor, image]: posters carry no provenance of the image model; live images are capped (6/day, 30/session) so most art is prebaked/procedural; `meta.source == "live"` is available on `bus.poster_ready` (gmi_image_client.gd:652, poster_feature.gd:335).

---------------------------------------------------------------------------------------------------

## 7. Proposals

Ordering rationale: P0 and P1 are the substrate and the stability fix (both also useful with no UI); P2-P6 are the five legibility additions; P7 gives them content; P8 fixes attribution. With 9 days to 12 Nov, a safe path is P0 -> P1 -> P2 (League columns first) -> P3 -> P4 -> P7 (flag, default off until tested live) -> P5 -> P6; P8 any time. Everything below is verifiable headless with fakes that already exist (tools/tests/support/gated_client.gd; `FakeNet extends GmiClient` overriding `_post` in tools/tests/fp_ops_test.gd:14-20; K.make_ctx in fp_kit.gd), and `tools/gate.sh quick`.

### P0. Telemetry substrate: ModelLedger + enriched call records + district history  (effort M)
Reuse: `GmiClient.call_logged(slim)`; `CityBrain.mayor_decided(mi, entry)` (keys actions[].ok/reason, source, latency_ms, error, proposal, votes, model); `sim.mayors[mi]` counters; `ResidentMinds.model_stats`; `Residents.district_mood(d)`; `sim._end_day_rest()` history append (city_sim.gd:719-731).
Build:
- new `scripts/ai/model_ledger.gd` (class_name ModelLedger, RefCounted): `note_call(rec)`, `note_turn(mi, entry)`, `snapshot()` rows {model, label, roles, calls, live_ok, live_fail, replay, fallback, offline, retries, p50_ms, p95_ms (live only, last 50), errors by class (http code / network / "no JSON"), repairs, tokens_in/out, accept% for mayors, health}; bounded ring of events (<= 400) for P5; to_dict/from_dict bounded. Owned by CityBrain (`brain.ledger`) so FpContext/HUD reach it without new plumbing.
- `gmi_client.gd`: in `_post` keep `usage` and `finish_reason`; add `classify_reply(content)` flags (think_tag, fenced, trailing_comma, salvaged, reasoning_only) next to extract_json; add `prompt_chars`/`prompt_hash` in `_new_result`; copy into slim log. In record mode store `{day, data, meta{latency_ms, model, attempts, tokens}}` (backward compatible: `_cache_lookup` already reads `.get("data")`), and expose `result["recorded_latency_ms"]` on a cache hit so replay can show "recorded 11 s".
- `city_sim.gd` + `save_shape.gd` + `docs/save-schema.md`: `district_history` ring (120 days) of per-mayor {pop, jobs, treasury, happiness, approval, annexed, ok, rej} appended in `_end_day_rest`.
- `city_brain.gd`: `council_history` ring, `paper["sources"] = feed` before `day_feed.clear()` (696), `entry["staleness"]` (ticks between send and land).
Degrade: offline rows carry source mix only (no percentiles); replay rows show recorded latency once a new recording exists, else "-". Web: pure in-memory, bounded; save growth tiny.
Verify headless: `tools/tests/ai_ledger_test.gd` (FakeNet `_post` returning usage + fenced/think-tagged JSON; assert repairs, tokens, p50/p95 over 20 injected records, acceptance from synthetic entries, save round trip); extend save round-trip tests; `tools/gate.sh quick`.
Risk: low-medium (hot path in GmiClient; new dict keys are optional for existing stubs). Showcase 5 / stability 6.

### P1. Per-model circuit breakers + health lights  (effort M)
Reuse: `CircuitBreaker` (scripts/ops/circuit_breaker.gd, has peek_state/retry_in_ms/open_count), `GmiClient.breaker_changed`, `live_outcomes`.
Build: `GmiClient.breakers: Dictionary model -> CircuitBreaker`, `_breaker_allows(model)`; keep `client.breaker` as an AGGREGATE (open only when every model seen in the last window is open) so `alerts.gd` (gather_inputs) and `ActivityFeature._live_state()` keep their meaning; `breaker_state(model := "")`; per-model `live_outcomes`. UI: 5 mayor-colour pips + 1 "services" pip beside the feed's state badge (`activity_feed.gd` `_header`/`set_state`, pips are shapes with tooltip, no owned text so BRAND_RE holds) and in orbit replace/extend `_ai_label` (city_hud.gd:250). Colours: green = last 5 ok and p95 < 60% of timeout; amber = retries/repairs/slow; red = breaker open or last 2 failed; grey = replay/offline. Flag `gmi_model_breakers` for rollback.
Degrade: offline = all grey "replay"; web identical.
Verify: extend fp_ops_test.gd with FakeNet: fail model A x4 -> A open, B still `source == "live"`, aggregate closed; all models fail -> aggregate open, `gmi_breaker_open` alert rule still fires (OpsAlerts.evaluate inputs); fp_activity_test pip count + LEAK_RE still passes.
Risk: medium (shared infra; keep default behaviour switchable). Showcase 4 / stability 8.

### P2. Arena scoreboard (live model leaderboard + health lights)  (effort M; FP columns alone S)
Reuse: ledger snapshot; `ReporterDesk.standings()` rows (already have orders/refused, model badge, color); `district_history` for sparklines; `minds.model_stats` for resident models.
UI: (a) FP: add columns to `ReporterLeague.COLS` ("Orders" accepted share, "Speed" p50 or "rec 9 s"/"-", health dot in `_who`), plus a second page "Services & minds" in the same modal (Tab flips pages) listing the 6 support agents, 6 resident models and 3 chatter models with calls/health. No new key (L is already bound). (b) Orbit: append `_rich("Arena")` as tab index 7 (city_hud.gd:398-407) rendered by `_render_arena()`: per mayor row [health dot] name, model, turns live/replay/fallback, speed p50/p95, accept%, repair%, action mix bar, tokens, sparkline of pop/treasury/approval; service rows below. A custom `_draw` Control for sparklines follows the existing `_rci` precedent.
Degrade: offline/replay: speed column shows "replay" (or recorded speed), accept% still real because the sim validates replayed actions, health grey; web: no extra network.
Verify: fp league test through `table_lines()` (reporter_league.gd:98-110) asserts the new columns and no BRAND_RE hit in `S.owned_texts`; new `ai_arena_test.gd` builds ledger rows and asserts the orbit text and ordering; `fp_orbit_names_test.gd` pattern for the HUD.
Risk: low. Showcase 9 / stability 3.

### P3. "Ask all five" counterfactual panel (same state, five models, live race)  (effort M)
Reuse: `CityBrain._mayor_system_prompt(mi)` / `_mayor_user_prompt(mi, day)`; `client.live_json` (live-only, never touches the role cache or saves, like ChatterMinds); `_heuristic_mayor.bind(mi)` as fallback; `ActivityWords.summarize/action_words` for action text; `D.debrand`; ledger for latency bars; chat's `/mayor` parsing (chat_feature.gd:246-256) for a `/ask <text>` entry; orbit Powers tab (decree box) for a button.
Build: `CityBrain.preview_all(question, persona_mode)` emitting `preview_answered(mi, result)`; persona_mode in {own, neutral} where neutral swaps the persona sentence (`m["persona"]`) for one shared line, so any difference is the MODEL; question appended as "OVERSEER QUESTION". Nothing is applied (`apply_action` never called). Show per column: model badge, live elapsed-time bar that fills, finish order 1st..5th, thought, post, proposed actions, and cheap plausibility flags from `sim.district_rect`, treasury vs `D.BUILDINGS[..].cost`. Budget like chat (D12): 1 ask / 60 s, 5 / day. New FP feature `scripts/fp/arena/` (modal via push_modal) opened by `/ask`; orbit overlay Control.
Degrade: no live -> each column shows that mayor's last RECORDED turn (replay cache nearest day) with a "recorded, did not hear your question" tag, or the scripted planner tagged OFFLINE; keyless web visitor sees this. With a key it is live (CORS allowed per web-deploy.md). [U: browser per-origin connection limits vs 5 parallel + resident batches; a 429 would show as a red column, which is itself legible.]
Verify: `tools/tests/ai_ask_all_test.gd` using GATED (`each = true`), release calls in permuted order and assert finish ranks; assert sim state byte-equal before/after (`sim.to_dict()`), `actions_ok` unchanged; budget refusal on the second ask within 60 s; offline path yields 5 non-live results; prompt contains the question and the neutral persona line when requested.
Risk: low-medium (5 extra calls, bounded). Showcase 9 / stability 2.

### P4. Council vote board + ruling history  (effort S-M)
Reuse: `brain.proposals[key] {by, day, votes{id: yes/no}}`; `brain.last_council`; `sim.ordinances` (key -> day); entries' `votes`/`proposal`; `D.ORDINANCES`; `_votes_by_name`.
Build: `brain.council_history` (<= 20 rulings: day, key, per-mayor votes snapshot, outcome enacted/rejected/deferred/repealed, statement, source) written in `_run_council` (city_brain.gd:808-841); optional `vote_notes` field in the mayor JSON (<=60 chars, schema line city_brain.gd:277, stored in `entry["vote_notes"]`) so a NO has a reason; override flag when ruling disagrees with the tally (enact with < 3 yes, defer with >= 3). UI: orbit City Hall tab (city_hud.gd:947-996) replaces "N yes N no" with a 5-seat grid per proposal (mayor colour, Y/N/-, proposer star) and a Speaker line "passed 3-2" or "OVERRIDE: passed with 2"; FP: tally + override in the council card (`activity_words.gd` politics/council_words, `activity_feature._on_council_ruled`) and a "Council" page in the arena modal.
Degrade: offline heuristics: Grok no on clean_air_act/curfew, rest yes (board shows 4-1 splits only for those two); replay shows recorded votes. Web identical.
Verify: unit test of `_run_council` with scripted proposals and GATED client (history entry, override flags), HUD text assertion, fp_activity_test for tally words and LEAK_RE.
Risk: low (the schema addition affects live prompts slightly: flag it with P7). Showcase 7 / stability 2.

### P5. Decision timeline / flight recorder (+ divergence diff)  (effort M; journal+diff tool +S)
Reuse: ledger event ring (start = landing - latency_ms, because `call_logged` fires at landing; mayor start also from `mayor_thinking`), `trace_id`/`request_id` (already sent as X-Trace-ID/X-Request-ID, so a bar maps to GMI-side logs), `raw` (600 chars), `entry.actions[].reason`, `Trace.begin("day N turn id")` labels (city_brain.gd:163), `OpsSink.append` for an opt-in local journal.
UI: swimlane Control: lanes = 5 mayors, Gazette, Council, Chaos, Operator, Citizens/Inspector, Residents (aggregated), Chatter; x = real time with game-day dividers; bar width = latency, colour = source (live/replay/fallback/offline), ticks for rejected actions, flags for proposals/votes/grants; click -> detail (thought/post/actions/raw/IDs). Orbit tab and an arena-modal page. Divergence: `GRIDFALL_RUN_JOURNAL=1` (flag `run_journal`, local file, per AGENTS.md) writes one JSON line per decision; `tools/ops/run_diff.py A B` reports per agent/day action-set Jaccard, same-first-action rate, text similarity, district outcome deltas; plus an optional in-game "vs recorded" chip comparing a live turn with the replay-cache turn of the same day (approximate: prompts changed since recording).
Degrade: replay bars are fixed-width hatched "replay" unless recorded latency exists; web keeps only the in-memory ring.
Verify: `ai_timeline_test.gd` (GATED each-release permutation -> lanes and start/land order; ring bound), pytest for run_diff over two fixture journals (tools/pytests, coverage gate).
Risk: low. Showcase 8 / stability 3. Cut for time: swimlane + detail only (M).

### P6. Interaction graph ("who said what to whom") + provenance  (effort M)
Reuse: `_mayor_user_prompt` inputs, `proposals`/`votes`, entries' `actions` (grant), thoughts/posts for mentions (same name/surname/brand matching idea as `D.debrand`), `Residents.messages_for`, Gazette `paper["sources"]` from P0, `last_chaos` (x,y -> district owner), `sim.grid_priority`, decree.
Build: `entry["inputs"]` = {posts_from[], headline, letters[ids], proposals[], decree} captured when the prompt is built (store per mayor in `_run_mayor`, attach in `_land_mayor`); `scripts/ai/interaction_graph.gd` (RefCounted) `build(window_days)` -> nodes (5 mayors, Council, Gazette, Operator, Chaos, Residents-by-district, Player) and weighted edges of kinds read, mention, vote-with/against, grant, letter, headline, targeted-by, ordered-by. UI: pentagon with mayor colours, edge thickness = weight, edge colour = kind, click -> quotes; `_draw` Control reused in orbit tab and arena modal page.
Degrade: offline heuristics have no mentions: show read/vote edges and the caption "offline: mayors work alone"; replay shows recorded mentions (old names). The graph will look sparse until P7 lands (data: 3/56 and 3/56).
Verify: `ai_graph_test.gd` with synthetic entries -> exact edge set; assert `entry["inputs"]` matches what the prompt text actually contains.
Risk: low; value depends on P7. Showcase 6 / stability 1.

### P7. Mayor context v2 (flag `mayor_context_v2`, default off until tried live)  (effort M)
Reuse: `last_council.statement`, `last_operator.note/advice`, `last_chaos.reason/narration`, `ReporterDesk.standings` (move the pure function to scripts/ai or duplicate the 20-line score), existing `grant` action, `sim._act_grant`.
Build: add prompt lines in `_mayor_user_prompt`: "COUNCIL RULED day N: ...", "GRID OPERATOR: ...", "CHAOS DIRECTOR: ..." (de-branded), "LEAGUE: you are 3rd of 5 (people, jobs, approval, funds gaps)"; optional JSON fields `message_to {mayor, text<=120}` (max one/day, stored in `brain.notes[to]`, shown next prompt as "NOTE FROM <name>") and `request {from, amount, reason}` answered by the existing `grant` action; one system-prompt sentence on when a grant is sensible (Kimi's persona already says it brokers deals).
Degrade: replay/offline unaffected (cache ignores prompts; heuristics ignore the new lines); notes only exist when a live model writes them.
Verify: tests/dump_prompts.gd-style test asserting each new line appears only when its source state exists and is de-branded; brain_live_test (heuristic) unchanged; ask-all-five run to compare live outputs with the flag on/off (live, owner-run).
Risk: medium (changes live behaviour and prompt size; more JSON fields can raise repair rates, which P0 will now show). Showcase 8 / stability 2.

### P8. Attribution fixes: chat voices and press-run cards  (effort S)
- Chat: either label lines credited to a mayor but written by a flash model as the mayor's "press office" (S), or call the mayor's own model for lines credited to that mayor (M; uses `live_json("chatter","mayor-voice", D.MAYORS[mi]["model"], ...)`, falls back to the flash line on failure); add the model badge to the chat row if `chat_panel_row.gd` supports it [U: not read].
- Press run: when `bus.poster_ready` (poster_feature.gd:335) arrives with `meta.source == "live"` (gmi_image_client.gd:652) push an activity item "Campaign poster printed" with the hy-image badge and the originating mayor.
Degrade: unchanged offline (no live images, no card). Verify: fp_activity_test with a fake meta; chat test asserting the line's model field. Risk: low. Showcase 5 / stability 1.

---------------------------------------------------------------------------------------------------

## 8. Suggested demo choreography for 12 Nov (what the proposals buy)
1. Start in orbit at 4x with a key: five cards flip to "thinking" together; Arena tab shows the race (speed bars), health pips, acceptance, repairs.
2. Type "Ask all five: your district is out of power and funds are -$1,500. What do you do?" -> P3 panel, neutral-persona toggle on, five answers, five latencies.
3. Open City Hall: vote board with names, a Speaker override badge; Timeline shows who landed first and which orders were refused.
4. Switch to the street: feed card + beacon for one decision, League with Orders/Speed columns, chat with the mayor's real voice (P8).
5. Close with the graph (needs P7) or, if short on time, the timeline.

## 9. Unknowns (not verified)
- Whether every GMI model returns `usage`/`finish_reason` (P0 assumes OpenAI-compatible; would be confirmed on the first keyed run).
- Real per-model latency distributions and failure rates today (only the trailer capture shows 9-15 s for three mayors; no log of a recent live run was read).
- Browser connection limits for 5 extra parallel calls on the web build; whether the web build ever has a key at the webinar (deployment never holds one: web-deploy.md).
- Whether current live prompts produce more mayor-to-mayor interaction than the recorded 56 turns.
- Whether `chat_panel_row.gd` can render a model badge (not read).
- Any pixels: nothing was rendered, all UI claims are from code and existing screenshots.
