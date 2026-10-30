extends SceneTree
## Feature arrival coverage (Phase B step 4): sky, audio and posters heal idempotently when
## their pack mounts on a split web build — no duplicate actors, no lost state, no new GMI
## traffic — and the props pack re-kits the procedural tree crowns into the real models.

const K := preload("res://tools/tests/fp_kit.gd")
const SkyDirector := preload("res://scripts/world/sky_director.gd")
const AudioDirector := preload("res://scripts/audio_director.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")
const ImgClient := preload("res://scripts/ai/gmi_image_client.gd")
const WebPackStream := preload("res://scripts/ops/web_pack_stream.gd")

var fails: Array[String] = []


class FakeStream:
	extends WebPackStream

	func request_path(_path: String) -> String:
		return ""

	func arrive(pack: String) -> void:
		pack_ready.emit(pack)


func _init() -> void:
	# --- Sky: setup builds the material once; refresh is a no-op afterwards.
	var env := Environment.new()
	var sun := DirectionalLight3D.new()
	var sky: SkyDirector = SkyDirector.new()
	get_root().add_child(sky)
	sky.setup(null, env, sun, null)
	var built: ShaderMaterial = sky._sky_mat
	K.check(fails, built != null, "sky: setup builds the material (assets present)")
	var hour0: float = sky.hour
	sky.refresh_pack_assets()
	K.check(fails, sky._sky_mat == built, "sky: refresh with a live sky is a no-op")
	K.check(fails, sky.hour == hour0, "sky: hour preserved")
	K.check(fails, env.sky != null and env.sky.sky_material == built, "sky: environment untouched")

	# --- Sky: the arrival path — no sky at setup (pack missing), refresh builds it.
	var env2 := Environment.new()
	var sky2: SkyDirector = SkyDirector.new()
	get_root().add_child(sky2)
	sky2.env = env2
	sky2.refresh_pack_assets()
	K.check(fails, sky2._sky_mat != null, "sky: refresh builds once the assets exist")
	K.check(fails, env2.sky != null, "sky: environment gets the sky")
	var built2: ShaderMaterial = sky2._sky_mat
	sky2.refresh_pack_assets()
	K.check(fails, sky2._sky_mat == built2, "sky: a second arrival keeps the material")
	var sky3: SkyDirector = SkyDirector.new()
	get_root().add_child(sky3)
	sky3.refresh_pack_assets()
	K.check(fails, sky3._sky_mat == null, "sky: no environment, no sky, no crash")

	# --- Audio director: cached misses purge, stems heal, mute/mix state is preserved.
	var ad: AudioDirector = AudioDirector.new()
	get_root().add_child(ad)
	await process_frame  # let _ready build the players
	ad._streams["res://sounds/music/definitely_missing.ogg"] = null
	ad.muted = true
	ad.refresh_pack_assets()
	K.check(
		fails,
		not ad._streams.has("res://sounds/music/definitely_missing.ogg"),
		"audio: cached miss purged"
	)
	K.check(fails, ad.muted, "audio: mute preserved")
	ad._nominal_player.stop()
	ad._nominal_player.stream = null
	ad.refresh_pack_assets()
	K.check(fails, ad._nominal_player.stream != null, "audio: silent stem reassigned")
	K.check(fails, ad._nominal_player.playing, "audio: silent stem restarted")
	var crisis_stream: AudioStream = ad._crisis_player.stream
	ad.refresh_pack_assets()
	K.check(fails, ad._crisis_player.stream == crisis_stream, "audio: live stem untouched")

	# --- FP audio bank: purging drops the misses, keeps the hits.
	BANK._cache["definitely_missing_sfx"] = null
	BANK.stream("punch_hit")
	BANK.purge_missing()
	K.check(fails, not BANK._cache.has("definitely_missing_sfx"), "bank: miss purged")
	K.check(fails, BANK._cache.has("punch_hit"), "bank: hit kept")

	# --- Posters: the manifest is re-read after the pack arrives.
	var ic: ImgClient = ImgClient.new()
	ic._manifest_loaded = true
	ic._by_key["k"] = "f.png"
	ic._prebaked_tex["missing.png"] = null
	ic.reset_pack_caches()
	K.check(fails, not ic._manifest_loaded, "posters: manifest re-read armed")
	K.check(fails, ic._by_key.is_empty(), "posters: stale manifest entries dropped")
	K.check(fails, not ic._prebaked_tex.has("missing.png"), "posters: cached miss purged")
	ic.free()

	# --- Trees: the props pack re-kits procedural crowns into the real models.
	var ctx: FpContext = K.make_ctx(get_root(), {"view": true})
	var view: CityView = ctx.view
	var stream := FakeStream.new()
	view.pack_stream = stream
	view._tree_kits = [view._procedural_tree_parts()]  # the pre-arrival fallback
	view._pack_waiting["props"] = ["res://models/real/props/tree_oak.glb"]
	stream.arrive("props")
	K.check(fails, view._tree_kits.size() > 1, "trees: real kits replace the fallback")
	K.check(fails, not view._tree_chunks.is_empty(), "trees: chunks rebuilt")

	K.finish(self, "PACK_ARRIVAL_TEST", fails)
