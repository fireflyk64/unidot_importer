# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
extends Node
## Unity's ScrollRect for the Control this node is a child of (helper child "UnidotScroll",
## added by ui_integration.gd). As in Unity the objects stay what they are: scrolling moves the
## content by its anchored position inside the viewport object (whose Mask clips it), and the
## Scrollbar objects are told their size and value.
##
## The parent's `unidot_scroll` metadata holds the component:
##   {content, viewport, hbar, vbar: NodePath, horizontal, vertical: bool,
##    movement (0 unrestricted, 1 elastic, 2 clamped), elasticity, inertia: bool,
##    deceleration (decelerationRate), sensitivity,
##    visibility: [horizontal, vertical] (0 permanent, 1 auto hide, 2 auto hide and expand the
##    viewport), spacing: [horizontal, vertical], enabled: bool}
## What happens every frame is ScrollRect.LateUpdate with its layout pass:
##   * a viewport that makes room for auto-hiding scrollbars is sized (SetLayoutHorizontal /
##     UpdateScrollbarLayout);
##   * the content moves on by its velocity, which decays (inertia); content that lies outside
##     the view is brought back: at once when the movement is clamped, by a spring when it is
##     elastic (`move`). The first frame finds the content at rest: what the scene shows at
##     its start is what `update` leaves, the static form of all this;
##   * the scrollbars get size (view / content) and value (the normalized position) and are
##     shown or hidden; their handles follow (Selectable.scrollbar_visuals). A Scrollbar with
##     steps takes the nearest step and the content is put there (Scrollbar.Set raises its
##     onValueChanged, to which the ScrollRect listens);
##   * `scrolled(normalized: Vector2)` of this node is raised when the position changed
##     (ScrollRect.onValueChanged; (0, 0) is the lower left corner).
## The pointer scrolls with the wheel and by dragging the view; a drag leaves its velocity
## behind (`velocity`, in units of the content's anchored position per second, y up).

const RT := preload("./rect_transform.gd")
const Selectable := preload("./selectable.gd")
const META := &"unidot_scroll"
const HELPER := "UnidotScroll"

signal scrolled(normalized: Vector2)

## ScrollRect.velocity
var velocity: Vector2 = Vector2.ZERO

var _host: Control = null
var _scrolling: bool = false     # the wheel moved the content since the last frame
var _last_position: Vector2 = Vector2.ZERO
var _dragging: bool = false
var _drag_from: Vector2 = Vector2.ZERO
var _drag_content: Vector2 = Vector2.ZERO
var _prev: Array = []
var _from_bar: bool = false


func _ready() -> void:
	_host = get_parent() as Control
	if _host == null:
		set_process(false)
		return
	_host.gui_input.connect(_on_input)
	for axis in range(2):
		var bar: Range = part(_host, "hbar" if axis == 0 else "vbar") as Range
		if bar != null:
			bar.value_changed.connect(_on_bar.bind(axis))


static func config(host: Node) -> Dictionary:
	if host != null and host.has_meta(META):
		return host.get_meta(META)
	return {}


static func part(host: Node, key: String) -> Node:
	var p = config(host).get(key)
	if p is NodePath and not (p as NodePath).is_empty():
		return host.get_node_or_null(p)
	return null


static func content_of(host: Node) -> Control:
	return part(host, "content") as Control


static func view_of(host: Node) -> Control:
	var v: Control = part(host, "viewport") as Control
	return v if v != null else host as Control


## Content coordinates → view coordinates (both Godot's: origin top-left, y down).
static func _to_view(view: Control, content: Control) -> Transform2D:
	var xf := Transform2D.IDENTITY
	var cur: Node = content
	while cur != null and cur != view:
		if not (cur is Control):
			cur = null
			break
		xf = RT.control_transform(cur) * xf
		cur = cur.get_parent()
	if cur == view:
		return xf
	if view.is_inside_tree() and content.is_inside_tree():
		return view.get_global_transform().affine_inverse() * content.get_global_transform()
	return Transform2D.IDENTITY


## [view min, view max, content min, content max] as ScrollRect.UpdateBounds computes them: in
## the view's space with y up (origin at the view's top-left corner), the content bounds
## padded to the view's size on the side its pivot leaves free.
static func bounds(host: Node) -> Array:
	var view: Control = view_of(host)
	var content: Control = content_of(host)
	var vs: Vector2 = RT.rect_size(view)
	var vmin := Vector2(0.0, -vs.y)
	var vmax := Vector2(vs.x, 0.0)
	if content == null:
		return [vmin, vmax, vmin, vmax]
	var xf: Transform2D = _to_view(view, content)
	var cs: Vector2 = RT.rect_size(content)
	var cmin := Vector2(INF, INF)
	var cmax := Vector2(-INF, -INF)
	for corner in [Vector2.ZERO, Vector2(cs.x, 0.0), cs, Vector2(0.0, cs.y)]:
		var p: Vector2 = xf * corner
		p.y = -p.y
		cmin = Vector2(minf(cmin.x, p.x), minf(cmin.y, p.y))
		cmax = Vector2(maxf(cmax.x, p.x), maxf(cmax.y, p.y))
	var pivot: Vector2 = RT.pivot(content)
	for axis in range(2):
		var excess: float = (vmax[axis] - vmin[axis]) - (cmax[axis] - cmin[axis])
		if excess > 0.0:
			var centre: float = (cmin[axis] + cmax[axis]) * 0.5 - excess * (pivot[axis] - 0.5)
			var half: float = (vmax[axis] - vmin[axis]) * 0.5
			cmin[axis] = centre - half
			cmax[axis] = centre + half
	return [vmin, vmax, cmin, cmax]


## ScrollRect.normalizedPosition: (0, 0) is the lower left corner.
static func normalized(host: Node) -> Vector2:
	var b: Array = bounds(host)
	var out := Vector2.ZERO
	for axis in range(2):
		var csize: float = b[3][axis] - b[2][axis]
		var vsize: float = b[1][axis] - b[0][axis]
		if csize <= vsize or is_equal_approx(csize, vsize):
			out[axis] = 1.0 if b[0][axis] > b[2][axis] else 0.0
		else:
			out[axis] = (b[0][axis] - b[2][axis]) / (csize - vsize)
	return out


## ScrollRect.SetNormalizedPosition
static func set_normalized(host: Node, value: float, axis: int) -> void:
	var content: Control = content_of(host)
	if content == null:
		return
	var b: Array = bounds(host)
	var hidden: float = (b[3][axis] - b[2][axis]) - (b[1][axis] - b[0][axis])
	var want_min: float = b[0][axis] - value * hidden
	var pos: Vector2 = RT.anchored_position(content)
	var moved: float = pos[axis] + _content_units(host, want_min - b[2][axis], axis)
	if absf(pos[axis] - moved) > 0.01:
		pos[axis] = moved
		RT.set_anchored_position(content, pos)


## A length of the view's space in units of the content's anchored position (the two differ
## when something between view and content is scaled).
static func _content_units(host: Node, length: float, axis: int) -> float:
	var content: Control = content_of(host)
	var view: Control = view_of(host)
	var p: Node = content.get_parent()
	if p == view or not (p is Control):
		return length
	var xf: Transform2D = _to_view(view, p)
	var scale: float = xf.x.length() if axis == 0 else xf.y.length()
	return length / scale if scale > 1e-9 else length


## How far the content bounds are outside the view (ScrollRect.CalculateOffset): what has to
## be added to the content's position to bring it back.
static func offset(host: Node, b: Array = []) -> Vector2:
	var cfg: Dictionary = config(host)
	var out := Vector2.ZERO
	if int(cfg.get("movement", 1)) == 0:
		return out
	if b.is_empty():
		b = bounds(host)
	if bool(cfg.get("horizontal", true)):
		if b[0].x - b[2].x < -0.001:
			out.x = b[0].x - b[2].x
		elif b[1].x - b[3].x > 0.001:
			out.x = b[1].x - b[3].x
	if bool(cfg.get("vertical", true)):
		if b[1].y - b[3].y > 0.001:
			out.y = b[1].y - b[3].y
		elif b[0].y - b[2].y < -0.001:
			out.y = b[0].y - b[2].y
	return out


## Move the content by `delta` (view units, y up), kept inside the view unless the movement is
## unrestricted. `wheel`: as ScrollRect.OnScroll does it, which lets an elastic rect overshoot
## (the spring brings the content back).
static func scroll_by(host: Node, delta: Vector2, wheel: bool = false) -> void:
	var content: Control = content_of(host)
	if content == null:
		return
	var cfg: Dictionary = config(host)
	if not bool(cfg.get("horizontal", true)):
		delta.x = 0.0
	if not bool(cfg.get("vertical", true)):
		delta.y = 0.0
	if not (wheel and int(cfg.get("movement", 1)) == 1):
		var b: Array = bounds(host)
		b[2] += delta
		b[3] += delta
		delta += offset(host, b)
	if delta.is_zero_approx():
		return
	RT.set_anchored_position(content, RT.anchored_position(content) + Vector2(_content_units(host, delta.x, 0), _content_units(host, delta.y, 1)))


## Mathf.SmoothDamp without a speed limit → [position, speed].
static func smooth_damp(current: float, target: float, speed: float, smooth_time: float, delta: float) -> Array:
	smooth_time = maxf(0.0001, smooth_time)
	var omega: float = 2.0 / smooth_time
	var x: float = omega * delta
	var decay: float = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change: float = current - target
	var temp: float = (speed + omega * change) * delta
	speed = (speed - omega * temp) * decay
	var output: float = target + (change + temp) * decay
	if (target - current > 0.0) == (output > target):
		# (past the target: stop there)
		output = target
		speed = 0.0
	return [output, speed]


## ScrollRect.RubberDelta: how far content dragged `over` beyond the view's edge still is from
## where the pointer would have it.
static func rubber(over: float, view_size: float) -> float:
	if view_size <= 0.0:
		return 0.0
	return (1.0 - (1.0 / ((absf(over) * 0.55 / view_size) + 1.0))) * view_size * signf(over)


## ScrollRect.OnDrag: the content at the anchored position `want`, the pointer's. Beyond the
## view's edge a clamped rect stops and an elastic one stretches like a rubber band.
static func drag_to(host: Node, want: Vector2) -> void:
	var content: Control = content_of(host)
	if content == null:
		return
	var cfg: Dictionary = config(host)
	var now: Vector2 = RT.anchored_position(content)
	if not bool(cfg.get("horizontal", true)):
		want.x = now.x
	if not bool(cfg.get("vertical", true)):
		want.y = now.y
	var units := Vector2(_content_units(host, 1.0, 0), _content_units(host, 1.0, 1))   # content units per view unit
	var b: Array = bounds(host)
	var shift: Vector2 = (want - now) / units
	b[2] += shift
	b[3] += shift
	var off: Vector2 = offset(host, b)
	want += off * units
	if int(cfg.get("movement", 1)) == 1:
		for axis in range(2):
			if off[axis] != 0.0:
				want[axis] -= rubber(off[axis], b[1][axis] - b[0][axis]) * units[axis]
	if not want.is_equal_approx(now):
		RT.set_anchored_position(content, want)


## The movement of ScrollRect.LateUpdate while nothing drags: `velocity` (units of the
## content's anchored position per second) decays and moves the content; content outside the
## view springs back (elastic) or is put back (clamped). → the velocity after `delta` seconds.
## `scrolling`: the wheel moved the content this frame (the spring is three times slower).
static func move(host: Node, velocity: Vector2, delta: float, scrolling: bool = false) -> Vector2:
	var content: Control = content_of(host)
	if content == null:
		return Vector2.ZERO
	var cfg: Dictionary = config(host)
	var movement: int = int(cfg.get("movement", 1))
	var off: Vector2 = offset(host)
	if off == Vector2.ZERO and velocity == Vector2.ZERO:
		return velocity
	var units := Vector2(_content_units(host, 1.0, 0), _content_units(host, 1.0, 1))
	var start: Vector2 = RT.anchored_position(content)
	var pos: Vector2 = start
	for axis in range(2):
		if movement == 1 and off[axis] != 0.0:
			var smooth: float = float(cfg.get("elasticity", 0.1)) * (3.0 if scrolling else 1.0)
			var damped: Array = smooth_damp(pos[axis], pos[axis] + off[axis] * units[axis], velocity[axis], smooth, delta)
			pos[axis] = damped[0]
			velocity[axis] = 0.0 if absf(damped[1]) < 1.0 else float(damped[1])
		elif bool(cfg.get("inertia", true)):
			velocity[axis] *= pow(float(cfg.get("deceleration", 0.135)), delta)
			if absf(velocity[axis]) < 1.0:
				velocity[axis] = 0.0
			pos[axis] += velocity[axis] * delta
		else:
			velocity[axis] = 0.0
	if not bool(cfg.get("horizontal", true)):
		pos.x = start.x
	if not bool(cfg.get("vertical", true)):
		pos.y = start.y
	if movement == 2:
		var b: Array = bounds(host)
		var shift: Vector2 = (pos - start) / units
		b[2] += shift
		b[3] += shift
		pos += offset(host, b) * units
	if pos != start:
		RT.set_anchored_position(content, pos)
	return velocity


## Is the content larger than the view on an axis (ScrollRect.hScrollingNeeded / vScrollingNeeded)?
static func scrolling_needed(host: Node, axis: int) -> bool:
	var b: Array = bounds(host)
	return (b[3][axis] - b[2][axis]) > (b[1][axis] - b[0][axis]) + 0.01


## The layout part of ScrollRect: a viewport that gives way to auto-hiding scrollbars
## (visibility 2) and scrollbars that leave the corner free when both are shown.
static func layout(host: Node) -> void:
	var cfg: Dictionary = config(host)
	var view: Control = part(host, "viewport") as Control
	var content: Control = content_of(host)
	var bars: Array = [part(host, "hbar") as Control, part(host, "vbar") as Control]
	var visibility: Array = cfg.get("visibility", [0, 0])
	var spacing: Array = cfg.get("spacing", [0.0, 0.0])
	if view == null or content == null or view.get_parent() != host:
		return
	for bar in bars:
		if bar != null and bar.get_parent() != host:
			return
	var expand: Array = [bars[0] != null and int(visibility[0]) == 2, bars[1] != null and int(visibility[1]) == 2]
	if not expand[0] and not expand[1]:
		return
	var thickness: Array = [RT.rect_size(bars[0]).y if bars[0] != null else 0.0, RT.rect_size(bars[1]).x if bars[1] != null else 0.0]
	# the content's size in the view at any view size: content that is stretched with the view
	# keeps its excess, other content keeps its size
	var full: Vector2 = RT.rect_size(host)
	var now: Vector2 = RT.rect_size(view)
	var xf: Transform2D = _to_view(view, content)
	var cs: Vector2 = RT.rect_size(content) * Vector2(xf.x.length(), xf.y.length())
	var stretched := Vector2(RT.anchor_max(content).x - RT.anchor_min(content).x, RT.anchor_max(content).y - RT.anchor_min(content).y)
	var needed := func(axis: int, view_size: float) -> bool:
		var c: float = cs[axis] + (view_size - now[axis]) * stretched[axis]
		return c > view_size + 0.01
	var sd := Vector2.ZERO
	if expand[1] and needed.call(1, full.y):
		sd.x = -(thickness[1] + float(spacing[1]))
	if expand[0] and needed.call(0, full.x + sd.x):
		sd.y = -(thickness[0] + float(spacing[0]))
	if expand[1] and needed.call(1, full.y + sd.y) and sd.x == 0.0 and sd.y < 0.0:
		sd.x = -(thickness[1] + float(spacing[1]))
	_drive(view, {"anchor_min": Vector2.ZERO, "anchor_max": Vector2.ONE, "anchored_position": Vector2.ZERO, "size_delta": sd})
	if expand[1] and bars[0] != null:
		var hv: Dictionary = RT.values(bars[0])
		_drive(bars[0], {"anchor_min": Vector2(0.0, hv["anchor_min"].y), "anchor_max": Vector2(1.0, hv["anchor_max"].y), "anchored_position": Vector2(0.0, hv["anchored_position"].y),
			"size_delta": Vector2(-(thickness[1] + float(spacing[1])) if needed.call(1, full.y + sd.y) else 0.0, hv["size_delta"].y)})
	if expand[0] and bars[1] != null:
		var vv: Dictionary = RT.values(bars[1])
		_drive(bars[1], {"anchor_min": Vector2(vv["anchor_min"].x, 0.0), "anchor_max": Vector2(vv["anchor_max"].x, 1.0), "anchored_position": Vector2(vv["anchored_position"].x, 0.0),
			"size_delta": Vector2(vv["size_delta"].x, -(thickness[0] + float(spacing[0])) if needed.call(0, full.x + sd.x) else 0.0)})


static func _drive(c: Control, want: Dictionary) -> void:
	var v: Dictionary = RT.values(c)
	for key in want:
		if not (v[key] as Vector2).is_equal_approx(want[key]):
			RT.set_values(c, want)
			return


## ScrollRect.LateUpdate without the pointer: layout, content brought back into the view,
## scrollbars. → [view min, view max, content min, content max, content position] after it.
## `dragging`: content outside the view is left where the pointer (or the spring) has it.
static func update(host: Node, dragging: bool = false) -> Array:
	var content: Control = content_of(host)
	if content == null:
		return []
	layout(host)
	if not dragging:
		var off: Vector2 = offset(host)
		if not off.is_zero_approx():
			RT.set_anchored_position(content, RT.anchored_position(content) + Vector2(_content_units(host, off.x, 0), _content_units(host, off.y, 1)))
	return bars(host)


## A linked Scrollbar with steps (Scrollbar.numberOfSteps) only takes those values, and what it
## takes it hands back (its onValueChanged sets the normalized position): the content lies on
## a step. → the axes on which the content was moved.
static func snap_to_steps(host: Node) -> Array:
	var snapped: Array = [false, false]
	for axis in range(2):
		var bar: Range = part(host, "hbar" if axis == 0 else "vbar") as Range
		var steps: int = int((bar.get_meta(&"unidot_scrollbar") as Dictionary).get("steps", 0)) if bar != null and bar.has_meta(&"unidot_scrollbar") else 0
		if steps < 2 or not scrolling_needed(host, axis):
			continue
		var at: float = normalized(host)[axis]
		var step: float = roundf(at * float(steps - 1)) / float(steps - 1)
		if absf(step - at) > 1e-4:
			var before: Vector2 = RT.anchored_position(content_of(host))
			set_normalized(host, step, axis)
			snapped[axis] = not RT.anchored_position(content_of(host)).is_equal_approx(before)
	return snapped


## ScrollRect.UpdateScrollbars and UpdateScrollbarVisibility → [view min, view max, content min,
## content max, content position].
static func bars(host: Node) -> Array:
	var content: Control = content_of(host)
	var cfg: Dictionary = config(host)
	snap_to_steps(host)
	var b: Array = bounds(host)
	var off: Vector2 = offset(host, b)
	var visibility: Array = cfg.get("visibility", [0, 0])
	var norm: Vector2 = normalized(host)
	for axis in range(2):
		var bar: Range = part(host, "hbar" if axis == 0 else "vbar") as Range
		if bar == null:
			continue
		var csize: float = b[3][axis] - b[2][axis]
		var vsize: float = b[1][axis] - b[0][axis]
		# (content stretched beyond the view's edge shrinks the handle)
		var size: float = clampf((vsize - absf(off[axis])) / csize, 0.0, 1.0) if csize > 0.0 else 1.0
		var sb: Dictionary = bar.get_meta(&"unidot_scrollbar") if bar.has_meta(&"unidot_scrollbar") else {}
		if not is_equal_approx(float(sb.get("size", -1.0)), size):
			sb = sb.duplicate()
			sb["size"] = size
			bar.set_meta(&"unidot_scrollbar", sb)
		if not is_equal_approx(bar.value, norm[axis]):
			bar.set_value_no_signal(norm[axis])
		Selectable.scrollbar_visuals(bar)
		# permanent: shown while the axis scrolls at all; otherwise while there is something to scroll
		var axis_on: bool = bool(cfg.get("horizontal" if axis == 0 else "vertical", true))
		var show: bool = axis_on if int(visibility[axis]) == 0 else csize > vsize + 0.01
		if bar.visible != show:
			bar.visible = show
	return [b[0], b[1], b[2], b[3], RT.anchored_position(content)]


## ScrollRect.StopMovement
func stop_movement() -> void:
	velocity = Vector2.ZERO


func _process(delta: float) -> void:
	if _host == null or not _host.is_visible_in_tree() or not bool(config(_host).get("enabled", true)):
		return
	var content: Control = content_of(_host)
	if content == null:
		return
	var state: Array
	if _prev.is_empty():
		# the first frame: the content at rest
		state = update(_host)
	else:
		layout(_host)
		if not _dragging:
			velocity = move(_host, velocity, delta, _scrolling)
		elif bool(config(_host).get("inertia", true)) and delta > 0.0:
			velocity = velocity.lerp((RT.anchored_position(content) - _last_position) / delta, minf(delta * 10.0, 1.0))
		var snapped: Array = snap_to_steps(_host)
		for axis in range(2):
			if snapped[axis]:
				velocity[axis] = 0.0
		state = bars(_host)
	_scrolling = false
	_last_position = RT.anchored_position(content)
	if _prev.is_empty():
		_prev = state
		return
	for i in range(state.size()):
		if not (state[i] as Vector2).is_equal_approx(_prev[i]):
			_prev = state
			scrolled.emit(normalized(_host))
			return


## A linked Scrollbar moved (by the pointer or by a script): its value is the normalized position.
func _on_bar(value: float, axis: int) -> void:
	set_normalized(_host, value, axis)


func _on_input(event: InputEvent) -> void:
	var cfg: Dictionary = config(_host)
	if not bool(cfg.get("enabled", true)):
		return
	if event is InputEventMouseButton:
		var notch := Vector2.ZERO
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				notch.y = 1.0
			MOUSE_BUTTON_WHEEL_DOWN:
				notch.y = -1.0
			MOUSE_BUTTON_WHEEL_LEFT:
				notch.x = -1.0
			MOUSE_BUTTON_WHEEL_RIGHT:
				notch.x = 1.0
			MOUSE_BUTTON_LEFT:
				_dragging = event.pressed and content_of(_host) != null
				if _dragging:
					# (OnInitializePotentialDrag: a press stops what was moving)
					velocity = Vector2.ZERO
					_drag_from = event.position
					_drag_content = RT.anchored_position(content_of(_host))
					_last_position = _drag_content
				return
		if notch != Vector2.ZERO and event.pressed:
			# ScrollRect.OnScroll: the wheel moves the content against its direction; a wheel
			# that has one axis scrolls a rect that has only the other
			var delta := Vector2(notch.x, -notch.y) * maxf(event.factor, 1.0)
			var horizontal: bool = bool(cfg.get("horizontal", true))
			var vertical: bool = bool(cfg.get("vertical", true))
			if vertical and not horizontal:
				if absf(delta.x) > absf(delta.y):
					delta.y = delta.x
				delta.x = 0.0
			if horizontal and not vertical:
				if absf(delta.y) > absf(delta.x):
					delta.x = delta.y
				delta.y = 0.0
			scroll_by(_host, delta * float(cfg.get("sensitivity", 1.0)), true)
			_scrolling = true
			_host.accept_event()
	elif event is InputEventMouseMotion and _dragging:
		if (event.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			_dragging = false
			return
		var view: Control = view_of(_host)
		# the pointer's way in the host, in view units (y up)
		var moved: Vector2 = event.position - _drag_from
		var to_view: Transform2D = _to_view(_host, view) if view != _host else Transform2D.IDENTITY
		var sx: float = to_view.x.length()
		var sy: float = to_view.y.length()
		drag_to(_host, _drag_content + Vector2(_content_units(_host, moved.x / (sx if sx > 1e-9 else 1.0), 0), _content_units(_host, -moved.y / (sy if sy > 1e-9 else 1.0), 1)))
