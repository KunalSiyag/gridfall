# Model ledger (who is fast, who is refused, who is failing)

Flags `model_ledger` (default on), `arena_tab` (default on) and `mayor_voice_calls` (default off). The
ledger counts every model call and every mayor turn in memory (`brain.ledger`, scripts/ai/model_ledger.gd)
so a viewer can see how the models differ in a live, non-deterministic run.

## Where to look

- Street, `L` (the league): Orders (the share of a mayor's orders the city carried out), Speed (the
  median time to answer; `replay` when the turns were recorded answers; `-` when nothing live or recorded
  has come) and a health light by each name (green good, amber shaky, red down, grey replay or scripted
  only, hollow idle). `Tab` flips to Services & minds (and closing the league resets it to the mayors' table): one row per
  model the city uses outside the mayors' chairs (Gazette, Council Speaker, Chaos Director, Grid
  Operator, Citizen Voices, Street Inspector, the residents' minds, the chat voices) with calls, live,
  failed, replay, scripted, speed and health. A row counts only that model's service calls: a model
  that also sits in a mayor's chair does not carry the mayor's answers here. The light has a shape as
  well as a colour (circle good, triangle shaky, diamond down, ring with a dot replay, empty ring idle).
- Planner (orbit): the Arena tab after People. A block per mayor, person first, the model in the
  sub-line: the light and its word, turns live / replay / fallback / offline, time to answer, accepted
  orders, repairs, tokens, errors by class and the order mix. Services follow. The tab is the 8th of a
  strip that scrolls (the arrows at its right end): all eight titles cannot fit in the 384 px panel.
  Lights and bars are background-coloured spans over `#` characters, because the web build's font has
  no U+25CF or U+2588.
- The chat: a line credited to a mayor carries PRESS OFFICE (a fast chat model or the offline script
  wrote it) or OWN WORDS (the mayor's own model, `mayor_voice_calls` on). A live campaign poster adds a
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
- A light turns amber for a recent failure, repair or retry, or a p95 over 30 s from 5 answers on (one
  slow answer does not). Ask the five calls are isolated: the ledger does not count them.
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
falls back to the sim's whole-city count), `arena_tab=off` removes
the Arena tab. `mayor_voice_calls` stays off unless you want the mayors' own models to write their chat
lines: it costs 1 to 3 extra live calls per chat round on the player's own key.

## Verify

`tools/tests/ai_ledger_test.gd`, `tools/tests/ai_ledger_review_test.gd`, `tools/tests/ai_arena_test.gd`,
`tools/tests/fp_league_ledger_test.gd`
and `tools/tests/fp_mayor_voice_test.gd` pass under `tools/gate.sh quick`.
