// A Unity LineRenderer's ribbon (runtime/line_renderer.gd): every point of the line is two
// vertices at the same place; NORMAL holds the line's direction there and UV2.x half its width
// (signed by the side). The ribbon is opened here, across the line and across the view, so
// it faces the camera wherever that is (alignment View), or across the object's z axis
// (alignment Transform Z).
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never;

uniform bool face_z = false;

void vertex() {
	vec3 centre = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 along = mat3(MODELVIEW_MATRIX) * NORMAL;
	// (an orthographic camera looks along its z axis from everywhere)
	vec3 facing = PROJECTION_MATRIX[3][3] != 0.0 ? vec3(0.0, 0.0, -1.0) : centre;
	if (face_z) {
		facing = mat3(MODELVIEW_MATRIX) * vec3(0.0, 0.0, 1.0);
	}
	vec3 side = cross(along, facing);
	float len = length(side);
	side = len > 1e-9 ? side / len : vec3(1.0, 0.0, 0.0);
	// a line in its object's space is as wide as the object is scaled
	centre += side * UV2.x * length(MODEL_MATRIX[0].xyz);
	POSITION = PROJECTION_MATRIX * vec4(centre, 1.0);
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;
}
