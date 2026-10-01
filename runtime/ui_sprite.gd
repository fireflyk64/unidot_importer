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
##   sprite: {type: 1 sliced | 2 tiled | 3 filled,
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
	if tex == null or sprite.is_empty():
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
			var unit: float = float(sprite.get("unit", 1.0))
			var tile: Vector2 = region.size * unit
			if tile.x <= 0.0 or tile.y <= 0.0:
				return
			# tiles from the bottom-left corner, as Unity lays them; the last ones are cut
			var y: float = size.y
			while y > 0.0:
				var h: float = minf(tile.y, y)
				var x: float = 0.0
				while x < size.x:
					var w: float = minf(tile.x, size.x - x)
					draw_texture_rect_region(src[0], Rect2(x, y - h, w, h), Rect2(region.position.x, region.position.y + region.size.y - h / unit, w / unit, h / unit))
					x += tile.x
				y -= tile.y
		_:
			draw_texture_rect_region(src[0], Rect2(Vector2.ZERO, size), region)
