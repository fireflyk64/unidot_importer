# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
@tool
extends Node
## The RectTransform of the Control this node is a child of, as animation tracks see it (helper
## child "UnidotRect", added by the importer to the controls an Animator animates).
##
## A Unity clip animates `m_AnchoredPosition.x`, `m_SizeDelta.y`, `m_LocalScale.z` ... of a
## RectTransform. A Control has none of these: its offsets, pivot, rotation and scale follow
## from them together (runtime/rect_transform.gd). The tracks of a converted clip therefore point
## here ("Knob/UnidotRect:anchored_position:x"), and every value set goes through the functions
## that the importer and scripts use, so an animated rect is laid out like any other.

const RT := preload("./rect_transform.gd")
const HELPER := "UnidotRect"

## Unity curve attribute (without its component) → property of this node.
const CURVES := {
	"m_AnchoredPosition": "anchored_position", "m_SizeDelta": "size_delta", "m_AnchorMin": "anchor_min", "m_AnchorMax": "anchor_max",
	"m_Pivot": "pivot", "m_LocalScale": "local_scale", "m_LocalPosition": "local_position",
	"localEulerAnglesRaw": "local_euler", "localEulerAngles": "local_euler", "m_LocalEulerAngles": "local_euler",
}


## "m_AnchoredPosition.x" → "anchored_position:x"; "" for anything that is not a value of a rect.
static func curve_property(attribute: String) -> String:
	var dot: int = attribute.rfind(".")
	if dot < 0:
		return ""
	var base: String = attribute.substr(0, dot)
	var component: String = attribute.substr(dot + 1)
	if not CURVES.has(base) or not (component in ["x", "y", "z"]):
		return ""
	if component == "z" and base in ["m_AnchoredPosition", "m_SizeDelta", "m_AnchorMin", "m_AnchorMax", "m_Pivot"]:
		return ""
	return str(CURVES[base]) + ":" + component


func _host() -> Node:
	var p: Node = get_parent()
	return p if p != null and RT.is_ui(p) else null


var anchored_position: Vector2:
	get:
		return RT.anchored_position(_host()) if _host() != null else Vector2.ZERO
	set(v):
		if _host() != null:
			RT.set_anchored_position(_host(), v)

var size_delta: Vector2:
	get:
		return RT.size_delta(_host()) if _host() != null else Vector2.ZERO
	set(v):
		if _host() != null:
			RT.set_size_delta(_host(), v)

var anchor_min: Vector2:
	get:
		return RT.anchor_min(_host()) if _host() != null else Vector2.ZERO
	set(v):
		if _host() != null:
			RT.set_anchor_min(_host(), v)

var anchor_max: Vector2:
	get:
		return RT.anchor_max(_host()) if _host() != null else Vector2.ZERO
	set(v):
		if _host() != null:
			RT.set_anchor_max(_host(), v)

var pivot: Vector2:
	get:
		return RT.pivot(_host()) if _host() != null else Vector2(0.5, 0.5)
	set(v):
		if _host() != null:
			RT.set_pivot(_host(), v)

var local_position: Vector3:
	get:
		return RT.local_position(_host()) if _host() != null else Vector3.ZERO
	set(v):
		if _host() != null:
			RT.set_local_position(_host(), v)

var local_scale: Vector3:
	get:
		return RT.local_scale(_host()) if _host() != null else Vector3.ONE
	set(v):
		if _host() != null:
			RT.set_local_scale(_host(), v)

## Euler angles in degrees, Unity's order (z, then x, then y), as clips record rotations.
var _euler: Vector3 = Vector3.ZERO
var _euler_known: bool = false

var local_euler: Vector3:
	get:
		if not _euler_known and _host() != null:
			_euler = unity_euler(RT.local_rotation(_host()))
			_euler_known = true
		return _euler
	set(v):
		_euler = v
		_euler_known = true
		if _host() != null:
			RT.set_local_rotation(_host(), unity_quaternion(v))


## Quaternion.Euler: z, then x, then y (degrees).
static func unity_quaternion(e: Vector3) -> Quaternion:
	return Quaternion(Vector3.UP, deg_to_rad(e.y)) * Quaternion(Vector3.RIGHT, deg_to_rad(e.x)) * Quaternion(Vector3.BACK, deg_to_rad(e.z))


## The inverse (degrees).
static func unity_euler(q: Quaternion) -> Vector3:
	var e: Vector3 = Basis(q.normalized()).get_euler(EULER_ORDER_YXZ)
	return Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z))


## Give `target` the helper (the importer, for the rects an Animator animates).
static func ensure(target: Node, owner: Node, script: Script) -> Node:
	var found: Node = target.get_node_or_null(HELPER)
	if found != null:
		return found
	var helper := Node.new()
	helper.name = HELPER
	helper.set_meta(RT.META_HELPER, true)
	helper.set_script(script)
	target.add_child(helper)
	if owner != null and owner != helper:
		helper.owner = owner
	return helper
