shader_type spatial;
// The paved surfaces at street level (slice G1, materials unit G2). The road models tile one asphalt
// quad per tile with its own UV offset, so the texture broke at every tile edge and repeated every
// 4 m. Here everything is mapped in world metres (continuous along the street) and broken up by
// noise at several scales. `surface` says what the mesh is; one shader, so the browser links one
// program set for all of them (a new shader costs boot time):
//   0 carriageway asphalt: a second rotated sample, then the wear real roads show: a darker oil
//     streak down each lane, polished wheel tracks either side of it, grit and dust in the gutters,
//     older greyer stretches, aggregate speckle, hairline cracks, dark tar repairs, oil darkening
//     at junctions, and in rain water standing in the tracks and gutters, rings spreading across it.
//   1 pavement slabs: the paver texture (a running bond of 1 m x 0.5 m blocks, 3 m a repeat), each
//     paver its own tone, dirt packed in the joints, stains, pores.
//   2 kerb stone: granite, speckled, dirty at its foot, jointed every metre.
//   3 poured concrete (lot slabs): mottled, stained, pitted, with a control joint every 3 m.
//   4 lane paint: white paint chipped and dirtied by tyres, never one flat white.
// lane_axis (asphalt only; one shared material per value, CityView.road_fp_material_for) says where
// the lanes run: 0 none (junctions), 1 along z, 2 along x, 3-6 round the tile corner +x+z, -x+z,
// -x-z, +x-z, 7 none and no junction oil (lots, car parks). It is not an instance uniform: on Compatibility those take a slot of a 4096-slot
// buffer per mesh, and a grown city's road pieces overflow it. Roughness is a constant per surface
// (the scanned maps were near flat, std 0.008 to 0.021, and cost 0.7 MB a piece on the web): asphalt
// 0.78, pavement 0.84, concrete 0.82, kerb 0.7, paint 0.8, each broken by noise; wet surfaces go glossy.
// Wet (look-polish unit D3): the weather's wetness climbs linearly over 120 s of rain and falls over
// 300 s; the surfaces answer with `damp`, which comes fast (a shower darkens the road within seconds)
// and goes slow on the way out, and the water standing in the tracks (`pool`) follows the slower
// wetness itself, so it gathers after the road has darkened and is the last to dry.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// A tiling, equalised fbm (textures/real/decals/noise_fbm.png): 256 px, values spread evenly 0..1.
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 tint : source_color = vec4(0.80, 0.80, 0.81, 1.0);
uniform float metre = 0.05;
uniform float repeat_m = 4.0;
uniform float lane_offset = 0.15;
uniform float half_width = 0.3;
uniform float wetness = 0.0;
// 1: the look-polish response (flag look_polish): wet surfaces darken early and further, shine less
// pale, asphalt blotches fade with distance, the kerb and the lane paint are not evenly marked.
// 0: the look before it. CityView writes 0 only with the flag off.
uniform float polish = 1.0;
// Rain falling now (0..1): rings on the standing water.
uniform float rain = 0.0;
uniform float lane_axis = 0.0;
// 0 asphalt, 1 pavement, 2 kerb, 3 concrete, 4 paint (see above).
uniform float surface = 0.0;
// Height of the carriageway in world units: the foot of a kerb.
uniform float base_y = 0.0;

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize(mat3(MODEL_MATRIX) * NORMAL);
	// World-aligned tangent frame to match the world-space UVs below.
	mat3 inv = inverse(mat3(MODEL_MATRIX));
	TANGENT = normalize(inv * vec3(1.0, 0.0, 0.0));
	BINORMAL = normalize(inv * vec3(0.0, 0.0, 1.0));
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float nz(vec2 uv) {
	return texture(noise_tex, uv).r;
}

// One layer of raindrop rings on standing water, p in metres over cells of 'cell' m: each cell gets
// a drop at a random point and time; its ring spreads to 'reach' of the cell and fades. Returns the
// ring's slope (a tangent-space tilt) at p.
vec2 rings(vec2 p, float cell, float t) {
	vec2 c = floor(p / cell);
	vec2 h = fract(sin(vec2(dot(c, vec2(127.1, 311.7)), dot(c, vec2(269.5, 183.3)))) * 43758.5453);
	vec2 d = p / cell - c - (0.25 + 0.5 * h);
	float r = length(d);
	float age = fract(t + h.x * 7.31);
	float x = r - age * 0.45;
	float ring = sin(x * 60.0) * (1.0 - age) * (1.0 - smoothstep(0.0, 0.05, abs(x)));
	return d / max(r, 1e-4) * ring;
}

// Distance across the carriageway from its centreline (tile units), or -1 with no lanes.
float across_of(vec2 local) {
	int a = int(lane_axis + 0.5);
	if (a == 1) {
		return abs(local.x);
	}
	if (a == 2) {
		return abs(local.y);
	}
	if (a >= 3 && a <= 6) {
		vec2 c = a == 3 ? vec2(0.5, 0.5) : (a == 4 ? vec2(-0.5, 0.5) : (a == 5 ? vec2(-0.5, -0.5) : vec2(0.5, -0.5)));
		return abs(length(local - c) - 0.5);
	}
	return -1.0;
}

void fragment() {
	int kind = int(surface + 0.5);
	float top = smoothstep(0.6, 0.9, wnrm.y);
	float damp = mix(wetness, 1.0 - (1.0 - wetness) * (1.0 - wetness), polish);
	// How far a blotch is from the eye (m): broad stains and warm casts fade out with it.
	float dist_f = polish * smoothstep(7.0, 45.0, length(VERTEX) / metre);
	// Metres on the ground plane; the faces of a kerb or slab edge map along the wall instead.
	vec2 m = top > 0.5 ? wpos.xz / metre : vec2(wpos.x + wpos.z, wpos.y) / metre;
	float px = length(fwidth(m));
	vec3 alb;
	vec3 nrm = vec3(0.5, 0.5, 1.0);
	float rough;
	float pool = 0.0;
	if (kind == 0) {
		float n_big = nz(m / 47.0);
		float n_mid = nz(m / 11.0 + vec2(0.5, 0.3));
		float n_fine = nz(m / 2.3 + vec2(0.2, 0.7));
		vec2 uv1 = m / repeat_m;
		vec2 uv2 = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * uv1 * 0.73 + vec2(0.37, 0.11);
		float pick = smoothstep(0.3, 0.7, n_mid);
		alb = mix(texture(albedo_tex, uv1).rgb, texture(albedo_tex, uv2).rgb, pick);
		nrm = mix(texture(normal_tex, uv1).rgb, texture(normal_tex, uv2).rgb, pick);
		// The scan is low contrast (luminance spread 0.01): stretch it about its mean (the 1x1 mip,
		// so it holds whatever colour space the platform samples in) so the aggregate reads.
		alb = max(alb + (alb - textureLod(albedo_tex, vec2(0.5), 10.0).rgb) * 1.1, vec3(0.0));
		alb *= tint.rgb;
		// The scanned asphalt is brown; city asphalt reads a neutral grey.
		alb = mix(alb, vec3(dot(alb, vec3(0.3333))), mix(0.45, 0.62, polish));
		// Older, sun-bleached stretches are lighter and greyer; patched ones darker. From a height
		// the stains read as camouflage, so their contrast and the brown in them fade with range.
		float age = smoothstep(0.25, 0.75, n_big);
		alb *= mix(mix(0.86, 1.08, age), 0.97, dist_f * 0.7);
		alb = mix(alb, vec3(dot(alb, vec3(0.3333))), max(age * 0.35, dist_f * 0.75));
		alb *= 0.90 + 0.20 * n_fine * (1.0 - dist_f * 0.5);
		vec2 local = wpos.xz - round(wpos.xz);
		float d = across_of(local);
		float oil = 0.0;
		float track = 0.0;
		float gutter = 0.0;
		if (d >= 0.0) {
			float lane = abs(d - lane_offset);
			// Wear comes and goes along the lane (stretches of 10 to 30 m), so the tracks and drips
			// read as patches of rubber, not as long parallel rules running to the horizon.
			float along_wear = 0.3 + 0.7 * smoothstep(0.3, 0.75, nz(m / 19.0 + vec2(0.7, 0.2)));
			oil = (1.0 - smoothstep(0.004, 0.014, lane)) * (0.55 + 0.9 * n_fine * n_mid) * along_wear;
			float t = abs(lane - 0.042);
			track = (1.0 - smoothstep(0.005, 0.015, t)) * along_wear;
			gutter = smoothstep(half_width - 0.035, half_width - 0.006, d);
		} else if (lane_axis < 6.5) {
			// A junction has no lanes: cars brake, turn and drip in its middle.
			oil = (1.0 - smoothstep(0.04, 0.36, length(local))) * (0.35 + 0.65 * n_mid);
		}
		// Tyres darken their tracks with rubber and keep them free of dust; drips darken the lane
		// centre; dust and grit settle between the lanes and along the gutters.
		float between = d >= 0.0 ? 1.0 - smoothstep(0.02, 0.05, d) : 0.0;
		alb *= 1.0 - 0.26 * clamp(oil, 0.0, 1.0) * (1.0 - dist_f * 0.45);
		alb *= 1.0 - 0.11 * track * (0.7 + 0.6 * n_mid);
		alb *= 1.0 + 0.10 * between;
		alb = mix(alb, mix(vec3(0.34, 0.32, 0.29), vec3(0.33), dist_f * 0.8), gutter * (0.35 + 0.35 * n_mid));
		// Aggregate: 6 mm grains and round 17 mm flints on a turned grid (so no square cells show),
		// each fading out where it is under a pixel.
		vec2 r1 = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * m;
		float f1 = 1.0 - smoothstep(0.35, 0.9, px / 0.006);
		float f2 = 1.0 - smoothstep(0.35, 0.9, px / 0.017);
		float h2 = hash12(floor(r1 / 0.017) + 31.0);
		float flint = (1.0 - smoothstep(0.2, 0.38, length(fract(r1 / 0.017) - 0.5))) * f2;
		// A wet road's pale flints go dull: the water takes the grit's sparkle.
		float grit_wet = 1.0 - 0.55 * damp * polish;
		alb *= 1.0 + (f1 * (hash12(floor(r1 / 0.006)) - 0.5) * 0.22 + flint * (step(0.85, h2) * 0.6 - step(h2, 0.1) * 0.35)) * grit_wet;
		// Hairline cracks follow the iso-line of a noise field, in a few worn stretches only; the
		// field blurs to its mean at range, so they fade out before they would draw lines everywhere.
		float cn = nz(m / 7.0 + vec2(0.13, 0.57));
		float worn = smoothstep(0.66, 0.88, nz(m / 31.0 + vec2(0.4, 0.2)));
		float crack = (1.0 - smoothstep(0.004, 0.011, abs(cn - 0.5))) * worn;
		crack *= 1.0 - smoothstep(0.4, 1.0, px / 0.03);
		alb *= 1.0 - 0.5 * crack * (1.0 - dist_f * 0.6);
		// Tar repairs: a square-edged darker patch in about one 4 m cell in ten, its edge ragged
		// by the noise (a road is mended with a cut rectangle, not a blot).
		vec2 pc = m / 4.0;
		vec2 pid = floor(pc);
		float tar = 0.0;
		if (hash12(pid + 71.0) > 0.9) {
			vec2 ctr = (0.35 + 0.3 * vec2(hash12(pid + 5.1), hash12(pid + 9.7))) * 4.0;
			vec2 half_size = vec2(0.4 + 0.8 * hash12(pid + 13.3), 0.3 + 0.6 * hash12(pid + 17.9));
			vec2 q = abs(fract(pc) * 4.0 - ctr) - half_size;
			tar = 1.0 - smoothstep(-0.012 - px, 0.012 + px, max(q.x, q.y) + (n_fine - 0.5) * 0.06);
		}
		alb *= 1.0 - 0.26 * tar * (1.0 - dist_f * 0.5);
		// Dry: nearly matte with polished tracks. Wet: darker and glossy, water standing in the
		// tracks and gutters where the noise says the surface dips.
		rough = 0.78 + 0.10 * (n_mid - 0.5) - 0.12 * track - 0.16 * tar - 0.05 * crack;
		pool = wetness * smoothstep(0.5, 0.7, max(track * n_mid, gutter * n_big) + n_fine * 0.25);
		alb *= mix(1.0, mix(0.6, 0.46, polish), damp);
		alb *= 1.0 - 0.25 * pool;
	} else if (kind == 1) {
		// Pavers in a running bond: 3 blocks of 1 m across a repeat, 6 rows of 0.5 m, every other
		// row shifted by half a block (read off the texture's own joints).
		vec2 t = m / repeat_m;
		alb = texture(albedo_tex, t).rgb * tint.rgb;
		nrm = texture(normal_tex, t).rgb;
		float row = floor(t.y * 6.0);
		float cx = t.x * 3.0 - 0.5 * (1.0 - mod(row, 2.0));
		vec2 cell = vec2(floor(cx), row) + floor(t) * vec2(3.0, 6.0);
		float hb = hash12(cell);
		float hc = hash12(cell + 7.7);
		float st = nz(mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * m / 3.1 + vec2(0.23, 0.81));
		float mot = nz(m / 0.55 + vec2(0.5, 0.5));
		// The scan is low contrast: stretch it, give each paver its own tone and warmth, then stain
		// and mottle the lot.
		alb = max(alb + (alb - textureLod(albedo_tex, vec2(0.5), 10.0).rgb) * 0.7, vec3(0.0));
		alb *= 0.90 + 0.20 * hb;
		alb *= mix(vec3(1.0), vec3(1.04, 1.0, 0.93), hc * 0.6);
		alb *= 1.0 - 0.12 * smoothstep(0.62, 0.95, st);
		alb *= 0.94 + 0.12 * mot;
		// Dirt packed in the joints, and the paver edges a shade darker.
		vec2 f = vec2(fract(cx), fract(t.y * 6.0));
		float dj = min(min(f.x, 1.0 - f.x) * 1.0, min(f.y, 1.0 - f.y) * 0.5);
		float jl = (1.0 - smoothstep(0.005, 0.016, dj)) * (1.0 - smoothstep(0.4, 1.0, px / 0.012));
		alb *= 1.0 - 0.1 * (1.0 - smoothstep(0.0, 0.06, dj));
		alb = mix(alb, alb * vec3(0.5, 0.52, 0.46), jl * (0.55 + 0.45 * mot));
		// Pores and fine grit.
		float f1 = 1.0 - smoothstep(0.35, 0.9, px / 0.004);
		alb *= 1.0 + f1 * (hash12(floor(m / 0.004)) - 0.5) * 0.3;
		rough = 0.84 + 0.12 * (mot - 0.5) - 0.06 * jl;
		alb *= mix(1.0, mix(0.62, 0.5, polish), damp);
	} else if (kind == 2) {
		// Granite kerb: speckle, grime at the foot of the face, a joint every metre along it.
		float n_mid = nz(m / 11.0 + vec2(0.5, 0.3));
		float n_fine = nz(m / 2.3 + vec2(0.2, 0.7));
		float along = abs(wnrm.x) > abs(wnrm.z) ? wpos.z : wpos.x;
		float mot = nz(m / 0.9 + vec2(0.35, 0.15));
		// The face is lit by sky ambient only (blue), so the stone is lighter and a touch warm there:
		// a kerb that reads black frames the busy pavement like a drawn line.
		alb = vec3(0.60, 0.585, 0.55) * tint.rgb * (0.84 + 0.30 * mot) * mix(vec3(1.0), vec3(1.07, 1.0, 0.88), 1.0 - top);
		float f1 = 1.0 - smoothstep(0.35, 0.9, px / 0.004);
		float g = hash12(floor(m / 0.004));
		alb *= 1.0 + f1 * ((g - 0.5) * 0.5 + step(0.93, g) * 0.45 - step(g, 0.06) * 0.35);
		// The face is a few pixels tall from the street: granite flecks at 1.2 cm and weathering at
		// 6 cm (noise reads, so they hold at range) keep it from reading as a smooth grey band.
		float fleck = hash12(floor(m / 0.012) + 5.0);
		float f3 = 1.0 - smoothstep(0.35, 0.95, px / 0.012);
		float wea = nz(m / 0.06 + vec2(0.7, 0.2)) * 0.6 + nz(m / 0.27 + vec2(0.1, 0.4)) * 0.4;
		alb *= 1.0 + polish * (f3 * ((fleck - 0.5) * 0.3 + step(0.9, fleck) * 0.22 - step(fleck, 0.08) * 0.22) + (1.0 - top) * (wea - 0.5) * 0.4);
		float h = (wpos.y - base_y) / metre;
		float foot = (1.0 - top) * (1.0 - smoothstep(0.0, 0.09, h));
		alb *= 1.0 - 0.3 * foot * (0.6 + 0.4 * n_fine);
		alb *= 1.0 - 0.18 * top * smoothstep(0.55, 0.9, n_mid);
		// A joint every metre or so: each stone a little longer or shorter than the next.
		float ai = along / metre;
		float dj = abs(fract(ai + 0.5) - 0.5);
		if (polish > 0.5) {
			float ij = floor(ai + 0.5);
			dj = min(abs(ai - ij - 0.3 * (hash12(vec2(ij, 3.0)) - 0.5)), min(abs(ai - ij + 1.0 - 0.3 * (hash12(vec2(ij - 1.0, 3.0)) - 0.5)), abs(ai - ij - 1.0 - 0.3 * (hash12(vec2(ij + 1.0, 3.0)) - 0.5))));
		}
		float jl = (1.0 - smoothstep(0.003, 0.010, dj)) * (1.0 - top) * (1.0 - smoothstep(0.4, 1.0, px / 0.01));
		alb *= 1.0 - 0.5 * jl;
		rough = 0.70 + 0.12 * (n_fine - 0.5) + 0.1 * foot;
		alb *= mix(1.0, mix(0.6, 0.5, polish), damp);
	} else if (kind == 3) {
		// Poured concrete: mottled, stained, pitted, a control joint every 3 m.
		float n_big = nz(m / 47.0);
		float mot = nz(m / 0.8 + vec2(0.12, 0.66));
		float st = nz(m / 3.3 + vec2(0.58, 0.07));
		alb = vec3(0.44, 0.43, 0.41) * tint.rgb * (0.86 + 0.28 * mot);
		alb *= 1.0 - 0.34 * smoothstep(0.55, 0.92, st);
		alb *= 1.0 + 0.1 * (n_big - 0.5);
		float f1 = 1.0 - smoothstep(0.35, 0.9, px / 0.005);
		float g = hash12(floor(m / 0.005));
		alb *= 1.0 + f1 * ((g - 0.5) * 0.3 - step(g, 0.04) * 0.4);
		vec2 jf = abs(fract(m / 3.0 + 0.5) - 0.5) * 3.0;
		float dj = min(jf.x, jf.y);
		float jl = (1.0 - smoothstep(0.004, 0.014, dj)) * (1.0 - smoothstep(0.4, 1.0, px / 0.012));
		alb *= 1.0 - 0.1 * (1.0 - smoothstep(0.0, 0.08, dj));
		alb = mix(alb, alb * 0.45, jl);
		rough = 0.82 + 0.12 * (mot - 0.5);
		alb *= mix(1.0, mix(0.62, 0.5, polish), damp);
	} else {
		// Lane paint: chipped where tyres have been, grey with dust, never flat white.
		float n_mid = nz(m / 11.0 + vec2(0.5, 0.3));
		float n_fine = nz(m / 2.3 + vec2(0.2, 0.7));
		float chip = smoothstep(0.62, 0.8, nz(m / 0.3 + vec2(0.9, 0.4)) * 0.6 + n_mid * 0.4);
		if (polish > 0.5) {
			// The 0.3 m tile of that noise repeated every 0.3 m, so the chips came at equal
			// spacing along a line: two turned tiles of unrelated size, grouped by a 7 m one.
			vec2 rm = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * m;
			float cz = nz(rm / 0.37 + vec2(0.9, 0.4)) * 0.5 + nz(vec2(rm.y, -rm.x) / 0.53 + vec2(0.2, 0.7)) * 0.5;
			chip = smoothstep(0.58, 0.78, cz * 0.65 + nz(m / 7.3 + vec2(0.3, 0.8)) * 0.35);
		}
		float dust = smoothstep(0.4, 0.9, n_fine);
		alb = vec3(0.66, 0.65, 0.62);
		alb = mix(alb, vec3(0.20, 0.19, 0.18), chip * 0.75);
		alb *= 1.0 - 0.28 * dust;
		float f1 = 1.0 - smoothstep(0.35, 0.9, px / 0.005);
		alb *= 1.0 + f1 * (hash12(floor(m / 0.005)) - 0.5) * 0.3;
		rough = 0.80 - 0.1 * chip;
		alb *= mix(1.0, mix(0.7, 0.6, polish), damp);
	}
	ALBEDO = alb;
	ROUGHNESS = mix(mix(rough, 0.22, wetness * 0.8), mix(rough, 0.3, damp * 0.85), polish);
	// Pools sheen, not mirror: at 0.03 with a flattened normal each pool pixel is a sky sample
	// (a glaring jagged band at grazing angles on the web GL build); 0.25 stays glossier than
	// the surrounding wet asphalt (~0.34) so the standing water still reads, via the darkened albedo.
	ROUGHNESS = mix(ROUGHNESS, mix(0.25, 0.2, polish), pool);
	// Dry surfaces barely shine (a rough sky reflection washes a dark road pale on the web GL build);
	// rain gives them a real gloss.
	// A wet road is dark with a sheen, not a pale mirror: the sheen is moderate over the wet surface
	// and stronger only on the standing water.
	SPECULAR = mix(mix(kind == 0 ? 0.12 : 0.15, 0.6, wetness), mix(kind == 0 ? 0.12 : 0.15, 0.36, damp) + 0.22 * pool, polish);
	// Kerb and slab faces are flat: only the top takes the scanned normal.
	NORMAL_MAP = mix(vec3(0.5, 0.5, 1.0), nrm, top);
	NORMAL_MAP = mix(NORMAL_MAP, vec3(0.5, 0.5, 1.0), pool * 0.5);
	if (rain > 0.0 && pool > 0.0) {
		vec2 tilt = rings(m, 0.35, TIME * 1.3) + rings(m + vec2(0.17, 0.41), 0.5, TIME * 1.05 + 0.5);
		NORMAL_MAP.xy += 0.35 * rain * pool * tilt;
	}
	NORMAL_MAP_DEPTH = 1.0;
}
