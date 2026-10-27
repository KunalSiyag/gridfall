shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;
// The ducks (scripts/fp/animals/duck_body.gd builds the mesh in metres, facing +Z with the soles
// at the origin, and sets the pivots below from its constants). A mallard, one mesh for both
// sexes: the vertex colours carry the DRAKE (a grey flank, a chestnut breast, a white neck ring, a
// green head, an olive bill) and the fragment mixes them toward the hen's mottled browns. Each
// duck's INSTANCE_CUSTOM:
//   x the wings' beat angle above level (rad), read only while y has them spread;
//   y how far the pair is spread (0 folded on the flanks, 1 out);
//   z how far it dabs (0..1: the neck and head pitch forward and down, at 1 the bill is under);
//   w the drake share (0 the hen's palette, 1 the drake's), carried on to the fragment.
// UV2.x tags what moves by side (+-1 the spread wings, +-2 the folded ones, 3 the neck and head,
// 4 the feet, which a dab holds still at the waterline) and UV2.y is the share of the head's
// motion a vertex takes. UV.x is the part (0 plumage: the vertex colour times the duck's instance
// colour, 1 the bill, 2 the eye, 3 the speculum patch, 4 the feet) and UV.y the plumage region for
// part 0 (0 the body, 1 the neck, 2 the head, 3 the folded wing, 4 the spread wing, drawn pale
// underneath) or the share across the speculum patch for part 3 (0 its white edge, 1 its middle).

uniform vec3 shoulder = vec3(0.05, 0.012, 0.045);
uniform vec3 hip = vec3(0.0, -0.01, 0.0);
uniform vec3 neck = vec3(0.0, 0.0, 0.098);
// How far a closed wing is swept back (rad); a dab's head dip (rad), its drop (m) and reach
// forward (m), and how far the body tips forward about the hip (rad).
uniform float fold_sweep = 1.35;
uniform float dab_dip = 0.7;
uniform float dab_drop = 0.012;
uniform float dab_reach = 0.012;
uniform float dab_tilt = 0.1;
uniform vec3 drake_bill : source_color = vec3(0.78, 0.72, 0.28);
uniform vec3 hen_bill : source_color = vec3(0.72, 0.42, 0.16);
uniform vec3 eye_col : source_color = vec3(0.05, 0.04, 0.03);
uniform vec3 feet_col : source_color = vec3(0.85, 0.45, 0.12);
uniform vec3 spec_blue : source_color = vec3(0.1, 0.18, 0.5);
uniform vec3 spec_hen : source_color = vec3(0.12, 0.16, 0.32);
uniform vec3 spec_white : source_color = vec3(0.92, 0.92, 0.9);
uniform vec3 underwing : source_color = vec3(0.8, 0.79, 0.75);
uniform vec3 hen_dark : source_color = vec3(0.25, 0.18, 0.12);
uniform vec3 hen_pale : source_color = vec3(0.62, 0.52, 0.38);
uniform vec3 hen_buff : source_color = vec3(0.58, 0.44, 0.3);
uniform vec3 hen_wing : source_color = vec3(0.55, 0.48, 0.38);

// The duck's drake share, carried from the vertex stage.
varying float drake_share;

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
	drake_share = clamp(pose.w, 0.0, 1.0);
	float open = clamp(pose.y, 0.0, 1.0);
	float tag = UV2.x;
	float side = tag < 0.0 ? -1.0 : 1.0;
	float kind = abs(tag);
	vec3 piv = vec3(shoulder.x * side, shoulder.y, shoulder.z);
	if (kind > 0.5 && kind < 1.5) {
		// The spread wing: drawn in and swept back at the shoulder as it closes, then raised or
		// lowered about the body's long axis by the beat.
		mat3 r = rot_z(side * pose.x) * rot_y(side * (1.0 - open) * fold_sweep);
		VERTEX = piv + r * ((VERTEX - piv) * smoothstep(0.0, 0.6, open));
		NORMAL = r * NORMAL;
	} else if (kind > 1.5 && kind < 2.5) {
		// The folded wing on the flank: drawn in toward the shoulder as the pair spreads.
		VERTEX = piv + (VERTEX - piv) * (1.0 - smoothstep(0.2, 0.7, open));
	} else if (kind > 2.5 && kind < 3.5) {
		// The neck and head dabbling: pitched forward and down about the neck by UV2.y's share of
		// the motion, 0 at the neck's base and 1 at the bill.
		float w = UV2.y;
		mat3 r = rot_x(pose.z * dab_dip * w);
		VERTEX = neck + r * (VERTEX - neck) + vec3(0.0, -dab_drop, dab_reach) * pose.z * w;
		NORMAL = r * NORMAL;
	}
	if (kind < 3.5) {
		// Dabbling tips the whole bird but its feet, which stay at the waterline, forward about the
		// hip.
		mat3 r = rot_x(pose.z * dab_tilt);
		VERTEX = hip + r * (VERTEX - hip);
		NORMAL = r * NORMAL;
	}
}

// The hen's plumage: the drake's vertex colours read as a mottled brown, region by region, so the
// patches the drake carries (a dark crown, a pale flank) come out as a hen's barring.
vec3 hen_plumage(vec3 drake, float region) {
	float lum = dot(drake, vec3(0.3, 0.55, 0.15));
	vec3 col = mix(hen_dark, hen_pale, smoothstep(0.12, 0.72, lum));
	if (region > 0.5 && region < 1.5) {
		col = mix(col, hen_buff, 0.55);
	} else if (region > 1.5 && region < 2.5) {
		col = mix(col, hen_buff, 0.4);
	} else if (region > 2.5 && region < 3.5) {
		col = mix(col, hen_wing, 0.3);
	}
	float n = fract(sin(dot(drake, vec3(97.1, 41.7, 13.3))) * 437.585);
	return mix(col, hen_dark, 0.3 * n);
}

void fragment() {
	int part = int(UV.x + 0.5);
	vec3 col = COLOR.rgb;
	float rough = 0.85;
	if (part == 1) {
		// The bill: the drake's olive-yellow, the hen's orange-brown.
		col = mix(hen_bill, drake_bill, drake_share);
		rough = 0.45;
	} else if (part == 2) {
		col = eye_col;
		rough = 0.2;
	} else if (part == 3) {
		// The speculum: a blue patch with a white edge, duller on the hen.
		col = mix(spec_white, mix(spec_hen, spec_blue, drake_share), smoothstep(0.1, 0.5, UV.y));
		rough = 0.4;
	} else if (part == 4) {
		col = feet_col;
		rough = 0.55;
	} else {
		col = mix(hen_plumage(COLOR.rgb, UV.y), COLOR.rgb, drake_share);
		if (UV.y > 3.5 && !FRONT_FACING) {
			col = mix(col, underwing, 0.6);
		}
	}
	ALBEDO = min(col, vec3(0.95));
	ROUGHNESS = rough;
	SPECULAR = 0.35;
}
