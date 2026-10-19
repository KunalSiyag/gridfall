extends RefCounted
## Text helpers for the global chat and conversations (slice C): the display filter every line
## passes before it is shown or put into a prompt, dedupe normalisation, the checks the reply
## validators use (URLs, model names, sentence count), trimming, relative times and initials.

const D := preload("res://scripts/sim/sim_defs.gd")
const MAYOR_WORDS := ["argon", "deepseek", "kimi", "qwen", "grok"]

static var _coord_re: RegEx
static var _brand_ci_re: RegEx
static var _vendor_re: RegEx
static var _ai_re: RegEx
static var _tiles_re: RegEx
static var _tile_re: RegEx
static var _url_re: RegEx
static var _ws_re: RegEx
static var _norm_re: RegEx
static var _sentence_re: RegEx
static var _day_re: RegEx
static var _space_punct_re: RegEx


static func _ensure() -> void:
	if _coord_re != null:
		return
	_coord_re = RegEx.create_from_string("\\(\\s*(-?\\d+)\\s*,\\s*(-?\\d+)\\s*\\)")
	_brand_ci_re = RegEx.create_from_string("(?i)\\b(argon|deepseek|kimi|qwen|grok)\\b")
	_vendor_re = RegEx.create_from_string("(?i)\\b(gmi(\\s+cloud)?|gemini|minimax|glm|mimo|xiaomi|moonshot(ai)?|openai|chat\\s?gpt|gpt(-?\\d[\\w.]*)?|llms?|claude|anthropic|(large\\s+)?language\\s+models?|ai\\s+models?|chaos\\s+director)\\b")
	_ai_re = RegEx.create_from_string("\\bAI[- ](mayors?|run|driven|powered|controlled)\\b")
	_tiles_re = RegEx.create_from_string("\\b(\\d+)\\s+tiles\\b")
	_tile_re = RegEx.create_from_string("\\b(1|one|a)\\s+tile\\b")
	_url_re = RegEx.create_from_string("(?i)(https?://|www\\.|\\b[a-z0-9-]+\\.(com|net|org|io|ai|gg|xyz|co|app|dev)\\b)")
	_ws_re = RegEx.create_from_string("\\s+")
	_norm_re = RegEx.create_from_string("[^\\p{L}\\p{N} ]+")
	_sentence_re = RegEx.create_from_string("[.!?]+(?=\\s|$)")
	_day_re = RegEx.create_from_string("^Day\\s+\\d+:\\s*")
	_space_punct_re = RegEx.create_from_string("\\s+([,.;:!?])")


## The chat display filter (C §1): SimDefs.debrand, case-insensitive brand words, "AI mayors" ->
## "mayors", vendor and model words removed, every "(x,y)" rewritten to the directory's place
## label, "N tiles" -> "N blocks", whitespace collapsed. Never returns coordinates or brand words.
static func display(text: String, directory: CityDirectory) -> String:
	_ensure()
	if text.is_empty():
		return text
	var t := D.debrand(text)
	var m := _brand_ci_re.search(t)
	while m != null:
		var k := MAYOR_WORDS.find(m.get_string(1).to_lower())
		var disp := str(D.MAYORS[k]["display"])
		var rep := "Mayor " + disp.get_slice(" ", disp.get_slice_count(" ") - 1)
		t = t.substr(0, m.get_start()) + rep + t.substr(m.get_end())
		m = _brand_ci_re.search(t, m.get_start() + rep.length())
	m = _ai_re.search(t)
	while m != null:
		var word := m.get_string(1)
		var rep := word if word.begins_with("mayor") else ("city-" + word)
		t = t.substr(0, m.get_start()) + rep + t.substr(m.get_end())
		m = _ai_re.search(t, m.get_start() + rep.length())
	t = t.replace("five AI ", "five ").replace("Five AI ", "Five ").replace("an AI ", "a ").replace("An AI ", "A ")
	if _vendor_re.search(t) != null:
		t = _vendor_re.sub(t, "", true)
	t = coords(t, directory)
	t = _tiles_re.sub(t, "$1 blocks", true)
	t = _tile_re.sub(t, "$1 block", true)
	t = _ws_re.sub(t, " ", true)
	t = _space_punct_re.sub(t, "$1", true)
	return t.strip_edges()


## Rewrites every "(x,y)" pair to directory.place_label(D.idx(x, y)) ("the frontier" when the pair
## is outside the world, "nearby" without a directory).
static func coords(text: String, directory: CityDirectory) -> String:
	_ensure()
	var m := _coord_re.search(text)
	var t := text
	while m != null:
		var x := m.get_string(1).to_int()
		var y := m.get_string(2).to_int()
		var rep := "nearby"
		if directory != null:
			rep = directory.place_label(D.idx(x, y)) if D.in_bounds(x, y) else "the frontier"
		t = t.substr(0, m.get_start()) + rep + t.substr(m.get_end())
		m = _coord_re.search(t, m.get_start() + rep.length())
	return t


## Strips a leading "Day N: " (city_log lines and resident memories).
static func strip_day(text: String) -> String:
	_ensure()
	return _day_re.sub(text, "")


## Dedupe key: lower case, letters, digits and single spaces only.
static func normalise(text: String) -> String:
	_ensure()
	return _ws_re.sub(_norm_re.sub(text.to_lower(), " ", true), " ", true).strip_edges()


## True when text carries a URL or a bare domain.
static func has_url(text: String) -> bool:
	_ensure()
	return _url_re.search(text) != null


## True when text names a model, a vendor or a bare brand word (any case), or a model id from
## the mayors or the support agents. Validators drop such lines instead of rewriting them.
static func has_model_name(text: String) -> bool:
	_ensure()
	if _brand_ci_re.search(text) != null or _vendor_re.search(text) != null:
		return true
	var low := text.to_lower()
	for m: Dictionary in D.MAYORS:
		if low.contains(str(m["model"]).to_lower()):
			return true
	for a: Dictionary in D.SUPPORT_AGENTS.values():
		if low.contains(str(a["model"]).to_lower()):
			return true
	return low.contains("as an ai") or low.contains("i am an ai") or low.contains("i'm an ai")


## Sentences in text (runs of . ! ? followed by a space or the end; a trailing fragment counts).
static func sentence_count(text: String) -> int:
	_ensure()
	var t := text.strip_edges()
	if t.is_empty():
		return 0
	var n := _sentence_re.search_all(t).size()
	var last := t[t.length() - 1]
	if last not in [".", "!", "?"]:
		n += 1
	return maxi(n, 1)


## Words in text.
static func word_count(text: String) -> int:
	_ensure()
	var t := text.strip_edges()
	return 0 if t.is_empty() else _ws_re.sub(t, " ", true).split(" ").size()


## Trims text to at most n characters, at a word boundary with a closing ellipsis when cut.
static func clip(text: String, n: int) -> String:
	var t := text.strip_edges()
	if t.length() <= n:
		return t
	var cut := t.left(n - 1)
	var sp := cut.rfind(" ")
	if sp > n / 2:
		cut = cut.left(sp)
	return cut.rstrip(" ,;:-") + "…"


## Trims text to at most n words (adds an ellipsis when cut).
static func clip_words(text: String, n: int) -> String:
	_ensure()
	var words := _ws_re.sub(text.strip_edges(), " ", true).split(" ")
	if words.size() <= n:
		return text.strip_edges()
	return " ".join(words.slice(0, n)).rstrip(" ,;:-") + "…"


## "now", "3m", "2h", "4d" for an age in milliseconds.
static func rel_time(age_ms: int) -> String:
	var s := maxi(age_ms, 0) / 1000
	if s < 60:
		return "now"
	if s < 3600:
		return "%dm" % (s / 60)
	if s < 86400:
		return "%dh" % (s / 3600)
	return "%dd" % (s / 86400)


## Up to two upper-case initials ("Priya Gupta" -> "PG", "GridFall Gazette" -> "GG").
static func initials(name: String) -> String:
	var parts := name.strip_edges().split(" ", false)
	var out := ""
	for p in parts:
		var c := p.left(1)
		if c.to_upper() != c.to_lower():
			out += c.to_upper()
		if out.length() >= 2:
			break
	return out if not out.is_empty() else "?"


## First name ("Priya Gupta" -> "Priya").
static func first_name(name: String) -> String:
	return name.strip_edges().get_slice(" ", 0)


## Capitalises the first letter.
static func cap(text: String) -> String:
	return text.left(1).to_upper() + text.substr(1) if not text.is_empty() else text


## Deterministic non-negative hash of a string (stable across runs).
static func h(s: String) -> int:
	return absi(hash(s)) & 0x7fffffff


## h(s) with its bits mixed (a murmur-style finaliser). Godot's String hash is djb2, whose value
## modulo 3 depends only on the last character, so "hash(id + day) % 3" would make every letter of
## a day public or none; mix() spreads it.
static func mix(s: String) -> int:
	var x := h(s)
	x = ((x >> 16) ^ x) * 0x45d9f3b & 0x7fffffff
	x = ((x >> 16) ^ x) * 0x45d9f3b & 0x7fffffff
	return (x >> 16) ^ x


## Two-or-three letter badge for district d ("NW", "NE", "CTR", "SW", "SE"); "" outside them.
static func district_badge(d: int) -> String:
	return ["NW", "NE", "CTR", "SW", "SE"][d] if d >= 0 and d < 5 else ""
