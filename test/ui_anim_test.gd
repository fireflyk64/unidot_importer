# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# SPDX-License-Identifier: MIT
extends SceneTree
## Animator clips that animate RectTransforms, on the imported UI fixture (tests/unity_ui of
## udon2godot: the "Animated" canvas, 400 x 200 units at 0.001, centre at Unity (10.2, 3, 2)):
##   godot --headless --path <project> -s addons/unidot_importer/test/ui_anim_test.gd -- --scene res://X.tscn
## "Track" (200 x 40 at (0, 40)) has an Animator and a child "Knob" (40 x 40, at -70); the clips
## KnobLeft / KnobRight put the knob's anchored position at -70 / 70, KnobSlide moves it from
## -70 to 70 (and y 0 to 10) in a second while its width grows from 40 to 60 and its scale to 2;
## the controller has a state for each (Left, Right, Slide) and switches Left / Right by the bool
## "On" over 0.25 s.

const RT := preload("../runtime/rect_transform.gd")
const Graphic := preload("../runtime/ui_graphic.gd")
const UiText := preload("../runtime/ui_text.gd")

var _checks: int = 0
var _failed: int = 0


func ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		print("   FAIL " + what)


func near(a, b, what: String, eps: float = 0.01) -> void:
	var good: bool = false
	if a is Vector2 and b is Vector2:
		good = (a - b).length() <= eps
	elif a is Color and b is Color:
		good = absf(a.r - b.r) <= eps and absf(a.g - b.g) <= eps and absf(a.b - b.b) <= eps and absf(a.a - b.a) <= eps
	elif a is Vector3 and b is Vector3:
		good = (a - b).length() <= eps
	else:
		good = absf(float(a) - float(b)) <= eps
	ok(good, "%s: got %s, expected %s" % [what, str(a), str(b)])


func _find(n: Node, name: String) -> Node:
	if String(n.name) == name:
		return n
	for c in n.get_children():
		var f: Node = _find(c, name)
		if f != null:
			return f
	return null


func _frames(count: int) -> void:
	for _f in range(count):
		await process_frame


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
		push_error("ui_anim_test: cannot load the scene " + str(args.get("scene", "")))
		quit(2)
		return
	var scene: Node = ps.instantiate()
	root.add_child(scene)
	await _frames(10)
	var holder: Node = _find(scene, "Animated")
	var canvas: Control = RT.root_control(holder) if holder != null else null
	ok(canvas != null, "the Animated canvas of the fixture")
	if canvas == null:
		_done()
		return
	var track: Control = canvas.get_node_or_null("Track") as Control
	var knob: Control = track.get_node_or_null("Knob") as Control if track != null else null
	var other: Control = canvas.get_node_or_null("OtherTrack/Knob") as Control
	var player: AnimationPlayer = track.get_node_or_null("AnimationPlayer") as AnimationPlayer if track != null else null
	var tree: AnimationTree = track.get_node_or_null("AnimationTree") as AnimationTree if track != null else null
	ok(knob != null and other != null and player != null and tree != null, "Track has its knob, an AnimationPlayer and an AnimationTree: %s %s %s" % [str(knob), str(player), str(tree)])
	if knob == null or player == null or tree == null:
		_done()
		return
	ok(knob.get_node_or_null("UnidotRect") != null, "the animated RectTransform has the helper its tracks drive")
	# (the library names a clip after the state that plays it)
	ok(player.has_animation("Left") and player.has_animation("Right") and player.has_animation("Slide"), "the controller's clips: " + str(player.get_animation_list()))
	# every track of the clips leads somewhere
	var lost: Array = []
	for clip in player.get_animation_list():
		var anim: Animation = player.get_animation(clip)
		for t in range(anim.get_track_count()):
			var path: NodePath = anim.track_get_path(t)
			var target: Node = player.get_node(player.root_node).get_node_or_null(NodePath(path.get_concatenated_names()))
			if target == null or target.get(path.get_subname(0)) == null:
				lost.append("%s: %s" % [clip, str(path)])
	ok(lost.is_empty(), "every track has its node and property: " + str(lost))
	# the controller starts in Left and plays it: the pose comes back when something else moves
	# the knob (the scene has it there to begin with)
	await _frames(5)
	near(RT.anchored_position(knob), Vector2(-70, 0), "the default state holds the knob on the left")
	RT.set_anchored_position(knob, Vector2(-10, 20))
	await _frames(5)
	near(RT.anchored_position(knob), Vector2(-70, 0), "... and keeps holding it: the default state is played from the start")
	tree.set("metadata/On", true)
	await create_timer(0.6).timeout
	await _frames(2)
	near(RT.anchored_position(knob), Vector2(70, 0), "On: the knob is on the right")
	# 70 units right of the track's centre, on a canvas of 0.001 at (10.2, 3, 2), the track 40 up
	near(RT.drawn_point(knob, knob.size * 0.5), Vector3(10.2 + 0.07, 3.04, 2), "... and is drawn there", 0.002)
	near(RT.anchored_position(other), Vector2(-70, 0), "the other object with the same controller is not moved")
	tree.set("metadata/On", false)
	await create_timer(0.1).timeout
	var mid: float = RT.anchored_position(knob).x
	ok(mid > -69.0 and mid < 69.0, "in the transition the knob is between the two poses: %s" % str(mid))
	await create_timer(0.6).timeout
	await _frames(2)
	near(RT.anchored_position(knob), Vector2(-70, 0), "off again: back on the left")
	# a clip with keys over time, sampled by hand (the tree is switched off for it)
	tree.active = false
	player.play("Slide")
	player.pause()
	player.seek(0.5, true)
	await _frames(2)
	near(RT.anchored_position(knob), Vector2(0, 5), "the sliding clip at 0.5 s: half way")
	near(RT.size_delta(knob), Vector2(50, 40), "... its width half grown (the height is not animated)")
	near(RT.local_scale(knob), Vector3(1.5, 1.5, 1), "... its scale half grown")
	near(knob.size * knob.scale, Vector2(75, 60), "... the Control shows it")
	player.seek(1.0, true)
	await _frames(2)
	near(RT.anchored_position(knob), Vector2(70, 10), "the sliding clip at its end")
	near(RT.drawn_point(knob, Vector2.ZERO), Vector3(10.2 + 0.07 - 0.06, 3.04 + 0.01 + 0.04, 2), "... its top-left corner (60 x 40 at twice its scale)", 0.002)
	await _component_curves(scene)
	await _transitions(scene)
	_sprite_assets(scene)
	_done()


## A Sprite that is an asset of its own (Packed.asset: 32 x 32 in the right half of the sheet,
## borders 4 / 6 / 8 / 10 for left / bottom / right / top) is the part of its texture it was
## packed into.
func _sprite_assets(scene: Node) -> void:
	var holder: Node = _find(scene, "Mixed")
	var canvas: Control = RT.root_control(holder) if holder != null else null
	var packed: TextureRect = canvas.get_node_or_null("Packed") as TextureRect if canvas != null else null
	var sliced: Control = canvas.get_node_or_null("PackedSliced") as Control if canvas != null else null
	ok(packed != null and sliced != null, "the Images with the Sprite asset")
	if packed == null or sliced == null:
		return
	var tex: AtlasTexture = packed.texture as AtlasTexture
	ok(tex != null and tex.region == Rect2(32, 0, 32, 32), "a Sprite asset shows the rect of the texture it was packed into: " + str(tex.region if tex != null else packed.texture))
	var drawing: Dictionary = Graphic.state(sliced).get("sprite", {})
	ok(drawing.get("border", []) == [4.0, 10.0, 8.0, 6.0], "... a sliced Image has its border (left, top, right, bottom): " + str(drawing.get("border")))
	near(float(drawing.get("unit", 0.0)), 2.0, "... at its pixels per unit (50 on a canvas of 100: two units a pixel)")


## The pointer, as the viewport of `c` receives it: moved to the middle of `c` (or off the
## canvas), the left button pressed or released there.
func _point(c: Control, on: bool = true) -> Vector2:
	var p: Vector2 = c.get_global_transform_with_canvas() * (c.size * 0.5) if on else Vector2(-50, -50)
	var move := InputEventMouseMotion.new()
	move.position = p
	move.global_position = p
	c.get_viewport().push_input(move, true)
	return p


func _button(c: Control, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	ev.position = _point(c)
	ev.global_position = ev.position
	c.get_viewport().push_input(ev, true)


func _region_x(c: Control) -> float:
	var tex: Texture2D = (c as TextureRect).texture if c is TextureRect else Graphic.state(c).get("texture")
	return (tex as AtlasTexture).region.position.x if tex is AtlasTexture else -1.0


## The "Transitions" canvas: what a Selectable does over time, driven by the pointer. BtnSwap
## shows the left sprite of the sheet and the right one while highlighted (BtnSwapOff, not
## interactable, its disabled sprite: the right one); BtnFade's tint goes to red in 0.2 s;
## BtnAnim's Animator scales it to 1.2 (highlighted) and 0.9 (pressed) by triggers;
## ToggleFade's check mark fades in 0.1 s.
func _transitions(scene: Node) -> void:
	var holder: Node = _find(scene, "Transitions")
	var canvas: Control = RT.root_control(holder) if holder != null else null
	ok(canvas != null, "the Transitions canvas of the fixture")
	if canvas == null:
		return
	var swap: Control = canvas.get_node("BtnSwap")
	var swap_off: Control = canvas.get_node("BtnSwapOff")
	var fade: Control = canvas.get_node("BtnFade")
	var anim: Control = canvas.get_node("BtnAnim")
	var toggle: BaseButton = canvas.get_node("ToggleFade")
	var mark: Control = toggle.get_node("Background/Checkmark")
	# sprite swap
	near(_region_x(swap), 0.0, "sprite swap at rest: the Image's own sprite (the left of the sheet)")
	near(_region_x(swap_off), 32.0, "... a button that is not interactable shows its disabled sprite")
	_point(swap)
	await _frames(3)
	near(_region_x(swap), 32.0, "the pointer over it: the highlighted sprite")
	_point(swap, false)
	await _frames(3)
	near(_region_x(swap), 0.0, "... and its own again when the pointer leaves")
	# colour tint over fadeDuration
	near(Graphic.renderer_color(fade).g, 1.0, "colour tint at rest: the normal colour")
	_point(fade)
	var green: float = Graphic.renderer_color(fade).g
	ok(is_equal_approx(green, 1.0) and Graphic.fade_of(fade) != null, "the pointer over it: the tint starts to fade from where it is: %s" % str(green))
	await create_timer(0.1).timeout
	green = Graphic.renderer_color(fade).g
	ok(green < 0.999, "... is on its way after 0.1 s: %s" % str(green))
	await create_timer(0.35).timeout
	near(Graphic.renderer_color(fade), Color(1, 0, 0, 1), "... and there after fadeDuration (0.2 s)")
	near(Graphic.drawn_color(fade), Color(1, 0, 0, 1), "... which is what is drawn")
	_point(fade, false)
	await create_timer(0.3).timeout
	near(Graphic.renderer_color(fade), Color(1, 1, 1, 1), "... back to normal after the pointer left")
	# animation transition
	var tree: AnimationTree = anim.get_node_or_null("AnimationTree") as AnimationTree
	ok(tree != null and tree.active, "the animated button has its Animator")
	near(RT.local_scale(anim), Vector3.ONE, "animation transition at rest: the Normal state")
	_point(anim)
	await create_timer(0.4).timeout
	near(RT.local_scale(anim), Vector3(1.2, 1.2, 1), "the pointer over it: the Highlighted trigger plays its state")
	ok(tree != null and tree.get_meta("Highlighted", false) == false, "... and the trigger is used up")
	_button(anim, true)
	await create_timer(0.4).timeout
	near(RT.local_scale(anim), Vector3(0.9, 0.9, 1), "pressed: the Pressed state")
	_button(anim, false)
	_point(anim, false)
	await create_timer(0.5).timeout
	# (Unity's EventSystem keeps a clicked button selected until something else is)
	near(RT.local_scale(anim), Vector3(1.2, 1.2, 1), "released and left: the button stays selected (the Selected state)")
	anim.release_focus()
	await create_timer(0.5).timeout
	near(RT.local_scale(anim), Vector3.ONE, "... and is Normal again when the selection goes elsewhere")
	# the Toggle's check mark
	near(Graphic.renderer_color(mark).a, 0.0, "a toggle that is off: no check mark")
	_button(toggle, true)
	_button(toggle, false)
	var alpha: float = Graphic.renderer_color(mark).a
	ok(toggle.button_pressed and is_zero_approx(alpha) and Graphic.fade_of(mark) != null, "clicked: on, the mark starts to fade in: %s" % str(alpha))
	await create_timer(0.3).timeout
	near(Graphic.renderer_color(mark).a, 1.0, "... and is shown after 0.1 s")
	_point(toggle, false)


## The "AnimatedUi" canvas (500 x 300 at Unity (11.4, 3, 2)): the panel "Show" has an Animator
## whose states play one clip each. Turn: Dial turns 90 degrees about z and grows to twice its
## scale, the plain Transform "Holder" moves from (-80, 90) to (-40, 70): curves without a class
## id (m_EulerCurves, m_ScaleCurves, m_PositionCurves). Fade: fields of components. Frames: the
## sprite of an Image. Each is sampled by hand.
func _component_curves(scene: Node) -> void:
	var holder: Node = _find(scene, "AnimatedUi")
	var canvas: Control = RT.root_control(holder) if holder != null else null
	var show: Control = canvas.get_node_or_null("Show") as Control if canvas != null else null
	var player: AnimationPlayer = show.get_node_or_null("AnimationPlayer") as AnimationPlayer if show != null else null
	var tree: AnimationTree = show.get_node_or_null("AnimationTree") as AnimationTree if show != null else null
	ok(player != null and tree != null, "the Show panel of the AnimatedUi canvas has its player and tree")
	if player == null or tree == null:
		return
	ok(player.has_animation("Turn") and player.has_animation("Fade") and player.has_animation("Frames"), "its clips: " + str(player.get_animation_list()))
	var lost: Array = []
	for clip in player.get_animation_list():
		var anim: Animation = player.get_animation(clip)
		for t in range(anim.get_track_count()):
			var path: NodePath = anim.track_get_path(t)
			var target: Node = player.get_node(player.root_node).get_node_or_null(NodePath(path.get_concatenated_names()))
			if target == null or (path.get_subname_count() > 0 and not (String(path.get_subname(0)) in target)):
				lost.append("%s: %s" % [clip, str(path)])
	ok(lost.is_empty(), "every track has its node and property: " + str(lost))
	var dial: Control = show.get_node("Dial")
	var plain: Control = show.get_node("Holder")
	var held: Control = plain.get_node("Held")
	var label: Control = show.get_node("Label")
	var bar: Control = show.get_node("Bar")
	var group: Control = show.get_node("Group")
	var blink: Control = show.get_node("Blink")
	var hide: Control = show.get_node("Hide")
	var level: Range = show.get_node("Level")
	var check: BaseButton = show.get_node("Check")
	var go: BaseButton = show.get_node("Go")
	var icon: TextureRect = show.get_node("Icon")
	await _frames(3)
	near(RT.local_scale(dial), Vector3.ONE, "at rest nothing has changed: the dial's scale")
	near(Graphic.drawn_color(blink).a, 1.0, "... Blink is drawn")
	tree.active = false
	# rotation, scale and position
	player.play("Turn")
	player.pause()
	player.seek(0.5, true)
	await _frames(2)
	near(RT.local_rotation(dial).get_euler().z, deg_to_rad(45.0), "Turn at 0.5 s: the dial is turned 45 degrees about z")
	near(RT.local_scale(dial), Vector3(1.5, 1.5, 1), "... and scaled by 1.5")
	near(RT.anchored_position(dial), Vector2(-180, 90), "... where it was (no curve moves it)")
	near(dial.scale, Vector2(1.5, 1.5), "... the Control shows the scale")
	near(absf(dial.rotation), deg_to_rad(45.0), "... and the rotation")
	near(RT.local_position(plain), Vector3(-60, 80, 0), "... the plain Transform is half way")
	near(RT.drawn_point(held, held.size * 0.5), Vector3(11.4 - 0.06, 3.08, 2), "... and what it holds is drawn there", 0.002)
	player.seek(1.0, true)
	await _frames(2)
	near(RT.local_rotation(dial).get_euler().z, deg_to_rad(90.0), "Turn at its end: 90 degrees")
	# Unity's z rotation is counter-clockwise: the dial's local +x (right) points up on the canvas
	near(RT.drawn_point(dial, Vector2(dial.size.x, dial.size.y * 0.5)) - RT.drawn_point(dial, dial.size * 0.5), Vector3(0, 0.06, 0), "... its right edge is above its centre (60 units at twice the scale: 0.06)", 0.002)
	near(RT.local_position(plain), Vector3(-40, 70, 0), "... the plain Transform has arrived")
	# fields of components
	player.play("Fade")
	player.pause()
	player.seek(0.5, true)
	await _frames(2)
	near(Graphic.color(dial).a, 0.5, "Fade at 0.5 s: the Image's alpha")
	near(Graphic.color(dial).r, 0.75, "... and red")
	near(Graphic.color(label).a, 0.75, "... the text's alpha")
	near(UiText.font_size(label), 30.0, "... its font size")
	near(float((Graphic.state(bar).get("sprite", {}) as Dictionary).get("amount", -1.0)), 0.5, "... the fill amount")
	near(group.modulate.a, 0.75, "... the CanvasGroup's alpha fades what is in it")
	near(level.value, 0.5, "... the Slider's value")
	player.seek(0.25, true)
	await _frames(2)
	ok(Graphic.enabled(blink) and hide.visible and not check.button_pressed and not go.disabled, "Fade at 0.25 s: the switches are as they were")
	player.seek(0.75, true)
	await _frames(2)
	ok(not Graphic.enabled(blink) and is_zero_approx(Graphic.drawn_color(blink).a) and blink.visible, "Fade at 0.75 s: the Image component is disabled (its object is not hidden)")
	ok(not hide.visible, "... the object whose m_IsActive went to 0 is hidden")
	await create_timer(0.2).timeout   # (the check mark fades in)
	ok(check.button_pressed and is_equal_approx(Graphic.drawn_color(check.get_node("Mark")).a, 1.0), "... the Toggle is on and shows its check mark")
	ok(go.disabled, "... the Button is not interactable")
	# the sprite of an Image
	var left: Texture2D = icon.texture
	player.play("Frames")
	player.pause()
	player.seek(0.25, true)
	await _frames(2)
	ok(icon.texture is AtlasTexture and (icon.texture as AtlasTexture).region.position.x < 1.0, "Frames at 0.25 s: the first sprite of the sheet: " + str(icon.texture))
	player.seek(0.75, true)
	await _frames(2)
	ok(icon.texture is AtlasTexture and is_equal_approx((icon.texture as AtlasTexture).region.position.x, 32.0) and left != null, "Frames at 0.75 s: the second sprite (its rect starts at 32)")


func _done() -> void:
	print("[ui_anim_test] %d checks, %d failure(s)" % [_checks, _failed])
	print("ANIMATION TESTS " + ("PASSED" if _failed == 0 else "FAILED"))
	quit(0 if _failed == 0 else 1)
