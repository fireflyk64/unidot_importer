// The ribbon of a LineRenderer whose material adds to what is behind it (see the include).
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never, blend_add;

#include "line_renderer.gdshaderinc"

void fragment() {
	vec4 c = line_color(UV, COLOR);
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
