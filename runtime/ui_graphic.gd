# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## How a Unity Graphic (Image, RawImage, Text, TextMeshProUGUI) is drawn by its Control.
##
## Unity multiplies three things: the graphic's own colour, the colour of its CanvasRenderer (what
## a Selectable's colour tint and a Toggle's check mark fade write: a Button whose normal colour
## has alpha 0 is invisible until the pointer is over it) and whether the component is enabled
## (a disabled Image draws nothing; its GameObject and children stay). The three are kept in the
## `unidot_graphic` metadata and applied here, by the importer and by anything that changes them
## later.
##   {color: Color, renderer: Color, enabled: bool,
##    hidden: bool (drawn by something else or not at all: a Mask that does not show its graphic,
##    the text objects of an input field),
##    texture: Texture2D (the sprite of an Image that is the background of a widget),
##    sprite: {...} (an Image that is not simply stretched: sliced, tiled, filled; drawn by a
##    helper child, see runtime/ui_sprite.gd)}

const META := &"unidot_graphic"

## Style boxes a widget draws its background with ("focus" is drawn on top of them: left empty).
const _BOXES := ["normal", "hover", "pressed", "disabled", "hover_pressed", "panel", "read_only", "scroll"]


static func state(ctl: Node) -> Dictionary:
	var s: Dictionary = {"color": Color.WHITE, "renderer": Color.WHITE, "enabled": true, "hidden": false}
	if ctl == null:
		return s
	if ctl.has_meta(META):
		s.merge(ctl.get_meta(META), true)
	elif ctl is TextureRect:
		s["color"] = ctl.self_modulate
	elif ctl is ColorRect:
		s["color"] = ctl.color
	elif ctl is Label and ctl.has_theme_color_override("font_color"):
		s["color"] = ctl.get_theme_color("font_color")
	elif ctl is RichTextLabel and ctl.has_theme_color_override("default_color"):
		s["color"] = ctl.get_theme_color("default_color")
	elif ctl is Label3D:
		s["color"] = ctl.modulate
	return s


static func has_graphic(ctl: Node) -> bool:
	return ctl != null and ctl.has_meta(META)


## Change entries of the graphic's state and redraw.
static func update(ctl: Node, changes: Dictionary) -> void:
	if ctl == null:
		return
	var s: Dictionary = state(ctl)
	s.merge(changes, true)
	ctl.set_meta(META, s)
	apply(ctl)


static func color(ctl: Node) -> Color:
	return state(ctl)["color"]


static func set_color(ctl: Node, c: Color) -> void:
	update(ctl, {"color": c})


static func enabled(ctl: Node) -> bool:
	return bool(state(ctl)["enabled"])


static func set_enabled(ctl: Node, on: bool) -> void:
	update(ctl, {"enabled": on})


static func renderer_color(ctl: Node) -> Color:
	return state(ctl)["renderer"]


## CanvasRenderer.SetColor / Graphic.CrossFadeColor
static func set_renderer_color(ctl: Node, c: Color) -> void:
	if not has_graphic(ctl) or state(ctl)["renderer"] != c:
		update(ctl, {"renderer": c})


## CanvasRenderer.SetAlpha / Graphic.CrossFadeAlpha
static func set_renderer_alpha(ctl: Node, a: float) -> void:
	var r: Color = state(ctl)["renderer"]
	if not has_graphic(ctl) or not is_equal_approx(r.a, a):
		r.a = a
		update(ctl, {"renderer": r})


## The colour the graphic ends up with (alpha 0 when it is not drawn).
static func drawn_color(ctl: Node) -> Color:
	var s: Dictionary = state(ctl)
	var c: Color = (s["color"] as Color) * (s["renderer"] as Color)
	if not bool(s["enabled"]) or bool(s["hidden"]):
		c.a = 0.0
	# a filled sprite with no fill amount has no mesh (an Image without a sprite is drawn whole)
	var sprite = s.get("sprite")
	if sprite is Dictionary and int(sprite.get("type", 0)) == 3 and float(sprite.get("amount", 1.0)) < 0.001:
		if s.get("texture") is Texture2D or (ctl is TextureRect and ctl.texture != null):
			c.a = 0.0
	return c


static func apply(ctl: Node) -> void:
	var s: Dictionary = state(ctl)
	var shown: bool = bool(s["enabled"]) and not bool(s["hidden"])
	var own: Color = s["color"]
	var rend: Color = s["renderer"]
	var c: Color = own * rend
	if not shown:
		c.a = 0.0
	# a sliced / tiled / filled sprite is drawn by a helper child in this colour; the control
	# itself draws nothing
	var sprite: CanvasItem = ctl.get_node_or_null(^"UnidotSprite") as CanvasItem
	if sprite != null:
		sprite.self_modulate = c
		sprite.queue_redraw()
		c = Color(c.r, c.g, c.b, 0.0)
	if ctl is TextureRect:
		ctl.self_modulate = c
	elif ctl is Label:
		ctl.add_theme_color_override("font_color", own)
		ctl.self_modulate = rend if shown else Color(rend.r, rend.g, rend.b, 0.0)
	elif ctl is RichTextLabel:
		ctl.add_theme_color_override("default_color", own)
		ctl.self_modulate = rend if shown else Color(rend.r, rend.g, rend.b, 0.0)
		# a text that runs out of its rect is drawn by a child (runtime/ui_text.gd)
		var drawer: RichTextLabel = ctl.get_node_or_null(^"UnidotTextOverflow") as RichTextLabel
		if drawer != null:
			drawer.add_theme_color_override("default_color", own)
			drawer.self_modulate = ctl.self_modulate
	elif ctl is Label3D:
		ctl.modulate = c
	elif ctl is ColorRect:
		ctl.color = c
	elif ctl is Control:
		if not _apply_boxes(ctl, s, c):
			ctl.self_modulate = c


## An Image on a widget (Button, InputField, Dropdown, ScrollRect) is the widget's background.
## One box for every state of the widget, and a new one whenever it changes: the boxes saved in a
## scene are shared by all instances of that scene.
static func _apply_boxes(ctl: Control, s: Dictionary, c: Color) -> bool:
	var tex = s.get("texture")
	var states: Array = []
	for st in _BOXES:
		if ctl.has_theme_stylebox(st):
			states.append(st)
	if states.is_empty():
		return false
	var cur: StyleBox = ctl.get_theme_stylebox(states[0]) if ctl.has_theme_stylebox_override(states[0]) else null
	var box: StyleBox = null
	if c.a <= 0.0:
		if not (cur is StyleBoxEmpty):
			box = StyleBoxEmpty.new()
	elif tex is Texture2D:
		if not (cur is StyleBoxTexture) or cur.texture != tex or cur.modulate_color != c:
			var sbt := StyleBoxTexture.new()
			sbt.texture = tex
			sbt.modulate_color = c
			box = sbt
	elif not (cur is StyleBoxFlat) or cur.bg_color != c:
		var sbf := StyleBoxFlat.new()
		sbf.bg_color = c
		box = sbf
	if box != null:
		for st in states:
			ctl.add_theme_stylebox_override(st, box)
	if ctl is Button:
		ctl.flat = false
	return true
