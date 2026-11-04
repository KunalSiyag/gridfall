extends SceneTree
## Reading a model's reply (GmiParse, reached through GmiClient.extract_json and the real _post):
## a table of sample replies as the models actually send them (fences, <think> blocks, prose
## around, trailing commas, NaN, braces in strings, two objects, a reply cut off by the token
## limit, a reply that is only reasoning) with what each must yield, plus the chat message shapes
## (a content that is a list of parts, an empty content with the answer in the reasoning field)
## and a hostile reply that must not take long. Offline; the one network step (_round_trip) is a
## fake. Prints GMI_PARSE_TEST: PASS|FAIL.

var fails: Array[String] = []


## A GmiClient with the real _post and a scripted HTTPRequest round trip.
class ScriptedNet:
	extends GmiClient
	var message: Dictionary = {}
	## When set, the whole reply body instead of {"choices": [{"message": message}]}.
	var raw_body: String = ""

	func _round_trip(_headers: PackedStringArray, _body: String, _timeout_s: float) -> Dictionary:
		var body := (
			raw_body
			if not raw_body.is_empty()
			else JSON.stringify({"choices": [{"message": message}]})
		)
		return {
			"result": HTTPRequest.RESULT_SUCCESS,
			"http": 200,
			"headers": PackedStringArray(),
			"body": body.to_utf8_buffer(),
		}


func check(ok: bool, what: String) -> void:
	print(("GMI_PARSE_TEST:   ok   " if ok else "GMI_PARSE_TEST:   FAIL ") + what)
	if not ok:
		fails.append(what)


func _init() -> void:
	await process_frame
	_check_table()
	_check_repairs()
	_check_message_text()
	_check_cut_off()
	_check_salvage()
	_check_hostile()
	await _check_post()
	print("GMI_PARSE_TEST: " + ("PASS" if fails.is_empty() else "FAIL " + str(fails)))
	quit(0 if fails.is_empty() else 1)


## [name, reply, expected] where expected is {} for "no answer" or the pairs that must hold:
## {"key": value} are compared on the keys given (the parsed object may hold more).
func _table() -> Array:
	var long_post := "x".repeat(300)
	return [
		["plain object", '{"thought":"hi","actions":[]}', {"thought": "hi"}],
		["leading and trailing whitespace", '\n\n  {"thought":"hi"}  \n', {"thought": "hi"}],
		["json fence", '```json\n{"thought":"fenced"}\n```', {"thought": "fenced"}],
		[
			"bare fence with prose before and after",
			'Here is my plan:\n```\n{"thought":"in a bare fence","n":2}\n```\nGood luck!',
			{"thought": "in a bare fence", "n": 2.0}
		],
		[
			"think block first, braces in it ignored",
			'<think>Let me draft {"draft": 1} and check {x}.</think>\n{"thought":"after thinking"}',
			{"thought": "after thinking"}
		],
		["think tags in capitals", '<THINK>hmm {"a":1}</THINK>{"b":2}', {"b": 2.0}],
		[
			"reasoning closed by a lone close tag",
			(
				"The user wants a plan. I will answer in JSON.\n</think>\n"
				+ '{"thought":"after a lone tag"}'
			),
			{"thought": "after a lone tag"}
		],
		["unclosed think block (reply cut while thinking)", '<think>I should {"a": 1', {}],
		["only reasoning prose", "I think the city needs more power plants, so I would", {}],
		["no json at all", "Sorry, I cannot help with that.", {}],
		["empty reply", "", {}],
		["whitespace only", "   \n\t ", {}],
		[
			"trailing commas in object and array",
			'{"thought":"t","actions":[{"type":"zone","x":1,},],}',
			{"thought": "t"}
		],
		[
			"a comma inside a string is not a trailing comma",
			'{"post":"wait, }","n":1}',
			{"post": "wait, }", "n": 1.0}
		],
		[
			"stray braces in prose before the object",
			(
				'Use the {format} below, {{ok}}: {"thought":"the real one","actions":[]} '
				+ "Hope {this} helps"
			),
			{"thought": "the real one"}
		],
		[
			"two objects, the larger wins",
			(
				'{"ok":true}\nand then\n{"thought":"the long answer","actions":[],"post":"%s"}'
				% long_post
			),
			{"thought": "the long answer"}
		],
		["two objects of one size, the first wins", '{"a":1}{"b":2}', {"a": 1.0}],
		[
			"braces and quotes inside strings",
			'{"post":"he said \\"go }{ now\\" {ok}","n":3}',
			{"post": 'he said "go }{ now" {ok}', "n": 3.0}
		],
		[
			"nested objects, the outer one is the answer",
			'{"thought":"t","votes":{"a":"yes","b":{"x":1}},"actions":[{"type":"road"}]}',
			{"thought": "t"}
		],
		["NaN and Infinity", '{"x":NaN,"y":Infinity,"z":-Infinity,"ok":1}', {"ok": 1.0}],
		[
			"cut off inside an order: the finished orders and the thought are kept",
			'{"thought":"plan","actions":[{"type":"zone","x":1,"y":2},{"type":"ro',
			{"thought": "plan"}
		],
		[
			"cut off between orders",
			'{"thought":"plan","actions":[{"type":"zone","x":1},{"type":"road","x":2},',
			{"thought": "plan"}
		],
		["cut off in the middle of a string value", '{"a":1,"thought":"half a sen', {"a": 1.0}],
		["cut off before any value is complete", '{"thought":"half a sen', {}],
		[
			"cut off inside a fence",
			'```json\n{"thought":"fenced","actions":[{"type":"zone","x":1},{"ty',
			{"thought": "fenced"}
		],
		["single quotes are not json", "{'thought': 'x'}", {}],
		["unicode text", '{"thought":"Rosa — 100 % ☀ 市民"}', {"thought": "Rosa — 100 % ☀ 市民"}],
		["a bare array of objects is no answer object", '[{"a":1},{"b":2}]', {}],
		[
			"a bare array with a long element is no answer object either",
			'Here: [{"id":"r1","say":"a"},{"id":"r2","say":"bb"}]',
			{}
		],
		["a bare array cut off mid-element is no answer", '[{"id":"r1"},{"id":"r2","say":"b', {}],
		[
			"a [1] in prose does not hide the answer",
			'See [1] and [note]: {"thought":"still read"}',
			{"thought": "still read"}
		],
		[
			"a list inside the answer is not a bare array",
			'Plan: {"thought":"t","actions":[{"type":"zone"},{"type":"road"}]}',
			{"thought": "t"}
		],
		[
			"a lone close tag inside a quoted value is text, not the end of reasoning",
			'{"thought":"I wrote </think> as text","n":1}',
			{"thought": "I wrote </think> as text", "n": 1.0}
		],
		[
			"a lone close tag in a value, with nested braces after it",
			'{"thought":"a </think> b","m":{"x":1}}',
			{"thought": "a </think> b"}
		],
		[
			"twenty stray prose groups before the answer",
			"{x} ".repeat(20) + '{"thought":"the answer","n":1}',
			{"thought": "the answer"}
		],
		[
			"twenty small objects, then a larger answer",
			'{"a":1} '.repeat(20) + '{"thought":"the answer","actions":[]}',
			{"thought": "the answer"}
		],
		[
			"a complete answer before a longer cut-off draft",
			(
				'{"thought":"A","actions":[]} Wait, revise: {"thought":"B is longer text here",'
				+ '"actions":[{"type":"zone","x":1,"y":2},{"type":"road","x":1,'
			),
			{"thought": "A"}
		],
		[
			"a cut-off reply inside its first order is no answer",
			'{"thought":"p","actions":[{"type":"zone","x":1,',
			{}
		],
		[
			"a cut-off reply right after the opening of its list is no answer",
			'{"thought":"p","actions":[',
			{}
		],
		[
			"think block, fence, prose and trailing comma together",
			(
				'<think>draft</think>Sure!\n```json\n{"thought":"all of it","actions":[],}\n```'
				+ "\nBye {}"
			),
			{"thought": "all of it"}
		],
	]


func _check_table() -> void:
	for row: Array in _table():
		var got := GmiClient.extract_json(str(row[1]))
		var want: Dictionary = row[2]
		var ok := true
		if want.is_empty():
			ok = got.is_empty()
		else:
			for k: String in want:
				ok = ok and got.has(k) and str(got[k]) == str(want[k])
		check(ok, "%s (%s)" % [row[0], JSON.stringify(got).left(80)])
	# Specific shapes the table's key compare cannot show.
	var cut := GmiClient.extract_json('{"thought":"p","actions":[{"type":"zone","x":1},{"type":"ro')
	check(
		(cut.get("actions", []) as Array).size() == 1,
		"a cut-off order is dropped, the finished one stays"
	)
	var between := GmiClient.extract_json(
		'{"thought":"p","actions":[{"type":"zone","x":1},{"type":"road","x":2},'
	)
	check((between.get("actions", []) as Array).size() == 2, "two finished orders stay")
	var nan := GmiClient.extract_json('{"x":NaN,"ok":1}')
	check(nan.has("x") and nan["x"] == null, "NaN becomes null")
	var big := GmiClient.extract_json('{"a":1}{"b":2,"c":3}')
	check(big.has("c") and not big.has("a"), "the larger of two objects is chosen")
	var first_of_two := GmiClient.extract_json('{"a":1}{"b":2}')
	check(first_of_two.has("a") and not first_of_two.has("b"), "a tie goes to the first")
	check(
		(
			GmiParse.extract_json('<think>{"a":1}</think>{"b":2}')
			== GmiClient.extract_json('<think>{"a":1}</think>{"b":2}')
		),
		"GmiClient.extract_json is GmiParse.extract_json"
	)


func _check_repairs() -> void:
	check(GmiParse.repair('{"a":1,}') == '{"a":1}', "repair: a trailing comma goes")
	check(
		GmiParse.repair("[1,2 , ]") == "[1,2  ]", "repair: a trailing comma before a bracket goes"
	)
	check(GmiParse.repair('{"a":"x,}"}') == '{"a":"x,}"}', "repair: a comma in a string stays")
	check(GmiParse.repair('{"a":NaN}') == '{"a":null}', "repair: NaN becomes null")
	check(GmiParse.repair('{"a":"NaN"}') == '{"a":"NaN"}', "repair: the word NaN in a string stays")
	check(
		GmiParse.repair('{"NaNa":1,"b":-Infinity}') == '{"NaNa":1,"b":null}',
		"repair: only a bare NaN or Infinity token is rewritten"
	)
	check(GmiParse.parse_object("[1,2]").is_empty(), "parse_object: a list is not an object")
	check(
		GmiParse.parse_object("{").is_empty(), "parse_object: broken text is {} and prints nothing"
	)


func _check_message_text() -> void:
	check(GmiParse.message_text({"content": "hello"}) == "hello", "message: a plain content")
	check(
		GmiParse.message_text({"content": null, "reasoning_content": '{"a":1}'}) == '{"a":1}',
		"message: a null content falls back to the reasoning field"
	)
	check(
		(
			GmiParse.message_text({"content": "  ", "reasoning": "thought it through"})
			== "thought it through"
		),
		"message: a blank content falls back to the reasoning field"
	)
	check(
		(
			GmiParse.message_text({"content": [{"type": "text", "text": '{"a":'}, {"text": "1}"}]})
			== '{"a":\n1}'
		),
		"message: a list of parts is joined"
	)
	check(GmiParse.message_text({"content": 5}).is_empty(), "message: a number is no text")
	check(GmiParse.message_text({}).is_empty(), "message: nothing is empty")
	var think_only := GmiParse.message_text(
		{"content": "", "reasoning_content": "Let me think. {no json}"}
	)
	check(
		GmiClient.extract_json(think_only).is_empty(),
		"a reasoning-only reply with no object yields {}"
	)


## The cut-off rule: what survives a reply that stops mid-way, and what is dropped with its order.
func _check_cut_off() -> void:
	var one := '{"type":"zone","x":1,"y":2}'
	var head := '{"thought":"p","actions":[' + one + ","
	var cases := {
		"inside a later order's flat members": head + '{"type":"road","x":3,',
		"after a comma inside a later order": head + '{"type":"road","x":3,"y":',
		"after a nested list of a later order": head + '{"type":"zone","tiles":[1,2,3],"grade":"hi',
		"inside a nested list of a later order": head + '{"type":"road","pts":[1,2,3',
		"after a nested object of a later order":
		head + '{"type":"road","from":{"x":1,"y":2},"to":{"x":5',
	}
	for what: String in cases:
		var got := GmiParse.extract_json(str(cases[what]))
		var orders: Array = got.get("actions", [])
		check(
			orders.size() == 1 and orders[0] == {"type": "zone", "x": 1.0, "y": 2.0},
			"cut off %s: only the finished order stays (%s)" % [what, JSON.stringify(got).left(90)]
		)
	var residents := GmiParse.extract_json(
		'{"residents":[{"id":"r1","tags":["a"],"say":"x"},{"id":"r2","tags":["a","b"],"th'
	)
	var kept: Array = residents.get("residents", [])
	check(
		kept.size() == 1 and (kept[0] as Dictionary).has("say"),
		(
			"a resident cut off after its tags is dropped whole (%s)"
			% JSON.stringify(residents).left(90)
		)
	)
	var tiles := GmiParse.extract_json('{"thought":"t","tiles":[[1,2],[3,4],[5')
	check(
		(tiles.get("tiles", []) as Array).size() == 2,
		"a list of lists at the root keeps its finished items"
	)
	var meta := GmiParse.extract_json('{"thought":"t","meta":{"a":1},"note":"cut here')
	check(
		meta.has("meta") and not meta.has("note"), "a finished root member stays, the cut one goes"
	)


func _check_salvage() -> void:
	var s := GmiClient.salvage_array('{"residents":[{"id":"r1","a":1},{"id":"r2"},{"id":"r3","a"')
	check(
		s.has("residents") and (s["residents"] as Array).size() == 2,
		"salvage_array keeps the finished entries of a cut-off list"
	)
	check(GmiClient.salvage_array("no brackets here").is_empty(), "salvage_array: no list is {}")
	check(
		GmiClient.salvage_array('the "plan" is [{"a":1},{"b":2}]').is_empty(),
		"salvage_array: a list that is not the value of a quoted key is {}"
	)
	var cut := GmiClient.extract_json('{"residents":[{"id":"r1"},{"id":"r2"},{"id":"r3","a"')
	check(
		cut.has("residents") and (cut["residents"] as Array).size() == 2,
		"extract_json closes a cut-off list the same way"
	)


func _check_hostile() -> void:
	var t0 := Time.get_ticks_msec()
	var braces := "{".repeat(200000)
	check(GmiClient.extract_json(braces).is_empty(), "200 000 open braces yield {}")
	var quotes := ('{"a":"' + "\\".repeat(5000)).repeat(40)
	GmiClient.extract_json(quotes)
	var deep := '{"a":'.repeat(3000) + "1" + "}".repeat(3000)
	GmiClient.extract_json(deep)
	var many := '{"k":1}'.repeat(20000)
	check(not GmiClient.extract_json(many).is_empty(), "twenty thousand tiny objects still answer")
	var ms := Time.get_ticks_msec() - t0
	check(ms < 10000, "hostile replies are read in bounded time (%d ms)" % ms)


## The real _post over a scripted round trip: what a reply becomes in the client.
func _check_post() -> void:
	var net := ScriptedNet.new()
	net.name = "ScriptedNet"
	get_root().add_child(net)
	var cases := [
		["fenced content", {"content": '```json\n{"thought":"a","actions":[]}\n```'}, true],
		["content with prose", {"content": 'Here you go: {"thought":"b"} Done.'}, true],
		[
			"empty content, answer in reasoning_content",
			{"content": "", "reasoning_content": '{"thought":"c"}'},
			true
		],
		[
			"null content, answer in reasoning_content",
			{"content": null, "reasoning_content": '{"thought":"d"}'},
			true
		],
		["content as parts", {"content": [{"type": "text", "text": '{"thought":"e"}'}]}, true],
		[
			"reasoning only, no object",
			{"content": "", "reasoning_content": "Hmm, let me think about zoning."},
			false
		],
		["refusal prose", {"content": "I can't help with that."}, false],
		[
			"cut off inside its first order: no answer, so the caller falls back",
			{"content": '{"thought":"g","actions":[{"type":"zone","x":1,'},
			false
		],
		["a bare array of objects", {"content": '[{"type":"zone","x":1},{"type":"road"}]'}, false],
		[
			"cut off but with a finished thought",
			{"content": '{"thought":"f","actions":[{"type":"zone","x":1},{"ty'},
			true
		],
	]
	for row: Array in cases:
		net.message = row[1]
		var res: Dictionary = await net._post("m", "s", "u", 100, 5.0)
		var ok := bool(res.get("ok", false)) == bool(row[2])
		if bool(row[2]):
			ok = ok and (res.get("data", {}) as Dictionary).has("thought")
		else:
			ok = (
				ok
				and str(res.get("error", "")) == "no JSON in reply"
				and not bool(res.get("service_fail", true))
			)
		check(ok, "_post: " + str(row[0]))
	# A reply body whose "choices" is not a list is no choices, not a script error.
	for raw: String in [
		'{"choices":null}', '{"choices":"x"}', '{"choices":{"a":1}}', '{"choices":5}'
	]:
		net.raw_body = raw
		var res: Variant = await net._post("m", "s", "u", 100, 5.0)
		check(
			(
				typeof(res) == TYPE_DICTIONARY
				and not bool((res as Dictionary).get("ok", true))
				and str((res as Dictionary).get("error", "")) == "no choices"
			),
			"_post: %s is 'no choices' and a failed call, not a service failure" % raw
		)
		check(
			(
				typeof(res) == TYPE_DICTIONARY
				and not bool((res as Dictionary).get("service_fail", true))
			),
			"_post: %s does not count against the breaker" % raw
		)
	net.raw_body = ""
	net.queue_free()
