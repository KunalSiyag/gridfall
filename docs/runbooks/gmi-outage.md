# GMI outage or degraded inference

## Symptoms

- Mayor cards and the GMI Log show `cache` or `heuristic` instead of `live`.
- Web build: the street badge reads Reconnecting (it needs at least three live calls seen, most of them failed), or the GMI Cloud page's **Test** button says "Blocked by the browser or offline" or "Key rejected (401)".
- Console lines like `OPS_ALERT gmi_breaker_open` or `GMI_FAIL chatter/player on <model>: HTTP 503 ...` (one per failed live call; a repeat of the same line is not printed again).
- The chat says "The mayors are busy fighting right now. Chat later." (no residents yet and the mayors' call failed), or a resident says they can't think straight with the mayors fighting (a talk reply failed or took over 8 s).
- Days take the full 75 s wait before advancing.

## Confirm

1. Web build, before anything else: press **Test** on the in-game GMI Cloud page (Esc, Settings, GMI Cloud). `Key works` means the path is fine and the trouble is load or a model; `Key rejected (401)` is the key; `Rate limited` is a quota; `No answer from GMI in 12 s` is a slow or stalled answer, not a CORS block (press Test again); `GMI answered an error (HTTP n)` means the key reached GMI and the test call failed (402 is usually credit, 400 or 404 a model not enabled for the key); `Blocked by the browser or offline` is a CORS block or no connection: run `tools/demo_check.sh <instance URL>` and read its `build` and preflight lines, then F12, Console and Network for the CORS error, which names the header. (An image built before the browser-header fix is blocked whatever GMI's preflight says, but it also has no **Test** button: if the page has none, the image is old, rebuild it; `demo_check.sh` says so on its `build` line.) The **Test** button is refused under `GRIDFALL_OFFLINE=1` like every other call. `python tools/ops/model_check.py` (from your shell, key in the environment) lists any configured model GMI no longer serves.
2. Check the key is set: `test -n "$GMI_API_KEY" && echo set`. Never paste the key into issues or logs.
3. Check `GRIDFALL_OFFLINE` is not `1`.
4. Call the API directly (replace nothing, the key comes from the environment):

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' https://api.gmi-serving.com/v1/models \
     -H "Authorization: Bearer $GMI_API_KEY"
   ```

   `401/403` is a key problem, `429` is rate limiting, `5xx` or a timeout is an outage.
5. With `GRIDFALL_ERROR_LOG=1`, summarise `user://ops/errors.jsonl` with `python3 tools/ops/errors_to_issues.py`. Each record carries the `trace_id` sent to GMI as `X-Trace-ID`; each GMI Log entry also has its `request_id` (`X-Request-ID`). On the desktop build those ids go out as headers. The **web build cannot send them**: a browser must clear a CORS preflight first, and GMI's allow-list (measured 2026-11-03: `Content-Type, Authorization, X-Requested-With, x-gmi-request-id`) excludes `User-Agent`, `X-Request-ID` and `X-Trace-ID`, so the web build sends only `Authorization` and `Content-Type` and keeps the ids in the local GMI Log and trace (`GmiClient.request_headers`, flag `gmi_web_safe_headers`; switch it off only if GMI starts allowing those headers, which `tools/demo_check.sh` shows). Do not quote a web player's request id to GMI support: GMI never saw it.
6. `OPS_ALERT` lines in the console come from `data/alert_rules.json` (breaker open, live failure ratio with at least 6 calls, error bursts).

## Fix

- **Outage / 5xx / timeouts:** nothing to do in game. `GmiClient` retries transient failures twice with jittered exponential backoff (honouring `Retry-After` on desktop; a browser cannot read that header from GMI's CORS reply, so the web build waits the computed jitter only). After 4 failed calls in a row the circuit breaker (`scripts/ops/circuit_breaker.gd`) opens for 30 s and calls go straight to the replay cache and heuristics; then one probe call goes out and a success closes it. Keep playing, or set `GRIDFALL_OFFLINE=1` (or `GRIDFALL_FLAGS=gmi_live=off`) to stop waiting on calls.
- **429 rate limit:** lower the parallel load or switch live off for a while. The real levers are the **Live GMI** button in the orbit view's top bar (off: every call uses the replay cache and the heuristics) and `Residents.MAX_RESIDENTS` (100, in `scripts/sim/residents.gd`; fewer residents means fewer resident batches per dawn, but it is a source constant, so it needs an edit and a rebuild). `LIVE_RESIDENTS` is not a lever: only the `tools/tests/residents_live.gd` test reads it. In first person there is no live button; `GRIDFALL_OFFLINE=1` or `GRIDFALL_FLAGS=gmi_live=off` do the same.
- **401/403:** rotate the key in the GMI console, update `GMI_API_KEY` (or `~/.factory/settings.json`), restart the game. In the web build paste the new key on the GMI Cloud page and press **Test**. A rejected key is not an outage, so the circuit breaker stays closed and each call still spends a round trip before it falls back to the cache.
- **HTTP 400 naming the temperature:** nothing to do. The client retries that call once with temperature 1 and keeps 1 for that model until the game restarts. Any other 400 is a bad request: open an issue with the `GMI_FAIL` line.
- **One model failing:** the breaker is shared, so one dead model can trip it for all. Swap the model id in `scripts/sim/sim_defs.gd` only if the model was retired; open an issue with the request id from the GMI Log.

## Verify

The next in-game day shows `live` on the mayor cards and no new `OPS_ALERT gmi_breaker_open` lines.
