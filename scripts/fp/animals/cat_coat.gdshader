shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// The cats' coats (scripts/fp/animals/cat_bodies.gd puts this on every cat; tools/blender/make_cat.py
// writes the fields). UV is the rest pose's (forward, up) and UV2 its (left, distance along the
// tail, 0 off it), in model units, so the markings ride the skin as it moves. COLOR.r is the order
// white spreads in (0 the paws and the chest first, 1 the tail last), COLOR.g a smooth noise for
// patches and COLOR.b 1 on the nose and inside the ears. Each cat's coat: base (its ground colour),
// stripe (a tabby's stripes), patch_col (a calico's or a tortie's second colour) and look: x how
// strong the stripes are, y how far the white spreads (0 none, 1.2 all over), z how much of the
// coat is patched, w the eyes from green (0) to amber (1). One shared material per coat
// (cat_bodies.material_for): instance uniforms would take Compatibility's 4096-slot buffer.

uniform vec3 base : source_color = vec3(0.43, 0.32, 0.21);
uniform vec3 stripe : source_color = vec3(0.09, 0.07, 0.05);
uniform vec3 patch_col : source_color = vec3(0.0);
uniform vec4 look = vec4(1.0, 0.0, 0.0, 0.7);
uniform vec3 white_col : source_color = vec3(0.9, 0.89, 0.86);
uniform vec3 pink_col : source_color = vec3(0.8, 0.52, 0.52);
uniform vec3 eye_green : source_color = vec3(0.48, 0.66, 0.22);
uniform vec3 eye_amber : source_color = vec3(0.86, 0.6, 0.16);
// The eyes: centre (left either way, up) and radius in model units, the slit's half width as a
// share of the radius; the face is the skin further forward than face_fwd.
uniform vec2 eye_at = vec2(0.2, 2.9);
uniform float eye_r = 0.1;
uniform float slit = 0.22;
uniform float face_fwd = 2.6;
// A tabby's stripes: one every stripe_u model units along the body (closer on the legs, the tail
// and the face), and the dark line down the spine.
uniform float stripe_u = 0.42;
uniform float legs_up = 1.3;

void fragment() {
	float fwd = UV.x;
	float up = UV.y;
	float side = abs(UV2.x);
	float tail = UV2.y;
	vec3 col = base;
	float patched = smoothstep(1.0 - look.z - 0.03, 1.0 - look.z + 0.03, COLOR.g);
	col = mix(col, patch_col, look.z > 0.0 ? patched : 0.0);
	// Stripes: rings round the tail and the legs, lines down the flanks slanting back, fine lines
	// up the face.
	float ph = (fwd + 0.35 * up + 0.8 * (COLOR.g - 0.5)) / stripe_u;
	if (tail > 0.01) {
		ph = tail / (stripe_u * 0.9);
	} else if (up < legs_up) {
		ph = up / (stripe_u * 0.6);
	} else if (fwd > face_fwd - 0.4) {
		ph = (up + 0.6 * side) / (stripe_u * 0.45);
	}
	float w = fwidth(ph);
	float band = smoothstep(0.55 - w, 0.55 + w, 0.5 + 0.5 * cos(ph * TAU));
	band = mix(band, 0.4, clamp(w * 2.0 - 0.4, 0.0, 1.0));
	float spine = (1.0 - smoothstep(0.08, 0.3, side)) * smoothstep(2.1, 2.5, up);
	spine *= step(tail, 0.01) * step(fwd, face_fwd - 0.4);
	col = mix(col, stripe, look.x * max(band, spine));
	float white = 1.0 - smoothstep(look.y - 0.04, look.y + 0.04, COLOR.r);
	col = mix(col, white_col, white);
	float lum = dot(col, vec3(0.3, 0.55, 0.15));
	col = mix(col, mix(col * 0.7, pink_col, clamp(lum * 1.8, 0.2, 1.0)), step(0.5, COLOR.b));
	float rough = 0.82;
	float spec = 0.3;
	float d = length(vec2(side, up) - eye_at);
	if (fwd > face_fwd && d < eye_r) {
		vec3 iris = mix(eye_green, eye_amber, look.w);
		float pupil = step(abs(side - eye_at.x), eye_r * slit) * step(abs(up - eye_at.y), eye_r * 0.85);
		col = mix(iris, vec3(0.02), max(pupil, smoothstep(eye_r * 0.82, eye_r * 0.95, d)));
		rough = 0.08;
		spec = 0.6;
	} else {
		RIM = 0.35;
		RIM_TINT = 0.6;
	}
	ALBEDO = min(col, vec3(0.95));
	ROUGHNESS = rough;
	SPECULAR = spec;
}
