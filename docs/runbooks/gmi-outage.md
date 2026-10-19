# GMI outage or degraded inference

## Symptoms

- Mayor cards and the GMI Log show `cache` or `heuristic` instead of `live`.
- Console lines like `OPS_ALERT gmi_breaker_open` or `GMI ... status 5xx / timeout`.
- Days take the full 75 s wait before advancing.

## Confirm

1. Check the key is set: `test -n "$GMI_API_KEY" && echo set`. Never paste the key into issues or logs.
2. Check `GRIDFALL_OFFLINE` is not `1`.
3. Call the API directly (replace nothing, the key comes from the environment):

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' https://api.gmi-serving.com/v1/models \
     -H "Authorization: Bearer $GMI_API_KEY"
   ```

   `401/403` is a key problem, `429` is rate limiting, `5xx` or a timeout is an outage.
4. With `GRIDFALL_ERROR_LOG=1`, summarise `user://ops/errors.jsonl` with `python3 tools/ops/errors_to_issues.py`. Each record carries the `trace_id` sent to GMI as `X-Trace-ID`; each GMI Log entry also has its `request_id` (`X-Request-ID`).
5. `OPS_ALERT` lines in the console come from `data/alert_rules.json` (breaker open, live failure ratio, error bursts).

## Fix

- **Outage / 5xx / timeouts:** nothing to do in game. `GmiClient` retries transient failures twice with jittered exponential backoff (honouring `Retry-After`). After 4 failed calls in a row the circuit breaker (`scripts/ops/circuit_breaker.gd`) opens for 30 s and calls go straight to the replay cache and heuristics; then one probe call goes out and a success closes it. Keep playing, or set `GRIDFALL_OFFLINE=1` (or `GRIDFALL_FLAGS=gmi_live=off`) to stop waiting on calls.
- **429 rate limit:** lower parallel load (`LIVE_RESIDENTS`, fewer live residents) or disable the live toggle in the top bar for a while.
- **401/403:** rotate the key in the GMI console, update `GMI_API_KEY` (or `~/.factory/settings.json`), restart the game.
- **One model failing:** the breaker is shared, so one dead model can trip it for all. Swap the model id in `scripts/sim/sim_defs.gd` only if the model was retired; open an issue with the request id from the GMI Log.

## Verify

The next in-game day shows `live` on the mayor cards and no new `OPS_ALERT gmi_breaker_open` lines.
