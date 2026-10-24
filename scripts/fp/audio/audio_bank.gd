extends RefCounted
## Slice I's sound assets (sounds/fp/, made by tools/audio/synth_fp_sfx.py): names, a load-once
## stream cache and the mix. Assets are normalised (loops to an RMS target, one-shots to a peak or
## short-term loudness), so every level of the mix lives in the tables below. Sounds the game
## starts often are WAV (a start costs about 1 us); the long, rarely started loops are Ogg Vorbis
## (a start decodes headers for about 0.4 ms).

const DIR := "res://sounds/fp/"
## Wind, distant rumble and garden birds: reused as the residential bed (its birdsong rules it
## out downtown). Imported with loop=false, which is not slice I's to change, so it plays as a
## looping duplicate.
const LEGACY_AMBIENCE := "res://sounds/ambience.ogg"
const SURFACES: Array[String] = ["asphalt", "sidewalk", "lot", "grass", "dirt", "bridge"]
const STEP_VARIANTS := 6
## The wet layer played over a step on soaked paving: footstep_splash_<n>.
const SPLASH_VARIANTS := 4
## Every looping asset (their .import files set loop=true).
const LOOPS: Array[String] = [
	"engine_idle", "engine_run", "siren_two_tone", "construction_loop", "fire_crackle", "river_loop",
	"river_bed", "fountain_loop", "plant_hum", "park_birds", "night_insects", "traffic_hum", "rain",
]
const ONE_SHOTS: Array[String] = [
	"horn_short", "horn_long", "chat_blip", "chat_blip_soft", "alert_stinger", "crash_heavy",
	"crash_light", "prop_clatter", "prop_clang", "car_door_open", "car_door_close", "punch_hit",
	"punch_whoosh", "body_fall", "dog_bark_1", "dog_bark_2", "dog_bark_3", "dog_growl", "dog_whine",
	"dog_snap", "pigeon_coo_1", "pigeon_coo_2", "pigeon_flap", "pigeon_takeoff", "cat_meow_1",
	"cat_meow_2", "cat_meow_3", "cat_purr", "cat_hiss", "cat_chatter", "bat_hit", "pipe_hit",
	"bottle_smash", "dog_yelp", "cat_yowl",
]
## Stored as WAV (with every footstep_*); everything else is .ogg.
const WAV_SOUNDS: Array[String] = [
	"engine_idle", "engine_run", "siren_two_tone", "horn_short", "horn_long", "chat_blip",
	"chat_blip_soft", "alert_stinger", "crash_heavy", "crash_light", "prop_clatter", "prop_clang",
	"car_door_open", "car_door_close", "punch_hit", "punch_whoosh", "body_fall", "dog_bark_1",
	"dog_bark_2", "dog_bark_3", "dog_growl", "dog_whine", "dog_snap", "pigeon_coo_1", "pigeon_coo_2",
	"pigeon_flap", "pigeon_takeoff", "cat_meow_1", "cat_meow_2", "cat_meow_3", "cat_purr", "cat_hiss",
	"cat_chatter", "bat_hit", "pipe_hit", "bottle_smash", "dog_yelp", "cat_yowl",
]

## Bus names (created by audio_feature.setup when missing).
const BUS_MUSIC := &"Music"
const BUS_SFX := &"SFX"
const BUS_AMBIENCE := &"Ambience"
const BUS_UI := &"UI"

## Area beds: name -> [stream, volume_db at weight 1]. "residential_quiet" uses LEGACY_AMBIENCE.
const BEDS := {
	"traffic_hum": ["traffic_hum", -9.0],
	"park_birds": ["park_birds", -11.0],
	"river": ["river_bed", -10.0],
	"residential_quiet": ["", -9.0],
	"night_insects": ["night_insects", -14.0],
	"rain": ["rain", -9.0],
}
## Footsteps: base level (contract: -14 dB), running and crouching trims, pitch spread.
const STEP_DB := -14.0
const STEP_RUN_DB := 3.0
const STEP_CROUCH_DB := -6.0
const STEP_PITCH_SPREAD := 0.08
## The splash layer at full wetness, relative to the step.
const SPLASH_DB := -2.0
## UI cues on the UI bus.
const BLIP_DB := -16.0
const BLIP_SOFT_DB := -19.0
const BLIP_CHATTER_DB := -24.0
const STINGER_DB := -12.0
## The player's car hitting walls and cars (car_impact): crash_heavy from CRASH_MPS (m/s of
## closing speed) up, at full level from CRASH_FULL_MPS; crash_light below, at full level from
## CRASH_MPS. Knocked props (prop_knocked) are at full level from KNOCK_FULL_MPS. A softer hit
## keeps at least IMPACT_MIN_GAIN of the level.
const CRASH_MPS := 6.0
const CRASH_FULL_MPS := 14.0
const KNOCK_FULL_MPS := 6.0
const IMPACT_MIN_GAIN := 0.3
## The one-shot a knocked prop of each kind plays (KNOCK_DEFAULT for the metal ones; a carton
## thuds), at most one per KNOCK_GAP (s).
const KNOCK_STREAMS := {
	"bin": "prop_clatter", "bench_park": "prop_clatter", "planter": "crash_light",
	"cone": "prop_clatter", "wheelie": "prop_clatter", "carton": "body_fall",
}
const KNOCK_DEFAULT := "prop_clang"
const KNOCK_GAP := 0.1
## The player's car door (car_door): the latch letting go plays this far under the slam.
const DOOR_OPEN_DB := -7.0
## People hit in the street (person_hit): the blow's thump is at full level from HIT_FULL strength
## (0..1), a car's lower and HIT_CAR_DB louder; someone knocked down lands BODY_FALL_S later
## (body_fall, BODY_FALL_DB on the thump's level). The hero's swing (hero_action) whooshes
## WHOOSH_DB under the thump, a shove SHOVE_DB lower still.
const HIT_FULL := 0.6
const HIT_CAR_DB := 4.0
const BODY_FALL_S := 0.45
const BODY_FALL_DB := 2.0
const WHOOSH_DB := -8.0
const SHOVE_DB := -6.0
## The hero's landing roll (hero_action "roll"): the shoulder meets the ground ROLL_THUD_S after
## the feet, a body_fall ROLL_DB under a knock-down's.
const ROLL_THUD_S := 0.15
const ROLL_DB := -8.0
## Dogs (animal_called): a bark is one of BARK_VARIANTS (dog_bark_<n>), a growl, a whine and a
## struck dog's yelp play dog_growl, dog_whine and dog_yelp, each DOG_DB on the bark. The samples
## are of a dog DOG_PITCH_M high at the shoulder; a dog h m high plays at sqrt(DOG_PITCH_M / h), so
## a small dog yaps higher. A dog's bite on the hero (hero_hurt "bite") snaps its jaws (dog_snap)
## SNAP_Y m up, at the knee.
const BARK_VARIANTS := 3
const DOG_DB := {"bark": 0.0, "growl": -6.0, "whine": -12.0, "yelp": 0.0}
const DOG_PITCH_M := 0.5
const SNAP_Y := 0.5
## A blow of the hero's on an animal (animal_hit): the thump (punch_hit) at ANIMAL_HIT_Y m up,
## ANIMAL_HIT_DB on a blow on a person of the same strength, pitched up ANIMAL_HIT_PITCH for the
## smaller body (a pigeon's twice that).
const ANIMAL_HIT_Y := 0.3
const ANIMAL_HIT_DB := -5.0
const ANIMAL_HIT_PITCH := 1.25
## Pigeons (animal_called): a coo is one of COO_VARIANTS (pigeon_coo_<n>), a lone bird's flap and
## a flock's take-off play pigeon_flap and pigeon_takeoff; each at PIGEON_DB on the bird emitter's
## level, its pitch within PIGEON_PITCH of the sample's.
const COO_VARIANTS := 2
const PIGEON_DB := {"coo": -16.0, "flap": 0.0, "takeoff": 0.0}
const PIGEON_PITCH := 0.06
## Cats (animal_called): a meow is one of MEOW_VARIANTS (cat_meow_<n>), a purr, a hiss, a hunter's
## chatter and a struck cat's yowl play cat_purr, cat_hiss, cat_chatter and cat_yowl, each CAT_DB on
## the meow. The samples are of a cat CAT_PITCH_M high at the shoulder; a cat h m high plays at
## sqrt(CAT_PITCH_M / h) (a kitten mews higher), within CAT_PITCH of that.
const MEOW_VARIANTS := 3
const CAT_DB := {"meow": 0.0, "purr": -8.0, "hiss": -2.0, "chatter": -8.0, "yowl": 0.0}
const CAT_PITCH_M := 0.25
const CAT_PITCH := 0.05

static var _cache: Dictionary = {}
static var _legacy_loop: AudioStream = null


## The stream sounds/fp/<name>.wav or .ogg, loaded once; null when the file is missing.
static func stream(name: String) -> AudioStream:
	if not _cache.has(name):
		var path := path_of(name)
		_cache[name] = load(path) as AudioStream if ResourceLoader.exists(path) else null
	return _cache[name]


static func path_of(name: String) -> String:
	return DIR + name + (".wav" if is_wav(name) else ".ogg")


static func is_wav(name: String) -> bool:
	return name in WAV_SOUNDS or name.begins_with("footstep_")


## Every asset name (loops, one-shots, footsteps).
static func all_names() -> Array[String]:
	var out: Array[String] = []
	out.append_array(LOOPS)
	out.append_array(ONE_SHOTS)
	for s in SURFACES:
		for n in range(1, STEP_VARIANTS + 1):
			out.append(step_name(s, n))
	for n in range(1, SPLASH_VARIANTS + 1):
		out.append("footstep_splash_%d" % n)
	return out


## Loads every asset now (FP setup), so nothing touches the disk mid-game.
static func preload_all() -> void:
	for n in all_names():
		stream(n)
	legacy_ambience_loop()


## footstep_<surface>_<n> (n in 1..STEP_VARIANTS).
static func step_name(surface: String, n: int) -> String:
	return "footstep_%s_%d" % [surface, n]


## A looping duplicate of LEGACY_AMBIENCE (the imported resource keeps loop=false), or null.
static func legacy_ambience_loop() -> AudioStream:
	if _legacy_loop == null and ResourceLoader.exists(LEGACY_AMBIENCE):
		var src := load(LEGACY_AMBIENCE) as AudioStreamOggVorbis
		if src != null:
			var dup := src.duplicate() as AudioStreamOggVorbis
			dup.loop = true
			_legacy_loop = dup
	return _legacy_loop


## The stream a bed plays.
static func bed_stream(bed: String) -> AudioStream:
	if bed == "residential_quiet":
		var s := legacy_ambience_loop()
		return s if s != null else stream("park_birds")
	return stream(str(BEDS[bed][0]))
