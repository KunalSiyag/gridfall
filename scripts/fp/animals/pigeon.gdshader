shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;
// The pigeons (scripts/fp/animals/pigeon_body.gd builds the mesh in metres, facing +Z with the feet
// at the origin, and sets the pivots below from its constants). Each bird's INSTANCE_CUSTOM: x the
// wings' angle above level (rad) in the air, the legs' stride angle (rad) on the ground; y how far
// the wings are spread (0 folded on the flanks, 1 spread); z how far it leans in to peck (0..1); w
// the head's bob along the body (-1 back .. 1 forward, in bob_m). UV2.x tags what moves by side
// (+-1 the spread wings, +-2 the folded ones, +-3 the legs, 4 the tail) and UV2.y is the share of
// the head's motion a vertex takes. UV.x is the part (0 plumage: the vertex colour times the
// bird's instance colour, its morph; 1 beak, 2 cere, 3 eye, 4 feet, 5 the iridescent neck) and
// UV.y marks the spread wings, white underneath.

uniform vec3 shoulder = vec3(0.03, 0.134, 0.035);
uniform vec3 hip = vec3(0.0, 0.067, 0.0);
uniform vec3 neck = vec3(0.0, 0.124, 0.06);
// How far a folded wing is swept back (rad); a peck's head dip (rad), neck stretch (m) and the
// body's lean forward about the hip (rad); the bob (m); the legs tucked back in flight (rad); the
// tail's fan with the wings spread (share of its width).
uniform float fold_sweep = 1.45;
uniform float peck_dip = 1.1;
uniform float peck_drop = 0.045;
uniform float peck_tilt = 0.35;
uniform float bob_m = 0.026;
uniform float leg_tuck = 1.2;
uniform float tail_fan = 1.1;
uniform vec3 beak_col : source_color = vec3(0.16, 0.15, 0.15);
uniform vec3 cere_col : source_color = vec3(0.86, 0.85, 0.82);
uniform vec3 eye_col : source_color = vec3(0.93, 0.42, 0.1);
uniform vec3 feet_col : source_color = vec3(0.78, 0.33, 0.36);
// The neck's sheen tints its plumage green face-on and purple toward the edges.
uniform vec3 neck_green = vec3(0.55, 1.5, 0.95);
uniform vec3 neck_purple = vec3(1.35, 0.7, 1.45);
uniform vec3 underwing : source_color = vec3(0.86, 0.87, 0.89);

mat3 rot_x(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, c, s), vec3(0.0, -s, c));
}

mat3 rot_y(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat3(vec3(c, 0.0, -s), vec3(0.0, 1.0, 0.0), vec3(s, 0.0, c));
}

mat3 rot_z(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat3(vec3(c, s, 0.0), vec3(-s, c, 0.0), vec3(0.0, 0.0, 1.0));
}

void vertex() {
	vec4 pose = INSTANCE_CUSTOM;
	float open = clamp(pose.y, 0.0, 1.0);
	float tag = UV2.x;
	float side = tag < 0.0 ? -1.0 : 1.0;
	float kind = abs(tag);
	vec3 piv = vec3(shoulder.x * side, shoulder.y, shoulder.z);
	if (kind > 0.5 && kind < 1.5) {
		// Spread wing: swept back as it closes and grown out of the shoulder as it opens, then
		// raised or lowered about the body's long axis.
		mat3 r = rot_z(side * pose.x) * rot_y(side * (1.0 - open) * fold_sweep);
		VERTEX = piv + r * ((VERTEX - piv) * smoothstep(0.0, 0.6, open));
		NORMAL = r * NORMAL;
	} else if (kind > 1.5 && kind < 2.5) {
		// Folded wing on the flank: drawn in toward the shoulder as the wing spreads.
		VERTEX = piv + (VERTEX - piv) * (1.0 - smoothstep(0.2, 0.7, open));
	} else if (kind > 2.5 && kind < 3.5) {
		// Legs: striding on the ground, tucked back and up in flight.
		float swing = side * pose.x * (1.0 - smoothstep(0.0, 0.15, open));
		mat3 r = rot_x(swing + leg_tuck * open);
		VERTEX = hip + r * (VERTEX - hip) * (1.0 - 0.45 * open);
		NORMAL = r * NORMAL;
	} else if (kind > 3.5) {
		VERTEX.x *= 1.0 + tail_fan * open;
	}
	float w = UV2.y;
	if (w > 0.0) {
		mat3 r = rot_x(pose.z * peck_dip * w);
		vec3 move = vec3(0.0, -peck_drop * pose.z, pose.w * bob_m) * w;
		VERTEX = neck + r * (VERTEX - neck) + move;
		NORMAL = r * NORMAL;
	}
	if (kind < 2.5 || kind > 3.5) {
		// Leaning in to peck: everything but the legs tips forward about the hip.
		mat3 r = rot_x(pose.z * peck_tilt);
		VERTEX = hip + r * (VERTEX - hip);
		NORMAL = r * NORMAL;
	}
}

void fragment() {
	int part = int(UV.x + 0.5);
	vec3 col = COLOR.rgb;
	float rough = 0.85;
	if (part == 1) {
		col = beak_col;
		rough = 0.5;
	} else if (part == 2) {
		col = cere_col;
	} else if (part == 3) {
		col = eye_col;
		rough = 0.25;
	} else if (part == 4) {
		col = feet_col;
		rough = 0.6;
	} else if (part == 5) {
		float edge = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
		col *= mix(neck_green, neck_purple, smoothstep(0.2, 0.75, edge));
		rough = 0.4;
	} else if (UV.y > 0.5 && !FRONT_FACING) {
		col = mix(col, underwing, 0.6);
	}
	ALBEDO = min(col, vec3(0.95));
	ROUGHNESS = rough;
	SPECULAR = 0.35;
}
