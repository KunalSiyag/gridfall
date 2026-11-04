extends RefCounted
## Reading a feed card in tests: the text of a named label, and the text of a named badge.

const S := preload("res://scripts/fp/ui/hud_style.gd")
## Brand names and system words that owned feed text must never show (badges are exempt).
const LEAK_RE := "(?i)(Argon|DeepSeek|Kimi|Qwen|Grok|GMI|gemini|MiniMax|latency|cache|heuristic)"


## The text of the label named n under root, "" when it is missing.
static func text(root: Node, n: String) -> String:
	if root == null:
		return ""
	var l := root.find_child(n, true, false) as Label
	return l.text if l != null else ""


## The text of the badge named n under root, "" when it is missing or not a badge.
static func badge(root: Node, n: String) -> String:
	if root == null:
		return ""
	var p := root.find_child(n, true, false)
	if p == null or p.get_child_count() == 0:
		return ""
	var l := p.get_child(0) as Label
	return l.text if l != null and l.has_meta(S.BADGE_META) else ""
