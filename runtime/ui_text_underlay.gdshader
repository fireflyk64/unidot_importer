// The underlay of a TextMeshPro text with softness (runtime/ui_text.gd): the group holds the
// text in the underlay's colour, as far out as the underlay reaches; this shader draws the
// group's picture blurred over a disc as wide as the softness, which makes the hard edge the
// ramp TextMeshPro's shader draws about it.
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
// (pixels of the viewport)
uniform float radius = 2.0;

void fragment() {
	vec4 sum = textureLod(screen_texture, SCREEN_UV, 0.0);
	float taps = 1.0;
	for (int ring = 1; ring <= 3; ring++) {
		float r = radius * float(ring) / 3.0;
		int count = ring * 6;
		for (int i = 0; i < count; i++) {
			float a = 6.2831853 * (float(i) + 0.5 * float(ring)) / float(count);
			sum += textureLod(screen_texture, SCREEN_UV + vec2(cos(a), sin(a)) * r * SCREEN_PIXEL_SIZE, 0.0);
			taps += 1.0;
		}
	}
	vec4 c = sum / taps;
	// (the group's picture holds colours multiplied by their alpha)
	if (c.a > 0.0001) {
		c.rgb /= c.a;
	}
	COLOR *= c;
}
