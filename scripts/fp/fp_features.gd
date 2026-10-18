extends RefCounted
## Every first-person feature, in setup order. Pre-populated by S0; slices edit only their own
## feature file, never this list.
const FEATURES := [
	{"id": "sim_perf", "slice": "F", "path": "res://scripts/fp/sim/sim_perf_feature.gd"},
	{"id": "streetscape", "slice": "G1", "path": "res://scripts/fp/street/streetscape_feature.gd"},
	{"id": "render_opt", "slice": "G2", "path": "res://scripts/fp/render/render_opt_feature.gd"},
	{"id": "traffic", "slice": "E", "path": "res://scripts/fp/traffic/traffic_feature.gd"},
	{"id": "interact", "slice": "A", "path": "res://scripts/fp/interact/interact_feature.gd"},
	{"id": "hud_widgets", "slice": "B", "path": "res://scripts/fp/ui/hud_widgets_feature.gd"},
	{"id": "chat", "slice": "C", "path": "res://scripts/fp/chat/chat_feature.gd"},
	{"id": "posters", "slice": "D", "path": "res://scripts/fp/posters/poster_feature.gd"},
	{"id": "audio", "slice": "I", "path": "res://scripts/fp/audio/audio_feature.gd"},
]
