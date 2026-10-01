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
##            method (0 horizontal, 1 vertical, 2-4 radial), origin, amount, clockwise (filled)}
## Sliced: nine patches as Unity builds them (Image.GenerateSlicedSprite): the borders keep
## their size, `unit` per sprite pixel, and shrink together on an axis where the rect is
## smaller than both of them. The colour comes from the parent's graphic state as this
## node's self-modulate.

const HELPER := "UnidotSprite"
const META_GRAPHIC := &"unidot_graphic"

const SLICED := 1
const TILED := 2
const FILLED := 3


## Canvas units per sprite pixel of the borders on each axis (Image.GetAdjustedBorders).
static func slice_scale(size: Vector2, border: Array, unit: float) -> Vector2:
	var out := Vector2(unit, unit)
	for axis in range(2):
		var combined: float = (float(border[axis]) + float(border[axis + 2])) * unit
		if combined > 0.0 and size[axis] < combined:
			out[axis] = unit * size[axis] / combined
	return out


## The sprite pixel that a sliced image shows at `p` (rect coordinates, origin top-left).
static func slice_texel(p: Vector2, size: Vector2, sprite_size: Vector2, border: Array, unit: float) -> Vector2:
	var sc: Vector2 = slice_scale(size, border, unit)
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


func _ready() -> void:
	resized.connect(queue_redraw)


func _draw() -> void:
	var host: Control = get_parent() as Control
	if host == null or not host.has_meta(META_GRAPHIC) or size.x <= 0.0 or size.y <= 0.0:
		return
	var state: Dictionary = host.get_meta(META_GRAPHIC)
	var tex: Texture2D = state.get("texture") as Texture2D
	if tex == null and host is TextureRect:
		tex = host.texture
	var sprite: Dictionary = state.get("sprite", {})
	if sprite.is_empty():
		return
	if tex == null:
		# an Image without a sprite is a rectangle in its colour (on a widget that cannot draw it)
		draw_rect(Rect2(Vector2.ZERO, size), Color.WHITE)
		return
	var src: Array = source(tex)
	var region: Rect2 = src[1]
	match int(sprite.get("type", 0)):
		SLICED:
			var border: Array = sprite.get("border", [0, 0, 0, 0])
			var sc: Vector2 = slice_scale(size, border, float(sprite.get("unit", 1.0)))
			if sc.x <= 0.0 or sc.y <= 0.0:
				return
			draw_set_transform(Vector2.ZERO, 0.0, sc)
			RenderingServer.canvas_item_add_nine_patch(get_canvas_item(), Rect2(Vector2.ZERO, size / sc), region, (src[0] as Texture2D).get_rid(),
				Vector2(float(border[0]), float(border[1])), Vector2(float(border[2]), float(border[3])),
				RenderingServer.NINE_PATCH_STRETCH, RenderingServer.NINE_PATCH_STRETCH, bool(sprite.get("center", true)))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		FILLED:
			var method: int = int(sprite.get("method", 4))
			if method > 1:
				# radial fills are drawn whole
				draw_texture_rect_region(src[0], Rect2(Vector2.ZERO, size), region)
				return
			var rects: Array = fill_rects(size, region.size, method, int(sprite.get("origin", 0)), float(sprite.get("amount", 1.0)))
			var part: Rect2 = rects[1]
			if (rects[0] as Rect2).size.x > 0.0 and (rects[0] as Rect2).size.y > 0.0:
				draw_texture_rect_region(src[0], rects[0], Rect2(region.position + part.position, part.size))
		TILED:
			for q in tiled_quads(size, region.size, sprite.get("border", [0, 0, 0, 0]), float(sprite.get("unit", 1.0)), bool(sprite.get("center", true))):
				var part: Rect2 = q[1]
				draw_texture_rect_region(src[0], q[0], Rect2(region.position + part.position, part.size))
		_:
			draw_texture_rect_region(src[0], Rect2(Vector2.ZERO, size), region)
