extends SceneTree
## Writes the golden file tools/tests/fixtures/mayor_prompts_golden.json that fp_mayor_context_test
## compares the mayors' prompts against with the flag off: the system and user prompt of each of
## the five mayors for the fixed seed-7 state of tests/support/prompt_fixture.gd (sha256 and length
## of all ten, the full text of mayor 0's two prompts and of mayor 3's user prompt for line diffs).
##
## Regenerate it only for a DELIBERATE change to the prompt text, or because another change moved
## what the sim prints into a prompt (the district summary, the city summary, the map): then
## regenerate and read the git diff of the golden's full texts, which must show only that change.
##
##   XDG_DATA_HOME=$(mktemp -d) GRIDFALL_OFFLINE=1 godot --headless --path . \
##       -s tools/gen_mayor_prompts_golden.gd -- tools/tests/fixtures/mayor_prompts_golden.json

const D := preload("res://scripts/sim/sim_defs.gd")
const PF := preload("res://tools/tests/support/prompt_fixture.gd")


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("mayor_context_v2", false)
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -s tools/gen_mayor_prompts_golden.gd -- <out.json>")
		quit(2)
		return
	var w := PF.build(get_root())
	var brain: CityBrain = w["brain"]
	var out := {"day": PF.PROMPT_DAY, "system": [], "user": []}
	for mi in range(D.MAYORS.size()):
		var s: String = brain._mayor_system_prompt(mi)
		var u: String = brain._mayor_user_prompt(mi, PF.PROMPT_DAY)
		out["system"].append(
			{"sha": s.sha256_text(), "len": s.length(), "text": s if mi == 0 else ""}
		)
		out["user"].append(
			{"sha": u.sha256_text(), "len": u.length(), "text": u if mi == 0 or mi == 3 else ""}
		)
	var f := FileAccess.open(args[0], FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "\t"))
	f.close()
	print("WROTE ", args[0], " ", out["system"][0]["len"], " ", out["user"][0]["len"])
	quit(0)
