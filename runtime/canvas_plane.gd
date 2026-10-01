# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
@tool
extends MeshInstance3D
## The quad that shows a world-space Unity canvas (see rect_transform.gd): it displays the
## SubViewport holding the converted UI and, every frame, lets the canvas follow its rect, its
## content and the canvas it may be nested in.

const RT := preload("./rect_transform.gd")


func _ready() -> void:
	var holder: Node = get_parent()
	if holder == null or not holder.has_meta(RT.META_CANVAS):
		return
	var cfg: Dictionary = holder.get_meta(RT.META_CANVAS)
	var vp: SubViewport = holder.get_node_or_null(cfg.get("viewport", NodePath())) as SubViewport
	if vp == null:
		return
	var mat: BaseMaterial3D = material_override as BaseMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	else:
		mat = mat.duplicate()
	material_override = mat
	mat.albedo_texture = vp.get_texture()
	if Engine.is_editor_hint():
		set_process(false)
		return
	# a canvas under a disabled node still has to be hidden and placed
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	RT.sync_island(holder)


func _process(_delta: float) -> void:
	var holder: Node = get_parent()
	if holder == null or not holder.has_meta(RT.META_CANVAS):
		return
	if RT.root_control(holder) == null:
		# the control this canvas was made for is gone
		if bool(holder.get_meta(RT.META_CANVAS).get("promoted", false)):
			holder.queue_free()
		return
	RT.sync_island(holder)
