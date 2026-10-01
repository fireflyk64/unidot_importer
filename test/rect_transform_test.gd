# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# SPDX-License-Identifier: MIT
extends SceneTree
## Unit tests for runtime/rect_transform.gd and the modules that draw Unity UI (ui_text.gd,
## ui_graphic.gd, selectable.gd), without importer or scripting layer:
##   godot --headless --path <project with this addon> -s addons/unidot_importer/test/rect_transform_test.gd
## Expected numbers are Unity's, worked out by hand from the RectTransform rules.

const RT := preload("../runtime/rect_transform.gd")
const Scaler := preload("../runtime/canvas_scaler.gd")
const UiText := preload("../runtime/ui_text.gd")
const Graphic := preload("../runtime/ui_graphic.gd")
const Selectable := preload("../runtime/selectable.gd")
const TextFit := preload("../runtime/ui_text_fit.gd")
const Sprite := preload("../runtime/ui_sprite.gd")
const Scroll := preload("../runtime/scroll_rect.gd")
const UiGroup := preload("../runtime/canvas_group.gd")

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
	await _plain_holders()
	_rich_text()
	await _text_nodes()
	_graphics()
	_sprites()
	await _selectables()
	await _scroll_rect()
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


func rendered(c: Control, local: Vector2) -> Vector3:
	return RT.drawn_point(c, local)


func _world_canvas() -> void:
	var holder: Node3D = _canvas()
	var croot: Control = RT.root_control(holder)
	near(holder.position, Vector3(1, 2, 3), "the holder sits at the canvas's anchored position (x mirrored)")
	near(RT.rect_size(holder), Vector2(200, 100), "canvas rect size")
	near(RT.world_position(holder), Vector3(-1, 2, 3), "canvas world position (Unity space)")
	ok(not (croot.get_viewport() as SubViewport).gui_snap_controls_to_pixels, "the canvas viewport does not snap controls to whole canvas units")
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
	# the plane grows at once and shrinks back when the content has been still for a few frames
	RT.set_anchored_position(far, Vector2(0, 0))
	for _f in range(RT.FIT_SETTLE_FRAMES + 3):
		await process_frame
	cfg = holder.get_meta(RT.META_CANVAS)
	ok(absf(cfg["plane_size"].x - 80.0) < 0.2 and absf(cfg["plane_size"].y - 45.0) < 0.2, "the plane shrinks to the content once it is still: " + str(cfg["plane_size"]))
	RT.set_anchored_position(far, Vector2(300, -200))
	await process_frame
	await process_frame
	near(rendered(far, Vector2(10, 10)), Vector3(-1 + 3.0, 2 - 2.0, 3), "... and grows at once when content leaves it", 2e-3)
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
	ok(RT.holder_of(panel) == null, "the canvas is not built inside the setter (the state may not last)")
	near(RT.world_position(img), Vector3(0.2, 1, 0), "world positions are right before the canvas exists")
	await process_frame
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
	RT.flush_promotions()
	ok(RT.holder_of(other) == null, "half a millimetre off the plane stays in the canvas")
	RT.set_local_position(other, Vector3(0, 0, 50))     # 0.5 m
	RT.flush_promotions()
	ok(RT.holder_of(other) != null, "half a metre off the plane becomes a canvas of its own")
	await process_frame
	# a state that does not last: out of the plane and back within one frame (SetParent keeping
	# the world position, then the local values are reset, as list entries are instantiated)
	var entry := Control.new()
	entry.name = "Entry"
	croot.add_child(entry)
	_rt(entry, {"size_delta": Vector2(10, 10)})
	RT.set_local_rotation(entry, Quaternion(Vector3(1, 0, 0), 1.0))
	RT.set_local_position(entry, Vector3(5, 5, 300))
	RT.set_local_rotation(entry, Quaternion.IDENTITY)
	RT.set_local_position(entry, Vector3(5, 5, 0))
	await process_frame
	ok(RT.holder_of(entry) == null and entry.get_parent() == croot, "a control that is back in the plane by the end of the frame stays a control")
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
	RT.flush_promotions()
	ok(RT.holder_of(img) == null, "a tilted control on a screen canvas stays flat")
	canvas.queue_free()
	await process_frame


func eq(a, b, what: String) -> void:
	ok(typeof(a) == typeof(b) and a == b, "%s: got %s, expected %s" % [what, str(a), str(b)])


## Unity rich text → BBCode and the characters shown.
## Plain Transforms that hold UI: a holder turned out of the canvas plane whose rects are turned
## back (vrcbce's desktop UI). The holder hands its rotation and scale down; the rects show the
## composed transform and keep their own Unity values.
func _plain_holders() -> void:
	var holder: Node3D = _canvas(Vector3(0, 1, 0), 0.01)
	var croot: Control = RT.root_control(holder)
	var flat := Control.new()
	flat.name = "Flat"
	flat.set_meta(RT.META_PLAIN, true)
	croot.add_child(flat)
	var down := Quaternion(Vector3(1, 0, 0), -PI / 2.0)
	var back := Quaternion(Vector3(1, 0, 0), PI / 2.0)
	_rt(flat, {"anchored_position": Vector2(30, 20), "size_delta": Vector2.ZERO, "rotation": down, "scale": Vector3(50, 50, 50)})
	near(flat.rotation, 0.0, "a plain holder does not turn as a Control")
	near(flat.scale, Vector2.ONE, "... nor scale")
	near(RT.local_rotation(flat), down, "... its rotation is still its own")
	near(RT.local_scale(flat), Vector3(50, 50, 50), "... and its scale")
	var img: TextureRect = _image(flat, "Img", {"anchored_position": Vector2(1.5, 0), "z": 0.4, "size_delta": Vector2(40, 20), "rotation": back, "scale": Vector3(0.02, 0.02, 0.02)})
	near(img.rotation, 0.0, "a rect turned back below it is in the plane again: no rotation")
	near(img.scale, Vector2(1, 1), "... the scales multiply (50 x 0.02)")
	near(RT.local_rotation(img), back, "... while its Unity rotation stays what it is")
	near(RT.local_scale(img), Vector3(0.02, 0.02, 0.02), "... and its scale")
	near(RT.local_position(img), Vector3(1.5, 0, 0.4), "... and its local position (in the holder's space)")
	near(RT.anchored_position(img), Vector2(1.5, 0), "... which is its anchored position")
	await process_frame
	await process_frame
	ok(RT.holder_of(flat) == null and RT.holder_of(img) == null, "nothing needs a canvas of its own: the composed transform is planar")
	# local (1.5, 0, 0.4) in the holder turned -90 degrees about x and scaled 50: (75, 20, 0)
	near(RT.world_position(img), Vector3(0.3 + 0.75, 1 + 0.2 + 0.2, 0), "world position through the holder", 1e-3)
	near(RT.drawn_point(img, img.size * 0.5), Vector3(0.3 + 0.75, 1 + 0.2 + 0.2, 0), "... and it is drawn there", 2e-3)
	near(RT.drawn_point(img, Vector2.ZERO), Vector3(0.3 + 0.75 - 0.2, 1 + 0.4 + 0.1, 0), "... as large as 40 x 20 units", 2e-3)
	# the holder turns: what is below it follows, and leaves the plane
	RT.set_local_rotation(flat, Quaternion.IDENTITY)
	near(img.scale, Vector2(1, 0), "the holder is turned: the rect below shows its new projection (edge on)", 1e-4)
	await process_frame
	await process_frame
	ok(RT.holder_of(img) != null and RT.holder_of(flat) == null, "... and gets a canvas of its own, the holder does not")
	near(RT.world_position(img), Vector3(0.3 + 0.75, 1.2, 0.2), "... at its place in space", 2e-3)
	# a holder that is off the plane (along z): what is below it is off the plane too
	var lifted := Control.new()
	lifted.name = "Lifted"
	lifted.set_meta(RT.META_PLAIN, true)
	croot.add_child(lifted)
	_rt(lifted, {"anchored_position": Vector2(-50, 0), "z": -30.0, "size_delta": Vector2.ZERO, "scale": Vector3(0.5, 0.5, 0.5)})
	var label: TextureRect = _image(lifted, "Label", {"anchored_position": Vector2(10, 0), "size_delta": Vector2(20, 10)})
	near(label.scale, Vector2(0.5, 0.5), "below a scaled holder: its scale")
	RT.promote_out_of_plane(holder)   # (what a canvas does at start for the values it was built with)
	await process_frame
	await process_frame
	ok(RT.holder_of(lifted) == null and RT.holder_of(label) != null, "a rect below a holder that is off the plane gets a canvas of its own")
	near(RT.world_position(label), Vector3(-0.5 + 0.05, 1, -0.3), "... at the holder's depth", 2e-3)
	near(RT.world_position(lifted), Vector3(-0.5, 1, -0.3), "... and the holder knows where it is", 2e-3)
	holder.queue_free()
	await process_frame
	# the same on a screen canvas, where nothing gets a canvas of its own
	var canvas := Node3D.new()
	canvas.name = "Overlay"
	root.add_child(canvas)
	var layer := CanvasLayer.new()
	canvas.add_child(layer)
	var sroot := Control.new()
	sroot.name = "Canvas"
	layer.add_child(sroot)
	sroot.size = Vector2(800, 600)
	canvas.set_meta(RT.META_CANVAS, {"mode": "overlay", "root": canvas.get_path_to(sroot)})
	var sflat := Control.new()
	sflat.name = "Flat"
	sflat.set_meta(RT.META_PLAIN, true)
	sroot.add_child(sflat)
	_rt(sflat, {"anchor_min": Vector2.ZERO, "anchor_max": Vector2.ZERO, "anchored_position": Vector2(200, 100), "size_delta": Vector2.ZERO, "rotation": down, "scale": Vector3(50, 50, 50)})
	var simg: TextureRect = _image(sflat, "Img", {"anchored_position": Vector2(0, 0), "size_delta": Vector2(100, 60), "rotation": back, "scale": Vector3(0.02, 0.02, 0.02)})
	var inner := Control.new()
	inner.name = "Inner"
	inner.set_meta(RT.META_PLAIN, true)
	sflat.add_child(inner)
	_rt(inner, {"anchored_position": Vector2(-1, 0), "z": -0.5, "size_delta": Vector2.ZERO})
	var deep: TextureRect = _image(inner, "Deep", {"anchored_position": Vector2(0, 0), "size_delta": Vector2(60, 60), "rotation": back, "scale": Vector3(0.01, 0.01, 0.01)})
	await process_frame
	near(simg.get_global_rect(), Rect2(150, 600 - 100 - 30, 100, 60), "screen canvas: the rect below a turned holder is whole", 0.01)
	near(inner.get_global_rect().position, Vector2(150, 600 - 100 + 25), "a holder inside the holder is placed in the turned space", 0.01)
	near(deep.get_global_rect(), Rect2(150 - 15, 600 - 100 + 25 - 15, 30, 30), "... and hands on what it was handed (50 x 0.01)", 0.01)
	var tilted := Control.new()
	tilted.name = "Tilted"
	tilted.set_meta(RT.META_PLAIN, true)
	sroot.add_child(tilted)
	_rt(tilted, {"anchor_min": Vector2.ZERO, "anchor_max": Vector2.ZERO, "anchored_position": Vector2(400, 300), "size_delta": Vector2.ZERO, "rotation": Quaternion(Vector3(1, 0, 0), PI / 3.0)})
	var timg: TextureRect = _image(tilted, "Img", {"anchored_position": Vector2(0, 0), "size_delta": Vector2(100, 100)})
	await process_frame
	near(timg.get_global_transform().basis_xform(timg.size), Vector2(100, 50), "what stays tilted is shortened on the screen (cos 60)", 0.01)
	canvas.queue_free()
	await process_frame


func _rich_text() -> void:
	eq(UiText.to_bbcode("plain", true, 0, 20.0), "plain", "plain text is unchanged")
	eq(UiText.to_bbcode("<b>B</b><i>I</i><u>U</u><s>S</s>", true, 0, 20.0), "[b]B[/b][i]I[/i][u]U[/u][s]S[/s]", "bold, italic, underline, strikethrough")
	eq(UiText.to_bbcode("<color=#FFD700>gold</color>", true, 0, 20.0), "[color=#FFD700]gold[/color]", "colour by hex")
	eq(UiText.to_bbcode("<color=red>r</color><color=green>g</color>", true, 0, 20.0), "[color=#ff0000]r[/color][color=#00ff00]g[/color]", "TextMeshPro colour names")
	eq(UiText.to_bbcode("<color=green>g</color>", true, 0, 20.0, false), "[color=#008000]g[/color]", "uGUI's green is darker")
	eq(UiText.to_bbcode("<#00ff00>short</color>", true, 0, 20.0), "[color=#00ff00]short[/color]", "TextMeshPro's short colour tag")
	eq(UiText.to_bbcode("<size=13>s</size>", true, 0, 20.0), "[font_size=13]s[/font_size]", "absolute size")
	eq(UiText.to_bbcode("<size=150%>s</size><size=+4>t</size><size=2em>u</size>", true, 0, 20.0), "[font_size=30]s[/font_size][font_size=24]t[/font_size][font_size=40]u[/font_size]", "relative sizes")
	eq(UiText.to_bbcode("<size=13>LocalPlayer", true, 0, 20.0), "[font_size=13]LocalPlayer[/font_size]", "an unclosed tag is closed")
	eq(UiText.to_bbcode("a<br>b", true, 0, 20.0), "a\nb", "line break")
	eq(UiText.to_bbcode("1<<2 <3 a<b", true, 0, 20.0), "1<<2 <3 a<b", "angle brackets that are no tags are text")
	eq(UiText.to_bbcode("<winner> x", true, 0, 20.0), "<winner> x", "an unknown tag is text")
	eq(UiText.to_bbcode("a[0] [b]", true, 0, 20.0), "a[lb]0] [lb]b]", "square brackets are not BBCode")
	eq(UiText.to_bbcode("<sprite name=\"x\">a<voffset=1em>b</voffset><link=\"id\">c</link>", true, 0, 20.0), "abc", "tags without a counterpart are dropped")
	eq(UiText.to_bbcode("<noparse><b>x</b></noparse>", true, 0, 20.0), "<b>x</b>", "noparse")
	eq(UiText.to_bbcode("<b>x</b>", false, 0, 20.0), "<b>x</b>", "rich text off: tags are text")
	eq(UiText.to_bbcode("x", true, UiText.BOLD | UiText.ITALIC, 20.0), "[b][i]x[/i][/b]", "bold italic style")
	eq(UiText.to_bbcode("Ab c", true, UiText.UPPER, 20.0), "AB C", "upper case style")
	eq(UiText.to_bbcode("Ab C", true, UiText.LOWER, 20.0), "ab c", "lower case style")
	eq(UiText.to_bbcode("Ab", true, UiText.SMALLCAPS, 20.0), "A[font_size=16]B[/font_size]", "small caps: capitals at 80 %")
	eq(UiText.to_bbcode("a<uppercase>b</uppercase>c", true, 0, 20.0), "aBc", "uppercase tag")
	eq(UiText.to_bbcode("<u>x</u> <b>y</b>", true, 0, 20.0, false), "<u>x</u> [b]y[/b]", "uGUI knows only b, i, size, color")
	eq(UiText.plain("<b>Bold</b> <color=#FFD700>gold</color> 1<<2 <unknown>", true, 0), "Bold gold 1<<2 <unknown>", "plain text of rich text")
	eq(UiText.plain("Small Caps", true, 35), "SMALL CAPS", "plain text of small caps")
	eq(UiText.plain("a<br>b", true, 0), "a\nb", "plain text keeps line breaks")


func _text(parent: Node, settings: Dictionary, size: Vector2) -> RichTextLabel:
	var t := RichTextLabel.new()
	t.name = "Text"
	t.size = size
	UiText.set_fonts(t)
	var s: Dictionary = {"tmp": true}
	s.merge(settings, true)
	t.set_meta(UiText.META, s)
	parent.add_child(t)
	UiText.render(t)
	return t


## Text nodes: what is rendered, what a setter changes, auto-sizing.
func _text_nodes() -> void:
	var host := Control.new()
	root.add_child(host)
	var t: RichTextLabel = _text(host, {"text": "<b>Hi</b> there", "size": 20.0}, Vector2(300, 40))
	eq(t.text, "[b]Hi[/b] there", "the text is rendered as BBCode")
	eq(t.get_parsed_text(), "Hi there", "... and shows no tags")
	eq(UiText.text(t), "<b>Hi</b> there", "the Unity string is kept")
	eq(t.get_theme_font_size("normal_font_size"), 20, "font size")
	ok(not t.clip_contents, "TextMeshPro's overflow mode draws outside the rect")
	UiText.set_text(t, "<size=13>LocalPlayer")
	eq(t.get_parsed_text(), "LocalPlayer", "a text set later goes through the same conversion")
	eq(UiText.text(t), "<size=13>LocalPlayer", "... and reads back as it was set")
	UiText.set_font_size(t, 31.6)
	eq(t.get_theme_font_size("normal_font_size"), 32, "font size setter")
	near(UiText.font_size(t), 31.6, "... keeps the exact Unity value")
	ok(t.get_theme_font("normal_font") == UiText.FONTS[0] and t.get_theme_font("bold_font") == UiText.FONTS[1], "the default family is set")
	# auto-sizing: the largest size that fits
	var a: RichTextLabel = _text(host, {"text": "Auto sized text that has to shrink", "size": 60.0, "auto": true, "min": 8.0, "max": 60.0}, Vector2(200, 30))
	var fit := Node.new()
	fit.name = UiText.HELPER
	fit.set_script(TextFit)
	a.add_child(fit)
	await process_frame
	await process_frame
	var fitted: int = a.get_theme_font_size("normal_font_size")
	ok(fitted >= 8 and fitted < 60, "an auto-sized text shrinks: %d" % fitted)
	ok(a.get_content_height() <= 30.5 and a.get_content_width() <= 200.5, "... until it fits its rect: %d x %d" % [a.get_content_width(), a.get_content_height()])
	a.size = Vector2(400, 60)
	await process_frame
	await process_frame
	ok(a.get_theme_font_size("normal_font_size") > fitted, "... and grows with the rect: %d" % a.get_theme_font_size("normal_font_size"))
	a.size = Vector2(400, 80)
	UiText.set_text(a, "x")
	eq(a.get_theme_font_size("normal_font_size"), 60, "a short text in a rect that is high enough takes the maximum size")
	# a text higher than its rect: every line is drawn, around the alignment point
	var o: RichTextLabel = _text(host, {"text": "one<br>two<br>three", "size": 20.0, "overflow": 0}, Vector2(200, 30))
	o.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var ofit := Node.new()
	ofit.name = UiText.HELPER
	ofit.set_script(TextFit)
	o.add_child(ofit)
	await process_frame
	await process_frame
	var drawer: RichTextLabel = o.get_node_or_null(UiText.DRAWER) as RichTextLabel
	ok(drawer != null, "a text that runs out of its rect gets a drawing child")
	if drawer != null:
		var content: float = float(o.get_content_height())
		ok(content > 60.0, "three lines of 20 are higher than the rect of 30: %.0f" % content)
		near(drawer.size, Vector2(200, content), "the child is as high as the content")
		near(drawer.position.y, (30.0 - content) * 0.5, "... centred on the rect (middle alignment)")
		eq(drawer.get_parsed_text(), "one\ntwo\nthree", "... and draws the text")
		eq(o.visible_characters, 0, "the node itself draws no glyphs")
		eq(o.get_parsed_text(), "one\ntwo\nthree", "... but still holds the text")
		ok(drawer.has_meta(RT.META_HELPER) and not RT.logical_children(o).has(drawer), "the child is no object of the scene")
		o.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		UiText.layout(o)
		near(drawer.position.y, 30.0 - content, "bottom alignment: the text grows upwards")
		Graphic.update(o, {"color": Color(1, 0, 0, 1)})
		eq(drawer.get_theme_color("default_color"), Color(1, 0, 0, 1), "the colour of the text reaches the child")
	UiText.set_text(o, "one")
	ok(o.get_node_or_null(UiText.DRAWER) == null and o.visible_characters == -1, "a text that fits again is drawn by the node itself")
	o.size = Vector2(200, 10)
	await process_frame
	ok(o.get_node_or_null(UiText.DRAWER) != null, "a rect that shrinks below one line: the child is back")
	# a text that is truncated shows the lines that fit entirely, placed by the alignment
	var cut: RichTextLabel = _text(host, {"text": "one<br>two<br>three", "size": 20.0, "overflow": 3}, Vector2(200, 50))
	cut.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	await process_frame
	UiText.layout(cut)
	var cut_drawer: RichTextLabel = cut.get_node_or_null(UiText.DRAWER) as RichTextLabel
	ok(cut_drawer != null and cut.clip_contents, "a truncated text higher than its rect is drawn by the child too, inside the rect")
	if cut_drawer != null:
		var two: float = cut.get_line_offset(2)
		ok(two <= 50.5 and float(cut.get_content_height()) > 50.5, "two of three lines fit a rect of 50: %.0f of %d" % [two, cut.get_content_height()])
		eq(cut_drawer.visible_characters, 8, "... and only they are shown (the characters of 'one' and 'two' with their line ends)")
		near(cut_drawer.position.y, (50.0 - two) * 0.5, "... centred as two lines")
	UiText.update(cut, {"overflow": 2})
	cut_drawer = cut.get_node_or_null(UiText.DRAWER) as RichTextLabel
	ok(cut_drawer != null and cut_drawer.visible_characters == -1 and cut.clip_contents, "a masked text is drawn whole and clipped at the rect")
	# TextMeshPro's Ellipsis mode: the text ends in an ellipsis where it is cut
	var ell: RichTextLabel = _text(host, {"text": "one<br>two<br>three", "size": 20.0, "overflow": 1}, Vector2(200, 50))
	await process_frame
	UiText.layout(ell)
	var ell_drawer: RichTextLabel = ell.get_node_or_null(UiText.DRAWER) as RichTextLabel
	ok(ell_drawer != null, "an Ellipsis text higher than its rect is drawn by the child")
	if ell_drawer != null:
		eq(ell_drawer.get_parsed_text(), "one\ntwo…", "the lines that fit, the last one ending in the ellipsis")
		eq(ell.get_parsed_text(), "one\ntwo\nthree", "... while the node keeps the whole text")
		eq(UiText.text(ell), "one<br>two<br>three", "... and the Unity string")
	# ... and a line that is not wrapped is cut at the rect's width
	var name_text: String = "A player name that is much too long for its column"
	var wide: RichTextLabel = _text(host, {"text": "<b>" + name_text + "</b>", "size": 20.0, "overflow": 1, "wrap": false}, Vector2(160, 30))
	await process_frame
	UiText.layout(wide)
	var wide_drawer: RichTextLabel = wide.get_node_or_null(UiText.DRAWER) as RichTextLabel
	ok(wide_drawer != null and float(wide.get_content_width()) > 160.0, "a line wider than its rect, not wrapped")
	if wide_drawer != null:
		var shown: String = wide_drawer.get_parsed_text()
		ok(shown.ends_with("…") and shown.length() > 4 and name_text.begins_with(shown.trim_suffix("…")), "... shows its beginning and an ellipsis: " + shown)
		ok(float(wide_drawer.get_content_width()) <= 160.5, "... which fit the rect: %d" % wide_drawer.get_content_width())
		ok(not shown.trim_suffix("…").ends_with(" "), "... without a blank before the ellipsis")
		ok(wide_drawer.text.begins_with("[b]"), "... in the text's style")
		# more would not fit (two characters: the next one may be a blank, which is not shown
		# before the ellipsis)
		var longer: String = UiText.to_bbcode("<b>" + name_text + "</b>", true, 0, 20.0, true, shown.length() + 1, "…")
		wide_drawer.text = longer
		ok(float(wide_drawer.get_content_width()) > 160.5, "... and more of it would not")
		UiText.layout(wide)
	UiText.update(wide, {"overflow": 3})
	wide_drawer = wide.get_node_or_null(UiText.DRAWER) as RichTextLabel
	ok(wide_drawer != null and not wide_drawer.get_parsed_text().ends_with("…") and name_text.begins_with(wide_drawer.get_parsed_text()) and float(wide_drawer.get_content_width()) <= 160.5,
		"Truncate cuts the line at the rect without an ellipsis: " + (wide_drawer.get_parsed_text() if wide_drawer != null else "no child"))
	UiText.set_text(wide, "Short")
	ok(wide.get_node_or_null(UiText.DRAWER) == null, "a line that fits is drawn by the node itself")
	eq(UiText.visible_length("a<b>bc</b><br>d <unknown>", true, true), 15, "the characters a text shows: tags are not counted, a break is one, an unknown tag is text")
	eq(UiText.to_bbcode("ab<br>cd", true, 0, 20.0, true, 3, "…"), "ab\n…", "a cut at a line's first character")
	# a hand-built Label has no Unity settings: the plain properties are used
	var l := Label.new()
	host.add_child(l)
	UiText.set_text(l, "<b>raw</b>")
	eq(l.text, "<b>raw</b>", "a Label without settings gets the string as it is")
	eq(UiText.text(l), "<b>raw</b>", "... and gives it back")
	# TextMeshPro in 3D: the font size is in tenths of a unit
	var l3 := Label3D.new()
	l3.font_size = 64
	l3.set_meta(UiText.META, {"text": "<b>W</b>inner", "tmp": true, "size": 2.0, "style": UiText.UPPER})
	host.add_child(l3)
	UiText.render(l3)
	eq(l3.text, "WINNER", "3D text shows no tags and is cased")
	near(l3.pixel_size, 0.2 / 64.0, "3D text: font size 2 is an em of 0.2 units", 1e-6)
	host.queue_free()
	await process_frame


## Graphic colour × CanvasRenderer colour × enabled.
func _graphics() -> void:
	var img := TextureRect.new()
	img.texture = PlaceholderTexture2D.new()
	Graphic.update(img, {"color": Color(0.5, 1, 1, 1)})
	eq(img.self_modulate, Color(0.5, 1, 1, 1), "an image is tinted by its colour")
	Graphic.set_renderer_color(img, Color(1, 0.5, 1, 0.5))
	eq(img.self_modulate, Color(0.5, 0.5, 1, 0.5), "... times the CanvasRenderer colour")
	eq(Graphic.color(img), Color(0.5, 1, 1, 1), "the graphic's own colour is kept apart")
	Graphic.set_enabled(img, false)
	eq(img.self_modulate.a, 0.0, "a disabled graphic draws nothing")
	ok(img.visible, "... but its object (and children) stay")
	ok(not Graphic.enabled(img), "enabled reads back")
	Graphic.set_enabled(img, true)
	eq(img.self_modulate, Color(0.5, 0.5, 1, 0.5), "enabled again: the colour is back")
	Graphic.set_renderer_alpha(img, 0.0)
	eq(Graphic.drawn_color(img).a, 0.0, "CanvasRenderer alpha 0")
	img.free()
	# without metadata the control's own state is the start
	var plain := TextureRect.new()
	plain.self_modulate = Color(1, 0, 0, 1)
	Graphic.set_enabled(plain, false)
	Graphic.set_enabled(plain, true)
	eq(plain.self_modulate, Color(1, 0, 0, 1), "a hand-built image keeps its colour through enabled")
	plain.free()
	var text := RichTextLabel.new()
	Graphic.update(text, {"color": Color(1, 1, 0, 1)})
	eq(text.get_theme_color("default_color"), Color(1, 1, 0, 1), "a text's colour is its default colour")
	Graphic.set_renderer_alpha(text, 0.25)
	near(text.self_modulate.a, 0.25, "... faded by the CanvasRenderer alpha")
	text.free()
	# an Image on a widget is its background
	var button := Button.new()
	Graphic.update(button, {"color": Color(0.2, 0.4, 0.6, 1)})
	var box: StyleBox = button.get_theme_stylebox("normal")
	ok(box is StyleBoxFlat and (box as StyleBoxFlat).bg_color == Color(0.2, 0.4, 0.6, 1), "a button's image is its style box")
	ok(button.get_theme_stylebox("hover") == box and button.get_theme_stylebox("pressed") == box, "... in every state (Unity tints by the CanvasRenderer)")
	Graphic.set_renderer_color(button, Color(1, 1, 1, 0))
	ok(button.get_theme_stylebox("normal") is StyleBoxEmpty, "normal colour with alpha 0: the button draws no background")
	Graphic.set_renderer_color(button, Color(0.5, 0.5, 0.5, 1))
	ok(button.get_theme_stylebox("normal") != box and (button.get_theme_stylebox("normal") as StyleBoxFlat).bg_color == Color(0.1, 0.2, 0.3, 1), "a tint makes a new box (boxes of a saved scene are shared by its instances)")
	Graphic.set_enabled(button, false)
	ok(button.get_theme_stylebox("normal") is StyleBoxEmpty, "a disabled Image on a button draws nothing")
	button.free()


func _slider(parent: Control, direction: int, value: float, lo: float = 0.0, hi: float = 1.0) -> Array:
	var s: Range = VSlider.new() if direction >= 2 else HSlider.new()
	s.name = "Slider"
	s.min_value = lo
	s.max_value = hi
	s.step = 0.0
	s.value = value
	parent.add_child(s)
	_rt(s, {"size_delta": Vector2(20, 160) if direction >= 2 else Vector2(160, 20)})
	var area := Control.new()
	area.name = "Area"
	s.add_child(area)
	_rt(area, {"anchor_min": Vector2(0, 0), "anchor_max": Vector2(1, 1), "size_delta": Vector2.ZERO})
	var fill: TextureRect = _image(area, "Fill", {"anchor_min": Vector2(0, 0), "anchor_max": Vector2(0.9, 0.8), "size_delta": Vector2(10, 0)})
	var handle: TextureRect = _image(area, "Handle", {"anchor_min": Vector2(0.9, 0.1), "anchor_max": Vector2(0.9, 0.9), "size_delta": Vector2(20, 0)})
	s.set_meta(Selectable.META, {"direction": direction, "fill": s.get_path_to(fill), "handle": s.get_path_to(handle), "target": s.get_path_to(handle),
		"colors": {"normalColor": Color(1, 1, 1, 1), "disabledColor": Color(0.5, 0.5, 0.5, 0.5), "pressedColor": Color(0.2, 0.2, 0.2, 1)}})
	return [s, fill, handle]


## Selectables: Slider.UpdateVisuals, the Toggle's check mark, colour tints.
func _selectables() -> void:
	var host := Control.new()
	host.size = Vector2(400, 400)
	root.add_child(host)
	# the importer's static pass: no helper node, nothing running
	var a: Array = _slider(host, 0, 0.25)
	Selectable.refresh_static(a[0])
	near(RT.anchor_max(a[1]), Vector2(0.25, 1), "left to right: the fill ends at the value")
	near(RT.anchor_min(a[1]), Vector2(0, 0), "... and starts at the start")
	near(RT.size_delta(a[1]), Vector2(10, 0), "... keeping its size delta")
	near(RT.anchor_min(a[2]), Vector2(0.25, 0), "the handle is anchored at the value")
	near(RT.anchor_max(a[2]), Vector2(0.25, 1), "... on the whole other axis")
	a = _slider(host, 1, 0.25)
	Selectable.refresh_static(a[0])
	near(RT.anchor_min(a[1]), Vector2(0.75, 0), "right to left: the fill starts at 1 - value")
	near(RT.anchor_max(a[1]), Vector2(1, 1), "... and ends at the end")
	near(RT.anchor_min(a[2]), Vector2(0.75, 0), "right to left handle")
	a = _slider(host, 2, 0.6)
	Selectable.refresh_static(a[0])
	near(RT.anchor_max(a[1]), Vector2(1, 0.6), "bottom to top fill")
	near(RT.anchor_min(a[2]), Vector2(0, 0.6), "bottom to top handle")
	a = _slider(host, 3, 0.6)
	Selectable.refresh_static(a[0])
	near(RT.anchor_min(a[1]), Vector2(0, 0.4), "top to bottom fill")
	near(RT.anchor_max(a[2]), Vector2(1, 0.4), "top to bottom handle")
	a = _slider(host, 0, 0.0, -10.0, 30.0)
	Selectable.refresh_static(a[0])
	near(RT.anchor_max(a[1]), Vector2(0.25, 1), "the value is normalized by the range")
	# running: the helper follows the value and the state
	var helper := Node.new()
	helper.name = Selectable.HELPER
	helper.set_script(Selectable)
	a[0].add_child(helper)
	await process_frame
	(a[0] as Range).value = 10.0
	near(RT.anchor_max(a[1]), Vector2(0.5, 1), "a value set later moves the fill")
	near(RT.anchor_min(a[2]), Vector2(0.5, 0), "... and the handle")
	await process_frame
	near(a[2].size.x, 20.0, "the handle keeps its width")
	near(a[2].position.x + 10.0, 80.0, "... centred on the value (in a 160 wide area)", 0.01)
	eq(Graphic.renderer_color(a[2]), Color(1, 1, 1, 1), "normal colour on the target graphic")
	(a[0] as Slider).editable = false
	Selectable.refresh_host(a[0])
	eq(Graphic.renderer_color(a[2]), Color(0.5, 0.5, 0.5, 0.5), "disabled colour when not interactable")
	(a[0] as Slider).editable = true
	Selectable.apply(a[0], "pressed")
	eq(Graphic.renderer_color(a[2]), Color(0.2, 0.2, 0.2, 1), "pressed colour")
	# toggle
	var toggle := Button.new()
	toggle.toggle_mode = true
	host.add_child(toggle)
	var back: TextureRect = _image(toggle, "Background", {"size_delta": Vector2(20, 20)})
	var mark: TextureRect = _image(back, "Checkmark", {"size_delta": Vector2(16, 16)})
	Graphic.update(mark, {"color": Color(0.1, 0.1, 0.1, 1)})
	toggle.set_meta(Selectable.META, {"graphic": toggle.get_path_to(mark), "target": toggle.get_path_to(back), "colors": {"normalColor": Color(1, 1, 1, 0), "colorMultiplier": 1.0}})
	Selectable.refresh_static(toggle)
	eq(mark.self_modulate.a, 0.0, "the check mark of a toggle that is off is not drawn")
	eq(back.self_modulate.a, 0.0, "a normal colour with alpha 0 hides the target graphic")
	var thelper := Node.new()
	thelper.name = Selectable.HELPER
	thelper.set_script(Selectable)
	toggle.add_child(thelper)
	toggle.button_pressed = true
	eq(mark.self_modulate, Color(0.1, 0.1, 0.1, 1), "isOn shows the check mark")
	toggle.set_pressed_no_signal(false)
	Selectable.refresh_host(toggle)
	eq(mark.self_modulate.a, 0.0, "... and off without a signal, refreshed by the caller")
	# canvas groups: a group that is not interactable disables the selectables below it
	var group := Control.new()
	host.add_child(group)
	var gbutton := Button.new()
	group.add_child(gbutton)
	Graphic.update(gbutton, {"color": Color.WHITE})
	gbutton.set_meta(Selectable.META, {"target": NodePath("."), "colors": {"normalColor": Color(1, 1, 1, 1), "disabledColor": Color(0.5, 0.5, 0.5, 0.5)}})
	var ghelper := Node.new()
	ghelper.name = Selectable.HELPER
	ghelper.set_script(Selectable)
	gbutton.add_child(ghelper)
	eq(Graphic.renderer_color(gbutton), Color(1, 1, 1, 1), "a button below a group that allows interaction: normal colour")
	UiGroup.update(group, {"interactable": false, "alpha": 0.5})
	ok(not Selectable.interactable(gbutton) and not gbutton.disabled, "a group that is not interactable stops the button (its own flag stays)")
	eq(Graphic.renderer_color(gbutton), Color(0.5, 0.5, 0.5, 0.5), "... which shows its disabled colour at once")
	eq(group.mouse_behavior_recursive, Control.MOUSE_BEHAVIOR_DISABLED, "... and takes no pointer input, nor does anything below")
	near(group.modulate.a, 0.5, "the group's alpha fades everything below")
	var inner_group := Control.new()
	group.add_child(inner_group)
	var ibutton := Button.new()
	inner_group.add_child(ibutton)
	UiGroup.update(inner_group, {"ignoreParentGroups": true})
	ok(Selectable.interactable(ibutton), "a group that ignores its parents starts over")
	eq(inner_group.mouse_behavior_recursive, Control.MOUSE_BEHAVIOR_ENABLED, "... for the pointer too")
	UiGroup.update(group, {"interactable": true})
	eq(Graphic.renderer_color(gbutton), Color(1, 1, 1, 1), "interactable again: normal colour")
	eq(group.mouse_behavior_recursive, Control.MOUSE_BEHAVIOR_INHERITED, "... and input as before")
	# colour multiplier
	var cfg: Dictionary = toggle.get_meta(Selectable.META).duplicate(true)
	cfg["colors"] = {"normalColor": Color(0.4, 0.4, 0.4, 1), "colorMultiplier": 2.0}
	toggle.set_meta(Selectable.META, cfg)
	Selectable.refresh_host(toggle)
	near(Graphic.renderer_color(back).r, 0.8, "the colour multiplier")
	eq(Graphic.renderer_color(back).a, 1.0, "... clamped")
	eq(Selectable.colors(toggle)["pressedColor"], Selectable.DEFAULT_COLORS["pressedColor"], "missing colours of the block are Unity's defaults")
	host.queue_free()
	await process_frame


## Sliced and filled sprites: Unity's geometry (Image.GenerateSlicedSprite, GetAdjustedBorders,
## GenerateFilledSprite), numbers worked out by hand. Borders are [left, top, right, bottom].
func _sprites() -> void:
	var b16: Array = [16, 16, 16, 16]
	near(Sprite.slice_scale(Vector2(200, 100), b16, 1.0), Vector2(1, 1), "borders at their size in a rect that has room")
	near(Sprite.slice_scale(Vector2(20, 80), b16, 1.0), Vector2(0.625, 1), "32 units of borders in 20: both shrink to 10")
	near(Sprite.slice_scale(Vector2(24, 24), b16, 1.0), Vector2(0.75, 0.75), "... on each axis by itself")
	near(Sprite.slice_scale(Vector2(160, 60), b16, 0.5), Vector2(0.5, 0.5), "pixels per unit multiplier 2: 8 unit borders")
	near(Sprite.slice_scale(Vector2(10, 10), [10, 10, 10, 10], 0.5), Vector2(0.5, 0.5), "a built-in sprite at 200 pixels per unit: 5 unit borders fit 10 exactly")
	near(Sprite.slice_scale(Vector2(100, 100), [0, 0, 0, 0], 1.0), Vector2(1, 1), "no borders")
	var s64 := Vector2(64, 64)
	near(Sprite.slice_texel(Vector2(8, 8), Vector2(200, 100), s64, b16, 1.0), Vector2(8, 8), "the top-left corner is drawn 1:1")
	near(Sprite.slice_texel(Vector2(192, 92), Vector2(200, 100), s64, b16, 1.0), Vector2(56, 56), "the bottom-right corner too, from its own end")
	near(Sprite.slice_texel(Vector2(100, 50), Vector2(200, 100), s64, b16, 1.0), Vector2(32, 32), "the centre is stretched: its middle is the sprite's middle")
	near(Sprite.slice_texel(Vector2(58, 8), Vector2(200, 100), s64, b16, 1.0), Vector2(24, 8), "the top edge is stretched along x only: 42 of 168 units in is 8 of 32 pixels")
	near(Sprite.slice_texel(Vector2(5, 40), Vector2(20, 80), s64, b16, 1.0), Vector2(8, 32), "shrunk borders: 5 of 10 units is 8 of 16 pixels")
	near(Sprite.slice_texel(Vector2(4, 4), Vector2(160, 60), s64, b16, 0.5), Vector2(8, 8), "multiplier 2: 4 units in is 8 pixels in")
	var r: Array = Sprite.fill_rects(Vector2(128, 32), Vector2(64, 16), 0, 0, 0.25)
	near(r[0], Rect2(0, 0, 32, 32), "horizontal fill from the left, a quarter: the left quarter of the rect")
	near(r[1], Rect2(0, 0, 16, 16), "... shows the left quarter of the sprite")
	r = Sprite.fill_rects(Vector2(128, 32), Vector2(64, 16), 0, 1, 0.75)
	near(r[0], Rect2(32, 0, 96, 32), "from the right, three quarters")
	near(r[1], Rect2(16, 0, 48, 16), "... the right three quarters of the sprite")
	r = Sprite.fill_rects(Vector2(64, 96), Vector2(64, 64), 1, 0, 0.5)
	near(r[0], Rect2(0, 48, 64, 48), "vertical fill from the bottom, half: the lower half")
	near(r[1], Rect2(0, 32, 64, 32), "... of the sprite as well")
	r = Sprite.fill_rects(Vector2(64, 96), Vector2(64, 64), 1, 1, 0.25)
	near(r[0], Rect2(0, 0, 64, 24), "from the top, a quarter")
	near(r[1], Rect2(0, 0, 64, 16), "... the upper quarter of the sprite")
	_radial_fills()
	# tiled (Image.GenerateTiledSprite): a 64 pixel sprite with 16 pixel borders in 150 x 90
	var q: Array = Sprite.tiled_quads(Vector2(150, 90), s64, b16, 1.0, true)
	# centre 118 x 58 in tiles of 32: 4 x 2 (the last of each cut), + 2 x 2 side and 2 x 4 top /
	# bottom edge pieces + 4 corners
	eq(q.size(), 8 + 4 + 8 + 4, "tiled with borders: centre tiles, edge pieces and corners")
	near(q[0][0], Rect2(16, 42, 32, 32), "the first centre tile sits at the bottom-left of the centre")
	near(q[0][1], Rect2(16, 16, 32, 32), "... and shows the sprite's centre")
	near(q[3][0], Rect2(112, 42, 22, 32), "the last tile of the row is cut at the right border")
	near(q[3][1], Rect2(16, 16, 22, 32), "... and shows the left part of the centre")
	near(q[4][0], Rect2(16, 16, 32, 26), "the upper row is cut at the top border")
	near(q[4][1], Rect2(16, 22, 32, 26), "... and shows the lower part of the centre (tiles grow from the bottom)")
	near(Sprite.tiled_texel(Vector2(8, 82), Vector2(150, 90), s64, b16, 1.0, true), Vector2(8, 56), "the bottom-left corner is the sprite's")
	near(Sprite.tiled_texel(Vector2(8, 50), Vector2(150, 90), s64, b16, 1.0, true), Vector2(8, 24), "the left edge repeats along y")
	ok(Sprite.tiled_texel(Vector2(60, 50), Vector2(150, 90), s64, b16, 1.0, false) == null, "without fill centre the middle is empty")
	q = Sprite.tiled_quads(Vector2(160, 40), Vector2(64, 16), [0, 0, 0, 0], 1.0, true)
	eq(q.size(), 9, "tiled without borders: 2.5 x 2.5 copies of the sprite")
	near(q[0][0], Rect2(0, 24, 64, 16), "... from the bottom-left corner")
	near(q[8][0], Rect2(128, 0, 32, 8), "... the last one cut on both axes")
	near(q[8][1], Rect2(0, 8, 32, 8), "... to its lower left part")
	# the helper is coloured by the graphic's state, the control itself draws nothing
	var img := TextureRect.new()
	img.texture = PlaceholderTexture2D.new()
	var helper := Control.new()
	helper.name = Sprite.HELPER
	helper.set_script(Sprite)
	img.add_child(helper)
	Graphic.update(img, {"color": Color(0.5, 1, 1, 1), "sprite": {"type": 1, "border": b16, "unit": 1.0, "center": true}})
	eq(helper.self_modulate, Color(0.5, 1, 1, 1), "a sliced sprite is drawn by the helper in the graphic's colour")
	eq(img.self_modulate.a, 0.0, "... and the control itself draws nothing")
	Graphic.set_enabled(img, false)
	eq(helper.self_modulate.a, 0.0, "a disabled sliced Image draws nothing")
	img.free()




## A Unity scroll view: 200 x 200, viewport stretched over it (pivot top-left), content 500 high
## anchored to the viewport's top, a vertical scrollbar at the right edge.
func _scroll_view(parent: Control, content_height: float, visibility: int) -> Array:
	var host := Control.new()
	host.name = "Scroll"
	parent.add_child(host)
	_rt(host, {"size_delta": Vector2(200, 200)})
	var view := Control.new()
	view.name = "Viewport"
	view.clip_contents = true
	host.add_child(view)
	_rt(view, {"anchor_min": Vector2(0, 0), "anchor_max": Vector2(1, 1), "pivot": Vector2(0, 1), "size_delta": Vector2.ZERO})
	var content := Control.new()
	content.name = "Content"
	view.add_child(content)
	_rt(content, {"anchor_min": Vector2(0, 1), "anchor_max": Vector2(1, 1), "pivot": Vector2(0, 1), "size_delta": Vector2(0, content_height)})
	var bar := VScrollBar.new()
	bar.name = "Bar"
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.step = 0.0
	bar.page = 0.0
	host.add_child(bar)
	_rt(bar, {"anchor_min": Vector2(1, 0), "anchor_max": Vector2(1, 1), "pivot": Vector2(1, 1), "size_delta": Vector2(20, 0)})
	var area := Control.new()
	area.name = "Area"
	bar.add_child(area)
	_rt(area, {"anchor_min": Vector2(0, 0), "anchor_max": Vector2(1, 1), "size_delta": Vector2(-20, -20)})
	var handle: TextureRect = _image(area, "Handle", {"anchor_min": Vector2(0, 0), "anchor_max": Vector2(1, 0.2), "size_delta": Vector2(20, 20)})
	bar.set_meta(&"unidot_scrollbar", {"direction": 2, "size": 0.2})
	bar.set_meta(Selectable.META, {"transition": 0, "handle": bar.get_path_to(handle), "direction": 2})
	host.set_meta(Scroll.META, {"content": host.get_path_to(content), "viewport": host.get_path_to(view), "vbar": host.get_path_to(bar),
		"horizontal": false, "vertical": true, "movement": 2, "sensitivity": 20.0, "visibility": [0, visibility], "spacing": [0.0, -3.0]})
	return [host, view, content, bar, handle]


## ScrollRect: bounds, normalized position, clamping, scrollbar size / value / handle, the
## viewport that makes room for the bar. Numbers by Unity's rules.
func _scroll_rect() -> void:
	var parent := Control.new()
	parent.size = Vector2(600, 600)
	root.add_child(parent)
	var s: Array = _scroll_view(parent, 500.0, 0)
	await process_frame
	Scroll.update(s[0])
	near(Scroll.normalized(s[0]), Vector2(0, 1), "content at the top: normalized position (0, 1)")
	near((s[3] as Range).value, 1.0, "the scrollbar's value is the normalized position")
	near(float(s[3].get_meta(&"unidot_scrollbar")["size"]), 0.4, "its size is the share of the content in view (200 of 500)")
	near(RT.anchor_min(s[4]), Vector2(0, 0.6), "the handle spans that share, at the top (Scrollbar.UpdateVisuals)")
	near(RT.anchor_max(s[4]), Vector2(1, 1.0), "... up to the end")
	near(RT.rect_size(s[1]), Vector2(200, 200), "a permanent scrollbar leaves the viewport alone")
	Scroll.set_normalized(s[0], 0.0, 1)
	near(RT.anchored_position(s[2]), Vector2(0, 300), "normalized 0: the content moved up by what was hidden")
	Scroll.update(s[0])
	near((s[3] as Range).value, 0.0, "... and the bar follows")
	near(RT.anchor_max(s[4]), Vector2(1, 0.4), "... with its handle at the bottom")
	Scroll.set_normalized(s[0], 0.5, 1)
	near(RT.anchored_position(s[2]), Vector2(0, 150), "normalized 0.5: half way")
	Scroll.scroll_by(s[0], Vector2(0, 1000))
	near(RT.anchored_position(s[2]), Vector2(0, 300), "scrolling past the end stops at the end (clamped)")
	Scroll.scroll_by(s[0], Vector2(50, -20))
	near(RT.anchored_position(s[2]), Vector2(0, 280), "a horizontal delta does nothing on a vertical rect")
	RT.set_anchored_position(s[2], Vector2(0, 900))
	Scroll.update(s[0])
	near(RT.anchored_position(s[2]), Vector2(0, 300), "content put outside the view is brought back")
	# a helper node: the bar scrolls the rect, the rect raises `scrolled`
	var helper := Node.new()
	helper.name = Scroll.HELPER
	helper.set_script(Scroll)
	s[0].add_child(helper)
	var events: Array = []
	helper.scrolled.connect(func(v: Vector2) -> void: events.append(v))
	await process_frame
	await process_frame
	(s[3] as Range).value = 1.0
	near(RT.anchored_position(s[2]), Vector2(0, 0), "scrollbar.value = 1 scrolls to the top")
	await process_frame
	await process_frame
	ok(events.size() >= 1 and (events[-1] as Vector2).is_equal_approx(Vector2(0, 1)), "onValueChanged was raised with the normalized position: " + str(events))
	# content smaller than the view: nothing to scroll, the bar is full
	var small: Array = _scroll_view(parent, 120.0, 1)
	await process_frame
	Scroll.update(small[0])
	near(float(small[3].get_meta(&"unidot_scrollbar")["size"]), 1.0, "content that fits: the handle fills the bar")
	ok(not (small[3] as Control).visible, "... and an auto-hiding bar is hidden")
	Scroll.scroll_by(small[0], Vector2(0, 50))
	near(RT.anchored_position(small[2]), Vector2(0, 0), "... and nothing scrolls")
	# auto hide and expand: the viewport gives way to the bar while it is needed
	var expand: Array = _scroll_view(parent, 500.0, 2)
	await process_frame
	Scroll.update(expand[0])
	near(RT.rect_size(expand[1]), Vector2(183, 200), "the viewport makes room for the bar (20 wide, spacing -3)")
	ok((expand[3] as Control).visible, "... which is shown")
	RT.set_size_delta(expand[2], Vector2(0, 100))
	Scroll.update(expand[0])
	near(RT.rect_size(expand[1]), Vector2(200, 200), "content that fits again: the viewport is whole")
	ok(not (expand[3] as Control).visible, "... and the bar hidden")
	parent.queue_free()
	await process_frame


func _in_quads(quads: Array, p: Vector2) -> bool:
	for q in quads:
		if Geometry2D.is_point_in_polygon(p, PackedVector2Array(q)):
			return true
	return false


## Radial fills: the quads Unity builds (Image.GenerateFilledSprite / RadialCut) against the
## meaning of the fill, a swept angle. Points are in the rect's proportions, y up.
func _radial_fills() -> void:
	var q: Array = Sprite.radial_quads(4, 0, 0.25, true)
	ok(q.size() == 1, "radial 360 from the bottom, clockwise, a quarter: one quad")
	if q.size() == 1:
		near(q[0][0], Vector2(0, 0), "... the bottom-left quarter")
		near(q[0][2], Vector2(0.5, 0.5), "... up to the centre")
	q = Sprite.radial_quads(4, 0, 0.125, true)
	ok(_in_quads(q, Vector2(0.4, 0.1)) and not _in_quads(q, Vector2(0.1, 0.4)), "an eighth: the triangle between straight down and the bottom-left corner")
	q = Sprite.radial_quads(4, 0, 0.125, false)
	ok(_in_quads(q, Vector2(0.6, 0.1)) and not _in_quads(q, Vector2(0.4, 0.1)), "counter-clockwise: towards the bottom-right corner")
	q = Sprite.radial_quads(4, 2, 0.6, true)
	ok(_in_quads(q, Vector2(0.9, 0.9)) and _in_quads(q, Vector2(0.9, 0.1)) and _in_quads(q, Vector2(0.45, 0.1)) and not _in_quads(q, Vector2(0.1, 0.2)) and not _in_quads(q, Vector2(0.1, 0.9)),
		"from the top, clockwise, 0.6: the right half and a little past the bottom")
	q = Sprite.radial_quads(3, 0, 0.5, true)
	ok(_in_quads(q, Vector2(0.25, 0.5)) and not _in_quads(q, Vector2(0.75, 0.5)), "radial 180 from the bottom, clockwise, half: the left half")
	q = Sprite.radial_quads(3, 0, 0.5, false)
	ok(_in_quads(q, Vector2(0.75, 0.5)) and not _in_quads(q, Vector2(0.25, 0.5)), "... counter-clockwise: the right half")
	q = Sprite.radial_quads(3, 1, 0.25, true)
	ok(_in_quads(q, Vector2(0.2, 0.9)) and not _in_quads(q, Vector2(0.8, 0.7)) and not _in_quads(q, Vector2(0.5, 0.2)), "radial 180 from the left, clockwise, a quarter: the upper-left triangle")
	q = Sprite.radial_quads(2, 0, 0.5, true)
	ok(_in_quads(q, Vector2(0.2, 0.8)) and not _in_quads(q, Vector2(0.8, 0.2)), "radial 90 from the bottom-left, clockwise, half: the triangle above the diagonal")
	q = Sprite.radial_quads(2, 2, 0.5, true)
	ok(_in_quads(q, Vector2(0.8, 0.2)) and not _in_quads(q, Vector2(0.2, 0.8)), "radial 90 from the top-right, clockwise, half: the triangle below the diagonal")
	ok(Sprite.radial_quads(4, 0, 0.0005, true).is_empty(), "almost no fill: nothing")
	ok(Sprite.radial_quads(4, 1, 1.0, false).size() == 1, "a full fill: the whole rect, one quad")
	# every method, origin and direction: the quads cover what the swept angle covers
	var wrong: Array = []
	var points: int = 0
	for method in [2, 3, 4]:
		for origin in range(4):
			for clockwise in [true, false]:
				for amount in [0.05, 0.125, 0.25, 0.3, 0.5, 0.6, 0.75, 0.875, 0.97]:
					var quads: Array = Sprite.radial_quads(method, origin, amount, clockwise)
					for ix in range(17):
						for iy in range(17):
							var p := Vector2((ix + 0.37) / 17.0, (iy + 0.61) / 17.0)
							var want: bool = Sprite.radial_covers(p, method, origin, amount, clockwise)
							# (not at the edge of the fill)
							if Sprite.radial_covers(p, method, origin, amount - 0.004, clockwise) != want or Sprite.radial_covers(p, method, origin, minf(amount + 0.004, 0.999), clockwise) != want:
								continue
							points += 1
							if _in_quads(quads, p) != want and wrong.size() < 5:
								wrong.append("method %d origin %d %s amount %s at %s: %s" % [method, origin, "cw" if clockwise else "ccw", str(amount), str(p), "covered" if not want else "missing"])
	ok(wrong.is_empty(), "radial quads cover the swept angle at %d points: %s" % [points, str(wrong)])
