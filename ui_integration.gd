# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## Unity UI (uGUI and TextMeshPro) → Godot Controls.
##
## A built-in importer plugin (same hooks as vrm_integration.gd), enabled by the database's
## `convert_ui` flag. GameObjects with a RectTransform become Controls laid out by
## runtime/rect_transform.gd; a Canvas below a plain Transform becomes a world canvas (Node3D
## holder + SubViewport + plane) or, in a screen-space render mode, a CanvasLayer scaled like
## Unity's CanvasScaler. Components configure the Control of their GameObject: graphics (Image,
## RawImage, Text, TextMeshProUGUI), selectables (Button, Toggle, Slider, Scrollbar, InputField,
## Dropdown), ScrollRect, masks, layout groups and fitters, effects.
##
## Nothing here knows about scripting. UnityEvent persistent calls (Button.onClick ...) are handed
## to the other enabled plugins through their optional hook
##   ui_unity_event(event: Dictionary, source: Control, signal_name: String, unbinds: int, state, obj)
## and plugins may name further UI component scripts with
##   ui_component_kind(guid: String, keys: Dictionary, file_id: int) -> String   ("" = not UI)

const RT := preload("./runtime/rect_transform.gd")
const canvas_scaler_script := preload("./runtime/canvas_scaler.gd")
const layout_group_script := preload("./runtime/layout_group.gd")
const scroll_rect_script := preload("./runtime/scroll_rect.gd")
const dropdown_script := preload("./runtime/dropdown.gd")

## Unity UI / TextMeshPro component scripts by GUID.
const UI_COMPONENTS := {
	"fe87c0e1cc204ed48ad3b37840f39efc": "Image",
	"1344c3c82d62a2a41a3576d8abb8e3ea": "RawImage",
	"5f7201a12d95ffc409449d95f23cf332": "Text",
	"4e29b1a8efbd4b44bb3f3716e73f07ff": "Button",
	"9085046f02f69544eb97fd06b6048fe2": "Toggle",
	"67db9e8f0e2ae9c40bc1e2b64352a6b4": "Slider",
	"2a4db7a114972834c8e4117be1d82ba3": "Scrollbar",
	"d199490a83bb2b844b9695cbf13b01ef": "InputField",
	"0d1c2a8fe1a7b7a4d9edbdc6bf0d0d5b": "Dropdown",
	"1aa08ab6e0800fa44ae55d278d1423e3": "ScrollRect",
	"0cd44c1031e13a943bb63640046fad76": "CanvasScaler",
	"dc42784cf147c0c48a680349fa168899": "GraphicRaycaster",
	"31a19414c41e5ae4aae2af33fee712f6": "Mask",
	"3312d7739989d2b4e91e6319e9a96d76": "RectMask2D",
	"306cc8c2b49d7114eaa3623786fc2126": "LayoutElement",
	"30649d3a9faa99c48a7b1166b86bf2a0": "HorizontalLayoutGroup",
	"59f8146938fff824cb5fd77236b75775": "VerticalLayoutGroup",
	"8a8695521f0d02e499659fee002a26c2": "GridLayoutGroup",
	"3245ec927659c4140ac4f8d17403cc18": "ContentSizeFitter",
	"86710e43de46f6f4bac7c8e50813a599": "AspectRatioFitter",
	"e19747de3f5aca642ab2be37e372fb86": "Outline",
	"cfabb0440166ab443bba8876756fdfa9": "Shadow",
	"76c392e42b5098c458856cdf6ecaaaa1": "EventSystem",
	"4f231c4fb786f3946a6b90b886c48677": "StandaloneInputModule",
	"f4688fdb7df04437aeb418b961361dc5": "TextMeshProUGUI",
	"9541d86e2fd84c1d9990edf0852d74ab": "TextMeshPro",
	"2da0c512f12947e489f739169773d7ca": "TMP_InputField",
	"7b743370ac3e4ec2a1668f5455a8ef8a": "TMP_Dropdown",
}

## Unity UI components that decide the Control class of a RectTransform GameObject (first wins).
const UI_PRIMARY_ORDER := ["Button", "Toggle", "Slider", "Scrollbar", "InputField", "TMP_InputField", "Dropdown", "TMP_Dropdown", "ScrollRect", "Text", "TextMeshProUGUI", "Image", "RawImage"]

var database = null
## Counters for import reports.
var stats: Dictionary = {"ui_nodes": 0, "canvases": 0, "unresolved": []}
var _pending: Array = []   # {owner, node, meta_key, cfg_key, ref, meta}


func set_database(db) -> void:
	database = db


# ---------------------------------------------------------------------------------------------
# importer plugin hooks
# ---------------------------------------------------------------------------------------------

func handle_monobehaviour(obj: RefCounted, state: RefCounted, node: Node, _existing: Node):
	if node == null:
		return null
	var guid: String = str(obj.monoscript[2]) if obj.monoscript[2] != null else ""
	var kind: String = identify(guid, obj.keys, _to_int(obj.monoscript[1]), obj.meta)
	var ctl: Control = control_of(node)
	if ctl == null:
		if kind == "TextMeshPro" and node is Node3D:
			_text_mesh_3d(obj, state, node)
		return null
	if kind != "":
		configure_component(kind, obj, state, ctl)
	return null


## TextMeshPro (the 3D text, on a GameObject outside any canvas) becomes a Label3D. The font
## size of a 3D text is in tenths of a unit per em; the text box is the object's RectTransform.
func _text_mesh_3d(obj: RefCounted, state: RefCounted, node: Node3D) -> void:
	var keys: Dictionary = obj.keys
	var label := Label3D.new()
	label.name = "TextMeshPro"
	label.text = _strip_tags(str(keys.get("m_text", "")) if keys.get("m_text") != null else "")
	var size: float = maxf(_to_float(keys.get("m_fontSize", 36.0)), 0.01)
	label.font_size = 64
	label.outline_size = 0
	label.pixel_size = size / 10.0 / 64.0
	if keys.get("m_fontColor") is Color:
		label.modulate = keys["m_fontColor"]
	var rect: Vector2 = Vector2.ZERO
	var pivot: Vector2 = Vector2(0.5, 0.5)
	var go = obj.gameObject
	if go != null and go.transform != null:
		var tk: Dictionary = go.transform.keys
		if tk.get("m_SizeDelta") is Vector2:
			rect = tk["m_SizeDelta"]
		if tk.get("m_Pivot") is Vector2:
			pivot = tk["m_Pivot"]
	var x: float = 0.5
	match _to_int(keys.get("m_HorizontalAlignment", 1)):
		1:
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			x = 0.0
		4:
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			x = 1.0
		8:
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_FILL
			x = 0.0
		_:
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var y: float = 0.5
	match _to_int(keys.get("m_VerticalAlignment", 256)):
		256:
			label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
			y = 1.0
		1024:
			label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
			y = 0.0
		_:
			label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if rect.x > 0.0 and _to_int(keys.get("m_enableWordWrapping", 0)) != 0:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.width = rect.x / label.pixel_size
	# readable from the object's -z side like every Unity text; x is mirrored in the Godot scene
	label.transform = Transform3D(Basis.from_euler(Vector3(0.0, PI, 0.0)), Vector3(-(x - pivot.x) * rect.x, (y - pivot.y) * rect.y, 0.0))
	state.add_child(label, node, obj)
	stats["text_3d"] = int(stats.get("text_3d", 0)) + 1


static func _strip_tags(s: String) -> String:
	var re := RegEx.new()
	re.compile("<[^>]*>")
	return re.sub(s, "", true)


func handle_scripted_object(_obj: RefCounted):
	return null


func post_process_avatar(_obj: RefCounted, _state: RefCounted, _node: Node, _avatar_meta: RefCounted):
	pass


func initialize_skelleys(_state: RefCounted, _objs: Array, _is_prefab: bool):
	pass


func setup_post_children(_game_object: RefCounted, _state: RefCounted, node: Node, _avatar_meta: RefCounted):
	# the canvas's controls exist now: size its viewport and plane to what it draws
	if node != null and RT.is_island(node):
		RT.fit_island(node)


func setup_post_prefab(_prefab_object: RefCounted, _state: RefCounted, _instanced_scene: Node):
	pass


func setup_post_scene(pkgasset: RefCounted, _root_objects: Array, _root_skelleys: Array, _state: RefCounted, scene_contents: Node):
	var meta: Resource = pkgasset.parsed_meta
	var remaining: Array = []
	for e in _pending:
		var n = e["node"]
		if not (n is Node) or not is_instance_valid(n):
			continue
		if e["owner"] != scene_contents and not scene_contents.is_ancestor_of(n):
			remaining.append(e)
			continue
		var ref: Array = e["ref"]
		var np: NodePath = meta.fileid_to_nodepath.get(ref[1], meta.prefab_fileid_to_nodepath.get(ref[1], NodePath()))
		var target: Node = scene_contents.get_node_or_null(np) if np != NodePath() else null
		if target == null:
			stats["unresolved"].append({"field": str(e["meta_key"]) + "." + str(e["cfg_key"]), "fileID": ref[1], "node": str(scene_contents.get_path_to(n))})
			continue
		var cfg: Dictionary = n.get_meta(e["meta_key"]) if n.has_meta(e["meta_key"]) else {}
		cfg[e["cfg_key"]] = n.get_path_to(control_of(target) if control_of(target) != null else target)
		n.set_meta(e["meta_key"], cfg)
	_pending = remaining


## The Control of a UI GameObject node: the node itself, or a canvas's root control.
static func control_of(node: Node) -> Control:
	if node is Control:
		return node
	if RT.is_canvas(node):
		return RT.root_control(node)
	return null


## Which Unity UI component is this script? By GUID, by another plugin's word, or, for packages
## that ship their own copy of the UI assembly, by the fields the component serializes.
func identify(guid: String, keys: Dictionary, file_id: int = 0, meta: Resource = null) -> String:
	if UI_COMPONENTS.has(guid):
		return UI_COMPONENTS[guid]
	if meta != null:
		for plugin in meta.get_enabled_plugins():
			if plugin != self and plugin.has_method("ui_component_kind"):
				var k: String = str(plugin.ui_component_kind(guid, keys, file_id))
				if k != "":
					return k
	if keys.has("m_EffectColor") and keys.has("m_EffectDistance"):
		return "Shadow"
	if keys.has("m_AspectMode") and keys.has("m_AspectRatio"):
		return "AspectRatioFitter"
	if keys.has("m_TextComponent") and keys.has("m_CharacterLimit"):
		return "TMP_InputField" if keys.has("m_FontAsset") else "InputField"
	if keys.has("m_CaptionText") and keys.has("m_Options"):
		return "TMP_Dropdown" if keys.has("m_ItemText") and keys.has("m_AlphaFadeSpeed") else "Dropdown"
	if keys.has("m_OnClick") and keys.has("m_Interactable"):
		return "Button"
	if keys.has("m_IsOn") and keys.has("toggleTransition"):
		return "Toggle"
	if keys.has("m_Direction") and keys.has("m_MinValue"):
		return "Slider"
	if keys.has("m_FontData") and keys.has("m_Text"):
		return "Text"
	if keys.has("m_text") and keys.has("m_fontAsset"):
		return "TextMeshProUGUI"
	if keys.has("m_Sprite") and keys.has("m_Type") and keys.has("m_FillMethod"):
		return "Image"
	if keys.has("m_Content") and keys.has("m_Horizontal") and keys.has("m_Vertical"):
		return "ScrollRect"
	if keys.has("m_Texture") and keys.has("m_UVRect"):
		return "RawImage"
	return ""


## The Unity values of a serialized RectTransform (see RT.values).
static func rect_values(keys: Dictionary) -> Dictionary:
	var v: Dictionary = RT._defaults()
	for pair in [["m_AnchorMin", "anchor_min"], ["m_AnchorMax", "anchor_max"], ["m_AnchoredPosition", "anchored_position"], ["m_SizeDelta", "size_delta"], ["m_Pivot", "pivot"]]:
		if keys.get(pair[0]) is Vector2:
			v[pair[1]] = keys[pair[0]]
	if keys.get("m_LocalPosition") is Vector3:
		v["z"] = keys["m_LocalPosition"].z
	if keys.get("m_LocalRotation") is Quaternion:
		v["rotation"] = (keys["m_LocalRotation"] as Quaternion).normalized()
	if keys.get("m_LocalScale") is Vector3:
		v["scale"] = keys["m_LocalScale"]
	return v


## Prefab-instance overrides of a RectTransform (`m_AnchoredPosition.x` ...) as Godot property
## values of `node`. Called by UnidotRectTransform.convert_properties.
static func rect_override_properties(node: Node, uprops: Dictionary) -> Dictionary:
	var v: Dictionary = RT.values(node)
	var changed: bool = false
	for pair in [["m_AnchorMin", "anchor_min"], ["m_AnchorMax", "anchor_max"], ["m_AnchoredPosition", "anchored_position"], ["m_SizeDelta", "size_delta"], ["m_Pivot", "pivot"]]:
		var cur: Vector2 = v[pair[1]]
		if uprops.get(pair[0]) is Vector2:
			cur = uprops[pair[0]]
			changed = true
		for axis in ["x", "y"]:
			if uprops.has(pair[0] + "." + axis):
				cur[axis] = float(uprops[pair[0] + "." + axis])
				changed = true
		v[pair[1]] = cur
	if uprops.has("m_LocalPosition.z"):
		v["z"] = float(uprops["m_LocalPosition.z"])
		changed = true
	elif uprops.get("m_LocalPosition") is Vector3:
		v["z"] = uprops["m_LocalPosition"].z
		changed = true
	var q: Quaternion = v["rotation"]
	if uprops.get("m_LocalRotation") is Quaternion:
		q = uprops["m_LocalRotation"]
		changed = true
	for axis in ["x", "y", "z", "w"]:
		if uprops.has("m_LocalRotation." + axis):
			q[axis] = float(uprops["m_LocalRotation." + axis])
			changed = true
	v["rotation"] = q.normalized() if q.length_squared() > 0.0 else Quaternion.IDENTITY
	var sc: Vector3 = v["scale"]
	if uprops.get("m_LocalScale") is Vector3:
		sc = uprops["m_LocalScale"]
		changed = true
	for axis in ["x", "y", "z"]:
		if uprops.has("m_LocalScale." + axis):
			sc[axis] = float(uprops["m_LocalScale." + axis])
			changed = true
	v["scale"] = sc
	if not changed:
		return {}
	var s: Node = RT.store(node)
	if not RT._prefab_rect(s).is_empty():
		return {"metadata/" + String(RT.META_PREFAB_RECT): v}   # the root of a prefab variant
	if s is Control:
		return RT.control_properties(v)
	var out: Dictionary = {"metadata/" + String(RT.META_RECT): v}
	if s is Node3D and not RT.is_nested(s):
		var ap: Vector2 = v["anchored_position"]
		out["position"] = Vector3(-ap.x, ap.y, float(v["z"]))
		out["quaternion"] = Quaternion(q.x, -q.y, -q.z, q.w).normalized()
		out["scale"] = RT._safe_scale(sc)
	return out


## GameObjects with a RectTransform become Controls; the class follows the main UI component.
func create_gameobject_node(go: RefCounted, state: RefCounted, new_parent: Node) -> Node:
	var transform = go.transform
	if transform == null or transform.type != "RectTransform":
		return null
	var parent: Node = RT.child_host(new_parent)
	var canvas = go.GetComponent("Canvas")
	if canvas == null and not (parent is Control) and new_parent != null:
		return null   # a RectTransform outside every canvas draws no UI: an ordinary Node3D
	var kinds: Array = []
	var kind_keys: Dictionary = {}
	for component_ref in go.components:
		var component = go.meta.lookup(component_ref.values()[0])
		if component == null or component.type != "MonoBehaviour":
			continue
		var g: String = str(component.monoscript[2]) if component.monoscript[2] != null else ""
		var kind: String = identify(g, component.keys, _to_int(component.monoscript[1]), go.meta)
		if kind != "":
			kinds.append(kind)
			kind_keys[kind] = component.keys
	var primary: String = ""
	for k in UI_PRIMARY_ORDER:
		if kinds.has(k):
			primary = k
			break
	var ctl: Control = _new_control(primary, kind_keys.get(primary, {}))
	var v: Dictionary = rect_values(transform.keys)
	var active: bool = go.enabled if "enabled" in go else true
	if parent is Control or canvas == null:
		# a control of the canvas it is in, or the root of a UI prefab that is instanced under one
		ctl.name = go.name
		state.add_child(ctl, parent, transform)
		if parent == null:
			# the root of a UI prefab: its rect waits for the instance (RT.apply_prefab_rect)
			ctl.set_meta(RT.META_PREFAB_RECT, v)
		else:
			RT.set_values(ctl, v)
		if canvas != null:
			ctl.set_meta(&"unidot_canvas_nested", true)   # a Canvas inside a canvas: a plain container here
		ctl.visible = active
		stats["ui_nodes"] += 1
		return ctl
	# a canvas below a plain Transform, or the root of a canvas prefab
	var holder := Node3D.new()
	holder.name = go.name
	state.add_child(holder, new_parent, transform)
	ctl.name = "Canvas"
	if _to_int(canvas.keys.get("m_RenderMode", 0)) == 2:
		RT.build_island(holder, ctl, v, state.owner)
	else:
		_build_screen_canvas(holder, ctl, v, canvas.keys, kind_keys.get("CanvasScaler", {}), state.owner)
	holder.visible = active
	stats["canvases"] += 1
	return holder


func _new_control(primary: String, keys: Dictionary) -> Control:
	# Unity's Direction: 0 LeftToRight, 1 RightToLeft, 2 BottomToTop, 3 TopToBottom
	var vertical: bool = _to_int(keys.get("m_Direction", 0)) >= 2
	var node: Control
	match primary:
		"Button":
			node = Button.new()
			node.flat = true
		"Toggle":
			node = Button.new()
			node.toggle_mode = true
			node.flat = true
		"Slider":
			node = VSlider.new() if vertical else HSlider.new()
		"Scrollbar":
			# a real scroll bar: scripts find it as a Scrollbar and a ScrollRect links to it
			node = VScrollBar.new() if vertical else HScrollBar.new()
		"InputField", "TMP_InputField":
			node = LineEdit.new()
		"Dropdown", "TMP_Dropdown":
			node = OptionButton.new()
		"ScrollRect":
			node = ScrollContainer.new()
		"Text":
			node = Label.new()
		"TextMeshProUGUI":
			node = RichTextLabel.new()
			node.bbcode_enabled = true
			node.scroll_active = false
			node.fit_content = false
		"Image", "RawImage":
			node = TextureRect.new()
			node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			node.stretch_mode = TextureRect.STRETCH_SCALE
		_:
			node = Control.new()
	if primary in ["Text", "TextMeshProUGUI", "Image", "RawImage"]:
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	elif primary == "":
		node.mouse_filter = Control.MOUSE_FILTER_PASS
	else:
		node.mouse_filter = Control.MOUSE_FILTER_STOP
	_no_minimum_size(node)
	return node


## A Unity rect is as large as its RectTransform says. Godot widgets have a minimum size from
## their theme (a Button 8 x 8, a LineEdit 68 x 31, a slider 16 high): in a canvas whose units are
## metres that is larger than the whole canvas. Empty style boxes take the margins away.
func _no_minimum_size(node: Control) -> void:
	var boxes: Array = []
	if node is Button:   # OptionButton too
		boxes = ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed", "normal_mirrored", "hover_mirrored", "pressed_mirrored", "disabled_mirrored", "hover_pressed_mirrored"]
	elif node is LineEdit:
		boxes = ["normal", "focus", "read_only"]
	elif node is Slider:
		boxes = ["slider", "grabber_area", "grabber_area_highlight"]
	elif node is ScrollBar:
		boxes = ["scroll", "scroll_focus", "grabber", "grabber_highlight", "grabber_pressed"]
	elif node is ScrollContainer:
		boxes = ["panel", "focus"]
	for b in boxes:
		node.add_theme_stylebox_override(b, StyleBoxEmpty.new())
	# Unity draws sliders, scroll bars and dropdown arrows with child objects of its own: the
	# widget's icons would be drawn a second time and give it a minimum size
	var icons: Array = []
	if node is Slider:
		icons = ["grabber", "grabber_highlight", "grabber_disabled", "tick"]
	elif node is ScrollBar:
		icons = ["increment", "increment_highlight", "increment_pressed", "decrement", "decrement_highlight", "decrement_pressed"]
	elif node is OptionButton:
		icons = ["arrow"]
	for i in icons:
		node.add_theme_icon_override(i, _empty_icon())
	if node is OptionButton:
		node.add_theme_constant_override("arrow_margin", 0)
		node.add_theme_constant_override("h_separation", 0)
	if node is LineEdit:
		node.add_theme_constant_override("minimum_character_width", 0)


## A screen-space canvas: CanvasLayer + root control, scaled like Unity's CanvasScaler by
## runtime/canvas_scaler.gd.
func _build_screen_canvas(holder: Node3D, root: Control, v: Dictionary, canvas_keys: Dictionary, scaler_keys: Dictionary, owner: Node) -> void:
	var layer := CanvasLayer.new()
	layer.name = "CanvasLayer"
	layer.layer = _to_int(canvas_keys.get("m_SortingOrder", 0))
	layer.set_meta(RT.META_HELPER, true)
	holder.add_child(layer, true)
	layer.add_child(root, true)
	if owner != null:
		layer.owner = owner
		root.owner = owner
	var ref: Vector2 = scaler_keys.get("m_ReferenceResolution") if scaler_keys.get("m_ReferenceResolution") is Vector2 else Vector2(800, 600)
	var scaler: Dictionary = {
		"mode": _to_int(scaler_keys.get("m_UiScaleMode", 0)),
		"scale_factor": _to_float(scaler_keys.get("m_ScaleFactor", 1.0)),
		"reference_resolution": ref,
		"match_mode": _to_int(scaler_keys.get("m_ScreenMatchMode", 0)),
		"match": _to_float(scaler_keys.get("m_MatchWidthOrHeight", 0.0)),
		"default_dpi": _to_float(scaler_keys.get("m_DefaultSpriteDPI", 96.0)),
	}
	# until the scene runs (the editor): the reference resolution at scale 1
	root.size = ref if scaler["mode"] == 1 else Vector2(ProjectSettings.get_setting("display/window/size/viewport_width", 1152), ProjectSettings.get_setting("display/window/size/viewport_height", 648))
	if root.get_class() == "Control":
		# an invisible full-window container must not swallow the clicks meant for the 3D world
		root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.set_meta(RT.META_CANVAS, {"mode": "overlay", "root": holder.get_path_to(root), "size": root.size, "scaler": scaler})
	holder.set_meta(RT.META_RECT, v)
	layer.set_script(canvas_scaler_script)


## The helper child that runs Unity's auto layout for `ctl` (runtime/layout_group.gd).
## A child, not a script on the Control: that slot is left to the scene's own scripts.
func _ensure_layout_helper(ctl: Control, state: RefCounted) -> void:
	if ctl.get_node_or_null("UnidotLayout") != null:
		return
	var helper := Node.new()
	helper.name = "UnidotLayout"
	helper.set_meta(RT.META_HELPER, true)
	helper.set_script(layout_group_script)
	ctl.add_child(helper)
	helper.owner = state.owner if state.owner != null else ctl


var _no_icon: Texture2D = null

func _empty_icon() -> Texture2D:
	if _no_icon == null:
		_no_icon = PlaceholderTexture2D.new()
		(_no_icon as PlaceholderTexture2D).size = Vector2.ZERO
	return _no_icon


var _white_tex: Texture2D = null

## Shared white texture for graphics that have no sprite (a .tres next to the runtime scripts:
## no import step).
func _white_texture() -> Texture2D:
	if _white_tex == null:
		var path: String = (get_script() as Script).resource_path.get_base_dir() + "/runtime/ui_white.tres"
		if ResourceLoader.exists(path):
			_white_tex = load(path)
		if _white_tex == null:
			var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
			img.fill(Color.WHITE)
			_white_tex = ImageTexture.create_from_image(img)
	return _white_tex


## UnityEvent persistent calls are for a scripting plugin to wire.
func _events(evt, source: Control, signal_name: String, unbinds: int, state: RefCounted, obj: RefCounted) -> void:
	if not (evt is Dictionary):
		return
	for plugin in obj.meta.get_enabled_plugins():
		if plugin != self and plugin.has_method("ui_unity_event"):
			plugin.ui_unity_event(evt, source, signal_name, unbinds, state, obj)


## Path from `node` to the object a component field refers to; a target that is not built yet
## (a child of this object) is patched into the metadata entry when the scene is complete.
func _ref_path(ref, obj: RefCounted, node: Node, meta_key: String, cfg_key: String) -> NodePath:
	if typeof(ref) != TYPE_ARRAY or ref.size() < 4 or ref[1] == 0:
		return NodePath()
	var meta: Resource = obj.meta
	var owner: Node = node
	while owner != null and owner.owner != null:
		owner = owner.owner
	var np: NodePath = meta.fileid_to_nodepath.get(ref[1], meta.prefab_fileid_to_nodepath.get(ref[1], NodePath()))
	var target: Node = owner.get_node_or_null(np) if np != NodePath() and owner != null else null
	if target == null:
		_pending.append({"owner": owner, "node": node, "meta_key": meta_key, "cfg_key": cfg_key, "ref": ref, "meta": meta})
		return NodePath()
	return node.get_path_to(control_of(target) if control_of(target) != null else target)


## Apply one Unity UI component to the Control of its GameObject.
func configure_component(kind: String, obj: RefCounted, state: RefCounted, ctl: Control) -> void:
	state.add_fileID(ctl, obj)
	var keys: Dictionary = obj.keys
	match kind:
		"Image":
			var tex: Texture2D = _sprite_texture(obj.get_ref(keys, "m_Sprite"), obj)
			var col: Color = keys.get("m_Color", Color.WHITE) if keys.get("m_Color") is Color else Color.WHITE
			if ctl is TextureRect:
				# Unity draws an Image without a sprite as a solid rectangle in its colour, and the
				# built-in UI sprites (UISprite, Background, Knob ...) are not part of any package:
				# both get a white texture. The colour tints this graphic only, not its children.
				ctl.texture = tex if tex != null else _white_texture()
				if tex == null:
					ctl.set_meta("unidot_no_sprite", true)
				ctl.self_modulate = col
				if ctl.has_meta("unidot_mask_hidden"):
					ctl.self_modulate.a = 0.0  # a Mask that does not show its graphic (any order)
				if _to_int(keys.get("m_PreserveAspect", 0)) != 0:
					ctl.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			else:
				_apply_background(ctl, tex, col, keys)
		"RawImage":
			var tex2: Texture2D = _sprite_texture(obj.get_ref(keys, "m_Texture"), obj)
			var col2: Color = keys.get("m_Color", Color.WHITE) if keys.get("m_Color") is Color else Color.WHITE
			if ctl is TextureRect:
				ctl.texture = tex2 if tex2 != null else _white_texture()
				if tex2 == null:
					ctl.set_meta("unidot_no_sprite", true)
				ctl.self_modulate = col2
				if ctl.has_meta("unidot_mask_hidden"):
					ctl.self_modulate.a = 0.0
			else:
				_apply_background(ctl, tex2, col2, keys)
		"Text":
			_configure_text(ctl, keys, obj)
		"TextMeshProUGUI":
			_configure_tmp(ctl, keys, obj)
		"Button":
			if ctl is BaseButton:
				ctl.disabled = _to_int(keys.get("m_Interactable", 1)) == 0
			_events(keys.get("m_OnClick"), ctl, "pressed", 0, state, obj)
		"Toggle":
			if ctl is BaseButton:
				ctl.button_pressed = _to_int(keys.get("m_IsOn", 0)) != 0
				ctl.disabled = _to_int(keys.get("m_Interactable", 1)) == 0
			_events(keys.get("onValueChanged"), ctl, "toggled", 1, state, obj)
		"Scrollbar":
			if ctl is Range:
				# Unity's value runs 0..1 whatever the handle size is: no page, the size is kept aside
				ctl.min_value = 0.0
				ctl.max_value = 1.0
				ctl.step = 0.0
				ctl.page = 0.0
				ctl.value = _to_float(keys.get("m_Value", 0.0))
				ctl.set_meta("unidot_scrollbar", {"direction": _to_int(keys.get("m_Direction", 0)), "size": _to_float(keys.get("m_Size", 1.0))})
			_events(keys.get("m_OnValueChanged"), ctl, "value_changed", 1, state, obj)
		"Slider":
			if ctl is Range:
				ctl.min_value = _to_float(keys.get("m_MinValue", 0.0))
				ctl.max_value = _to_float(keys.get("m_MaxValue", 1.0))
				ctl.rounded = _to_int(keys.get("m_WholeNumbers", 0)) != 0
				ctl.step = 1.0 if ctl.rounded else 0.0
				ctl.value = _to_float(keys.get("m_Value", 0.0))
			_events(keys.get("m_OnValueChanged"), ctl, "value_changed", 1, state, obj)
		"InputField", "TMP_InputField":
			if ctl is LineEdit:
				ctl.text = str(keys.get("m_Text", "")) if keys.get("m_Text") != null else ""
				ctl.max_length = _to_int(keys.get("m_CharacterLimit", 0))
				ctl.editable = _to_int(keys.get("m_Interactable", 1)) != 0
				ctl.add_theme_font_size_override("font_size", _input_font_size(ctl, keys, obj))
			_events(keys.get("m_OnEndEdit"), ctl, "text_submitted", 1, state, obj)
			_events(keys.get("m_OnValueChanged"), ctl, "text_changed", 1, state, obj)
			_events(keys.get("m_OnSubmit"), ctl, "text_submitted", 1, state, obj)
		"Dropdown", "TMP_Dropdown":
			if ctl is OptionButton:
				var opts = keys.get("m_Options", {})
				if opts is Dictionary:
					for o in opts.get("m_Options", []):
						ctl.add_item(str(o.get("m_Text", "")) if o is Dictionary else str(o))
				ctl.selected = _to_int(keys.get("m_Value", 0))
				# Unity draws the caption with its own Text child (built later): the runtime
				# dropdown script hides the button's own text and keeps that label up to date
				ctl.set_meta("unidot_dropdown", {})
				if keys.has("m_CaptionText"):
					var cap: NodePath = _ref_path(keys["m_CaptionText"], obj, ctl, "unidot_dropdown", "caption")
					if cap != NodePath():
						ctl.set_meta("unidot_dropdown", {"caption": cap})
				ctl.set_script(dropdown_script)
			_events(keys.get("m_OnValueChanged"), ctl, "item_selected", 1, state, obj)
		"ScrollRect":
			if ctl is ScrollContainer:
				# Unity draws its own Scrollbar objects: Godot's bars stay hidden but keep scrolling
				ctl.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER if _to_int(keys.get("m_Horizontal", 1)) != 0 else ScrollContainer.SCROLL_MODE_DISABLED
				ctl.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER if _to_int(keys.get("m_Vertical", 1)) != 0 else ScrollContainer.SCROLL_MODE_DISABLED
				ctl.set_meta("unidot_scroll", {})
				# content and the Unity Scrollbar objects are built later: unresolved ones are
				# patched into the metadata when the scene is complete
				for pair in [["m_Content", "content"], ["m_VerticalScrollbar", "vbar"], ["m_HorizontalScrollbar", "hbar"]]:
					if keys.has(pair[0]):
						var cp: NodePath = _ref_path(keys[pair[0]], obj, ctl, "unidot_scroll", pair[1])
						if cp != NodePath():
							var sc: Dictionary = ctl.get_meta("unidot_scroll")
							sc[pair[1]] = cp
							ctl.set_meta("unidot_scroll", sc)
				# runtime/scroll_rect.gd sizes the scrolled child from the content and
				# raises `scrolled` (ScrollRect.onValueChanged)
				ctl.set_script(scroll_rect_script)
				_events(keys.get("m_OnValueChanged"), ctl, "scrolled", 1, state, obj)
		"Mask", "RectMask2D":
			ctl.clip_contents = true
			if kind == "Mask" and _to_int(keys.get("m_ShowMaskGraphic", 1)) == 0 and ctl is TextureRect:
				# the Image of the same object may be configured before or after this component
				ctl.set_meta("unidot_mask_hidden", true)
				ctl.self_modulate.a = 0.0
		"HorizontalLayoutGroup", "VerticalLayoutGroup", "GridLayoutGroup":
			# Unity's auto layout runs at run time (runtime/layout_group.gd on a helper child)
			var pd = keys.get("m_Padding", {})
			var lay: Dictionary = {
				"type": "grid" if kind == "GridLayoutGroup" else ("horizontal" if kind == "HorizontalLayoutGroup" else "vertical"),
				"padding": [_to_int(pd.get("m_Left", 0)), _to_int(pd.get("m_Right", 0)), _to_int(pd.get("m_Top", 0)), _to_int(pd.get("m_Bottom", 0))] if pd is Dictionary else [0, 0, 0, 0],
				"align": _to_int(keys.get("m_ChildAlignment", 0)),
			}
			if kind == "GridLayoutGroup":
				lay["cell"] = keys.get("m_CellSize", Vector2(100, 100)) if keys.get("m_CellSize") is Vector2 else Vector2(100, 100)
				lay["spacing2"] = keys.get("m_Spacing", Vector2.ZERO) if keys.get("m_Spacing") is Vector2 else Vector2.ZERO
				lay["corner"] = _to_int(keys.get("m_StartCorner", 0))
				lay["axis"] = _to_int(keys.get("m_StartAxis", 0))
				lay["constraint"] = _to_int(keys.get("m_Constraint", 0))
				lay["count"] = _to_int(keys.get("m_ConstraintCount", 2))
			else:
				lay["spacing"] = _to_float(keys.get("m_Spacing", 0.0))
				# before Unity 2017.1 the groups always controlled their children's size
				lay["control_w"] = _to_int(keys.get("m_ChildControlWidth", 1)) != 0
				lay["control_h"] = _to_int(keys.get("m_ChildControlHeight", 1)) != 0
				lay["expand_w"] = _to_int(keys.get("m_ChildForceExpandWidth", 1)) != 0
				lay["expand_h"] = _to_int(keys.get("m_ChildForceExpandHeight", 1)) != 0
				lay["scale_w"] = _to_int(keys.get("m_ChildScaleWidth", 0)) != 0
				lay["scale_h"] = _to_int(keys.get("m_ChildScaleHeight", 0)) != 0
				lay["reverse"] = _to_int(keys.get("m_ReverseArrangement", 0)) != 0
			if _to_int(keys.get("m_Enabled", 1)) != 0:
				ctl.set_meta("unidot_layout", lay)
				_ensure_layout_helper(ctl, state)
		"ContentSizeFitter":
			if _to_int(keys.get("m_Enabled", 1)) != 0:
				ctl.set_meta("unidot_fitter", {"h": _to_int(keys.get("m_HorizontalFit", 0)), "v": _to_int(keys.get("m_VerticalFit", 0))})
				_ensure_layout_helper(ctl, state)
		"LayoutElement":
			ctl.set_meta("unidot_layout_element", {
				"min": Vector2(_to_float(keys.get("m_MinWidth", -1.0)), _to_float(keys.get("m_MinHeight", -1.0))),
				"pref": Vector2(_to_float(keys.get("m_PreferredWidth", -1.0)), _to_float(keys.get("m_PreferredHeight", -1.0))),
				"flex": Vector2(_to_float(keys.get("m_FlexibleWidth", -1.0)), _to_float(keys.get("m_FlexibleHeight", -1.0))),
				"ignore": _to_int(keys.get("m_IgnoreLayout", 0)) != 0,
				"priority": _to_int(keys.get("m_LayoutPriority", 1)),
				"enabled": _to_int(keys.get("m_Enabled", 1)) != 0,
			})
		"Outline", "Shadow":
			# Unity text effects → theme overrides on the text control
			var ecol: Color = keys.get("m_EffectColor", Color(0, 0, 0, 0.5)) if keys.get("m_EffectColor") is Color else Color(0, 0, 0, 0.5)
			var edist: Vector2 = keys.get("m_EffectDistance", Vector2(1, -1)) if keys.get("m_EffectDistance") is Vector2 else Vector2(1, -1)
			var effect: String = "outline" if kind == "Outline" else "shadow"
			ctl.set_meta("unidot_effect_" + effect, {"effectColor": ecol, "effectDistance": edist, "useGraphicAlpha": _to_int(keys.get("m_UseGraphicAlpha", 1)) != 0, "enabled": _to_int(keys.get("m_Enabled", 1)) != 0})
			if _to_int(keys.get("m_Enabled", 1)) != 0:
				if kind == "Outline":
					ctl.add_theme_color_override("font_outline_color", ecol)
					ctl.add_theme_constant_override("outline_size", int(round(maxf(absf(edist.x), absf(edist.y)))))
				else:
					ctl.add_theme_color_override("font_shadow_color", ecol)
					ctl.add_theme_constant_override("shadow_offset_x", int(round(edist.x)))
					ctl.add_theme_constant_override("shadow_offset_y", int(round(-edist.y)))
		"AspectRatioFitter":
			var mode: int = _to_int(keys.get("m_AspectMode", 0))
			var ratio: float = maxf(_to_float(keys.get("m_AspectRatio", 1.0)), 0.001)
			var props: Dictionary = ctl.get_meta("unidot_props") if ctl.has_meta("unidot_props") else {}
			props["aspectMode"] = mode
			props["aspectRatio"] = ratio
			ctl.set_meta("unidot_props", props)
			if mode != 0 and _to_int(keys.get("m_Enabled", 1)) != 0:
				# the fitter follows the rect at run time (runtime/layout_group.gd)
				ctl.set_meta("unidot_aspect", {"mode": mode, "ratio": ratio})
				_ensure_layout_helper(ctl, state)
		"CanvasScaler", "GraphicRaycaster", "EventSystem", "StandaloneInputModule":
			pass
		_:
			pass


## Font size of an input field: that of the Unity text component it edits, but never taller than
## the rect (a LineEdit cannot be smaller than one line of its font).
func _input_font_size(ctl: Control, keys: Dictionary, obj: RefCounted) -> int:
	var size: float = 14.0
	var ref = keys.get("m_TextComponent")
	if typeof(ref) == TYPE_ARRAY and ref.size() >= 2 and ref[1] != 0:
		var text_obj = obj.meta.lookup(ref)
		if text_obj != null:
			var fd = text_obj.keys.get("m_FontData")
			if fd is Dictionary:
				size = _to_float(fd.get("m_FontSize", size))
			elif text_obj.keys.has("m_fontSize"):
				size = _to_float(text_obj.keys.get("m_fontSize", size))
	var h: float = RT.rect_size(ctl).y
	if h > 0.0:
		size = minf(size, floorf(h / 1.45))
	return maxi(int(size), 1)


func _apply_background(ctl: Control, tex: Texture2D, col: Color, keys: Dictionary) -> void:
	var sb: StyleBox
	if tex != null:
		var sbt := StyleBoxTexture.new()
		sbt.texture = tex
		sbt.modulate_color = col
		sb = sbt
	else:
		var sbf := StyleBoxFlat.new()
		sbf.bg_color = col
		sb = sbf
	for st in ["normal", "hover", "pressed", "disabled", "focus", "panel"]:
		if ctl.has_theme_stylebox(st):
			ctl.add_theme_stylebox_override(st, sb)
	if ctl is BaseButton:
		ctl.flat = false


func _sprite_texture(ref: Array, obj: RefCounted) -> Texture2D:
	if ref.size() < 4 or ref[1] == 0:
		return null
	if obj.meta.lookup_meta(ref) == null and not database.guid_to_path.has(str(ref[2])):
		return null
	var res = obj.meta.get_godot_resource(ref, true)
	if res is Texture2D:
		return res
	if res == null and ref[2] != null:
		var path: String = str(database.guid_to_path.get(str(ref[2]), ""))
		if path != "" and ResourceLoader.exists("res://" + path):
			var loaded = load("res://" + path)
			if loaded is Texture2D:
				return loaded
	return null


func _configure_text(ctl: Control, keys: Dictionary, obj: RefCounted) -> void:
	var text: String = str(keys.get("m_Text", "")) if keys.get("m_Text") != null else ""
	var fd = keys.get("m_FontData", {})
	var size: int = 14
	var align: int = 0
	if fd is Dictionary:
		size = _to_int(fd.get("m_FontSize", 14))
		align = _to_int(fd.get("m_Alignment", 0))
	var col: Color = keys.get("m_Color", Color.WHITE) if keys.get("m_Color") is Color else Color.WHITE
	if ctl is Label:
		ctl.text = text
		ctl.add_theme_font_size_override("font_size", maxi(size, 1))
		ctl.add_theme_color_override("font_color", col)
		ctl.horizontal_alignment = [HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_RIGHT][align % 3]
		ctl.vertical_alignment = [VERTICAL_ALIGNMENT_TOP, VERTICAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_BOTTOM][mini(int(align / 3), 2)]
		ctl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		ctl.clip_text = true
		if fd is Dictionary:
			var fref: Array = obj.get_ref(fd, "m_Font")
			if fref[1] != 0 and obj.meta.lookup_meta(fref) != null:
				var font = obj.meta.get_godot_resource(fref, true)
				if font is Font:
					ctl.add_theme_font_override("font", font)
	elif ctl is Button:
		ctl.text = text


func _configure_tmp(ctl: Control, keys: Dictionary, _obj: RefCounted) -> void:
	var text: String = str(keys.get("m_text", "")) if keys.get("m_text") != null else ""
	var size: float = _to_float(keys.get("m_fontSize", 14.0))
	var col: Color = keys.get("m_fontColor", Color.WHITE) if keys.get("m_fontColor") is Color else Color.WHITE
	var align: int = _to_int(keys.get("m_HorizontalAlignment", 1))
	var valign: int = _to_int(keys.get("m_VerticalAlignment", 256))
	if ctl is RichTextLabel:
		ctl.bbcode_enabled = true
		ctl.text = _tmp_to_bbcode(text)
		ctl.add_theme_font_size_override("normal_font_size", maxi(int(size), 1))
		ctl.add_theme_font_size_override("bold_font_size", maxi(int(size), 1))
		ctl.add_theme_color_override("default_color", col)
		ctl.scroll_active = false
		var h: int = HORIZONTAL_ALIGNMENT_LEFT
		match align:
			2:
				h = HORIZONTAL_ALIGNMENT_CENTER
			4:
				h = HORIZONTAL_ALIGNMENT_RIGHT
			8:
				h = HORIZONTAL_ALIGNMENT_FILL
		ctl.horizontal_alignment = h
		match valign:
			512:
				ctl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			1024:
				ctl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
			_:
				ctl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		ctl.set_meta("unidot_tmp", true)
	elif ctl is Label:
		ctl.text = text
	elif ctl is Button:
		ctl.text = text


## Minimal TextMeshPro rich text → BBCode (colour, bold, italic, size, line breaks).
static func _tmp_to_bbcode(s: String) -> String:
	var out: String = s
	out = out.replace("<b>", "[b]").replace("</b>", "[/b]").replace("<i>", "[i]").replace("</i>", "[/i]")
	out = out.replace("</color>", "[/color]").replace("</size>", "[/font_size]")
	var re := RegEx.new()
	re.compile("<color=(#?[0-9A-Fa-f]{6,8}|[a-zA-Z]+)>")
	out = re.sub(out, "[color=$1]", true)
	re.compile("<size=([0-9.]+)>")
	out = re.sub(out, "[font_size=$1]", true)
	re.compile("<[^>]*>")
	out = re.sub(out, "", true)
	return out


func _to_float(v) -> float:
	match typeof(v):
		TYPE_FLOAT, TYPE_INT:
			return float(v)
		TYPE_STRING:
			return str(v).to_float()
		TYPE_BOOL:
			return 1.0 if v else 0.0
	return 0.0


func _to_int(v) -> int:
	match typeof(v):
		TYPE_INT:
			return v
		TYPE_FLOAT:
			return int(v)
		TYPE_STRING:
			var s: String = str(v)
			if s.is_valid_int():
				return s.to_int()
			return int(s.to_float())
		TYPE_BOOL:
			return 1 if v else 0
	return 0
