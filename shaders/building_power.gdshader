shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// GridFall Plot Plinth & Building Power-Down Shader (matches concepts/04_shader_and_hud_sheet.png)
uniform float blackout_intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec3 base_slate : source_color = vec3(0.12, 0.15, 0.21);
uniform vec3 trim_cyan : source_color = vec3(0.0, 0.941, 1.0);
uniform vec3 alert_red : source_color = vec3(1.0, 0.180, 0.329);

void fragment() {
	vec2 border_dist = min(UV, 1.0 - UV);
	float edge = 1.0 - smoothstep(0.02, 0.07, min(border_dist.x, border_dist.y));
	float beacon_pulse = 0.5 + 0.5 * sin(TIME * 6.0);
	vec3 active_col = mix(trim_cyan, alert_red, blackout_intensity);
	float power_level = mix(1.4, 0.25 + 0.55 * beacon_pulse, blackout_intensity);

	ALBEDO = mix(base_slate, active_col * 0.2, edge);
	ROUGHNESS = 0.72;
	METALLIC = 0.25;
	EMISSION = active_col * edge * power_level;
}
