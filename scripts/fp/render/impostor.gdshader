// Far building impostors (slice G2): stepped mass proxies merged per 8x8 chunk. A proxy shows only
// beyond `range` from its building's centre, the exact point the engine measures the real
// building's visibility_range_end from, so real and proxy never overlap or leave a gap. Facades get
// a filtered window grid sized by the building's glass share; at night some windows light up.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Squared switch distance (VIS_BUILDING * vis_mult)^2, world units.
uniform float range_sq = 400.0;
// CityView.night: 0 at noon, 1 at midnight.
uniform float night = 0.0;
uniform vec3 glass : source_color = vec3(0.15, 0.19, 0.25);
uniform vec3 lamp : source_color = vec3(1.0, 0.8, 0.55);
uniform float lamp_energy = 2.6;

const float FLOOR_H = 0.16;   // 3.2 m storeys
const float BAY_W = 0.14;     // 2.8 m window bays
const float WIN_H = 0.55;     // window height share of a storey

varying vec3 v_world;
varying vec3 v_nrm;
varying flat float v_seed;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	vec3 c = vec3(UV2.x, UV.y, UV2.y);
	vec3 d = c - CAMERA_POSITION_WORLD;
	if (dot(d, d) < range_sq) {
		VERTEX = vec3(0.0);
	}
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_nrm = NORMAL;
	v_seed = hash(c.xz);
}

void fragment() {
	vec3 base = srgb_to_linear(COLOR.rgb);
	float wall = 1.0 - step(0.5, abs(v_nrm.y));
	float share = clamp(UV.x, 0.0, 0.9);
	float wx = clamp(share / WIN_H, 0.0, 0.9);
	float along = abs(v_nrm.x) > 0.5 ? v_world.z : v_world.x;
	vec2 g = vec2(along / BAY_W, (v_world.y - 0.01) / FLOOR_H);
	vec2 fw = max(fwidth(g), vec2(1e-4));
	vec2 f = abs(fract(g) - 0.5);
	vec2 half_size = vec2(wx, WIN_H) * 0.5;
	vec2 box = clamp((half_size - f) / fw + 0.5, 0.0, 1.0);
	float m = box.x * box.y;
	// Under about two pixels per bay the grid would shimmer: blend to its average.
	m = mix(m, wx * WIN_H, smoothstep(0.25, 0.6, max(fw.x, fw.y)));
	m *= wall * step(0.0001, share);
	ALBEDO = mix(base, srgb_to_linear(glass), m);
	ROUGHNESS = mix(0.88, 0.18, m);
	METALLIC = 0.25 * m;
	SPECULAR = 0.4;
	float glow = smoothstep(0.25, 0.85, night);
	vec2 cell = floor(g);
	float lit = step(hash(cell + v_seed * 97.0), COLOR.a);
	float tint = hash(cell.yx + v_seed * 31.0);
	EMISSION = srgb_to_linear(lamp) * mix(0.7, 1.15, tint) * lamp_energy * glow * lit * m;
}
