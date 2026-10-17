shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// GridFall Road Energy Conduit Shader (matches concepts/04_shader_and_hud_sheet.png)
uniform float blackout_intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec3 asphalt_color : source_color = vec3(0.075, 0.090, 0.133);
uniform vec3 nominal_cyan : source_color = vec3(0.0, 0.941, 1.0);
uniform vec3 crisis_crimson : source_color = vec3(1.0, 0.180, 0.329);
uniform float pulse_speed : hint_range(0.2, 6.0) = 1.8;

void fragment() {
	vec2 uv = UV;
	// Dual embedded power traces along the road lanes
	float lane_a = smoothstep(0.045, 0.012, abs(uv.x - 0.32));
	float lane_b = smoothstep(0.045, 0.012, abs(uv.x - 0.68));
	float cross_a = smoothstep(0.045, 0.012, abs(uv.y - 0.32));
	float cross_b = smoothstep(0.045, 0.012, abs(uv.y - 0.68));
	float trace_mask = clamp(max(lane_a + lane_b, cross_a + cross_b), 0.0, 1.0);

	// Travelling energy packet wave
	float wave = 0.5 + 0.5 * sin((uv.x + uv.y) * 18.0 - TIME * pulse_speed * 3.0);
	// Brownout flicker when blackout_intensity > 0.3
	float flicker = 1.0 - blackout_intensity * (0.45 + 0.35 * sin(TIME * 17.0 + uv.x * 11.0));
	vec3 glow_col = mix(nominal_cyan, crisis_crimson, smoothstep(0.25, 0.85, blackout_intensity));
	float glow_strength = mix(2.2, 0.65, blackout_intensity) * (0.45 + 0.55 * wave) * max(0.15, flicker);

	ALBEDO = mix(asphalt_color, glow_col * 0.25, trace_mask);
	ROUGHNESS = mix(0.82, 0.25, trace_mask);
	METALLIC = mix(0.15, 0.65, trace_mask);
	EMISSION = glow_col * trace_mask * glow_strength;
}
