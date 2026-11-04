class_name GmiParse
extends RefCounted
## Reads the JSON object a model put in its reply. Models wrap it in prose, code fences or a
## <think> block, leave a trailing comma, write NaN, stop mid-sentence at the token limit, or answer
## only in their reasoning field. Every function is static and pure (no node, no network), so
## tools/tests/gmi_parse_test.gd can run a table of sample replies offline.
##
## extract_json() finds every balanced top-level {...} in the reply (string-aware, so a brace inside
## a quoted value does not count), repairs each (trailing commas, NaN and Infinity) and returns the
## largest one that parses as an object; the first wins a tie. A reply cut off by the token limit
## has no balanced object: it is closed at the last complete value instead, so what the model did
## finish is kept: its root-level members and the finished items of its lists (an order that has a
## nested object or list of its own is cut with that order, so no order is ever half made). When the
## cut falls before the first finished item of the list it was writing (a mayor stopped inside its
## first order), nothing is kept: the caller falls back as for any reply with no answer, instead of
## playing an idle day. A bare array reply ([{...}, {...}]) has no answer object, so it is {}.
## {} means there was no answer to be found.

## Longest reply scanned, in characters. A model that loops never makes the scan unbounded.
const MAX_SCAN := 60000
## Most "{" starting points tried and most candidate objects parsed from one reply.
const MAX_STARTS := 32
const MAX_CANDIDATES := 256
## A reply with more "{" than "}" by this much is not an answer (a reply cut off mid-way is a few
## levels short): {} at once, so a looping model cannot make the scan expensive.
const MAX_UNCLOSED := 40
## Unbalanced starts a truncation repair is tried from.
const MAX_REPAIRS := 4
const THINK_OPEN := "<think>"
const THINK_CLOSE := "</think>"
## The characters the scans look at, as code points (cheaper than slicing a string per character).
const LBRACE := 0x7B
const RBRACE := 0x7D
const LBRACKET := 0x5B
const RBRACKET := 0x5D
const QUOTE := 0x22
const BACKSLASH := 0x5C
const COMMA := 0x2C


## The object the reply carries: the largest valid balanced one, else a truncated reply closed at
## its last complete value, else {}. Never fails and never prints.
static func extract_json(content: String) -> Dictionary:
	return extract_json_info(content)["data"]


## extract_json with how it got there: {"data": the object ({} when none), "truncated": true when
## the object is a cut-off reply closed at its last complete value}. One scan, so the caller that
## wants to count repairs (GmiReply) pays nothing extra.
static func extract_json_info(content: String) -> Dictionary:
	var text := _without_thinking(content.left(MAX_SCAN))
	if text.count("{") - text.count("}") > MAX_UNCLOSED:
		return {"data": {}, "truncated": false}
	var best: Dictionary = {}
	var best_len := 0
	var best_start := -1
	var open_starts: Array[int] = []
	var seen := 0
	var from := 0
	var tried := 0
	var gap_from := 0
	var arrays := 0
	while tried < MAX_STARTS and seen < MAX_CANDIDATES:
		var start := text.find("{", from)
		if start < 0:
			break
		tried += 1
		arrays = _array_depth(text, gap_from, start, arrays)
		gap_from = start
		var scan := _scan_object(text, start)
		if scan["end"] >= 0:
			var span := int(scan["end"]) - start + 1
			from = int(scan["end"]) + 1
			gap_from = from
			seen += 1
			if arrays > 0:
				# An element of a bare array is not the answer object (a reply that is a list).
				continue
			var parsed := parse_object(text.substr(start, span))
			if not parsed.is_empty() and span > best_len:
				best = parsed
				best_len = span
				best_start = start
			continue
		# Unbalanced from here: the reply was cut off, or this "{" was only prose. Remember the
		# first few such starts for the truncation repair, and try the next "{".
		if arrays == 0 and open_starts.size() < MAX_REPAIRS:
			open_starts.append(start)
		from = start + 1
	for open_start in open_starts:
		# A complete answer that came before this start wins over a cut-off later draft. The
		# complete objects after it are only the orders of the cut-off object, which spans the rest
		# of the reply: closed at its last complete value it is the answer.
		if best_start >= 0 and best_start < open_start:
			break
		var repaired := _close_truncated(text, open_start)
		if not repaired.is_empty():
			return {"data": repaired, "truncated": true}
	return {"data": best, "truncated": false}


## The reply without its reasoning (what extract_json scans): <think> blocks cut out, the scan
## limit applied.
static func visible_text(content: String) -> String:
	return _without_thinking(content.left(MAX_SCAN))


## True when the reply put its answer in the reasoning field because its content was empty
## (message_text takes that way out).
static func used_reasoning(msg: Dictionary) -> bool:
	if not _text_of(msg.get("content")).strip_edges().is_empty():
		return false
	return not message_text(msg).strip_edges().is_empty()


## The "message" of one entry of a reply's "choices" ({} when it is not an object holding one).
static func message_of(choice: Variant) -> Dictionary:
	if typeof(choice) != TYPE_DICTIONARY:
		return {}
	var msg: Variant = (choice as Dictionary).get("message")
	return msg as Dictionary if typeof(msg) == TYPE_DICTIONARY else {}


## The reply's answer text for a chat message: its content (a string, or a list of parts with a
## "text"), and when that is empty the reasoning field some providers answer in. "" when none.
static func message_text(msg: Dictionary) -> String:
	var content := _text_of(msg.get("content"))
	if not content.strip_edges().is_empty():
		return content
	for key: String in ["reasoning_content", "reasoning"]:
		var alt := _text_of(msg.get(key))
		if not alt.strip_edges().is_empty():
			return alt
	return content


## The object a JSON text parses to after the small repairs models need, or {} when it is not an
## object. Never prints (JSON.parse_string would log a parse error; a JSON instance does not).
static func parse_object(text: String) -> Dictionary:
	var parsed: Variant = _parse(text)
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed as Dictionary
	var fixed := repair(text)
	if fixed != text:
		parsed = _parse(fixed)
		if typeof(parsed) == TYPE_DICTIONARY:
			return parsed as Dictionary
	return {}


## text with trailing commas dropped and the bare NaN, Infinity and -Infinity tokens (JSON has no
## way to write them) turned into null. Quoted text is left alone.
static func repair(text: String) -> String:
	var out := PackedStringArray()
	var n := text.length()
	var i := 0
	var in_str := false
	while i < n:
		var ch := text[i]
		if in_str:
			out.append(ch)
			if ch == "\\" and i + 1 < n:
				i += 1
				out.append(text[i])
			elif ch == '"':
				in_str = false
			i += 1
			continue
		if ch == '"':
			in_str = true
			out.append(ch)
		elif ch == ",":
			var j := _skip_space(text, i + 1)
			if j < n and (text[j] == "}" or text[j] == "]"):
				i += 1
				continue
			out.append(ch)
		elif ch == "N" and text.substr(i, 3) == "NaN" and _bare_token(text, i, 3):
			out.append("null")
			i += 3
			continue
		elif ch == "I" and text.substr(i, 8) == "Infinity" and _bare_token(text, i, 8):
			out.append("null")
			i += 8
			continue
		elif ch == "-" and text.substr(i, 9) == "-Infinity" and _bare_token(text, i, 9):
			out.append("null")
			i += 9
			continue
		else:
			out.append(ch)
		i += 1
	return "".join(out)


## Recovers the complete objects of a truncated {"key":[{...},{...},{... reply. It is the
## fallback for a reply extract_json found nothing in.
static func salvage_array(content: String) -> Dictionary:
	var text := _without_thinking(content.left(MAX_SCAN))
	var lb := text.find("[")
	if lb < 0:
		return {}
	var q2 := text.rfind('"', lb)
	var q1 := text.rfind('"', q2 - 1) if q2 > 0 else -1
	if q1 < 0:
		return {}
	if not text.substr(q2 + 1, lb - q2 - 1).strip_edges().trim_prefix(":").strip_edges().is_empty():
		return {}  # the "[" is not the value of that quoted word
	var key := text.substr(q1 + 1, q2 - q1 - 1)
	var items: Array = []
	var depth := 0
	var in_str := false
	var esc := false
	var start := -1
	for i in range(lb + 1, text.length()):
		var ch := text[i]
		if in_str:
			if esc:
				esc = false
			elif ch == "\\":
				esc = true
			elif ch == '"':
				in_str = false
			continue
		if ch == '"':
			in_str = true
		elif ch == "{":
			if depth == 0:
				start = i
			depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0 and start >= 0:
				var parsed := parse_object(text.substr(start, i - start + 1))
				if not parsed.is_empty():
					items.append(parsed)
				start = -1
		elif ch == "]" and depth == 0:
			break
	return {key: items} if not items.is_empty() else {}


## The reply with its reasoning removed: every <think>...</think> block, the text before a lone
## </think> (a model that opens its reasoning without the tag), and an unclosed <think> with all
## that follows it (a reply cut off while the model was still thinking has no answer in it).
static func _without_thinking(content: String) -> String:
	var text := content
	var lower := text.to_lower()
	var settled := 0
	var guard := 0
	while guard < 64:
		guard += 1
		var open := lower.find(THINK_OPEN, settled)
		var close := lower.find(THINK_CLOSE, settled)
		if close >= 0 and (open < 0 or close < open):
			if _in_json_string(text, close):
				# The tag is text inside a quoted value of the answer, not the end of reasoning.
				settled = close + THINK_CLOSE.length()
				continue
			text = text.substr(close + THINK_CLOSE.length())
			lower = lower.substr(close + THINK_CLOSE.length())
			settled = 0
		elif open >= 0:
			var end := lower.find(THINK_CLOSE, open)
			if end < 0:
				return text.left(open)
			text = text.left(open) + text.substr(end + THINK_CLOSE.length())
			lower = lower.left(open) + lower.substr(end + THINK_CLOSE.length())
		else:
			break
	return text


## True when text[pos] lies inside a quoted string of a balanced {...} object (tried from each of
## the first few "{" before pos).
static func _in_json_string(text: String, pos: int) -> bool:
	var from := 0
	for _try in range(8):
		var start := text.find("{", from)
		if start < 0 or start >= pos:
			return false
		from = start + 1
		var depth := 0
		var in_str := false
		var at_pos := false
		var n := text.length()
		var i := start
		while i < n:
			if i == pos:
				at_pos = in_str
			var ch := text.unicode_at(i)
			if in_str:
				if ch == BACKSLASH:
					i += 1
				elif ch == QUOTE:
					in_str = false
			elif ch == QUOTE:
				in_str = true
			elif ch == LBRACE:
				depth += 1
			elif ch == RBRACE:
				depth -= 1
				if depth == 0:
					break
			i += 1
		if depth == 0 and i > pos and at_pos:
			return true
	return false


## The array nesting at text[to] after the gap text[from..to): depth plus the "[" in the gap that
## start a list of objects or lists (the next non-space character is "{" or "["), minus the "]".
## A "[" inside prose ("see [1]") does not count.
static func _array_depth(text: String, from: int, to: int, depth: int) -> int:
	var d := depth
	var i := from
	while i < to:
		var ch := text.unicode_at(i)
		if ch == LBRACKET:
			var j := _skip_space(text, i + 1)
			if j < text.length() and (text[j] == "{" or text[j] == "["):
				d += 1
		elif ch == RBRACKET and d > 0:
			d -= 1
		i += 1
	return d


## Where the object starting at text[start] ends: {"end": index of its closing brace, or -1 when
## the text runs out first}. Braces inside quoted strings do not count.
static func _scan_object(text: String, start: int) -> Dictionary:
	var depth := 0
	var in_str := false
	var n := text.length()
	var i := start
	while i < n:
		var ch := text.unicode_at(i)
		if in_str:
			if ch == BACKSLASH:
				i += 1
			elif ch == QUOTE:
				in_str = false
		elif ch == QUOTE:
			in_str = true
		elif ch == LBRACE:
			depth += 1
		elif ch == RBRACE:
			depth -= 1
			if depth == 0:
				return {"end": i}
		i += 1
	return {"end": -1}


## The object of a reply that ends mid-way: the text from start cut back to its last complete
## value, with every bracket still open closed. A value is complete at a root-level comma, at the
## closing bracket of a root member, and after an item of a list that sits (through lists only)
## directly in the root; anything inside an object below the root is not (that object is an order or
## a record, and half of it is not one). {} when nothing complete is left, and also when the cut
## falls before the first item of the root member being written (see the header).
static func _close_truncated(text: String, start: int) -> Dictionary:
	var stack := PackedStringArray()
	var inner := 0  # objects open below the root
	var cut := -1
	var closers_at_cut := ""
	var member_start := -1  # where the root member open at the end began
	var n := text.length()
	var i := start
	while i < n:
		var ch := text.unicode_at(i)
		if ch == QUOTE:
			i = _string_end(text, i)
		elif ch == LBRACE or ch == LBRACKET:
			if stack.size() == 1:
				member_start = i
			if ch == LBRACE and not stack.is_empty():
				inner += 1
			stack.append("}" if ch == LBRACE else "]")
		elif ch == RBRACE or ch == RBRACKET:
			if stack.size() > 1 and stack[-1] == "}":
				inner -= 1
			stack.remove_at(stack.size() - 1)
			if stack.is_empty():
				break  # the root closed: nothing was cut off
			if inner == 0:
				# A complete value of the root or of a list under it: a safe place to cut after.
				cut = i + 1
				closers_at_cut = _closers(stack)
		elif ch == COMMA and inner == 0:
			cut = i
			closers_at_cut = _closers(stack)
		i += 1
	if cut < 0 or (stack.size() >= 2 and cut <= member_start):
		return {}
	return parse_object(text.substr(start, cut - start) + closers_at_cut)


## The index of the quote that closes the string opening at text[open] (the text's end when it is
## cut off inside the string).
static func _string_end(text: String, open: int) -> int:
	var n := text.length()
	var j := open + 1
	while j < n:
		var ch := text.unicode_at(j)
		if ch == BACKSLASH:
			j += 2
		elif ch == QUOTE:
			return j
		else:
			j += 1
	return n


static func _closers(stack: PackedStringArray) -> String:
	var parts := PackedStringArray()
	for k in range(stack.size() - 1, -1, -1):
		parts.append(stack[k])
	return "".join(parts)


static func _parse(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


static func _skip_space(text: String, from: int) -> int:
	var j := from
	while (
		j < text.length()
		and (text[j] == " " or text[j] == "\n" or text[j] == "\t" or text[j] == "\r")
	):
		j += 1
	return j


## True when the n characters of text at i stand alone (no letter, digit or quote beside them), so
## a word like "Infinity" inside a longer token is not rewritten.
static func _bare_token(text: String, i: int, n: int) -> bool:
	var before := text[i - 1] if i > 0 else " "
	var after := text[i + n] if i + n < text.length() else " "
	return not (_word_char(before) or _word_char(after))


static func _word_char(ch: String) -> bool:
	return (
		ch == "_"
		or ch == '"'
		or (ch >= "a" and ch <= "z")
		or (ch >= "A" and ch <= "Z")
		or (ch >= "0" and ch <= "9")
	)


## A message field as text: a string as is, a list of parts joined by their "text", else "".
static func _text_of(v: Variant) -> String:
	match typeof(v):
		TYPE_STRING:
			return v as String
		TYPE_ARRAY:
			var parts := PackedStringArray()
			for p: Variant in v as Array:
				if typeof(p) == TYPE_STRING:
					parts.append(p as String)
				elif (
					typeof(p) == TYPE_DICTIONARY
					and typeof((p as Dictionary).get("text")) == TYPE_STRING
				):
					parts.append((p as Dictionary)["text"] as String)
			return "\n".join(parts)
	return ""
