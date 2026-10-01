# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# SPDX-License-Identifier: MIT
extends SceneTree
## Writes the stand-ins for Unity's built-in UI sprites next to this script:
##   godot --headless --path <project with this addon> -s addons/unidot_importer/runtime/sprites/make_sprites.gd
## Unity's own (UISprite, Background, InputFieldBackground, Knob, Checkmark, DropdownArrow,
## UIMask in "UI/Skin") are part of the editor, not of any project. These have their sizes
## (200 pixels per unit: a 32 pixel sprite is 16 units), their 10 pixel borders and their
## look: white shapes that the Image's colour tints, dark marks.
## ImageTextures saved as text resources: no import step in the project that uses them.


func _init() -> void:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	_save(dir, "ui_sprite", _rounded(32, 6.0, Color.WHITE, 0.0))
	_save(dir, "background", _rounded(32, 6.0, Color.WHITE, 0.0))
	_save(dir, "ui_mask", _rounded(32, 6.0, Color.WHITE, 0.0))
	_save(dir, "input_field_background", _rounded(32, 6.0, Color.WHITE, 0.12))
	_save(dir, "knob", _disc(40))
	_save(dir, "checkmark", _polyline(40, [Vector2(7, 21), Vector2(16, 30), Vector2(33, 9)], 5.0, Color(0.2, 0.2, 0.2, 1)))
	_save(dir, "dropdown_arrow", _polyline(40, [Vector2(10, 15), Vector2(20, 26), Vector2(30, 15)], 4.0, Color(0.2, 0.2, 0.2, 1)))
	quit(0)


func _save(dir: String, name: String, img: Image) -> void:
	var tex := ImageTexture.create_from_image(img)
	var err: int = ResourceSaver.save(tex, dir.path_join(name + ".tres"))
	print("%s: %d x %d%s" % [name, img.get_width(), img.get_height(), "" if err == OK else "  SAVE FAILED %d" % err])


## Coverage of a pixel by a shape whose signed distance at the pixel centre is `d` (negative
## inside): one pixel of soft edge.
func _coverage(d: float) -> float:
	return clampf(0.5 - d, 0.0, 1.0)


## A rounded square; `shade` darkens the upper rim (an inset field).
func _rounded(size: int, radius: float, color: Color, shade: float) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half: float = size * 0.5
	for y in range(size):
		for x in range(size):
			var p := Vector2(absf(x + 0.5 - half), absf(y + 0.5 - half))
			var q: Vector2 = p - Vector2(half - radius, half - radius)
			var d: float = Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - radius
			var c: Color = color
			if shade > 0.0:
				var rim: float = clampf(1.0 - (y + 0.5) / 4.0, 0.0, 1.0)
				c = c.darkened(shade * rim)
			c.a = _coverage(d)
			img.set_pixel(x, y, c)
	return img


func _disc(size: int) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half: float = size * 0.5
	for y in range(size):
		for x in range(size):
			var d: float = Vector2(x + 0.5 - half, y + 0.5 - half).length() - (half - 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, _coverage(d)))
	return img


func _polyline(size: int, points: Array, width: float, color: Color) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in range(size):
		for x in range(size):
			var p := Vector2(x + 0.5, y + 0.5)
			var d: float = 1e9
			for i in range(points.size() - 1):
				var a: Vector2 = points[i]
				var b: Vector2 = points[i + 1]
				var t: float = clampf((p - a).dot(b - a) / (b - a).length_squared(), 0.0, 1.0)
				d = minf(d, (p - (a + (b - a) * t)).length())
			img.set_pixel(x, y, Color(color.r, color.g, color.b, _coverage(d - width * 0.5)))
	return img
