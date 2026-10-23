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
	{"id": "overview", "slice": "integration", "path": "res://scripts/fp/overview/overview_feature.gd"},
	{"id": "drive", "slice": "integration", "path": "res://scripts/fp/drive/drive_feature.gd"},
	{"id": "phone", "slice": "integration", "path": "res://scripts/fp/phone/phone_feature.gd"},
	{
		"id": "activity", "slice": "integration",
		"path": "res://scripts/fp/activity/activity_feature.gd",
	},
	{"id": "crews", "slice": "integration", "path": "res://scripts/fp/crews/crews_feature.gd"},
	{"id": "props", "slice": "integration", "path": "res://scripts/fp/props/props_feature.gd"},
	{
		"id": "actions", "slice": "integration",
		"path": "res://scripts/fp/actions/actions_feature.gd",
	},
	{
		"id": "reporter", "slice": "integration",
		"path": "res://scripts/fp/reporter/reporter_feature.gd",
	},
	{
		"id": "health", "slice": "integration",
		"path": "res://scripts/fp/health/health_feature.gd",
	},
	{
		"id": "parkour", "slice": "integration",
		"path": "res://scripts/fp/parkour/parkour_feature.gd",
	},
]
