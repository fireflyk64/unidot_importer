# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
extends Node
## Helper child ("UnidotText") of a text whose drawing depends on its rect: an auto-sized text
## is fitted again whenever the rect changes, a text that may run out of its rect is checked for
## that (runtime/ui_text.gd does the work).

const UiText := preload("./ui_text.gd")


func _ready() -> void:
	var host: Control = get_parent() as Control
	if host == null:
		return
	host.resized.connect(_layout)
	_layout.call_deferred()


func _layout() -> void:
	var host: Control = get_parent() as Control
	if host != null:
		UiText.layout(host)
