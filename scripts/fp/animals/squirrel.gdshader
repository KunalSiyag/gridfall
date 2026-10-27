shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// The squirrels (scripts/fp/animals/squirrel_body.gd builds the mesh in metres, facing +Z with
// the feet at the origin, and sets the pivots below from its constants). Each animal's
// INSTANCE_CUSTOM: x the legs' stride angle (rad) — the front pair and the hind pair swing in
// antiphase, the gallop, and the body bobs with them; y the sit-up share 0..1 — the front of the
// body rotates up about the hips into the sitting-up pose, the head pitching up further with it,
// the front paws riding along and the hind feet staying planted; z the tail's sway angle (rad),
// about the tail's root and bending more along its length; w the run's forward lean (rad),
// pitching the whole body about the hips and laying the ears back. UV2.x tags what moves (its
// sign the side: 1 the tail (midline), +-2 the legs, 3 the head and neck, +-4 the ears) and
// UV2.y is the share of that motion the vertex takes: the tail's 0 at its root and 1 at its tip,
// the body's sit-up share ramping up its length, 1 on the head, the ears and the front legs, 0
// on the hind legs (a leg is front or hind by which of the two leg pivots it stands nearer).
// UV.x is the part (0 plumage: the vertex colour times the animal's instance colour; 1 the
// eye, 2 the nose and the paws, 3 the ear tufts).

uniform vec3 hip = vec3(0.0, 0.05, -0.012);
uniform vec3 neck = vec3(0.0, 0.07, 0.092);
uniform vec3 rump = vec3(0.0, 0.058, -0.064);
uniform vec3 shoulder = vec3(0.009, 0.048, 0.068);
uniform vec3 thigh = vec3(0.015, 0.052, -0.016);
uniform vec3 ear_base = vec3(0.0085, 0.105, 0.101);
// The sit-up's angle at full share and the head's extra pitch with it (rad); how far the ears
// lay back with the run's lean (rad); the gait's body bob (m).
uniform float sit_rad = 1.0;
uniform float head_pitch = 0.45;
uniform float ear_lay = 0.8;
uniform float bob_m = 0.004;
uniform vec3 eye_col : source_color = vec3(0.03, 0.025, 0.02);
uniform vec3 paw_col : source_color = vec3(0.16, 0.12, 0.1);
uniform vec3 tuft_col : source_color = vec3(0.88, 0.85, 0.78);

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

void vertex() {
	vec4 pose = INSTANCE_CUSTOM;
	float sit = clamp(pose.y, 0.0, 1.0);
	float tag = UV2.x;
	float side = tag < 0.0 ? -1.0 : 1.0;
	float kind = abs(tag);
	float w = UV2.y;
	if (kind > 1.5 && kind < 2.5) {
		// Legs: the front pair and the hind pair stride in antiphase (the gallop), each about
		// the pivot nearer it — the z halfway between the two pivots splits front from hind.
		float front = VERTEX.z > (shoulder.z + thigh.z) * 0.5 ? 1.0 : -1.0;
		vec3 piv = front > 0.0 ? shoulder : thigh;
		piv = vec3(piv.x * side, piv.y, piv.z);
		mat3 r = rot_x(pose.x * front);
		VERTEX = piv + r * (VERTEX - piv);
		NORMAL = r * NORMAL;
	} else if (kind > 0.5 && kind < 1.5) {
		// The tail sways about its root, bending more along its length (its share).
		mat3 r = rot_y(pose.z * w);
		VERTEX = rump + r * (VERTEX - rump);
		NORMAL = r * NORMAL;
	} else if (kind > 3.5) {
		// The ears lay back with the run's lean, about their bases.
		vec3 piv = vec3(ear_base.x * side, ear_base.y, ear_base.z);
		mat3 r = rot_x(pose.w * ear_lay);
		VERTEX = piv + r * (VERTEX - piv);
		NORMAL = r * NORMAL;
	}
	if (w > 0.0 && (kind < 0.5 || kind > 1.5)) {
		// The sit-up: everything but the tail rotates up about the hips by its share — the
		// hind legs hold share 0 and stay planted.
		mat3 r = rot_x(-sit_rad * sit * w);
		VERTEX = hip + r * (VERTEX - hip);
		NORMAL = r * NORMAL;
	}
	if (kind > 2.5) {
		// The head, the neck and the ears pitch up further about the neck as the body sits.
		mat3 full = rot_x(-sit_rad * sit);
		vec3 piv = hip + full * (neck - hip);
		mat3 r = rot_x(-head_pitch * sit * w);
		VERTEX = piv + r * (VERTEX - piv);
		NORMAL = r * NORMAL;
	}
	// The run's lean pitches the whole body about the hips, and the gait bobs the body along
	// with the stride — eased off while sitting up, so the hind feet stay on the ground.
	mat3 lean = rot_x(pose.w);
	VERTEX = hip + lean * (VERTEX - hip);
	NORMAL = lean * NORMAL;
	VERTEX.y += bob_m * sin(pose.x) * (1.0 - sit);
}

void fragment() {
	int part = int(UV.x + 0.5);
	vec3 col = COLOR.rgb;
	float rough = 0.85;
	if (part == 1) {
		col = eye_col;
		rough = 0.15;
	} else if (part == 2) {
		col = paw_col;
		rough = 0.5;
	} else if (part == 3) {
		col = tuft_col;
		rough = 0.8;
	}
	ALBEDO = min(col, vec3(0.95));
	ROUGHNESS = rough;
	SPECULAR = 0.35;
}
