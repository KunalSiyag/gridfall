extends RefCounted
## Removes model brand names from CityBrain text: a Gazette page as it comes in, and state restored
## from saves written before the display names, whose text feeds the prompts and the HUDs. No nodes.

const D := preload("res://scripts/sim/sim_defs.gd")


## De-brands a Gazette front page in place: headline, editorial, and each story's title and body.
static func debrand_paper(paper: Dictionary) -> void:
	for key: String in ["headline", "editorial"]:
		if paper.has(key):
			paper[key] = D.debrand(str(paper[key]))
	if typeof(paper.get("stories")) == TYPE_ARRAY:
		for st: Variant in paper["stories"]:
			if typeof(st) == TYPE_DICTIONARY:
				for key: String in ["title", "body"]:
					if (st as Dictionary).has(key):
						(st as Dictionary)[key] = D.debrand(str((st as Dictionary)[key]))


## De-brands restored brain state in place: proposal authors, mayor posts, thoughts and log
## entries, the Gazette and the council ruling.
static func debrand_state(
	proposals: Dictionary, mayor_state: Array[Dictionary], paper: Dictionary, council: Dictionary
) -> void:
	for key: Variant in proposals.keys():
		if typeof(proposals[key]) == TYPE_DICTIONARY:
			var pr: Dictionary = proposals[key]
			pr["by"] = D.debrand(str(pr.get("by", "")))
	for ms: Dictionary in mayor_state:
		ms["post"] = D.debrand(str(ms.get("post", "")))
		if typeof(ms.get("thoughts")) == TYPE_ARRAY:
			var th: Array = ms["thoughts"]
			for k in range(th.size()):
				th[k] = D.debrand(str(th[k]))
		if typeof(ms.get("log")) == TYPE_ARRAY:
			for e: Variant in ms["log"]:
				if typeof(e) == TYPE_DICTIONARY:
					for key: String in ["thought", "post"]:
						if (e as Dictionary).has(key):
							(e as Dictionary)[key] = D.debrand(str((e as Dictionary)[key]))
	debrand_paper(paper)
	if council.has("statement"):
		council["statement"] = D.debrand(str(council["statement"]))
