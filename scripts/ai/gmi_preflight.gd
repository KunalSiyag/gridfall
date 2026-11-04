class_name GmiPreflight
extends RefCounted
## The readiness check of a key (flag gmi_preflight): once per key, one GET of the model list
## through GmiClient (its own _models_trip, so no request leaves the process any other way),
## compared with the model ids the game calls (GmiReadiness), a sentence for the key panel and one
## line in the GMI log. The check goes out with the web-safe header set (Authorization and
## Content-Type only, whatever the build), is not retried, and leaves the client's breakers,
## live_outcomes and counters alone like the key test does. It starts by itself when a key is set
## (GmiClient.set_player_key calls key_changed) and at boot (Main calls run), but only where the
## game runs: `enabled` is Main's switch, so a test client never reaches for the network. It never
## asks without a key, under GRIDFALL_OFFLINE=1 or with the gmi_live kill switch off
## (GmiClient.test_refusal). The report holds model ids and counts, never the key.

## The check of the key in use finished, or its report was cleared (a new key).
signal changed(report: Dictionary)

## Main sets this where the game runs; a test turns it on to test the check itself.
var enabled: bool = false
## The latest report of the key in use: {"ok", "total", "available", "missing", "offline",
## "skipped", "listed", "seconds"}, or {"ok": false, "error", "seconds"}; {} before one.
var report: Dictionary = {}

var _by_key: Dictionary = {}
var _out: Dictionary = {}


## The key panel's sentence for the latest report ("" before one): see GmiReadiness.line.
func line() -> String:
	return GmiReadiness.line(report)


## The key in use changed: show the report of that key (none yet clears the line) and, where the
## game runs, start its check. Not awaited: the check finishes on its own.
func key_changed(client: GmiClient) -> void:
	var known: Dictionary = _by_key.get(fingerprint(client.api_key), {})
	if known != report:
		report = known
		changed.emit(report)
	if client.has_key():
		run(client)


## Asks for the model list of the key in use and returns the report. {} when the check was not made
## (not enabled, the flag off, no key, offline, the live kill switch), is still out for this key, or
## the key changed while it was out. The same key is asked once; force asks again.
func run(client: GmiClient, force: bool = false) -> Dictionary:
	if not enabled or not FeatureFlags.enabled("gmi_preflight", true):
		return {}
	if not client.test_refusal().is_empty():
		return {}
	var fp := fingerprint(client.api_key)
	if not force and _by_key.has(fp):
		report = _by_key[fp]
		return report
	if _out.has(fp):
		return {}
	_out[fp] = true
	var t0 := Time.get_ticks_msec()
	var headers := client._wire_headers("", "", true)
	var trip: Dictionary = await client._models_trip(headers, GmiClient.PREFLIGHT_TIMEOUT_S)
	_out.erase(fp)
	var got := GmiReadiness.from_trip(trip, GmiClient.PREFLIGHT_TIMEOUT_S)
	got["seconds"] = float(Time.get_ticks_msec() - t0) / 1000.0
	_by_key[fp] = got
	if fp != fingerprint(client.api_key):
		return {}
	report = got
	print(console_line(got, client.api_key))
	_log(client, got)
	changed.emit(got)
	return got


## A short stand-in for a key, for telling keys apart without keeping one.
static func fingerprint(key: String) -> String:
	return key.sha256_text().left(16) if not key.is_empty() else ""


## The scrubbed console line of a finished check: counts and seconds only.
static func console_line(got: Dictionary, key: String) -> String:
	var text := (
		"GMI_MODELS %s %d/%d in %.1f s"
		% [
			"ok" if bool(got.get("ok", false)) else "unavailable",
			int(got.get("available", 0)),
			int(got.get("total", 0)),
			float(got.get("seconds", 0.0))
		]
	)
	return Redact.scrub(text, PackedStringArray([key]))


## One GMI log entry for a finished check (role "preflight"): the sentence, scrubbed like any
## record.
func _log(client: GmiClient, got: Dictionary) -> void:
	var ok := bool(got.get("ok", false))
	var rec := client._new_result("preflight", "models", "", 0)
	rec["ok"] = ok
	rec["source"] = "live" if ok else "failed"
	rec["latency_ms"] = int(float(got.get("seconds", 0.0)) * 1000.0)
	rec["error"] = "" if ok else str(got.get("error", ""))
	rec["data"] = {"note": GmiReadiness.line(got)}
	client._log(rec)
