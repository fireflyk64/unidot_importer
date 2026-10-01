# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# SPDX-License-Identifier: MIT
extends SceneTree
## Loads an imported scene, lets it run a few frames and writes the UI dump (test/ui_dump.gd):
##   godot --headless --path <project> -s addons/unidot_importer/test/ui_dump_main.gd -- \
##         --scene res://X.tscn --out dump.json [--frames 10]

const UiDump := preload("./ui_dump.gd")


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
		push_error("ui_dump: cannot load the scene " + str(args.get("scene", "")))
		quit(2)
		return
	var scene: Node = ps.instantiate()
	root.add_child(scene)
	for _f in range(int(args.get("frames", 10))):
		await process_frame
	var out: Dictionary = UiDump.dump(scene)
	var f := FileAccess.open(str(args.get("out", "user://ui_dump.json")), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, " "))
	f.close()
	var total: int = 0
	for c in out["canvases"]:
		total += c["nodes"].size()
	print("[ui_dump] %d canvases, %d nodes" % [out["canvases"].size(), total])
	quit(0)
