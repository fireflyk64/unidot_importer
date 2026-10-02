# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## Unity text (uGUI Text, TextMeshProUGUI, TextMeshPro) on Godot text nodes.
##
## The Unity string and its settings are kept in the `unidot_text` metadata and rendered from
## there, by the importer and whenever a setting changes later (a script assigning `text`,
## `fontSize` ...): rich text becomes BBCode, font styles (bold, italic, upper case, small caps)
## are applied, auto-sizing picks the largest font size that fits the rect.
##   {text, tmp: bool, rich: bool, size: float, style: int, auto: bool, min: float, max: float,
##    wrap: bool, overflow: int (0: drawn outside the rect, else cut at the rect),
##    box: float (TextMeshPro 3D: width of the text box in units),
##    margin: [left, top, right, bottom] (TextMeshPro's margins: the text is laid out in the
##    rect without them; a negative one gives room beyond the rect),
##    line: float (TextMeshPro's line spacing: hundredths of the font size between lines),
##    line_scale: float (uGUI's line spacing: a factor of the line height),
##    first: int (TextMeshPro's firstVisibleCharacter: the text starts there),
##    visible: int, lines: int (TextMeshPro's maxVisibleCharacters / maxVisibleLines: no more
##    is drawn of the text as it is laid out; absent or negative: all of it),
##    page: int (overflow mode 5: the page that is shown, from 1),
##    linked: NodePath (overflow mode 6: the text that goes on where this one ends),
##    outline: {ratio, color} and underlay: {x, y, dilate, color} (what the material of a
##    TextMeshPro font draws around the glyphs; lengths in font sizes, y down),
##    unit: float (the gradient scale of the font's atlas per unit of font size: the measure
##    of the material's numbers),
##    sprites: a Resource whose `unidot_tmp_sprites` metadata describes a TextMeshPro sprite
##    asset ({point, scale, names: {name: index}, list: [{rect, width, height, scale}]}),
##    sprite_sheet: Texture2D (its picture)}
## Font styles are TextMeshPro's: 1 bold, 2 italic, 4 underline, 8 lower case, 16 upper case,
## 32 small caps, 64 strikethrough (uGUI's FontStyle has the same two lowest bits).
##
## A text whose drawing depends on its rect (auto-sizing, or text that may run out of the rect)
## has a helper child (runtime/ui_text_fit.gd) that calls `layout` when the rect changes.
##
## A text higher than its rect: Unity places what it draws by the vertical alignment. In
## overflow mode (TextMeshPro's default, uGUI's vertical overflow) every line is drawn, around
## the alignment point; a text that is truncated (uGUI's default, TextMeshPro's Truncate and
## Ellipsis) shows the lines that fit entirely; a masked one is clipped at the rect. A
## RichTextLabel draws from the top and leaves out the lines that start below its rect, so such
## a text is drawn by a child label as high as the content ("UnidotTextOverflow"), placed by
## the alignment, while the node itself keeps the Unity rect and the text. A text with margins
## is laid out in another rect than the node's: the same child draws it, there.
##
## Godot draws text at whole font sizes, 1 at least. A text smaller than SMALL (a canvas whose
## units are metres has font sizes like 0.022) is laid out at RASTER by that child, in a rect
## that many times larger, and the child is scaled down to the size the text has in Unity.

const RT := preload("./rect_transform.gd")
const META := &"unidot_text"
const HELPER := "UnidotText"
const DRAWER := "UnidotTextOverflow"
const SMALL := 4.0
const RASTER := 32.0

## Regular, bold, italic, bold italic: a family with the metrics of Liberation Sans, which is
## TextMeshPro's default font (LiberationSans SDF) and metric-compatible with uGUI's Arial.
const FONTS := [preload("./fonts/sans.tres"), preload("./fonts/sans_bold.tres"), preload("./fonts/sans_italic.tres"), preload("./fonts/sans_bold_italic.tres")]

const BOLD := 1
const ITALIC := 2
const UNDERLINE := 4
const LOWER := 8
const UPPER := 16
const SMALLCAPS := 32
const STRIKE := 64
## Small capitals are drawn at this fraction of the font size (TextMeshPro).
const SMALLCAPS_SCALE := 0.8

## Colour names of uGUI rich text, and where TextMeshPro's differ.
const COLORS := {
	"black": "#000000", "blue": "#0000ff", "green": "#008000", "orange": "#ffa500", "purple": "#800080", "red": "#ff0000",
	"white": "#ffffff", "yellow": "#ffff00", "aqua": "#00ffff", "brown": "#a52a2a", "cyan": "#00ffff", "darkblue": "#0000a0",
	"fuchsia": "#ff00ff", "grey": "#808080", "gray": "#808080", "lightblue": "#add8e6", "lime": "#00ff00", "magenta": "#ff00ff",
	"maroon": "#800000", "navy": "#000080", "olive": "#808000", "silver": "#c0c0c0", "teal": "#008080",
}
const COLORS_TMP := {"green": "#00ff00", "orange": "#ff8000", "purple": "#a020f0"}

const _RENDERED := ["b", "i", "u", "s", "strikethrough", "br", "color", "size", "align", "mark", "uppercase", "allcaps", "smallcaps", "lowercase", "sprite"]
## Tags that have no BBCode counterpart: they are not text either, and are dropped.
const _DROPPED := ["nobr", "font", "material", "line-height", "line-indent", "indent", "margin", "margin-left", "margin-right",
	"pos", "voffset", "cspace", "mspace", "gradient", "link", "style", "width", "quad", "rotate", "page", "space",
	"font-weight", "alpha", "sup", "sub", "noparse"]
## uGUI's rich text knows only these.
const _UGUI := ["b", "i", "size", "color", "material", "quad"]


static func _defaults() -> Dictionary:
	return {"text": "", "tmp": false, "rich": true, "size": 14.0, "style": 0, "auto": false, "min": 1.0, "max": 72.0, "wrap": true, "overflow": 0}


static func settings(n: Node) -> Dictionary:
	var s: Dictionary = _defaults()
	if n != null and n.has_meta(META):
		s.merge(n.get_meta(META), true)
	elif n != null and n.get("text") != null:
		s["text"] = str(n.get("text"))
		s["rich"] = false
	return s


## The Unity string of a text node.
static func text(n: Node) -> String:
	if n == null:
		return ""
	if n.has_meta(META):
		return str(n.get_meta(META).get("text", ""))
	var t = n.get("text")
	return str(t) if t != null else ""


static func set_text(n: Node, value: String) -> void:
	update(n, {"text": value})


static func font_size(n: Node) -> float:
	if n != null and n.has_meta(META):
		return float(n.get_meta(META).get("size", 14.0))
	if n is Label3D:
		return float(n.font_size)
	if n is RichTextLabel:
		return float(n.get_theme_font_size("normal_font_size"))
	if n is Control:
		return float(n.get_theme_font_size("font_size"))
	return 14.0


static func set_font_size(n: Node, size: float) -> void:
	update(n, {"size": size})


## Change settings and render. A node without the metadata (a hand-built Label, a LineEdit) just
## gets the plain property.
static func update(n: Node, changes: Dictionary) -> void:
	if n == null:
		return
	if not n.has_meta(META):
		if changes.has("text") and n.get("text") != null:
			n.set("text", str(changes["text"]))
		if changes.has("size"):
			var px: int = maxi(int(round(float(changes["size"]))), 1)
			if n is Label3D:
				n.font_size = px
			elif n is RichTextLabel:
				_rich_font_size(n, px)
			elif n is Control:
				n.add_theme_font_size_override("font_size", px)
		return
	var s: Dictionary = settings(n)
	s.merge(changes, true)
	n.set_meta(META, s)
	render(n)


static func render(n: Node) -> void:
	var s: Dictionary = settings(n)
	var size: float = maxf(float(s["size"]), 1.0)
	if n is RichTextLabel:
		n.bbcode_enabled = true
		n.scroll_active = false
		# (a label that wraps is at least 1 wide: the node of a small text, which its child
		# draws, does not wrap, or it could not have its rect)
		n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if bool(s["wrap"]) and not _by_child(s) else TextServer.AUTOWRAP_OFF
		# Unity text may run out of its rect (TextMeshPro's default overflow mode)
		n.clip_contents = int(s["overflow"]) != 0
		_show(n, s, size)
		# a text that only the child can draw (margins, a size below a font's) shows nothing
		# until it is laid out
		if _by_child(s):
			n.visible_characters = 0
		elif n.get_node_or_null(DRAWER) == null:
			n.visible_characters = -1
		layout(n)
	elif n is Label:
		n.text = plain(str(s["text"]), bool(s["rich"]), int(s["style"]), bool(s["tmp"]))
		n.add_theme_font_size_override("font_size", maxi(int(round(size)), 1))
	elif n is Label3D:
		n.text = plain(str(s["text"]), bool(s["rich"]), int(s["style"]), bool(s["tmp"]))
		n.font = FONTS[int(s["style"]) & 3]
		# the font size of a 3D text is in tenths of a unit per em
		n.pixel_size = size / 10.0 / float(maxi(n.font_size, 1))
		if float(s.get("box", 0.0)) > 0.0 and bool(s["wrap"]):
			n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			n.width = float(s["box"]) / n.pixel_size
	elif n.get("text") != null:
		n.set("text", str(s["text"]))


## Shows the text on a label at a font size of the label's own (`k`: how many times larger than
## in Unity that is, see `raster`).
static func _show(n: RichTextLabel, s: Dictionary, size: float, k: float = 1.0) -> void:
	_rich_font_size(n, maxi(int(round(size)), 1))
	_effects(n, s, size)
	_spacing(n, s, size)
	n.text = to_bbcode(str(s["text"]), bool(s["rich"]), int(s["style"]), size, bool(s["tmp"]), -1, "", _options(s, 0, false, k))


## What to_bbcode needs beside the text: where it starts, the sprites of its <sprite> tags.
static func _options(s: Dictionary, skip: int = 0, trim: bool = false, k: float = 1.0) -> Dictionary:
	return {"skip": int(s.get("first", 0)) + skip, "trim": trim, "sprites": s.get("sprites"), "sprite_sheet": s.get("sprite_sheet"), "scale": k}


## How many times larger than in Unity a text of that size is laid out (see above): 1 for a
## text of an ordinary size.
static func _raster(size: float) -> float:
	return RASTER / size if size > 0.0 and size < SMALL else 1.0


## ... the text of a node: by the size it is drawn at (an auto-sized one: the size it was
## fitted to).
static func raster(s: Dictionary, n: Node = null) -> float:
	if bool(s.get("auto", false)):
		return _raster(float(n.get_meta(&"unidot_text_fit")) if n != null and n.has_meta(&"unidot_text_fit") else float(s.get("max", 72.0)))
	return _raster(float(s.get("size", 14.0)))


## Is the text drawn by the child whatever its rect: it has margins, or it is (or may be
## fitted to) a size below a font's.
static func _by_child(s: Dictionary) -> bool:
	return _has_margins(s) or float(s.get("min", 1.0) if bool(s.get("auto", false)) else s.get("size", 14.0)) < SMALL


static func _has_margins(s: Dictionary) -> bool:
	var m = s.get("margin")
	return m is Array and (m as Array).size() >= 4 and not (is_zero_approx(float(m[0])) and is_zero_approx(float(m[1])) and is_zero_approx(float(m[2])) and is_zero_approx(float(m[3])))


## A length the material gives in font sizes, in whole units: what is thinner than a unit but
## can be seen is one unit.
static func _units(ratio: float, size: float) -> int:
	var v: float = ratio * size
	if absf(v) < 0.25:
		return 0
	return int(signf(v)) * maxi(roundi(absf(v)), 1)


## The outline and the underlay of a TextMeshPro material: the label's outline and shadow.
static func _effects(n: RichTextLabel, s: Dictionary, size: float) -> void:
	var outline = s.get("outline")
	if outline is Dictionary:
		n.add_theme_constant_override("outline_size", _units(float(outline.get("ratio", 0.0)), size))
		n.add_theme_color_override("font_outline_color", outline.get("color", Color.BLACK))
	var underlay = s.get("underlay")
	if underlay is Dictionary:
		n.add_theme_color_override("font_shadow_color", underlay.get("color", Color(0, 0, 0, 0.5)))
		n.add_theme_constant_override("shadow_offset_x", _units(float(underlay.get("x", 0.0)), size))
		n.add_theme_constant_override("shadow_offset_y", _units(float(underlay.get("y", 0.0)), size))
		n.add_theme_constant_override("shadow_outline_size", _units(float(underlay.get("dilate", 0.0)), size))


## The room between lines: TextMeshPro's line spacing is in hundredths of the font size,
## uGUI's a factor of the font's line height. In whole units, as the label takes it.
static func _spacing(n: RichTextLabel, s: Dictionary, size: float) -> void:
	var extra: float = float(s.get("line", 0.0)) * size / 100.0
	var scale: float = float(s.get("line_scale", 1.0))
	if not is_equal_approx(scale, 1.0):
		var font: Font = n.get_theme_font("normal_font")
		if font != null:
			extra += (scale - 1.0) * font.get_height(maxi(int(round(size)), 1))
	if not is_zero_approx(extra) or n.has_theme_constant_override("line_separation"):
		n.add_theme_constant_override("line_separation", roundi(extra))


## The rect a text is laid out in, in the node's own coordinates: the node's rect without
## TextMeshPro's margins.
static func area(n: Control, s: Dictionary) -> Rect2:
	var m = s.get("margin")
	if not (m is Array) or (m as Array).size() < 4:
		return Rect2(Vector2.ZERO, n.size)
	return Rect2(float(m[0]), float(m[1]), maxf(n.size.x - float(m[0]) - float(m[2]), 0.0), maxf(n.size.y - float(m[1]) - float(m[3]), 0.0))


static func _rich_font_size(n: RichTextLabel, size: int) -> void:
	for item in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
		n.add_theme_font_size_override(item, size)


## The four fonts of a rich text (regular, bold, italic, bold italic).
static func set_fonts(n: Node, fonts: Array = FONTS) -> void:
	if n is RichTextLabel:
		n.add_theme_font_override("normal_font", fonts[0])
		n.add_theme_font_override("bold_font", fonts[1])
		n.add_theme_font_override("italics_font", fonts[2])
		n.add_theme_font_override("bold_italics_font", fonts[3])
	elif n is Label3D:
		n.font = fonts[0]
	elif n is Control:
		n.add_theme_font_override("font", fonts[0])


## TextMeshPro's overflow modes that show only whole lines (Ellipsis, Truncate, Page, Linked);
## uGUI's vertical Truncate is stored as 3.
const CUT_MODES := [1, 3, 5, 6]
const ELLIPSIS := 1
const PAGE := 5
const LINKED := 6


## Does the drawing of a text with these settings depend on its rect (→ the helper child)?
## Any text may be higher than its rect.
static func needs_layout(_s: Dictionary) -> bool:
	return true


## What depends on the rect: the font size of an auto-sized text, and whether the text runs out
## of the rect. Called when the text or the rect changes (the helper child connects `resized`).
static func layout(n: Node) -> void:
	if not (n is RichTextLabel) or not n.has_meta(META):
		return
	var s: Dictionary = settings(n)
	if bool(s.get("auto", false)):
		fit(n)
	_overflow(n, s)


## The child that draws the text in place of the node (see above), with the node's fonts,
## colours, alignment and text.
static func _drawer(n: RichTextLabel, drawer: RichTextLabel, wrap: bool) -> RichTextLabel:
	if drawer == null:
		drawer = RichTextLabel.new()
		drawer.name = DRAWER
		drawer.set_meta(RT.META_HELPER, true)
		drawer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		drawer.bbcode_enabled = true
		drawer.scroll_active = false
		drawer.clip_contents = false
		n.add_child(drawer)
	for item in ["normal_font", "bold_font", "italics_font", "bold_italics_font"]:
		if n.has_theme_font_override(item):
			drawer.add_theme_font_override(item, n.get_theme_font(item))
	for item in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
		drawer.add_theme_font_size_override(item, n.get_theme_font_size(item))
	for item in ["default_color", "font_outline_color", "font_shadow_color"]:
		if n.has_theme_color_override(item):
			drawer.add_theme_color_override(item, n.get_theme_color(item))
	for item in ["outline_size", "shadow_offset_x", "shadow_offset_y", "shadow_outline_size", "line_separation"]:
		if n.has_theme_constant_override(item):
			drawer.add_theme_constant_override(item, n.get_theme_constant(item))
	drawer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap else TextServer.AUTOWRAP_OFF
	drawer.horizontal_alignment = n.horizontal_alignment
	drawer.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	drawer.self_modulate = n.self_modulate
	drawer.text = n.text
	return drawer


## The label a text is laid out on: the node itself, or its child when the text has margins
## (the child is then as wide as the rect without them) or is laid out `k` times larger.
static func _laid_out(n: RichTextLabel, s: Dictionary, box: Rect2, k: float) -> RichTextLabel:
	if not _by_child(s):
		return n
	var drawer: RichTextLabel = _drawer(n, n.get_node_or_null(DRAWER) as RichTextLabel, bool(s.get("wrap", true)))
	if k != 1.0:
		_show(drawer, s, drawn_font_size(n) * k, k)
	drawer.size = Vector2(box.size.x * k, maxf(drawer.size.y, 1.0))
	drawer.scale = Vector2.ONE / k
	return drawer


## A text higher than its rect, or one with margins, is drawn by a child as high as the content
## (see above).
static func _overflow(n: RichTextLabel, s: Dictionary) -> void:
	var drawer: RichTextLabel = n.get_node_or_null(DRAWER) as RichTextLabel
	var mode: int = int(s.get("overflow", 0))
	var box: Rect2 = area(n, s)
	var k: float = raster(s, n)
	var wraps: bool = bool(s.get("wrap", true))
	var ready: bool = n.is_inside_tree() and box.size.x > 0.0
	var inset: bool = ready and _by_child(s)
	var laid: RichTextLabel = n
	if inset:
		laid = _laid_out(n, s, box, k)
		drawer = laid
	# (the area in the units of the label the text is laid out on)
	var limit: Vector2 = box.size * k
	var content: float = 0.0
	var over: bool = false
	# a line that is not wrapped and is wider than the rect is cut as well
	var wide: bool = false
	if ready:
		content = float(laid.get_content_height())
		over = content > limit.y + 0.5
		wide = mode in CUT_MODES and not wraps and float(laid.get_content_width()) > limit.x + 0.5
	# a page that is not the first one is not what the node itself would draw
	var paged: bool = mode == PAGE and int(s.get("page", 1)) > 1 and ready
	if not over and not wide and not paged and not inset:
		if drawer != null:
			n.remove_child(drawer)
			drawer.queue_free()
		# (a text that only the child can draw stays hidden until it is laid out)
		if not _by_child(s):
			n.visible_characters = _shown_characters(n, s, -1) if ready else -1
		if mode == LINKED and ready:
			_link(n, s, -1)
		return
	if not inset:
		drawer = _drawer(n, drawer, wraps)
	drawer.size = Vector2(limit.x, content)
	drawer.scale = Vector2.ONE / k
	# what is drawn: everything, or the lines that fit entirely
	var shown: float = content
	var characters: int = -1
	if mode == ELLIPSIS and over or (wide and mode in CUT_MODES):
		# the longest beginning of the text that fits the rect (with the ellipsis after it, in
		# TextMeshPro's Ellipsis mode): found by laying it out
		var raw: String = str(s.get("text", ""))
		var rich: bool = bool(s.get("rich", true))
		var tmp: bool = bool(s.get("tmp", true))
		var style: int = int(s.get("style", 0))
		var size: float = float(drawer.get_theme_font_size("normal_font_size"))
		var total: int = maxi(visible_length(raw, rich, tmp) - int(s.get("first", 0)), 0)
		var tail: String = "…" if mode == ELLIPSIS else ""
		var wrapped: bool = wraps
		var lo: int = 0
		var hi: int = total
		while lo < hi:
			var mid: int = (lo + hi + 1) / 2
			drawer.text = to_bbcode(raw, rich, style, size, tmp, mid, tail if mid < total else "", _options(s, 0, false, k))
			if float(drawer.get_content_height()) <= limit.y + 0.5 and (wrapped or float(drawer.get_content_width()) <= limit.x + 0.5):
				lo = mid
			else:
				hi = mid - 1
		drawer.text = to_bbcode(raw, rich, style, size, tmp, lo, tail if lo < total else "", _options(s, 0, false, k))
		shown = minf(float(drawer.get_content_height()), limit.y) if lo > 0 else 0.0
		if lo == 0:
			drawer.text = ""   # (not even one character and the ellipsis)
	elif mode == PAGE and (over or paged):
		# the lines of the page, laid out as a text of their own
		var range_: Array = page_range(laid, int(s.get("page", 1)), limit.y)
		if range_.is_empty():
			drawer.text = ""
			shown = 0.0
		else:
			drawer.text = to_bbcode(str(s.get("text", "")), bool(s.get("rich", true)), int(s.get("style", 0)), float(drawer.get_theme_font_size("normal_font_size")), bool(s.get("tmp", true)),
				range_[1] - range_[0], "", _options(s, range_[0], true, k))
			shown = minf(float(drawer.get_content_height()), limit.y)
	elif mode in CUT_MODES and over:
		var fit: Array = whole_lines(laid, limit.y)
		shown = fit[0]
		characters = fit[1]
		if mode == LINKED:
			_link(n, s, characters)
	elif mode == LINKED:
		_link(n, s, -1)
	drawer.visible_characters = _shown_characters(drawer, s, characters)
	var y: float = 0.0
	match n.vertical_alignment:
		VERTICAL_ALIGNMENT_CENTER:
			y = (box.size.y - shown / k) * 0.5
		VERTICAL_ALIGNMENT_BOTTOM:
			y = box.size.y - shown / k
	drawer.position = box.position + Vector2(0.0, y)
	n.visible_characters = 0   # the node keeps the text (and measures it) but does not draw it


## How many characters a laid out text shows: those its overflow mode leaves (`characters`,
## -1: all), no more than maxVisibleCharacters and the characters of maxVisibleLines.
static func _shown_characters(label: RichTextLabel, s: Dictionary, characters: int) -> int:
	var most: int = int(s.get("visible", -1))
	if most >= 0 and (characters < 0 or most < characters):
		characters = most
	var lines: int = int(s.get("lines", -1))
	if lines >= 0 and lines < label.get_line_count():
		var first: int = _line_start(label, lines)
		if characters < 0 or first < characters:
			characters = first
	return characters


## TextMeshPro's Linked overflow: the text that does not fit goes on in another text
## component, which gets this one's string and the character it starts at. `characters`: how
## many this text shows (-1: all of them, and the other one shows nothing).
static func _link(n: RichTextLabel, s: Dictionary, characters: int) -> void:
	var path = s.get("linked")
	var target: Node = n.get_node_or_null(path) if path is NodePath and not (path as NodePath).is_empty() else null
	if target == null or target == n or not target.has_meta(META):
		return
	var theirs: Dictionary = target.get_meta(META)
	var text_: String = str(s.get("text", "")) if characters >= 0 else ""
	var first: int = int(s.get("first", 0)) + characters if characters >= 0 else 0
	if str(theirs.get("text", "")) != text_ or int(theirs.get("first", 0)) != first:
		update(target, {"text": text_, "first": first})


## The first character of a line of a laid out text (the number of characters when there is no
## such line).
static func _line_start(n: RichTextLabel, line: int) -> int:
	var lo: int = 0
	var hi: int = n.get_total_character_count()
	while lo < hi:
		var mid: int = (lo + hi) / 2
		if n.get_character_line(mid) >= line:
			hi = mid
		else:
			lo = mid + 1
	return lo


## TextMeshPro's Page overflow: the lines that fit the rect are a page, the next ones the next
## page. → [first character, the one after the last] of a page (from 1), [] when the text has
## no such page.
static func page_range(n: RichTextLabel, page: int, height: float = -1.0) -> Array:
	if height < 0.0:
		height = n.size.y
	var lines: int = n.get_line_count()
	var content: float = float(n.get_content_height())
	var start: int = 0
	var number: int = 1
	while start < lines:
		var top: float = n.get_line_offset(start)
		var last: int = start
		for i in range(start + 1, lines):
			var bottom: float = n.get_line_offset(i + 1) if i + 1 < lines else content
			if bottom - top > height + 0.5:
				break
			last = i
		if number == page:
			return [_line_start(n, start), _line_start(n, last + 1)]
		number += 1
		start = last + 1
	return []


## The lines of a text that fit its rect entirely: [their height, the number of characters
## in them].
static func whole_lines(n: RichTextLabel, limit: float = -1.0) -> Array:
	if limit < 0.0:
		limit = n.size.y
	var lines: int = n.get_line_count()
	var content: float = float(n.get_content_height())
	var last: int = -1
	var height: float = 0.0
	for i in range(lines):
		var bottom: float = n.get_line_offset(i + 1) if i + 1 < lines else content
		if bottom > limit + 0.5:
			break
		last = i
		height = bottom
	if last < 0:
		return [0.0, 0]
	if last == lines - 1:
		return [height, -1]
	# the characters up to the first one of the line after the last that fits
	var total: int = n.get_total_character_count()
	var lo: int = 0
	var hi: int = total
	while lo < hi:
		var mid: int = (lo + hi) / 2
		if n.get_character_line(mid) > last:
			hi = mid
		else:
			lo = mid + 1
	return [height, lo]


## Auto-sizing (TextMeshPro's enableAutoSizing, uGUI's best fit): the largest size between `min`
## and `max` at which the text fits the rect: a whole size, or any size below SMALL.
static func fit(n: RichTextLabel) -> void:
	var s: Dictionary = settings(n)
	var box: Rect2 = area(n, s)
	if box.size.x <= 0.0 or box.size.y <= 0.0:
		return
	var high: float = maxf(float(s["max"]), float(s["min"]))
	var low: float = maxf(float(s["min"]), minf(high, 0.001))
	var best: float = low
	if low >= SMALL:
		var lo: int = maxi(int(ceil(low)), 1)
		var hi: int = maxi(int(floor(high)), lo)
		best = float(lo)
		while lo <= hi:
			var mid: int = (lo + hi) / 2
			if _fits(n, s, box, float(mid)):
				best = float(mid)
				lo = mid + 1
			else:
				hi = mid - 1
	elif _fits(n, s, box, _whole(high)):
		best = _whole(high)
	else:
		var lo: float = low
		var hi: float = high
		for i in range(16):
			var mid: float = (lo + hi) * 0.5
			if _fits(n, s, box, _whole(mid)):
				lo = mid
			else:
				hi = mid
		best = maxf(_whole(lo), low)
	_show(n, s, maxf(best, 1.0))
	n.set_meta(&"unidot_text_fit", best)


static func _whole(size: float) -> float:
	return floorf(size) if size >= SMALL else size


## Does the text fit its area at a font size? (Laid out on the node, or on its child.)
static func _fits(n: RichTextLabel, s: Dictionary, box: Rect2, size: float) -> bool:
	var k: float = _raster(size)
	var laid: RichTextLabel = n
	if _by_child(s):
		laid = _drawer(n, n.get_node_or_null(DRAWER) as RichTextLabel, bool(s.get("wrap", true)))
		laid.size = Vector2(box.size.x * k, maxf(laid.size.y, 1.0))
		laid.scale = Vector2.ONE / k
	_show(laid, s, size * k, k)
	return laid.get_content_height() <= box.size.y * k + 0.5 and laid.get_content_width() <= box.size.x * k + 0.5


## The size the text is drawn at: the fitted one for an auto-sized text.
static func drawn_font_size(n: Node) -> float:
	if n is RichTextLabel:
		if n.has_meta(META):
			var s: Dictionary = settings(n)
			if raster(s, n) != 1.0:
				return float(n.get_meta(&"unidot_text_fit")) if bool(s.get("auto", false)) and n.has_meta(&"unidot_text_fit") else float(s["size"])
		return float(n.get_theme_font_size("normal_font_size"))
	return font_size(n)


## The size the text asks for (ILayoutElement.preferredWidth / preferredHeight): unwrapped on
## the horizontal axis, wrapped at the current width on the vertical one.
static func preferred_size(n: Control, axis: int) -> float:
	if n is RichTextLabel:
		# (TextMeshPro's margins are part of what the text asks for)
		var s: Dictionary = settings(n)
		var m: Array = s["margin"] if s.get("margin") is Array and (s["margin"] as Array).size() >= 4 else [0.0, 0.0, 0.0, 0.0]
		var k: float = raster(s, n)
		# (the child lays the text out when it has margins or is small)
		var laid: RichTextLabel = n
		if _by_child(s) and n.get_node_or_null(DRAWER) is RichTextLabel and (k != 1.0 or int(s.get("overflow", 0)) == 0):
			laid = n.get_node(DRAWER)
		if axis == 1:
			return float(laid.get_content_height()) / k + float(m[1]) + float(m[3])
		var font: Font = n.get_theme_font("bold_font" if int(s["style"]) & BOLD else "normal_font")
		if font == null:
			return float(laid.get_content_width()) / k + float(m[0]) + float(m[2])
		return font.get_multiline_string_size(n.get_parsed_text(), HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(roundi(drawn_font_size(n) * k), 1)).x / k + float(m[0]) + float(m[2])
	if n is Label:
		var lf: Font = n.get_theme_font("font")
		if lf == null:
			return 0.0
		var sz: Vector2 = lf.get_multiline_string_size(n.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0 if axis == 0 else maxf(n.size.x, 1.0), n.get_theme_font_size("font_size"))
		return sz[axis]
	return 0.0


## The characters Unity shows: no tags, cased by the style.
static func plain(t: String, rich: bool, style: int, tmp: bool = true) -> String:
	var upper: int = 1 if style & (UPPER | SMALLCAPS) else 0
	var lower: int = 1 if style & LOWER else 0
	if not rich:
		return _case(t, upper, lower)
	var out: String = ""
	for piece in _tokens(t, tmp):
		match piece[0]:
			"":
				out += _case(piece[1], upper, lower)
			"br":
				out += "\n"
			"uppercase", "allcaps", "smallcaps":
				upper += 1
			"/uppercase", "/allcaps", "/smallcaps":
				upper = maxi(upper - 1, 0)
			"lowercase":
				lower += 1
			"/lowercase":
				lower = maxi(lower - 1, 0)
	return out


static func strip_tags(t: String) -> String:
	return plain(t, true, 0)


## Unity rich text → BBCode. A `<...>` that is not a tag is text, as in Unity (`<<`, `<3`).
## `limit`: at most that many characters of the text are shown (as `visible_length` counts
## them: text, line breaks and sprites), with `tail` after them when the text is longer (an
## ellipsis). `options`: {skip: the characters before this one are left out (their tags still
## count), trim: no line breaks at the end, sprites, sprite_sheet: the sprite asset of <sprite>
## tags (see the settings)}.
static func to_bbcode(t: String, rich: bool, style: int, base_size: float, tmp: bool = true, limit: int = -1, tail: String = "", options: Dictionary = {}) -> String:
	var out: String = ""
	var left: int = limit
	var skip: int = int(options.get("skip", 0))
	if style & BOLD:
		out += "[b]"
	if style & ITALIC:
		out += "[i]"
	if style & UNDERLINE:
		out += "[u]"
	if style & STRIKE:
		out += "[s]"
	var upper: int = 1 if style & UPPER else 0
	var lower: int = 1 if style & LOWER else 0
	var small: int = 1 if style & SMALLCAPS else 0
	var sizes: Array = [base_size]
	var colors: int = 0
	var pieces: Array = _tokens(t, tmp) if rich else [["", t]]
	for piece in pieces:
		var tag: String = piece[0]
		var value: String = piece[1]
		if skip > 0 and (tag == "" or tag == "br" or tag == "sprite"):
			var skipped: int = value.length() if tag == "" else 1
			if skipped <= skip:
				skip -= skipped
				continue
			value = value.substr(skip)
			skip = 0
		if limit >= 0 and (tag == "" or tag == "br" or tag == "sprite"):
			var length: int = value.length() if tag == "" else 1
			if length > left:
				# the cut: what still fits of this piece (no blanks before the tail), the tail,
				# and nothing after it
				if tag == "" and left > 0:
					out += _cased_bbcode(value.substr(0, left).rstrip(" \t"), upper, lower, small, float(sizes.back()))
				out += _escape(tail)
				break
			left -= length
		match tag:
			"":
				out += _cased_bbcode(value, upper, lower, small, float(sizes.back()))
			"b", "i", "u", "s", "/b", "/i", "/u", "/s":
				out += "[" + tag + "]"
			"strikethrough":
				out += "[s]"
			"/strikethrough":
				out += "[/s]"
			"br":
				out += "\n"
			"sprite":
				out += _sprite(value, float(sizes.back()), options)
			"color":
				out += "[color=" + _color(value, tmp) + "]"
				colors += 1
			"/color":
				if colors > 0:
					out += "[/color]"
					colors -= 1
			"size":
				sizes.append(_size(value, float(sizes.back()), base_size, float(options.get("scale", 1.0))))
				out += "[font_size=%d]" % maxi(int(round(float(sizes.back()))), 1)
			"/size":
				if sizes.size() > 1:
					sizes.pop_back()
					out += "[/font_size]"
			"align":
				out += {"left": "[left]", "center": "[center]", "right": "[right]", "justified": "[fill]", "flush": "[fill]"}.get(value.strip_edges().to_lower(), "")
			"mark":
				out += "[bgcolor=" + _color(value, tmp) + "]"
			"/mark":
				out += "[/bgcolor]"
			"uppercase", "allcaps":
				upper += 1
			"/uppercase", "/allcaps":
				upper = maxi(upper - 1, 0)
			"smallcaps":
				small += 1
			"/smallcaps":
				small = maxi(small - 1, 0)
			"lowercase":
				lower += 1
			"/lowercase":
				lower = maxi(lower - 1, 0)
			_:
				pass   # a tag without a counterpart (and "/align": BBCode alignment ends with its paragraph)
	if bool(options.get("trim", false)):
		while out.ends_with("\n"):
			out = out.substr(0, out.length() - 1)
	while sizes.size() > 1:
		sizes.pop_back()
		out += "[/font_size]"
	while colors > 0:
		out += "[/color]"
		colors -= 1
	if style & STRIKE:
		out += "[/s]"
	if style & UNDERLINE:
		out += "[/u]"
	if style & ITALIC:
		out += "[/i]"
	if style & BOLD:
		out += "[/b]"
	return out


## The number of characters a text shows (its tags are not shown; a line break is one, and
## so is a sprite).
static func visible_length(t: String, rich: bool, tmp: bool = true) -> int:
	if not rich:
		return t.length()
	var count: int = 0
	for piece in _tokens(t, tmp):
		if piece[0] == "":
			count += (piece[1] as String).length()
		elif piece[0] == "br" or piece[0] == "sprite":
			count += 1
	return count


## `<sprite=1>`, `<sprite index=1>`, `<sprite name="x">`, `<sprite="asset" index=1>`: a picture
## of the text's sprite asset, scaled with the font size as TextMeshPro scales it. Without the
## asset (or the sprite) nothing is drawn.
static func _sprite(value: String, size: float, options: Dictionary) -> String:
	var asset = options.get("sprites")
	var sheet = options.get("sprite_sheet")
	if not (asset is Resource) or not (sheet is Texture2D) or not (asset as Resource).has_meta(&"unidot_tmp_sprites") or (sheet as Texture2D).resource_path.is_empty():
		return ""
	var info: Dictionary = (asset as Resource).get_meta(&"unidot_tmp_sprites")
	var list: Array = info.get("list", [])
	var index: int = -1
	var v: String = value.strip_edges()
	var named: int = v.find("name=")
	var indexed: int = v.find("index=")
	if named >= 0:
		var name: String = v.substr(named + 5).strip_edges()
		if name.begins_with("\""):
			name = name.substr(1, name.find("\"", 1) - 1)
		else:
			name = name.get_slice(" ", 0)
		index = int((info.get("names", {}) as Dictionary).get(name, -1))
	elif indexed >= 0:
		index = v.substr(indexed + 6).get_slice(" ", 0).to_int()
	elif v.is_valid_int() or (v.get_slice(" ", 0)).is_valid_int():
		index = v.get_slice(" ", 0).to_int()
	if index < 0 or index >= list.size():
		return ""
	var sprite: Dictionary = list[index]
	var rect: Rect2 = sprite.get("rect", Rect2())
	var point: float = float(info.get("point", 0.0))
	var k: float = (size / point if point > 0.0 else 1.0) * float(info.get("scale", 1.0)) * float(sprite.get("scale", 1.0))
	# (the rect is Unity's: its y is from the bottom of the sheet)
	return "[img width=%d height=%d region=%d,%d,%d,%d]%s[/img]" % [maxi(roundi(float(sprite.get("width", rect.size.x)) * k), 1), maxi(roundi(float(sprite.get("height", rect.size.y)) * k), 1),
		int(rect.position.x), int(float((sheet as Texture2D).get_height()) - rect.position.y - rect.size.y), int(rect.size.x), int(rect.size.y), (sheet as Texture2D).resource_path]


static func _case(t: String, upper: int, lower: int) -> String:
	if upper > 0:
		return t.to_upper()
	if lower > 0:
		return t.to_lower()
	return t


## Text with its case applied; small capitals are capitals at a smaller size.
static func _cased_bbcode(t: String, upper: int, lower: int, small: int, size: float) -> String:
	if upper > 0 or lower > 0 or small <= 0:
		return _escape(_case(t, upper, lower))
	var out: String = ""
	var run: String = ""
	var run_small: bool = false
	var small_size: int = maxi(int(round(size * SMALLCAPS_SCALE)), 1)
	for i in range(t.length()):
		var ch: String = t[i]
		var is_small: bool = ch != ch.to_upper()
		if is_small != run_small and run != "":
			out += ("[font_size=%d]%s[/font_size]" % [small_size, _escape(run.to_upper())]) if run_small else _escape(run)
			run = ""
		run_small = is_small
		run += ch
	if run != "":
		out += ("[font_size=%d]%s[/font_size]" % [small_size, _escape(run.to_upper())]) if run_small else _escape(run)
	return out


static func _escape(t: String) -> String:
	return t.replace("[", "[lb]")


static func _color(v: String, tmp: bool = true) -> String:
	var c: String = v.strip_edges().trim_prefix("\"").trim_suffix("\"")
	if c.begins_with("#"):
		return c
	c = c.to_lower()
	if tmp and COLORS_TMP.has(c):
		return COLORS_TMP[c]
	return COLORS.get(c, "#ffffff")


## `<size=24>`, `<size=150%>`, `<size=+4>`, `<size=1.5em>`
## (`scale`: how many times larger than in Unity the text is laid out, see `raster`)
static func _size(v: String, current: float, base: float, scale: float = 1.0) -> float:
	var t: String = v.strip_edges()
	if t.ends_with("%"):
		return base * t.trim_suffix("%").to_float() / 100.0
	if t.ends_with("em"):
		return current * t.trim_suffix("em").to_float()
	if t.begins_with("+") or t.begins_with("-"):
		return base + t.to_float() * scale
	return t.trim_suffix("px").to_float() * scale


## Split into [tag, value] pieces; text is ["", text]. `<#RRGGBB>` is TextMeshPro's short form
## of a colour tag.
static func _tokens(t: String, tmp: bool = true) -> Array:
	var out: Array = []
	var i: int = 0
	var plain_run: String = ""
	var noparse: bool = false
	while i < t.length():
		var lt: int = t.find("<", i)
		var gt: int = t.find(">", lt) if lt >= 0 else -1
		if lt < 0 or gt < 0:
			plain_run += t.substr(i)
			break
		var body: String = t.substr(lt + 1, gt - lt - 1)
		# the name ends at `=` (a value follows) or at a space (attributes: `<sprite name="x">`)
		var name: String = body
		var value: String = ""
		var cut: int = -1
		for j in range(body.length()):
			if body[j] == "=" or body[j] == " ":
				cut = j
				break
		if tmp and body.begins_with("#"):
			name = "color"
			value = body
		elif cut >= 0:
			name = body.substr(0, cut)
			value = body.substr(cut + 1)
		name = name.strip_edges().to_lower()
		var base_name: String = name.trim_prefix("/")
		var known: bool = (base_name in _RENDERED or base_name in _DROPPED) if tmp else base_name in _UGUI
		if noparse and name != "/noparse":
			known = false
		if not known or body.contains("<"):
			plain_run += t.substr(i, lt - i + 1)
			i = lt + 1
			continue
		plain_run += t.substr(i, lt - i)
		if plain_run != "":
			out.append(["", plain_run])
			plain_run = ""
		if name == "noparse":
			noparse = true
		elif name == "/noparse":
			noparse = false
		out.append([name, value])
		i = gt + 1
	if plain_run != "":
		out.append(["", plain_run])
	return out
