shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_schlick_ggx;
// Knitted scaffold debris netting at street level: a fine diamond weave, mostly opaque, hanging in
// soft vertical folds, with sewn seams between the 2.5 m sheets, tie lines at every 2 m lift and
// dust toward the ground. World-space, in metres; the weave fades to its mean cover once its cells
// are smaller than a pixel, so it never shimmers.

uniform vec4 colour : source_color = vec4(0.17, 0.33, 0.23, 1.0);
// World units per metre (WS.M).
uniform float metre = 0.05;
// Cover of the weave (0 clear .. 1 solid).
uniform float cover = 0.8;

float hash1(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

void fragment() {
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz / metre;
	vec3 wn = abs((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float u = wn.x > wn.z ? wp.z : wp.x;
	float v = wp.y;
	vec2 cell = vec2(u + v, u - v) / 0.014;
	vec2 f = abs(fract(cell) - 0.5);
	float thread = smoothstep(0.28, 0.40, max(f.x, f.y));
	float blur = clamp(length(fwidth(cell)) * 0.8, 0.0, 1.0);
	float weave = mix(mix(cover * 0.8, 1.0, thread), cover, blur);
	// Each sheet sags between its ties: folds a few tens of centimetres apart, varying per sheet.
	float sheet = floor(u / 2.5);
	float fold = sin(u * (9.0 + 4.0 * hash1(sheet)) + sin(v * 0.7 + sheet) * 1.5) * 0.5 + 0.5;
	float seam = 1.0 - smoothstep(0.02, 0.05, abs(fract(u / 2.5 + 0.5) - 0.5) * 2.5);
	float tie = 1.0 - smoothstep(0.015, 0.03, abs(fract(v / 2.0 + 0.5) - 0.5) * 2.0);
	float dust = clamp(1.0 - v / 6.0, 0.0, 1.0);
	vec3 c = colour.rgb * (0.82 + 0.3 * fold) * (1.0 - 0.15 * seam) * (1.0 - 0.12 * tie);
	c *= 0.9 + 0.2 * hash1(sheet + 17.0);
	c = mix(c, vec3(0.30, 0.27, 0.22), dust * 0.3);
	ALBEDO = c;
	ALPHA = clamp(max(weave, seam), 0.0, 1.0);
	ROUGHNESS = 0.9;
	SPECULAR = 0.15;
	BACKLIGHT = c * 0.5;
}
