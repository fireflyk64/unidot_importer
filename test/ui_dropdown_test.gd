# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# SPDX-License-Identifier: MIT
extends SceneTree
## Opens the dropdowns of the imported UI fixture (tests/unity_ui of udon2godot: the "Widgets"
## canvas, 800 x 600 units) and checks the list Unity's Dropdown.Show builds from the template:
##   godot --headless --path <project> -s addons/unidot_importer/test/ui_dropdown_test.gd -- --scene res://X.tscn
## Expected numbers are Unity's, worked out by hand: the dropdowns are 160 x 30 with a template of
## 160 x 150 hanging 2 below, items of 20 with 4 above and below them.

const RT := preload("../runtime/rect_transform.gd")
const Dropdown := preload("../runtime/dropdown.gd")
const Graphic := preload("../runtime/ui_graphic.gd")

var _checks: int = 0
var _failed: int = 0


func ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		print("   FAIL " + what)


func near(a: Vector2, b: Vector2, what: String, eps: float = 0.6) -> void:
	ok(absf(a.x - b.x) <= eps and absf(a.y - b.y) <= eps, "%s: got %s, expected %s" % [what, str(a), str(b)])


func _find(n: Node, name: String) -> Node:
	if String(n.name) == name:
		return n
	for c in n.get_children():
		var f: Node = _find(c, name)
		if f != null:
			return f
	return null


## Rect of a control in the coordinates of the canvas root (origin top-left, y down).
func _in(canvas: Control, c: Control) -> Rect2:
	var xf: Transform2D = canvas.get_global_transform().affine_inverse() * c.get_global_transform()
	return Rect2(xf * Vector2.ZERO, xf.basis_xform(c.size))


## A left click as the viewport of `c` receives it (motion, press, release), at a point of its rect.
func _click(c: Control, at: Vector2 = Vector2(0.5, 0.5)) -> void:
	var vp: Viewport = c.get_viewport()
	var p: Vector2 = c.get_global_transform_with_canvas() * (c.size * at)
	var move := InputEventMouseMotion.new()
	move.position = p
	move.global_position = p
	vp.push_input(move, true)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		ev.position = p
		ev.global_position = p
		vp.push_input(ev, true)
	for _f in range(4):
		await process_frame


var _shots: String = ""

## With --shots <dir> on a display: a picture of the canvas as it is now.
func _shot(canvas: Control, name: String) -> void:
	if _shots.is_empty() or DisplayServer.get_name() == "headless":
		return
	var vp: Viewport = canvas.get_viewport()
	if vp is SubViewport:
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_shots)
	vp.get_texture().get_image().save_png(_shots.path_join(name + ".png"))


func _init() -> void:
	var args: Dictionary = {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < raw.size():
		if raw[i].begins_with("--") and i + 1 < raw.size():
			args[raw[i].substr(2)] = raw[i + 1]
			i += 1
		i += 1
	_shots = str(args.get("shots", ""))
	var ps = load(str(args.get("scene", "")))
	if ps == null:
		push_error("ui_dropdown_test: cannot load the scene " + str(args.get("scene", "")))
		quit(2)
		return
	var scene: Node = ps.instantiate()
	root.add_child(scene)
	for _f in range(10):
		await process_frame
	var holder: Node = _find(scene, "Widgets")
	var canvas: Control = RT.root_control(holder) if holder != null else null
	ok(canvas != null, "the Widgets canvas of the fixture")
	if canvas == null:
		_done()
		return

	# three options, the second selected: the list hangs below the button, as high as its items
	var dd: OptionButton = _find(canvas, "Dropdown") as OptionButton
	var helper: Node = dd.get_node_or_null(Dropdown.HELPER) if dd != null else null
	ok(dd != null and helper != null and dd.item_count == 3 and dd.selected == 1, "Dropdown imported with its options, value and helper")
	var selected: Array = []
	dd.item_selected.connect(func(v: int) -> void: selected.append(v))
	await _click(dd)
	var list: Control = canvas.get_node_or_null(Dropdown.LIST) as Control
	ok(list != null and helper.is_shown(), "a click puts the list on top of the canvas")
	ok(not dd.get_popup().visible, "... and the OptionButton's own popup stays closed")
	await _shot(canvas, "dropdown_open")
	if list != null:
		near(_in(canvas, list).size, Vector2(160, 68), "the list is as wide as the button and as high as three items of 20 with 4 above and below")
		near(_in(canvas, list).position, Vector2(20, 363), "... 2 below the button (which ends at 365 from the top; the template overlaps by 2)")
		ok(canvas.get_child(canvas.get_child_count() - 1) == list and canvas.get_child(canvas.get_child_count() - 2).name == &"Blocker", "... as the last control of the canvas, the blocker behind it")
		var content: Control = _find(list, "Content") as Control
		var items: Array = []
		for c in content.get_children():
			if c is BaseButton and c.visible:
				items.append(c)
		# (Unity's name is "Item 0: Option A"; a node name cannot hold the colon)
		ok(items.size() == 3 and String(items[0].name) == "Item 0_ Option A", "one item per option, named like Unity's: " + str(items.map(func(x): return x.name)))
		if items.size() == 3:
			for k in range(3):
				near(_in(canvas, items[k]).position, Vector2(20, 363 + 4 + 20 * k), "item %d from the top" % k)
				near(_in(canvas, items[k]).size, Vector2(160, 20), "item %d spans the list (no scrollbar is needed)" % k)
				var label: RichTextLabel = items[k].get_node_or_null("Item Label") as RichTextLabel
				ok(label != null and label.get_parsed_text() == dd.get_item_text(k), "item %d shows its option's text" % k)
				var mark: Control = items[k].get_node_or_null("Item Checkmark") as Control
				ok(mark != null and is_equal_approx(Graphic.drawn_color(mark).a, 1.0 if k == 1 else 0.0), "the check mark is on the selected item only (item %d)" % k)
			var bar: Control = _find(list, "Scrollbar") as Control
			ok(bar != null and not bar.visible, "the list's scrollbar hides when everything fits")
			var template: Control = Dropdown.part(dd, "template") as Control
			ok(template != null and not template.visible and template != list, "the template itself stays inactive")
			# picking the third item: value, caption, event, list closed
			await _click(items[2])
			ok(dd.selected == 2 and selected == [2], "picking an item sets the value and raises onValueChanged once: %d %s" % [dd.selected, str(selected)])
			var caption: RichTextLabel = Dropdown.part(dd, "caption") as RichTextLabel
			ok(caption != null and caption.get_parsed_text() == "Option C", "... the caption shows it")
			ok(not helper.is_shown() and canvas.get_node_or_null(Dropdown.LIST) == null and canvas.get_node_or_null(Dropdown.BLOCKER) == null, "... and the list and its blocker are gone")

	# ten options: the list keeps the template's height and scrolls
	var long: OptionButton = _find(canvas, "DropdownLong") as OptionButton
	var long_helper: Node = long.get_node(Dropdown.HELPER)
	long_helper.show()
	for _f in range(6):
		await process_frame
	list = canvas.get_node_or_null(Dropdown.LIST) as Control
	ok(list != null, "the long dropdown's list")
	if list != null:
		near(_in(canvas, list).size, Vector2(160, 150), "ten items do not fit: the list keeps the template's height")
		var long_content: Control = _find(list, "Content") as Control
		near(RT.rect_size(long_content), Vector2(143, 208), "the content holds ten items (208) in a viewport that gave way to the scrollbar (160 - 20 + 3)")
		var long_bar: Control = _find(list, "Scrollbar") as Control
		ok(long_bar != null and long_bar.visible, "... whose scrollbar is shown")
		# the blocker closes the list
		await _shot(canvas, "dropdown_long")
		# the wheel over the list scrolls it
		var before: float = RT.anchored_position(long_content).y
		for down in [true, false]:
			var wheel := InputEventMouseButton.new()
			wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
			wheel.pressed = down
			wheel.factor = 1.0
			wheel.position = list.get_global_transform_with_canvas() * (list.size * 0.5)
			wheel.global_position = wheel.position
			list.get_viewport().push_input(wheel, true)
		for _f in range(3):
			await process_frame
		ok(RT.anchored_position(long_content).y > before + 0.5, "the wheel scrolls the list: content at %s, was %s" % [str(RT.anchored_position(long_content).y), str(before)])
		# the blocker closes the list: a click on the canvas beside it
		var blocker: Control = canvas.get_node_or_null(Dropdown.BLOCKER) as Control
		near(_in(canvas, blocker).size, canvas.size, "the blocker covers the canvas")
		# (the point is on the BtnPlain button, which must not get the click)
		var behind: BaseButton = _find(canvas, "BtnPlain") as BaseButton
		var pressed: Array = []
		behind.pressed.connect(func() -> void: pressed.append(1))
		await _click(behind)
		ok(pressed.is_empty(), "a click beside the list does not reach what is behind the blocker")
		ok(not long_helper.is_shown() and long.selected == 0, "a click beside the list closes it without changing the value")

	# at the lower edge of the canvas the list opens upwards
	var low: OptionButton = _find(canvas, "DropdownLow") as OptionButton
	await _click(low)
	list = canvas.get_node_or_null(Dropdown.LIST) as Control
	ok(list != null, "the low dropdown's list")
	if list != null:
		near(_in(canvas, list).size, Vector2(160, 48), "two items")
		near(_in(canvas, list).position, Vector2(340, 524), "a list that would leave the canvas is flipped above the button (which starts at 570; 2 of overlap)")
		await _shot(canvas, "dropdown_low")
		# a second click on the button closes it
		await _click(low)
		ok(not low.get_node(Dropdown.HELPER).is_shown(), "a click on the open dropdown's button reaches the blocker and closes the list")
	_done()


func _done() -> void:
	print("[ui_dropdown_test] %d checks, %d failure(s)" % [_checks, _failed])
	print("DROPDOWN TESTS " + ("PASSED" if _failed == 0 else "FAILED"))
	quit(0 if _failed == 0 else 1)
