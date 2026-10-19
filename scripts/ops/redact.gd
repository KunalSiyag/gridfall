class_name Redact
extends RefCounted
## Masks secrets and personal data in text bound for logs and the local ops files: bearer and
## basic credentials, key=value secrets, sk- keys, JWTs, long random tokens, e-mail addresses and
## every value registered with add_secret() (the live GMI key).

const MASK := "[REDACTED]"
## Registered secrets shorter than this are ignored (masking "abc" would shred normal text).
const MIN_SECRET := 8
## A token is masked when it holds an alphanumeric run this long with enough digits and letters.
const TOKEN_RUN := 20

static var _secrets: PackedStringArray = PackedStringArray()
## [RegEx, replacement] pairs, applied in order: credentials before key=value so "Authorization:
## Bearer x" never leaves x behind.
static var _rules: Array = _build_rules()
static var _token_rx: RegEx = RegEx.create_from_string("[A-Za-z0-9_+=-]{%d,}" % TOKEN_RUN)
static var _run_rx: RegEx = RegEx.create_from_string("[A-Za-z0-9]{%d,}" % TOKEN_RUN)


## Registers a value that must never reach a log (call once with the API key).
static func add_secret(secret: String) -> void:
	var s := secret.strip_edges()
	if s.length() >= MIN_SECRET and not _secrets.has(s):
		_secrets.append(s)


## text with every secret, credential and e-mail address masked. extra: more literal secrets.
static func scrub(text: String, extra: PackedStringArray = PackedStringArray()) -> String:
	if text.is_empty():
		return text
	var out := text
	for list: PackedStringArray in [_secrets, extra]:
		for s: String in list:
			if s.length() >= MIN_SECRET:
				out = out.replace(s, MASK)
	for rule: Array in _rules:
		out = (rule[0] as RegEx).sub(out, str(rule[1]), true)
	return _mask_tokens(out)


static func _build_rules() -> Array:
	var specs := [
		["(?i)\\b(bearer|basic)\\s+(?!\\[REDACTED)[A-Za-z0-9._~+/=-]{6,}", "$1 " + MASK],
		["\\beyJ[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}(\\.[A-Za-z0-9_-]+)?", MASK],
		["\\bsk-[A-Za-z0-9_-]{8,}", MASK],
		["(?i)\\b(api[_-]?key|apikey|x-api-key|access[_-]?token|refresh[_-]?token|auth[_-]?token|token|secret|client[_-]?secret|password|passwd|authorization)(\\\\?[\"']?\\s*[:=]\\s*\\\\?[\"']?)(?!\\[REDACTED)[^\\s\"'\\\\,;}&]+", "$1$2" + MASK],
		["[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}", "[EMAIL]"],
	]
	var out: Array = []
	for s: Array in specs:
		out.append([RegEx.create_from_string(str(s[0])), s[1]])
	return out


## Masks long tokens that look random (a long alphanumeric run with at least 3 digits and 3
## letters); model ids like Qwen3-235B-A22B-Instruct-2507 and file paths survive.
static func _mask_tokens(text: String) -> String:
	var matches := _token_rx.search_all(text)
	if matches.is_empty():
		return text
	var out := ""
	var at := 0
	for m: RegExMatch in matches:
		var tok := m.get_string()
		if _looks_random(tok):
			out += text.substr(at, m.get_start() - at) + MASK
			at = m.get_end()
	return out + text.substr(at)


static func _looks_random(tok: String) -> bool:
	for m: RegExMatch in _run_rx.search_all(tok):
		var run := m.get_string()
		var digits := 0
		for ch in run:
			if ch >= "0" and ch <= "9":
				digits += 1
		if digits >= 3 and run.length() - digits >= 3:
			return true
	return false
