## Unity's LineRenderer on a MeshInstance3D: what the line is lives in the node's `unidot_line`
## metadata, and `draw` makes the mesh from it. The importer writes the metadata and draws
## once; whatever moves the points at run time changes the metadata (or a copy) and draws again
## through the same function.
##
## The metadata: {positions: Array of Vector3 in Unity's coordinates (x to the left of Godot's),
## world_space, loop, width (Unity's widthMultiplier), width_curve (a Curve over the line's
## length, times `width`; null: 1), gradient (a Gradient over the line's length; null: white),
## alignment (0: the ribbon faces the camera, 1: it lies across the object's z axis),
## corner_vertices, cap_vertices (how many vertices round a corner and a cap off; 0: corners
## as they come, flat ends), texture_mode (0: the texture is stretched over the line, 1: once
## per unit of length, 2: spread evenly over the points, 3: once per segment),
## texture_scale (Vector2), material (the Material of the renderer: its colour, its texture
## with its tiling and how it blends are taken from it; the ribbon is always unlit)}.
@tool
extends RefCounted

const META := &"unidot_line"
const SHADER := preload("./line_renderer.gdshader")
const SHADER_ADD := preload("./line_renderer_add.gdshader")
const SHADER_OPAQUE := preload("./line_renderer_opaque.gdshader")

const STRETCH := 0
const TILE := 1
const DISTRIBUTE_PER_SEGMENT := 2
const REPEAT_PER_SEGMENT := 3


static func defaults() -> Dictionary:
	return {"positions": [], "world_space": true, "loop": false, "width": 1.0, "width_curve": null, "gradient": null, "alignment": 0,
		"corner_vertices": 0, "cap_vertices": 0, "texture_mode": 0, "texture_scale": Vector2.ONE, "material": null}


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


## Where the ribbon has vertices: at every point of the line, and in between where the width
## curve or the gradient has a key (a taper or a fade in the middle of a segment is not
## straight from end to end). → [{t, at, arrive, leave, u, point}]: the place along the line
## (0 to 1 by length), the position, the directions the line arrives and leaves with (the
## same between points), the texture coordinate along the line, whether it is a point.
static func stations(info: Dictionary) -> Array:
	var pts: PackedVector3Array = points(info)
	var out: Array = []
	if pts.size() < 2:
		return out
	var closed: bool = bool(info.get("loop", false)) and pts.size() > 3
	var lengths := PackedFloat32Array([0.0])
	for i in range(1, pts.size()):
		lengths.append(lengths[i - 1] + pts[i].distance_to(pts[i - 1]))
	var total: float = lengths[lengths.size() - 1]
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
	var mode: int = int(info.get("texture_mode", STRETCH))
	var last: int = pts.size() - 1
	for i in range(pts.size()):
		var t: float = lengths[i] / total if total > 0.0 else float(i) / float(last)
		var before: Vector3 = (pts[i] - pts[i - 1]).normalized() if i > 0 else Vector3.ZERO
		var after: Vector3 = (pts[i + 1] - pts[i]).normalized() if i < last else Vector3.ZERO
		if closed and i == 0:
			before = (pts[last] - pts[last - 1]).normalized()
		if closed and i == last:
			after = (pts[1] - pts[0]).normalized()
		if before.length_squared() < 0.5:
			before = after
		if after.length_squared() < 0.5:
			after = before
		var u: float = t
		match mode:
			TILE:
				u = lengths[i]
			DISTRIBUTE_PER_SEGMENT:
				u = float(i) / float(last)
			REPEAT_PER_SEGMENT:
				u = float(i)
		out.append({"t": t, "at": pts[i], "arrive": before, "leave": after, "u": u, "point": true})
		if i < last and total > 0.0:
			var t1: float = lengths[i + 1] / total
			var inside: Array = stops.filter(func(s) -> bool: return s > t + 1e-5 and s < t1 - 1e-5)
			inside.sort()
			var previous: float = t
			for s in inside:
				if s - previous < 1e-5:
					continue
				previous = s
				var f: float = (s - t) / (t1 - t)
				var u_in: float = s
				match mode:
					TILE:
						u_in = lerpf(lengths[i], lengths[i + 1], f)
					DISTRIBUTE_PER_SEGMENT:
						u_in = (float(i) + f) / float(last)
					REPEAT_PER_SEGMENT:
						u_in = float(i) + f
				out.append({"t": s, "at": pts[i].lerp(pts[i + 1], f), "arrive": after, "leave": after, "u": u_in, "point": false})
	return out


## The ribbon (see line_renderer.gdshaderinc for what a vertex carries). Null without two
## points.
static func mesh(info: Dictionary) -> ArrayMesh:
	var where: Array = stations(info)
	if where.size() < 2:
		return null
	var corners: int = clampi(int(info.get("corner_vertices", 0)), 0, 90)
	var caps: int = clampi(int(info.get("cap_vertices", 0)), 0, 90)
	var closed: bool = bool(info.get("loop", false)) and points(info).size() > 3
	var scale: Vector2 = info.get("texture_scale", Vector2.ONE) if info.get("texture_scale") is Vector2 else Vector2.ONE
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var offsets := PackedVector2Array()
	var custom := PackedFloat32Array()
	var rates := PackedFloat32Array()
	var indices := PackedInt32Array()
	var widest: float = 0.0
	var translucent: bool = false

	# one vertex: where on the line, the two directions, how far round the corner, the
	# offset across and along, the colour, the texture coordinates
	var add := func(st: Dictionary, arrive: Vector3, leave: Vector3, turn: float, across: float, along: float, color: Color, uv: Vector2) -> int:
		vertices.append(st["at"])
		normals.append(arrive)
		custom.append_array(PackedFloat32Array([leave.x, leave.y, leave.z, turn]))
		rates.append_array(PackedFloat32Array([float(st["rate_in"]) * scale.x, float(st["rate_out"]) * scale.x]))
		offsets.append(Vector2(across, along))
		colors.append(color)
		uvs.append(uv * scale)
		return vertices.size() - 1

	# how fast the texture runs along the segment before and after each station
	for i in range(where.size()):
		var here: Dictionary = where[i]
		var rate_in: float = 0.0
		var rate_out: float = 0.0
		if i > 0:
			var d: float = (here["at"] as Vector3).distance_to(where[i - 1]["at"])
			rate_in = (float(here["u"]) - float(where[i - 1]["u"])) / d if d > 1e-9 else 0.0
		if i < where.size() - 1:
			var d: float = (where[i + 1]["at"] as Vector3).distance_to(here["at"])
			rate_out = (float(where[i + 1]["u"]) - float(here["u"])) / d if d > 1e-9 else 0.0
		here["rate_in"] = rate_in if i > 0 else rate_out
		here["rate_out"] = rate_out if i < where.size() - 1 else rate_in
	var tail: Array = []   # the vertices (left, right) the next segment starts from
	for i in range(where.size()):
		var st: Dictionary = where[i]
		var half: float = width_at(info, float(st["t"])) * 0.5
		widest = maxf(widest, absf(half))
		var color: Color = color_at(info, float(st["t"]))
		translucent = translucent or color.a < 0.999
		var arrive: Vector3 = st["arrive"]
		var leave: Vector3 = st["leave"]
		var u: float = float(st["u"])
		var head: Array = []   # the vertices (left, right) the segment before ends at
		var bent: bool = bool(st["point"]) and corners > 0 and arrive.dot(leave) < 0.9998 and (closed or (i > 0 and i < where.size() - 1))
		if bent and closed and i == where.size() - 1:
			# (the last point of a loop is its first one again, which has the corner: the
			# segment ends at the edge it arrives with)
			for side in [-1.0, 1.0]:
				head.append(add.call(st, arrive, leave, 0.0, half * side, 0.0, color, Vector2(u, 0.5 + 0.5 * side)))
			tail_and_quad(indices, tail, head)
			tail = head
		elif bent:
			# a rounded corner: a fan about the point on each side, from the edge of the
			# segment that arrives to the edge of the one that leaves (on the inner side all
			# of it lies on the point where the two edges meet: the shader's)
			var centre: int = add.call(st, arrive, leave, 0.0, 0.0, 0.0, color, Vector2(u, 0.5))
			var ends: Array = []
			for side in [-1.0, 1.0]:
				var first: int = -1
				var previous: int = -1
				for j in range(corners + 2):
					var v: int = add.call(st, arrive, leave, float(j) / float(corners + 1), half * side, 0.0, color, Vector2(u, 0.5 + 0.5 * side))
					if j == 0:
						first = v
					else:
						indices.append_array(PackedInt32Array([centre, previous, v]))
					previous = v
				head.append(first)
				ends.append(previous)
			tail_and_quad(indices, tail, head)
			# (between the end of the arriving segment, the point and the start of the
			# leaving one: the edges that end on the inner side are not across the line)
			indices.append_array(PackedInt32Array([centre, head[0], head[1], centre, ends[0], ends[1]]))
			tail = ends
		else:
			var mid: Vector3 = arrive + leave
			if mid.length_squared() < 1e-12:
				mid = leave
			mid = mid.normalized()
			for side in [-1.0, 1.0]:
				head.append(add.call(st, mid, mid, 0.0, half * side, 0.0, color, Vector2(u, 0.5 + 0.5 * side)))
			tail_and_quad(indices, tail, head)
			tail = head
		# a rounded cap: half a disc about the end, in the ribbon's plane
		if caps > 0 and not closed and (i == 0 or i == where.size() - 1):
			var outward: float = -1.0 if i == 0 else 1.0
			var dir: Vector3 = leave if i == 0 else arrive
			var centre: int = add.call(st, dir, dir, 0.0, 0.0, 0.0, color, Vector2(u, 0.5))
			var previous: int = -1
			for j in range(caps + 2):
				var angle: float = PI * float(j) / float(caps + 1)
				var v: int = add.call(st, dir, dir, 0.0, half * cos(angle), half * sin(angle) * outward, color, Vector2(u, 0.5 + 0.5 * cos(angle)))
				if j > 0:
					indices.append_array(PackedInt32Array([centre, previous, v]))
				previous = v
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = offsets
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	arrays[Mesh.ARRAY_CUSTOM1] = rates
	arrays[Mesh.ARRAY_INDEX] = indices
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		(Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RG_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT))
	# (the vertices lie on the line: the ribbon reaches half its width beyond them, more at
	# the inner side of a sharp corner)
	out.custom_aabb = out.get_aabb().grow(widest * 3.0)
	out.surface_set_material(0, ribbon_material(info, translucent))
	return out


## The two triangles between the end of one segment and the start of the next.
static func tail_and_quad(indices: PackedInt32Array, tail: Array, head: Array) -> void:
	if tail.size() == 2 and head.size() == 2:
		indices.append_array(PackedInt32Array([tail[0], tail[1], head[0], tail[1], head[1], head[0]]))


## The material the ribbon is drawn with: the ribbon's shader with what the renderer's
## material says (its colour, its texture and tiling, whether it adds or covers).
static func ribbon_material(info: Dictionary, translucent: bool) -> ShaderMaterial:
	var out := ShaderMaterial.new()
	var albedo: Color = Color.WHITE
	var texture: Texture2D = null
	var st := Vector4(1.0, 1.0, 0.0, 0.0)
	var additive: bool = false
	var source = info.get("material")
	if source is BaseMaterial3D:
		var m: BaseMaterial3D = source
		albedo = m.albedo_color
		texture = m.albedo_texture
		st = Vector4(m.uv1_scale.x, m.uv1_scale.y, m.uv1_offset.x, m.uv1_offset.y)
		additive = m.blend_mode == BaseMaterial3D.BLEND_MODE_ADD
		translucent = translucent or m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or albedo.a < 0.999
	elif source is ShaderMaterial:
		# a shader of the project's own cannot open the ribbon: its main colour and texture
		# are what is taken of it
		var m: ShaderMaterial = source
		for name in [&"_Color", &"_TintColor", &"_BaseColor"]:
			var c = m.get_shader_parameter(name)
			if c is Color:
				albedo = c
				break
		for name in [&"_MainTex", &"_BaseMap"]:
			var t = m.get_shader_parameter(name)
			if t is Texture2D:
				texture = t
				var tiling = m.get_shader_parameter(StringName(String(name) + "_ST"))
				if tiling is Vector4:
					st = tiling
				break
		translucent = true
	out.shader = SHADER_ADD if additive else (SHADER if translucent else SHADER_OPAQUE)
	out.set_shader_parameter(&"face_z", int(info.get("alignment", 0)) == 1)
	out.set_shader_parameter(&"albedo", albedo)
	out.set_shader_parameter(&"albedo_texture", texture)
	out.set_shader_parameter(&"uv_st", st)
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
