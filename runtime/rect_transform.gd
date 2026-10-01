# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## Unity RectTransform semantics on Godot nodes.
##
## One implementation for the importer (which builds Controls from serialized RectTransforms) and
## for code that changes them later (a scripting layer setting `anchoredPosition`, `sizeDelta`,
## `localRotation` ...): both go through `set_values` and the setters below, so a value written at
## import and the same value written at run time give the same node.
##
## Representation
##   * A RectTransform GameObject inside a canvas is a Control. Its anchors, offsets, pivot,
##     rotation about z and scale are the Control's own properties (Unity y-up values are flipped
##     to Godot's y-down); what a Control cannot hold (z offset, a rotation that is not about z,
##     z scale) is kept in the `unidot_rect` metadata.
##   * A Canvas is an "island": a Node3D holder with a SubViewport that renders the UI and a quad
##     that shows it in the world (runtime/canvas_plane.gd). The holder carries `unidot_canvas`
##     (viewport, root control, pixel density, fit) and `unidot_rect` (the Unity values of its own
##     RectTransform). The viewport's root Control stands for the holder's rect: its size is the
##     rect size, its position and scale are the fit and the pixel density.
##   * A UI node whose transform leaves the plane of the canvas it is in (rotated about x / y,
##     moved along z) cannot stay a Control of that canvas. It becomes an island of its own: at
##     import (`needs_island`) or at run time (`promote`, called by the setters). A nested island
##     is placed from its Unity values every frame by its plane script: on a quad of its own, or,
##     while it is coplanar with the island it sits in, as a texture inside that island.
##
## Unity space here: x right, y up, z away from the viewer, a rect's origin at its pivot. World
## matrices are Unity-space matrices; Godot Node3D transforms mirror x (unidot's convention).

const META_CANVAS := &"unidot_canvas"
const META_RECT := &"unidot_rect"
const META_VIEW := &"unidot_canvas_view"
## Helper nodes that are not GameObjects of their own (viewport, plane, shape, inline view).
const META_HELPER := &"unidot_helper"
const GROUP_UI_SHAPE := &"unidot_ui_shape"

## Largest viewport edge; beyond it the pixel density drops so quad, viewport and root scale keep
## describing the same canvas units.
const MAX_VIEWPORT_PX := 8192.0
## A rect tilted by more than this against its canvas plane (cosine of 0.5 degrees) leaves it.
const TILT_COS := 0.99996

enum Edge { LEFT = 0, RIGHT = 1, TOP = 2, BOTTOM = 3 }


# ---------------------------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------------------------

## Viewport pixels per metre of a world canvas at scale 1.
static func pixels_per_metre() -> float:
	return float(ProjectSettings.get_setting("unidot/ui/pixels_per_metre", 1024.0))


## Depth (metres) a UI node may be offset from its canvas plane and still be drawn in it.
static func flatten_depth() -> float:
	return float(ProjectSettings.get_setting("unidot/ui/flatten_depth", 0.001))


# ---------------------------------------------------------------------------------------------
# Which node is what
# ---------------------------------------------------------------------------------------------

static func is_canvas(n: Node) -> bool:
	return n != null and n.has_meta(META_CANVAS)


## A world-space canvas holder (Node3D + viewport + plane).
static func is_island(n: Node) -> bool:
	return n is Node3D and n.has_meta(META_CANVAS) and str(n.get_meta(META_CANVAS).get("mode", "")) == "world"


static func is_ui(n: Node) -> bool:
	return n is Control or is_canvas(n)


## The Control that stands for the canvas's own rect.
static func root_control(canvas: Node) -> Control:
	if canvas == null or not canvas.has_meta(META_CANVAS):
		return null
	return canvas.get_node_or_null(canvas.get_meta(META_CANVAS).get("root", NodePath())) as Control


## The canvas `c` is the root control of, or null.
static func holder_of(c: Node) -> Node:
	if not (c is Control):
		return null
	var p: Node = c.get_parent()
	if p == null or not (p is SubViewport or p is CanvasLayer):
		return null
	var h: Node = p.get_parent()
	if h != null and h.has_meta(META_CANVAS) and root_control(h) == c:
		return h
	return null


## The node that holds the rect values: the holder for a canvas (also when given its root
## control), the Control itself otherwise.
static func store(n: Node) -> Node:
	var h: Node = holder_of(n)
	return h if h != null else n


## The node scripts know the GameObject by: the holder for an imported canvas, the Control for
## one that became an island at run time (references to it were handed out before).
static func identity(n: Node) -> Node:
	if n == null:
		return null
	if n.has_meta(META_CANVAS):
		if bool(n.get_meta(META_CANVAS).get("promoted", false)):
			var r: Control = root_control(n)
			return r if r != null else n
		return n
	var h: Node = holder_of(n)
	if h != null and not bool(h.get_meta(META_CANVAS).get("promoted", false)):
		return h
	return n


## Parent GameObject: viewports, canvas layers and holders of promoted controls are skipped.
static func logical_parent(n: Node) -> Node:
	if n == null:
		return null
	var s: Node = store(n)
	var p: Node = s.get_parent()
	if p == null:
		return null
	return identity(p)


## Child GameObjects of a UI node, in sibling order (helper nodes are left out).
static func logical_children(n: Node) -> Array:
	var out: Array = []
	if n == null:
		return out
	var s: Node = store(n)
	var hosts: Array = [s]
	if s.has_meta(META_CANVAS):
		var r: Control = root_control(s)
		hosts = [r, s] if r != null else [s]
	for host in hosts:
		for c in host.get_children():
			if c.has_meta(META_HELPER):
				continue
			out.append(identity(c))
	return out


## The world island whose viewport draws `n` (for a holder: the island its parent control is in).
static func island_of(n: Node) -> Node:
	var cur: Node = store(n).get_parent() if n != null else null
	while cur != null:
		if cur is SubViewport:
			var h: Node = cur.get_parent()
			return h if is_island(h) else null
		if cur is CanvasLayer:
			return null
		cur = cur.get_parent()
	return null


## True for a holder that sits inside another canvas (its parent node is a Control).
static func is_nested(holder: Node) -> bool:
	return holder != null and holder.get_parent() is Control


static func _overlay_of(n: Node) -> Node:
	var cur: Node = n
	while cur != null:
		if cur is CanvasLayer:
			var h: Node = cur.get_parent()
			return h if is_canvas(h) else null
		if cur is SubViewport:
			return null
		cur = cur.get_parent()
	return null


# ---------------------------------------------------------------------------------------------
# Unity values of a rect
# ---------------------------------------------------------------------------------------------

## Pivot of a Control as a Unity fraction (y up). `pivot_offset` in pixels is honoured for
## hand-built controls; `set_values` writes the ratio form, which follows size changes.
static func _control_pivot(c: Control) -> Vector2:
	var r: Vector2 = c.pivot_offset_ratio
	if c.pivot_offset != Vector2.ZERO:
		var size: Vector2 = _control_rect(c).size
		if size.x > 0.0:
			r.x += c.pivot_offset.x / size.x
		if size.y > 0.0:
			r.y += c.pivot_offset.y / size.y
	return Vector2(r.x, 1.0 - r.y)


## Position and size of a Control in its parent, Godot coordinates. Controls outside the tree
## (a scene being built) are not laid out, so the rectangle is computed from anchors and offsets.
static func _control_rect(c: Control) -> Rect2:
	if c.is_inside_tree():
		return Rect2(c.position, c.size)
	var ps: Vector2 = _godot_size(c.get_parent())
	var left: float = c.anchor_left * ps.x + c.offset_left
	var top: float = c.anchor_top * ps.y + c.offset_top
	var right: float = c.anchor_right * ps.x + c.offset_right
	var bottom: float = c.anchor_bottom * ps.y + c.offset_bottom
	return Rect2(left, top, maxf(right - left, 0.0), maxf(bottom - top, 0.0))


static func _godot_size(n: Node) -> Vector2:
	if not (n is Control):
		return Vector2.ZERO
	var c: Control = n
	if c.is_inside_tree() or holder_of(c) != null:
		return c.size   # a root control's size is set explicitly
	return _control_rect(c).size


## Every Unity value of the rect:
##   anchor_min, anchor_max, anchored_position, size_delta, pivot (Vector2),
##   z (localPosition.z), rotation (Quaternion, localRotation), scale (Vector3, localScale)
static func values(n: Node) -> Dictionary:
	var s: Node = store(n)
	if s is Control:
		var c: Control = s
		var pv: Vector2 = _control_pivot(c)
		var omin := Vector2(c.offset_left, -c.offset_bottom)
		var omax := Vector2(c.offset_right, -c.offset_top)
		var sd: Vector2 = omax - omin
		var extra: Dictionary = c.get_meta(META_RECT) if c.has_meta(META_RECT) else {}
		var q: Quaternion = extra["rotation"] if extra.has("rotation") else Quaternion(Vector3(0.0, 0.0, 1.0), -c.rotation)
		var sc: Vector3 = extra["scale"] if extra.has("scale") else Vector3(c.scale.x, c.scale.y, float(extra.get("scale_z", 1.0)))
		return {
			"anchor_min": Vector2(c.anchor_left, 1.0 - c.anchor_bottom),
			"anchor_max": Vector2(c.anchor_right, 1.0 - c.anchor_top),
			"anchored_position": omin + pv * sd,
			"size_delta": sd,
			"pivot": pv,
			"z": float(extra.get("z", 0.0)),
			"rotation": q,
			"scale": sc,
		}
	var v: Dictionary = _defaults()
	if s != null and s.has_meta(META_RECT):
		v.merge(s.get_meta(META_RECT), true)
	if s is Node3D and not is_nested(s):
		# a canvas below a plain Transform: the parent rect is empty, so the anchored position
		# is the local position, and rotation / scale are the node's own
		var n3: Node3D = s
		v["anchored_position"] = Vector2(-n3.position.x, n3.position.y)
		v["z"] = n3.position.z
		v["rotation"] = Quaternion(n3.quaternion.x, -n3.quaternion.y, -n3.quaternion.z, n3.quaternion.w)
		v["scale"] = n3.scale
	return v


static func _defaults() -> Dictionary:
	return {
		"anchor_min": Vector2(0.5, 0.5), "anchor_max": Vector2(0.5, 0.5),
		"anchored_position": Vector2.ZERO, "size_delta": Vector2(100.0, 100.0), "pivot": Vector2(0.5, 0.5),
		"z": 0.0, "rotation": Quaternion.IDENTITY, "scale": Vector3.ONE,
	}


## Control rotation and scale that show the XY projection of a Unity rotation and scale.
## → [rotation (radians, Godot sense), scale (Vector2)]
static func planar_rotation_scale(q: Quaternion, s: Vector3) -> Array:
	var b := Basis(q.normalized())
	var gx := Vector2(b.x.x * s.x, -b.x.y * s.x)     # image of Godot +x
	var gy := Vector2(-b.y.x * s.y, b.y.y * s.y)     # image of Godot +y (Unity -y)
	var sx: float = gx.length()
	if sx < 1e-12:
		return [0.0, Vector2(0.0, gy.length())]
	var det: float = gx.x * gy.y - gx.y * gy.x
	return [atan2(gx.y, gx.x), Vector2(sx, det / sx)]


## Is a rotation about z only (what Control.rotation can hold)?
static func _is_z_rotation(q: Quaternion) -> bool:
	return absf(q.x) < 1e-6 and absf(q.y) < 1e-6


## The Godot properties of a Control for a set of Unity values (also used for prefab overrides,
## which are stored as property values of the instance).
static func control_properties(v: Dictionary) -> Dictionary:
	var amin: Vector2 = v["anchor_min"]
	var amax: Vector2 = v["anchor_max"]
	var ap: Vector2 = v["anchored_position"]
	var sd: Vector2 = v["size_delta"]
	var pv: Vector2 = v["pivot"]
	var q: Quaternion = v["rotation"]
	var sc: Vector3 = v["scale"]
	var rs: Array = planar_rotation_scale(q, sc)
	var extra: Dictionary = {}
	if absf(float(v["z"])) > 0.0:
		extra["z"] = float(v["z"])
	if _is_z_rotation(q):
		if sc.z != 1.0:
			extra["scale_z"] = sc.z
	else:
		extra["rotation"] = q
		extra["scale"] = sc
	return {
		"anchor_left": amin.x, "anchor_right": amax.x, "anchor_top": 1.0 - amax.y, "anchor_bottom": 1.0 - amin.y,
		"offset_left": ap.x - pv.x * sd.x, "offset_right": ap.x + (1.0 - pv.x) * sd.x,
		"offset_top": -(ap.y + (1.0 - pv.y) * sd.y), "offset_bottom": -(ap.y - pv.y * sd.y),
		"pivot_offset": Vector2.ZERO, "pivot_offset_ratio": Vector2(pv.x, 1.0 - pv.y),
		"rotation": rs[0], "scale": rs[1],
		"metadata/" + String(META_RECT): extra,
	}


## Write Unity values to a rect. `v` may hold any subset of the keys `values` returns.
static func set_values(n: Node, v: Dictionary) -> void:
	var s: Node = store(n)
	if s == null:
		return
	var full: Dictionary = values(s)
	full.merge(v, true)
	if s is Control:
		var c: Control = s
		var p: Dictionary = control_properties(full)
		# (an anchor is clamped against its opposite unless that one is pushed: min first, then max)
		c.set_anchor(SIDE_LEFT, p["anchor_left"], false, true)
		c.set_anchor(SIDE_RIGHT, p["anchor_right"], false, true)
		c.set_anchor(SIDE_TOP, p["anchor_top"], false, true)
		c.set_anchor(SIDE_BOTTOM, p["anchor_bottom"], false, true)
		c.offset_left = p["offset_left"]
		c.offset_right = p["offset_right"]
		c.offset_top = p["offset_top"]
		c.offset_bottom = p["offset_bottom"]
		c.pivot_offset = Vector2.ZERO
		c.pivot_offset_ratio = p["pivot_offset_ratio"]
		c.rotation = p["rotation"]
		c.scale = p["scale"]
		var extra: Dictionary = p["metadata/" + String(META_RECT)]
		if extra.is_empty():
			if c.has_meta(META_RECT):
				c.remove_meta(META_RECT)
		else:
			c.set_meta(META_RECT, extra)
		return
	s.set_meta(META_RECT, {
		"anchor_min": full["anchor_min"], "anchor_max": full["anchor_max"], "anchored_position": full["anchored_position"],
		"size_delta": full["size_delta"], "pivot": full["pivot"], "z": full["z"], "rotation": full["rotation"], "scale": full["scale"],
	})
	if s is Node3D and not is_nested(s):
		var n3: Node3D = s
		var ap: Vector2 = full["anchored_position"]
		var q: Quaternion = full["rotation"]
		n3.position = Vector3(-ap.x, ap.y, float(full["z"]))
		n3.quaternion = Quaternion(q.x, -q.y, -q.z, q.w).normalized()
		n3.scale = _safe_scale(full["scale"])
	_island_resized(s)


## (canvas scales are small: a 0.005 scale has a determinant of 1e-7, far below is_zero_approx)
static func _singular(b: Basis) -> bool:
	return absf(b.determinant()) < 1e-24


## Godot cannot invert a transform with a zero scale; Unity UI uses it to hide things.
static func _safe_scale(s: Vector3) -> Vector3:
	return Vector3(s.x if absf(s.x) > 1e-7 else 1e-7, s.y if absf(s.y) > 1e-7 else 1e-7, s.z if absf(s.z) > 1e-7 else 1e-7)


## Keep a canvas's root control and config in step with its rect.
static func _island_resized(holder: Node) -> void:
	if not holder.has_meta(META_CANVAS):
		return
	var cfg: Dictionary = holder.get_meta(META_CANVAS)
	if str(cfg.get("mode", "")) != "world":
		return
	var size: Vector2 = rect_size(holder)
	var pv: Vector2 = values(holder)["pivot"]
	var root: Control = root_control(holder)
	var shown := Vector2(maxf(size.x, 0.0), maxf(size.y, 0.0))
	if root != null and root.size != shown:
		root.size = shown
	if cfg.get("size") != size or cfg.get("pivot") != pv:
		cfg["size"] = size
		cfg["pivot"] = pv
		holder.set_meta(META_CANVAS, cfg)


## Unity rect size (RectTransform.rect.size).
static func rect_size(n: Node) -> Vector2:
	var s: Node = store(n)
	if s is Control:
		return _control_rect(s).size
	if s == null or not s.has_meta(META_CANVAS):
		return Vector2.ZERO
	if str(s.get_meta(META_CANVAS).get("mode", "")) != "world":
		var r: Control = root_control(s)
		return r.size if r != null else Vector2.ZERO
	var v: Dictionary = values(s)
	var ps: Vector2 = _parent_size(s)
	return (v["anchor_max"] - v["anchor_min"]) * ps + v["size_delta"]


static func _parent_size(n: Node) -> Vector2:
	var p: Node = logical_parent(n)
	return rect_size(p) if is_ui(p) else Vector2.ZERO


static func _parent_pivot(n: Node) -> Vector2:
	var p: Node = logical_parent(n)
	return pivot(p) if is_ui(p) else Vector2.ZERO


static func pivot(n: Node) -> Vector2:
	var s: Node = store(n)
	if s is Control:
		return _control_pivot(s)
	if s != null and s.has_meta(META_CANVAS) and str(s.get_meta(META_CANVAS).get("mode", "")) != "world":
		return Vector2(0.5, 0.5)
	return values(s)["pivot"]


## RectTransform.rect: the rectangle in the node's own space (origin at the pivot, y up).
static func rect(n: Node) -> Rect2:
	var size: Vector2 = rect_size(n)
	var pv: Vector2 = pivot(n)
	return Rect2(-pv.x * size.x, -pv.y * size.y, size.x, size.y)


static func anchor_min(n: Node) -> Vector2:
	return values(n)["anchor_min"]


static func anchor_max(n: Node) -> Vector2:
	return values(n)["anchor_max"]


static func anchored_position(n: Node) -> Vector2:
	return values(n)["anchored_position"]


static func size_delta(n: Node) -> Vector2:
	return values(n)["size_delta"]


static func offset_min(n: Node) -> Vector2:
	var v: Dictionary = values(n)
	return v["anchored_position"] - v["pivot"] * v["size_delta"]


static func offset_max(n: Node) -> Vector2:
	var v: Dictionary = values(n)
	return v["anchored_position"] + (Vector2.ONE - v["pivot"]) * v["size_delta"]


static func set_anchor_min(n: Node, a: Vector2) -> void:
	set_values(n, {"anchor_min": a})


static func set_anchor_max(n: Node, a: Vector2) -> void:
	set_values(n, {"anchor_max": a})


static func set_anchored_position(n: Node, p: Vector2) -> void:
	set_values(n, {"anchored_position": p})


static func set_size_delta(n: Node, d: Vector2) -> void:
	set_values(n, {"size_delta": d})


## Unity keeps anchoredPosition and sizeDelta when a script changes the pivot: the rect moves.
static func set_pivot(n: Node, p: Vector2) -> void:
	set_values(n, {"pivot": p})


static func set_offset_min(n: Node, o: Vector2) -> void:
	var v: Dictionary = values(n)
	var omax: Vector2 = v["anchored_position"] + (Vector2.ONE - v["pivot"]) * v["size_delta"]
	var sd: Vector2 = omax - o
	set_values(n, {"size_delta": sd, "anchored_position": o + v["pivot"] * sd})


static func set_offset_max(n: Node, o: Vector2) -> void:
	var v: Dictionary = values(n)
	var omin: Vector2 = v["anchored_position"] - v["pivot"] * v["size_delta"]
	var sd: Vector2 = o - omin
	set_values(n, {"size_delta": sd, "anchored_position": omin + v["pivot"] * sd})


## RectTransform.SetSizeWithCurrentAnchors(axis, size): axis 0 horizontal, 1 vertical.
static func set_size_with_current_anchors(n: Node, axis: int, size: float) -> void:
	var v: Dictionary = values(n)
	var ps: Vector2 = _parent_size(n)
	var sd: Vector2 = v["size_delta"]
	sd[axis] = size - ps[axis] * (v["anchor_max"][axis] - v["anchor_min"][axis])
	set_values(n, {"size_delta": sd})


## RectTransform.SetInsetAndSizeFromParentEdge(edge, inset, size).
static func set_inset_and_size_from_parent_edge(n: Node, edge: int, inset: float, size: float) -> void:
	var v: Dictionary = values(n)
	var axis: int = 1 if (edge == Edge.TOP or edge == Edge.BOTTOM) else 0
	var end: bool = edge == Edge.TOP or edge == Edge.RIGHT
	var amin: Vector2 = v["anchor_min"]
	var amax: Vector2 = v["anchor_max"]
	var sd: Vector2 = v["size_delta"]
	var ap: Vector2 = v["anchored_position"]
	var pv: Vector2 = v["pivot"]
	amin[axis] = 1.0 if end else 0.0
	amax[axis] = 1.0 if end else 0.0
	sd[axis] = size
	ap[axis] = (-inset - size * (1.0 - pv[axis])) if end else (inset + size * pv[axis])
	set_values(n, {"anchor_min": amin, "anchor_max": amax, "size_delta": sd, "anchored_position": ap})


# ---------------------------------------------------------------------------------------------
# Local and world transform (Unity space)
# ---------------------------------------------------------------------------------------------

## localPosition: the pivot in the parent's rect space (parent pivot at the origin, y up).
static func local_position(n: Node) -> Vector3:
	var s: Node = store(n)
	if s is Control:
		var c: Control = s
		var r: Rect2 = _control_rect(c)
		var pv: Vector2 = _control_pivot(c)
		var gp: Vector2 = r.position + Vector2(pv.x * r.size.x, (1.0 - pv.y) * r.size.y)
		var z: float = float(c.get_meta(META_RECT).get("z", 0.0)) if c.has_meta(META_RECT) else 0.0
		var pc: Node = c.get_parent()
		if not (pc is Control):
			return Vector3(gp.x, -gp.y, z)
		var ps: Vector2 = _godot_size(pc)
		var pp: Vector2 = pivot(pc)
		return Vector3(gp.x - pp.x * ps.x, (1.0 - pp.y) * ps.y - gp.y, z)
	var v: Dictionary = values(s)
	if s is Node3D and not is_nested(s):
		return Vector3(v["anchored_position"].x, v["anchored_position"].y, float(v["z"]))
	var psz: Vector2 = _parent_size(s)
	var ppv: Vector2 = _parent_pivot(s)
	var amin: Vector2 = v["anchor_min"]
	var amax: Vector2 = v["anchor_max"]
	var xy: Vector2 = psz * (amin - ppv + v["pivot"] * (amax - amin)) + v["anchored_position"]
	return Vector3(xy.x, xy.y, float(v["z"]))


static func local_rotation(n: Node) -> Quaternion:
	return values(n)["rotation"]


static func local_scale(n: Node) -> Vector3:
	return values(n)["scale"]


## The rect's space → its parent's rect space.
static func local_matrix(n: Node) -> Transform3D:
	var v: Dictionary = values(n)
	var q: Quaternion = v["rotation"]
	return Transform3D(Basis(q.normalized()) * Basis.from_scale(v["scale"]), local_position(n))


static func unity_from_godot(t: Transform3D) -> Transform3D:
	var b: Basis = t.basis
	return Transform3D(Basis(Vector3(b.x.x, -b.x.y, -b.x.z), Vector3(-b.y.x, b.y.y, b.y.z), Vector3(-b.z.x, b.z.y, b.z.z)), Vector3(-t.origin.x, t.origin.y, t.origin.z))


## The mirror is its own inverse.
static func godot_from_unity(t: Transform3D) -> Transform3D:
	return unity_from_godot(t)


static func _node3d_global(n: Node3D) -> Transform3D:
	if n.is_inside_tree():
		return n.global_transform
	var t: Transform3D = n.transform
	var p: Node = n.get_parent()
	while p != null:
		if p is Node3D:
			t = p.transform * t
		p = p.get_parent()
	return t


## The rect's space → Unity world space. Screen-space canvases live in window pixels (y up).
static func world_matrix(n: Node) -> Transform3D:
	var s: Node = store(n)
	if s == null:
		return Transform3D.IDENTITY
	if s.has_meta(META_CANVAS):
		if str(s.get_meta(META_CANVAS).get("mode", "")) != "world":
			return _overlay_matrix(s)
		if not is_nested(s):
			return unity_from_godot(_node3d_global(s))
	elif s is Node3D:
		return unity_from_godot(_node3d_global(s))
	var p: Node = logical_parent(s)
	if p == null or not (is_ui(p) or p is Node3D):
		return local_matrix(s)
	return world_matrix(p) * local_matrix(s)


## Unity places a screen-space canvas with its pivot at the screen centre and the scale factor
## as its scale: world units are window pixels, y up.
static func _overlay_matrix(canvas: Node) -> Transform3D:
	var root: Control = root_control(canvas)
	if root == null:
		return Transform3D.IDENTITY
	var f: Vector2 = root.scale
	var size: Vector2 = root.size
	return Transform3D(Basis.from_scale(Vector3(f.x, f.y, f.x)), Vector3(size.x * f.x * 0.5, size.y * f.y * 0.5, 0.0))


static func world_position(n: Node) -> Vector3:
	return world_matrix(n).origin


static func world_rotation(n: Node) -> Quaternion:
	return world_matrix(n).basis.orthonormalized().get_rotation_quaternion()


static func lossy_scale(n: Node) -> Vector3:
	var b: Basis = world_matrix(n).basis
	return Vector3(b.x.length(), b.y.length(), b.z.length())


static func _parent_world(n: Node) -> Transform3D:
	var p: Node = logical_parent(n)
	if p == null:
		return Transform3D.IDENTITY
	if is_ui(p):
		return world_matrix(p)
	if p is Node3D:
		return unity_from_godot(_node3d_global(p))
	return Transform3D.IDENTITY


## RectTransform.GetLocalCorners: bottom-left, top-left, top-right, bottom-right.
static func local_corners(n: Node) -> Array:
	var r: Rect2 = rect(n)
	return [Vector3(r.position.x, r.position.y, 0.0), Vector3(r.position.x, r.end.y, 0.0), Vector3(r.end.x, r.end.y, 0.0), Vector3(r.end.x, r.position.y, 0.0)]


static func world_corners(n: Node) -> Array:
	var m: Transform3D = world_matrix(n)
	var out: Array = []
	for c in local_corners(n):
		out.append(m * c)
	return out


static func set_local_position(n: Node, p: Vector3) -> void:
	var s: Node = store(n)
	var cur: Vector3 = local_position(s)
	var v: Dictionary = values(s)
	set_values(s, {"anchored_position": v["anchored_position"] + Vector2(p.x - cur.x, p.y - cur.y), "z": p.z})
	_left_plane(s)


static func set_local_rotation(n: Node, q: Quaternion) -> void:
	var s: Node = store(n)
	set_values(s, {"rotation": q.normalized()})
	_left_plane(s)


static func set_local_scale(n: Node, sc: Vector3) -> void:
	set_values(n, {"scale": sc})


static func set_world_position(n: Node, p: Vector3) -> void:
	var pm: Transform3D = _parent_world(n)
	if _singular(pm.basis):
		return
	set_local_position(n, pm.affine_inverse() * p)


static func set_world_rotation(n: Node, q: Quaternion) -> void:
	var pq: Quaternion = _parent_world(n).basis.orthonormalized().get_rotation_quaternion()
	set_local_rotation(n, pq.inverse() * q)


## Does a local transform stay in its parent's plane? `depth_scale` turns z into metres.
static func is_planar(z: float, q: Quaternion, depth_scale: float) -> bool:
	if absf(z) * depth_scale > flatten_depth():
		return false
	var zaxis: Vector3 = Basis(q.normalized()).z
	return absf(zaxis.z) >= TILT_COS


## After a setter: a Control that no longer lies in the plane of its canvas becomes an island.
static func _left_plane(s: Node) -> void:
	if not (s is Control) or not s.is_inside_tree():
		return
	if island_of(s) == null:
		return   # screen space: drawn flat whatever its transform is
	var v: Dictionary = values(s)
	var depth: float = _parent_world(s).basis.z.length()
	if is_planar(float(v["z"]), v["rotation"], depth):
		return
	promote(s)


# ---------------------------------------------------------------------------------------------
# Islands
# ---------------------------------------------------------------------------------------------

static var _plane_script: Script = null

static func plane_script() -> Script:
	if _plane_script == null:
		var me: RefCounted = new()
		var dir: String = (me.get_script() as Script).resource_path.get_base_dir()
		if ResourceLoader.exists(dir + "/canvas_plane.gd"):
			_plane_script = load(dir + "/canvas_plane.gd")
	return _plane_script


## Turn `holder` (a Node3D already in place) into a world canvas whose rect is `root`:
## SubViewport, root control, plane and pointer shape. `rect_values` are the Unity values of the
## canvas's own RectTransform; `owner` is set on the new nodes when a scene is being built.
static func build_island(holder: Node3D, root: Control, rect_values: Dictionary, owner: Node = null, promoted: bool = false) -> void:
	var v: Dictionary = _defaults()
	v.merge(rect_values, true)
	var vp := SubViewport.new()
	vp.name = "Viewport"
	vp.size = Vector2i(2, 2)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.gui_embed_subwindows = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.set_meta(META_HELPER, true)
	holder.add_child(vp, true)
	if root.get_parent() != null:
		root.get_parent().remove_child(root)
	vp.add_child(root, true)
	# the root control is the canvas's own rect: top-left anchored, sized explicitly
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		root.set_anchor_and_offset(side, 0.0, 0.0, false)
	root.pivot_offset = Vector2.ZERO
	root.pivot_offset_ratio = Vector2.ZERO
	root.rotation = 0.0
	root.position = Vector2.ZERO
	if root.has_meta(META_RECT):
		root.remove_meta(META_RECT)
	var area := Area3D.new()
	area.name = "UiShape"
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	area.add_child(shape, true)
	area.set_meta(META_HELPER, true)
	holder.add_child(area, true)
	area.add_to_group(GROUP_UI_SHAPE, true)
	var plane := MeshInstance3D.new()
	plane.name = "CanvasPlane"
	plane.mesh = QuadMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	plane.material_override = mat
	plane.set_meta(META_HELPER, true)
	holder.set_meta(META_CANVAS, {
		"mode": "world", "viewport": holder.get_path_to(vp), "root": holder.get_path_to(root), "plane": NodePath("CanvasPlane"),
		"size": Vector2.ZERO, "pivot": v["pivot"], "k": 1.0, "offset": Vector2.ZERO, "plane_size": Vector2.ZERO, "plane_center": Vector3.ZERO,
		"promoted": promoted,
	})
	holder.set_meta(META_RECT, v)
	if not is_nested(holder):
		set_values(holder, v)   # the holder's own transform comes from the rect
	_island_resized(holder)
	var cfg: Dictionary = holder.get_meta(META_CANVAS)
	cfg["density"] = maxf(pixels_per_metre() * maxf(world_matrix(holder).basis.x.length(), 1e-6), 0.01)
	holder.set_meta(META_CANVAS, cfg)
	# the plane goes in last, with its script: in a running scene its _ready starts the syncing
	var script: Script = plane_script()
	if script != null:
		plane.set_script(script)
	holder.add_child(plane, true)
	if owner != null:
		for x in [vp, plane, area, shape]:
			x.owner = owner
		root.owner = owner
	fit_island(holder)


## A Control that left the plane of its canvas gets a canvas of its own in the same place of
## the tree. References to the Control stay valid: it becomes the new canvas's root control.
static func promote(c: Control) -> Node3D:
	var existing: Node = holder_of(c)
	if existing != null:
		return existing as Node3D
	var v: Dictionary = values(c)
	var parent: Node = c.get_parent()
	var index: int = c.get_index()
	var holder := Node3D.new()
	holder.name = c.name
	parent.remove_child(c)
	parent.add_child(holder)
	parent.move_child(holder, index)
	build_island(holder, c, v, null, true)
	sync_island(holder)
	return holder


## Does the control draw anything? RectTransforms without a Graphic become plain Controls (menus,
## anchors, layout groups) whose rects are layout helpers, often far larger than what they hold,
## and must not size the plane.
static func draws(c: Control) -> bool:
	return c.get_class() != "Control"


static func control_transform(c: Control) -> Transform2D:
	if c.is_inside_tree():
		return c.get_transform()
	var r: Rect2 = _control_rect(c)
	var pv: Vector2 = c.pivot_offset + c.pivot_offset_ratio * r.size
	return Transform2D(0.0, r.position + pv) * Transform2D(c.rotation, c.scale, 0.0, Vector2.ZERO) * Transform2D(0.0, -pv)


## Append the rect, in root units, of every drawing control at or below `c`, hidden ones included
## (menus toggled at run time must fit the plane). `to_root` maps c's parent space to root space.
static func content_bounds(c: Control, to_root: Transform2D, out: Array) -> void:
	if c.has_meta(META_VIEW) and not c.visible:
		return   # the inline view of a nested canvas that is shown on its own plane
	var xf: Transform2D = to_root * control_transform(c)
	var own: Rect2 = xf * Rect2(Vector2.ZERO, _control_rect(c).size)
	if draws(c):
		out.append(own)
	# a Mask / RectMask2D / ScrollRect clips what it holds: hidden scroll content must not grow the plane
	var inner: Array = [] if (c.clip_contents or c is ScrollContainer) else out
	for ch in c.get_children():
		if ch is Control:
			content_bounds(ch, xf, inner)
	if inner != out:
		for r in inner:
			var clipped: Rect2 = (r as Rect2).intersection(own)
			if clipped.size.x > 0.0 and clipped.size.y > 0.0:
				out.append(clipped)


## Size the viewport and the plane to what the canvas draws (Unity world canvases do not clip:
## children may lie far outside the canvas rect) and keep the canvas's world placement.
## → true when the canvas draws something.
static func fit_island(holder: Node) -> bool:
	var cfg: Dictionary = holder.get_meta(META_CANVAS)
	var root: Control = root_control(holder)
	var vp: SubViewport = holder.get_node_or_null(cfg.get("viewport", NodePath())) as SubViewport
	var plane: MeshInstance3D = holder.get_node_or_null(cfg.get("plane", NodePath())) as MeshInstance3D
	if root == null or vp == null or plane == null:
		return false
	var rsize: Vector2 = cfg.get("size", Vector2.ZERO)
	var rects: Array = []
	if draws(root):
		rects.append(Rect2(Vector2.ZERO, root.size))
	for ch in root.get_children():
		if ch is Control:
			content_bounds(ch, Transform2D.IDENTITY, rects)
	var union := Rect2()
	var any: bool = false
	for r in rects:
		var rr: Rect2 = (r as Rect2).abs()
		if rr.size.x <= 0.0 or rr.size.y <= 0.0:
			continue
		union = union.merge(rr) if any else rr
		any = true
	if not any:
		if cfg.get("plane_size", Vector2.ZERO) != Vector2.ZERO:
			cfg["plane_size"] = Vector2.ZERO
			holder.set_meta(META_CANVAS, cfg)
		return false
	# pixel density: the wanted one, lowered when the viewport would exceed its limit
	var want: float = float(cfg.get("density", cfg.get("k", 1.0)))
	var k: float = want
	if union.size.x * k > MAX_VIEWPORT_PX:
		k = MAX_VIEWPORT_PX / union.size.x
	if union.size.y * k > MAX_VIEWPORT_PX:
		k = MAX_VIEWPORT_PX / union.size.y
	k = maxf(k, 1e-4)
	var pv: Vector2 = cfg.get("pivot", Vector2(0.5, 0.5))
	# keep the current fit while the content stays inside it and has not shrunk much (content
	# that moves every frame would otherwise resize the viewport every frame)
	var cur := Rect2(cfg.get("offset", Vector2.ZERO), cfg.get("plane_size", Vector2.ZERO))
	if is_equal_approx(k, float(cfg.get("k", 0.0))) and cfg.get("fit_size") == rsize and cfg.get("fit_pivot") == pv:
		var slack: Vector2 = Vector2.ONE * (1.5 / k)
		if cur.grow(0.001 / k).encloses(union) and cur.size.x <= union.size.x * 1.25 + slack.x and cur.size.y <= union.size.y * 1.25 + slack.y:
			return true
	# whole pixels, so the texture maps 1:1 and controls keep their sub-pixel placement
	var origin: Vector2 = (union.position * k).floor() / k
	var w: int = clampi(int(ceil((union.end.x - origin.x) * k - 0.001)), 1, int(MAX_VIEWPORT_PX))
	var h: int = clampi(int(ceil((union.end.y - origin.y) * k - 0.001)), 1, int(MAX_VIEWPORT_PX))
	var psize := Vector2(w / k, h / k)
	root.scale = Vector2(k, k)
	root.position = -origin * k
	if vp.size != Vector2i(w, h):
		vp.size = Vector2i(w, h)
	# the plane in the holder's space: Unity x is mirrored there, the quad is turned to face -z
	var center := Vector3(pv.x * rsize.x - origin.x - psize.x * 0.5, (1.0 - pv.y) * rsize.y - origin.y - psize.y * 0.5, 0.0)
	var quad: QuadMesh = plane.mesh as QuadMesh
	if quad != null:
		quad.size = psize
	plane.transform = Transform3D(Basis.from_euler(Vector3(0.0, PI, 0.0)), center)
	var area: Area3D = holder.get_node_or_null(NodePath("UiShape")) as Area3D
	if area != null:
		area.transform = plane.transform
		var shape: CollisionShape3D = area.get_node_or_null(NodePath("CollisionShape3D")) as CollisionShape3D
		if shape != null and shape.shape is BoxShape3D:
			(shape.shape as BoxShape3D).size = Vector3(psize.x, psize.y, 0.01)
	cfg["k"] = k
	cfg["offset"] = origin
	cfg["plane_size"] = psize
	cfg["plane_center"] = center
	cfg["fit_size"] = rsize
	cfg["fit_pivot"] = pv
	holder.set_meta(META_CANVAS, cfg)
	return true


## Is the canvas shown? Its own state, the control it hangs under and the canvases around it.
static func island_shown(holder: Node) -> bool:
	var root: Control = root_control(holder)
	if root == null or not root.visible or not (holder as Node3D).visible:
		return false
	if not is_nested(holder):
		return (holder as Node3D).is_visible_in_tree()
	var p: Control = holder.get_parent() as Control
	if p == null or not p.is_visible_in_tree():
		return false
	var outer: Node = island_of(holder)
	return outer == null or island_shown(outer)


## How many canvases are around this one.
static func island_depth(holder: Node) -> int:
	var d: int = 0
	var cur: Node = island_of(holder)
	while cur != null:
		d += 1
		cur = island_of(cur)
	return d


## Place and size a canvas for this frame (called by its plane script): the rect follows its
## anchors, the pixel density follows the world scale, the plane fits the content, and a canvas
## nested in another one is put where its Unity values say.
static func sync_island(holder: Node) -> void:
	var cfg: Dictionary = holder.get_meta(META_CANVAS)
	var root: Control = root_control(holder)
	var plane: MeshInstance3D = holder.get_node_or_null(cfg.get("plane", NodePath())) as MeshInstance3D
	if root == null or plane == null:
		return
	_island_resized(holder)
	cfg = holder.get_meta(META_CANVAS)
	var nested: bool = is_nested(holder)
	var wm: Transform3D = world_matrix(holder)
	var density: float = maxf(pixels_per_metre() * maxf(wm.basis.x.length(), 1e-6), 0.01)
	if not is_equal_approx(density, float(cfg.get("density", 0.0))):
		cfg["density"] = density
		holder.set_meta(META_CANVAS, cfg)
	var has_content: bool = fit_island(holder)
	cfg = holder.get_meta(META_CANVAS)
	var shown: bool = has_content and island_shown(holder) and not _singular(wm.basis)
	var inline: bool = false
	if nested and not _singular(wm.basis):
		var outer: Node = island_of(holder)
		if outer != null and _coplanar(wm, world_matrix(outer)):
			inline = true
		else:
			(holder as Node3D).global_transform = godot_from_unity(wm)
	var view: TextureRect = _inline_view(holder, inline and shown)
	if view != null:
		view.visible = inline and shown
		if inline and shown:
			_place_view(holder, view, cfg)
	var on_plane: bool = shown and not inline
	if plane.visible != on_plane:
		plane.visible = on_plane
	plane.sorting_offset = 0.002 * island_depth(holder)
	var shape: CollisionShape3D = holder.get_node_or_null(NodePath("UiShape/CollisionShape3D")) as CollisionShape3D
	if shape != null and shape.disabled == on_plane:
		shape.disabled = not on_plane


static func _coplanar(wm: Transform3D, outer: Transform3D) -> bool:
	if _singular(outer.basis):
		return true
	var rel: Transform3D = outer.affine_inverse() * wm
	var zaxis: Vector3 = rel.basis.z
	if zaxis.length_squared() < 1e-18:
		return true
	if absf(zaxis.normalized().z) < TILT_COS:
		return false
	return absf(rel.origin.z) * outer.basis.z.length() <= flatten_depth()


## The TextureRect that shows a nested canvas inside the canvas around it.
static func _inline_view(holder: Node, create: bool) -> TextureRect:
	var host: Control = holder.get_parent() as Control
	if host == null:
		return null
	var name: String = String(holder.name) + "_View"
	for c in host.get_children():
		if c.has_meta(META_VIEW) and c.get_meta(META_VIEW) == holder.get_instance_id():
			return c as TextureRect
	if not create:
		return null
	var cfg: Dictionary = holder.get_meta(META_CANVAS)
	var vp: SubViewport = holder.get_node_or_null(cfg.get("viewport", NodePath())) as SubViewport
	if vp == null:
		return null
	var view := TextureRect.new()
	view.name = name
	view.texture = vp.get_texture()
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_SCALE
	view.mouse_filter = Control.MOUSE_FILTER_STOP
	view.set_meta(META_VIEW, holder.get_instance_id())
	view.set_meta(META_HELPER, true)
	host.add_child(view)
	host.move_child(view, holder.get_index() + 1)
	view.gui_input.connect(func(ev: InputEvent) -> void:
		var e: InputEvent = ev.duplicate()
		if e is InputEventMouse and view.size.x > 0.0 and view.size.y > 0.0:
			var px: Vector2 = view.get_local_mouse_position() / view.size * Vector2(vp.size)
			e.position = px
			e.global_position = px
		vp.push_input(e, true))
	return view


## The view covers the canvas's fitted rectangle, transformed like a Control with the canvas's
## Unity values would be.
static func _place_view(holder: Node, view: TextureRect, cfg: Dictionary) -> void:
	var host: Control = holder.get_parent() as Control
	var v: Dictionary = values(holder)
	var size: Vector2 = cfg.get("size", Vector2.ZERO)
	var pv: Vector2 = v["pivot"]
	var lp: Vector3 = local_position(holder)
	var hs: Vector2 = _godot_size(host)
	var hp: Vector2 = pivot(host)
	var gp := Vector2(lp.x + hp.x * hs.x, (1.0 - hp.y) * hs.y - lp.y)   # the pivot in the host
	var off: Vector2 = cfg.get("offset", Vector2.ZERO)
	var psize: Vector2 = cfg.get("plane_size", size)
	var pivot_px: Vector2 = Vector2(pv.x * size.x, (1.0 - pv.y) * size.y) - off
	var rs: Array = planar_rotation_scale(v["rotation"], v["scale"])
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		view.set_anchor(side, 0.0, false, false)
	view.pivot_offset_ratio = Vector2.ZERO
	view.pivot_offset = pivot_px
	view.size = psize
	view.position = gp - pivot_px
	view.rotation = rs[0]
	view.scale = rs[1]
	if view.get_index() != holder.get_index() + 1:
		host.move_child(view, mini(holder.get_index() + 1, host.get_child_count() - 1))


## Decide at import whether a RectTransform needs a canvas of its own: `parent` is the node its
## GameObject is built under, `v` its Unity values, `depth_scale` the world scale along z of the
## parent (within the file being imported).
static func needs_island(parent: Node, v: Dictionary, depth_scale: float) -> bool:
	if not (parent is Control):
		return false
	if _overlay_of(parent) != null:
		return false
	return not is_planar(float(v.get("z", 0.0)), v.get("rotation", Quaternion.IDENTITY), depth_scale)
