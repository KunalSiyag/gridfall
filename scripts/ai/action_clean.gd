class_name ActionClean
extends RefCounted
## A model's order (one entry of "actions") made safe to show and to apply. A model's loose JSON
## carries a null where a number goes, a word, NaN, a negative width, a coordinate of 1e12, a tax
## rate of -4. Shown, those read as "<null>" or "$9223372036854775807"; applied, a road to x2 =
## 1e12 makes the sim walk a trillion tiles. clean() returns a copy in which
##  - every number field holds a finite number inside its range (out of range is clamped to the
##    nearest bound, which is what the sim does with it anyway: a zone side is cut to its maximum, a
##    tax rate to 0..20; a coordinate past the map is outside it either way), and a null, list,
##    bool, word or non-finite value is dropped, so the order reads as missing that number;
##  - a text field (type, building, zone, grade, to) that is not text is dropped, so a missing type
##    shows as "?" and not as "<null>".
## An order that already holds sane values comes back equal to the input, so replayed and scripted
## turns play exactly as before. text_of() is the same rule for a thought or a post.

## The numbers an order may carry, with the range each is held to ([lo, hi]).
const COORD_LIMIT := 2048
const SIDE_MAX := 64
const TAX_MAX := 20
const AMOUNT_MAX := 100000000
const RANGES := {
	"x": [-COORD_LIMIT, COORD_LIMIT],
	"y": [-COORD_LIMIT, COORD_LIMIT],
	"x2": [-COORD_LIMIT, COORD_LIMIT],
	"y2": [-COORD_LIMIT, COORD_LIMIT],
	"w": [1, SIDE_MAX],
	"h": [1, SIDE_MAX],
	"amount": [0, AMOUNT_MAX],
	"r": [0, TAX_MAX],
	"c": [0, TAX_MAX],
	"i": [0, TAX_MAX],
}
const TEXT_KEYS := ["type", "building", "zone", "grade", "to"]
## The text str() makes of a null: it must never reach a screen.
const NULL_TEXT := "<null>"


## A copy of order with its number and text fields made safe (see the header). Keys it does not
## know are copied as they are.
static func clean(order: Dictionary) -> Dictionary:
	var out := order.duplicate(true)
	for key: String in RANGES:
		if not out.has(key):
			continue
		var n: Variant = number(out[key])
		if n == null:
			out.erase(key)
		else:
			var bounds: Array = RANGES[key]
			out[key] = _held(n, int(bounds[0]), int(bounds[1]))
	for key: String in TEXT_KEYS:
		if (
			out.has(key)
			and typeof(out[key]) != TYPE_STRING
			and typeof(out[key]) != TYPE_STRING_NAME
		):
			out.erase(key)
	return out


## The finite number v stands for: an int or float as it is, a string that reads as a number
## (as an int when whole), else null (null, bool, list, map, a word, NaN, infinity).
static func number(v: Variant) -> Variant:
	match typeof(v):
		TYPE_INT:
			return v
		TYPE_FLOAT:
			return v if is_finite(v) else null
		TYPE_STRING:
			var t := (v as String).strip_edges()
			if t.is_valid_int():
				return int(t)
			if t.is_valid_float():
				var f := t.to_float()
				return f if is_finite(f) else null
	return null


## text_of(v) for a field a person reads (a thought, a post): the string as it is, a finite number
## as its digits, a list of those joined by spaces, and "" for anything else (null, a map, a bool,
## the literal "<null>").
static func text_of(v: Variant) -> String:
	var out := ""
	match typeof(v):
		TYPE_STRING, TYPE_STRING_NAME:
			out = str(v)
		TYPE_INT:
			out = str(v)
		TYPE_FLOAT:
			out = str(v) if is_finite(v) else ""
		TYPE_ARRAY:
			var parts := PackedStringArray()
			for item: Variant in v as Array:
				if typeof(item) != TYPE_ARRAY and typeof(item) != TYPE_DICTIONARY:
					var part := text_of(item)
					if not part.is_empty():
						parts.append(part)
			out = " ".join(parts)
	return "" if out == NULL_TEXT else out


## v as a whole number inside +-COORD_LIMIT, or fallback when it is not a finite number (a field a
## model nulled or filled with a list).
static func int_of(v: Variant, fallback: int) -> int:
	var n: Variant = number(v)
	if n == null:
		return fallback
	return clampi(
		int(clampf(float(n), -float(COORD_LIMIT), float(COORD_LIMIT))), -COORD_LIMIT, COORD_LIMIT
	)


## v as a yes/no: a bool as it is, a number is yes unless it is 0, text is yes for "true", "yes" and
## "1", and anything else (null, a list, a map) is no.
static func truthy(v: Variant) -> bool:
	match typeof(v):
		TYPE_BOOL:
			return v as bool
		TYPE_INT, TYPE_FLOAT:
			return v != 0
		TYPE_STRING, TYPE_STRING_NAME:
			return str(v).to_lower() in ["true", "yes", "1"]
	return false


## text_of(v), or fallback when v is null (a field the model left out or nulled).
static func text_or(v: Variant, fallback: String) -> String:
	return fallback if v == null else text_of(v)


## n (an int or a float) held to lo..hi: an int stays an int, a float stays a float.
static func _held(n: Variant, lo: int, hi: int) -> Variant:
	if typeof(n) == TYPE_INT:
		return clampi(n as int, lo, hi)
	return clampf(n as float, float(lo), float(hi))
