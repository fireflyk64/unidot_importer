# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## Unity's CanvasGroup on the Control of its GameObject (metadata `unidot_canvas_group`:
## {alpha, interactable, blocksRaycasts, ignoreParentGroups}).
##   * alpha fades the control and everything below it (modulate);
##   * a group that is not interactable, or does not block raycasts, takes no pointer input,
##     nor does anything below it (the pointer goes through to what is behind);
##   * Selectables below a group that is not interactable are in their disabled state
##     (runtime/selectable.gd asks `allows_interaction`).
## A group below with `ignoreParentGroups` starts over.

const META := &"unidot_canvas_group"


static func state(ctl: Node) -> Dictionary:
	var s: Dictionary = {"alpha": 1.0, "interactable": true, "blocksRaycasts": true, "ignoreParentGroups": false}
	if ctl != null and ctl.has_meta(META):
		s.merge(ctl.get_meta(META), true)
	return s


## Change settings of the group and apply them.
static func update(ctl: Node, changes: Dictionary) -> void:
	if not (ctl is Control):
		return
	var s: Dictionary = state(ctl)
	s.merge(changes, true)
	ctl.set_meta(META, s)
	apply(ctl)


static func apply(ctl: Control) -> void:
	var s: Dictionary = state(ctl)
	ctl.modulate.a = clampf(float(s["alpha"]), 0.0, 1.0)
	if not bool(s["interactable"]) or not bool(s["blocksRaycasts"]):
		ctl.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_DISABLED
	elif bool(s["ignoreParentGroups"]):
		ctl.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_ENABLED
	else:
		ctl.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_INHERITED
	_refresh_selectables(ctl)


## Do the canvas groups at and above `n` let a Selectable there interact
## (Selectable.IsInteractable's m_GroupsAllowInteraction)?
static func allows_interaction(n: Node) -> bool:
	var cur: Node = n
	while cur is Control:
		if cur.has_meta(META):
			var s: Dictionary = cur.get_meta(META)
			if not bool(s.get("interactable", true)):
				return false
			if bool(s.get("ignoreParentGroups", false)):
				return true
		cur = cur.get_parent()
	return true


## The selectables below show their disabled state when the group stops interaction.
static func _refresh_selectables(n: Node) -> void:
	for c in n.get_children():
		if c.name == &"UnidotSelectable" and c.has_method("refresh") and c.is_inside_tree():
			c.call("refresh")
		elif c is Control:
			_refresh_selectables(c)
