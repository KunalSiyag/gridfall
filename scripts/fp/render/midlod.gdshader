// Mid-range building LOD (slice G2): a building mesh merged into one surface, each former surface
// carrying its material's average colour (vertex colour, sRGB) and a kind in alpha: 0 opaque,
// 0.5 glass, 1 a window that lights up. Lit windows use G1's street-level window cells (4 m x
// 3.2 m rooms in world space, the same hash), so the same rooms are lit as on the real building.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// CityView.night: 0 at noon, 1 at midnight.
uniform float night = 0.0;
uniform vec3 glass_tint : source_color = vec3(0.045, 0.06, 0.075);
uniform vec2 cell = vec2(0.2, 0.16);

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
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float glass = step(0.25, COLOR.a);
	float window = step(0.75, COLOR.a);
	vec3 base = srgb_to_linear(COLOR.rgb);
	bool xface = abs(wnrm.x) > abs(wnrm.z);
	float along = xface ? wpos.z : wpos.x;
	float facade = floor((xface ? wpos.x : wpos.z) * 2.0) + (xface ? 0.5 : 0.0);
	vec2 id = floor(vec2(along / cell.x, wpos.y / cell.y));
	float r1 = hash13(vec3(id, facade));
	float r2 = hash13(vec3(id + 17.0, facade + 3.0));
	float r3 = hash13(vec3(id - 5.0, facade - 9.0));
	float lit = window * step(r1 * 0.97 + r3 * 0.03, mix(0.06, 0.6, night));
	vec3 lamp = mix(vec3(1.0, 0.74, 0.44), vec3(0.82, 0.9, 1.0), step(0.72, r2));
	// Glass as G1 dresses it on foot: dark, sky-reflecting, keeping a trace of the authored hue.
	vec3 curtain = srgb_to_linear(mix(vec3(0.045, 0.065, 0.08), COLOR.rgb * 0.35, 0.5));
	ALBEDO = mix(mix(base, curtain, glass), mix(glass_tint, vec3(0.06), 0.55), window);
	ROUGHNESS = mix(0.82, 0.1, glass);
	METALLIC = 0.2 * glass;
	SPECULAR = mix(0.45, 0.6, glass);
	EMISSION = lamp * lit * mix(0.25, 2.6, night) * 0.62;
}
