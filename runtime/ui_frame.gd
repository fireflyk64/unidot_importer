# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
extends Node3D
## The 3D frame of a UI object: a Unity RectTransform is a Transform, and what is below it or on
## it may be 3D (an AudioSource on a button, a collider, a mesh or a particle system under a
## panel, plain Transforms without any UI). A Control has no place in the 3D world, so those
## nodes hang under this helper child of the Control ("Unidot3D", see rect_transform.gd), which
## stays where Unity has the rect: at its pivot, turned and scaled as the rect is in the world.
## Child GameObjects below it are children of the UI object for scripts
## (RT.logical_parent / logical_children).

const RT := preload("./rect_transform.gd")


func _ready() -> void:
	follow()


func _process(_delta: float) -> void:
	follow()


## Take the place of the rect (and its visibility: a Node3D does not inherit that of a Control).
func follow() -> void:
	var host: Control = get_parent() as Control
	if host == null:
		return
	var shown: bool = host.is_visible_in_tree()
	if visible != shown:
		visible = shown
	var want: Transform3D = RT.godot_from_unity(RT.world_matrix(host))
	if RT._singular(want.basis):
		return
	if not global_transform.is_equal_approx(want):
		global_transform = want
