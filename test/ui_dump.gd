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
const UiText := preload("../runtime/ui_text.gd")


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
	# what is not UI among the UI: [path, where it is in Unity's world]
	entry["spatial"] = []
	for c in RT.logical_children(holder):
		_walk(c, "", entry["nodes"], entry["spatial"])
		if not RT.is_ui(c) and RT.store(c).get_parent() == holder:
			_spatial(c, "", entry["spatial"])
	return entry


static func _spatial(n: Node, prefix: String, out: Array) -> void:
	if not (n is Node3D) or n.has_meta(RT.META_CANVAS) or n is Viewport:
		return
	var path: String = prefix + ("/" if prefix != "" else "") + String(n.name)
	var at: Vector3 = RT.unity_from_godot((n as Node3D).global_transform).origin
	out.append({"path": path, "position": [at.x, at.y, at.z]})
	for c in n.get_children():
		_spatial(c, path, out)


## GameObject path of a node from the scene root (viewports and holders left out).
static func _unity_path(n: Node, scene: Node) -> String:
	var parts: Array = []
	var cur: Node = n
	while cur != null and cur != scene:
		parts.push_front(String(cur.name))
		cur = RT.logical_parent(cur)
	return "/".join(parts)


static func _walk(n: Node, prefix: String, out: Array, spatial: Array) -> void:
	if not RT.is_ui(n):
		return
	var path: String = prefix + ("/" if prefix != "" else "") + String(RT.store(n).name)
	var ctl: Control = n as Control
	if ctl == null:
		ctl = RT.root_control(n)
	if ctl == null:
		return
	var frame: Node3D = RT.frame_of(ctl)
	for under in (frame.get_children() if frame != null else []):
		_spatial(under, path, spatial)
	var s: Vector2 = ctl.size
	# (a rect of negative size: the Control has none, its corners are where that size puts them)
	var unity_size: Vector2 = RT.rect_size(ctl) if RT.holder_of(ctl) == null else s
	if unity_size.x < 0.0:
		s.x = unity_size.x
	if unity_size.y < 0.0:
		s.y = unity_size.y
	var corners: Array = []
	for p in [Vector2(0, s.y), Vector2(0, 0), Vector2(s.x, 0), Vector2(s.x, s.y)]:
		var w: Vector3 = rendered(ctl, p)
		corners.append([w.x, w.y, w.z])
	var model: Array = []
	for w in RT.world_corners(n):
		model.append([w.x, w.y, w.z])
	# a plain Transform that holds UI draws nothing and has no size: there is no drawn place to
	# follow, so its place is where its transforms say (it may be off the plane it is drawn in,
	# and what is below it gets a canvas of its own where it has to)
	if RT.carries(ctl) and RT.holder_of(ctl) == null:
		corners = model.duplicate(true)
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
		# a text smaller than a font can be is laid out `k` times larger by its drawing child
		# (runtime/ui_text.gd): what that child draws, in the units of the rect
		var drawer: RichTextLabel = ctl.get_node_or_null("UnidotTextOverflow") as RichTextLabel
		var k: float = UiText.raster(UiText.settings(ctl), ctl) if ctl.has_meta(UiText.META) else 1.0
		var shown: RichTextLabel = drawer if drawer != null and k != 1.0 else ctl
		e["raster"] = k
		e["font_size"] = UiText.drawn_font_size(ctl)
		e["font"] = font_family(ctl.get_theme_font("normal_font"))
		# what is drawn around the glyphs, the fonts behind the font, the pictures in the text
		if shown.has_theme_constant_override("outline_size") and shown.get_theme_constant("outline_size") > 0:
			var oc: Color = shown.get_theme_color("font_outline_color")
			e["outline"] = [shown.get_theme_constant("outline_size") / k, oc.r, oc.g, oc.b, oc.a]
		if shown.has_theme_color_override("font_shadow_color") and shown.get_theme_color("font_shadow_color").a > 0.0:
			var sc: Color = shown.get_theme_color("font_shadow_color")
			e["shadow"] = [shown.get_theme_constant("shadow_offset_x") / k, shown.get_theme_constant("shadow_offset_y") / k, sc.r, sc.g, sc.b, sc.a]
		var fallbacks: Array = []
		var shown_font: Font = ctl.get_theme_font("normal_font")
		for fallback in (shown_font.fallbacks if shown_font != null else []):
			fallbacks.append(font_family(fallback))
		e["fallbacks"] = fallbacks
		var pictures: Array = []
		var img := RegEx.create_from_string("\\[img width=(\\d+) height=(\\d+) region=(\\d+),(\\d+),(\\d+),(\\d+)\\]")
		for found in img.search_all(shown.text):
			pictures.append([found.get_string(3).to_int(), found.get_string(4).to_int(), found.get_string(5).to_int(), found.get_string(6).to_int(), found.get_string(1).to_int() / k, found.get_string(2).to_int() / k])
		e["sprites"] = pictures
		# where the text is laid out (a text with margins: by its drawing child) and the room
		# between its lines
		if drawer != null:
			e["text_box"] = [drawer.position.x, drawer.position.y, drawer.size.x / k, drawer.size.y / k, drawer.get_line_count()]
		e["valign"] = int(ctl.vertical_alignment)
		e["line_spacing"] = (shown.get_theme_constant("line_separation") / k) if shown.has_theme_constant_override("line_separation") else 0.0
		var line_font: Font = shown.get_theme_font("normal_font")
		e["line_height"] = (line_font.get_height(shown.get_theme_font_size("normal_font_size")) / k) if line_font != null else 0.0
	elif ctl is Label or ctl is Button or ctl is LineEdit:
		e["text"] = str(ctl.text)
		e["font_size"] = ctl.get_theme_font_size("font_size")
	var g = drawn_color(ctl)
	if g != null:
		e["graphic"] = [g.r, g.g, g.b, g.a]
	out.append(e)
	for c in RT.logical_children(id):
		_walk(c, path, out, spatial)


## Where a point of a control (its own Godot coordinates) is drawn, in Unity world space.
static func rendered(c: Control, local: Vector2) -> Vector3:
	return RT.drawn_point(c, local)


## The family of the font file a text is drawn with (through font variations).
static func font_family(font: Font) -> String:
	var depth: int = 0
	while font is FontVariation and depth < 8:
		font = (font as FontVariation).base_font
		depth += 1
	return font.get_font_name() if font != null else ""


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

