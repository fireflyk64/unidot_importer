# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# SPDX-License-Identifier: MIT
extends SceneTree
## Unit tests for runtime/rect_transform.gd (no importer, no scripting layer):
##   godot --headless --path <project with this addon> -s addons/unidot_importer/test/rect_transform_test.gd
## Expected numbers are Unity's, worked out by hand from the RectTransform rules.

const RT := preload("../runtime/rect_transform.gd")
const Scaler := preload("../runtime/canvas_scaler.gd")

var _checks: int = 0
var _failed: Array = []


func ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_failed.append(what)
		print("   FAIL " + what)


func near(a, b, what: String, eps: float = 1e-3) -> void:
	var good: bool = false
	if a is Vector2 and b is Vector2:
		good = absf(a.x - b.x) <= eps and absf(a.y - b.y) <= eps
	elif a is Vector3 and b is Vector3:
		good = absf(a.x - b.x) <= eps and absf(a.y - b.y) <= eps and absf(a.z - b.z) <= eps
	elif a is Quaternion and b is Quaternion:
		good = absf(absf(a.dot(b)) - 1.0) <= eps
	elif a is Rect2 and b is Rect2:
		good = (a.position - b.position).length() <= eps and (a.size - b.size).length() <= eps
	else:
		good = absf(float(a) - float(b)) <= eps
	ok(good, "%s: got %s, expected %s" % [what, str(a), str(b)])


func _init() -> void:
	await process_frame
	for mode in ["outside the tree", "in the tree"]:
		_values(mode == "in the tree")
		_setters(mode == "in the tree")
		_three_d_extras(mode == "in the tree")
	_scaler()
	await _world_canvas()
	await _promotion()
	await _nested_canvas()
	await _screen_canvas()
	print("[rect_transform_test] %d checks, %d failure(s)" % [_checks, _failed.size()])
	print("RECT TRANSFORM TESTS " + ("PASSED" if _failed.is_empty() else "FAILED"))
	quit(0 if _failed.is_empty() else 1)


## A 400 x 200 parent with a child; in the tree or not (a scene being imported is not).
func _pair(in_tree: bool) -> Array:
	var parent := Control.new()
	parent.name = "Parent"
	parent.size = Vector2(400, 200)
	parent.pivot_offset_ratio = Vector2(0.5, 0.5)
	var child := Control.new()
	child.name = "Child"
	parent.add_child(child)
	if in_tree:
		root.add_child(parent)
	return [parent, child]


func _done(nodes: Array) -> void:
	var top: Node = nodes[0]
	if top.is_inside_tree():
		top.get_parent().remove_child(top)
	top.free()


func _values(in_tree: bool) -> void:
	var tag: String = " (in the tree)" if in_tree else " (outside the tree)"
	# centre anchors: the anchored position is the pivot relative to the parent's centre
	var p: Array = _pair(in_tree)
	var c: Control = p[1]
	RT.set_values(c, {"anchor_min": Vector2(0.5, 0.5), "anchor_max": Vector2(0.5, 0.5), "anchored_position": Vector2(10, 20), "size_delta": Vector2(100, 50), "pivot": Vector2(0.5, 0.5)})
	near(RT._control_rect(c), Rect2(160, 55, 100, 50), "centre anchors: control rectangle" + tag)
	near(RT.local_position(c), Vector3(10, 20, 0), "centre anchors: localPosition" + tag)
	near(RT.rect(c), Rect2(-50, -25, 100, 50), "centre anchors: rect" + tag)
	near(RT.anchored_position(c), Vector2(10, 20), "centre anchors: anchoredPosition reads back" + tag)
	near(RT.size_delta(c), Vector2(100, 50), "centre anchors: sizeDelta reads back" + tag)
	_done(p)
	# stretched over the parent with insets: offsetMin (10, 20), offsetMax (-30, -40)
	p = _pair(in_tree)
	c = p[1]
	RT.set_values(c, {"anchor_min": Vector2(0, 0), "anchor_max": Vector2(1, 1), "anchored_position": Vector2(-10, -10), "size_delta": Vector2(-40, -60), "pivot": Vector2(0.5, 0.5)})
	near(RT._control_rect(c), Rect2(10, 40, 360, 140), "stretched: control rectangle" + tag)
	near(RT.offset_min(c), Vector2(10, 20), "stretched: offsetMin" + tag)
	near(RT.offset_max(c), Vector2(-30, -40), "stretched: offsetMax" + tag)
	near(RT.rect_size(c), Vector2(360, 140), "stretched: rect size" + tag)
	near(RT.local_position(c), Vector3(-10, -10, 0), "stretched: localPosition" + tag)
	_done(p)
	# top-left anchors and a top-left pivot
	p = _pair(in_tree)
	c = p[1]
	RT.set_values(c, {"anchor_min": Vector2(0, 1), "anchor_max": Vector2(0, 1), "anchored_position": Vector2(5, -7), "size_delta": Vector2(80, 30), "pivot": Vector2(0, 1)})
	near(RT._control_rect(c), Rect2(5, 7, 80, 30), "top-left pivot: control rectangle" + tag)
	near(RT.local_position(c), Vector3(-195, 93, 0), "top-left pivot: localPosition" + tag)
	near(RT.rect(c), Rect2(0, -30, 80, 30), "top-left pivot: rect" + tag)
	near(RT.pivot(c), Vector2(0, 1), "top-left pivot: pivot reads back" + tag)
	# scale and rotation turn about the pivot: the top-left corner stays, 90 degrees counter-clockwise
	RT.set_values(c, {"scale": Vector3(2, 2, 1), "rotation": Quaternion(Vector3(0, 0, 1), PI / 2.0)})
	var xf: Transform2D = RT.control_transform(c)
	near(xf * Vector2(0, 0), Vector2(5, 7), "scaled and rotated: the pivot corner stays" + tag)
	# Unity: the rect's +x (width 80, scale 2) points up after +90 degrees: 160 units up the screen
	near(xf * Vector2(80, 0), Vector2(5, 7 - 160), "scaled and rotated: the top-right corner goes up" + tag)
	near(RT.local_rotation(c), Quaternion(Vector3(0, 0, 1), PI / 2.0), "rotation reads back" + tag)
	near(RT.local_scale(c), Vector3(2, 2, 1), "scale reads back" + tag)
	_done(p)
	# stretched horizontally only, bottom anchored: a bar 20 high, 10 above the bottom edge
	p = _pair(in_tree)
	c = p[1]
	RT.set_values(c, {"anchor_min": Vector2(0, 0), "anchor_max": Vector2(1, 0), "anchored_position": Vector2(0, 10), "size_delta": Vector2(-20, 20), "pivot": Vector2(0.5, 0)})
	near(RT._control_rect(c), Rect2(10, 170, 380, 20), "bottom bar: control rectangle" + tag)
	near(RT.local_position(c), Vector3(0, -90, 0), "bottom bar: localPosition" + tag)
	_done(p)


func _setters(in_tree: bool) -> void:
	var tag: String = " (in the tree)" if in_tree else " (outside the tree)"
	var p: Array = _pair(in_tree)
	var c: Control = p[1]
	RT.set_values(c, {"anchor_min": Vector2(0.5, 0.5), "anchor_max": Vector2(0.5, 0.5), "anchored_position": Vector2(0, 0), "size_delta": Vector2(100, 50), "pivot": Vector2(0.5, 0.5)})
	RT.set_anchored_position(c, Vector2(-30, 40))
	near(RT._control_rect(c), Rect2(120, 35, 100, 50), "anchoredPosition setter" + tag)
	# sizeDelta grows around the pivot
	RT.set_size_delta(c, Vector2(200, 100))
	near(RT._control_rect(c), Rect2(70, 10, 200, 100), "sizeDelta setter grows around the pivot" + tag)
	# pivot: anchoredPosition and sizeDelta stay, so the rect moves (Unity's scripting behaviour)
	RT.set_pivot(c, Vector2(0, 0))
	near(RT._control_rect(c), Rect2(170, -40, 200, 100), "pivot setter moves the rect" + tag)
	near(RT.anchored_position(c), Vector2(-30, 40), "pivot setter keeps anchoredPosition" + tag)
	# anchors: anchoredPosition and sizeDelta stay
	RT.set_anchor_min(c, Vector2(0, 0))
	RT.set_anchor_max(c, Vector2(0, 0))
	near(RT._control_rect(c), Rect2(-30, 60, 200, 100), "anchor setters keep anchoredPosition and sizeDelta" + tag)
	near(RT.anchor_min(c), Vector2(0, 0), "anchorMin reads back" + tag)
	# offsets
	RT.set_values(c, {"anchor_min": Vector2(0, 0), "anchor_max": Vector2(1, 1), "anchored_position": Vector2.ZERO, "size_delta": Vector2.ZERO, "pivot": Vector2(0.5, 0.5)})
	RT.set_offset_min(c, Vector2(10, 20))
	near(RT._control_rect(c), Rect2(10, 0, 390, 180), "offsetMin setter" + tag)
	RT.set_offset_max(c, Vector2(-30, -40))
	near(RT._control_rect(c), Rect2(10, 40, 360, 140), "offsetMax setter" + tag)
	near(RT.size_delta(c), Vector2(-40, -60), "offsets give sizeDelta" + tag)
	near(RT.anchored_position(c), Vector2(-10, -10), "offsets give anchoredPosition" + tag)
	# SetSizeWithCurrentAnchors: the size, whatever the anchors are
	RT.set_size_with_current_anchors(c, 0, 100.0)
	RT.set_size_with_current_anchors(c, 1, 50.0)
	near(RT.rect_size(c), Vector2(100, 50), "SetSizeWithCurrentAnchors" + tag)
	near(RT.size_delta(c), Vector2(-300, -150), "SetSizeWithCurrentAnchors writes sizeDelta against stretched anchors" + tag)
	# SetInsetAndSizeFromParentEdge
	RT.set_inset_and_size_from_parent_edge(c, RT.Edge.LEFT, 15.0, 60.0)
	RT.set_inset_and_size_from_parent_edge(c, RT.Edge.TOP, 25.0, 40.0)
	near(RT._control_rect(c), Rect2(15, 25, 60, 40), "SetInsetAndSizeFromParentEdge left / top" + tag)
	near(RT.anchor_min(c), Vector2(0, 1), "SetInsetAndSizeFromParentEdge collapses the anchors" + tag)
	RT.set_inset_and_size_from_parent_edge(c, RT.Edge.RIGHT, 15.0, 60.0)
	RT.set_inset_and_size_from_parent_edge(c, RT.Edge.BOTTOM, 25.0, 40.0)
	near(RT._control_rect(c), Rect2(325, 135, 60, 40), "SetInsetAndSizeFromParentEdge right / bottom" + tag)
	# localPosition setter moves the pivot, keeps the anchors
	RT.set_local_position(c, Vector3(0, 0, 0))
	near(RT._control_rect(c), Rect2(170, 80, 60, 40), "localPosition setter centres the rect" + tag)
	near(RT.anchor_min(c), Vector2(1, 0), "localPosition setter keeps the anchors" + tag)
	near(RT.local_position(c), Vector3(0, 0, 0), "localPosition reads back" + tag)
	# corners: bottom-left, top-left, top-right, bottom-right in the rect's own space
	var corners: Array = RT.local_corners(c)
	near(corners[0], Vector3(-30, -20, 0), "GetLocalCorners bottom-left" + tag)
	near(corners[2], Vector3(30, 20, 0), "GetLocalCorners top-right" + tag)
	_done(p)


func _three_d_extras(in_tree: bool) -> void:
	var tag: String = " (in the tree)" if in_tree else " (outside the tree)"
	var p: Array = _pair(in_tree)
	var c: Control = p[1]
	# what a Control cannot hold round-trips through the metadata (no canvas here, so no island)
	var flip := Quaternion(Vector3(0, 1, 0), PI)
	_rt(c, {"size_delta": Vector2(100, 50), "z": -3.5, "rotation": flip, "scale": Vector3(2, 3, 4)})
	near(RT.local_position(c).z, -3.5, "z offset reads back" + tag)
	near(RT.local_rotation(c), flip, "a half turn about y reads back" + tag)
	near(RT.local_scale(c), Vector3(2, 3, 4), "scale with z reads back" + tag)
	# seen from the front a half turn about y mirrors x: the Control shows that projection
	var xf: Transform2D = RT.control_transform(c)
	var centre: Vector2 = xf * Vector2(50, 25)
	near((xf * Vector2(100, 25)) - centre, Vector2(-100, 0), "a half turn about y mirrors the rect" + tag)
	near((xf * Vector2(50, 50)) - centre, Vector2(0, 75), "... and keeps y" + tag)
	# back to a plain rotation: the metadata goes away again
	RT.set_values(c, {"z": 0.0, "rotation": Quaternion.IDENTITY, "scale": Vector3.ONE})
	ok(not c.has_meta(RT.META_RECT), "a planar rect keeps no extra metadata" + tag)
	_done(p)


func _scaler() -> void:
	near(Scaler.scale_factor({"mode": 0, "scale_factor": 2.0}, Vector2(1920, 1080)), 2.0, "constant pixel size")
	var sws: Dictionary = {"mode": 1, "reference_resolution": Vector2(800, 600), "match_mode": 0, "match": 0.0}
	near(Scaler.scale_factor(sws, Vector2(1600, 900)), 2.0, "scale with screen size, match width")
	sws["match"] = 1.0
	near(Scaler.scale_factor(sws, Vector2(1600, 900)), 1.5, "scale with screen size, match height")
	sws["match"] = 0.5
	near(Scaler.scale_factor(sws, Vector2(1600, 900)), sqrt(3.0), "scale with screen size, match 0.5 (geometric mean)")
	sws["match_mode"] = 1
	near(Scaler.scale_factor(sws, Vector2(1600, 900)), 1.5, "scale with screen size, expand")
	sws["match_mode"] = 2
	near(Scaler.scale_factor(sws, Vector2(1600, 900)), 2.0, "scale with screen size, shrink")


## A world canvas: holder at Godot (1, 2, 3) (Unity (-1, 2, 3)), scale 0.01, rect 200 x 100.
func _canvas(pos: Vector3 = Vector3(1, 2, 3), scale: float = 0.01) -> Node3D:
	var holder := Node3D.new()
	holder.name = "Canvas"
	root.add_child(holder)
	var croot := Control.new()
	croot.name = "Canvas"
	RT.build_island(holder, croot, {"anchored_position": Vector2(-pos.x, pos.y), "z": pos.z, "size_delta": Vector2(200, 100), "scale": Vector3(scale, scale, scale)})
	return holder


## Unity's defaults (centre anchors, centre pivot) plus the given values.
func _rt(n: Node, v: Dictionary) -> void:
	var full: Dictionary = RT._defaults()
	full.merge(v, true)
	RT.set_values(n, full)


func _image(parent: Control, name: String, v: Dictionary) -> TextureRect:
	var t := TextureRect.new()
	t.name = name
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	parent.add_child(t)
	_rt(t, v)
	return t


## Where a point of a control is drawn in the world, following what is rendered: control →
## viewport pixel → the quad showing that viewport (or the inline view in the canvas around it).
func rendered(c: Control, local: Vector2) -> Vector3:
	var px: Vector2 = c.get_global_transform() * local
	var vp: SubViewport = c.get_viewport() as SubViewport
	var holder: Node = vp.get_parent()
	var plane: MeshInstance3D = holder.get_node("CanvasPlane")
	if plane.visible:
		var s: Vector2 = (plane.mesh as QuadMesh).size
		var uv: Vector2 = px / Vector2(vp.size)
		var g: Vector3 = plane.global_transform * Vector3((uv.x - 0.5) * s.x, (0.5 - uv.y) * s.y, 0.0)
		return Vector3(-g.x, g.y, g.z)   # Unity world space
	for v in holder.get_parent().get_children():
		if v.has_meta(RT.META_VIEW) and v.get_meta(RT.META_VIEW) == holder.get_instance_id():
			return rendered(v, px / Vector2(vp.size) * v.size)
	return Vector3(INF, INF, INF)


func _world_canvas() -> void:
	var holder: Node3D = _canvas()
	var croot: Control = RT.root_control(holder)
	near(holder.position, Vector3(1, 2, 3), "the holder sits at the canvas's anchored position (x mirrored)")
	near(RT.rect_size(holder), Vector2(200, 100), "canvas rect size")
	near(RT.world_position(holder), Vector3(-1, 2, 3), "canvas world position (Unity space)")
	var img: TextureRect = _image(croot, "Img", {"anchored_position": Vector2(50, 25), "size_delta": Vector2(40, 20)})
	# far outside the canvas rect: Unity world canvases do not clip
	var far: TextureRect = _image(croot, "Far", {"anchored_position": Vector2(300, -200), "size_delta": Vector2(20, 20)})
	await process_frame
	await process_frame
	near(RT.world_position(img), Vector3(-1 + 0.5, 2 + 0.25, 3), "a child's world position")
	near(RT.lossy_scale(img), Vector3(0.01, 0.01, 0.01), "a child's lossyScale")
	near(RT.world_corners(img)[0], Vector3(-1 + 0.3, 2 + 0.15, 3), "GetWorldCorners bottom-left")
	near(rendered(img, Vector2(20, 10)), Vector3(-0.5, 2.25, 3), "the image is drawn where its world position says", 2e-3)
	near(rendered(far, Vector2(10, 10)), Vector3(-1 + 3.0, 2 - 2.0, 3), "a child outside the canvas rect is drawn in place", 2e-3)
	var cfg: Dictionary = holder.get_meta(RT.META_CANVAS)
	ok(cfg["plane_size"].x >= 280.0 and cfg["plane_size"].x < 280.3 and cfg["plane_size"].y >= 245.0 and cfg["plane_size"].y < 245.3, "the plane covers the content, not the canvas rect: " + str(cfg["plane_size"]))
	near(float(cfg["k"]), 1024.0 * 0.01, "pixel density follows the world scale")
	ok(RT.logical_parent(img) == holder, "a child's parent is the canvas, not its viewport")
	ok(RT.logical_children(holder) == [img, far], "the canvas's children are its controls")
	# world position setter inside the plane: stays a control
	RT.set_world_position(img, Vector3(-1, 2, 3))
	near(RT.anchored_position(img), Vector2(0, 0), "world position setter moves the anchored position")
	ok(RT.holder_of(img) == null, "a move inside the plane keeps the control in its canvas")
	# moving the canvas moves what it draws
	holder.position = Vector3(0, 0, 0)
	await process_frame
	near(rendered(img, Vector2(20, 10)), Vector3(0, 0, 0), "the canvas moved: the image follows", 2e-3)
	# sizeDelta of the canvas itself
	RT.set_size_delta(holder, Vector2(400, 100))
	await process_frame
	near(croot.size, Vector2(400, 100), "canvas sizeDelta resizes the root control")
	near(rendered(img, Vector2(20, 10)), Vector3(0, 0, 0), "... and centred children stay centred", 2e-3)
	holder.queue_free()
	await process_frame


func _promotion() -> void:
	var holder: Node3D = _canvas(Vector3(0, 1, 0), 0.01)
	var croot: Control = RT.root_control(holder)
	var panel := Control.new()
	panel.name = "Panel"
	croot.add_child(panel)
	_rt(panel, {"anchored_position": Vector2(0, 0), "size_delta": Vector2(100, 100)})
	var img: TextureRect = _image(panel, "Img", {"anchored_position": Vector2(20, 0), "size_delta": Vector2(40, 20)})
	await process_frame
	# tilt the panel 45 degrees about x: it leaves the canvas plane and gets a canvas of its own
	var tilt := Quaternion(Vector3(1, 0, 0), PI / 4.0)
	RT.set_local_rotation(panel, tilt)
	var island: Node = RT.holder_of(panel)
	ok(island != null and RT.is_island(island), "a tilted control becomes a canvas of its own")
	ok(RT.identity(island) == panel, "... and is still known by the control")
	ok(RT.logical_parent(panel) == holder, "... with the same parent")
	ok(RT.logical_children(holder) == [panel], "... and the same place among the children")
	ok(RT.logical_parent(img) == panel, "its children still see it as their parent")
	near(RT.local_rotation(panel), tilt, "localRotation reads back from the promoted control")
	await process_frame
	await process_frame
	# Unity: the image centre is 20 units right of the panel pivot; the tilt leaves x alone
	near(RT.world_position(img), Vector3(0.2, 1, 0), "world position of a child of the tilted panel")
	var up: Vector3 = RT.world_matrix(img) * Vector3(0, 10, 0)
	near(up, Vector3(0.2, 1 + 0.1 * cos(PI / 4.0), 0.1 * sin(PI / 4.0)), "the panel's y axis is tilted towards +z")
	near(rendered(img, Vector2(20, 10)), Vector3(0.2, 1, 0), "the image is drawn on the tilted plane: centre", 2e-3)
	near(rendered(img, Vector2(20, 0)), Vector3(0.2, 1 + 0.1 * cos(PI / 4.0), 0.1 * sin(PI / 4.0)), "... and its top edge", 2e-3)
	ok((island.get_node("CanvasPlane") as MeshInstance3D).visible, "the tilted canvas has its own plane")
	# world position and rotation: put it somewhere else entirely (what setTransform-style scripts do)
	var spot_pos := Vector3(2, 0.5, -1)
	var spot_rot := Quaternion(Vector3(0, 1, 0), PI / 2.0)
	RT.set_world_position(panel, spot_pos)
	RT.set_world_rotation(panel, spot_rot)
	await process_frame
	near(RT.world_position(panel), spot_pos, "world position setter on a promoted control")
	near(RT.world_rotation(panel), spot_rot, "world rotation setter on a promoted control")
	# the image centre is 20 units along the panel's x axis, which now points along -z
	near(rendered(img, Vector2(20, 10)), spot_pos + spot_rot * Vector3(0.2, 0, 0), "the image follows the panel to the spot", 2e-3)
	# z offset alone also leaves the plane
	var other := Control.new()
	other.name = "Other"
	croot.add_child(other)
	_rt(other, {"size_delta": Vector2(10, 10)})
	_image(other, "Dot", {"size_delta": Vector2(10, 10)})
	RT.set_local_position(other, Vector3(0, 0, 0.05))   # 0.05 units * 0.01 = 0.5 mm: still flat
	ok(RT.holder_of(other) == null, "half a millimetre off the plane stays in the canvas")
	RT.set_local_position(other, Vector3(0, 0, 50))     # 0.5 m
	ok(RT.holder_of(other) != null, "half a metre off the plane becomes a canvas of its own")
	await process_frame
	near(RT.world_position(other), Vector3(0, 1, 0.5), "its world position carries the z offset")
	# hiding the control hides its plane; freeing it removes the holder
	panel.visible = false
	await process_frame
	ok(not (island.get_node("CanvasPlane") as MeshInstance3D).visible, "a hidden promoted control hides its plane")
	panel.queue_free()
	await process_frame
	await process_frame
	ok(not is_instance_valid(island) or island.is_queued_for_deletion(), "freeing the control frees its holder")
	holder.queue_free()
	await process_frame


func _nested_canvas() -> void:
	var holder: Node3D = _canvas(Vector3(0, 1, 0), 0.01)
	var croot: Control = RT.root_control(holder)
	var bg: TextureRect = _image(croot, "Bg", {"size_delta": Vector2(200, 100)})
	# a canvas inside the canvas (what a nested Canvas prefab instance becomes): coplanar at first
	var inner := Node3D.new()
	inner.name = "Inner"
	croot.add_child(inner)
	var iroot := Control.new()
	iroot.name = "Canvas"
	RT.build_island(inner, iroot, {"anchored_position": Vector2(50, 0), "size_delta": Vector2(60, 40), "scale": Vector3(0.5, 0.5, 0.5)})
	var dot: TextureRect = _image(iroot, "Dot", {"size_delta": Vector2(60, 40)})
	await process_frame
	await process_frame
	await process_frame
	ok(RT.is_nested(inner) and RT.island_of(inner) == holder, "the inner canvas knows the canvas around it")
	ok(not (inner.get_node("CanvasPlane") as MeshInstance3D).visible, "a coplanar inner canvas has no plane of its own")
	near(RT.world_position(inner), Vector3(0.5, 1, 0), "inner canvas world position")
	near(RT.lossy_scale(dot), Vector3(0.005, 0.005, 0.005), "inner canvas scale carries to its children")
	near(rendered(dot, Vector2(30, 20)), Vector3(0.5, 1, 0), "drawn inside the outer canvas: centre", 2e-3)
	near(rendered(dot, Vector2(60, 20)), Vector3(0.5 + 0.15, 1, 0), "drawn inside the outer canvas: right edge", 2e-3)
	ok(RT.logical_children(holder) == [bg, inner], "the inline view is not a child object")
	# turned out of the plane: it gets its own quad
	RT.set_local_rotation(inner, Quaternion(Vector3(0, 1, 0), PI / 2.0))
	await process_frame
	await process_frame
	ok((inner.get_node("CanvasPlane") as MeshInstance3D).visible, "turned out of the plane it is shown on its own quad")
	# the inner rect's +x now points along world -z (a positive turn about y in Unity's left-handed space)
	near(rendered(dot, Vector2(60, 20)), Vector3(0.5, 1, -0.15), "the right edge points along -z", 2e-3)
	# hiding the control the inner canvas hangs under hides it
	croot.visible = false
	await process_frame
	ok(not (inner.get_node("CanvasPlane") as MeshInstance3D).visible, "hidden with the canvas around it")
	holder.queue_free()
	await process_frame


func _screen_canvas() -> void:
	var canvas := Node3D.new()
	canvas.name = "Overlay"
	root.add_child(canvas)
	var layer := CanvasLayer.new()
	layer.name = "CanvasLayer"
	canvas.add_child(layer)
	var croot := Control.new()
	croot.name = "Canvas"
	layer.add_child(croot)
	canvas.set_meta(RT.META_CANVAS, {"mode": "overlay", "root": canvas.get_path_to(croot), "scaler": {"mode": 1, "reference_resolution": Vector2(800, 600), "match_mode": 0, "match": 0.0}})
	layer.set_script(Scaler)
	layer.apply()
	var screen: Vector2 = root.get_visible_rect().size
	var f: float = screen.x / 800.0
	near(croot.scale, Vector2(f, f), "the screen canvas is scaled by the scaler's factor")
	near(croot.size, screen / f, "... and covers the window in canvas units")
	var img: TextureRect = _image(croot, "Img", {"anchor_min": Vector2(1, 0), "anchor_max": Vector2(1, 0), "anchored_position": Vector2(-10, 10), "size_delta": Vector2(20, 20), "pivot": Vector2(1, 0)})
	await process_frame
	# bottom-right corner, 10 canvas units in: Unity world units of a screen canvas are pixels, y up
	near(RT.world_position(img), Vector3(screen.x - 10 * f, 10 * f, 0), "screen canvas world position is in pixels, y up", 0.01)
	RT.set_local_rotation(img, Quaternion(Vector3(1, 0, 0), 1.0))
	ok(RT.holder_of(img) == null, "a tilted control on a screen canvas stays flat")
	canvas.queue_free()
	await process_frame
