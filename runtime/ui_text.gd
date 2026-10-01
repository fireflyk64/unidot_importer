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
##    box: float (TextMeshPro 3D: width of the text box in units)}
## Font styles are TextMeshPro's: 1 bold, 2 italic, 4 underline, 8 lower case, 16 upper case,
## 32 small caps, 64 strikethrough (uGUI's FontStyle has the same two lowest bits).
##
## A text whose size depends on its rect (auto-sizing) has a helper child (runtime/ui_text_fit.gd)
## that calls `layout` when the rect changes.

const META := &"unidot_text"
const HELPER := "UnidotText"

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

const _RENDERED := ["b", "i", "u", "s", "strikethrough", "br", "color", "size", "align", "mark", "uppercase", "allcaps", "smallcaps", "lowercase"]
## Tags that have no BBCode counterpart: they are not text either, and are dropped.
const _DROPPED := ["nobr", "font", "material", "line-height", "line-indent", "indent", "margin", "margin-left", "margin-right",
	"pos", "voffset", "cspace", "mspace", "gradient", "link", "style", "width", "sprite", "quad", "rotate", "page", "space",
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
		n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if bool(s["wrap"]) else TextServer.AUTOWRAP_OFF
		# Unity text may run out of its rect (TextMeshPro's default overflow mode)
		n.clip_contents = int(s["overflow"]) != 0
		_show(n, s, size)
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


static func _show(n: RichTextLabel, s: Dictionary, size: float) -> void:
	_rich_font_size(n, maxi(int(round(size)), 1))
	n.text = to_bbcode(str(s["text"]), bool(s["rich"]), int(s["style"]), size, bool(s["tmp"]))


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


## What depends on the rect: the font size of an auto-sized text. Called when the text or the
## rect changes (the helper child connects `resized`).
static func layout(n: Node) -> void:
	if n is RichTextLabel and n.has_meta(META) and bool(n.get_meta(META).get("auto", false)):
		fit(n)


## Auto-sizing (TextMeshPro's enableAutoSizing, uGUI's best fit): the largest size between `min`
## and `max` at which the text fits the rect.
static func fit(n: RichTextLabel) -> void:
	if n.size.x <= 0.0 or n.size.y <= 0.0:
		return
	var s: Dictionary = settings(n)
	var lo: int = maxi(int(ceil(float(s["min"]))), 1)
	var hi: int = maxi(int(floor(float(s["max"]))), lo)
	var best: int = lo
	while lo <= hi:
		var mid: int = (lo + hi) / 2
		_show(n, s, float(mid))
		if n.get_content_height() <= n.size.y + 0.5 and n.get_content_width() <= n.size.x + 0.5:
			best = mid
			lo = mid + 1
		else:
			hi = mid - 1
	_show(n, s, float(best))
	n.set_meta(&"unidot_text_fit", best)


## The size the text is drawn at: the fitted one for an auto-sized text.
static func drawn_font_size(n: Node) -> float:
	if n is RichTextLabel:
		return float(n.get_theme_font_size("normal_font_size"))
	return font_size(n)


## The size the text asks for (ILayoutElement.preferredWidth / preferredHeight): unwrapped on
## the horizontal axis, wrapped at the current width on the vertical one.
static func preferred_size(n: Control, axis: int) -> float:
	if n is RichTextLabel:
		if axis == 1:
			return float(n.get_content_height())
		var s: Dictionary = settings(n)
		var font: Font = n.get_theme_font("bold_font" if int(s["style"]) & BOLD else "normal_font")
		if font == null:
			return float(n.get_content_width())
		return font.get_multiline_string_size(n.get_parsed_text(), HORIZONTAL_ALIGNMENT_LEFT, -1, n.get_theme_font_size("normal_font_size")).x
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
static func to_bbcode(t: String, rich: bool, style: int, base_size: float, tmp: bool = true) -> String:
	var out: String = ""
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
			"color":
				out += "[color=" + _color(value, tmp) + "]"
				colors += 1
			"/color":
				if colors > 0:
					out += "[/color]"
					colors -= 1
			"size":
				sizes.append(_size(value, float(sizes.back()), base_size))
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
static func _size(v: String, current: float, base: float) -> float:
	var t: String = v.strip_edges()
	if t.ends_with("%"):
		return base * t.trim_suffix("%").to_float() / 100.0
	if t.ends_with("em"):
		return current * t.trim_suffix("em").to_float()
	if t.begins_with("+") or t.begins_with("-"):
		return base + t.to_float()
	return t.trim_suffix("px").to_float()


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
