shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_schlick_ggx;
// Leaf cards at street level: hashed alpha (stable under TAA/FSR, no MSAA needed), the authored
// normals on both faces (StreetDressing bends them out from the crown, so cards shade like a
// volume instead of flipping dark), soft translucency and a light wind sway.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0);
uniform vec3 translucency : source_color = vec3(0.30, 0.38, 0.12);
uniform float wind = 1.0;
uniform float wetness = 0.0;
// Pulls the normal toward world up: cards then shade like a canopy lit from above (used on the
// building models' hedges and shrubs, whose normals are not bent).
uniform float up_bias = 0.0;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = max(VERTEX.y - 0.06, 0.0);
	float ph = TIME * 1.4 + wp.x * 9.0 + wp.z * 7.0;
	float sway = (sin(ph) * 0.6 + sin(ph * 2.3 + 1.7) * 0.4) * 0.012 * h * wind;
	VERTEX.x += sway;
	VERTEX.z += sway * 0.6;
}

void fragment() {
	vec4 a = texture(albedo_tex, UV) * tint;
	// Mip-averaged alpha thins distant crowns; push coverage back up as the footprint grows.
	vec2 ts = vec2(textureSize(albedo_tex, 0));
	vec2 dx = dFdx(UV * ts);
	vec2 dy = dFdy(UV * ts);
	float lod = max(0.5 * log2(max(dot(dx, dx), dot(dy, dy))), 0.0);
	ALBEDO = a.rgb * mix(1.0, 0.72, wetness);
	ALPHA = clamp(a.a * (1.0 + lod * 0.28), 0.0, 1.0);
	ALPHA_HASH_SCALE = 1.0;
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	if (up_bias > 0.0) {
		NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz, up_bias));
	}
	ROUGHNESS = mix(0.72, 0.35, wetness);
	SPECULAR = 0.35;
	BACKLIGHT = translucency;
}
