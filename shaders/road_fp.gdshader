shader_type spatial;
// Carriageway asphalt at street level (slice G1). The road models tile one asphalt quad per tile
// with its own UV offset, so the texture broke at every tile edge and repeated every 4 m. Here it
// is mapped in world metres (continuous along the street) and broken up by a second rotated sample
// and two noise scales; then the wear real roads show: a darker oil streak down each lane, polished
// wheel tracks either side of it, grit and dust in the gutters, older greyer stretches, and in rain
// water standing in the tracks and gutters. lane_axis (per instance) says where the lanes run:
// 0 none (junctions), 1 along z, 2 along x, 3-6 round the tile corner +x+z, -x+z, -x-z, +x-z.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
// A tiling, equalised fbm (textures/real/decals/noise_fbm.png).
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 tint : source_color = vec4(0.80, 0.80, 0.81, 1.0);
uniform float metre = 0.05;
uniform float repeat_m = 4.0;
uniform float lane_offset = 0.15;
uniform float half_width = 0.3;
uniform float wetness = 0.0;
instance uniform float lane_axis = 0.0;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// World-aligned tangent frame to match the world-space UVs below.
	mat3 inv = inverse(mat3(MODEL_MATRIX));
	TANGENT = normalize(inv * vec3(1.0, 0.0, 0.0));
	BINORMAL = normalize(inv * vec3(0.0, 0.0, 1.0));
}

// Distance across the carriageway from its centreline (tile units), or -1 with no lanes.
float across_of(vec2 local) {
	int a = int(lane_axis + 0.5);
	if (a == 1) {
		return abs(local.x);
	}
	if (a == 2) {
		return abs(local.y);
	}
	if (a >= 3 && a <= 6) {
		vec2 c = a == 3 ? vec2(0.5, 0.5) : (a == 4 ? vec2(-0.5, 0.5) : (a == 5 ? vec2(-0.5, -0.5) : vec2(0.5, -0.5)));
		return abs(length(local - c) - 0.5);
	}
	return -1.0;
}

void fragment() {
	vec2 m = wpos.xz / metre;
	vec2 uv1 = m / repeat_m;
	vec2 uv2 = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * uv1 * 0.73 + vec2(0.37, 0.11);
	float n_big = texture(noise_tex, m / 47.0).r;
	float n_mid = texture(noise_tex, m / 11.0 + vec2(0.5, 0.3)).r;
	float n_fine = texture(noise_tex, m / 2.3 + vec2(0.2, 0.7)).r;
	float pick = smoothstep(0.3, 0.7, n_mid);
	vec3 alb = mix(texture(albedo_tex, uv1).rgb, texture(albedo_tex, uv2).rgb, pick);
	vec3 nrm = mix(texture(normal_tex, uv1).rgb, texture(normal_tex, uv2).rgb, pick);
	float rough = mix(texture(rough_tex, uv1).r, texture(rough_tex, uv2).r, pick);
	alb *= tint.rgb;
	// The scanned asphalt is brown; city asphalt reads a neutral grey.
	alb = mix(alb, vec3(dot(alb, vec3(0.3333))), 0.45);
	// Older, sun-bleached stretches are lighter and greyer; patched ones darker.
	float age = smoothstep(0.25, 0.75, n_big);
	alb *= mix(0.86, 1.1, age);
	alb = mix(alb, vec3(dot(alb, vec3(0.3333))), age * 0.35);
	alb *= 0.94 + 0.12 * n_fine;
	vec2 local = wpos.xz - round(wpos.xz);
	float d = across_of(local);
	float oil = 0.0;
	float track = 0.0;
	float gutter = 0.0;
	if (d >= 0.0) {
		float lane = abs(d - lane_offset);
		oil = (1.0 - smoothstep(0.004, 0.014, lane)) * (0.55 + 0.9 * n_fine * n_mid);
		float t = abs(lane - 0.042);
		track = 1.0 - smoothstep(0.005, 0.015, t);
		gutter = smoothstep(half_width - 0.035, half_width - 0.006, d);
	}
	// Tyres darken their tracks with rubber and keep them free of dust; drips darken the lane centre;
	// dust and grit settle between the lanes and along the gutters.
	float between = d >= 0.0 ? 1.0 - smoothstep(0.02, 0.05, d) : 0.0;
	alb *= 1.0 - 0.3 * clamp(oil, 0.0, 1.0);
	alb *= 1.0 - 0.13 * track * (0.7 + 0.6 * n_mid);
	alb *= 1.0 + 0.08 * between;
	alb = mix(alb, vec3(0.34, 0.32, 0.29), gutter * (0.35 + 0.35 * n_mid));
	// Dry: matte with polished tracks. Wet: darker and glossy, water standing in the tracks and
	// gutters where the noise says the surface dips.
	rough = mix(0.8, 0.95, rough) - 0.12 * track;
	float pool = wetness * smoothstep(0.5, 0.7, max(track * n_mid, gutter * n_big) + n_fine * 0.25);
	alb *= mix(1.0, 0.6, wetness);
	alb *= 1.0 - 0.25 * pool;
	ALBEDO = alb;
	ROUGHNESS = mix(rough, 0.22, wetness * 0.8);
	ROUGHNESS = mix(ROUGHNESS, 0.03, pool);
	SPECULAR = mix(0.35, 0.6, wetness);
	NORMAL_MAP = mix(nrm, vec3(0.5, 0.5, 1.0), pool * 0.9);
	NORMAL_MAP_DEPTH = 1.0;
}
