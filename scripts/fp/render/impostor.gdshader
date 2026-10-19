// Far building impostors (slice G2): stepped mass proxies merged per 8x8 chunk. A proxy shows only
// beyond `range` from its building's centre, the exact point the engine measures the real
// building's visibility_range_end from, so real and proxy never overlap or leave a gap. Facades get
// a filtered window grid sized by the building's glass share, on G1's 4 m x 3.2 m room cells, and
// the rooms G1's window shader lights are lit here too (same world-space hash).
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Squared switch distance (VIS_BUILDING * vis_mult)^2, world units.
uniform float range_sq = 225.0;
// CityView.night: 0 at noon, 1 at midnight.
uniform float night = 0.0;
uniform vec3 glass_tint : source_color = vec3(0.045, 0.06, 0.075);
uniform vec2 cell = vec2(0.2, 0.16);
const float WIN_H = 0.6;     // window height share of a storey

varying vec3 wpos;
varying vec3 wnrm;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	vec3 c = vec3(UV2.x, UV.y, UV2.y);
	vec3 d = c - CAMERA_POSITION_WORLD;
	if (dot(d, d) < range_sq) {
		VERTEX = vec3(0.0);
	}
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = NORMAL;
}

void fragment() {
	vec3 base = srgb_to_linear(COLOR.rgb);
	float wall = 1.0 - step(0.5, abs(wnrm.y));
	float share = clamp(UV.x, 0.0, 0.85);
	float wx = clamp(share / WIN_H, 0.0, 0.9);
	bool xface = abs(wnrm.x) > abs(wnrm.z);
	float along = xface ? wpos.z : wpos.x;
	float facade = floor((xface ? wpos.x : wpos.z) * 2.0) + (xface ? 0.5 : 0.0);
	vec2 g = vec2(along / cell.x, wpos.y / cell.y);
	vec2 fw = max(fwidth(g), vec2(1e-4));
	vec2 f = abs(fract(g) - 0.5);
	vec2 half_size = vec2(wx, WIN_H) * 0.5;
	vec2 box = clamp((half_size - f) / fw + 0.5, 0.0, 1.0);
	float m = box.x * box.y;
	// Under about two pixels per room the grid would shimmer: blend to its average.
	m = mix(m, wx * WIN_H, smoothstep(0.25, 0.6, max(fw.x, fw.y)));
	m *= wall * step(0.0001, share);
	vec2 id = floor(g);
	float r1 = hash13(vec3(id, facade));
	float r2 = hash13(vec3(id + 17.0, facade + 3.0));
	float r3 = hash13(vec3(id - 5.0, facade - 9.0));
	float lit = step(r1 * 0.97 + r3 * 0.03, mix(0.06, 0.6, night)) * step(r2, COLOR.a);
	vec3 lamp = mix(vec3(1.0, 0.74, 0.44), vec3(0.82, 0.9, 1.0), step(0.72, r2));
	ALBEDO = mix(base, mix(glass_tint, vec3(0.06), 0.55), m);
	ROUGHNESS = mix(0.88, 0.1, m);
	METALLIC = 0.2 * m;
	SPECULAR = mix(0.4, 0.6, m);
	EMISSION = lamp * lit * m * mix(0.25, 2.6, night) * 0.62;
}
