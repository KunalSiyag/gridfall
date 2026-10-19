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
const ONE_SHOTS: Array[String] = ["horn_short", "horn_long", "chat_blip", "chat_blip_soft", "alert_stinger"]
## Stored as WAV (with every footstep_*); everything else is .ogg.
const WAV_SOUNDS: Array[String] = [
	"engine_idle", "engine_run", "siren_two_tone", "horn_short", "horn_long", "chat_blip", "chat_blip_soft", "alert_stinger",
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
