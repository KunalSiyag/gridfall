shader_type sky;
// Day HDRI -> sunset HDRI -> procedural starry night, driven by the city clock.

uniform sampler2D day_sky : filter_linear, repeat_enable, hint_default_black;
uniform sampler2D dusk_sky : filter_linear, repeat_enable, hint_default_black;
uniform float dusk : hint_range(0.0, 1.0) = 0.0;
uniform float night : hint_range(0.0, 1.0) = 0.0;
// The sunset panorama is several times brighter than the day one.
uniform float dusk_gain = 0.3;
uniform vec3 tint = vec3(1.0);
uniform float exposure = 1.0;
// Weather: 0 clear .. 1 overcast. A grey sky, brighter at the horizon, keeping a trace of the
// panorama's cloud structure; no sun disc, no stars.
uniform float grey : hint_range(0.0, 1.0) = 0.0;

float hash3(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

void sky() {
	// Clamped so the panoramas' sun discs cannot flood ambient light and reflections.
	vec3 d = min(texture(day_sky, SKY_COORDS).rgb, vec3(6.0)) * tint;
	vec3 s = min(texture(dusk_sky, SKY_COORDS).rgb * dusk_gain, vec3(2.5));
	vec3 col = mix(d, s, dusk);
	float up = clamp(EYEDIR.y, -1.0, 1.0);
	if (grey > 0.001) {
		float l = min(dot(col, vec3(0.2126, 0.7152, 0.0722)), 1.5);
		vec3 over = mix(vec3(0.66, 0.69, 0.73), vec3(0.44, 0.47, 0.52), smoothstep(0.0, 0.7, up)) * (0.75 + 0.3 * l);
		over *= mix(1.0, 0.35, dusk);
		col = mix(col, over, grey);
	}
	if (night > 0.001) {
		vec3 n = mix(vec3(0.020, 0.024, 0.040), vec3(0.003, 0.006, 0.018), smoothstep(0.0, 0.6, up));
		// Sodium glow of the city on the horizon (stronger under cloud).
		n += vec3(0.06, 0.035, 0.015) * pow(1.0 - abs(up), 8.0) * (1.0 + grey);
		float star = step(0.9982, hash3(floor(EYEDIR * 420.0))) * smoothstep(0.05, 0.35, up) * (1.0 - grey);
		n += vec3(0.9, 0.92, 1.0) * star * 1.5;
		col = mix(col, n, night);
	}
	COLOR = col * exposure;
}
