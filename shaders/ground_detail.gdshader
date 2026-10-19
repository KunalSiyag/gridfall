shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
// Metric ground for street level. Grass (or a dirt mix on vacant lots) at one repeat per 3 m with no
// visible tiling: each region of the plane samples the texture at its own random offset and the
// regions blend across a noise field (Quilez, "texture repetition", technique 3). A 40 m macro layer
// varies the colour and wears in dirt patches, so open land stops reading as a golf course.

uniform sampler2D grass_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_rough : hint_roughness_g, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// Repeats per world unit (1 u = 20 m): 1 per 3 m for detail, 1 per 40 m for the macro layer.
uniform float detail_scale = 6.6667;
uniform float macro_scale = 0.5;
// 0 lawn .. 1 bare earth; lot_edge > 0 fades the earth back to grass toward the quad's UV edges.
uniform float dirt = 0.0;
uniform float lot_edge = 0.0;
uniform vec3 grass_tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float normal_strength = 0.7;
uniform float wetness = 0.0;

varying vec3 wpos;
varying vec2 luv;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	return vnoise(p) * 0.55 + vnoise(p * 2.07 + 13.1) * 0.3 + vnoise(p * 4.13 + 7.7) * 0.15;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	luv = UV;
}

void fragment() {
	vec2 p = wpos.xz * detail_scale;
	vec2 dx = dFdx(p);
	vec2 dy = dFdy(p);
	// Index field: about one change every 4 repeats; two neighbouring offsets blended.
	float l = vnoise(p * 0.23) * 8.0;
	float ia = floor(l);
	float f = fract(l);
	vec2 oa = sin(vec2(3.0, 7.0) * ia);
	vec2 ob = sin(vec2(3.0, 7.0) * (ia + 1.0));
	vec3 ga = textureGrad(grass_albedo, p + oa, dx, dy).rgb;
	vec3 gb = textureGrad(grass_albedo, p + ob, dx, dy).rgb;
	float w = smoothstep(0.2, 0.8, f - 0.1 * dot(ga - gb, vec3(1.0)));
	vec3 g = mix(ga, gb, w);
	vec3 gn = mix(textureGrad(grass_normal, p + oa, dx, dy).rgb, textureGrad(grass_normal, p + ob, dx, dy).rgb, w);
	float gr = mix(textureGrad(grass_rough, p + oa, dx, dy).g, textureGrad(grass_rough, p + ob, dx, dy).g, w);
	// Dirt at the same scale, rotated so its features do not line up with the grass.
	vec2 q = vec2(p.y, -p.x) * 0.8;
	vec2 qdx = vec2(dx.y, -dx.x) * 0.8;
	vec2 qdy = vec2(dy.y, -dy.x) * 0.8;
	vec3 da = mix(textureGrad(dirt_albedo, q + oa, qdx, qdy).rgb, textureGrad(dirt_albedo, q + ob, qdx, qdy).rgb, w);
	vec3 dn = mix(textureGrad(dirt_normal, q + oa, qdx, qdy).rgb, textureGrad(dirt_normal, q + ob, qdx, qdy).rgb, w);
	// Macro layer: lush and dry patches at 40 m, worn spots at 10 m.
	vec2 mp = wpos.xz * macro_scale;
	float m1 = fbm(mp);
	float m2 = fbm(mp * 4.0 + 5.3);
	g *= grass_tint * mix(vec3(0.80, 0.86, 0.74), vec3(1.10, 1.06, 0.86), smoothstep(0.25, 0.75, m1));
	g *= 0.9 + 0.2 * m2;
	float worn = smoothstep(0.66, 0.86, m2 * 0.65 + m1 * 0.35) * 0.55;
	float earth = worn;
	if (dirt > 0.0) {
		float patchy = clamp(dirt + (fbm(p * 0.35 + 3.1) - 0.5) * 1.1, 0.0, 1.0);
		if (lot_edge > 0.0) {
			float e = min(min(luv.x, 1.0 - luv.x), min(luv.y, 1.0 - luv.y));
			patchy *= smoothstep(0.0, 0.09, e);
		}
		earth = max(earth, patchy);
	}
	earth = clamp(earth + (gn.g - 0.5) * 0.3 * earth, 0.0, 1.0);
	vec3 alb = mix(g, da * vec3(0.95, 0.9, 0.85), earth);
	vec3 nrm = mix(gn, dn, earth);
	float rough = mix(gr, 0.95, earth);
	// Rain: darker, with a satin sheen on bare earth (grass blades stay fairly matte).
	alb *= mix(1.0, mix(0.72, 0.55, earth), wetness);
	rough = mix(rough, mix(0.55, 0.25, earth), wetness);
	ALBEDO = alb;
	NORMAL_MAP = nrm;
	NORMAL_MAP_DEPTH = normal_strength;
	ROUGHNESS = rough;
	SPECULAR = 0.35;
}
