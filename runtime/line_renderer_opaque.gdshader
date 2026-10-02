// The ribbon of a LineRenderer that is opaque: its material and every colour of its gradient
// (see the include).
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

#include "line_renderer.gdshaderinc"

void fragment() {
	ALBEDO = line_color(UV, COLOR).rgb;
}
