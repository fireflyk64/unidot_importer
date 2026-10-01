# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
extends Node
## What a Unity Selectable does to other objects, for the Control this node is a child of
## (ui_integration.gd adds it as a helper child named "UnidotSelectable"):
##   * colour tint transition: the target graphic takes the colour of the selection state
##     (normal, highlighted, pressed, selected, disabled);
##   * Toggle: the check mark graphic is shown while the toggle is on;
##   * Slider: the fill and handle rects follow the value (their anchors, as Unity sets them).
## The parent's `unidot_selectable` metadata holds the settings:
##   {transition (0 none, 1 colour tint),
##    colors: a ColorBlock {normalColor, highlightedColor, pressedColor, selectedColor,
##            disabledColor, colorMultiplier, fadeDuration},
##    target: NodePath (the target graphic), graphic: NodePath (Toggle),
##    fill, handle: NodePath and direction (Slider: 0 left to right, 1 right to left,
##    2 bottom to top, 3 top to bottom), fill_image: bool (the fill is an Image of type Filled)}
## `refresh_static` applies the resting state without this node: the importer calls it, so the
## saved scene already shows what Unity shows before any input.

const RT := preload("./rect_transform.gd")
const Graphic := preload("./ui_graphic.gd")
const META := &"unidot_selectable"
const HELPER := "UnidotSelectable"

const DEFAULT_COLORS := {
	"normalColor": Color(1, 1, 1, 1), "highlightedColor": Color(0.9607843, 0.9607843, 0.9607843, 1),
	"pressedColor": Color(0.78431374, 0.78431374, 0.78431374, 1), "selectedColor": Color(0.9607843, 0.9607843, 0.9607843, 1),
	"disabledColor": Color(0.78431374, 0.78431374, 0.78431374, 0.5019608), "colorMultiplier": 1.0, "fadeDuration": 0.1,
}

var _host: Control = null
var _inside: bool = false
var _down: bool = false


func _ready() -> void:
	_host = get_parent() as Control
	if _host == null:
		return
	_host.mouse_entered.connect(func() -> void:
		_inside = true
		refresh())
	_host.mouse_exited.connect(func() -> void:
		_inside = false
		refresh())
	_host.focus_entered.connect(refresh)
	_host.focus_exited.connect(refresh)
	_host.visibility_changed.connect(_shown)
	if _host is BaseButton:
		_host.button_down.connect(func() -> void:
			_down = true
			refresh())
		_host.button_up.connect(func() -> void:
			_down = false
			refresh())
		_host.toggled.connect(func(_on: bool) -> void: refresh())
	if _host is Range:
		_host.value_changed.connect(func(_v: float) -> void: refresh())
		_host.changed.connect(refresh)
	if _host is Slider:
		_host.drag_started.connect(func() -> void:
			_down = true
			refresh())
		_host.drag_ended.connect(func(_changed: bool) -> void:
			_down = false
			refresh())
	refresh()


## Selectable.OnEnable / OnDisable: the visuals are brought up to date, pointer state is forgotten.
func _shown() -> void:
	if not _host.is_visible_in_tree():
		_inside = false
		_down = false
	refresh()


## Unity's selection state: disabled, pressed, selected (has the focus), highlighted, normal.
func selection_state() -> String:
	if not interactable(_host):
		return "disabled"
	if _down:
		return "pressed"
	if _host.has_focus():
		return "selected"
	if _inside:
		return "highlighted"
	return "normal"


static func interactable(host: Control) -> bool:
	if host is BaseButton:
		return not host.disabled
	if host is Slider or host is LineEdit:
		return host.editable
	return true


func refresh() -> void:
	if _host != null:
		apply(_host, selection_state())


## Bring what `host` drives up to date (after its value, colours or interactable changed).
static func refresh_host(host: Node) -> void:
	if not (host is Control) or not host.has_meta(META):
		return
	var helper: Node = host.get_node_or_null(HELPER)
	if helper != null and helper.has_method("refresh") and helper.is_inside_tree():
		helper.refresh()
	else:
		refresh_static(host)


## The resting state, for a scene that is not running.
static func refresh_static(host: Control) -> void:
	apply(host, "normal" if interactable(host) else "disabled")


static func config(host: Node) -> Dictionary:
	if host != null and host.has_meta(META):
		return host.get_meta(META)
	return {}


static func colors(host: Node) -> Dictionary:
	var block: Dictionary = DEFAULT_COLORS.duplicate()
	block.merge(config(host).get("colors", {}), true)
	return block


## The node a path of the configuration (target, graphic, fill, handle) points at.
static func part(host: Node, key: String) -> Node:
	var p = config(host).get(key)
	if p is NodePath and not (p as NodePath).is_empty():
		return host.get_node_or_null(p)
	return null


## Apply a selection state (and the toggle / slider visuals) to what `host` drives.
static func apply(host: Control, sel_state: String) -> void:
	if not host.has_meta(META):
		return
	var cfg: Dictionary = host.get_meta(META)
	if int(cfg.get("transition", 1)) == 1:
		var target: Node = part(host, "target")
		if target != null:
			var block: Dictionary = colors(host)
			var tint: Color = block.get(sel_state + "Color", block["normalColor"])
			var mul: float = float(block.get("colorMultiplier", 1.0))
			# (the alpha is multiplied too, as in Unity)
			Graphic.set_renderer_color(target, Color(tint.r * mul, tint.g * mul, tint.b * mul, tint.a * mul).clamp())
	if host is BaseButton:
		var mark: Node = part(host, "graphic")
		if mark != null:
			Graphic.set_renderer_alpha(mark, 1.0 if host.button_pressed else 0.0)
	if host is Range:
		_slider_visuals(host, cfg)


## Slider.UpdateVisuals: the fill is anchored from the start to the value, the handle at the value.
static func _slider_visuals(host: Range, cfg: Dictionary) -> void:
	var span: float = host.max_value - host.min_value
	var t: float = clampf((host.value - host.min_value) / span, 0.0, 1.0) if span > 0.0 else 0.0
	var direction: int = int(cfg.get("direction", 0))
	var axis: int = 0 if direction < 2 else 1
	var reverse: bool = direction == 1 or direction == 3
	var fill: Control = part(host, "fill") as Control
	if fill != null and RT.logical_parent(fill) is Control:
		var amin := Vector2.ZERO
		var amax := Vector2.ONE
		if not bool(cfg.get("fill_image", false)):
			if reverse:
				amin[axis] = 1.0 - t
			else:
				amax[axis] = t
		_set_anchors(fill, amin, amax)
	var handle: Control = part(host, "handle") as Control
	if handle != null and RT.logical_parent(handle) is Control:
		var hmin := Vector2.ZERO
		var hmax := Vector2.ONE
		hmin[axis] = (1.0 - t) if reverse else t
		hmax[axis] = hmin[axis]
		_set_anchors(handle, hmin, hmax)


static func _set_anchors(c: Control, amin: Vector2, amax: Vector2) -> void:
	var v: Dictionary = RT.values(c)
	if (v["anchor_min"] as Vector2).is_equal_approx(amin) and (v["anchor_max"] as Vector2).is_equal_approx(amax):
		return
	RT.set_values(c, {"anchor_min": amin, "anchor_max": amax})
