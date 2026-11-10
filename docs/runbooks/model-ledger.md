# Model ledger (who is fast, who is refused, who is failing)

Flags `model_ledger` (default on), `arena_tab` (default on) and `mayor_voice_calls` (default off). The
ledger counts every model call and every mayor turn in memory (`brain.ledger`, scripts/ai/model_ledger.gd)
so a viewer can see how the models differ in a live, non-deterministic run.

## Where to look

- Street, `L` (the league): Orders (the share of a mayor's orders the city carried out; `no data` until
  one has been counted, with a tooltip: the count starts with the ledger, so a save from before it, or a
  fresh city, reads `no data` until new turns land), Speed (the median time to answer; `replay` when the
  turns were recorded answers; `-` when nothing live or recorded has come) and a health light by each
  name (green good, amber shaky, red down, grey replay, a small square scripted, hollow idle). The
  table is 960 px wide so every district name shows whole at 1280x720; the model of each mayor is a
  badge, the only street text that names a model. `Tab` flips to Services & minds (and closing the league resets it to the mayors' table): one row per
  model the city uses outside the mayors' chairs (Gazette, Council Speaker, Chaos Director, Grid
  Operator, Citizen Voices, Street Inspector, the residents' minds, the chat voices) with calls, live,
  failed, replay, scripted, speed and health. A row counts only that model's service calls: a model
  that also sits in a mayor's chair does not carry the mayor's answers here. Street text on this
  page names jobs and people (Gazette, Residents, Chat...); the model of a row is its badge. The light has
  a shape as well as a colour (circle good, triangle shaky, diamond down, ring with a dot replay, small
  square scripted, empty ring idle). The panel keeps its place when Tab flips the page.
- Planner (orbit): the Arena tab after People. A block per mayor, person first, the model in the
  sub-line: the light and its word, turns live / replay / fallback / offline, time to answer, accepted
  orders, repairs, tokens, errors by class and the order mix. Services follow. The tab is the 8th of a
  strip that scrolls (the arrows at its right end): all eight titles cannot fit in the 384 px panel.
  Lights and bars are background-coloured spans over `#` characters, because the web build's font has
  no U+25CF or U+2588.
- The chat: a line credited to a mayor carries PRESS OFFICE (a fast chat model or the offline script
  wrote it) or OWN WORDS (the mayor's own model, `mayor_voice_calls` on). When the full chip would run
  into the time stamp (a long name in a narrow panel) it shortens to PR or OWN and says what it means as
  a tooltip. A live campaign poster adds a
  "Campaign poster printed" card to the street feed with the image model's badge.

## Reading the numbers honestly

- "Time to answer" is the call's `latency_ms`: it includes retries, back-off and waiting behind the
  other calls in flight. It is how long the city waited, not how fast a model is.
- A mayor answers once a game day, so a p50 or p95 over a short run rests on a handful of calls: the
  Arena shows last, mean and n below 5 live answers and a p95 only from 5 on.
- Replay and scripted turns are labelled as such and never get a speed. Accepted orders (the Arena's
  and the league's Orders, one counter) count the model's live and replayed orders since the ledger
  began (a save from before it starts at zero); the sim validates each order whoever wrote it. The
  scripted planner's orders after a failed or skipped call are not counted, they are not the model's.
  A replayed day can carry up to two orders borrowed from the planner (the replay top-up).
- A light turns amber for a failure, a retry, a cut-off (`salvaged`) or reasoning-only answer among the
  last 5 outcomes, or a p95 over 30 s from 5 answers on (one slow answer does not). A code fence, a
  `<think>` block or a trailing comma is a model's house style: counted as a repair (the Arena shows the
  share) but the light stays green. Grey is no live answer and at least one recorded one; `scripted` is
  nothing but the built-in planner's answers.
- A call that was still in flight when New City or Load replaced the city is not counted in the new
  city's ledger (the client numbers its calls; clearing the ledger remembers the last number). Ask the five calls are isolated: the ledger does not count them.
- Tokens come from the API's `usage` on the last attempt of a call; a reply without `usage` adds none.
- Repairs: `think_tag`, `fenced`, `trailing_comma` (also NaN), `salvaged` (cut off at the token limit),
  `reasoning_only`. A high repair share is a model that needs more tolerance, not a failure.

## What the red light means

The last two live calls of that model (or mayor) failed. Open the GMI Log (orbit) for the error text, or
the Arena tab for the classes (an HTTP code, `network`, `no JSON`). A 429 on every model is a rate limit
on the key: lower the load (Live GMI off, slower speed). One model red among green ones is that model.
See gmi-outage.md for the breakers.

## Switching it off

`GRIDFALL_FLAGS=model_ledger=off` counts nothing (Speed reads `-` and the lights read idle; Orders
falls back to the sim's whole-city count). A ledger an older save carried is not loaded while it is
off, and the save passes it on untouched, so switching the flag back on finds it again, `arena_tab=off` removes
the Arena tab. `mayor_voice_calls` stays off unless you want the mayors' own models to write their chat
lines: it costs 1 to 3 extra live calls per chat round on the player's own key.

## Verify

`tools/tests/ai_ledger_test.gd`, `tools/tests/ai_ledger_review_test.gd`, `tools/tests/ai_arena_test.gd`,
`tools/tests/fp_league_ledger_test.gd`
and `tools/tests/fp_mayor_voice_test.gd` pass under `tools/gate.sh quick`.
