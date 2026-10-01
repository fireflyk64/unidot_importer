# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# SPDX-License-Identifier: MIT
extends RefCounted
## Describes every converted Unity canvas of a running scene: where each UI node is drawn in the
## world. The result has the shape of tools/unity_ui_reference.py's reference (computed from the
## Unity files alone), which compares the two.
##
## Per node: `corners` are the world positions (Unity space: x mirrored back) of the rect's
## bottom-left, top-left, top-right and bottom-right corners, followed through what is rendered
## (control → viewport pixel → the quad or inline view showing that viewport); `model` are the
## same corners from rect_transform.gd's world matrix. Screen-space canvases are in window pixels
## with y up. `graphic` is the colour the control draws its Unity graphic with, read from what
## the control draws (texture and modulation, font colour, style box), alpha 0 when it draws
## nothing; `text` the characters a text control shows and `font_size` their size.

const RT := preload("../runtime/rect_transform.gd")


static func dump(scene: Node) -> Dictionary:
	var canvases: Array = []
	_find(scene, scene, canvases)
	var window: Vector2 = scene.get_viewport().get_visible_rect().size if scene.is_inside_tree() else Vector2.ZERO
	return {"screen": [window.x, window.y], "canvases": canvases}


static func _find(n: Node, scene: Node, out: Array) -> void:
	if n.has_meta(RT.META_CANVAS) and not RT.is_nested(n) and RT.island_of(n) == null:
		out.append(_canvas(n, scene))
		return
	for c in n.get_children():
		_find(c, scene, out)


static func _canvas(holder: Node, scene: Node) -> Dictionary:
	var cfg: Dictionary = holder.get_meta(RT.META_CANVAS)
	var size: Vector2 = RT.rect_size(holder)
	var entry: Dictionary = {
		"path": _unity_path(holder, scene),
		"mode": str(cfg.get("mode", "")),
		"size": [size.x, size.y],
		"nodes": [],
	}
	if holder is Node3D:
		var m: Transform3D = RT.world_matrix(holder)
		entry["world_scale"] = [m.basis.x.length(), m.basis.y.length(), m.basis.z.length()]
		entry["world_position"] = [m.origin.x, m.origin.y, m.origin.z]
		entry["active"] = (holder as Node3D).visible
	for c in RT.logical_children(holder):
		_walk(c, "", entry["nodes"])
	return entry


## GameObject path of a node from the scene root (viewports and holders left out).
static func _unity_path(n: Node, scene: Node) -> String:
	var parts: Array = []
	var cur: Node = n
	while cur != null and cur != scene:
		parts.push_front(String(cur.name))
		cur = RT.logical_parent(cur)
	return "/".join(parts)


static func _walk(n: Node, prefix: String, out: Array) -> void:
	if not RT.is_ui(n):
		return
	var path: String = prefix + ("/" if prefix != "" else "") + String(RT.store(n).name)
	var ctl: Control = n as Control
	if ctl == null:
		ctl = RT.root_control(n)
	if ctl == null:
		return
	var s: Vector2 = ctl.size
	var corners: Array = []
	for p in [Vector2(0, s.y), Vector2(0, 0), Vector2(s.x, 0), Vector2(s.x, s.y)]:
		var w: Vector3 = rendered(ctl, p)
		corners.append([w.x, w.y, w.z])
	var model: Array = []
	for w in RT.world_corners(n):
		model.append([w.x, w.y, w.z])
	var id: Node = RT.identity(n)
	var e: Dictionary = {
		"path": path,
		"class": ctl.get_class(),
		"corners": corners,
		"model": model,
		"size": [s.x, s.y],
		"active": ctl.visible and (not (RT.store(n) is Node3D) or (RT.store(n) as Node3D).visible),
		"island": RT.holder_of(ctl) != null,
	}
	if ctl is RichTextLabel:
		e["text"] = ctl.get_parsed_text()
		e["font_size"] = ctl.get_theme_font_size("normal_font_size")
	elif ctl is Label or ctl is Button or ctl is LineEdit:
		e["text"] = str(ctl.text)
		e["font_size"] = ctl.get_theme_font_size("font_size")
	var g = drawn_color(ctl)
	if g != null:
		e["graphic"] = [g.r, g.g, g.b, g.a]
	out.append(e)
	for c in RT.logical_children(id):
		_walk(c, path, out)


## Where a point of a control (its own Godot coordinates) is drawn, in Unity world space.
static func rendered(c: Control, local: Vector2) -> Vector3:
	return RT.drawn_point(c, local)


## The colour a control draws its graphic with, from the properties that decide the drawing;
## null for a control that draws no graphic of its own (a plain container).
static func drawn_color(ctl: Control):
	var c = null
	var sprite: CanvasItem = ctl.get_node_or_null(^"UnidotSprite") as CanvasItem
	if sprite != null:
		c = sprite.self_modulate   # a sliced / tiled / filled sprite is drawn by this helper
		if sprite.has_method(&"draws") and not sprite.draws():
			c.a = 0.0
	elif ctl is TextureRect:
		c = ctl.self_modulate if ctl.texture != null else Color(1, 1, 1, 0)
	elif ctl is RichTextLabel:
		c = ctl.get_theme_color("default_color") * ctl.self_modulate
	elif ctl is Label:
		c = ctl.get_theme_color("font_color") * ctl.self_modulate
	else:
		for st in ["normal", "panel", "scroll"]:
			if ctl.has_theme_stylebox(st):
				var box: StyleBox = ctl.get_theme_stylebox(st)
				if box is StyleBoxFlat:
					c = box.bg_color * ctl.self_modulate
				elif box is StyleBoxTexture:
					c = box.modulate_color * ctl.self_modulate
				else:
					c = Color(1, 1, 1, 0)
				break
	if c == null:
		return null
	# canvas groups (and anything else that fades a subtree)
	var n: Node = ctl
	while n is CanvasItem:
		c = c * (n as CanvasItem).modulate
		n = n.get_parent()
	return c

