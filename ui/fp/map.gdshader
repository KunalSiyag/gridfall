// Map renderer for the minimap and the full map (slice B). Draws the city procedurally from
// the 192x192 tile images of minimap_model.gd: roads joined to their neighbours, inset building
// footprints, smooth shorelines and woods, hazed unsurveyed plots, and optional district borders.
// The rect shows the world around `center` (tiles) at `ppt` pixels per tile, north up; the minimap
// rotates its Control for the heading, the full map pans and zooms through the uniforms.
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D col_tex : filter_nearest, repeat_disable;
uniform sampler2D data_tex : filter_nearest, repeat_disable;
uniform sampler2D survey_tex : filter_linear, repeat_disable;
uniform vec2 world_origin = vec2(-80.0, -80.0);
uniform vec2 world_size = vec2(192.0, 192.0);
uniform vec2 center = vec2(15.0, 14.0);
uniform float ppt = 3.5;
uniform vec2 rect_size = vec2(200.0, 200.0);
// 0 = circle (minimap), 1 = rounded rectangle (full map).
uniform int shape = 0;
uniform float corner = 16.0;
uniform float opacity = 0.9;
uniform float rim_shade = 0.35;
// Circle only: pixels between the circle and the rect edge, holding the soft outer shadow.
uniform float pad = 0.0;
uniform float ring_alpha = 0.42;
uniform bool borders = false;

const int LAND = 0;
const int ROAD = 1;
const int WATER = 2;
const int PARK = 3;
const int FOREST = 4;
const int LOT = 5;
const int BUILDING = 6;
const int SERVICE = 7;
const int SITE = 8;
const int RUBBLE = 9;
const int BRIDGE = 10;
const int LANDMARK = 11;

const vec3 WILD = vec3(0.105, 0.12, 0.14);
const vec3 HAZE = vec3(0.085, 0.095, 0.11);
const vec3 WATER_COL = vec3(0.125, 0.265, 0.365);
const vec3 SHORE_COL = vec3(0.21, 0.37, 0.48);
const vec3 WALK_COL = vec3(0.24, 0.27, 0.30);
const vec3 FOREST_COL = vec3(0.13, 0.175, 0.155);
// Woods inside a district read as green space, not as holes in the blocks.
const vec3 CITY_WOOD = vec3(0.165, 0.245, 0.19);
// City blocks (the ground of every developed lot) and the neutral tone of building footprints,
// tinted faintly by use.
const vec3 BLOCK_COL = vec3(0.165, 0.185, 0.215);
const vec3 BUILD_COL = vec3(0.305, 0.33, 0.37);

ivec2 texel(vec2 tile) {
	return ivec2(tile - world_origin);
}

bool inside(ivec2 t) {
	return t.x >= 0 && t.y >= 0 && t.x < int(world_size.x) && t.y < int(world_size.y);
}

vec4 data_at(ivec2 t) {
	return inside(t) ? texelFetch(data_tex, t, 0) : vec4(0.0);
}

int cls_at(ivec2 t) {
	return inside(t) ? int(round(texelFetch(data_tex, t, 0).r * 255.0)) : -1;
}

bool is_road(int c) {
	return c == ROAD || c == BRIDGE;
}

// Developed tiles: they join into city blocks.
bool is_block(int c) {
	return c == LOT || c == BUILDING || c == SERVICE || c == SITE || c == RUBBLE || c == LANDMARK || c == PARK;
}

// A building of level 2 or more (dense neighbours join into a street wall).
bool dense_at(ivec2 t) {
	vec4 d = data_at(t);
	return int(round(d.r * 255.0)) == BUILDING && int(round(d.g * 255.0)) >= 2;
}

vec2 hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

float water_of(ivec2 t) {
	int c = cls_at(t);
	return (c == WATER || c == BRIDGE) ? 1.0 : 0.0;
}

float forest_of(ivec2 t) {
	return cls_at(t) == FOREST ? 1.0 : 0.0;
}

// Cubic B-spline weights: masks sampled over 4 x 4 tiles come out soft and rounded, and single
// scattered trees fade out instead of speckling the map.
vec4 bspline(float f) {
	float f2 = f * f;
	float f3 = f2 * f;
	return vec4((1.0 - f) * (1.0 - f) * (1.0 - f), 3.0 * f3 - 6.0 * f2 + 4.0, -3.0 * f3 + 3.0 * f2 + 3.0 * f + 1.0, f3) / 6.0;
}

// The 4 x 4 B-spline of a mask (which: 0 = woods, 1 = water) around world point w.
float smooth_mask(vec2 w, int which) {
	vec2 b = floor(w);
	vec2 f = w - b;
	vec4 wx = bspline(f.x);
	vec4 wy = bspline(f.y);
	ivec2 t = texel(b);
	float v = 0.0;
	for (int j = 0; j < 4; j++) {
		float row = 0.0;
		for (int i = 0; i < 4; i++) {
			ivec2 q = t + ivec2(i - 1, j - 1);
			row += (which == 0 ? forest_of(q) : water_of(q)) * wx[i];
		}
		v += row * wy[j];
	}
	return v;
}

float sd_segment(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}

float sd_box(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Distance to a tile's part of a joined shape: each side reaches past the tile (beyond the
// rounded corner) toward a joined neighbour, else stops at inset e from the centre.
float sd_joined(vec2 lp, bool xp, bool xn, bool yp, bool yn, float e, float r) {
	float far = 0.62 + r;
	vec2 lo = vec2(xn ? -far : -e, yn ? -far : -e);
	vec2 hi = vec2(xp ? far : e, yp ? far : e);
	return sd_box(lp - (lo + hi) * 0.5, (hi - lo) * 0.5, r);
}

// Coverage of an SDF (negative inside) with a one-pixel antialiased edge; px = tiles per pixel.
float cover(float d, float px) {
	return clamp(0.5 - d / px, 0.0, 1.0);
}

void fragment() {
	vec2 p = (UV - 0.5) * rect_size;
	vec2 w = center + p / ppt;
	float px = 1.0 / ppt;
	vec2 tile = floor(w + 0.5);
	vec2 lp = w - tile;
	ivec2 t = texel(tile);
	int c = cls_at(t);
	vec4 dat = data_at(t);
	int level = int(round(dat.g * 255.0));
	bool burning = dat.b > 0.0;
	int dist = int(round(dat.a * 255.0)) - 1;
	vec3 tile_col = inside(t) ? texelFetch(col_tex, t, 0).rgb : WILD;

	// Ground: the district's land colour (painted on plain land tiles; reused under lots).
	vec3 col = WILD;
	if (c == LAND) {
		col = tile_col;
	} else if (inside(t)) {
		col = mix(WILD, vec3(0.125, 0.145, 0.165), dist >= 0 ? 1.0 : 0.0);
	}

	// Woods: smooth blobs.
	float fv = smooth_mask(w, 0);
	float fw = max(fwidth(fv), 1e-4);
	col = mix(col, dist >= 0 ? CITY_WOOD : FOREST_COL, 0.8 * clamp((fv - 0.45) / fw + 0.5, 0.0, 1.0));

	// Water with a soft lighter shore line.
	// The B-spline narrows water, so its edge sits lower: a one-tile river keeps about a tile.
	float wv = smooth_mask(w, 1);
	float ww = max(fwidth(wv), 1e-4);
	float water = clamp((wv - 0.4) / ww + 0.5, 0.0, 1.0);
	float shore = clamp(1.0 - abs(wv - 0.4) / (ww * 1.6), 0.0, 1.0) * smoothstep(2.0, 5.0, ppt);
	col = mix(col, WATER_COL, water);
	col = mix(col, SHORE_COL, shore * 0.6);

	// City blocks: every developed tile joins its developed neighbours into one block, inset only
	// where it meets a road or open land, so a street block reads as one calm shape at any zoom.
	float detail = smoothstep(4.5, 9.0, ppt);
	if (is_block(c)) {
		float db = sd_joined(lp, is_block(cls_at(t + ivec2(1, 0))), is_block(cls_at(t + ivec2(-1, 0))),
				is_block(cls_at(t + ivec2(0, 1))), is_block(cls_at(t + ivec2(0, -1))), 0.43, 0.07);
		col = mix(col, BLOCK_COL, cover(db, px));
		if (c == PARK) {
			float dp = sd_joined(lp, cls_at(t + ivec2(1, 0)) == PARK, cls_at(t + ivec2(-1, 0)) == PARK,
					cls_at(t + ivec2(0, 1)) == PARK, cls_at(t + ivec2(0, -1)) == PARK, 0.41, 0.12);
			col = mix(col, tile_col, cover(dp, px));
		} else if (c != LOT) {
			// A footprint per lot, varied per tile and pulled toward the street; dense buildings join
			// their dense neighbours into a street wall. Zoomed out the lot just brightens its block.
			vec2 hv = hash2(tile);
			vec2 street = vec2(0.0);
			if (is_road(cls_at(t + ivec2(1, 0)))) street.x += 1.0;
			if (is_road(cls_at(t + ivec2(-1, 0)))) street.x -= 1.0;
			if (is_road(cls_at(t + ivec2(0, 1)))) street.y += 1.0;
			if (is_road(cls_at(t + ivec2(0, -1)))) street.y -= 1.0;
			vec2 hs = vec2(0.4) + (hv - 0.5) * 0.06;
			vec2 off = vec2(0.0);
			if (c == BUILDING) {
				float s = level >= 3 ? 0.43 : (level == 2 ? 0.38 : 0.3);
				hs = vec2(s) + (hv - 0.5) * (level >= 3 ? 0.04 : 0.1);
				off = street * (level <= 1 ? 0.1 : 0.03) + (hash2(tile + 31.0) - 0.5) * (level <= 1 ? 0.06 : 0.02);
			} else if (c == LANDMARK) {
				hs = vec2(0.44);
			} else if (c == SITE) {
				hs = vec2(0.4);
			} else if (c == RUBBLE) {
				hs = vec2(0.3) + (hv - 0.5) * 0.1;
			}
			vec2 lo = off - hs;
			vec2 hi = off + hs;
			if (c == BUILDING && level >= 2) {
				if (dense_at(t + ivec2(1, 0))) hi.x = 0.62;
				if (dense_at(t + ivec2(-1, 0))) lo.x = -0.62;
				if (dense_at(t + ivec2(0, 1))) hi.y = 0.62;
				if (dense_at(t + ivec2(0, -1))) lo.y = -0.62;
			}
			float d = mix(db, sd_box(lp - (lo + hi) * 0.5, (hi - lo) * 0.5, 0.03), detail);
			vec3 fill = c == BUILDING || c == SERVICE ? mix(BUILD_COL, tile_col, 0.4) * (0.92 + 0.05 * float(level)) : tile_col;
			if (c == SITE && ppt >= 7.0) {
				fill = mix(fill, fill * 0.8, step(0.5, fract((lp.x + lp.y) * 3.5)));
			}
			if (burning) {
				fill = mix(fill, vec3(1.0, 0.36, 0.3), 0.7);
			}
			fill = mix(mix(BLOCK_COL, fill, 0.55), fill, detail);
			col = mix(col, fill * 0.45, cover(d - px * 1.1, px) * detail);
			col = mix(col, fill, cover(d, px));
		}
	}

	// Roads: a capsule from the tile centre toward every road neighbour, a filled corner where a
	// road is two or more tiles wide, and sidewalks at zoom.
	if (is_road(c)) {
		float rd = length(lp);
		if (is_road(cls_at(t + ivec2(0, -1)))) rd = min(rd, sd_segment(lp, vec2(0.0), vec2(0.0, -0.51)));
		if (is_road(cls_at(t + ivec2(0, 1)))) rd = min(rd, sd_segment(lp, vec2(0.0), vec2(0.0, 0.51)));
		if (is_road(cls_at(t + ivec2(1, 0)))) rd = min(rd, sd_segment(lp, vec2(0.0), vec2(0.51, 0.0)));
		if (is_road(cls_at(t + ivec2(-1, 0)))) rd = min(rd, sd_segment(lp, vec2(0.0), vec2(-0.51, 0.0)));
		ivec2 qx = ivec2(lp.x >= 0.0 ? 1 : -1, 0);
		ivec2 qy = ivec2(0, lp.y >= 0.0 ? 1 : -1);
		if (is_road(cls_at(t + qx)) && is_road(cls_at(t + qy)) && is_road(cls_at(t + qx + qy))) rd = 0.0;
		float walk = cover(rd - 0.5, px) * smoothstep(5.0, 10.0, ppt);
		col = mix(col, WALK_COL, walk);
		float hw = mix(0.36, 0.3, smoothstep(3.0, 8.0, ppt));
		col = mix(col, tile_col, cover(rd - hw, px));
	}

	// District borders (full map).
	if (borders && inside(t) && ppt >= 2.5) {
		ivec2 sx = ivec2(lp.x >= 0.0 ? 1 : -1, 0);
		ivec2 sy = ivec2(0, lp.y >= 0.0 ? 1 : -1);
		float lw = px * 1.1;
		float e = 0.0;
		if (int(round(data_at(t + sx).a * 255.0)) - 1 != dist && inside(t + sx)) e = max(e, cover(0.5 - abs(lp.x) - lw, px));
		if (int(round(data_at(t + sy).a * 255.0)) - 1 != dist && inside(t + sy)) e = max(e, cover(0.5 - abs(lp.y) - lw, px));
		col = mix(col, vec3(0.92, 0.95, 1.0), e * 0.16);
	}

	// Haze over unsurveyed plots (soft, one texel per plot).
	float sv = inside(t) ? texture(survey_tex, (w - world_origin + 0.5) / world_size).r : 0.0;
	float haze = 1.0 - smoothstep(0.2, 0.8, sv);
	col = mix(col, HAZE, haze * 0.45);

	// Shape mask and rim shading.
	float a = opacity;
	if (shape == 0) {
		// The map inside the circle, a soft shadow under it and a thin light ring on its edge,
		// composited here so the minimap is one draw.
		float r = length(p);
		float rad = min(rect_size.x, rect_size.y) * 0.5 - pad;
		col *= mix(1.0, 1.0 - rim_shade, smoothstep(rad * 0.62, rad, r));
		float inside = clamp(rad - r + 0.5, 0.0, 1.0);
		a *= inside;
		float sh = 1.0 - smoothstep(0.0, 7.0, r - rad);
		float sa = 0.3 * sh * sh * (1.0 - inside);
		float oa = a + sa * (1.0 - a);
		col = oa > 0.0 ? col * a / oa : col;
		float ring = clamp(1.25 - abs(r - (rad - 0.75)), 0.0, 1.0) * ring_alpha;
		float ra = ring + oa * (1.0 - ring);
		col = ra > 0.0 ? (vec3(1.0) * ring + col * oa * (1.0 - ring)) / ra : col;
		a = ra;
	} else {
		float d = sd_box(p, rect_size * 0.5, corner);
		a *= clamp(0.5 - d, 0.0, 1.0);
	}
	COLOR = vec4(col, a);
}
