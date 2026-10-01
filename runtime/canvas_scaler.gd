# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
extends CanvasLayer
## A screen-space Unity canvas: the root control covers the window divided by the scale factor
## of Unity's CanvasScaler (constant pixel size, scale with screen size, constant physical size).

const RT := preload("./rect_transform.gd")


func _ready() -> void:
	get_viewport().size_changed.connect(apply)
	process_mode = Node.PROCESS_MODE_ALWAYS
	apply()


## A CanvasLayer does not inherit the visibility of the Node3D it hangs under.
func _process(_delta: float) -> void:
	var canvas: Node3D = get_parent() as Node3D
	if canvas != null and visible != canvas.is_visible_in_tree():
		visible = canvas.is_visible_in_tree()


## Unity's CanvasScaler: the factor between canvas units and screen pixels.
static func scale_factor(scaler: Dictionary, screen: Vector2) -> float:
	match int(scaler.get("mode", 0)):
		0:
			return maxf(float(scaler.get("scale_factor", 1.0)), 1e-6)
		1:
			var ref: Vector2 = scaler.get("reference_resolution", Vector2(800, 600))
			if ref.x <= 0.0 or ref.y <= 0.0 or screen.x <= 0.0 or screen.y <= 0.0:
				return 1.0
			match int(scaler.get("match_mode", 0)):
				0:
					var lw: float = log(screen.x / ref.x) / log(2.0)
					var lh: float = log(screen.y / ref.y) / log(2.0)
					return pow(2.0, lerpf(lw, lh, clampf(float(scaler.get("match", 0.0)), 0.0, 1.0)))
				1:
					return minf(screen.x / ref.x, screen.y / ref.y)
				_:
					return maxf(screen.x / ref.x, screen.y / ref.y)
		_:
			# constant physical size: Unity's fallback of 96 dpi against the default sprite dpi
			return 96.0 / maxf(float(scaler.get("default_dpi", 96.0)), 1.0)


func apply() -> void:
	var canvas: Node = get_parent()
	if canvas == null or not canvas.has_meta(RT.META_CANVAS):
		return
	var cfg: Dictionary = (canvas.get_meta(RT.META_CANVAS) as Dictionary).duplicate()   # instances share it
	var root: Control = RT.root_control(canvas)
	if root == null:
		return
	var screen: Vector2 = get_viewport().get_visible_rect().size
	var f: float = scale_factor(cfg.get("scaler", {}), screen)
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		root.set_anchor(side, 0.0, false, false)
	root.position = Vector2.ZERO
	if not is_equal_approx(f, 1.0) and get_viewport().gui_snap_controls_to_pixels:
		# canvas units are not pixels any more: Godot would round every control's origin to a
		# whole unit of its parent's space when drawing
		get_viewport().gui_snap_controls_to_pixels = false
	root.scale = Vector2(f, f)
	root.size = screen / f
	cfg["size"] = root.size
	cfg["scale_factor"] = f
	canvas.set_meta(RT.META_CANVAS, cfg)
