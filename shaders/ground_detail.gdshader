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
// Unpaved road tiles (CityView.track_material_for): the tile's road mask and grade come from one
// shared material per (mask, grade); the carriageway shape mirrors RoadTopology.is_carriageway.
// cut_grass discards everything but the track itself (orbit view, where the ground under it is
// not this shader). No instance uniforms here: on Compatibility every mesh drawn with a shader
// that declares one takes a slot of a 4096-slot buffer, set or not, and a grown city's ground,
// lawns and site parts overflow it (the engine then crashes).
uniform bool track = false;
uniform bool cut_grass = false;
uniform float road_half = 0.3;
uniform float lane_offset = 0.15;
uniform vec2 corner_radii = vec2(0.2, 0.8);
uniform vec2 end_circle = vec2(0.04, 0.38);
uniform float track_mask = 0.0;
uniform float track_grade = 0.0;

varying vec3 wpos;
varying vec2 luv;
varying vec2 tile_lp;

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

// Mask bit k (N, E, S, W) to its arm direction in tile space, north at -Z.
vec2 arm_dir(int k) {
	if (k == 0) {
		return vec2(0.0, -1.0);
	} else if (k == 1) {
		return vec2(1.0, 0.0);
	} else if (k == 2) {
		return vec2(0.0, 1.0);
	}
	return vec2(-1.0, 0.0);
}

int arm_count(int m) {
	return (m & 1) + ((m >> 1) & 1) + ((m >> 2) & 1) + ((m >> 3) & 1);
}

// Signed distance (tile units, negative inside) to the carriageway edge of a road tile.
float road_sdf(vec2 lp, int m) {
	int n = arm_count(m);
	if (n == 0 || m == 5) {
		return abs(lp.x) - road_half;
	}
	if (m == 10) {
		return abs(lp.y) - road_half;
	}
	if (n == 2) {
		vec2 c = vec2(0.0);
		for (int k = 0; k < 4; k++) {
			if ((m & (1 << k)) != 0) {
				c += arm_dir(k) * 0.5;
			}
		}
		float r = length(lp - c);
		return max(corner_radii.x - r, r - corner_radii.y);
	}
	float d = n == 1 ? 1e3 : max(abs(lp.x), abs(lp.y)) - road_half;
	for (int k = 0; k < 4; k++) {
		if ((m & (1 << k)) != 0) {
			vec2 a = arm_dir(k);
			d = min(d, max(abs(dot(lp, vec2(-a.y, a.x))) - road_half, -dot(lp, a)));
			if (n == 1) {
				d = min(d, length(lp + a * end_circle.x) - end_circle.y);
			}
		}
	}
	return d;
}

// 1 on a wheel line (0.8 m either side of a lane centre); u is the distance from the road's centre
// line, w the band half-width.
float wheel(float u, float w) {
	float e = min(abs(u - lane_offset - 0.04), abs(u - lane_offset + 0.04));
	return 1.0 - smoothstep(w * 0.5, w, e);
}

// Wheel lines over a whole road tile: along each arm, round a corner's arc, and at a dead end a
// worn patch where traffic turns.
float wheel_lines(vec2 lp, int m, float w) {
	int n = arm_count(m);
	if (n == 0 || m == 5) {
		return wheel(abs(lp.x), w);
	}
	if (m == 10) {
		return wheel(abs(lp.y), w);
	}
	if (n == 2) {
		vec2 c = vec2(0.0);
		for (int k = 0; k < 4; k++) {
			if ((m & (1 << k)) != 0) {
				c += arm_dir(k) * 0.5;
			}
		}
		return wheel(abs(length(lp - c) - 0.5 * (corner_radii.x + corner_radii.y)), w);
	}
	float b = 0.0;
	for (int k = 0; k < 4; k++) {
		if ((m & (1 << k)) != 0) {
			vec2 a = arm_dir(k);
			if (dot(lp, a) > (n == 1 ? -end_circle.x : -road_half)) {
				b = max(b, wheel(abs(dot(lp, vec2(-a.y, a.x))), w));
			}
			if (n == 1) {
				b = max(b, 0.8 * (1.0 - smoothstep(0.07, 0.15, length(lp + a * end_circle.x))));
			}
		}
	}
	return b;
}
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	luv = UV;
	tile_lp = VERTEX.xz;
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
	float puddle = 0.0;
	if (track) {
		int m = int(track_mask + 0.5);
		int grade = int(track_grade + 0.5);
		float d = road_sdf(tile_lp, m) + (fbm(p * 0.9 + 1.7) - 0.5) * 0.035;
		float on = 1.0 - smoothstep(-0.008, 0.008, d);
		// In orbit the bands would be sub-pixel; widen them.
		float wk = cut_grass ? 2.0 : 1.0;
		float ruts = wheel_lines(tile_lp, m, 0.013 * wk);
		float lanes = wheel_lines(tile_lp, m, 0.07);
		float breakup = fbm(p * 0.6 + 9.0);
		vec3 surf;
		float cover;
		float srough;
		if (grade == 1) {
			// Gravel: grey-beige loose stone, pebble speckle fading out with distance, compacted wheel lines.
			float lum = dot(da, vec3(0.3, 0.59, 0.11));
			surf = mix(vec3(lum), da, 0.3) * vec3(1.2, 1.17, 1.1);
			float fade = 1.0 - smoothstep(0.2, 0.8, length(fwidth(p)) * 70.0);
			surf *= 1.0 + (vnoise(p * 70.0) - 0.5) * 0.6 * fade + (vnoise(p * 23.0 + 4.0) - 0.5) * 0.25;
			surf *= 1.0 - 0.14 * ruts;
			cover = on;
			srough = 0.92;
		} else if (grade == 2) {
			// Dirt track: brown earth rutted by wheels, grass tufts between and beside the wheel lanes.
			surf = da * vec3(0.92, 0.82, 0.68) * (1.0 - 0.22 * ruts);
			float tufts = (1.0 - lanes) * smoothstep(0.5, 0.72, breakup);
			tufts = max(tufts, smoothstep(-0.07, 0.0, d) * smoothstep(0.35, 0.6, breakup));
			cover = on * (1.0 - tufts);
			srough = 0.97;
		} else {
			// Grass trail: two worn earth lines per lane in trampled grass, broken where the grass wins.
			alb *= mix(vec3(1.0), vec3(1.06, 1.0, 0.78), on * lanes * 0.6);
			surf = da * vec3(0.9, 0.84, 0.72);
			cover = on * wheel_lines(tile_lp, m, 0.05 * wk) * smoothstep(0.25, 0.5, breakup + 0.1);
			srough = 0.95;
		}
		if (cut_grass && cover < 0.5) {
			discard;
		}
		alb = mix(alb, surf, cover);
		nrm = mix(nrm, dn, cover);
		rough = mix(rough, srough, cover);
		earth = max(earth, cover);
		puddle = grade == 1 ? 0.0 : ruts * cover;
	}
	// Rain: darker, with a satin sheen on bare earth (grass blades stay fairly matte); water stands in ruts.
	alb *= mix(1.0, mix(0.72, 0.55, earth), wetness);
	rough = mix(rough, mix(0.55, 0.25, earth), wetness);
	rough = mix(rough, 0.05, puddle * wetness * 0.85);	ALBEDO = alb;
	NORMAL_MAP = nrm;
	NORMAL_MAP_DEPTH = normal_strength;
	ROUGHNESS = rough;
	SPECULAR = 0.35;
}
