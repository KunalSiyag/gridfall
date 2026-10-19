shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_schlick_ggx;
// Leaf cards at street level: hashed alpha (stable under TAA/FSR, no MSAA needed), normals bent out
// from the crown centre (so cards shade like a volume instead of flipping dark) and kept on both
// faces, soft translucency, a light wind sway, and the multimesh's per-tree tint (COLOR).

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0);
uniform vec3 translucency : source_color = vec3(0.30, 0.38, 0.12);
uniform float wind = 1.0;
uniform float wetness = 0.0;
// Pulls the normal toward world up: cards then shade like a canopy lit from above (used on the
// building models' hedges and shrubs, whose normals are not bent).
uniform float up_bias = 0.0;
// Bends normals away from crown_centre (mesh space) by this much; done here rather than in the
// mesh so the imported mesh keeps its automatic LODs.
uniform float bend = 0.0;
uniform vec3 crown_centre = vec3(0.0, 0.25, 0.0);
// A card turning edge-on smears its cluster into long slivers (the "torn paper" look): between
// these facings (|cos| of the view angle) the cluster shrinks toward the card centre, and below
// edge_lo the card is gone.
uniform float edge_lo = 0.1;
uniform float edge_hi = 0.5;
// The model exporter shifts every card's 0..1 UVs by one offset per material (core.py build), which
// cuts the round leaf cluster into quarters at the card corners; subtracting it recentres them.
uniform vec2 uv_offset = vec2(0.0);
// Leaves closer to the camera than near_fade.x are gone and fade in by near_fade.y (world units), so
// a camera backed into a crown sees through it; (0, 0) turns it off.
uniform vec2 near_fade = vec2(0.0);

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = max(VERTEX.y - 0.06, 0.0);
	float ph = TIME * 1.4 + wp.x * 9.0 + wp.z * 7.0;
	float sway = (sin(ph) * 0.6 + sin(ph * 2.3 + 1.7) * 0.4) * 0.012 * h * wind;
	if (bend > 0.0) {
		vec3 r = VERTEX - crown_centre;
		r.y *= 1.4;
		NORMAL = normalize(mix(NORMAL, normalize(r), bend));
	}
	VERTEX.x += sway;
	VERTEX.z += sway * 0.6;
}

void fragment() {
	vec2 cuv = UV - uv_offset;
	vec4 a = texture(albedo_tex, cuv) * tint;
	// Mip-averaged alpha thins distant crowns; push coverage back up as the footprint grows.
	vec2 ts = vec2(textureSize(albedo_tex, 0));
	vec2 dx = dFdx(cuv * ts);
	vec2 dy = dFdy(cuv * ts);
	float lod = max(0.5 * log2(max(dot(dx, dx), dot(dy, dy))), 0.0);
	ALBEDO = a.rgb * COLOR.rgb * mix(1.0, 0.72, wetness);
	vec3 face_n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	float keep = smoothstep(edge_lo, edge_hi, abs(dot(face_n, normalize(VERTEX))));
	float r = length(cuv - 0.5) * 2.0;
	float shrink = 1.0 - smoothstep(keep * 1.15 - 0.3, keep * 1.15, r);
	ALPHA = clamp(a.a * (1.0 + lod * 0.28), 0.0, 1.0) * shrink;
	if (near_fade.y > 0.0) {
		ALPHA *= smoothstep(near_fade.x, near_fade.y, length(VERTEX));
	}
	ALPHA_HASH_SCALE = 1.0;
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	if (up_bias > 0.0) {
		NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz, up_bias));
	}
	ROUGHNESS = mix(0.72, 0.35, wetness);
	SPECULAR = 0.35;
	BACKLIGHT = translucency;
}
