# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
@tool
extends Node3D
## The RectTransform of the Control this node is a child of, as animation tracks see it (helper
## child "UnidotRect", added by the importer to the controls an Animator animates).
##
## A Unity clip animates `m_AnchoredPosition.x`, `m_SizeDelta.y`, `m_LocalScale.z` ... of a
## RectTransform. A Control has none of these: its offsets, pivot, rotation and scale follow
## from them together (runtime/rect_transform.gd). The tracks of a converted clip therefore point
## here ("Knob/UnidotRect:anchored_position:x"), and every value set goes through the functions
## that the importer and scripts use, so an animated rect is laid out like any other.
##
## Rotation, scale and position curves (m_EulerCurves, m_RotationCurves, m_ScaleCurves,
## m_PositionCurves) carry no class id and are converted as 3D tracks, which only a Node3D can
## take: this node is one, and what a track sets on it (in Godot's space, as for any Node3D) is
## handed to the rect as its local rotation, scale and position. Only what a track changed is
## handed on, so a clip that turns a rect does not move it.

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


# ---- what 3D tracks set ------------------------------------------------------------------------

var _seen_position: Vector3 = Vector3.ZERO
var _seen_rotation: Quaternion = Quaternion.IDENTITY
var _seen_scale: Vector3 = Vector3.ONE
var _syncing: bool = false


func _ready() -> void:
	sync_from_host()
	set_notify_local_transform(true)


## Take the rect's values as this node's transform (the base 3D tracks blend from).
func sync_from_host() -> void:
	var h: Node = _host()
	if h == null:
		return
	_syncing = true
	var lp: Vector3 = RT.local_position(h)
	var q: Quaternion = RT.local_rotation(h)
	position = Vector3(-lp.x, lp.y, lp.z)
	quaternion = Quaternion(q.x, -q.y, -q.z, q.w).normalized()
	scale = RT._safe_scale(RT.local_scale(h))
	_seen_position = position
	_seen_rotation = quaternion
	_seen_scale = scale
	_syncing = false


func _notification(what: int) -> void:
	if what != NOTIFICATION_LOCAL_TRANSFORM_CHANGED or _syncing:
		return
	var h: Node = _host()
	if h == null:
		return
	if not position.is_equal_approx(_seen_position):
		_seen_position = position
		RT.set_local_position(h, Vector3(-position.x, position.y, position.z))
	var q: Quaternion = quaternion
	if not q.is_equal_approx(_seen_rotation):
		_seen_rotation = q
		RT.set_local_rotation(h, Quaternion(q.x, -q.y, -q.z, q.w))
	if not scale.is_equal_approx(_seen_scale):
		_seen_scale = scale
		RT.set_local_scale(h, scale)


## Give `target` the helper (the importer, for the rects an Animator animates).
static func ensure(target: Node, owner: Node, script: Script) -> Node:
	var found: Node = target.get_node_or_null(HELPER)
	if found != null:
		return found
	var helper := Node3D.new()
	helper.name = HELPER
	helper.set_meta(RT.META_HELPER, true)
	helper.set_script(script)
	target.add_child(helper)
	if owner != null and owner != helper:
		helper.owner = owner
	return helper
