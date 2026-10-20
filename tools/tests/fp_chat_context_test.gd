extends SceneTree
## Answers in context, the parts that need no chat feature: a mayor's orders and a council ruling
## in words, which mayor a line names, forced replies and the drip hold in ChatFeed, and the typing
## line. fp_chat_test.gd checks the answers themselves, live and offline, with its counting fake.

const K := preload("res://tools/tests/fp_kit.gd")
const T := preload("res://scripts/fp/chat/chat_text.gd")
const F := preload("res://scripts/fp/chat/chat_facts.gd")
const STEP := 0.25
## [line, the speaker's district, the mayor mayor_named finds]. Rosa is also a resident's first
## name, so only "mayor rosa" means Rosa Quintero; "Hana" is not Viktor Han.
const NAMED := [
	["Mayor Viktor, hi", -1, 1],
	["hey viktor", -1, 1],
	["ask Quintero", -1, 3],
	["Rosa, how are you?", -1, -1],
	["mayor rosa?", -1, 3],
	["what are the mayors up to", 2, 2],
	["nothing here", 2, -1],
	["Hana says hi", -1, -1],
]

var fails: Array[String] = []
var ctx: FpContext


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"grow": true})
	_check_fact_words()
	_check_mayor_named()
	_check_forced_replies()
	_check_hold()
	_check_typing_line()
	K.finish(self, "FP_CHAT_CONTEXT_TEST", fails)


func _feed() -> ChatFeed:
	var f := ChatFeed.new()
	get_root().add_child(f)
	f.setup(ctx)
	f.set_process(false)
	return f


func _check_fact_words() -> void:
	var dir := ctx.directory
	var zone := {"type": "zone", "zone": "R", "x": 3, "y": 4, "w": 2, "h": 3}
	var applied := [{"action": zone, "ok": true}, {"action": {"type": "road"}, "ok": false}]
	var did := F.did_words(applied, dir)
	var zoned := did.begins_with("zoned 6 homes") and not did.contains("road")
	K.check(fails, zoned, "facts: a turn in words skips the orders that failed (%s)" % did)
	var tax := F.order_words({"type": "set_tax", "r": 11}, dir)
	K.check(fails, tax == "set home taxes to 11 percent", "facts: a tax order in words (%s)" % tax)
	var ruling := F.council_words({"enacted": ["curfew"]})
	K.check(fails, ruling == "passed the Youth Curfew", "facts: a council ruling (%s)" % ruling)


func _check_mayor_named() -> void:
	for c: Array in NAMED:
		var got := F.mayor_named(str(c[0]), int(c[1]))
		var what := "facts: mayor_named('%s', %d) is %d (%d)" % [c[0], c[1], c[2], got]
		K.check(fails, got == int(c[2]), what)


func _check_forced_replies() -> void:
	var f := _feed()
	var line := "Same answer as before, honestly."
	f.post_now(f.make("r1", "Ann Lee", "resident", 0, line, "chatter"))
	var fast := {"skip": true, "exempt": true, "force": true, "delay_ms": 100}
	var plain := f.enqueue(f.make("r1", "Ann Lee", "resident", 0, line, "chatter"))
	var forced := f.enqueue(f.make("r1", "Ann Lee", "resident", 0, line, "chatter"), fast)
	var copy := f.enqueue(f.make("r2", "Bo Kim", "resident", 0, line, "chatter"), fast)
	var ids := "%d %d %d" % [plain, forced, copy]
	var once := plain == -1 and forced > 0 and copy == -1
	K.check(fails, once, "replies: a direct answer may repeat a row, once (%s)" % ids)
	f.pump(0.5)
	var shown := f.messages.size()
	K.check(fails, shown == 2, "replies: the forced answer is shown (%d)" % shown)
	f.free()


func _check_hold() -> void:
	var f := _feed()
	f.hold_low = true
	f.enqueue(f.make("r3", "Cy Diaz", "resident", 0, "Anyone else hear that?", "chatter"))
	f.enqueue(f.make("system", "Chat", "system", -1, "Live replies are back.", "status"))
	for _k in range(40):
		f.pump(STEP)
	var held: Array = []
	for m: Dictionary in f.messages:
		held.append(str(m["kind"]))
	var what := "hold: while held only alert-level cards drip %s" % str(held)
	K.check(fails, held == ["status"], what)
	f.hold_low = false
	for _k in range(40):
		f.pump(STEP)
	var shown := f.messages.size()
	K.check(fails, shown == 2, "hold: the held chatter shows after (%d)" % shown)
	f.free()


func _check_typing_line() -> void:
	var none: Array[String] = []
	var one: Array[String] = ["Maya"]
	var two: Array[String] = ["Maya", "Theo"]
	var four: Array[String] = ["Maya", "Theo", "Ana", "Bo"]
	var got := [T.typing_line(none), T.typing_line(one), T.typing_line(two), T.typing_line(four)]
	var want := [
		"Someone is typing…",
		"Maya is typing…",
		"Maya and Theo are typing…",
		"Maya, Theo and 2 others are typing…",
	]
	K.check(fails, got == want, "typing: the line names who answers next %s" % str(got))
