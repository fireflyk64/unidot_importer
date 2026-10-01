# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
## Unity Dropdown / TMP_Dropdown on an OptionButton (set by ui_integration.gd). Unity draws
## the caption with its own Text child (font, size, colour of the scene) and an arrow image; the
## OptionButton would draw a second caption and arrow over them. With a caption label the button's
## own text and arrow are made invisible and the label follows the selection.
extends OptionButton

var _caption: Control = null


func _ready() -> void:
	if has_meta("unidot_dropdown"):
		var cfg: Dictionary = get_meta("unidot_dropdown")
		if cfg.get("caption") is NodePath:
			_caption = get_node_or_null(cfg["caption"]) as Control
	if _caption == null:
		return
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color", "font_disabled_color"]:
		add_theme_color_override(c, Color(0, 0, 0, 0))
	add_theme_icon_override("arrow", ImageTexture.new())
	item_selected.connect(_on_selected)
	refresh_caption()


func _on_selected(_index: int) -> void:
	refresh_caption()


## Call it after `selected` or the options change (Dropdown.RefreshShownValue) and after the options change.
func refresh_caption() -> void:
	if _caption == null:
		return
	var text: String = get_item_text(selected) if selected >= 0 and selected < item_count else ""
	if _caption is Label or _caption is RichTextLabel:
		_caption.text = text
