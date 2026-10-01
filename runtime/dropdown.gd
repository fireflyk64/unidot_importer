# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
extends Node
## Unity's Dropdown / TMP_Dropdown for the OptionButton this node is a child of (helper child
## "UnidotDropdown", added by ui_integration.gd). The OptionButton holds the options and the
## value; what the user sees is Unity's own objects:
##   * the caption Text (and Image) shows the selected option; the button's own text and arrow
##     are not drawn;
##   * a click opens Unity's list, built from the Template object as Dropdown.Show does: the
##     template is copied ("Dropdown List"), one copy of its item per option (text, image, the
##     Toggle on for the current value), the content sized to the items, the list shortened to
##     its content and flipped to the other side when it would leave the canvas; a blocker
##     behind it closes it. The list is drawn (and takes the pointer) above everything else of
##     its canvas, as Unity's list canvas with sorting order 30000 does.
## Without a template the OptionButton's own popup opens.
## The parent's `unidot_dropdown` metadata: {caption, caption_image, template, item_text,
## item_image: NodePath}.

const RT := preload("./rect_transform.gd")
const UiText := preload("./ui_text.gd")
const Graphic := preload("./ui_graphic.gd")
const Selectable := preload("./selectable.gd")
const META := &"unidot_dropdown"
const HELPER := "UnidotDropdown"
const LIST := "Dropdown List"
const BLOCKER := "Blocker"

var _host: OptionButton = null
var _list: Control = null
var _blocker: Control = null


func _ready() -> void:
	_host = get_parent() as OptionButton
	if _host == null:
		return
	if part(_host, "caption") != null:
		# Unity draws the caption with its own objects
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color", "font_disabled_color"]:
			_host.add_theme_color_override(c, Color(0, 0, 0, 0))
		_host.add_theme_icon_override("arrow", ImageTexture.new())
	_host.item_selected.connect(func(_i: int) -> void: refresh_caption(_host))
	_host.gui_input.connect(_on_input)
	refresh_caption(_host)


static func part(host: Node, key: String) -> Node:
	if host == null or not host.has_meta(META):
		return null
	var p = (host.get_meta(META) as Dictionary).get(key)
	if p is NodePath and not (p as NodePath).is_empty():
		return host.get_node_or_null(p)
	return null


## Dropdown.RefreshShownValue: the caption shows the selected option, or nothing.
static func refresh_caption(host: OptionButton) -> void:
	var caption: Node = part(host, "caption")
	var selected: int = host.selected
	var has: bool = selected >= 0 and selected < host.item_count
	if caption != null:
		UiText.set_text(caption, host.get_item_text(selected) if has else "")
	var image: Control = part(host, "caption_image") as Control
	if image != null:
		var icon: Texture2D = host.get_item_icon(selected) if has else null
		if image is TextureRect and icon != null:
			image.texture = icon
		Graphic.update(image, {"enabled": icon != null})


func is_shown() -> bool:
	return _list != null and is_instance_valid(_list)


func _on_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or event.button_index != MOUSE_BUTTON_LEFT:
		return
	if part(_host, "template") == null:
		return   # the OptionButton's own popup
	_host.accept_event()
	if event.pressed and Selectable.interactable(_host):
		if is_shown():
			hide()
		else:
			show()


## The control that everything of the canvas is under (Unity's root canvas rect).
func _canvas_root() -> Control:
	var cur: Control = _host
	while cur.get_parent() is Control:
		cur = cur.get_parent()
	return cur


## The first Toggle below `n` (Unity: the template's item).
static func _first_toggle(n: Node) -> BaseButton:
	for c in n.get_children():
		if c is BaseButton and c.toggle_mode:
			return c
		var found: BaseButton = _first_toggle(c)
		if found != null:
			return found
	return null


## Dropdown.Show
func show() -> void:
	if is_shown() or _host == null:
		return
	var template: Control = part(_host, "template") as Control
	if template == null:
		_host.show_popup()
		return
	var item_proto: BaseButton = _first_toggle(template)
	if item_proto == null:
		_host.show_popup()   # (Unity: "The dropdown template is not valid")
		return
	# where the item's text and image are, relative to the item
	var text_path := NodePath()
	var image_path := NodePath()
	var item_text: Node = part(_host, "item_text")
	var item_image: Node = part(_host, "item_image")
	if item_text != null and item_proto.is_ancestor_of(item_text):
		text_path = item_proto.get_path_to(item_text)
	if item_image != null and item_proto.is_ancestor_of(item_image):
		image_path = item_proto.get_path_to(item_image)
	var item_path: NodePath = template.get_path_to(item_proto)
	# the list: a copy of the template, next to it
	var list: Control = template.duplicate() as Control
	list.name = LIST
	template.get_parent().add_child(list)
	_set_active(list, true)
	_list = list
	var proto: BaseButton = list.get_node(item_path) as BaseButton
	var content: Control = proto.get_parent() as Control
	_set_active(proto, true)
	# the gaps between the item's edges and the content's edges
	var content_rect: Rect2 = RT.rect(content)
	var item_rect: Rect2 = RT.rect(proto)
	var item_local: Vector3 = RT.local_position(proto)
	var offset_min: Vector2 = item_rect.position - content_rect.position + Vector2(item_local.x, item_local.y)
	var offset_max: Vector2 = item_rect.end - content_rect.end + Vector2(item_local.x, item_local.y)
	var item_size: Vector2 = item_rect.size
	var items: Array = []
	for i in range(_host.item_count):
		var item: BaseButton = proto.duplicate() as BaseButton
		item.name = "Item %d: %s" % [i, _host.get_item_text(i)]
		content.add_child(item)
		if not text_path.is_empty() and item.get_node_or_null(text_path) != null:
			UiText.set_text(item.get_node(text_path), _host.get_item_text(i))
		if not image_path.is_empty() and item.get_node_or_null(image_path) != null:
			var image: Node = item.get_node(image_path)
			var icon: Texture2D = _host.get_item_icon(i)
			if image is TextureRect and icon != null:
				image.texture = icon
			Graphic.update(image, {"enabled": icon != null})
		item.set_pressed_no_signal(i == _host.selected)
		Selectable.refresh_host(item)
		item.toggled.connect(_on_item.bind(i))
		items.append(item)
	# the content holds the items; a list that is higher than its content shrinks to it
	var content_delta: Vector2 = RT.size_delta(content)
	content_delta.y = item_size.y * items.size() + offset_min.y - offset_max.y
	RT.set_size_delta(content, content_delta)
	var extra: float = RT.rect_size(list).y - RT.rect_size(content).y
	if extra > 0.0:
		var list_delta: Vector2 = RT.size_delta(list)
		RT.set_size_delta(list, Vector2(list_delta.x, list_delta.y - extra))
	# a list that leaves the canvas goes to the other side of the button
	var canvas: Control = _canvas_root()
	var canvas_rect := Rect2(Vector2.ZERO, canvas.size).grow(0.01)
	var to_canvas: Transform2D = canvas.get_global_transform().affine_inverse() * list.get_global_transform()
	for axis in range(2):
		var outside: bool = false
		for corner in [Vector2.ZERO, Vector2(list.size.x, 0.0), list.size, Vector2(0.0, list.size.y)]:
			var p: Vector2 = to_canvas * corner
			if p[axis] < canvas_rect.position[axis] or p[axis] > canvas_rect.end[axis]:
				outside = true
		if outside:
			_flip(list, axis)
	for i in range(items.size()):
		var item: Control = items[i]
		var v: Dictionary = RT.values(item)
		RT.set_values(item, {
			"anchor_min": Vector2(v["anchor_min"].x, 0.0), "anchor_max": Vector2(v["anchor_max"].x, 0.0),
			"anchored_position": Vector2(v["anchored_position"].x, offset_min.y + item_size.y * (items.size() - 1 - i) + item_size.y * v["pivot"].y),
			"size_delta": Vector2(v["size_delta"].x, item_size.y),
		})
	_set_active(proto, false)
	# above everything else of the canvas: last under its root, the blocker just below
	var blocker := Control.new()
	blocker.name = BLOCKER
	blocker.set_meta(RT.META_HELPER, true)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(blocker)
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blocker.gui_input.connect(_on_blocker.bind(blocker))
	_blocker = blocker
	var xf: Transform2D = canvas.get_global_transform().affine_inverse() * list.get_global_transform()
	var size: Vector2 = list.size
	list.get_parent().remove_child(list)
	canvas.add_child(list)
	list.set_anchors_preset(Control.PRESET_TOP_LEFT)
	list.pivot_offset = Vector2.ZERO
	list.pivot_offset_ratio = Vector2.ZERO
	list.rotation = xf.get_rotation()
	list.scale = xf.get_scale()
	list.position = xf.origin
	list.size = size


## GameObject.SetActive for the list's own objects (an inactive object is hidden and, where the
## importer says so with the process mode, not processing).
static func _set_active(c: Control, on: bool) -> void:
	c.visible = on
	if on:
		if c.process_mode == Node.PROCESS_MODE_DISABLED:
			c.process_mode = Node.PROCESS_MODE_INHERIT
	else:
		c.process_mode = Node.PROCESS_MODE_DISABLED


## RectTransformUtility.FlipLayoutOnAxis(rect, axis, false, false)
static func _flip(rect: Control, axis: int) -> void:
	var v: Dictionary = RT.values(rect)
	var pivot: Vector2 = v["pivot"]
	pivot[axis] = 1.0 - pivot[axis]
	var pos: Vector2 = v["anchored_position"]
	pos[axis] = -pos[axis]
	var amin: Vector2 = v["anchor_min"]
	var amax: Vector2 = v["anchor_max"]
	var low: float = amin[axis]
	amin[axis] = 1.0 - amax[axis]
	amax[axis] = 1.0 - low
	RT.set_values(rect, {"pivot": pivot, "anchored_position": pos, "anchor_min": amin, "anchor_max": amax})


## Dropdown.Hide
func hide() -> void:
	if _list != null and is_instance_valid(_list):
		_list.queue_free()
	if _blocker != null and is_instance_valid(_blocker):
		_blocker.queue_free()
	_list = null
	_blocker = null


## The blocker is a Button over the whole canvas: a click closes the list, and nothing behind it
## gets the pointer (the wheel included).
func _on_blocker(event: InputEvent, blocker: Control) -> void:
	if event is InputEventMouseButton:
		blocker.accept_event()   # (the release still arrives at a blocker that is being freed)
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			hide()


## Dropdown.OnSelectItem: the item's toggle was switched on (or pressed again).
func _on_item(_on: bool, index: int) -> void:
	var changed: bool = _host.selected != index
	_host.select(index)
	refresh_caption(_host)
	hide()
	if changed:
		_host.item_selected.emit(index)
