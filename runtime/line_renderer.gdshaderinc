// A Unity LineRenderer's ribbon (runtime/line_renderer.gd). Every vertex lies on the line and
// says how it leaves it:
//   NORMAL      the direction the line arrives with at this point
//   CUSTOM0.xyz the direction it goes on with; CUSTOM0.w: how far the vertex is round the
//               corner from the edge of the arriving segment (0) to that of the leaving one (1)
//   UV2.x       its distance across the line (signed by the side), UV2.y along it (a cap)
//   CUSTOM1.xy  how fast the texture runs along the arriving and the leaving segment (a
//               vertex that is moved along the line takes the texture with it)
// The ribbon is opened here, across the line and across the view, so it faces the camera
// wherever that is (alignment View), or across the object's z axis (alignment Transform Z).
uniform bool face_z = false;
uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 uv_st = vec4(1.0, 1.0, 0.0, 0.0);

void vertex() {
	vec3 centre = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// (an orthographic camera looks along its z axis from everywhere)
	vec3 facing = PROJECTION_MATRIX[3][3] != 0.0 ? vec3(0.0, 0.0, -1.0) : centre;
	if (face_z) {
		facing = mat3(MODELVIEW_MATRIX) * vec3(0.0, 0.0, 1.0);
	}
	vec3 arrive = mat3(MODELVIEW_MATRIX) * NORMAL;
	vec3 leave = mat3(MODELVIEW_MATRIX) * CUSTOM0.xyz;
	vec3 side_a = cross(arrive, facing);
	vec3 side_b = cross(leave, facing);
	float len_a = length(side_a);
	float len_b = length(side_b);
	side_a = len_a > 1e-9 ? side_a / len_a : vec3(1.0, 0.0, 0.0);
	side_b = len_b > 1e-9 ? side_b / len_b : side_a;
	vec3 side = mix(side_a, side_b, CUSTOM0.w);
	float len = length(side);
	side = len > 1e-6 ? side / len : side_a;
	// the inner side of a bend: the edges of the two segments would cross, both end where
	// they meet instead (the outer side goes round the corner)
	float turn = dot(cross(arrive, leave), facing);
	float moved = 0.0;
	if (turn * UV2.x < -1e-9) {
		vec3 mitre = side_a + side_b;
		float m = length(mitre);
		if (m > 1e-6) {
			mitre /= m;
			side = mitre / max(dot(mitre, side_a), 0.35);
			// (that point is before the corner on the arriving segment, after it on the
			// leaving one)
			vec3 own = CUSTOM0.w < 0.5 ? arrive : leave;
			float own_len = length(own);
			moved = own_len > 1e-9 ? dot(side * UV2.x, own / own_len) * (CUSTOM0.w < 0.5 ? CUSTOM1.x : CUSTOM1.y) : 0.0;
		}
	}
	vec3 along = cross(facing, side_a);
	float len_along = length(along);
	along = len_along > 1e-9 ? along / len_along : vec3(0.0);
	// a line in its object's space is as wide as the object is scaled
	centre += (side * UV2.x + along * UV2.y) * length(MODEL_MATRIX[0].xyz);
	POSITION = PROJECTION_MATRIX * vec4(centre, 1.0);
	// (a cap goes on with the texture of its end)
	UV.x += moved + UV2.y * CUSTOM1.x;
	UV = UV * uv_st.xy + uv_st.zw;
}

vec4 line_color(vec2 uv, vec4 tint) {
	return texture(albedo_texture, uv) * albedo * tint;
}
