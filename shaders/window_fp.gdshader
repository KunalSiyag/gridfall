shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Street-level windows: dark reflective glass over a hint of the room behind it. The facade is cut
// into room cells in world space (4 m x 3.2 m); each cell picks a back-wall tone, curtains or
// blinds, and whether its lights are on (a few by day, most in the evening).

uniform float night = 0.0;
uniform vec3 glass_tint : source_color = vec3(0.045, 0.06, 0.075);
uniform vec2 cell = vec2(0.2, 0.16);

varying vec3 wpos;
varying vec3 wnrm;

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
	bool xface = abs(wnrm.x) > abs(wnrm.z);
	float along = xface ? wpos.z : wpos.x;
	float facade = floor((xface ? wpos.x : wpos.z) * 2.0) + (xface ? 0.5 : 0.0);
	vec2 rc = vec2(along / cell.x, wpos.y / cell.y);
	vec2 id = floor(rc);
	vec2 f = fract(rc);
	float r1 = hash13(vec3(id, facade));
	float r2 = hash13(vec3(id + 17.0, facade + 3.0));
	float r3 = hash13(vec3(id - 5.0, facade - 9.0));
	// The room: a dim back wall, sometimes curtains at the sides or blinds part-way down.
	vec3 wall = mix(vec3(0.05, 0.045, 0.04), vec3(0.16, 0.14, 0.12), r2);
	vec3 drape = mix(vec3(0.55, 0.5, 0.42), mix(vec3(0.5, 0.2, 0.16), vec3(0.24, 0.32, 0.46), step(0.5, r3)), step(0.7, r3));
	float curtains = step(0.5, r1) * (1.0 - smoothstep(0.16, 0.2, f.x) + smoothstep(0.8, 0.84, f.x));
	float blind_to = 1.0 - r3 * 0.7;
	float blinds = step(0.82, r2) * step(blind_to, f.y) * (0.75 + 0.25 * step(0.5, fract(wpos.y * 140.0)));
	vec3 room = mix(wall, drape * 0.45, clamp(curtains, 0.0, 1.0));
	room = mix(room, vec3(0.62, 0.6, 0.56) * 0.5, blinds);
	// Lights: about 6% of rooms by day, up to 60% at night; warm homes, a few cool offices.
	float lit = step(r1 * 0.97 + r3 * 0.03, mix(0.06, 0.6, night));
	vec3 lamp = mix(vec3(1.0, 0.74, 0.44), vec3(0.82, 0.9, 1.0), step(0.72, r2));
	float glow = lit * mix(0.25, 2.6, night) * (1.0 - 0.45 * clamp(curtains + blinds, 0.0, 1.0));
	ALBEDO = mix(glass_tint, room, 0.55);
	METALLIC = 0.1;
	ROUGHNESS = 0.07;
	SPECULAR = 0.62;
	EMISSION = lamp * glow * mix(room * 3.0 + 0.25, vec3(1.0), 0.5);
}
