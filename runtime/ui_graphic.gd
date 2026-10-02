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
##    raycast: bool (Graphic.raycastTarget: the pointer does not pass through it),
##    hidden: bool (drawn by something else or not at all: a Mask that does not show its graphic,
##    the text objects of an input field),
##    texture: Texture2D (the sprite of an Image that is the background of a widget),
##    sprite: {...} (an Image that is not simply stretched: sliced, tiled, filled; drawn by a
##    helper child, see runtime/ui_sprite.gd)}

const META := &"unidot_graphic"

## Style boxes a widget draws its background with ("focus" is drawn on top of them: left empty).
const _BOXES := ["normal", "hover", "pressed", "disabled", "hover_pressed", "panel", "read_only", "scroll"]


static func state(ctl: Node) -> Dictionary:
	var s: Dictionary = {"color": Color.WHITE, "renderer": Color.WHITE, "enabled": true, "hidden": false, "raycast": true}
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


## Unity's GraphicRaycaster, as far as "is something there": is a Graphic that takes raycasts
## under the point `at` (in the coordinates of the canvas's viewport) at or below `c`? A
## graphic counts whatever it draws (an invisible Image blocks); a disabled one, one that is
## no raycast target or lies below a CanvasGroup that does not block raycasts does not, nor
## does what a mask clips away. A pointer that finds nothing goes on to what is behind the
## canvas.
static func raycast_hit(c: Control, at: Vector2, passes: bool = false) -> bool:
	if c == null or not c.visible:
		return false
	if c.has_meta(&"unidot_canvas_group"):
		var group: Dictionary = c.get_meta(&"unidot_canvas_group")
		if bool(group.get("ignoreParentGroups", false)):
			passes = false
		if not bool(group.get("blocksRaycasts", true)):
			passes = true
	var xf: Transform2D = c.get_global_transform()
	var inside: bool = absf(xf.determinant()) > 1e-12 and Rect2(Vector2.ZERO, c.size).has_point(xf.affine_inverse() * at)
	if c.clip_contents and not inside:
		return false
	for child in c.get_children():
		if child is Control and raycast_hit(child, at, passes):
			return true
	if passes or not inside:
		return false
	if has_graphic(c):
		var s: Dictionary = state(c)
		return bool(s["enabled"]) and bool(s.get("raycast", true))
	# (a widget without a Unity graphic of its own: a hand-built scene)
	return c.mouse_filter == Control.MOUSE_FILTER_STOP and (c is BaseButton or c is Range or c is LineEdit)


const META_FADE := &"unidot_fade"

## Graphic.CrossFadeColor (and CrossFadeAlpha: `use_rgb` false): the CanvasRenderer colour goes
## from what it is to `target` in `duration` seconds. No duration, or a graphic outside the
## tree: at once. (The fade that runs is kept in the graphic's `unidot_fade` metadata:
## {tween, to}.)
static func cross_fade(ctl: Node, target: Color, duration: float, use_alpha: bool = true, use_rgb: bool = true) -> void:
	if ctl == null or not (use_alpha or use_rgb):
		return
	var from: Color = renderer_color(ctl)
	var to: Color = Color(target.r if use_rgb else from.r, target.g if use_rgb else from.g, target.b if use_rgb else from.b, target.a if use_alpha else from.a)
	var running: Tween = fade_of(ctl)
	if running != null and duration > 0.0 and ((ctl.get_meta(META_FADE) as Dictionary)["to"] as Color) == to:
		return   # on its way there
	if running != null:
		running.kill()
	if ctl.has_meta(META_FADE):
		ctl.remove_meta(META_FADE)
	if duration <= 0.0 or from == to or not ctl.is_inside_tree():
		set_renderer_color(ctl, to)
		return
	var tween: Tween = ctl.create_tween()
	tween.set_ignore_time_scale(true)
	tween.tween_method(func(t: float) -> void: update(ctl, {"renderer": from.lerp(to, t)}), 0.0, 1.0, duration)
	# (the callback knows the tween by its id: holding it would keep it alive for ever)
	var id: int = tween.get_instance_id()
	tween.finished.connect(func() -> void:
		if ctl.has_meta(META_FADE) and ((ctl.get_meta(META_FADE) as Dictionary)["tween"] as Tween).get_instance_id() == id:
			ctl.remove_meta(META_FADE))
	ctl.set_meta(META_FADE, {"tween": tween, "to": to})


## The fade a graphic is in, if any.
static func fade_of(ctl: Node) -> Tween:
	if ctl == null or not ctl.has_meta(META_FADE):
		return null
	var tween: Tween = (ctl.get_meta(META_FADE) as Dictionary).get("tween") as Tween
	return tween if tween != null and tween.is_valid() else null


const META_OWN_SPRITE := &"unidot_sprite_own"
const WHITE := preload("./ui_white.tres")

## Image.sprite: the sprite of the Image itself (another one may be drawn in its place:
## `set_override_sprite`).
static func sprite(ctl: Node) -> Texture2D:
	if ctl == null:
		return null
	if ctl.has_meta(META_OWN_SPRITE):
		return (ctl.get_meta(META_OWN_SPRITE) as Dictionary).get("texture") as Texture2D
	return _drawn_sprite(ctl)


static func set_sprite(ctl: Node, tex: Texture2D) -> void:
	if ctl == null:
		return
	if ctl.has_meta(META_OWN_SPRITE):
		ctl.set_meta(META_OWN_SPRITE, {"texture": tex})
	else:
		_draw_sprite(ctl, tex)


## Image.overrideSprite: drawn in place of the Image's sprite until it is null again (the
## sprite swap of a Selectable).
static func set_override_sprite(ctl: Node, tex: Texture2D) -> void:
	if ctl == null:
		return
	if tex == null:
		if ctl.has_meta(META_OWN_SPRITE):
			var own: Texture2D = (ctl.get_meta(META_OWN_SPRITE) as Dictionary).get("texture") as Texture2D
			ctl.remove_meta(META_OWN_SPRITE)
			_draw_sprite(ctl, own)
		return
	if not ctl.has_meta(META_OWN_SPRITE):
		ctl.set_meta(META_OWN_SPRITE, {"texture": _drawn_sprite(ctl)})
	_draw_sprite(ctl, tex)


static func _drawn_sprite(ctl: Node) -> Texture2D:
	if ctl is TextureRect:
		return null if bool(ctl.get_meta(&"unidot_no_sprite", false)) else ctl.texture
	return state(ctl).get("texture") as Texture2D


## (an Image without a sprite is a rectangle in its colour: a white texture; a sprite that is
## sliced brings its own border)
static func _draw_sprite(ctl: Node, tex: Texture2D) -> void:
	var changes: Dictionary = {}
	var drawing = state(ctl).get("sprite")
	if tex != null and tex.has_meta(&"unidot_sprite") and drawing is Dictionary:
		var changed: Dictionary = (drawing as Dictionary).duplicate()
		changed["border"] = (tex.get_meta(&"unidot_sprite") as Dictionary).get("border", changed.get("border", [0, 0, 0, 0]))
		changes["sprite"] = changed
	if ctl is TextureRect:
		ctl.texture = tex if tex != null else WHITE
		ctl.set_meta(&"unidot_no_sprite", tex == null)
	else:
		changes["texture"] = tex
	update(ctl, changes)



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
