class_name GmiReply
extends RefCounted
## Reads one chat-completion body into what the game keeps of it: the answer object, the text it
## came from, which repairs the reply needed, and what the API reported about its size. Pure and
## static (no node, no network), so tools/tests/ai_ledger_test.gd can feed it fenced, think-tagged
## and cut-off replies; GmiClient._post is the only caller in the game.
##
## Repairs name what GmiParse had to do to get an object out of the text (the ModelLedger counts
## them per model: they are the visible difference between hybrid-reasoning models):
##   think_tag       a <think> block (or a lone </think>) was cut out
##   fenced          the object came in a code fence
##   trailing_comma  a trailing comma, NaN or Infinity had to be fixed (GmiParse.repair)
##   salvaged        the reply was cut off by the token limit and closed at its last complete value
##   reasoning_only  the content was empty and the answer was read from the reasoning field

const THINK_TAG := "think_tag"
const FENCED := "fenced"
const TRAILING_COMMA := "trailing_comma"
const SALVAGED := "salvaged"
const REASONING_ONLY := "reasoning_only"
const KINDS := [THINK_TAG, FENCED, TRAILING_COMMA, SALVAGED, REASONING_ONLY]

static var _fix_re: RegEx
## How many times the full repair scan ran (a reply with a comma, NaN or Infinity candidate): a
## clean reply must leave it alone, which ai_ledger_test asserts (the scan is a script loop).
static var repair_scans: int = 0


## body: the parsed JSON of a 200 reply. Returns {"error": "" | "no choices", "data": {} (empty
## when the text held no object), "raw": the answer text, "repairs": Array of KINDS names (only
## when an object was found), "tokens_in", "tokens_out" (-1 when the API sent no usage),
## "finish_reason" ("" when absent)}.
static func read(body: Dictionary) -> Dictionary:
	var raw_choices: Variant = body.get("choices")
	# "choices": null (or a word) is not a list: no choices, not a script error.
	var choices: Array = raw_choices as Array if typeof(raw_choices) == TYPE_ARRAY else []
	if choices.is_empty():
		return {
			"error": "no choices",
			"data": {},
			"raw": "",
			"repairs": [],
			"tokens_in": -1,
			"tokens_out": -1,
			"finish_reason": ""
		}
	var msg := GmiParse.message_of(choices[0])
	var content := GmiParse.message_text(msg)
	var found := GmiParse.extract_json_info(content)
	var data: Dictionary = found["data"]
	var salvaged: bool = bool(found["truncated"])
	if data.is_empty():
		data = GmiParse.salvage_array(content)
		salvaged = not data.is_empty()
	var out := usage_of(body, choices[0])
	out["error"] = ""
	out["data"] = data
	out["raw"] = content
	out["repairs"] = (
		classify(content, GmiParse.used_reasoning(msg), salvaged) if not data.is_empty() else []
	)
	return out


## Which repairs reading content took (KINDS names, in KINDS order). from_reasoning: the text came
## from the reasoning field; salvaged: the object was recovered from a cut-off reply. Every reply
## passes through here, so a clean one costs a few native string searches and one regex scan, not
## a script loop (the loop in GmiParse.repair only runs when the regex saw a candidate).
static func classify(content: String, from_reasoning: bool, salvaged: bool) -> Array:
	var out: Array = []
	var thinking := content.findn("<think>") >= 0 or content.findn("</think>") >= 0
	if thinking:
		out.append(THINK_TAG)
	var text := GmiParse.visible_text(content) if thinking else content
	if _fenced(text):
		out.append(FENCED)
	if _needs_fixing(text):
		out.append(TRAILING_COMMA)
	if salvaged:
		out.append(SALVAGED)
	if from_reasoning:
		out.append(REASONING_ONLY)
	return out


## {"tokens_in", "tokens_out", "finish_reason"} from a reply body and its first choice: the usage
## counts (-1 when missing or not a number) and the reason the model stopped ("length" = it hit
## max_tokens).
static func usage_of(body: Dictionary, choice: Variant) -> Dictionary:
	var out := {"tokens_in": -1, "tokens_out": -1, "finish_reason": ""}
	var usage: Variant = body.get("usage")
	if typeof(usage) == TYPE_DICTIONARY:
		out["tokens_in"] = _count((usage as Dictionary).get("prompt_tokens"))
		out["tokens_out"] = _count((usage as Dictionary).get("completion_tokens"))
	if typeof(choice) == TYPE_DICTIONARY:
		var fr: Variant = (choice as Dictionary).get("finish_reason")
		if typeof(fr) == TYPE_STRING:
			out["finish_reason"] = (fr as String).left(24)
	return out


## True when the answer came in a code fence: a fence opens before the first "{". Three backticks
## inside a string value of the object are not a fence.
static func _fenced(text: String) -> bool:
	var fence := text.find("```")
	if fence < 0:
		return false
	var brace := text.find("{")
	return brace < 0 or fence < brace


## True when the object between the first "{" and the last "}" of text changes under
## GmiParse.repair (a trailing comma, NaN or Infinity outside quotes). The regex only finds
## candidates (it cannot tell a comma inside a string from one outside); repair decides.
static func _needs_fixing(text: String) -> bool:
	if _fix_re == null:
		_fix_re = RegEx.create_from_string(",\\s*[}\\]]|NaN|Infinity")
	if _fix_re.search(text) == null:
		return false
	var first := text.find("{")
	var last := text.rfind("}")
	if first < 0 or last <= first:
		return false
	var span := text.substr(first, last - first + 1)
	repair_scans += 1
	return GmiParse.repair(span) != span


static func _count(v: Variant) -> int:
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return maxi(int(v), -1)
	return -1
