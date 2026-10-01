# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# SPDX-License-Identifier: MIT
extends SceneTree
## Renders every world canvas of an imported scene to a PNG (the canvas's own viewport, so what
## the UI draws can be looked at without finding a camera position), and checks the rendering
## against the controls' transforms:
##   godot --path <project> -s addons/unidot_importer/test/ui_shots.gd -- \
##         --scene res://X.tscn --out <dir> [--frames 10] [--only <canvas name>] [--check 1] [--static 1] [--all 1]
## Needs a display (the headless renderer draws nothing).
##
## --check 1: the rendered pixels must show what the transforms put there. Positions computed
## from transforms and positions on screen are two things: the engine may draw a control
## elsewhere than its transform says (snapping, stale canvas items), which no check of
## transforms can see. Sampled are five points of every solid-colour graphic and nine of every
## sprite (where its texture is opaque and even) that no other graphic covers; under a text the
## pixel may be anything between the graphic's colour and the text's. A graphic is reported
## when most of its points show something else.
## --static 1: scripts that are not unidot's own are removed first (the scene as imported).
## --all 1: every UI object is made visible first (menus that a script shows later are rendered
## and checked too; they may overlap).

const RT := preload("../runtime/rect_transform.gd")


func _init() -> void:
	var args: Dictionary = {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < raw.size():
		if raw[i].begins_with("--") and i + 1 < raw.size():
			args[raw[i].substr(2)] = raw[i + 1]
			i += 1
		i += 1
	var ps = load(str(args.get("scene", "")))
	if ps == null:
		push_error("ui_shots: cannot load the scene " + str(args.get("scene", "")))
		quit(2)
		return
	var scene: Node = ps.instantiate()
	if str(args.get("static", "0")) == "1":
		_strip_scripts(scene)
	if str(args.get("all", "0")) == "1":
		_show_all(scene, false)
	root.add_child(scene)
	for _f in range(int(args.get("frames", 10))):
		await process_frame
	var holders: Array = []
	_find(scene, holders)
	var out: String = str(args.get("out", "user://"))
	var check: bool = str(args.get("check", "0")) == "1"
	var count: int = 0
	var points: int = 0
	var problems: Array = []
	for holder in holders:
		if args.has("only") and String(holder.name) != str(args["only"]):
			continue
		var cfg: Dictionary = holder.get_meta(RT.META_CANVAS)
		var vp: SubViewport = holder.get_node_or_null(cfg.get("viewport", NodePath())) as SubViewport
		if vp == null or vp.size.x < 2 or vp.size.y < 2:
			continue
		# a canvas that is hidden or off screen is not rendered: render it once for the picture
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await process_frame
		await process_frame
		var img: Image = vp.get_texture().get_image()
		if img == null or img.is_empty():
			continue
		img.save_png(out.path_join(String(scene.get_path_to(holder)).validate_filename().replace("/", "_") + ".png"))
		count += 1
		if check and RT.island_shown(holder):
			points += _check(vp, img, String(scene.get_path_to(holder)), problems)
	print("[ui_shots] %d canvases" % count)
	if check:
		for p in problems.slice(0, 40):
			print("  MISDRAWN " + str(p))
		print("[ui_shots] pixel check: %d points on %d of %d graphics, %d not drawn where the transforms put them" % [points, graphics_checked, graphics_seen, problems.size()])
	quit(1 if check and (not problems.is_empty() or points == 0) else 0)


func _show_all(n: Node, in_ui: bool) -> void:
	var ui: bool = in_ui or n.has_meta(RT.META_CANVAS) or n is Control
	if ui and (n is Control or n is Node3D) and not n.has_meta(RT.META_VIEW):
		n.visible = true
	for c in n.get_children():
		_show_all(c, ui)


func _strip_scripts(n: Node) -> void:
	var sc: Script = n.get_script() as Script
	if sc != null and not sc.resource_path.begins_with("res://addons/unidot_importer/"):
		n.set_script(null)
	for c in n.get_children():
		_strip_scripts(c)


func _find(n: Node, out: Array) -> void:
	if n.has_meta(RT.META_CANVAS) and str(n.get_meta(RT.META_CANVAS).get("mode", "")) == "world":
		out.append(n)
	for c in n.get_children():
		_find(c, out)


## What a control draws at its rect: [kind, colour, texture]. kind 0 nothing, 1 one opaque
## colour, 2 something that is not compared (a translucent colour, another canvas, a widget),
## 3 a texture stretched over the rect and multiplied by the colour, 4 text in that colour.
func _drawn(c: Control, fade: Color) -> Array:
	var col = null
	if c.has_meta(RT.META_VIEW):
		return [2, Color.WHITE]
	if c is TextureRect:
		if c.texture == null:
			return [0, Color.WHITE]
		if not bool(c.get_meta("unidot_no_sprite", false)):
			if (c.self_modulate * fade).a <= 0.004:
				return [0, Color.WHITE]
			if c.stretch_mode != TextureRect.STRETCH_SCALE or c.flip_h or c.flip_v:
				return [2, Color.WHITE]
			return [3, c.self_modulate * fade, c.texture]
		col = c.self_modulate
	elif c is ColorRect:
		col = c.color
	elif c is RichTextLabel or c is Label:
		var text_color: Color = c.get_theme_color("default_color" if c is RichTextLabel else "font_color") * c.self_modulate * fade
		return [4 if text_color.a > 0.004 else 0, text_color]
	elif c is LineEdit or c is OptionButton or c is Slider or c is ScrollBar:
		return [2, Color.WHITE]
	else:
		for st in ["normal", "panel"]:
			if c.has_theme_stylebox(st):
				var box: StyleBox = c.get_theme_stylebox(st)
				if box is StyleBoxFlat:
					col = box.bg_color * c.self_modulate
				elif box is StyleBoxTexture:
					if c is Button and str(c.text) != "":
						return [2, Color.WHITE]
					var tint: Color = box.modulate_color * c.self_modulate * fade
					return [3, tint, box.texture] if tint.a > 0.004 and box.texture != null else [0, Color.WHITE]
				break
		if c is Button and str(c.text) != "":
			return [2, Color.WHITE]
	if col == null:
		return [0, Color.WHITE]
	col = col * fade
	if col.a <= 0.004:
		return [0, col]
	return [1 if col.a >= 0.996 else 2, col]


## Draw order of the controls of one viewport: [control, transform to viewport pixels, kind,
## colour, clip ancestors].
func _collect(c: Control, fade: Color, clips: Array, out: Array) -> void:
	if not c.visible:
		return
	var f: Color = fade * c.modulate
	var d: Array = _drawn(c, f)
	out.append([c, c.get_global_transform_with_canvas(), d[0], d[1], clips, d[2] if d.size() > 2 else null])
	var inner: Array = clips
	if c.clip_contents or c is ScrollContainer:
		inner = clips.duplicate()
		inner.append(c)
	for ch in c.get_children():
		if ch is Control:
			_collect(ch, f, inner, out)


func _inside(c: Control, xf: Transform2D, p: Vector2) -> bool:
	if absf(xf.determinant()) < 1e-12:
		return false
	var l: Vector2 = xf.affine_inverse() * p
	return l.x >= 0.0 and l.y >= 0.0 and l.x <= c.size.x and l.y <= c.size.y


var _images: Dictionary = {}   # texture → Image (null when it cannot be read)

func _texture_image(tex: Texture2D) -> Image:
	if not _images.has(tex):
		var im: Image = tex.get_image()
		if im != null and im.is_compressed():
			if im.decompress() != OK:
				im = null
		_images[tex] = im
	return _images[tex]


## The colour of a texture around `uv` when it is even there (no edge of the picture within the
## footprint of one screen pixel and a margin), else null.
func _even_texel(tex: Texture2D, uv: Vector2, footprint: Vector2):
	var im: Image = _texture_image(tex)
	if im == null or im.is_empty():
		return null
	var w: int = im.get_width()
	var h: int = im.get_height()
	var cx: int = clampi(int(uv.x * w), 0, w - 1)
	var cy: int = clampi(int(uv.y * h), 0, h - 1)
	var rx: int = maxi(int(ceil(footprint.x * w * 2.0)), 3)
	var ry: int = maxi(int(ceil(footprint.y * h * 2.0)), 3)
	if cx - rx < 0 or cy - ry < 0 or cx + rx >= w or cy + ry >= h:
		return null
	var c0: Color = im.get_pixel(cx, cy)
	for dy in [-ry, 0, ry]:
		for dx in [-rx, 0, rx]:
			var c: Color = im.get_pixel(cx + dx, cy + dy)
			if absf(c.r - c0.r) > 0.02 or absf(c.g - c0.g) > 0.02 or absf(c.b - c0.b) > 0.02 or absf(c.a - c0.a) > 0.02:
				return null
	return c0


var graphics_seen: int = 0
var graphics_checked: int = 0

func _rgb_error(a: Color, b: Color) -> float:
	return maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b))


## Is `px` the colour `want`, or something between it and one of the text colours drawn over it?
func _shows(px: Color, want: Color, texts: Array, tolerance: float) -> bool:
	if absf(px.a - 1.0) > tolerance:
		return false
	if _rgb_error(px, want) <= tolerance:
		return true
	for tc in texts:
		var d := Vector3(tc.r - want.r, tc.g - want.g, tc.b - want.b)
		var len2: float = d.length_squared()
		if len2 < 1e-6:
			continue
		var t: float = clampf(Vector3(px.r - want.r, px.g - want.g, px.b - want.b).dot(d) / len2, 0.0, 1.0)
		if _rgb_error(px, want.lerp(Color(tc.r, tc.g, tc.b, 1.0), t)) <= tolerance:
			return true
	return false


func _check(vp: SubViewport, img: Image, canvas: String, problems: Array) -> int:
	var items: Array = []
	for ch in vp.get_children():
		if ch is Control:
			_collect(ch, Color.WHITE, [], items)
	var points: int = 0
	for index in range(items.size()):
		var item: Array = items[index]
		if item[2] != 1 and item[2] != 3:
			continue
		graphics_seen += 1
		var c: Control = item[0]
		var xf: Transform2D = item[1]
		var on_screen := Vector2(xf.basis_xform(Vector2(c.size.x, 0.0)).length(), xf.basis_xform(Vector2(0.0, c.size.y)).length())
		# too small on screen to have an inner pixel
		if on_screen.x < 4.0 or on_screen.y < 4.0:
			continue
		var fractions: Array = [Vector2(0.5, 0.5), Vector2(0.3, 0.3), Vector2(0.7, 0.3), Vector2(0.3, 0.7), Vector2(0.7, 0.7)]
		if item[2] == 3:
			fractions = []
			for fy in [0.25, 0.5, 0.75]:
				for fx in [0.25, 0.5, 0.75]:
					fractions.append(Vector2(fx, fy))
		var misdrawn: int = 0
		var first: String = ""
		var sampled: int = 0
		for frac in fractions:
			var p: Vector2 = xf * (c.size * frac)
			if p.x < 1.0 or p.y < 1.0 or p.x >= img.get_width() - 1.0 or p.y >= img.get_height() - 1.0:
				continue
			# is this graphic the topmost at the point (later in the tree is drawn later), and
			# which texts are drawn over it?
			var covered: bool = false
			var texts: Array = []
			for j in range(items.size()):
				var other: Array = items[j]
				if j == index or other[2] == 0 or not _inside(other[0], other[1], p):
					continue
				var clipped: bool = false
				for clip in other[4]:
					if not _inside(clip, (clip as Control).get_global_transform_with_canvas(), p):
						clipped = true
				if clipped or j < index:
					continue
				if other[2] == 4:
					texts.append(other[3])
				else:
					covered = true
			for clip in item[4]:
				if not _inside(clip, (clip as Control).get_global_transform_with_canvas(), p):
					covered = true
			if covered:
				continue
			var want: Color = item[3]
			if item[2] == 3:
				var texel = _even_texel(item[5], frac, Vector2(1.0 / on_screen.x, 1.0 / on_screen.y))
				if texel == null:
					continue
				want = (texel as Color) * (item[3] as Color)
				if want.a < 0.996:
					continue
			sampled += 1
			var shown: bool = false
			var got := Color()
			for dx in [0, -1, 1]:
				for dy in [0, -1, 1]:
					var px: Color = img.get_pixel(int(p.x) + dx, int(p.y) + dy)
					if dx == 0 and dy == 0:
						got = px
					if _shows(px, want, texts, 0.06 if item[2] == 1 else 0.1):
						shown = true
			if not shown:
				misdrawn += 1
				if first == "":
					first = "pixel (%d, %d) is %s, the transforms put %s there (%s)" % [int(p.x), int(p.y), str(got), str(c.name), str(want)]
		points += sampled
		if sampled > 0:
			graphics_checked += 1
		if misdrawn * 2 > sampled:
			problems.append("%s :: %s: %d of %d points; %s" % [canvas, str(vp.get_child(0).get_path_to(c)), misdrawn, sampled, first])
	return points
