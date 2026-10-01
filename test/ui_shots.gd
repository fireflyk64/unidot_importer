# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# SPDX-License-Identifier: MIT
extends SceneTree
## Renders every world canvas of an imported scene to a PNG (the canvas's own viewport, so what
## the UI draws can be looked at without finding a camera position):
##   godot --path <project> -s addons/unidot_importer/test/ui_shots.gd -- \
##         --scene res://X.tscn --out <dir> [--frames 10] [--only <canvas name>]
## Needs a display (the headless renderer draws nothing).

const RT := preload("../runtime/rect_transform.gd")


func _init() -> void:
	var args: Dictionary = {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < raw.size():
		if raw[i].begins_with("--") and i + 1 < raw.size():
			args[raw[i].substr(2)] = raw[i + 1]
			i += 1
		i += 1
	var ps = load(str(args.get("scene", "")))
	if ps == null:
		push_error("ui_shots: cannot load the scene " + str(args.get("scene", "")))
		quit(2)
		return
	var scene: Node = ps.instantiate()
	root.add_child(scene)
	for _f in range(int(args.get("frames", 10))):
		await process_frame
	var holders: Array = []
	_find(scene, holders)
	var out: String = str(args.get("out", "user://"))
	var count: int = 0
	for holder in holders:
		if args.has("only") and String(holder.name) != str(args["only"]):
			continue
		var cfg: Dictionary = holder.get_meta(RT.META_CANVAS)
		var vp: SubViewport = holder.get_node_or_null(cfg.get("viewport", NodePath())) as SubViewport
		if vp == null or vp.size.x < 2 or vp.size.y < 2:
			continue
		# a canvas that is hidden or off screen is not rendered: render it once for the picture
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await process_frame
		await process_frame
		var img: Image = vp.get_texture().get_image()
		if img == null or img.is_empty():
			continue
		img.save_png(out.path_join(String(holder.name).validate_filename() + ".png"))
		count += 1
	print("[ui_shots] %d canvases" % count)
	quit(0)


func _find(n: Node, out: Array) -> void:
	if n.has_meta(RT.META_CANVAS) and str(n.get_meta(RT.META_CANVAS).get("mode", "")) == "world":
		out.append(n)
	for c in n.get_children():
		_find(c, out)
