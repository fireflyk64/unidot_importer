## Unity's LineRenderer on a MeshInstance3D: what the line is lives in the node's `unidot_line`
## metadata, and `draw` makes the mesh from it. The importer writes the metadata and draws
## once; whatever moves the points at run time changes the metadata (or a copy) and draws again
## through the same function.
##
## The metadata: {positions: Array of Vector3 in Unity's coordinates (x to the left of Godot's),
## world_space, loop, width (Unity's widthMultiplier), width_curve (a Curve over the line's
## length, times `width`; null: 1), gradient (a Gradient over the line's length; null: white),
## alignment (0: the ribbon faces the camera, 1: it lies across the object's z axis)}.
## Not drawn: the line's material and texture, rounded corners and caps.
@tool
extends RefCounted

const META := &"unidot_line"
const SHADER := preload("./line_renderer.gdshader")


static func defaults() -> Dictionary:
	return {"positions": [], "world_space": true, "loop": false, "width": 1.0, "width_curve": null, "gradient": null, "alignment": 0}


## The line of a node (a copy; defaults when it has none).
static func info_of(node: Node) -> Dictionary:
	var info: Dictionary = defaults()
	if node != null and node.has_meta(META) and node.get_meta(META) is Dictionary:
		info.merge((node.get_meta(META) as Dictionary), true)
	return info


## The width of the line at `t` (0: its first point, 1: its last, by length).
static func width_at(info: Dictionary, t: float) -> float:
	var curve: Curve = info.get("width_curve") as Curve
	var w: float = float(info.get("width", 1.0))
	if curve != null and curve.point_count > 0:
		w *= curve.sample_baked(clampf(t, curve.min_domain, curve.max_domain)) if curve.point_count > 1 else curve.get_point_position(0).y
	return w


static func color_at(info: Dictionary, t: float) -> Color:
	var gradient: Gradient = info.get("gradient") as Gradient
	return gradient.sample(clampf(t, 0.0, 1.0)) if gradient != null and gradient.get_point_count() > 0 else Color.WHITE


## The points the ribbon goes through, in Godot's coordinates: those that are set, the first
## one again at the end of a loop.
static func points(info: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p in info.get("positions", []):
		if p is Vector3:
			out.append(Vector3(-p.x, p.y, p.z))
	if bool(info.get("loop", false)) and out.size() > 2:
		out.append(out[0])
	return out


## The ribbon: two vertices per point (see line_renderer.gdshader), a point of a curve or a
## gradient key in between where the line needs one to follow them. Null without two points.
static func mesh(info: Dictionary) -> ArrayMesh:
	var pts: PackedVector3Array = points(info)
	if pts.size() < 2:
		return null
	var lengths := PackedFloat32Array([0.0])
	for i in range(1, pts.size()):
		lengths.append(lengths[i - 1] + pts[i].distance_to(pts[i - 1]))
	var total: float = lengths[lengths.size() - 1]
	# where the width or the colour has a key, the ribbon gets a point: a taper or a fade
	# in the middle of a segment is not straight from end to end
	var stops: Array = []
	var curve: Curve = info.get("width_curve") as Curve
	if curve != null:
		for i in range(curve.point_count):
			stops.append(curve.get_point_position(i).x)
		# (a curve bends between its keys)
		if curve.point_count > 1 and not _is_linear(curve):
			for i in range(1, 16):
				stops.append(float(i) / 16.0)
	var gradient: Gradient = info.get("gradient") as Gradient
	if gradient != null:
		for i in range(gradient.get_point_count()):
			stops.append(gradient.get_offset(i))
	var where: Array = []   # [t, point, direction]
	for i in range(pts.size()):
		var t: float = lengths[i] / total if total > 0.0 else float(i) / float(pts.size() - 1)
		var before: Vector3 = pts[i] - pts[i - 1] if i > 0 else Vector3.ZERO
		var after: Vector3 = pts[i + 1] - pts[i] if i + 1 < pts.size() else Vector3.ZERO
		var along: Vector3 = before.normalized() + after.normalized()
		if along.length_squared() < 1e-12:
			along = after if after.length_squared() > 0.0 else before
		where.append([t, pts[i], along.normalized()])
		if i + 1 < pts.size() and total > 0.0:
			var t1: float = lengths[i + 1] / total
			var inside: Array = stops.filter(func(s) -> bool: return s > t + 1e-5 and s < t1 - 1e-5)
			inside.sort()
			var last: float = t
			for s in inside:
				if s - last < 1e-5:
					continue
				last = s
				where.append([s, pts[i].lerp(pts[i + 1], (s - t) / (t1 - t)), after.normalized()])
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var sides := PackedVector2Array()
	var indices := PackedInt32Array()
	var widest: float = 0.0
	for i in range(where.size()):
		var t: float = where[i][0]
		var half: float = width_at(info, t) * 0.5
		widest = maxf(widest, absf(half))
		var color: Color = color_at(info, t)
		for side in [-1.0, 1.0]:
			vertices.append(where[i][1])
			normals.append(where[i][2])
			colors.append(color)
			uvs.append(Vector2(t, 0.5 + 0.5 * side))
			sides.append(Vector2(half * side, 0.0))
		if i > 0:
			var a: int = (i - 1) * 2
			indices.append_array(PackedInt32Array([a, a + 1, a + 2, a + 1, a + 3, a + 2]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = sides
	arrays[Mesh.ARRAY_INDEX] = indices
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# (the vertices lie on the line: the ribbon reaches half its width beyond them)
	out.custom_aabb = out.get_aabb().grow(widest)
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter(&"face_z", int(info.get("alignment", 0)) == 1)
	out.surface_set_material(0, material)
	return out


static func _is_linear(curve: Curve) -> bool:
	for i in range(curve.point_count - 1):
		var a: Vector2 = curve.get_point_position(i)
		var b: Vector2 = curve.get_point_position(i + 1)
		var slope: float = (b.y - a.y) / (b.x - a.x) if b.x > a.x else 0.0
		if absf(curve.get_point_right_tangent(i) - slope) > 0.01 or absf(curve.get_point_left_tangent(i + 1) - slope) > 0.01:
			return false
	return true


## Draws `info` (the node's own metadata when null) on the node. Positions of the world are
## drawn where they are, whatever the object does; those of the object move with it.
static func draw(node: MeshInstance3D, info = null) -> void:
	var line: Dictionary = info if info is Dictionary else info_of(node)
	node.mesh = mesh(line)
	var world: bool = bool(line.get("world_space", true))
	if node.top_level != world:
		node.top_level = world
	if world:
		if node.is_inside_tree():
			node.global_transform = Transform3D.IDENTITY
		else:
			node.transform = Transform3D.IDENTITY
	elif node.transform != Transform3D.IDENTITY:
		node.transform = Transform3D.IDENTITY
