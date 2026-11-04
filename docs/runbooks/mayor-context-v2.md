# Council vote board and mayor context v2

Two things that make the five models answer each other. The council vote board is always on and changes no prompt. Mayor context v2 (flag `mayor_context_v2`, **default off**) changes what live models read and may write; nothing about it has been measured with a live model yet, so try it with a key before the demo.

## The council vote board (always on)

Every ruling of the Council Speaker leaves a record per proposal (`brain.council_history`, the last 20): how each of the five mayors voted, the outcome (passed, rejected, deferred, repealed) and whether the Speaker went against the count. Passing with fewer than 3 yes, or keeping a proposal out with 3 or more, is an **override**.

- Orbit, City Hall tab: each proposal on the floor is a row of five seats (mayor colour, Y, N or -, a star on the proposer) with its tally, "Speaker, day N: deferred 2-1" for one held over, then a **Council record** with the last six rulings ("passed 3-2", "OVERRIDE: passed with 2").
- Street: the council card's headline carries the counts ("Passed Youth Curfew 3-2", "Rejected Tourism Campaign despite 3 yes (override)"; a long ruling lists what fits and then "+N more") and its last line says who voted how in first names.
- A rejected proposal is any proposal that got four or more votes and was not enacted, whatever the split, so read the seats, not just the word.
- Offline planners vote in unison (only Duke Granger votes no, and only on Clean Air Act and Curfew, which no planner proposes), so an offline board is almost all 5-0. Replay shows the recorded votes. The recorded Speaker does not read today's tally, so a replayed ruling is never called an override: it reads "rejected" or "passed" without a count when it disagrees with the votes (the orbit board adds "(replay)" or "(offline)"; the street card carries the REPLAY badge). Only a live Speaker is held to the count.

## Mayor context v2 (flag `mayor_context_v2`)

Try it: `GRIDFALL_FLAGS=mayor_context_v2=on` (or `"mayor_context_v2": true` in `user://feature_flags.json`), a key in use, then watch a few game days.

What changes for a live mayor, only when the state it reports exists:

- The user prompt gains `COUNCIL RULED day N: ...` (the count and override of each proposal, then the Speaker's words), `GRID OPERATOR (day N): ...` (the shed order in person names, note and advice), `CHAOS DIRECTOR (day N): ...` (what struck, where, in whose district, why), `LEAGUE: you are 3rd of 5 (gaps to Duke Granger in 1st: people -120, ...)` (the street league's rank), `REASONS GIVEN FOR VOTES`, `NOTE FROM <name>` and `REQUEST FROM <name>`. A `MAYOR IDS` line maps every display name to the lowercase id (argon, deepseek, kimi, qwen, grok) that answer fields take; text about other agents is de-branded.
- The reply may carry `vote_notes` (60 characters per vote), `message_to` (`{"mayor": id, "text": up to 120 characters}`, one a day) and `request` (`{"from": id, "amount", "reason"}`, one a day, at most $3000). A note is shown to the addressee once, on their next turn. A request is answered by an ordinary `grant` order; the sim still refuses a grant over the giver's treasury. A grant `to` written as a display name or surname is understood.
- A note or request shows on the street as a rounded speech-bubble card ("Ada Okafor: Told Mei Kimura", the words in quotes), and in the orbit City Hall tab under "Notes between mayors". The Gazette's feed hears them, and hears a ruling that went against the vote.
- Replay and offline planners never write notes, so with no key nothing new appears except the lines in prompts nobody reads.

Cost: 943 more characters of system prompt and up to about 900 more of user prompt per mayor turn (all lines present, measured on the test city), and three more optional JSON fields, which can raise a model's repair rate (the GMI log shows it). To compare, use Ask the five with the flag off and on.

Off, prompts and replies are exactly what they were (`tools/tests/fp_mayor_context_test.gd` pins the prompt text byte for byte against `tools/tests/fixtures/mayor_prompts_golden.json`). Saves gain `council_history`, `notes` (empty with the flag off) and a `tally` on `last_council` whatever the flag says, because the council vote board is always on. The golden hashes the whole prompt, including the sim's district and city summaries and the map, so a change to those fails the test: regenerate it with `tools/gen_mayor_prompts_golden.gd` (usage in its header) and read the golden's full-text diff, which must show only that change.

## Verify

`tools/tests/fp_council_log_test.gd` (records, overrides, board text), `tools/tests/fp_mayor_context_test.gd` (golden, new lines, a scripted live exchange with a grant, saves), `tools/tests/fp_activity_test.gd` (street cards, no brand words) and `tools/tests/fp_orbit_names_test.gd` pass under `tools/gate.sh quick`.
