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
uniform float rim_shade = 0.45;
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

const vec3 WILD = vec3(0.098, 0.118, 0.141);
const vec3 HAZE = vec3(0.075, 0.09, 0.11);
const vec3 WATER_COL = vec3(0.110, 0.243, 0.341);
const vec3 SHORE_COL = vec3(0.20, 0.36, 0.47);
const vec3 WALK_COL = vec3(0.235, 0.267, 0.302);
const vec3 FOREST_COL = vec3(0.153, 0.267, 0.192);

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

// Bilinear blend of a per-tile mask between tile centres: smooth, rounded outlines.
float smooth_water(vec2 w) {
	vec2 b = floor(w);
	vec2 f = w - b;
	ivec2 t = texel(b);
	float a = mix(water_of(t), water_of(t + ivec2(1, 0)), f.x);
	float c = mix(water_of(t + ivec2(0, 1)), water_of(t + ivec2(1, 1)), f.x);
	return mix(a, c, f.y);
}

float smooth_forest(vec2 w) {
	vec2 b = floor(w);
	vec2 f = w - b;
	ivec2 t = texel(b);
	float a = mix(forest_of(t), forest_of(t + ivec2(1, 0)), f.x);
	float c = mix(forest_of(t + ivec2(0, 1)), forest_of(t + ivec2(1, 1)), f.x);
	return mix(a, c, f.y);
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
		col = mix(WILD, vec3(0.118, 0.141, 0.169), dist >= 0 ? 1.0 : 0.0);
	}

	// Woods: smooth blobs.
	float fv = smooth_forest(w);
	float fw = max(fwidth(fv), 1e-4);
	col = mix(col, FOREST_COL, clamp((fv - 0.45) / fw + 0.5, 0.0, 1.0));

	// Water with a soft lighter shore line.
	float wv = smooth_water(w);
	float ww = max(fwidth(wv), 1e-4);
	float water = clamp((wv - 0.5) / ww + 0.5, 0.0, 1.0);
	float shore = clamp(1.0 - abs(wv - 0.5) / (ww * 1.6), 0.0, 1.0) * smoothstep(2.0, 5.0, ppt);
	col = mix(col, WATER_COL, water);
	col = mix(col, SHORE_COL, shore * 0.6);

	// Lots and footprints.
	if (c == LOT) {
		col = mix(col, tile_col, cover(sd_box(lp, vec2(0.46), 0.05), px));
	} else if (c == PARK) {
		col = mix(col, tile_col, cover(sd_box(lp, vec2(0.47), 0.12), px));
	} else if (c == BUILDING || c == SERVICE || c == LANDMARK || c == RUBBLE || c == SITE) {
		float h = c == BUILDING ? (level >= 3 ? 0.43 : (level == 2 ? 0.4 : 0.36)) : (c == RUBBLE ? 0.36 : 0.42);
		float d = sd_box(lp, vec2(h), 0.05);
		vec3 fill = tile_col;
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
		col = mix(col, vec3(0.92, 0.95, 1.0), e * 0.35);
	}

	// Haze over unsurveyed plots (soft, one texel per plot).
	float sv = inside(t) ? texture(survey_tex, (w - world_origin + 0.5) / world_size).r : 0.0;
	float haze = 1.0 - smoothstep(0.2, 0.8, sv);
	col = mix(col, HAZE, haze * 0.7);

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
