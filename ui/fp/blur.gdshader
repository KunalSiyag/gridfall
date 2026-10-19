// Frosted backdrop for slice B's modal screens (pause menu, full map): a soft blur of what is
// already on screen, darkened toward `tint`, with an optional left-side gradient for menus.
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float lod = 2.6;
uniform vec4 tint : source_color = vec4(0.03, 0.04, 0.06, 0.55);
uniform float side_shade = 0.0;
uniform float fade = 1.0;

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE * exp2(lod);
	vec3 acc = vec3(0.0);
	float wsum = 0.0;
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			float wgt = exp(-float(x * x + y * y) / 4.5);
			acc += textureLod(screen_tex, SCREEN_UV + vec2(float(x), float(y)) * px, lod).rgb * wgt;
			wsum += wgt;
		}
	}
	vec3 blurred = acc / wsum;
	vec3 base = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
	float shade = tint.a + side_shade * (1.0 - smoothstep(0.0, 0.62, UV.x));
	vec3 col = mix(blurred, tint.rgb, clamp(shade, 0.0, 0.94));
	COLOR = vec4(mix(base, col, fade), 1.0);
}
