# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
@tool
extends Node
## The UI components of the object this node is a child of, as animation tracks see them
## (helper child "UnidotUi", added by the importer to the objects an Animator animates).
##
## A Unity clip animates fields of components: `m_Color.a` of an Image, `m_fontSize` of a
## text, `m_Alpha` of a CanvasGroup, `m_Sprite`. What those do to the Control is decided by the
## run-time modules (ui_graphic.gd, ui_text.gd, canvas_group.gd, selectable.gd), so the tracks
## of a converted clip point here ("Icon/UnidotUi:color:a") and every value set goes through
## the function a script's setter goes through. Flags are numbers, as curves have them.

const RT := preload("./rect_transform.gd")
const Graphic := preload("./ui_graphic.gd")
const UiText := preload("./ui_text.gd")
const UiGroup := preload("./canvas_group.gd")
const Selectable := preload("./selectable.gd")
const HELPER := "UnidotUi"

const GRAPHICS := ["Image", "RawImage", "Text", "TextMeshProUGUI"]
const SELECTABLES := ["Button", "Toggle", "Slider", "Scrollbar", "InputField", "TMP_InputField", "Dropdown", "TMP_Dropdown"]


## What a float curve of a UI component drives: "ui:<property of this node>" or
## "node:<property of the Control>"; "" for a field that is not animated here.
## `kind` is the component (ui_integration.gd's names; "CanvasGroup" for the native component).
static func curve_property(kind: String, attribute: String) -> String:
	if kind in GRAPHICS:
		for field in ["m_Color", "m_fontColor"]:
			if attribute.begins_with(field + ".") and attribute.substr(field.length() + 1) in ["r", "g", "b", "a"]:
				return "ui:color:" + attribute.substr(field.length() + 1)
		match attribute:
			"m_Enabled":
				return "ui:graphic_enabled"
			"m_FillAmount":
				return "ui:fill_amount"
			"m_fontSize", "m_FontData.m_FontSize":
				return "ui:font_size"
	if kind == "CanvasGroup":
		match attribute:
			"m_Alpha":
				return "ui:group_alpha"
			"m_Interactable":
				return "ui:group_interactable"
			"m_BlocksRaycasts":
				return "ui:group_blocks_raycasts"
	if kind in SELECTABLES:
		match attribute:
			"m_Interactable":
				return "ui:interactable"
			"m_IsOn":
				return "ui:is_on"
			"m_Value":
				return "node:value" if kind in ["Slider", "Scrollbar"] else ""
	return ""


## The Control the components of this object configure.
func _host() -> Control:
	var p: Node = get_parent()
	if p is Control:
		return p
	return RT.root_control(p) if p != null else null


var color: Color:
	get:
		return Graphic.color(_host()) if _host() != null else Color.WHITE
	set(v):
		if _host() != null:
			Graphic.set_color(_host(), v)

var graphic_enabled: float:
	get:
		return 1.0 if _host() != null and Graphic.enabled(_host()) else 0.0
	set(v):
		if _host() != null and Graphic.enabled(_host()) != (v > 0.5):
			Graphic.set_enabled(_host(), v > 0.5)

## Image.fillAmount
var fill_amount: float:
	get:
		var sprite = Graphic.state(_host()).get("sprite") if _host() != null else null
		return float(sprite.get("amount", 1.0)) if sprite is Dictionary else 1.0
	set(v):
		var h: Control = _host()
		var sprite = Graphic.state(h).get("sprite") if h != null else null
		if sprite is Dictionary and not is_equal_approx(float(sprite.get("amount", 1.0)), clampf(v, 0.0, 1.0)):
			var changed: Dictionary = (sprite as Dictionary).duplicate()
			changed["amount"] = clampf(v, 0.0, 1.0)
			Graphic.update(h, {"sprite": changed})

var font_size: float:
	get:
		return UiText.font_size(_host()) if _host() != null else 0.0
	set(v):
		if _host() != null and not is_equal_approx(UiText.font_size(_host()), v):
			UiText.set_font_size(_host(), v)

var group_alpha: float:
	get:
		return float(UiGroup.state(_host()).get("alpha", 1.0)) if _host() != null else 1.0
	set(v):
		if _host() != null:
			UiGroup.update(_host(), {"alpha": clampf(v, 0.0, 1.0)})

var group_interactable: float:
	get:
		return 1.0 if _host() != null and bool(UiGroup.state(_host()).get("interactable", true)) else 0.0
	set(v):
		if _host() != null and bool(UiGroup.state(_host()).get("interactable", true)) != (v > 0.5):
			UiGroup.update(_host(), {"interactable": v > 0.5})

var group_blocks_raycasts: float:
	get:
		return 1.0 if _host() != null and bool(UiGroup.state(_host()).get("blocksRaycasts", true)) else 0.0
	set(v):
		if _host() != null and bool(UiGroup.state(_host()).get("blocksRaycasts", true)) != (v > 0.5):
			UiGroup.update(_host(), {"blocksRaycasts": v > 0.5})

## Selectable.interactable
var interactable: float:
	get:
		var h: Control = _host()
		if h is BaseButton:
			return 0.0 if h.disabled else 1.0
		if h != null and h.get("editable") != null:
			return 1.0 if h.editable else 0.0
		return 1.0
	set(v):
		var h: Control = _host()
		if h == null or (interactable > 0.5) == (v > 0.5):
			return
		if h is BaseButton:
			h.disabled = not (v > 0.5)
		elif h.get("editable") != null:
			h.editable = v > 0.5
		Selectable.refresh_host(h)

## Toggle.isOn (no event: an animated field does not raise onValueChanged)
var is_on: float:
	get:
		return 1.0 if _host() is BaseButton and (_host() as BaseButton).button_pressed else 0.0
	set(v):
		var h: Control = _host()
		if h is BaseButton and h.button_pressed != (v > 0.5):
			h.set_pressed_no_signal(v > 0.5)
			Selectable.refresh_host(h)

## Image.sprite (a clip's object curve on m_Sprite). The texture may carry the sprite's border
## (metadata `unidot_sprite`: {border}).
var sprite: Texture2D:
	get:
		var h: Control = _host()
		if h is TextureRect:
			return h.texture
		return Graphic.state(h).get("texture") as Texture2D if h != null else null
	set(v):
		var h: Control = _host()
		if h == null:
			return
		var changes: Dictionary = {}
		var drawing = Graphic.state(h).get("sprite")
		if v != null and v.has_meta(&"unidot_sprite") and drawing is Dictionary:
			var changed: Dictionary = (drawing as Dictionary).duplicate()
			changed["border"] = (v.get_meta(&"unidot_sprite") as Dictionary).get("border", changed.get("border", [0, 0, 0, 0]))
			changes["sprite"] = changed
		if h is TextureRect:
			h.texture = v
		else:
			changes["texture"] = v
		Graphic.update(h, changes)


## Give the node of an animated object the helper (the importer).
static func ensure(target: Node, owner: Node, script: Script) -> Node:
	var found: Node = target.get_node_or_null(HELPER)
	if found != null:
		return found
	var helper := Node.new()
	helper.name = HELPER
	helper.set_meta(RT.META_HELPER, true)
	helper.set_script(script)
	target.add_child(helper)
	if owner != null and owner != helper:
		helper.owner = owner
	return helper
