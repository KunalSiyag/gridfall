extends RefCounted
## What the model ledger (scripts/ai/model_ledger.gd) adds to the street's mayors' league: an
## "Orders" column (the share of a mayor's orders the city carried out), a "Speed" column (the
## typical time to answer, or what to read instead when no live answer has come) and a health
## light beside the name. Pure functions over standings rows; nothing here draws or reads the sim.
##
## Street text names no model here: the words are "Orders", "Speed" and the light's words. (The
## league's cells show a model only as a badge, hud_style.badge: the one street text allowed to.)

## The words the light is read as (also its tooltip): ledger health -> [short word, sentence].
const HEALTH_WORDS := {
	"green": ["good", "Answering live."],
	"amber":
	["shaky", "Answering live, but a recent answer failed, was retried, was cut off or slow."],
	"red": ["down", "The last live calls failed."],
	"grey": ["replay", "No live answer yet: only recorded answers."],
	"scripted": ["scripted", "No live answer yet: only the built-in planner has answered."],
	"idle": ["idle", "Has not been called yet."],
}
## What the Orders cell reads before any order was counted, and its tooltip.
const NO_DATA := "no data"
const NO_DATA_TIP := (
	"No orders counted yet. The count starts with the first turn after this city was begun or"
	+ " loaded; a save from before the model ledger has no earlier count."
)


## Adds to each standings row (ReporterDesk.standings) "speed" (text), "speed_ms" (-1 when none),
## "health" (ModelLedger.health_of word) and "orders_text". ledger null, or the model_ledger flag
## off, leaves the neutral values: Speed "-", the light idle, and Orders the sim's whole-city count
## (a ledger an older save carried must not show through a switched-off flag). With the ledger on,
## Orders reads the same counters as the Arena tab (the ledger's: the model's own live and replayed
## orders, since the ledger began).
static func decorate(rows: Array[Dictionary], ledger: ModelLedger) -> void:
	var by_mi := {}
	var from_ledger := ledger != null and ModelLedger.enabled()
	if from_ledger:
		for lr: Dictionary in ledger.mayor_rows():
			by_mi[int(lr["mi"])] = lr
	for r: Dictionary in rows:
		var lr: Dictionary = by_mi.get(int(r.get("mi", -1)), {}) if from_ledger else {}
		r["speed_ms"] = int(lr.get("p50_ms", -1))
		r["speed"] = speed_text(lr)
		r["health"] = str(lr.get("health", "idle"))
		if from_ledger:
			r["orders_text"] = orders_text(
				int(lr.get("orders_ok", 0)), int(lr.get("orders_rejected", 0))
			)
		else:
			r["orders_text"] = orders_text(int(r.get("orders", 0)), int(r.get("refused", 0)))


## "87%" for orders carried out of orders given; NO_DATA before any order.
static func orders_text(done: int, refused: int) -> String:
	var total := done + refused
	return NO_DATA if total <= 0 else "%d%%" % roundi(100.0 * float(done) / float(total))


## A mayor's Speed: the median time to answer of its live calls ("11.2 s"); "replay" when its
## turns were recorded answers; "-" for nothing to say (no turn yet, or only the scripted planner).
static func speed_text(ledger_row: Dictionary) -> String:
	if ledger_row.is_empty():
		return "-"
	if int(ledger_row.get("n_live", 0)) > 0:
		return ModelLedger.seconds_text(int(ledger_row.get("p50_ms", -1)))
	if int(ledger_row.get("turns_replay", 0)) + int(ledger_row.get("replay", 0)) > 0:
		return "replay"
	return "-"


## The word a health light is read as ("good", "shaky", "down", "replay", "scripted", "idle").
static func health_word(health: String) -> String:
	return str((HEALTH_WORDS.get(health, HEALTH_WORDS["idle"]) as Array)[0])


## The light's tooltip: its sentence.
static func health_tip(health: String) -> String:
	return str((HEALTH_WORDS.get(health, HEALTH_WORDS["idle"]) as Array)[1])
