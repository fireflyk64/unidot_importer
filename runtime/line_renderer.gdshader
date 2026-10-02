// The ribbon of a LineRenderer, blended over what is behind it (see the include).
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never;

#include "line_renderer.gdshaderinc"

void fragment() {
	vec4 c = line_color(UV, COLOR);
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
