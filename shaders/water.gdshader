shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;
// River and lake surface: two scrolling normal maps, a fresnel sky sheen and a night-aware tint.
// With depth_fade set, the colour deepens and the surface turns opaque with the water depth read
// from the depth buffer, a band of foam rims the banks, and rain stipples the surface with rings.

uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec3 deep_color : source_color = vec3(0.10, 0.30, 0.38);
uniform vec3 shallow_color : source_color = vec3(0.22, 0.48, 0.52);
uniform vec3 foam_color : source_color = vec3(0.82, 0.86, 0.84);
// Normal-map repeats per world unit and scroll speed in repeats per second.
uniform float tiling = 0.35;
uniform float speed = 0.03;
uniform float night = 0.0;
// Water depth (world units) at which the colour is fully deep and the surface opaque; 0 disables
// the depth read. Foam rims the banks out to foam_width of depth.
uniform float depth_fade = 0.0;
uniform float foam_width = 0.006;
uniform float rain = 0.0;

varying vec3 world_pos;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// The normal map is imported two-channel (RGTC), with no blue: rebuild it as the encoded value an
// RGB normal map carries, so the mix below behaves as before.
vec3 normal_at(vec2 uv) {
	vec2 xy = texture(normal_tex, uv).rg;
	vec2 d = xy * 2.0 - 1.0;
	return vec3(xy, sqrt(max(0.0, 1.0 - dot(d, d))) * 0.5 + 0.5);
}

void fragment() {
	vec2 uv = world_pos.xz * tiling;
	vec3 n1 = normal_at(uv + vec2(TIME * speed, TIME * speed * 0.6));
	vec3 n2 = normal_at(uv * 1.7 - vec2(TIME * speed * 0.8, -TIME * speed * 0.4));
	vec3 nm = normalize(mix(n1, n2, 0.5));
	if (rain > 0.0) {
		// Expanding rings in a jittered grid of 16 cm cells, each on its own clock.
		vec2 cell = world_pos.xz * 125.0;
		vec2 id = floor(cell);
		vec2 c = fract(cell) - 0.5 - (vec2(hash12(id), hash12(id + 7.3)) - 0.5) * 0.5;
		float t = fract(TIME * 1.3 + hash12(id + 3.1));
		float ripple = smoothstep(0.07, 0.0, abs(length(c) - t * 0.4)) * (1.0 - t) * rain;
		nm.xy += normalize(c + 1e-4) * ripple * 0.22;
	}
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = 0.6;
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	float t_depth = 1.0;
	float foam = 0.0;
	if (depth_fade > 0.0) {
		float z = texture(depth_tex, SCREEN_UV).r;
		vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, z, 1.0);
		vp.xyz /= vp.w;
		vec3 scene = (INV_VIEW_MATRIX * vec4(vp.xyz, 1.0)).xyz;
		float depth = max(world_pos.y - scene.y, 0.0);
		t_depth = smoothstep(0.0, depth_fade, depth);
		float wobble = n1.r * 0.6 + n2.g * 0.4;
		foam = (1.0 - smoothstep(0.0, foam_width * (0.6 + wobble), depth)) * 0.85;
	}
	vec3 col = mix(shallow_color, deep_color, clamp(0.55 * t_depth + 0.45 * fres, 0.0, 1.0));
	col = mix(col, foam_color, foam);
	ALBEDO = col * mix(1.0, 0.45, smoothstep(0.5, 1.0, night));
	METALLIC = 0.0;
	ROUGHNESS = mix(0.04, 0.55, foam);
	SPECULAR = 0.8;
	ALPHA = depth_fade > 0.0 ? clamp(mix(0.5, 0.97, t_depth) + foam * 0.1, 0.0, 1.0) : 0.94;
}
