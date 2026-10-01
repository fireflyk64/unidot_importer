# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
extends Node
## Unity UI auto layout for the Control this node is a child of (ui_integration.gd adds it as a
## helper child named "UnidotLayout", so the Control stays free for a script of the scene).
##
## The parent's metadata describes the Unity layout components of that GameObject:
##   unidot_layout  {type: "horizontal" | "vertical" | "grid", padding: [left, right, top, bottom],
##                   spacing, align (0..8, UpperLeft .. LowerRight), control_w, control_h, expand_w,
##                   expand_h, scale_w, scale_h, reverse; for grids cell: Vector2, spacing2: Vector2,
##                   corner, axis, constraint (0 flexible, 1 columns, 2 rows), count}
##   unidot_fitter  {h, v}          ContentSizeFitter: 0 unconstrained, 1 min size, 2 preferred size
##   unidot_aspect  {mode, ratio}   AspectRatioFitter: 1 width controls height, 2 height controls
##                                  width, 3 fit in parent, 4 envelope parent
## (each may hold `enabled: false`: the component is disabled, its settings are kept)
## and any Control may carry
##   unidot_layout_element {min: Vector2, pref: Vector2, flex: Vector2, ignore, priority}
## with -1 for "not set" (Unity's LayoutElement).
##
## The algorithm is Unity's (LayoutRebuilder, HorizontalOrVerticalLayoutGroup, GridLayoutGroup,
## ContentSizeFitter, AspectRatioFitter, LayoutUtility): a rebuild starts at the layout root (the
## topmost object of a chain of layout groups); per axis the sizes components ask for are gathered
## bottom-up and applied top-down — an object's own fitters first, then its group, then its
## children — the horizontal axis for the whole subtree, then the vertical one. Groups place a
## child the way Unity does, by writing its anchors, anchored position and size delta through
## rect_transform.gd, so `anchoredPosition` read by a script is what Unity would report.

const RT := preload("./rect_transform.gd")
const UiText := preload("./ui_text.gd")
const HELPER := "UnidotLayout"

var _host: Control = null
var _queued: bool = false
var _busy: bool = false
var _inputs: Dictionary = {}   # [control instance id, axis] → [min, preferred, flexible]
var _changed: bool = false


func _ready() -> void:
	_host = get_parent() as Control
	if _host == null:
		return
	_host.child_order_changed.connect(queue_layout)
	_host.resized.connect(queue_layout)
	_host.visibility_changed.connect(queue_layout)
	_host.child_entered_tree.connect(_watch)
	for c in _host.get_children():
		_watch(c)
	queue_layout()


func _watch(c: Node) -> void:
	if c is Control and c != _host:
		if not c.visibility_changed.is_connected(queue_layout):
			c.visibility_changed.connect(queue_layout)
		if not c.minimum_size_changed.is_connected(queue_layout):
			c.minimum_size_changed.connect(queue_layout)
		if not c.resized.is_connected(queue_layout):
			c.resized.connect(queue_layout)
	queue_layout()


static func helper_of(c: Node) -> Node:
	if c == null:
		return null
	var s: Node = RT.child_host(RT.store(c))
	var h: Node = s.get_node_or_null(HELPER) if s != null else null
	return h if h != null and h.has_method("layout_now") else null


## LayoutRebuilder.MarkLayoutForRebuild: the rebuild runs once at the end of the frame, from the
## layout root.
func queue_layout() -> void:
	if not is_inside_tree() or _host == null:
		return
	var root: Node = _root_helper()
	if root != self:
		root.queue_layout()
		return
	if _queued or _busy:
		return
	_queued = true
	layout_now.call_deferred()


## The helper of the topmost object in the chain of layout groups above this one.
func _root_helper() -> Node:
	var top: Node = self
	var cur: Control = _host
	while true:
		var p: Node = RT.logical_parent(cur)
		var pc: Control = RT.child_host(RT.store(p)) as Control if p != null else null
		if pc == null or _group(pc).is_empty():
			break
		var ph: Node = helper_of(pc)
		if ph == null:
			break
		top = ph
		cur = pc
	return top


static func _group(c: Control) -> Dictionary:
	return _component(c, &"unidot_layout")


## The settings of a layout component of `c`; empty when it has none or it is disabled
## (`enabled: false`: the settings are kept for when a script enables it).
static func _component(c: Control, key: StringName) -> Dictionary:
	if c == null or not c.has_meta(key):
		return {}
	var cfg = c.get_meta(key)
	if not (cfg is Dictionary) or not bool(cfg.get("enabled", true)):
		return {}
	return cfg


## Rebuild now (LayoutRebuilder.ForceRebuildLayoutImmediate), from the layout root.
func layout_now() -> void:
	_queued = false
	if _host == null or _busy or not is_inside_tree():
		return
	var root: Node = _root_helper()
	if root != self:
		root.layout_now()
		return
	if not _host.is_visible_in_tree():
		return   # Unity does not lay out inactive objects; showing them queues a rebuild
	_busy = true
	# what the vertical pass changes (aspect fitters, wrapped grids, fitted children) can change
	# what the horizontal pass saw: Unity rebuilds again on the next frame; here until nothing moves
	for _round in range(3):
		_changed = false
		for axis in range(2):
			_inputs.clear()
			_control(_host, axis, true)
		if not _changed:
			break
	_busy = false


# --- what a rect asks for (LayoutUtility) --------------------------------------------------------

## The children a group lays out: active RectTransforms that do not ignore layout.
func _rect_children(host: Control) -> Array:
	var out: Array = []
	for c in RT.logical_children(host):
		var ctl: Control = RT.child_host(RT.store(c)) as Control
		if ctl == null or not ctl.visible:
			continue
		var s: Node = RT.store(c)
		if s is Node3D and not (s as Node3D).visible:
			continue
		if ctl.has_meta("unidot_layout_element") and bool(ctl.get_meta("unidot_layout_element").get("ignore", false)):
			continue
		out.append(c)
	return out


## [min, preferred, flexible] of a rect on one axis: per property the component with the highest
## layoutPriority that gives a value >= 0 wins (LayoutElement 1 unless set, everything else 0);
## among equals the larger value.
func _ask(c: Node, axis: int) -> Array:
	var ctl: Control = RT.child_host(RT.store(c)) as Control
	var key: Array = [ctl.get_instance_id(), axis]
	if _inputs.has(key):
		return _inputs[key]
	var cands: Array = [[], [], []]   # [priority, value] per property
	if ctl.has_meta("unidot_layout_element"):
		var le: Dictionary = ctl.get_meta("unidot_layout_element")
		if bool(le.get("enabled", true)):
			var prio: int = int(le.get("priority", 1))
			cands[0].append([prio, float((le.get("min", Vector2(-1, -1)) as Vector2)[axis])])
			cands[1].append([prio, float((le.get("pref", Vector2(-1, -1)) as Vector2)[axis])])
			cands[2].append([prio, float((le.get("flex", Vector2(-1, -1)) as Vector2)[axis])])
	var cfg: Dictionary = _group(ctl)
	if not cfg.is_empty():
		var g: Array = _group_ask(ctl, cfg, axis)
		for i in range(3):
			cands[i].append([0, g[i]])
	var own: Vector2 = _content_size(ctl, axis)
	if own.x >= 0.0:
		cands[0].append([0, 0.0])
		cands[1].append([0, own[axis]])
		cands[2].append([0, -1.0])
	var res: Array = [0.0, 0.0, 0.0]
	for i in range(3):
		var best_p = null
		for cand in cands[i]:
			if best_p != null and cand[0] < best_p:
				continue
			if cand[1] < 0.0:
				continue
			if best_p == null or cand[0] > best_p:
				best_p = cand[0]
				res[i] = cand[1]
			elif cand[1] > res[i]:
				res[i] = cand[1]
	res[1] = maxf(res[0], res[1])
	_inputs[key] = res
	return res


## Preferred size of a graphic (Unity's Image and Text are layout elements): a sprite's size, a
## text's size. (-1, -1) for controls that ask for nothing.
static func _content_size(ctl: Control, axis: int) -> Vector2:
	if ctl is Label or ctl is RichTextLabel:
		return Vector2(UiText.preferred_size(ctl, 0) if axis == 0 else 0.0, UiText.preferred_size(ctl, 1) if axis == 1 else 0.0)
	if ctl is TextureRect:
		# an Image without a sprite asks for nothing (the importer gives it a small white texture)
		var tex: Texture2D = ctl.texture
		if tex != null and not bool(ctl.get_meta("unidot_no_sprite", false)):
			return tex.get_size()
		return Vector2.ZERO
	return Vector2(-1, -1)


func _child_sizes(c: Node, axis: int, control: bool, force_expand: bool) -> Array:
	var res: Array
	if not control:
		var sd: float = (RT.values(c)["size_delta"] as Vector2)[axis]
		res = [sd, sd, 0.0]
	else:
		res = _ask(c, axis).duplicate()
	if force_expand:
		res[2] = maxf(res[2], 1.0)
	return res


## Padding as [left, right, top, bottom] (stored as that array, or as a RectOffset-like
## dictionary a script may hold on to and change).
static func _pad(cfg: Dictionary) -> Array:
	var p = cfg.get("padding", [0, 0, 0, 0])
	if p is Dictionary:
		return [float(p.get("left", 0)), float(p.get("right", 0)), float(p.get("top", 0)), float(p.get("bottom", 0))]
	return [float(p[0]), float(p[1]), float(p[2]), float(p[3])]


static func _flag(cfg: Dictionary, name: String, axis: int) -> bool:
	return bool(cfg.get(name + ("_w" if axis == 0 else "_h"), false))


## LayoutGroup.minWidth / preferredWidth / flexibleWidth (and the heights).
func _group_ask(host: Control, cfg: Dictionary, axis: int) -> Array:
	var pad: Array = _pad(cfg)
	var padding: float = (pad[0] + pad[1]) if axis == 0 else (pad[2] + pad[3])
	var kids: Array = _rect_children(host)
	var kind: String = str(cfg.get("type", ""))
	if kind == "grid":
		var cell: Vector2 = cfg.get("cell", Vector2(100, 100))
		var gap: Vector2 = cfg.get("spacing2", Vector2.ZERO)
		var constraint: int = int(cfg.get("constraint", 0))
		var count: int = maxi(int(cfg.get("count", 2)), 1)
		if axis == 0:
			var min_cols: int = 1
			var pref_cols: int = ceili(sqrt(float(kids.size())))
			if constraint == 1:
				min_cols = count
				pref_cols = count
			elif constraint == 2:
				min_cols = ceili(kids.size() / float(count) - 0.001)
				pref_cols = min_cols
			return [padding + (cell.x + gap.x) * min_cols - gap.x, padding + (cell.x + gap.x) * pref_cols - gap.x, -1.0]
		var min_rows: int
		if constraint == 1:
			min_rows = ceili(kids.size() / float(count) - 0.001)
		elif constraint == 2:
			min_rows = count
		else:
			var width: float = RT.rect_size(host).x
			var cols: int = maxi(1, floori((width - (pad[0] + pad[1]) + gap.x + 0.001) / (cell.x + gap.x)))
			min_rows = ceili(kids.size() / float(cols))
		var v: float = padding + (cell.y + gap.y) * min_rows - gap.y
		return [v, v, -1.0]
	var vertical: bool = kind == "vertical"
	var other: bool = vertical != (axis == 1)
	var control: bool = _flag(cfg, "control", axis)
	var use_scale: bool = _flag(cfg, "scale", axis)
	var expand: bool = _flag(cfg, "expand", axis)
	var spacing: float = float(cfg.get("spacing", 0.0))
	var total_min: float = padding
	var total_pref: float = padding
	var total_flex: float = 0.0
	for c in kids:
		var s: Array = _child_sizes(c, axis, control, expand)
		if use_scale:
			var sf: float = (RT.values(c)["scale"] as Vector3)[axis]
			s = [s[0] * sf, s[1] * sf, s[2] * sf]
		if other:
			total_min = maxf(s[0] + padding, total_min)
			total_pref = maxf(s[1] + padding, total_pref)
			total_flex = maxf(s[2], total_flex)
		else:
			total_min += s[0] + spacing
			total_pref += s[1] + spacing
			total_flex += s[2]
	if not other and kids.size() > 0:
		total_min -= spacing
		total_pref -= spacing
	total_pref = maxf(total_min, total_pref)
	return [total_min, total_pref, total_flex]


# --- placing (ILayoutController) -----------------------------------------------------------------

## LayoutGroup.SetChildAlongAxisWithScale: anchors to the top-left, the anchored position from the
## inset; `size` < 0 keeps the size delta.
func _set_child(c: Node, axis: int, pos: float, size: float, scale: float) -> void:
	var v: Dictionary = RT.values(c)
	var sd: Vector2 = v["size_delta"]
	var ap: Vector2 = v["anchored_position"]
	var pv: Vector2 = v["pivot"]
	if size >= 0.0:
		sd[axis] = size
	if axis == 0:
		ap.x = pos + sd.x * pv.x * scale
	else:
		ap.y = -pos - sd.y * (1.0 - pv.y) * scale
	var up := Vector2(0.0, 1.0)
	if v["anchor_min"] == up and v["anchor_max"] == up and (v["size_delta"] as Vector2).is_equal_approx(sd) and (v["anchored_position"] as Vector2).is_equal_approx(ap):
		return
	_changed = true
	RT.set_values(c, {"anchor_min": up, "anchor_max": up, "size_delta": sd, "anchored_position": ap})


func _set_size(c: Node, axis: int, size: float) -> void:
	if is_equal_approx(RT.rect_size(c)[axis], size):
		return
	_changed = true
	RT.set_size_with_current_anchors(c, axis, size)


## LayoutGroup.GetStartOffset
func _start_offset(host: Control, cfg: Dictionary, axis: int, required_without_padding: float) -> float:
	var pad: Array = _pad(cfg)
	var required: float = required_without_padding + ((pad[0] + pad[1]) if axis == 0 else (pad[2] + pad[3]))
	return (pad[0] if axis == 0 else pad[2]) + (RT.rect_size(host)[axis] - required) * _align(cfg, axis)


static func _align(cfg: Dictionary, axis: int) -> float:
	var a: int = int(cfg.get("align", 0))
	return (a % 3) * 0.5 if axis == 0 else (a / 3) * 0.5


## HorizontalOrVerticalLayoutGroup.SetChildrenAlongAxis
func _linear(host: Control, cfg: Dictionary, axis: int) -> void:
	var vertical: bool = str(cfg.get("type", "")) == "vertical"
	var other: bool = vertical != (axis == 1)
	var pad: Array = _pad(cfg)
	var pad_total: float = (pad[0] + pad[1]) if axis == 0 else (pad[2] + pad[3])
	var control: bool = _flag(cfg, "control", axis)
	var use_scale: bool = _flag(cfg, "scale", axis)
	var expand: bool = _flag(cfg, "expand", axis)
	var spacing: float = float(cfg.get("spacing", 0.0))
	var align: float = _align(cfg, axis)
	var size: float = RT.rect_size(host)[axis]
	var kids: Array = _rect_children(host)
	if bool(cfg.get("reverse", false)):
		kids.reverse()
	if other:
		var inner: float = size - pad_total
		for c in kids:
			var s: Array = _child_sizes(c, axis, control, expand)
			var sf: float = (RT.values(c)["scale"] as Vector3)[axis] if use_scale else 1.0
			var hi: float = size if s[2] > 0.0 else s[1]
			var required: float = clampf(inner, s[0], hi) if hi >= s[0] else hi
			var start: float = _start_offset(host, cfg, axis, required * sf)
			if control:
				_set_child(c, axis, start, required, sf)
			else:
				var own: float = (RT.values(c)["size_delta"] as Vector2)[axis]
				_set_child(c, axis, start + (required - own) * align, -1.0, sf)
		return
	var total: Array = _group_ask(host, cfg, axis)
	var pos: float = pad[0] if axis == 0 else pad[2]
	var flex_mult: float = 0.0
	var surplus: float = size - total[1]
	if surplus > 0.0:
		if total[2] == 0.0:
			pos = _start_offset(host, cfg, axis, total[1] - pad_total)
		elif total[2] > 0.0:
			flex_mult = surplus / total[2]
	var lerp: float = 0.0
	if total[0] != total[1]:
		lerp = clampf((size - total[0]) / (total[1] - total[0]), 0.0, 1.0)
	for c in kids:
		var s: Array = _child_sizes(c, axis, control, expand)
		var sf: float = (RT.values(c)["scale"] as Vector3)[axis] if use_scale else 1.0
		var child_size: float = lerpf(s[0], s[1], lerp) + s[2] * flex_mult
		if control:
			_set_child(c, axis, pos, child_size, sf)
		else:
			var own: float = (RT.values(c)["size_delta"] as Vector2)[axis]
			_set_child(c, axis, pos + (child_size - own) * align, -1.0, sf)
		pos += child_size * sf + spacing


## GridLayoutGroup.SetCellsAlongAxis
func _grid(host: Control, cfg: Dictionary, axis: int) -> void:
	var kids: Array = _rect_children(host)
	var pad: Array = _pad(cfg)
	var cell: Vector2 = cfg.get("cell", Vector2(100, 100))
	var gap: Vector2 = cfg.get("spacing2", Vector2.ZERO)
	if axis == 0:
		# the horizontal pass only sizes the cells
		var up := Vector2(0.0, 1.0)
		for c in kids:
			var v: Dictionary = RT.values(c)
			if v["anchor_min"] == up and v["anchor_max"] == up and (v["size_delta"] as Vector2).is_equal_approx(cell):
				continue
			_changed = true
			RT.set_values(c, {"anchor_min": up, "anchor_max": up, "size_delta": cell})
		return
	var size: Vector2 = RT.rect_size(host)
	var constraint: int = int(cfg.get("constraint", 0))
	var count: int = maxi(int(cfg.get("count", 2)), 1)
	var n: int = kids.size()
	var cols: int = 1
	var rows: int = 1
	if constraint == 1:
		cols = count
		if n > cols:
			rows = n / cols + (1 if n % cols > 0 else 0)
	elif constraint == 2:
		rows = count
		if n > rows:
			cols = n / rows + (1 if n % rows > 0 else 0)
	else:
		cols = 0x7FFFFFFF if cell.x + gap.x <= 0.0 else maxi(1, floori((size.x - pad[0] - pad[1] + gap.x + 0.001) / (cell.x + gap.x)))
		rows = 0x7FFFFFFF if cell.y + gap.y <= 0.0 else maxi(1, floori((size.y - pad[2] - pad[3] + gap.y + 0.001) / (cell.y + gap.y)))
	var corner: int = int(cfg.get("corner", 0))
	var horizontal: bool = int(cfg.get("axis", 0)) == 0
	var per_main: int
	var actual_x: int
	var actual_y: int
	if horizontal:
		per_main = cols
		actual_x = clampi(cols, 1, maxi(n, 1))
		actual_y = clampi(rows, 1, maxi(ceili(n / float(per_main)), 1))
	else:
		per_main = rows
		actual_y = clampi(rows, 1, maxi(n, 1))
		actual_x = clampi(cols, 1, maxi(ceili(n / float(per_main)), 1))
	var required := Vector2(actual_x * cell.x + (actual_x - 1) * gap.x, actual_y * cell.y + (actual_y - 1) * gap.y)
	var start := Vector2(_start_offset(host, cfg, 0, required.x), _start_offset(host, cfg, 1, required.y))
	for i in range(n):
		var px: int = i % per_main if horizontal else i / per_main
		var py: int = i / per_main if horizontal else i % per_main
		if corner % 2 == 1:
			px = actual_x - 1 - px
		if corner / 2 == 1:
			py = actual_y - 1 - py
		_set_child(kids[i], 0, start.x + (cell.x + gap.x) * px, cell.x, 1.0)
		_set_child(kids[i], 1, start.y + (cell.y + gap.y) * py, cell.y, 1.0)


## AspectRatioFitter.UpdateRect
func _aspect(ctl: Control) -> void:
	var a: Dictionary = ctl.get_meta("unidot_aspect")
	var mode: int = int(a.get("mode", 0))
	var ratio: float = clampf(float(a.get("ratio", 1.0)), 0.001, 1000.0)
	var size: Vector2 = RT.rect_size(ctl)
	match mode:
		1:
			_set_size(ctl, 1, size.x / ratio)
		2:
			_set_size(ctl, 0, size.y * ratio)
		3, 4:
			var p: Node = RT.logical_parent(ctl)
			var ps: Vector2 = RT.rect_size(p) if RT.is_ui(p) else Vector2.ZERO
			var sd := Vector2.ZERO
			if (ps.y * ratio < ps.x) != (mode == 3):
				sd.y = ps.x / ratio - ps.y
			else:
				sd.x = ps.y * ratio - ps.x
			var v: Dictionary = RT.values(ctl)
			if v["anchor_min"] == Vector2.ZERO and v["anchor_max"] == Vector2.ONE and (v["anchored_position"] as Vector2).is_zero_approx() and (v["size_delta"] as Vector2).is_equal_approx(sd):
				return
			_changed = true
			RT.set_values(ctl, {"anchor_min": Vector2.ZERO, "anchor_max": Vector2.ONE, "anchored_position": Vector2.ZERO, "size_delta": sd})


## LayoutRebuilder.PerformLayoutControl for one axis: the object's own fitters, then its group,
## then its children that have layout components of their own.
func _control(ctl: Control, axis: int, shown: bool) -> void:
	if not shown:
		return
	var f: Dictionary = _component(ctl, &"unidot_fitter")
	if not f.is_empty():
		var mode: int = int(f.get("h" if axis == 0 else "v", 0))
		if mode != 0:
			var want: Array = _ask(ctl, axis)
			_set_size(ctl, axis, want[0] if mode == 1 else want[1])
	if axis == 1 and not _component(ctl, &"unidot_aspect").is_empty():
		_aspect(ctl)
	var cfg: Dictionary = _group(ctl)
	match str(cfg.get("type", "")):
		"horizontal", "vertical":
			_linear(ctl, cfg, axis)
		"grid":
			_grid(ctl, cfg, axis)
	for c in RT.logical_children(ctl):
		var child: Control = RT.child_host(RT.store(c)) as Control
		if child != null and helper_of(child) != null:
			_control(child, axis, child.visible)


## Size this group asks for (LayoutGroup.preferredWidth / preferredHeight), padding included.
func preferred_size() -> Vector2:
	_inputs.clear()
	return Vector2(_ask(_host, 0)[1], _ask(_host, 1)[1])


func minimum_size() -> Vector2:
	_inputs.clear()
	return Vector2(_ask(_host, 0)[0], _ask(_host, 1)[0])


func flexible_size() -> Vector2:
	_inputs.clear()
	return Vector2(_ask(_host, 0)[2], _ask(_host, 1)[2])
