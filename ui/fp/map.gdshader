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
// Zoomed out every built lot takes this neutral tone, so blocks read as one shape.
const vec3 BLOCK_COL = vec3(0.235, 0.26, 0.295);

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
	col = mix(col, FOREST_COL, 0.8 * clamp((fv - 0.45) / fw + 0.5, 0.0, 1.0));

	// Water with a soft lighter shore line.
	// The B-spline narrows water, so its edge sits lower: a one-tile river keeps about a tile.
	float wv = smooth_mask(w, 1);
	float ww = max(fwidth(wv), 1e-4);
	float water = clamp((wv - 0.4) / ww + 0.5, 0.0, 1.0);
	float shore = clamp(1.0 - abs(wv - 0.4) / (ww * 1.6), 0.0, 1.0) * smoothstep(2.0, 5.0, ppt);
	col = mix(col, WATER_COL, water);
	col = mix(col, SHORE_COL, shore * 0.6);

	// Lots and footprints. Zoomed out they fill their tiles, so a street block reads as one shape;
	// zoomed in each lot separates into its own footprint.
	float merge = 1.0 - smoothstep(4.5, 9.0, ppt);
	if (c == LOT) {
		// Zoned but empty: a faint plot outline only when zoomed in.
		col = mix(col, tile_col, cover(sd_box(lp, vec2(0.46), 0.05), px) * (1.0 - merge));
	} else if (c == PARK) {
		col = mix(col, tile_col, cover(sd_box(lp, vec2(mix(0.47, 0.51, merge)), 0.12 * (1.0 - merge)), px));
	} else if (c == BUILDING || c == SERVICE || c == LANDMARK || c == RUBBLE || c == SITE) {
		float h = c == BUILDING ? (level >= 3 ? 0.43 : (level == 2 ? 0.4 : 0.36)) : (c == RUBBLE ? 0.36 : 0.42);
		h = mix(h, 0.51, merge);
		float d = sd_box(lp, vec2(h), 0.05 * (1.0 - merge));
		vec3 fill = mix(tile_col, BLOCK_COL * (0.9 + 0.06 * float(level)), merge * 0.8);
		if (c == SITE && ppt >= 7.0) {
			float stripe = step(0.5, fract((lp.x + lp.y) * 3.5));
			fill = mix(tile_col, tile_col * 0.78, stripe);
		}
		if (burning) {
			fill = mix(fill, vec3(1.0, 0.36, 0.3), 0.7);
		}
		col = mix(col, fill * 0.62, cover(d - px * 1.1, px) * smoothstep(3.0, 6.0, ppt));
		col = mix(col, fill, cover(d, px));
	}

	// Roads: a capsule from the tile centre toward every road neighbour; sidewalks at zoom.
	if (is_road(c)) {
		float rd = length(lp);
		if (is_road(cls_at(t + ivec2(0, -1)))) rd = min(rd, sd_segment(lp, vec2(0.0), vec2(0.0, -0.51)));
		if (is_road(cls_at(t + ivec2(0, 1)))) rd = min(rd, sd_segment(lp, vec2(0.0), vec2(0.0, 0.51)));
		if (is_road(cls_at(t + ivec2(1, 0)))) rd = min(rd, sd_segment(lp, vec2(0.0), vec2(0.51, 0.0)));
		if (is_road(cls_at(t + ivec2(-1, 0)))) rd = min(rd, sd_segment(lp, vec2(0.0), vec2(-0.51, 0.0)));
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
		float r = length(p);
		float rad = min(rect_size.x, rect_size.y) * 0.5;
		a *= clamp(rad - r - 0.5, 0.0, 1.0);
		col *= mix(1.0, 1.0 - rim_shade, smoothstep(rad * 0.62, rad, r));
	} else {
		float d = sd_box(p, rect_size * 0.5, corner);
		a *= clamp(0.5 - d, 0.0, 1.0);
	}
	COLOR = vec4(col, a);
}
