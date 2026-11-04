extends RefCounted
## The press run: a campaign poster that a live image model made lands on the street (GameBus
## poster_ready with meta.source "live"), and the activity feed says so with the image model's badge
## and the mayor whose campaign it is. Only a live image counts: a pre-baked or procedural poster is
## not a model decision, so it stays off the feed. Pure helpers; ActivityFeature adds the card.

const D := preload("res://scripts/sim/sim_defs.gd")
const W := preload("res://scripts/fp/activity/activity_words.gd")
## The poster kind of mayor <id>'s campaign (PosterDirector: "campaign_" + the mayor's id).
const KIND_PREFIX := "campaign_"
const HEADLINE := "Campaign poster printed"


## The mayor index whose live campaign poster this GameBus.poster_ready payload is, else -1.
static func mayor_of(poster: Dictionary) -> int:
	var meta: Variant = poster.get("meta", {})
	if typeof(meta) != TYPE_DICTIONARY or str((meta as Dictionary).get("source", "")) != "live":
		return -1
	var kind := str(poster.get("kind", ""))
	if not kind.begins_with(KIND_PREFIX):
		return -1
	return D.mayor_index(kind.substr(KIND_PREFIX.length()))


## The feed card's text for mayor mi's poster: {"headline", "detail"}.
static func words(mi: int) -> Dictionary:
	var district := str(D.MAYORS[mi]["district"])
	return {"headline": HEADLINE, "detail": "A new campaign poster went up for the %s." % district}


## The badge of the image model that drew it.
static func model_badge() -> String:
	return W.model_label(GmiImageClient.MODEL)
