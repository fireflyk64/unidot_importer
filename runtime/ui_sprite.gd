# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
@tool
extends Control
## Draws the sprite of a Unity Image that is not simply stretched over its rect: helper child
## ("UnidotSprite") of the Image's Control, drawn behind it (ui_integration.gd adds it).
##
## The parent's `unidot_graphic` metadata holds the sprite (runtime/ui_graphic.gd):
##   texture: Texture2D (an AtlasTexture for a sprite of a sheet; a TextureRect's own texture
##            otherwise),
##   sprite: {type: 0 simple (stretched) | 1 sliced | 2 tiled | 3 filled,
##            border: [left, top, right, bottom] in sprite pixels,
##            unit: canvas units per sprite pixel (canvas reference pixels per unit / sprite
##                  pixels per unit / the Image's multiplier),
##            center: bool (fill centre),
##            method (0 horizontal, 1 vertical, 2 radial 90, 3 radial 180, 4 radial 360),
##            origin, amount, clockwise (filled)}
## Sliced: nine patches as Unity builds them (Image.GenerateSlicedSprite): the borders keep
## their size, `unit` per sprite pixel, and shrink together on an axis where the rect is
## smaller than both of them. The colour comes from the parent's graphic state as this
## node's self-modulate.
##
## A rect of negative size (stretched with insets larger than its parent): Unity builds the
## Image's quad from the rect's origin by its size all the same, so the picture lies on the
## other side of the origin, mirrored on that axis. The Control has no size there (see
## rect_transform.gd): this helper is as large as the rect should be and draws mirrored about
## the Control's origin, a simple sprite too.

const RT := preload("./rect_transform.gd")
const HELPER := "UnidotSprite"
const META_GRAPHIC := &"unidot_graphic"

const SLICED := 1
const TILED := 2
const FILLED := 3


## Canvas units per sprite pixel of the borders on each axis (Image.GetAdjustedBorders).
## `mirror`: -1 on an axis where the rect's size is negative (`size` is its amount): Unity
## scales the borders by rect size / borders there as well, which is negative, so the two
## borders fill the rect between them and nothing is left for the centre.
static func slice_scale(size: Vector2, border: Array, unit: float, mirror: Vector2 = Vector2.ONE) -> Vector2:
	var out := Vector2(unit, unit)
	for axis in range(2):
		var combined: float = (float(border[axis]) + float(border[axis + 2])) * unit
		if combined > 0.0 and (size[axis] < combined or mirror[axis] < 0.0):
			out[axis] = unit * size[axis] / combined
	return out


## The sprite pixel that a sliced image shows at `p` (rect coordinates, origin top-left).
static func slice_texel(p: Vector2, size: Vector2, sprite_size: Vector2, border: Array, unit: float, mirror: Vector2 = Vector2.ONE) -> Vector2:
	var sc: Vector2 = slice_scale(size, border, unit, mirror)
	var out := Vector2.ZERO
	for axis in range(2):
		var lead: float = float(border[axis])
		var trail: float = float(border[axis + 2])
		var x: float = p[axis]
		if sc[axis] <= 0.0:
			out[axis] = 0.0
		elif x < lead * sc[axis]:
			out[axis] = x / sc[axis]
		elif x > size[axis] - trail * sc[axis]:
			out[axis] = sprite_size[axis] - (size[axis] - x) / sc[axis]
		else:
			var middle: float = size[axis] - (lead + trail) * sc[axis]
			var source: float = sprite_size[axis] - lead - trail
			out[axis] = lead + ((x - lead * sc[axis]) / middle * source if middle > 0.0 else 0.0)
	return out


## The quads of a tiled image (Image.GenerateTiledSprite): the borders stay where a sliced image
## has them; the centre is filled with copies of the sprite's centre, `unit` per pixel, laid from
## the bottom-left, the last ones cut; the edges repeat along their side.
## → [[rect in the control, rect in the sprite (pixels)], ...], both with the origin top-left.
static func tiled_quads(size: Vector2, sprite_size: Vector2, border: Array, unit: float, center: bool) -> Array:
	var out: Array = []
	var sc: Vector2 = slice_scale(size, border, unit)
	var l: float = float(border[0])
	var t: float = float(border[1])
	var r: float = float(border[2])
	var b: float = float(border[3])
	var has_border: bool = l > 0.0 or t > 0.0 or r > 0.0 or b > 0.0
	# Unity's axes: x from the left, y from the bottom
	var x_min: float = l * sc.x
	var x_max: float = size.x - r * sc.x
	var y_min: float = b * sc.y
	var y_max: float = size.y - t * sc.y
	var inner := Vector2(sprite_size.x - l - r, sprite_size.y - t - b)
	var tile := Vector2(inner.x * unit, inner.y * unit)
	if tile.x <= 0.0:
		tile.x = x_max - x_min
	if tile.y <= 0.0:
		tile.y = y_max - y_min
	if tile.x <= 0.0 or tile.y <= 0.0 or (not center and not has_border):
		return out
	var nx: int = mini(int(ceil((x_max - x_min) / tile.x - 1e-6)), 4096)
	var ny: int = mini(int(ceil((y_max - y_min) / tile.y - 1e-6)), 4096)
	# spans along each axis: [start, end, fraction of the tile that is shown]
	var xs: Array = []
	for i in range(nx):
		var x1: float = x_min + i * tile.x
		var x2: float = minf(x1 + tile.x, x_max)
		xs.append([x1, x2, (x2 - x1) / tile.x])
	var ys: Array = []
	for j in range(ny):
		var y1: float = y_min + j * tile.y
		var y2: float = minf(y1 + tile.y, y_max)
		ys.append([y1, y2, (y2 - y1) / tile.y])
	# a quad given in Unity's axes (y up, sprite rows counted from the bottom)
	var quad := func(x1: float, y1: float, x2: float, y2: float, u1: float, v1: float, u2: float, v2: float) -> void:
		if x2 - x1 <= 0.0 or y2 - y1 <= 0.0:
			return
		out.append([Rect2(x1, size.y - y2, x2 - x1, y2 - y1), Rect2(u1, sprite_size.y - v2, u2 - u1, v2 - v1)])
	if center:
		for ys_j in ys:
			for xs_i in xs:
				quad.call(xs_i[0], ys_j[0], xs_i[1], ys_j[1], l, b, l + inner.x * xs_i[2], b + inner.y * ys_j[2])
	if has_border:
		for ys_j in ys:
			quad.call(0.0, ys_j[0], x_min, ys_j[1], 0.0, b, l, b + inner.y * ys_j[2])
			quad.call(x_max, ys_j[0], size.x, ys_j[1], sprite_size.x - r, b, sprite_size.x, b + inner.y * ys_j[2])
		for xs_i in xs:
			quad.call(xs_i[0], 0.0, xs_i[1], y_min, l, 0.0, l + inner.x * xs_i[2], b)
			quad.call(xs_i[0], y_max, xs_i[1], size.y, l, sprite_size.y - t, l + inner.x * xs_i[2], sprite_size.y)
		quad.call(0.0, 0.0, x_min, y_min, 0.0, 0.0, l, b)
		quad.call(x_max, 0.0, size.x, y_min, sprite_size.x - r, 0.0, sprite_size.x, b)
		quad.call(0.0, y_max, x_min, size.y, 0.0, sprite_size.y - t, l, sprite_size.y)
		quad.call(x_max, y_max, size.x, size.y, sprite_size.x - r, sprite_size.y - t, sprite_size.x, sprite_size.y)
	return out


## The sprite pixel a tiled image shows at `p`; null where it draws nothing.
static func tiled_texel(p: Vector2, size: Vector2, sprite_size: Vector2, border: Array, unit: float, center: bool):
	for q in tiled_quads(size, sprite_size, border, unit, center):
		var dest: Rect2 = q[0]
		if dest.has_point(p):
			return (q[1] as Rect2).position + (p - dest.position) / dest.size * (q[1] as Rect2).size
	return null


## The texture and the part of it a sprite covers.
static func source(tex: Texture2D) -> Array:
	if tex is AtlasTexture and tex.atlas != null:
		return [tex.atlas, tex.region]
	return [tex, Rect2(Vector2.ZERO, tex.get_size())]


## The rect and the part of the sprite a filled image shows (horizontal and vertical fill).
## → [rect in the control, rect in the sprite (pixels, origin top-left)]
static func fill_rects(size: Vector2, sprite_size: Vector2, method: int, origin: int, amount: float) -> Array:
	var a: float = clampf(amount, 0.0, 1.0)
	var dest := Rect2(Vector2.ZERO, size)
	var src := Rect2(Vector2.ZERO, sprite_size)
	if method == 0:
		# origin 0 left, 1 right
		dest.size.x = size.x * a
		src.size.x = sprite_size.x * a
		if origin == 1:
			dest.position.x = size.x - dest.size.x
			src.position.x = sprite_size.x - src.size.x
	elif method == 1:
		# origin 0 bottom, 1 top
		dest.size.y = size.y * a
		src.size.y = sprite_size.y * a
		if origin == 0:
			dest.position.y = size.y - dest.size.y
			src.position.y = sprite_size.y - src.size.y
	return [dest, src]


## The quads of a radially filled image (Image.GenerateFilledSprite; method 2 radial 90, 3 radial
## 180, 4 radial 360), in the proportions of the rect: four points each in [0, 1] x [0, 1] with
## y up, in Unity's order (bottom-left, top-left, top-right, bottom-right; points of a cut quad
## may coincide). The same factors place a point in the rect and in the sprite.
static func radial_quads(method: int, origin: int, amount: float, clockwise: bool) -> Array:
	var out: Array = []
	if amount < 0.001:
		return out
	if amount >= 1.0 or method < 2:
		out.append([Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)])
		return out
	if method == 2:
		var whole: Array = [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]
		if _radial_cut(whole, amount, clockwise, origin):
			out.append(whole)
	elif method == 3:
		# two halves, beside each other (origin bottom / top) or above each other (left / right)
		var even: int = 1 if origin > 1 else 0
		for side in range(2):
			var lo := Vector2.ZERO
			var hi := Vector2.ONE
			if origin == 0 or origin == 2:
				if side == even:
					hi.x = 0.5
				else:
					lo.x = 0.5
			elif side == even:
				lo.y = 0.5
			else:
				hi.y = 0.5
			var half: Array = [Vector2(lo.x, lo.y), Vector2(lo.x, hi.y), Vector2(hi.x, hi.y), Vector2(hi.x, lo.y)]
			var val: float = (amount * 2.0 - side) if clockwise else (amount * 2.0 - (1 - side))
			if _radial_cut(half, clampf(val, 0.0, 1.0), clockwise, (side + origin + 3) % 4):
				out.append(half)
	else:
		# four quarters: bottom-left, top-left, top-right, bottom-right
		for corner in range(4):
			var lo := Vector2(0.0 if corner < 2 else 0.5, 0.0 if (corner == 0 or corner == 3) else 0.5)
			var hi := lo + Vector2(0.5, 0.5)
			var quarter: Array = [Vector2(lo.x, lo.y), Vector2(lo.x, hi.y), Vector2(hi.x, hi.y), Vector2(hi.x, lo.y)]
			var turn: int = (corner + origin) % 4
			var val: float = (amount * 4.0 - turn) if clockwise else (amount * 4.0 - (3 - turn))
			if _radial_cut(quarter, clampf(val, 0.0, 1.0), clockwise, (corner + 2) % 4):
				out.append(quarter)
	return out


## Image.RadialCut: the quad is cut along the ray that leaves its `corner` at `fill` of a
## quarter turn. False when nothing is left of it.
static func _radial_cut(xy: Array, fill: float, invert: bool, corner: int) -> bool:
	if fill < 0.001:
		return false
	# (every other corner turns the other way)
	if (corner & 1) == 1:
		invert = not invert
	if not invert and fill > 0.999:
		return true
	var angle: float = clampf(fill, 0.0, 1.0)
	if invert:
		angle = 1.0 - angle
	angle *= PI * 0.5
	var c: float = cos(angle)
	var s: float = sin(angle)
	var i0: int = corner
	var i1: int = (corner + 1) % 4
	var i2: int = (corner + 2) % 4
	var i3: int = (corner + 3) % 4
	var a: Vector2 = xy[i0]
	var b: Vector2 = xy[i2]
	if (corner & 1) == 1:
		if s > c:
			c /= s
			s = 1.0
			if invert:
				xy[i1] = Vector2(lerpf(a.x, b.x, c), xy[i1].y)
				xy[i2] = Vector2(xy[i1].x, xy[i2].y)
		elif c > s:
			s /= c
			c = 1.0
			if not invert:
				xy[i2] = Vector2(xy[i2].x, lerpf(a.y, b.y, s))
				xy[i3] = Vector2(xy[i3].x, xy[i2].y)
		else:
			c = 1.0
			s = 1.0
		# (Unity reads the opposite corner after it may have moved)
		if not invert:
			xy[i3] = Vector2(lerpf(a.x, xy[i2].x, c), xy[i3].y)
		else:
			xy[i1] = Vector2(xy[i1].x, lerpf(a.y, xy[i2].y, s))
	else:
		if c > s:
			s /= c
			c = 1.0
			if not invert:
				xy[i1] = Vector2(xy[i1].x, lerpf(a.y, b.y, s))
				xy[i2] = Vector2(xy[i2].x, xy[i1].y)
		elif s > c:
			c /= s
			s = 1.0
			if invert:
				xy[i2] = Vector2(lerpf(a.x, b.x, c), xy[i2].y)
				xy[i3] = Vector2(xy[i2].x, xy[i3].y)
		else:
			c = 1.0
			s = 1.0
		if invert:
			xy[i3] = Vector2(xy[i3].x, lerpf(a.y, xy[i2].y, s))
		else:
			xy[i1] = Vector2(lerpf(a.x, xy[i2].x, c), xy[i1].y)
	return true


## Whether a radially filled image covers the point `p` of its rect ([0, 1] x [0, 1], y up).
## This is what a radial fill means, not how Unity builds it: the angle swept about the origin
## (the centre for 360, the middle of an edge for 180, a corner for 90) in the proportions of
## the rect, starting where a clockwise fill starts. The tests hold the quads against it.
static func radial_covers(p: Vector2, method: int, origin: int, amount: float, clockwise: bool) -> bool:
	if amount < 0.001:
		return false
	if amount >= 1.0 or method < 2:
		return true
	var centre := Vector2(0.5, 0.5)
	var extent := Vector2(0.5, 0.5)
	var start := Vector2(0, -1)   # where a clockwise fill starts
	var total: float = TAU
	if method == 4:
		# bottom, right, top, left
		start = [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)][origin & 3]
	elif method == 3:
		# the middle of the bottom, left, top, right edge
		var inward: Vector2 = [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)][origin & 3]
		centre = Vector2(0.5, 0.5) - inward * 0.5
		extent = Vector2(1.0 if inward.x != 0.0 else 0.5, 1.0 if inward.y != 0.0 else 0.5)
		start = Vector2(-inward.y, inward.x)
		total = PI
	else:
		# the bottom-left, top-left, top-right, bottom-right corner
		centre = [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)][origin & 3]
		extent = Vector2.ONE
		var diagonal: Vector2 = (Vector2(0.5, 0.5) - centre) * 2.0
		start = Vector2(diagonal.x - diagonal.y, diagonal.x + diagonal.y) * 0.5
		total = PI * 0.5
	var d: Vector2 = (p - centre) / extent
	if d.is_zero_approx():
		return true
	var swept: float
	if clockwise:
		swept = fposmod(atan2(start.y, start.x) - atan2(d.y, d.x), TAU)
	else:
		# counter-clockwise from the other end
		swept = fposmod(atan2(d.y, d.x) - (atan2(start.y, start.x) - total), TAU)
	return swept <= amount * total


func _ready() -> void:
	resized.connect(queue_redraw)
	var host: Control = get_parent() as Control
	if host != null:
		# (the rect of the Image changes: a negative size is no size of the Control)
		if not host.resized.is_connected(fit):
			host.resized.connect(fit)
		fit()


## -1 on the axes where the Image's rect has a negative size, 1 on the others.
static func mirror_of(host: Control) -> Vector2:
	var unity: Vector2 = RT.rect_size(host)
	return Vector2(-1.0 if unity.x < 0.0 else 1.0, -1.0 if unity.y < 0.0 else 1.0)


## The helper covers the Image's rect: the Control's, or the size the rect should have when
## that is negative (drawn mirrored about the Control's origin then).
func fit() -> void:
	var host: Control = get_parent() as Control
	if host == null:
		return
	var unity: Vector2 = RT.rect_size(host)
	if unity.x < 0.0 or unity.y < 0.0:
		set_anchors_preset(Control.PRESET_TOP_LEFT)
		position = Vector2.ZERO
		size = unity.abs()
	elif anchor_right != 1.0 or anchor_bottom != 1.0:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		offset_left = 0.0
		offset_top = 0.0
		offset_right = 0.0
		offset_bottom = 0.0
	queue_redraw()


## False when there is nothing to draw at all: a filled sprite without fill amount (Unity builds
## no mesh; an Image without a sprite is drawn whole whatever its type).
func draws() -> bool:
	var host: Control = get_parent() as Control
	if host == null or not host.has_meta(META_GRAPHIC):
		return false
	var state: Dictionary = host.get_meta(META_GRAPHIC)
	var sprite: Dictionary = state.get("sprite", {})
	if sprite.is_empty():
		return mirror_of(host) != Vector2.ONE   # (a simple sprite on a rect of negative size)
	if int(sprite.get("type", 0)) == TILED and mirror_of(host) != Vector2.ONE:
		return false   # (no tiles on an axis of negative size)
	if state.get("texture") == null and not (host is TextureRect and host.texture != null):
		return true
	return not (int(sprite.get("type", 0)) == FILLED and float(sprite.get("amount", 1.0)) < 0.001)


func _draw() -> void:
	var host: Control = get_parent() as Control
	if host == null or not host.has_meta(META_GRAPHIC) or size.x <= 0.0 or size.y <= 0.0:
		return
	var state: Dictionary = host.get_meta(META_GRAPHIC)
	var tex: Texture2D = state.get("texture") as Texture2D
	if tex == null and host is TextureRect:
		tex = host.texture
	var sprite: Dictionary = state.get("sprite", {})
	var mirror: Vector2 = mirror_of(host)
	if sprite.is_empty() and mirror == Vector2.ONE:
		return
	draw_set_transform(Vector2.ZERO, 0.0, mirror)
	if tex == null:
		# an Image without a sprite is a rectangle in its colour (on a widget that cannot draw it)
		draw_rect(Rect2(Vector2.ZERO, size), Color.WHITE)
		return
	var src: Array = source(tex)
	var region: Rect2 = src[1]
	match int(sprite.get("type", 0)):
		SLICED:
			var border: Array = sprite.get("border", [0, 0, 0, 0])
			var sc: Vector2 = slice_scale(size, border, float(sprite.get("unit", 1.0)), mirror)
			if sc.x <= 0.0 or sc.y <= 0.0:
				return
			draw_set_transform(Vector2.ZERO, 0.0, sc * mirror)
			RenderingServer.canvas_item_add_nine_patch(get_canvas_item(), Rect2(Vector2.ZERO, size / sc), region, (src[0] as Texture2D).get_rid(),
				Vector2(float(border[0]), float(border[1])), Vector2(float(border[2]), float(border[3])),
				RenderingServer.NINE_PATCH_STRETCH, RenderingServer.NINE_PATCH_STRETCH, bool(sprite.get("center", true)))
			draw_set_transform(Vector2.ZERO, 0.0, mirror)
		FILLED:
			var method: int = int(sprite.get("method", 4))
			if method > 1:
				var tex_size: Vector2 = (src[0] as Texture2D).get_size()
				var white := PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE])
				for quad in radial_quads(method, int(sprite.get("origin", 0)), float(sprite.get("amount", 1.0)), bool(sprite.get("clockwise", true))):
					var points := PackedVector2Array()
					var uvs := PackedVector2Array()
					for v in quad:
						var at := Vector2(v.x, 1.0 - v.y)
						points.append(at * size)
						uvs.append((region.position + at * region.size) / tex_size)
					draw_primitive(points, white, uvs, src[0])
				return
			var rects: Array = fill_rects(size, region.size, method, int(sprite.get("origin", 0)), float(sprite.get("amount", 1.0)))
			var part: Rect2 = rects[1]
			if (rects[0] as Rect2).size.x > 0.0 and (rects[0] as Rect2).size.y > 0.0:
				draw_texture_rect_region(src[0], rects[0], Rect2(region.position + part.position, part.size))
		TILED:
			# (Unity counts the tiles of an axis from its size: none on a negative one)
			if mirror != Vector2.ONE:
				return
			for q in tiled_quads(size, region.size, sprite.get("border", [0, 0, 0, 0]), float(sprite.get("unit", 1.0)), bool(sprite.get("center", true))):
				var part: Rect2 = q[1]
				draw_texture_rect_region(src[0], q[0], Rect2(region.position + part.position, part.size))
		_:
			draw_texture_rect_region(src[0], Rect2(Vector2.ZERO, size), region)
