shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;
// River and lake surface. Orbit: two scrolling normal maps, a fresnel sheen and a night-aware tint.
// On foot (depth_fade > 0) the colour deepens and the surface turns opaque with the water depth
// read from the depth buffer; a streaked band of foam rims the banks and the hero's legs; a
// world-noise tint runs from clear teal through silty brown at the banks to dark mid-channel; a
// finer third normal layer rides the wind and a fourth drifts with the current (the mesh's vertex
// colour, scripts/world/water_surface.gd); rain stipples the surface with rings; and the hero's
// footfalls send expanding rings (uniform `ripples`).
// Texture fetches per pixel on foot: 5 normal (two wind layers, two flow phases, one fine layer)
// + 1 noise + 1 depth = 7; in orbit 2 normal.

uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec3 deep_color : source_color = vec3(0.10, 0.30, 0.38);
uniform vec3 shallow_color : source_color = vec3(0.22, 0.48, 0.52);
// Silty bank water, and the foam.
uniform vec3 silt_color : source_color = vec3(0.30, 0.25, 0.14);
uniform vec3 foam_color : source_color = vec3(0.82, 0.86, 0.84);
// Normal-map repeats per world unit and scroll speed in repeats per second.
uniform float tiling = 0.35;
uniform float speed = 0.03;
uniform float night = 0.0;
// Water depth (world units) at which the colour is fully deep and the surface opaque; 0 disables
// the depth read and the whole on-foot look. Foam rims the banks out to foam_width of depth.
uniform float depth_fade = 0.0;
uniform float foam_width = 0.007;
uniform float rain = 0.0;
// The web build renders with gl_compatibility, whose depth texture is in [0, 1] and unprojects
// with the screen uv remapped too; CityView sets this from RenderingServer.get_current_rendering_method().
uniform bool compat = false;
// How far (normal-map repeats) the current carries its pattern in one 8 s cycle.
uniform float flow_rep = 1.2;
// The hero's footfall rings: x, z, age in seconds (negative = unused), amplitude 0..1. ripple_on
// is 0 when none is alive, so an idle river pays one branch.
uniform vec4 ripples[4];
uniform float ripple_on = 0.0;

varying vec3 world_pos;
varying vec2 flow;
// 1 on a flood plane (a mesh without vertex colours reads white), 0 on the river mesh: a sheet of
// water a few millimetres deep over paving, which needs a much shorter depth scale to read as water.
varying float sheet;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// COLOR.rg is the current (0.5 = still) and COLOR.b is 0; a mesh without vertex colours (the
	// flood planes) reads white, which is still water.
	flow = COLOR.b > 0.5 ? vec2(0.0) : COLOR.rg * 2.0 - 1.0;
	sheet = COLOR.b > 0.5 ? 1.0 : 0.0;
}

// The normal map is imported two-channel (RGTC), with no blue: rebuild it as the encoded value an
// RGB normal map carries, so the mix below behaves as before.
vec3 normal_at(vec2 uv) {
	vec2 xy = texture(normal_tex, uv).rg;
	vec2 d = xy * 2.0 - 1.0;
	return vec3(xy, sqrt(max(0.0, 1.0 - dot(d, d))) * 0.5 + 0.5);
}

void fragment() {
	bool fp = depth_fade > 0.0;
	vec2 wp = world_pos.xz;
	vec2 uv = wp * tiling;
	vec3 n1 = normal_at(uv + vec2(TIME * speed, TIME * speed * 0.6));
	vec3 n2 = normal_at(uv * 1.7 - vec2(TIME * speed * 0.8, -TIME * speed * 0.4));
	vec3 nm = mix(n1, n2, 0.5);
	float streak = 0.0;
	if (fp) {
		// Drifting with the current: two phases half a cycle apart, so the pattern never smears
		// as the current turns at a bend.
		float fl = length(flow);
		float cyc = TIME * 0.125;
		float p1 = fract(cyc);
		float w1 = abs(1.0 - 2.0 * p1);
		vec2 fuv = uv * 2.3 + vec2(-flow.y, flow.x) * 0.37;
		vec3 nf = normal_at(fuv - flow * p1 * flow_rep) * w1;
		nf += normal_at(fuv - flow * fract(cyc + 0.5) * flow_rep) * (1.0 - w1);
		nm = mix(nm, nf, 0.35 + 0.25 * fl);
		// A third, finer layer (about 60 cm repeat on foot), faded out where it would alias.
		vec3 n3 = normal_at(uv * 13.0 + vec2(-TIME * speed * 3.0, TIME * speed * 2.2));
		float fade = 1.0 - smoothstep(0.15, 0.4, fwidth(wp.x) * tiling * 13.0);
		nm = nm + (n3 - vec3(0.5, 0.5, 1.0)) * 0.7 * fade;
		streak = n2.g - 0.5 + (nf.r - 0.5) * 0.7;
	}
	nm = normalize(nm);
	if (rain > 0.0) {
		// Expanding rings in a jittered grid of 16 cm cells, each on its own clock.
		vec2 cell = wp * 125.0;
		vec2 id = floor(cell);
		vec2 c = fract(cell) - 0.5 - (vec2(hash12(id), hash12(id + 7.3)) - 0.5) * 0.5;
		float t = fract(TIME * 1.3 + hash12(id + 3.1));
		float ripple = smoothstep(0.07, 0.0, abs(length(c) - t * 0.4)) * (1.0 - t) * rain;
		nm.xy += normalize(c + 1e-4) * ripple * 0.22;
	}
	if (ripple_on > 0.5) {
		// Rings of about 8 cm width that grow 1 m a second for 1.6 s, fading as they go.
		for (int i = 0; i < 4; i++) {
			vec4 r = ripples[i];
			if (r.z >= 0.0) {
				vec2 off = wp - r.xy;
				float d = length(off);
				float life = clamp(1.0 - r.z / 1.6, 0.0, 1.0);
				float ring = smoothstep(0.004, 0.0, abs(d - r.z * 0.05)) * life * life * r.w;
				nm.xy += off / max(d, 1e-5) * ring * 0.7;
			}
		}
	}
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = 0.6;
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), fp ? 3.0 : 4.0);
	float t_depth = 1.0;
	float foam = 0.0;
	vec3 col = mix(shallow_color, deep_color, clamp(0.55 + 0.45 * fres, 0.0, 1.0));
	if (fp) {
		float z = texture(depth_tex, SCREEN_UV).r;
		vec3 ndc = compat ? vec3(SCREEN_UV, z) * 2.0 - 1.0 : vec3(SCREEN_UV * 2.0 - 1.0, z);
		vec4 vp = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		vp.xyz /= vp.w;
		vec3 scene = (INV_VIEW_MATRIX * vec4(vp.xyz, 1.0)).xyz;
		float depth = max(world_pos.y - scene.y, 0.0);
		// A flood sheet is only millimetres deep: its depth scale, foam and silt shrink to match.
		float dfade = mix(depth_fade, depth_fade * 0.25, sheet);
		t_depth = smoothstep(0.0, dfade, depth);
		float wobble = n1.r * 0.6 + n2.g * 0.4;
		// A ragged line of foam hugging the bank (about 30 cm of depth, streaked with the current).
		foam = (1.0 - smoothstep(0.0, foam_width * (1.0 - 0.8 * sheet) * (0.6 + wobble + streak * 0.6), depth)) * 0.7;
		// World noise (one repeat per 25 m) steers the body: clear teal over green-blue, silt in
		// the shallows, dark where the water is deep.
		float nz = texture(noise_tex, wp * 0.8).r;
		vec3 clear = mix(shallow_color, deep_color * 1.7, smoothstep(0.15, 0.95, nz) * 0.75);
		float silt = smoothstep(0.5, 0.75, nz) * (1.0 - smoothstep(0.0, dfade * 1.5, depth)) * (1.0 - sheet);
		vec3 body = mix(clear, silt_color, silt * 0.8);
		col = mix(body, deep_color, clamp(0.65 * t_depth + 0.25 * fres, 0.0, 1.0));
	}
	col = mix(col, foam_color, foam);
	ALBEDO = col * mix(1.0, 0.45, smoothstep(0.5, 1.0, night));
	METALLIC = 0.0;
	// On foot the sky must not drown the body colour: a rougher, weaker mirror than the orbit's.
	ROUGHNESS = mix(fp ? 0.16 : 0.04, 0.55, foam);
	SPECULAR = fp ? 0.5 : 0.8;
	ALPHA = fp ? clamp(mix(0.5, 0.97, t_depth) + foam * 0.1, 0.0, 1.0) : 0.94;
}
