class_name GmiCache
extends RefCounted
## The shape of GmiClient's answer caches: {key: [{day, data}, ...]}. Pure functions over those
## dictionaries, kept apart from the client (a node that is already near the file-size cap) so
## the lookup rule and the save diet have one place and a test can run them without a node.
##
## Lookup: the entry nearest the asked day wins (the earlier day on a tie). The recorded replay
## cache has a horizon: it holds one captured game, so past the last day recorded for a key its
## entries are no longer an answer to the day asked (a day-14 city must not replay day 12 forever)
## and the caller falls through to the scripted planner. The session cache (this run's own live
## answers) has no horizon: it is the freshest thing there is.
##
## Save diet: a save keeps each key's last SAVE_KEEP_DAYS distinct days (the lookup reads the
## nearest day, so older ones are never the answer once newer ones exist). The in-memory cache is
## not touched.

## Distinct days per key a save (and the session file) keeps.
const SAVE_KEEP_DAYS := 3


## The last day any entry of entries records, or -1 when none does.
static func last_day(entries: Array) -> int:
	var best := -1
	for e: Variant in entries:
		if typeof(e) == TYPE_DICTIONARY:
			best = maxi(best, int((e as Dictionary).get("day", 0)))
	return best


## The data of the entry of entries nearest day, or {} when there is none. horizon true: {} too
## when day is past the last day the entries record.
static func nearest(entries: Array, day: int, horizon: bool = false) -> Dictionary:
	var best: Dictionary = {}
	var best_d := 1 << 30
	var last := -1
	for e: Variant in entries:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var ed: Dictionary = e
		var ed_day := int(ed.get("day", 0))
		last = maxi(last, ed_day)
		var dd := absi(ed_day - day)
		if dd < best_d and typeof(ed.get("data")) == TYPE_DICTIONARY:
			best_d = dd
			best = ed
	if best.is_empty() or (horizon and day > last):
		return {}
	return best["data"]


## The answer for key on day: the session cache's nearest entry, else the replay cache's (inside
## its horizon when horizon is true), else {}.
static func lookup(
	session: Dictionary, replay: Dictionary, key: String, day: int, horizon: bool
) -> Dictionary:
	if session.has(key) and typeof(session[key]) == TYPE_ARRAY:
		var hit := nearest(session[key] as Array, day)
		if not hit.is_empty():
			return hit
	if replay.has(key) and typeof(replay[key]) == TYPE_ARRAY:
		return nearest(replay[key] as Array, day, horizon)
	return {}


## A copy of cache keeping, for each key, the entries of its last keep distinct days (in their
## original order). The entries themselves are shared with cache, not copied.
static func pruned(cache: Dictionary, keep: int = SAVE_KEEP_DAYS) -> Dictionary:
	var out := {}
	for key: Variant in cache.keys():
		var entries: Variant = cache[key]
		if typeof(entries) != TYPE_ARRAY:
			continue
		var days: Array = []
		for e: Variant in entries as Array:
			if typeof(e) == TYPE_DICTIONARY:
				var d := int((e as Dictionary).get("day", 0))
				if not days.has(d):
					days.append(d)
		days.sort()
		var recent: Array = days.slice(maxi(0, days.size() - keep))
		var kept: Array = []
		for e: Variant in entries as Array:
			if typeof(e) == TYPE_DICTIONARY and recent.has(int((e as Dictionary).get("day", 0))):
				kept.append(e)
		out[key] = kept
	return out


## How many entries cache holds in all (the flush signature and the tests use it).
static func entry_count(cache: Dictionary) -> int:
	var n := 0
	for key: Variant in cache.keys():
		if typeof(cache[key]) == TYPE_ARRAY:
			n += (cache[key] as Array).size()
	return n


## A new city starts with no answers of the last one and zero counters (the calls in flight stay
## counted: they land after it): a New City must not replay the old city's live answers.
static func clear_session(client: GmiClient) -> void:
	client.session_cache = {}
	for k: String in client.stats.keys():
		if k != "in_flight":
			client.stats[k] = 0
