# Ask the five (what-if panel)

Flag `arena_ask`, default on. One question goes to all five mayors' models at once and the answers are only shown: nothing is applied to the city. First person: type `/ask <question>` in the chat (a bare `/ask` shows the last answers again). Orbit: Powers tab, **Ask the five (what-if)**. Esc or Close leaves the panel.

## Demo it with a key

1. Start with a key in use (`GMI_API_KEY` on desktop, or paste it on the GMI Cloud page and press **Test** in the web build). The panel's status line says "all five answered live" and every column carries a **LIVE** tag and a finish order; when some calls failed it says "3 of 5 answered live, 2 fell back"; without a key it says the question was not sent and the models were not asked.
2. Let the city grow a few days so the districts differ, then ask something concrete, for example `/ask Your district just lost power and the treasury is at minus 1500. What do you do?`.
3. Watch the bars fill (they run against the 45 s time budget) and the 1st to 5th labels appear: that is the race (only live answers take a place: a column that fell back shows a dash, so with two failures the live ones read 1st to 3rd). A call still silent after the 45 s budget lands as a failed column ("timed out after 45 s"). Read the orders first, then the post and the thought. Orders in red carry a flag (outside the district, the treasury cannot cover it, unknown order, past the daily limit); they are checks, not what the sim would do.
4. Flip **Same persona for all five**, wait a minute and ask the same question again: every mayor now gets one shared persona line. That narrows the differences but does not remove every input: the persona sentence is the only thing swapped, and each mayor still sees its own district, treasury, recent thoughts and the other mayors' posts. Without a key the switch changes nothing (its tooltip says so).
5. Budget: one ask per 60 s and five per game day, shared by the street and the orbit panel. A refused ask is a toast and a line in the panel ("ask again in 31 s", "5 questions for today"), not an error. The budget is kept on the key's session, so New City and Load do not reset it, and a new ask is refused as "busy" while an earlier run's calls are still in flight. Each ask costs five live calls plus whatever the prompts' tokens cost on the key.

## What a failed column looks like

A mayor whose live call failed shows a red "Live call failed: ..." line with the scrubbed error (the key never appears), the recorded or offline tag and that mayor's last turn from the replay cache instead (a session's own live turns are never passed off as a recording). A rate limit reads `HTTP 429 ...`: five parallel calls can meet one when the key's quota is small. That is legible on purpose. The calls use the isolated role `arena`, so they never count towards any circuit breaker, the live-failure ratio (the street's Reconnecting badge), the live counters or the city's retry count (their retries are `stats.side_retries`): a 429 storm in the panel cannot turn the city to replay. If the city itself is struggling (`OPS_ALERT gmi_breaker_open`, cards showing `cache`), see [gmi-outage.md](gmi-outage.md); with the mayors' breaker open the panel asks nobody (a failing residents or chatter group does not count: it says nothing about the mayors) and shows recorded or offline columns.

## What a keyless visitor sees (and the web build without a key)

No key, `GRIDFALL_OFFLINE=1`, the `gmi_live` kill switch or an open mayor breaker: no call goes out. Each column shows that mayor's last recorded turn nearest today from the replay cache, tagged **RECORDED** with the note "Recorded from another game, did not hear your question." (its places and money belong to the game it was recorded in, so some orders are flagged as outside your district), or, with nothing recorded, the scripted planner tagged **OFFLINE**. No finish order is shown (nothing raced). The text answers a question nobody asked it, which is why the tag is there; the status line says the question was not sent. The budget still applies (the same recordings come back each time, so there is little reason to re-ask).

## Switching it off

`GRIDFALL_FLAGS=arena_ask=off`, or set `"arena_ask": false` in `user://feature_flags.json`: `/ask` is then an ordinary chat line and the Powers button is not built.

## Verify

`tools/tests/ai_ask_all_test.gd` (core, budget, isolation, offline), `tools/tests/fp_arena_test.gd` (street modal) and `tools/tests/fp_arena_orbit_test.gd` pass under `tools/gate.sh quick`.
