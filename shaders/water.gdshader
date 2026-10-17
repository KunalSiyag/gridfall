shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;
// River and lake surface: two scrolling normal maps, a fresnel sky sheen, and a night-aware tint.

uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 deep_color : source_color = vec3(0.10, 0.30, 0.38);
uniform vec3 shallow_color : source_color = vec3(0.22, 0.48, 0.52);
uniform float tiling = 0.35;
uniform float speed = 0.03;
uniform float night = 0.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = world_pos.xz * tiling;
	vec3 n1 = texture(normal_tex, uv + vec2(TIME * speed, TIME * speed * 0.6)).rgb;
	vec3 n2 = texture(normal_tex, uv * 1.7 - vec2(TIME * speed * 0.8, -TIME * speed * 0.4)).rgb;
	NORMAL_MAP = normalize(mix(n1, n2, 0.5));
	NORMAL_MAP_DEPTH = 0.6;
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	vec3 col = mix(shallow_color, deep_color, 0.55 + 0.45 * fres);
	ALBEDO = col * mix(1.0, 0.45, smoothstep(0.5, 1.0, night));
	METALLIC = 0.0;
	ROUGHNESS = 0.04;
	SPECULAR = 0.8;
	ALPHA = 0.94;
}
