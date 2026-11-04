shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
// Metric ground for street level. Grass (or a dirt mix on vacant lots) at one repeat per 3 m with no
// visible tiling: each region of the plane samples the texture at its own random offset and the
// regions blend across a noise field (Quilez, "texture repetition", technique 3). A 40 m macro layer
// varies the colour and wears in dirt patches, so open land stops reading as a golf course; below it
// (G2) 30 cm clumps, 1 to 6 m thin and dry patches and darker clover keep a lawn from reading as one
// green plane, and pebbles break up bare earth. The macro and patch layers read one tiling noise
// texture (textures/real/decals/noise_fbm.png, mip-filtered, so they average out at range for free)
// instead of hashed fbm: about 40 hashes a pixel fewer on the biggest surface. Roughness is a
// constant (the scanned grass roughness varied by 0.008): grass 0.9, earth 0.95, no strong specular.

uniform sampler2D grass_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// A tiling, equalised fbm: 256 px, values spread evenly 0..1 (0.5 is the middle, and what a mip averages to).
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
// World units in a metre (WorldScale.M), for features sized in metres.
uniform float metre = 0.05;
// Repeats per world unit (1 u = 20 m): 1 per 3 m for detail, 1 per 40 m for the macro layer.
uniform float detail_scale = 6.6667;
uniform float macro_scale = 0.5;
// 0 lawn .. 1 bare earth; lot_edge > 0 fades the earth back to grass toward the quad's UV edges.
uniform float dirt = 0.0;
uniform float lot_edge = 0.0;
uniform vec3 grass_tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float normal_strength = 0.7;
uniform float wetness = 0.0;
// 1: the look-polish response (flag look_polish): the lawn's broad noise is calmed with range, its
// tone is lifted back toward green, rain darkens early, and the shore's wet line wanders.
// 0: the look before it. CityView writes 0 only with the flag off.
uniform float polish = 1.0;
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
// The shore band (scripts/world/shore.gd), from the vertex colour of the meshes that carry it: alpha 0.5
// marks a land tile coded with which of its eight neighbours are water, alpha 0.25 a river-bed vertex
// carrying sand and wet itself. Any other alpha (a plain mesh is white) means no shore.
varying vec4 shore_v;

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

float nz(vec2 uv) {
	return texture(noise_tex, uv).r;
}

// The shore's wet line is a ruler edge (the bank is a straight ramp): this low-frequency offset
// (about +-0.75, metres long) moves, by up to 0.8 m either way, where the sand turns wet and, on the
// bed under the shallows, where it turns to silt.
float shore_wob(vec2 wm) {
	return (nz(wm / 9.0 + vec2(0.2, 0.6)) - 0.5) + 0.5 * (nz(wm / 2.7 + vec2(0.6, 0.1)) - 0.5);
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
	shore_v = COLOR;
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
	// Dirt at the same scale, rotated so its features do not line up with the grass.
	vec2 q = vec2(p.y, -p.x) * 0.8;
	vec2 qdx = vec2(dx.y, -dx.x) * 0.8;
	vec2 qdy = vec2(dy.y, -dy.x) * 0.8;
	vec3 da = mix(textureGrad(dirt_albedo, q + oa, qdx, qdy).rgb, textureGrad(dirt_albedo, q + ob, qdx, qdy).rgb, w);
	vec3 dn = mix(textureGrad(dirt_normal, q + oa, qdx, qdy).rgb, textureGrad(dirt_normal, q + ob, qdx, qdy).rgb, w);
	vec2 wm = wpos.xz / metre;
	float px = length(fwidth(wm));
	// How far the pixel is (m), and how much of the broad variation to keep there: the 5 to 40 m
	// layers drawn at a grazing angle line up into combed arcs across a lawn, so they thin out with
	// range, while the fine layers (clumps, grain) go on as they were.
	float dist_m = length(VERTEX) / metre;
	float calm = polish * smoothstep(14.0, 70.0, dist_m);
	// Macro layer: lush and dry patches at 40 m, worn spots at 10 m.
	vec2 mp = wpos.xz * macro_scale;
	float m1 = nz(mp * 0.25);
	float m2 = nz(mp + vec2(0.37, 0.61));
	// The scan is low contrast (luminance spread 0.04): stretch the detail finer than about 15 cm (the
	// scan less its own blur, so it holds in whatever colour space the platform samples in). Stretching
	// the whole image about its mean amplified the tile's own 3 m blotches, which then showed as a
	// regular lattice of dark patches across a lawn; the patches come from the noise layers below.
	vec3 gl = mix(textureLod(grass_albedo, p + oa, 4.0).rgb, textureLod(grass_albedo, p + ob, 4.0).rgb, w);
	g = max(g + (g - gl) * 0.9, vec3(0.0));
	// The macro tone: the lush and dry ends, lifted toward green with look-polish (the dry end had
	// gone olive and the whole lawn about 9% darker than before the materials unit).
	vec3 lo = mix(vec3(0.78, 0.86, 0.70), vec3(0.86, 0.93, 0.78), polish);
	vec3 hi = mix(vec3(1.12, 1.06, 0.84), vec3(1.18, 1.14, 0.98), polish);
	float mt = mix(smoothstep(0.15, 0.85, m1), 0.5, calm * 0.6);
	g *= grass_tint * mix(lo, hi, mt);
	g *= mix(0.88 + 0.24 * m2, 1.0, calm * 0.6);
	// Clumps (under 1.5 m), thin and dry patches (up to 6 m), and darker, bluer clover between them.
	// Everything below reads metres warped by the 40 m macro noise (read for free: m1 and m2 are above):
	// a noise tile repeated at a fixed period shows as a regular lattice of dark blobs across a lawn,
	// and the warp (up to 6 m) makes every repeat a different size and place. The clumps are fine (0.45,
	// 0.8 and 1.4 m tiles): coarser ones with a bigger warp swirled the lawn like combed hair.
	vec2 ww = wm + (vec2(m2, m1) - 0.5) * mix(12.0, 5.0, polish);
	vec2 wwr = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * ww;
	vec2 wwr2 = mat2(vec2(0.96, -0.28), vec2(0.28, 0.96)) * ww;
	// Clumps: three layers of different period, each turned against the others.
	float c1 = (nz(ww / 0.45 + vec2(0.31, 0.77)) + nz(wwr / 0.8 + vec2(0.4, 0.2)) + nz(wwr2 / 1.4 + vec2(0.1, 0.5))) * 0.3333;
	float c2 = nz(ww / 5.5 + vec2(0.62, 0.15));
	float c3 = nz(wm / 23.0 + vec2(0.9, 0.4));
	g *= mix(0.70 + 0.48 * c1, 0.78 + 0.40 * c1, polish);
	float dry = smoothstep(0.7, 0.92, c3 * 0.55 + c2 * 0.45) * (1.0 - calm * 0.7);
	g = mix(g, g * mix(vec3(1.18, 1.06, 0.8), vec3(1.12, 1.05, 0.88), polish) + vec3(0.012, 0.008, 0.0), dry * mix(0.5, 0.4, polish));
	float clover = smoothstep(0.62, 0.74, 0.5 * (nz(wwr / 5.3 + vec2(0.2, 0.6)) + nz(ww / 7.9 + vec2(0.7, 0.3)))) * (1.0 - dry) * (1.0 - calm * 0.7);
	g = mix(g, g * vec3(0.78, 0.96, 0.80), clover * 0.55);
	// Blade-scale grain, where a pixel is smaller than a centimetre.
	g *= 1.0 + (1.0 - smoothstep(0.35, 0.9, px / 0.01)) * (hash12(floor(wm / 0.01)) - 0.5) * 0.18;
	float worn = smoothstep(0.82, 0.97, m2 * 0.65 + m1 * 0.35) * 0.55 * (1.0 - calm * 0.5);
	float earth = worn;
	if (dirt > 0.0) {
		float patchy = clamp(dirt + (nz(wm / 8.6 + vec2(0.3, 0.1)) - 0.5) * 0.5, 0.0, 1.0);
		if (lot_edge > 0.0) {
			float e = min(min(luv.x, 1.0 - luv.x), min(luv.y, 1.0 - luv.y));
			patchy *= smoothstep(0.0, 0.09, e);
		}
		earth = max(earth, patchy);
	}
	earth = clamp(earth + (gn.g - 0.5) * 0.3 * earth, 0.0, 1.0);
	// The earth scan is low contrast too; pebbles and dark voids in it where a pixel is under 1 cm.
	da = max(da + (da - textureLod(dirt_albedo, vec2(0.5), 10.0).rgb) * 0.8, vec3(0.0));
	vec3 alb = mix(g, da * vec3(0.95, 0.9, 0.85), earth);
	float pb = hash12(floor(wm / 0.012));
	alb *= 1.0 + earth * (1.0 - smoothstep(0.35, 0.9, px / 0.012)) * (step(0.93, pb) * 0.5 - step(pb, 0.05) * 0.3);
	vec3 nrm = mix(gn, dn, earth);
	float rough = mix(0.9 + 0.05 * (c1 - 0.5), 0.95, earth);
	float spec = mix(0.18, 0.3, earth);
	vec2 shore = vec2(0.0);
	vec2 away = vec2(0.0);
	if (abs(shore_v.a - 0.5) < 0.05) {
		// A land tile at the water: the distance to the water, per pixel, from the neighbour code
		// (as RiverBed.land_distance), and the direction away from it.
		int edges = int(shore_v.r * 15.0 + 0.5);
		int corners = int(shore_v.g * 15.0 + 0.5);
		vec2 t = fract(wpos.xz + 0.5);
		float dist = 2.0;
		for (int k = 0; k < 4; k++) {
			bool on_e = ((edges >> k) & 1) != 0;
			float de = k == 0 ? t.y : (k == 1 ? 1.0 - t.x : (k == 2 ? 1.0 - t.y : t.x));
			if (on_e && de < dist) {
				dist = de;
				away = k == 0 ? vec2(0.0, 1.0) : (k == 1 ? vec2(-1.0, 0.0) : (k == 2 ? vec2(0.0, -1.0) : vec2(1.0, 0.0)));
			}
			bool on_c = ((corners >> k) & 1) != 0;
			vec2 cc = k == 0 ? t : (k == 1 ? t - vec2(1.0, 0.0) : (k == 2 ? t - vec2(1.0, 1.0) : t - vec2(0.0, 1.0)));
			float dc = length(cc);
			if (on_c && dc < dist) {
				dist = dc;
				away = cc / max(dc, 1e-5);
			}
		}
		shore = vec2(1.0 - smoothstep(0.0, 0.15, dist), 1.0 - smoothstep(0.0, 0.05, dist - polish * shore_wob(wm) * 0.05));
	} else if (abs(shore_v.a - 0.25) < 0.05) {
		shore = clamp(shore_v.rg + polish * shore_wob(wm) * vec2(0.35, 0.8), 0.0, 1.0);
	}
	if (shore.x > 0.004) {
		// Shore band: grass gives way to pale warm sand rippled parallel to the waterline (crests
		// every 25 cm, warped), darker and glossier where it is wet.
		// The band's edges wander (the water's edge is geometry, but where the sand gives out to grass
		// and where it turns wet are not a ruler line): scale the band by noise that is 1 on average,
		// so it still fades to nothing at its outer limit.
		float sx = shore.x * (0.55 + 0.9 * nz(wm / 2.9 + vec2(0.55, 0.35)));
		shore.y = clamp(shore.y * (0.6 + 0.8 * nz(wm / 1.7 + vec2(0.15, 0.8))), 0.0, 1.0);
		float lum = dot(da, vec3(0.3, 0.59, 0.11));
		vec3 sand = vec3(lum) * vec3(2.35, 1.95, 1.3) * (0.8 + 0.4 * nz(wm / 6.7 + vec2(0.4, 0.2))) * (0.92 + 0.16 * nz(wm / 1.1 + vec2(0.3, 0.7)));
		// Grains (5 mm) while a pixel is smaller than that, and coarse grit and shell (2 cm) over them:
		// dark flecks and pale ones, so wet sand does not read as a smooth grey slab.
		sand *= 0.82;
		sand *= 1.0 + (1.0 - smoothstep(0.35, 0.9, px / 0.005)) * (hash12(floor(wm / 0.005)) - 0.5) * 0.3;
		float gh = hash12(floor(wm / 0.02) + 17.0);
		float grit = (1.0 - smoothstep(0.2, 0.42, length(fract(wm / 0.02) - 0.5))) * (1.0 - smoothstep(0.35, 0.9, px / 0.02));
		sand *= 1.0 + grit * (step(0.86, gh) * 0.45 - step(gh, 0.12) * 0.4);
		float cover = smoothstep(0.12, 0.55, sx + (nz(wm / 10.7 + vec2(0.8, 0.5)) - 0.5) * 0.25);
		float crest = sin((sx * 12.0 + (nz(wm / 10.0 + vec2(0.1, 0.9)) - 0.5) * 2.4) * 6.2831853);
		float ripple_fade = 1.0 - smoothstep(0.3, 0.8, (length(dx) + length(dy)) * 10.0);
		vec3 sn = vec3(0.5 + away * crest * 0.16 * ripple_fade, 1.0);
		sand *= 1.0 + crest * 0.04 * ripple_fade;
		alb = mix(alb, sand, cover);
		nrm = mix(nrm, sn, cover);
		rough = mix(rough, 0.82, cover);
		spec = mix(spec, 0.35, cover);
		float wet = shore.y * cover;
		alb *= mix(vec3(1.0), vec3(0.66, 0.62, 0.55), wet);
		rough = mix(rough, 0.2, wet);
	}
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
	// The ground darkens early in rain and dries slowly (see road_fp.gdshader's damp).
	float damp = mix(wetness, 1.0 - (1.0 - wetness) * (1.0 - wetness), polish);
	alb *= mix(1.0, mix(0.72, 0.55, earth), damp);
	rough = mix(rough, mix(0.55, 0.25, earth), damp);
	rough = mix(rough, 0.20, puddle * wetness * 0.85);
	ALBEDO = alb;
	NORMAL_MAP = nrm;
	NORMAL_MAP_DEPTH = normal_strength;
	ROUGHNESS = rough;
	// Grass and dry earth barely shine; rain gives bare earth a sheen (the grass stays matte).
	SPECULAR = mix(spec, 0.45, damp * earth);
}
