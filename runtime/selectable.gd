# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
extends Node
## What a Unity Selectable does to other objects, for the Control this node is a child of
## (ui_integration.gd adds it as a helper child named "UnidotSelectable"):
##   * colour tint transition: the target graphic takes the colour of the selection state
##     (normal, highlighted, pressed, selected, disabled), fading over the block's fadeDuration
##     (Graphic.CrossFadeColor); a Selectable that appears has its colour at once;
##   * sprite swap transition: the target Image draws the sprite of the state in place of its
##     own (Image.overrideSprite);
##   * animation transition: the Animator of the object gets the trigger of the state (the
##     others reset), when the state changes;
##   * Toggle: the check mark graphic is shown while the toggle is on (fading in 0.1 s when
##     its transition is Fade);
##   * Slider: the fill and handle rects follow the value (their anchors, as Unity sets them);
##   * Scrollbar: the handle spans `size` of the bar and moves with the value
##     (Scrollbar.UpdateVisuals; size and direction in the `unidot_scrollbar` metadata), and
##     the pointer sets the value as Unity's Scrollbar does (the Godot ScrollBar underneath
##     draws nothing and its own handling is bypassed).
## The parent's `unidot_selectable` metadata holds the settings:
##   {transition (0 none, 1 colour tint, 2 sprite swap, 3 animation),
##    colors: a ColorBlock {normalColor, highlightedColor, pressedColor, selectedColor,
##            disabledColor, colorMultiplier, fadeDuration},
##    sprites: {highlighted, pressed, selected, disabled: Texture2D},
##    triggers: {normal, highlighted, pressed, selected, disabled: String},
##    target: NodePath (the target graphic), graphic: NodePath (Toggle), toggle_fade: bool,
##    fill, handle: NodePath and direction (Slider: 0 left to right, 1 right to left,
##    2 bottom to top, 3 top to bottom), fill_image: bool (the fill is an Image of type Filled)}
## `refresh_static` applies the resting state without this node: the importer calls it, so the
## saved scene already shows what Unity shows before any input.

const RT := preload("./rect_transform.gd")
const Graphic := preload("./ui_graphic.gd")
const UiGroup := preload("./canvas_group.gd")
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
var _live: bool = false     # after the first refresh: what changes fades
var _state: String = ""


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
	if _host is ScrollBar:
		_host.gui_input.connect(_scrollbar_input)
	if _host is Slider:
		_host.drag_started.connect(func() -> void:
			_down = true
			refresh())
		_host.drag_ended.connect(func(_changed: bool) -> void:
			_down = false
			refresh())
	refresh()
	_live = true


## Selectable.OnEnable / OnDisable: the visuals are brought up to date at once, pointer state is
## forgotten.
func _shown() -> void:
	if not _host.is_visible_in_tree():
		_inside = false
		_down = false
	_live = false
	refresh()
	_live = true


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


## Selectable.IsInteractable: its own flag, and the canvas groups above it.
static func interactable(host: Control) -> bool:
	if not UiGroup.allows_interaction(host):
		return false
	if host is BaseButton:
		return not host.disabled
	if host is Slider or host is LineEdit:
		return host.editable
	return true


func refresh() -> void:
	if _host == null:
		return
	var now: String = selection_state()
	var changed: bool = now != _state
	_state = now
	apply(_host, now, not _live)
	if changed or not _live:
		trigger_animation(_host, now)


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


## Apply a selection state (and the toggle / slider visuals) to what `host` drives
## (Selectable.DoStateTransition). `instant`: without the fades.
static func apply(host: Control, sel_state: String, instant: bool = true) -> void:
	if not host.has_meta(META):
		return
	var cfg: Dictionary = host.get_meta(META)
	var target: Node = part(host, "target")
	if target != null:
		match int(cfg.get("transition", 1)):
			1:
				var block: Dictionary = colors(host)
				var tint: Color = block.get(sel_state + "Color", block["normalColor"])
				var mul: float = float(block.get("colorMultiplier", 1.0))
				# (the alpha is multiplied too, as in Unity)
				Graphic.cross_fade(target, Color(tint.r * mul, tint.g * mul, tint.b * mul, tint.a * mul).clamp(), 0.0 if instant else float(block.get("fadeDuration", 0.1)))
			2:
				var swap = (cfg.get("sprites", {}) as Dictionary).get(sel_state)
				Graphic.set_override_sprite(target, swap as Texture2D)
	if host is BaseButton:
		var mark: Node = part(host, "graphic")
		if mark != null:
			# Toggle.PlayEffect
			var fade: float = 0.1 if not instant and bool(cfg.get("toggle_fade", false)) else 0.0
			Graphic.cross_fade(mark, Color(0, 0, 0, 1.0 if host.button_pressed else 0.0), fade, true, false)
	if host is ScrollBar:
		scrollbar_visuals(host)
	elif host is Range:
		_slider_visuals(host, cfg)


## Selectable.TriggerAnimation: the Animator of the object (its AnimationTree, whose parameters
## are metadata) gets the trigger of the state; the triggers of the other states are reset.
static func trigger_animation(host: Control, sel_state: String) -> void:
	var cfg: Dictionary = config(host)
	if int(cfg.get("transition", 1)) != 3:
		return
	var triggers: Dictionary = cfg.get("triggers", {})
	var trigger: String = str(triggers.get(sel_state, ""))
	var tree: AnimationTree = null
	for c in host.get_children():
		if c is AnimationTree:
			tree = c
	if tree == null or not tree.active or trigger.is_empty():
		return
	for other in triggers.values():
		if str(other) != "":
			tree.set("metadata/" + str(other), false)
	tree.set("metadata/" + trigger, true)


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


## Scrollbar.UpdateVisuals: the handle covers `size` of its container, moved by the value.
## Scrollbar.numberOfSteps: with more than one step the bar's value is one of them (the steps
## divide 0..1 evenly, which is what Range.step does).
static func scrollbar_set_steps(bar: Range, steps: int) -> void:
	var sb: Dictionary = (bar.get_meta(&"unidot_scrollbar") as Dictionary).duplicate() if bar.has_meta(&"unidot_scrollbar") else {}
	sb["steps"] = steps
	bar.set_meta(&"unidot_scrollbar", sb)
	bar.step = 1.0 / float(steps - 1) if steps > 1 else 0.0


static func scrollbar_steps(bar: Range) -> int:
	return int((bar.get_meta(&"unidot_scrollbar") as Dictionary).get("steps", 0)) if bar.has_meta(&"unidot_scrollbar") else 0


static func scrollbar_visuals(host: Range) -> void:
	var handle: Control = part(host, "handle") as Control
	if handle == null or not (RT.logical_parent(handle) is Control):
		return
	var sb: Dictionary = host.get_meta(&"unidot_scrollbar") if host.has_meta(&"unidot_scrollbar") else {}
	var size: float = clampf(float(sb.get("size", 0.2)), 0.0, 1.0)
	var direction: int = int(sb.get("direction", int(config(host).get("direction", 0))))
	var axis: int = 0 if direction < 2 else 1
	var movement: float = clampf(host.value, 0.0, 1.0) * (1.0 - size)
	var amin := Vector2.ZERO
	var amax := Vector2.ONE
	if direction == 1 or direction == 3:
		amin[axis] = 1.0 - movement - size
		amax[axis] = 1.0 - movement
	else:
		amin[axis] = movement
		amax[axis] = movement + size
	_set_anchors(handle, amin, amax)


var _grab: Vector2 = Vector2.ZERO
var _sliding: bool = false

## Scrollbar.OnPointerDown / UpdateDrag: a press on the handle drags it, a press beside it moves
## the value one handle length towards the pointer; the Godot ScrollBar does not see the event.
func _scrollbar_input(event: InputEvent) -> void:
	var handle: Control = part(_host, "handle") as Control
	var container: Control = handle.get_parent() as Control if handle != null else null
	if container == null or not interactable(_host) or not _host.is_inside_tree():
		return
	var bar: Range = _host
	var sb: Dictionary = bar.get_meta(&"unidot_scrollbar") if bar.has_meta(&"unidot_scrollbar") else {}
	var size: float = clampf(float(sb.get("size", 0.2)), 0.0, 1.0)
	var direction: int = int(sb.get("direction", int(config(bar).get("direction", 0))))
	var axis: int = 0 if direction < 2 else 1
	# the pointer in the container (the event is in the bar's coordinates)
	var to_container: Transform2D = container.get_global_transform().affine_inverse() * bar.get_global_transform()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		bar.accept_event()
		_sliding = false
		if not event.pressed:
			return
		var p: Vector2 = to_container * (event as InputEventMouseButton).position
		var hrect := Rect2(handle.position, handle.size * handle.scale)
		if hrect.has_point(p):
			_sliding = true
			_grab = p - hrect.get_center()
		else:
			# towards the pointer: before the handle along the axis lowers the handle's position
			var before: bool = p[axis] < hrect.position[axis]
			var forward: bool = before == (direction == 1 or direction == 2)   # does that raise the value?
			bar.value = clampf(bar.value + (size if forward else -size), 0.0, 1.0)
	elif event is InputEventMouseMotion and _sliding:
		bar.accept_event()
		if ((event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			_sliding = false
			return
		var p2: Vector2 = to_container * (event as InputEventMouseMotion).position - _grab
		var length: float = container.size[axis]
		var remaining: float = length * (1.0 - size)
		if remaining <= 0.0:
			return
		# the handle's leading corner along the axis, from the container's left / bottom
		var along: float = p2.x if axis == 0 else length - p2.y
		var corner: float = along - length * size * 0.5
		var t: float = clampf(corner / remaining, 0.0, 1.0)
		bar.value = (1.0 - t) if (direction == 1 or direction == 3) else t


static func _set_anchors(c: Control, amin: Vector2, amax: Vector2) -> void:
	var v: Dictionary = RT.values(c)
	if (v["anchor_min"] as Vector2).is_equal_approx(amin) and (v["anchor_max"] as Vector2).is_equal_approx(amax):
		return
	RT.set_values(c, {"anchor_min": amin, "anchor_max": amax})
