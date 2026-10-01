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
const selectable_script := preload("./runtime/selectable.gd")
const text_fit_script := preload("./runtime/ui_text_fit.gd")
const sprite_script := preload("./runtime/ui_sprite.gd")
const Graphic := preload("./runtime/ui_graphic.gd")
const UiText := preload("./runtime/ui_text.gd")
const UiGroup := preload("./runtime/canvas_group.gd")

## Metadata of a Control: {file id of a Unity UI component on its GameObject → kind}. Overrides
## of a prefab instance name the component by that id.
const META_COMPONENTS := &"unidot_ui"

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
const UI_PRIMARY_ORDER := ["Button", "Toggle", "Slider", "Scrollbar", "InputField", "TMP_InputField", "Dropdown", "TMP_Dropdown", "Text", "TextMeshProUGUI", "Image", "RawImage"]

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
	label.font_size = 64
	label.outline_size = 0
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
	var settings: Dictionary = _tmp_settings(keys)
	settings["box"] = rect.x
	label.set_meta(UiText.META, settings)
	UiText.set_fonts(label, _tmp_fonts(keys, obj))
	UiText.render(label)
	Graphic.update(label, {"color": keys["m_fontColor"] if keys.get("m_fontColor") is Color else Color.WHITE, "enabled": _to_int(keys.get("m_Enabled", 1)) != 0})
	# readable from the object's -z side like every Unity text; x is mirrored in the Godot scene
	label.transform = Transform3D(Basis.from_euler(Vector3(0.0, PI, 0.0)), Vector3(-(x - pivot.x) * rect.x, (y - pivot.y) * rect.y, 0.0))
	state.add_child(label, node, obj)
	stats["text_3d"] = int(stats.get("text_3d", 0)) + 1


## TextMeshPro's font asset script.
const TMP_FONT_ASSET := "71c1514a6bd24e1e882cebbe1904ce04"
## Metadata of the Font a font asset becomes: {family, style, source: bool (the font file is in
## the project), bold (weight of the bold style), bold_spacing, italic (slant of the italic style)}
const META_FONT_ASSET := &"unidot_tmp_font"


## A TextMeshPro font asset is an atlas of glyphs made from a font file. Godot draws text from
## the font file itself, so the asset becomes a variation of the font it was made from (the
## asset's GUID then loads as a Font). Without that file in the project: a system font of the
## asset's family when there is one, the stand-in family otherwise.
func handle_scripted_object(obj: RefCounted):
	var script_ref = obj.keys.get("m_Script")
	if not (script_ref is Array) or script_ref.size() < 3 or str(script_ref[2]) != TMP_FONT_ASSET:
		return null
	var keys: Dictionary = obj.keys
	var guid: String = str(keys.get("m_SourceFontFileGUID", ""))
	if guid.length() != 32 and keys.get("m_CreationSettings") is Dictionary:
		guid = str((keys["m_CreationSettings"] as Dictionary).get("sourceFontFileGUID", ""))
	var face: Dictionary = keys["m_FaceInfo"] if keys.get("m_FaceInfo") is Dictionary else {}
	var family: String = str(face.get("m_FamilyName", "")).strip_edges()
	var source: Font = null
	if guid.length() == 32:
		var ref: Array = [null, 12800000, guid, 3]
		if obj.meta.lookup_meta_by_guid(guid) != null:
			source = obj.meta.get_godot_resource(ref, true) as Font
	var font := FontVariation.new()
	if source != null:
		font.base_font = source
	else:
		var names: PackedStringArray = (UiText.FONTS[0] as SystemFont).font_names.duplicate()
		if not family.is_empty():
			names.insert(0, family)
		var stand_in := SystemFont.new()
		stand_in.font_names = names
		font.base_font = stand_in
	font.set_meta(META_FONT_ASSET, {
		"family": family, "style": str(face.get("m_StyleName", "")), "source": source != null,
		"bold": _to_float(keys.get("boldStyle", 0.75)), "bold_spacing": _to_float(keys.get("boldSpacing", 7.0)),
		"italic": _to_float(keys.get("italicStyle", 35.0)),
	})
	stats["font_assets"] = int(stats.get("font_assets", 0)) + 1
	return font


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
	_finish_widgets(scene_contents)


## Every object of the scene exists and the references between them are node paths: what one
## object does to another (a Selectable to its target graphic, a Slider to its fill and handle,
## an input field to its text objects) is applied, so the saved scene shows Unity's resting state.
func _finish_widgets(n: Node) -> void:
	if n is Control:
		if n.has_meta(selectable_script.META):
			selectable_script.refresh_static(n)
		if n is LineEdit and n.has_meta(&"unidot_input"):
			_finish_input(n)
	for c in n.get_children():
		_finish_widgets(c)


## Unity draws an input field with two child objects, the text and the placeholder; a LineEdit
## draws both itself, with their fonts and colours.
func _finish_input(field: LineEdit) -> void:
	var cfg: Dictionary = field.get_meta(&"unidot_input")
	var shown: Node = field.get_node_or_null(cfg["text"]) if cfg.get("text") is NodePath else null
	var hint: Node = field.get_node_or_null(cfg["placeholder"]) if cfg.get("placeholder") is NodePath else null
	if shown is RichTextLabel and shown != field:
		field.add_theme_color_override("font_color", Graphic.color(shown))
		field.add_theme_font_override("font", shown.get_theme_font("normal_font"))
		field.alignment = shown.horizontal_alignment
		Graphic.update(shown, {"hidden": true})
	if hint is RichTextLabel and hint != field:
		var hs: Dictionary = UiText.settings(hint)
		field.placeholder_text = UiText.plain(str(hs["text"]), bool(hs["rich"]), int(hs["style"]), bool(hs["tmp"]))
		field.add_theme_color_override("font_placeholder_color", Graphic.color(hint))
		Graphic.update(hint, {"hidden": true})


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


## A CanvasGroup component (or the overrides of one on a prefab instance) on its Control:
## runtime/canvas_group.gd applies alpha, interactable and blocksRaycasts.
static func canvas_group(ctl: Control, keys: Dictionary) -> void:
	var changes: Dictionary = {}
	for pair in [["m_Interactable", "interactable"], ["m_BlocksRaycasts", "blocksRaycasts"], ["m_IgnoreParentGroups", "ignoreParentGroups"]]:
		if keys.has(pair[0]):
			changes[pair[1]] = keys[pair[0]] != 0
	if keys.has("m_Alpha"):
		changes["alpha"] = float(keys["m_Alpha"])
	if keys.has("m_Enabled") and keys["m_Enabled"] == 0:
		changes = {"alpha": 1.0, "interactable": true, "blocksRaycasts": true, "ignoreParentGroups": false}   # a disabled group does nothing
	UiGroup.update(ctl, changes)


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
	if RT.store(node).has_meta(META_PLAIN):
		# a plain Transform: x and y of its local position are its anchored position
		var ap: Vector2 = v["anchored_position"]
		if uprops.get("m_LocalPosition") is Vector3:
			ap = Vector2(uprops["m_LocalPosition"].x, uprops["m_LocalPosition"].y)
			changed = true
		for axis in ["x", "y"]:
			if uprops.has("m_LocalPosition." + axis):
				ap[axis] = float(uprops["m_LocalPosition." + axis])
				changed = true
		v["anchored_position"] = ap
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
		return RT.control_properties(v, RT.carry_above(s), RT.carries(s))
	var out: Dictionary = {"metadata/" + String(RT.META_RECT): v}
	if s is Node3D and not RT.is_nested(s):
		var ap: Vector2 = v["anchored_position"]
		out["position"] = Vector3(-ap.x, ap.y, float(v["z"]))
		out["quaternion"] = Quaternion(q.x, -q.y, -q.z, q.w).normalized()
		out["scale"] = RT._safe_scale(sc)
	return out


## Metadata flag of the Control a plain Transform inside a canvas became (see rect_transform.gd:
## it hands its rotation and scale down to the rects below it).
const META_PLAIN := RT.META_PLAIN


## Is there a RectTransform somewhere below this Transform (in its own file)?
func _holds_ui(transform: RefCounted, depth: int = 0) -> bool:
	if depth > 32 or not (transform.keys.get("m_Children") is Array):
		return false
	for ref in transform.keys["m_Children"]:
		var child = transform.meta.lookup(ref, true)
		if child == null:
			continue
		if child.type == "RectTransform" or _holds_ui(child, depth + 1):
			return true
	return false


## The rect of a plain Transform below a Control: no size, at its local position from the
## parent's pivot (the origin of the parent's space), with its rotation and scale.
static func plain_values(keys: Dictionary, parent: Control) -> Dictionary:
	var v: Dictionary = RT._defaults()
	var pivot: Vector2 = RT.values(parent)["pivot"]
	v["anchor_min"] = pivot
	v["anchor_max"] = pivot
	v["size_delta"] = Vector2.ZERO
	if keys.get("m_LocalPosition") is Vector3:
		var lp: Vector3 = keys["m_LocalPosition"]
		v["anchored_position"] = Vector2(lp.x, lp.y)
		v["z"] = lp.z
	if keys.get("m_LocalRotation") is Quaternion:
		v["rotation"] = (keys["m_LocalRotation"] as Quaternion).normalized()
	if keys.get("m_LocalScale") is Vector3:
		v["scale"] = keys["m_LocalScale"]
	return v


## GameObjects with a RectTransform become Controls; the class follows the main UI component.
## A plain Transform inside a canvas that has RectTransforms below it becomes a Control too: it
## has no rect, but what is below it is UI of that canvas, laid out against no parent rect.
func create_gameobject_node(go: RefCounted, state: RefCounted, new_parent: Node) -> Node:
	var transform = go.transform
	if transform == null:
		return null
	if transform.type != "RectTransform":
		var host: Node = RT.child_host(new_parent)
		if transform.type != "Transform" or not (host is Control) or not _holds_ui(transform):
			return null
		var plain := Control.new()
		plain.name = go.name
		plain.mouse_filter = Control.MOUSE_FILTER_IGNORE
		plain.set_meta(META_PLAIN, true)
		state.add_child(plain, host, transform)
		RT.set_values(plain, plain_values(transform.keys, host))
		plain.visible = go.enabled if "enabled" in go else true
		stats["ui_nodes"] += 1
		return plain
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
	# sprites are measured in canvas units through this (CanvasScaler.referencePixelsPerUnit)
	var scaler_keys: Dictionary = kind_keys.get("CanvasScaler", {})
	if scaler_keys.has("m_ReferencePixelsPerUnit") and not is_equal_approx(_to_float(scaler_keys["m_ReferencePixelsPerUnit"]), 100.0):
		var ccfg: Dictionary = holder.get_meta(RT.META_CANVAS)
		ccfg["reference_ppu"] = _to_float(scaler_keys["m_ReferencePixelsPerUnit"])
		holder.set_meta(RT.META_CANVAS, ccfg)
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
		"Text", "TextMeshProUGUI":
			# a RichTextLabel for uGUI's Text too: rich text, and lines that do not fit are not drawn
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
func _ensure_layout_helper(ctl: Control, state: RefCounted) -> void:
	_ensure_helper(ctl, state, "UnidotLayout", layout_group_script)


## Runtime behaviour of a UI object lives in helper children, not in a script on the Control:
## that slot is left to the scene's own scripts.
func _ensure_helper(ctl: Control, state: RefCounted, helper_name: String, script: Script) -> void:
	_add_helper(ctl, helper_name, script, state.owner if state.owner != null else ctl)


func _add_helper(ctl: Control, helper_name: String, script: Script, owner: Node) -> void:
	if ctl.get_node_or_null(helper_name) != null:
		return
	var helper := Node.new()
	helper.name = helper_name
	helper.set_meta(RT.META_HELPER, true)
	helper.set_script(script)
	ctl.add_child(helper)
	helper.owner = owner


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
func _events(evt, source: Node, signal_name: String, unbinds: int, state: RefCounted, obj: RefCounted) -> void:
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
	var hosted: Dictionary = (ctl.get_meta(META_COMPONENTS) as Dictionary).duplicate() if ctl.has_meta(META_COMPONENTS) else {}
	hosted[obj.fileID] = kind
	ctl.set_meta(META_COMPONENTS, hosted)
	var keys: Dictionary = obj.keys
	match kind:
		"Image", "RawImage":
			# colour, CanvasRenderer colour and enabled are applied by runtime/ui_graphic.gd
			var graphic: Dictionary = {"color": keys["m_Color"] if keys.get("m_Color") is Color else Color.WHITE, "enabled": _to_int(keys.get("m_Enabled", 1)) != 0}
			var info: Dictionary = _sprite(obj.get_ref(keys, "m_Sprite"), obj) if kind == "Image" else {"texture": _sprite_texture(obj.get_ref(keys, "m_Texture"), obj)}
			var tex: Texture2D = info.get("texture")
			var drawn: Dictionary = _sprite_drawing(keys, info, ctl) if kind == "Image" and tex != null else {}
			if ctl is TextureRect:
				# Unity draws an Image without a sprite as a solid rectangle in its colour: a white
				# texture. The colour tints this graphic only, not its children.
				ctl.texture = tex if tex != null else _white_texture()
				if tex == null:
					ctl.set_meta("unidot_no_sprite", true)
				if kind == "Image" and _to_int(keys.get("m_PreserveAspect", 0)) != 0 and drawn.is_empty():
					ctl.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			else:
				if tex != null:
					graphic["texture"] = tex   # the background of a widget
				if drawn.is_empty() and (ctl is Slider):
					# a widget that has no box of its own for a background: the helper draws it
					drawn = {"type": 0}
			if kind == "Image" and tex != null:
				# canvas units per sprite pixel, and the size the Image asks for in a layout: its
				# sprite's, or the borders of a sliced or tiled one (Image.preferredWidth)
				var unit: float = _sprite_unit(info, ctl)
				var edge: Array = info.get("border", [0, 0, 0, 0])
				graphic["unit"] = unit
				graphic["preferred"] = Vector2(float(edge[0]) + float(edge[2]), float(edge[1]) + float(edge[3])) * unit if _to_int(keys.get("m_Type", 0)) in [1, 2] else Vector2(tex.get_size()) * unit
			if not drawn.is_empty():
				# sliced, tiled or filled: drawn by a helper child (runtime/ui_sprite.gd)
				graphic["sprite"] = drawn
				_add_sprite_helper(ctl, state.owner if state.owner != null else ctl)
			Graphic.update(ctl, graphic)
		"Text":
			_configure_text(ctl, keys, obj, state)
		"TextMeshProUGUI":
			_configure_tmp(ctl, keys, obj, state)
		"Button":
			if ctl is BaseButton:
				ctl.disabled = _to_int(keys.get("m_Interactable", 1)) == 0
			_selectable(ctl, keys, obj, state)
			_events(keys.get("m_OnClick"), ctl, "pressed", 0, state, obj)
		"Toggle":
			if ctl is BaseButton:
				ctl.button_pressed = _to_int(keys.get("m_IsOn", 0)) != 0
				ctl.disabled = _to_int(keys.get("m_Interactable", 1)) == 0
			_selectable(ctl, keys, obj, state, {"graphic": "graphic"})
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
			_selectable(ctl, keys, obj, state, {"m_HandleRect": "handle"})
			_events(keys.get("m_OnValueChanged"), ctl, "value_changed", 1, state, obj)
		"Slider":
			if ctl is Range:
				ctl.min_value = _to_float(keys.get("m_MinValue", 0.0))
				ctl.max_value = _to_float(keys.get("m_MaxValue", 1.0))
				ctl.rounded = _to_int(keys.get("m_WholeNumbers", 0)) != 0
				ctl.step = 1.0 if ctl.rounded else 0.0
				ctl.value = _to_float(keys.get("m_Value", 0.0))
				ctl.editable = _to_int(keys.get("m_Interactable", 1)) != 0
			_selectable(ctl, keys, obj, state, {"m_FillRect": "fill", "m_HandleRect": "handle"})
			_events(keys.get("m_OnValueChanged"), ctl, "value_changed", 1, state, obj)
		"InputField", "TMP_InputField":
			if ctl is LineEdit:
				ctl.text = str(keys.get("m_Text", "")) if keys.get("m_Text") != null else ""
				ctl.max_length = _to_int(keys.get("m_CharacterLimit", 0))
				ctl.editable = _to_int(keys.get("m_Interactable", 1)) != 0
				ctl.add_theme_font_size_override("font_size", _input_font_size(ctl, keys, obj))
				UiText.set_fonts(ctl)
				# the Unity objects that draw the text and the placeholder (built later)
				ctl.set_meta(&"unidot_input", {})
				for pair in [["m_TextComponent", "text"], ["m_Placeholder", "placeholder"]]:
					var tp: NodePath = _ref_path(keys.get(pair[0]), obj, ctl, "unidot_input", pair[1])
					if tp != NodePath():
						var ic: Dictionary = ctl.get_meta(&"unidot_input")
						ic[pair[1]] = tp
						ctl.set_meta(&"unidot_input", ic)
			_selectable(ctl, keys, obj, state)
			_events(keys.get("m_OnEndEdit"), ctl, "text_submitted", 1, state, obj)
			_events(keys.get("m_OnValueChanged"), ctl, "text_changed", 1, state, obj)
			_events(keys.get("m_OnSubmit"), ctl, "text_submitted", 1, state, obj)
		"Dropdown", "TMP_Dropdown":
			if ctl is OptionButton:
				var opts = keys.get("m_Options", {})
				if opts is Dictionary:
					for o in opts.get("m_Options", []):
						ctl.add_item(str(o.get("m_Text", "")) if o is Dictionary and o.get("m_Text") != null else ("" if o is Dictionary else str(o)))
						if o is Dictionary and typeof(o.get("m_Image")) == TYPE_ARRAY:
							var option_image: Texture2D = _sprite(o["m_Image"], obj).get("texture")
							if option_image != null:
								ctl.set_item_icon(ctl.item_count - 1, option_image)
				ctl.selected = _to_int(keys.get("m_Value", 0))
				# Unity draws the caption and the list with its own objects (built later): the helper
				# child (runtime/dropdown.gd) keeps the caption up to date and builds the list from
				# the template object
				ctl.set_meta(dropdown_script.META, {})
				for pair in [["m_CaptionText", "caption"], ["m_CaptionImage", "caption_image"], ["m_Template", "template"], ["m_ItemText", "item_text"], ["m_ItemImage", "item_image"]]:
					var dp: NodePath = _ref_path(keys.get(pair[0]), obj, ctl, String(dropdown_script.META), pair[1])
					if dp != NodePath():
						var dc: Dictionary = ctl.get_meta(dropdown_script.META)
						dc[pair[1]] = dp
						ctl.set_meta(dropdown_script.META, dc)
				_ensure_helper(ctl, state, dropdown_script.HELPER, dropdown_script)
			_selectable(ctl, keys, obj, state)
			_events(keys.get("m_OnValueChanged"), ctl, "item_selected", 1, state, obj)
		"ScrollRect":
			# Unity's own scroller, on the objects as they are: runtime/scroll_rect.gd (a helper
			# child) moves the content inside the viewport object and drives the Scrollbars
			ctl.set_meta(scroll_rect_script.META, {
				"horizontal": _to_int(keys.get("m_Horizontal", 1)) != 0,
				"vertical": _to_int(keys.get("m_Vertical", 1)) != 0,
				"movement": _to_int(keys.get("m_MovementType", 1)),
				"sensitivity": _to_float(keys.get("m_ScrollSensitivity", 1.0)),
				"visibility": [_to_int(keys.get("m_HorizontalScrollbarVisibility", 0)), _to_int(keys.get("m_VerticalScrollbarVisibility", 0))],
				"spacing": [_to_float(keys.get("m_HorizontalScrollbarSpacing", 0.0)), _to_float(keys.get("m_VerticalScrollbarSpacing", 0.0))],
			})
			# content, viewport and the Scrollbar objects are built later: unresolved ones are
			# patched into the metadata when the scene is complete
			for pair in [["m_Content", "content"], ["m_Viewport", "viewport"], ["m_VerticalScrollbar", "vbar"], ["m_HorizontalScrollbar", "hbar"]]:
				if keys.has(pair[0]):
					var cp: NodePath = _ref_path(keys[pair[0]], obj, ctl, String(scroll_rect_script.META), pair[1])
					if cp != NodePath():
						var sc: Dictionary = ctl.get_meta(scroll_rect_script.META)
						sc[pair[1]] = cp
						ctl.set_meta(scroll_rect_script.META, sc)
			if ctl.mouse_filter == Control.MOUSE_FILTER_IGNORE:
				ctl.mouse_filter = Control.MOUSE_FILTER_PASS   # the wheel and drags reach it
			if _to_int(keys.get("m_Enabled", 1)) == 0:
				var off: Dictionary = ctl.get_meta(scroll_rect_script.META)
				off["enabled"] = false
				ctl.set_meta(scroll_rect_script.META, off)
			# the helper raises ScrollRect.onValueChanged
			_ensure_helper(ctl, state, scroll_rect_script.HELPER, scroll_rect_script)
			_events(keys.get("m_OnValueChanged"), ctl.get_node(scroll_rect_script.HELPER), "scrolled", 1, state, obj)
		"Mask", "RectMask2D":
			ctl.clip_contents = true
			if kind == "Mask" and _to_int(keys.get("m_ShowMaskGraphic", 1)) == 0 and _to_int(keys.get("m_Enabled", 1)) != 0:
				# the Image of the same object may be configured before or after this component
				Graphic.update(ctl, {"hidden": true})
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
			if _to_int(keys.get("m_Enabled", 1)) == 0:
				lay["enabled"] = false   # the settings are kept for a script that enables it
			ctl.set_meta("unidot_layout", lay)
			if _to_int(keys.get("m_Enabled", 1)) != 0:
				_ensure_layout_helper(ctl, state)
		"ContentSizeFitter":
			var fitter: Dictionary = {"h": _to_int(keys.get("m_HorizontalFit", 0)), "v": _to_int(keys.get("m_VerticalFit", 0))}
			if _to_int(keys.get("m_Enabled", 1)) == 0:
				fitter["enabled"] = false
			ctl.set_meta("unidot_fitter", fitter)
			if _to_int(keys.get("m_Enabled", 1)) != 0:
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
			var aspect: Dictionary = {"mode": mode, "ratio": ratio}
			if _to_int(keys.get("m_Enabled", 1)) == 0:
				aspect["enabled"] = false
			ctl.set_meta("unidot_aspect", aspect)
			if mode != 0 and _to_int(keys.get("m_Enabled", 1)) != 0:
				# the fitter follows the rect at run time (runtime/layout_group.gd)
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


## Unity's built-in UI sprites (the default look of buttons, toggles, sliders ...): no package
## ships them. Stand-ins of the same size, border and pixels per unit come with the run-time
## scripts (runtime/sprites).
const BUILTIN_GUID := "0000000000000000f000000000000000"
const BUILTIN_SPRITES := {
	10901: ["checkmark", 0], 10905: ["ui_sprite", 10], 10907: ["background", 10], 10911: ["input_field_background", 10],
	10913: ["knob", 0], 10915: ["dropdown_arrow", 0], 10917: ["ui_mask", 10],
}
const BUILTIN_PPU := 200.0

var _builtin_cache: Dictionary = {}


## A sprite reference → {texture, border: [left, top, right, bottom] in sprite pixels,
## ppu: sprite pixels per unit}. The texture is an AtlasTexture for a sprite of a sheet.
func _sprite(ref: Array, obj: RefCounted) -> Dictionary:
	if ref.size() < 4 or ref[1] == 0:
		return {}
	if str(ref[2]) == BUILTIN_GUID:
		if not BUILTIN_SPRITES.has(ref[1]):
			return {}
		var entry: Array = BUILTIN_SPRITES[ref[1]]
		if not _builtin_cache.has(entry[0]):
			var path: String = (get_script() as Script).resource_path.get_base_dir() + "/runtime/sprites/" + str(entry[0]) + ".tres"
			_builtin_cache[entry[0]] = load(path) if ResourceLoader.exists(path) else null
		if _builtin_cache[entry[0]] == null:
			return {}
		var b: int = entry[1]
		return {"texture": _builtin_cache[entry[0]], "border": [b, b, b, b], "ppu": BUILTIN_PPU}
	var tex: Texture2D = _sprite_texture(ref, obj)
	if tex == null:
		return {}
	var info: Dictionary = {"texture": tex, "border": [0, 0, 0, 0], "ppu": 100.0}
	var tm = obj.meta.lookup_meta(ref)
	var ik: Dictionary = tm.importer_keys if tm != null and tm.get("importer_keys") is Dictionary else {}
	if ik.has("spritePixelsToUnits"):
		info["ppu"] = maxf(_to_float(ik["spritePixelsToUnits"]), 0.0001)
	var border = ik.get("spriteBorder")
	if _to_int(ik.get("spriteMode", 1)) == 2:
		# a sheet: the sprite is named by its file id
		var sheet = ik.get("spriteSheet")
		for sp in (sheet.get("sprites", []) if sheet is Dictionary else []):
			if not (sp is Dictionary) or _to_int(sp.get("internalID", 0)) != ref[1]:
				continue
			border = sp.get("border")
			var r = sp.get("rect")
			if r is Dictionary:
				r = Rect2(_to_float(r.get("x", 0)), _to_float(r.get("y", 0)), _to_float(r.get("width", 0)), _to_float(r.get("height", 0)))
			if r is Rect2 and r.size.x > 0.0 and r.size.y > 0.0:
				# Unity's sprite rects have their origin at the bottom-left of the texture
				var atlas := AtlasTexture.new()
				atlas.atlas = tex
				atlas.region = Rect2(r.position.x, float(tex.get_height()) - r.position.y - r.size.y, r.size.x, r.size.y)
				info["texture"] = atlas
			break
	# Unity's border is left, bottom, right, top
	if border is Quaternion:
		info["border"] = [border.x, border.w, border.z, border.y]
	elif border is Vector4:
		info["border"] = [border.x, border.w, border.z, border.y]
	return info


## The pixels per unit of the canvas `ctl` is on (CanvasScaler.referencePixelsPerUnit).
func _reference_ppu(ctl: Node) -> float:
	var cur: Node = ctl
	while cur != null:
		if cur.has_meta(RT.META_CANVAS):
			return float((cur.get_meta(RT.META_CANVAS) as Dictionary).get("reference_ppu", 100.0))
		cur = cur.get_parent()
	return 100.0


## Canvas units per sprite pixel of an Image (1 / Image.pixelsPerUnit).
func _sprite_unit(info: Dictionary, ctl: Control) -> float:
	return _reference_ppu(ctl) / maxf(float(info.get("ppu", 100.0)), 0.0001)


## How an Image draws its sprite when it is not simply stretched (→ `sprite` of the graphic
## metadata, runtime/ui_sprite.gd); empty for a simple image.
func _sprite_drawing(keys: Dictionary, info: Dictionary, ctl: Control) -> Dictionary:
	var unit: float = _sprite_unit(info, ctl) / maxf(_to_float(keys.get("m_PixelsPerUnitMultiplier", 1.0)), 0.01)
	var border: Array = info.get("border", [0, 0, 0, 0])
	var has_border: bool = false
	for v in border:
		if float(v) > 0.0:
			has_border = true
	match _to_int(keys.get("m_Type", 0)):
		1:
			if has_border:
				return {"type": 1, "border": border, "unit": unit, "center": _to_int(keys.get("m_FillCenter", 1)) != 0}
		2:
			return {"type": 2, "border": border, "unit": unit, "center": _to_int(keys.get("m_FillCenter", 1)) != 0}
		3:
			return {"type": 3, "method": _to_int(keys.get("m_FillMethod", 4)), "origin": _to_int(keys.get("m_FillOrigin", 0)), "amount": _to_float(keys.get("m_FillAmount", 1.0)), "clockwise": _to_int(keys.get("m_FillClockwise", 1)) != 0}
	return {}


func _add_sprite_helper(ctl: Control, owner: Node) -> void:
	if ctl.get_node_or_null(sprite_script.HELPER) != null:
		return
	var helper := Control.new()
	helper.name = sprite_script.HELPER
	helper.set_meta(RT.META_HELPER, true)
	helper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	helper.show_behind_parent = true   # a Button draws its own text over it
	helper.set_script(sprite_script)
	ctl.add_child(helper)
	ctl.move_child(helper, 0)
	helper.set_anchors_preset(Control.PRESET_FULL_RECT)
	helper.owner = owner


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


## What a Selectable (Button, Toggle, Slider, InputField, Dropdown, Scrollbar) does to other
## objects: the colour tint of its target graphic, and the objects named by `refs`
## (Unity field → entry of the `unidot_selectable` metadata). runtime/selectable.gd applies it.
func _selectable(ctl: Control, keys: Dictionary, obj: RefCounted, state: RefCounted, refs: Dictionary = {}) -> void:
	var cfg: Dictionary = {"transition": _to_int(keys.get("m_Transition", 1))}
	var block = keys.get("m_Colors")
	if block is Dictionary:
		var colors: Dictionary = {}
		for pair in [["m_NormalColor", "normalColor"], ["m_HighlightedColor", "highlightedColor"], ["m_PressedColor", "pressedColor"], ["m_SelectedColor", "selectedColor"], ["m_DisabledColor", "disabledColor"]]:
			if block.get(pair[0]) is Color:
				colors[pair[1]] = block[pair[0]]
		if not colors.has("selectedColor") and colors.has("highlightedColor"):
			colors["selectedColor"] = colors["highlightedColor"]   # files older than Unity 2019.1
		colors["colorMultiplier"] = _to_float(block.get("m_ColorMultiplier", 1.0))
		colors["fadeDuration"] = _to_float(block.get("m_FadeDuration", 0.1))
		cfg["colors"] = colors
	if keys.has("m_Direction"):
		cfg["direction"] = _to_int(keys["m_Direction"])
	if keys.has("m_FillRect"):
		# a fill that is an Image of type Filled is not resized
		var fill_ref = keys["m_FillRect"]
		var fill_obj = obj.meta.lookup(fill_ref) if typeof(fill_ref) == TYPE_ARRAY and fill_ref.size() >= 2 and fill_ref[1] != 0 else null
		if fill_obj != null and fill_obj.gameObject != null:
			for component_ref in fill_obj.gameObject.components:
				var component = obj.meta.lookup(component_ref.values()[0])
				if component != null and component.type == "MonoBehaviour" and component.keys.has("m_FillMethod") and _to_int(component.keys.get("m_Type", 0)) == 3:
					cfg["fill_image"] = true
	ctl.set_meta(selectable_script.META, cfg)
	var fields: Dictionary = {"m_TargetGraphic": "target"}
	fields.merge(refs, true)
	var drives: bool = false
	for field in fields:
		var ref = keys.get(field)
		if typeof(ref) != TYPE_ARRAY or ref.size() < 2 or ref[1] == 0:
			continue
		if field == "m_TargetGraphic" and cfg["transition"] != 1:
			continue
		drives = true
		var np: NodePath = _ref_path(ref, obj, ctl, String(selectable_script.META), fields[field])
		if np != NodePath():
			cfg = ctl.get_meta(selectable_script.META)
			cfg[fields[field]] = np
			ctl.set_meta(selectable_script.META, cfg)
	if drives:
		_ensure_helper(ctl, state, selectable_script.HELPER, selectable_script)


var _families: Dictionary = {}   # font → [regular, bold, italic, bold italic]

## Bold and italic of a font that comes as one file: synthesized. A TextMeshPro font asset says
## how (TextMeshPro makes both from the regular glyphs as well: `italicStyle` is the slant in
## hundredths, 35 by default).
func _font_family(font: Font) -> Array:
	if font == null:
		return UiText.FONTS
	if not _families.has(font):
		var slant: float = 0.2
		if font.has_meta(META_FONT_ASSET):
			var info: Dictionary = font.get_meta(META_FONT_ASSET)
			if not bool(info.get("source", false)) and str(info.get("family", "")).is_empty():
				return UiText.FONTS
			slant = clampf(float(info.get("italic", 35.0)) * 0.01, 0.0, 1.0)
		var bold := FontVariation.new()
		bold.base_font = font
		bold.variation_embolden = 0.8
		var italic := FontVariation.new()
		italic.base_font = font
		italic.variation_transform = Transform2D(Vector2(1.0, slant), Vector2(0.0, 1.0), Vector2.ZERO)
		var both := FontVariation.new()
		both.base_font = font
		both.variation_embolden = 0.8
		both.variation_transform = italic.variation_transform
		_families[font] = [font, bold, italic, both]
	return _families[font]


## The fonts of a TextMeshPro component: its font asset (see handle_scripted_object), or the
## stand-in family when the asset is not in the project (TextMeshPro's own LiberationSans SDF).
func _tmp_fonts(keys: Dictionary, obj: RefCounted) -> Array:
	if obj == null or not keys.has("m_fontAsset"):
		return UiText.FONTS
	var ref: Array = obj.get_ref(keys, "m_fontAsset")
	if ref.size() < 3 or ref[1] == 0 or typeof(ref[2]) != TYPE_STRING or obj.meta.lookup_meta_by_guid(ref[2]) == null:
		return UiText.FONTS
	return _font_family(obj.meta.get_godot_resource(ref, true) as Font)


## A text component on its Control: the settings go to the `unidot_text` metadata and
## runtime/ui_text.gd renders them (as it does when a script changes the text later).
func _text_control(ctl: Control, settings: Dictionary, color: Color, enabled: bool, h: int, v: int, fonts: Array, state: RefCounted) -> void:
	if ctl is RichTextLabel:
		ctl.horizontal_alignment = h
		ctl.vertical_alignment = v
		UiText.set_fonts(ctl, fonts)
		ctl.set_meta(UiText.META, settings)
		UiText.render(ctl)
		Graphic.update(ctl, {"color": color, "enabled": enabled})
		if UiText.needs_layout(settings):
			_ensure_helper(ctl, state, UiText.HELPER, text_fit_script)
	elif ctl is Button:
		# a text on the object of a button itself
		ctl.text = UiText.plain(str(settings["text"]), bool(settings["rich"]), int(settings["style"]), bool(settings["tmp"]))
		ctl.add_theme_font_override("font", fonts[int(settings["style"]) & 3])
		ctl.add_theme_font_size_override("font_size", maxi(int(round(float(settings["size"]))), 1))
		for item in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color", "font_disabled_color"]:
			ctl.add_theme_color_override(item, color if enabled else Color(color.r, color.g, color.b, 0.0))


func _configure_text(ctl: Control, keys: Dictionary, obj: RefCounted, state: RefCounted) -> void:
	var fd: Dictionary = keys["m_FontData"] if keys.get("m_FontData") is Dictionary else {}
	var align: int = _to_int(fd.get("m_Alignment", 0))
	var overflows: bool = _to_int(fd.get("m_HorizontalOverflow", 0)) != 0 or _to_int(fd.get("m_VerticalOverflow", 0)) != 0
	var settings: Dictionary = {
		"text": str(keys["m_Text"]) if keys.get("m_Text") != null else "",
		"tmp": false,
		"rich": _to_int(fd.get("m_RichText", 1)) != 0,
		"size": _to_float(fd.get("m_FontSize", 14)),
		"style": _to_int(fd.get("m_FontStyle", 0)) & 3,
		"auto": _to_int(fd.get("m_BestFit", 0)) != 0,
		"min": _to_float(fd.get("m_MinSize", 10)),
		"max": _to_float(fd.get("m_MaxSize", 40)),
		"wrap": _to_int(fd.get("m_HorizontalOverflow", 0)) == 0,
		"overflow": 0 if overflows else 3,
	}
	# the built-in font is Arial; a font of the project comes as one file
	var font: Font = null
	var fref: Array = obj.get_ref(fd, "m_Font") if fd.has("m_Font") else [null, 0, null, null]
	if fref[1] != 0 and obj.meta.lookup_meta(fref) != null:
		font = obj.meta.get_godot_resource(fref, true) as Font
	var col: Color = keys["m_Color"] if keys.get("m_Color") is Color else Color.WHITE
	_text_control(ctl, settings, col, _to_int(keys.get("m_Enabled", 1)) != 0,
		[HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_RIGHT][align % 3],
		[VERTICAL_ALIGNMENT_TOP, VERTICAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_BOTTOM][clampi(int(align / 3), 0, 2)],
		_font_family(font), state)


## The `unidot_text` settings of a TextMeshPro component (TextMeshProUGUI and the 3D TextMeshPro).
func _tmp_settings(keys: Dictionary) -> Dictionary:
	var wrap: bool = _to_int(keys.get("m_enableWordWrapping", 1)) != 0
	if keys.has("m_TextWrappingMode"):
		wrap = _to_int(keys["m_TextWrappingMode"]) in [1, 2]
	return {
		"text": str(keys["m_text"]) if keys.get("m_text") != null else "",
		"tmp": true,
		"rich": _to_int(keys.get("m_isRichText", 1)) != 0,
		"size": _to_float(keys.get("m_fontSize", 36.0)),
		"style": _to_int(keys.get("m_fontStyle", 0)),
		"auto": _to_int(keys.get("m_enableAutoSizing", 0)) != 0,
		"min": _to_float(keys.get("m_fontSizeMin", 18.0)),
		"max": _to_float(keys.get("m_fontSizeMax", 72.0)),
		"wrap": wrap,
		"overflow": _to_int(keys.get("m_overflowMode", 0)),
	}


func _configure_tmp(ctl: Control, keys: Dictionary, obj: RefCounted, state: RefCounted) -> void:
	# files written before TextMeshPro 2.1 hold both alignments in one value
	var ha: int = _to_int(keys.get("m_HorizontalAlignment", 1))
	var va: int = _to_int(keys.get("m_VerticalAlignment", 256))
	var combined: int = _to_int(keys.get("m_textAlignment", 65535))
	if combined != 65535:
		ha = combined & 0xFF
		va = combined & 0xFF00
	var h: int = _tmp_halign(ha)
	var v: int = _tmp_valign(va)
	var col: Color = keys["m_fontColor"] if keys.get("m_fontColor") is Color else Color.WHITE
	_text_control(ctl, _tmp_settings(keys), col, _to_int(keys.get("m_Enabled", 1)) != 0, h, v, _tmp_fonts(keys, obj), state)


# ---------------------------------------------------------------------------------------------
# prefab instance overrides
# ---------------------------------------------------------------------------------------------

## Unity fields by which an overridden component is recognized when its file id is not known
## (a component inside a nested prefab instance): first field of the property path → kinds.
const _OVERRIDE_FIELDS := {
	"TextMeshProUGUI": ["m_text", "m_fontSize", "m_fontStyle", "m_fontColor", "m_fontColor32", "m_enableAutoSizing", "m_fontSizeMin", "m_fontSizeMax", "m_enableWordWrapping", "m_TextWrappingMode", "m_overflowMode", "m_isRichText", "m_HorizontalAlignment", "m_VerticalAlignment", "m_textAlignment"],
	"Text": ["m_Text", "m_FontData", "m_Color"],
	"Image": ["m_Sprite", "m_Type", "m_PreserveAspect", "m_FillAmount", "m_FillMethod", "m_Color"],
	"RawImage": ["m_Texture", "m_UVRect", "m_Color"],
	"Toggle": ["m_IsOn", "graphic", "toggleTransition", "m_Interactable", "m_Colors", "m_Transition", "m_TargetGraphic"],
	"Slider": ["m_Value", "m_MinValue", "m_MaxValue", "m_WholeNumbers", "m_Direction", "m_FillRect", "m_HandleRect", "m_Interactable", "m_Colors", "m_Transition", "m_TargetGraphic"],
	"Scrollbar": ["m_Value", "m_Size", "m_Direction", "m_HandleRect", "m_Interactable", "m_Colors", "m_Transition", "m_TargetGraphic"],
	"ScrollRect": ["m_Content", "m_Viewport", "m_Horizontal", "m_Vertical", "m_MovementType", "m_ScrollSensitivity", "m_HorizontalScrollbar", "m_VerticalScrollbar", "m_HorizontalScrollbarVisibility", "m_VerticalScrollbarVisibility", "m_HorizontalScrollbarSpacing", "m_VerticalScrollbarSpacing"],
	"InputField": ["m_Text", "m_CharacterLimit", "m_TextComponent", "m_Placeholder", "m_Interactable", "m_Colors", "m_Transition", "m_TargetGraphic"],
	"TMP_InputField": ["m_Text", "m_CharacterLimit", "m_TextComponent", "m_Placeholder", "m_Interactable", "m_Colors", "m_Transition", "m_TargetGraphic"],
	"Dropdown": ["m_Value", "m_Options", "m_CaptionText", "m_Interactable", "m_Colors", "m_Transition", "m_TargetGraphic"],
	"TMP_Dropdown": ["m_Value", "m_Options", "m_CaptionText", "m_Interactable", "m_Colors", "m_Transition", "m_TargetGraphic"],
	"Button": ["m_OnClick", "m_Interactable", "m_Colors", "m_Transition", "m_TargetGraphic"],
	"LayoutElement": ["m_IgnoreLayout", "m_MinWidth", "m_MinHeight", "m_PreferredWidth", "m_PreferredHeight", "m_FlexibleWidth", "m_FlexibleHeight", "m_LayoutPriority"],
	"HorizontalLayoutGroup": ["m_Padding", "m_ChildAlignment", "m_Spacing", "m_ChildForceExpandWidth", "m_ChildForceExpandHeight", "m_ChildControlWidth", "m_ChildControlHeight", "m_ChildScaleWidth", "m_ChildScaleHeight", "m_ReverseArrangement"],
	"VerticalLayoutGroup": ["m_Padding", "m_ChildAlignment", "m_Spacing", "m_ChildForceExpandWidth", "m_ChildForceExpandHeight", "m_ChildControlWidth", "m_ChildControlHeight", "m_ChildScaleWidth", "m_ChildScaleHeight", "m_ReverseArrangement"],
	"GridLayoutGroup": ["m_Padding", "m_ChildAlignment", "m_Spacing", "m_CellSize", "m_StartCorner", "m_StartAxis", "m_Constraint", "m_ConstraintCount"],
	"ContentSizeFitter": ["m_HorizontalFit", "m_VerticalFit"],
	"AspectRatioFitter": ["m_AspectMode", "m_AspectRatio"],
	"Mask": ["m_ShowMaskGraphic"],
}


## A UI component of a prefab instance is overridden (`uprops`: Unity property path → value;
## struct members arrive one by one, `m_Color.r`). The component's settings live in metadata, so
## the override is a change of that metadata, rendered by the same run-time modules. → true when
## the component is one of ours (the default would turn `m_Enabled` into the node's visibility,
## hiding the whole object with its children).
func convert_monobehaviour_properties(obj: RefCounted, node: Node, uprops: Dictionary) -> bool:
	var ctl: Control = control_of(node)
	if ctl == null or not ctl.has_meta(META_COMPONENTS):
		return false
	var kinds: Dictionary = ctl.get_meta(META_COMPONENTS)
	var kind: String = str(kinds.get(obj.modification_source_fileid, ""))
	if kind == "":
		# by the fields: the first component of the object that has one of them
		var fields: Dictionary = {}
		for key in uprops:
			fields[str(key).get_slice(".", 0)] = true
		for candidate in kinds.values():
			for field in _OVERRIDE_FIELDS.get(candidate, []):
				if fields.has(field):
					kind = candidate
					break
			if kind != "":
				break
	if kind == "":
		if uprops.size() == 1 and uprops.has("m_Enabled") and kinds.size() == 1:
			kind = str(kinds.values()[0])
		else:
			return false
	_override_component(kind, ctl, uprops, obj)
	stats["overrides"] = int(stats.get("overrides", 0)) + 1
	return true


## A colour given whole or by members (`key.r` ...), over `base`.
func _color_override(uprops: Dictionary, key: String, base: Color) -> Color:
	if uprops.get(key) is Color:
		return uprops[key]
	var c: Color = base
	for member in ["r", "g", "b", "a"]:
		if uprops.has(key + "." + member):
			c[member] = _to_float(uprops[key + "." + member])
	return c


func _has_field(uprops: Dictionary, field: String) -> bool:
	for key in uprops:
		if str(key) == field or str(key).begins_with(field + "."):
			return true
	return false


func _override_component(kind: String, ctl: Control, uprops: Dictionary, obj: RefCounted) -> void:
	match kind:
		"TextMeshProUGUI", "Text":
			_override_text(kind == "TextMeshProUGUI", ctl, uprops)
		"Image", "RawImage":
			var graphic: Dictionary = {}
			if _has_field(uprops, "m_Color"):
				graphic["color"] = _color_override(uprops, "m_Color", Graphic.color(ctl))
			if uprops.has("m_Enabled"):
				graphic["enabled"] = _to_int(uprops["m_Enabled"]) != 0
			var tex_key: String = "m_Sprite" if kind == "Image" else "m_Texture"
			if typeof(uprops.get(tex_key)) == TYPE_ARRAY:
				var info: Dictionary = _sprite(uprops[tex_key], obj) if kind == "Image" else {"texture": _sprite_texture(uprops[tex_key], obj)}
				var tex: Texture2D = info.get("texture")
				if ctl is TextureRect:
					ctl.texture = tex if tex != null else _white_texture()
					ctl.set_meta("unidot_no_sprite", tex == null)
				else:
					graphic["texture"] = tex
				# (the way the sprite is drawn - sliced, filled - stays that of the prefab, with
				# the new sprite's border)
				var old: Dictionary = Graphic.state(ctl).get("sprite", {})
				if not old.is_empty() and info.has("border"):
					var changed: Dictionary = old.duplicate()
					changed["border"] = info["border"]
					graphic["sprite"] = changed
			if uprops.has("m_FillAmount") and not (Graphic.state(ctl).get("sprite", {}) as Dictionary).is_empty():
				var filled: Dictionary = (graphic.get("sprite", Graphic.state(ctl)["sprite"]) as Dictionary).duplicate()
				filled["amount"] = _to_float(uprops["m_FillAmount"])
				graphic["sprite"] = filled
			if ctl is TextureRect and uprops.has("m_PreserveAspect"):
				ctl.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED if _to_int(uprops["m_PreserveAspect"]) != 0 else TextureRect.STRETCH_SCALE
			if not graphic.is_empty():
				Graphic.update(ctl, graphic)
		"Button", "Toggle", "Slider", "Scrollbar", "InputField", "TMP_InputField", "Dropdown", "TMP_Dropdown":
			_override_selectable(kind, ctl, uprops)
		"ScrollRect":
			var scroll: Dictionary = (ctl.get_meta(scroll_rect_script.META) as Dictionary).duplicate(true) if ctl.has_meta(scroll_rect_script.META) else {}
			for entry in [["m_Horizontal", "horizontal"], ["m_Vertical", "vertical"]]:
				if uprops.has(entry[0]):
					scroll[entry[1]] = _to_int(uprops[entry[0]]) != 0
			if uprops.has("m_MovementType"):
				scroll["movement"] = _to_int(uprops["m_MovementType"])
			if uprops.has("m_ScrollSensitivity"):
				scroll["sensitivity"] = _to_float(uprops["m_ScrollSensitivity"])
			var vis: Array = (scroll.get("visibility", [0, 0]) as Array).duplicate()
			var gap: Array = (scroll.get("spacing", [0.0, 0.0]) as Array).duplicate()
			for entry in [["m_HorizontalScrollbarVisibility", 0], ["m_VerticalScrollbarVisibility", 1]]:
				if uprops.has(entry[0]):
					vis[entry[1]] = _to_int(uprops[entry[0]])
			for entry in [["m_HorizontalScrollbarSpacing", 0], ["m_VerticalScrollbarSpacing", 1]]:
				if uprops.has(entry[0]):
					gap[entry[1]] = _to_float(uprops[entry[0]])
			scroll["visibility"] = vis
			scroll["spacing"] = gap
			ctl.set_meta(scroll_rect_script.META, scroll)
		"Mask":
			if uprops.has("m_ShowMaskGraphic") or uprops.has("m_Enabled"):
				var mask_on: bool = _to_int(uprops.get("m_Enabled", 1)) != 0
				Graphic.update(ctl, {"hidden": mask_on and _to_int(uprops.get("m_ShowMaskGraphic", 0 if Graphic.state(ctl)["hidden"] else 1)) == 0})
			if uprops.has("m_Enabled"):
				ctl.clip_contents = _to_int(uprops["m_Enabled"]) != 0
		"RectMask2D":
			if uprops.has("m_Enabled"):
				ctl.clip_contents = _to_int(uprops["m_Enabled"]) != 0
		"LayoutElement":
			var le: Dictionary = (ctl.get_meta("unidot_layout_element") as Dictionary).duplicate() if ctl.has_meta("unidot_layout_element") else {"min": Vector2(-1, -1), "pref": Vector2(-1, -1), "flex": Vector2(-1, -1), "ignore": false, "priority": 1, "enabled": true}
			for entry in [["m_MinWidth", "min", 0], ["m_MinHeight", "min", 1], ["m_PreferredWidth", "pref", 0], ["m_PreferredHeight", "pref", 1], ["m_FlexibleWidth", "flex", 0], ["m_FlexibleHeight", "flex", 1]]:
				if uprops.has(entry[0]):
					var v2: Vector2 = le[entry[1]]
					v2[entry[2]] = _to_float(uprops[entry[0]])
					le[entry[1]] = v2
			if uprops.has("m_IgnoreLayout"):
				le["ignore"] = _to_int(uprops["m_IgnoreLayout"]) != 0
			if uprops.has("m_LayoutPriority"):
				le["priority"] = _to_int(uprops["m_LayoutPriority"])
			if uprops.has("m_Enabled"):
				le["enabled"] = _to_int(uprops["m_Enabled"]) != 0
			ctl.set_meta("unidot_layout_element", le)
		"HorizontalLayoutGroup", "VerticalLayoutGroup", "GridLayoutGroup":
			if not ctl.has_meta("unidot_layout"):
				return
			var lay: Dictionary = (ctl.get_meta("unidot_layout") as Dictionary).duplicate()
			var pad: Array = (lay.get("padding", [0, 0, 0, 0]) as Array).duplicate()
			for entry in [["m_Padding.m_Left", 0], ["m_Padding.m_Right", 1], ["m_Padding.m_Top", 2], ["m_Padding.m_Bottom", 3]]:
				if uprops.has(entry[0]):
					pad[entry[1]] = _to_int(uprops[entry[0]])
			lay["padding"] = pad
			if uprops.has("m_ChildAlignment"):
				lay["align"] = _to_int(uprops["m_ChildAlignment"])
			if kind == "GridLayoutGroup":
				for entry in [["m_CellSize", "cell"], ["m_Spacing", "spacing2"]]:
					var v2: Vector2 = lay.get(entry[1], Vector2.ZERO)
					if uprops.get(entry[0]) is Vector2:
						v2 = uprops[entry[0]]
					if uprops.has(entry[0] + ".x"):
						v2.x = _to_float(uprops[entry[0] + ".x"])
					if uprops.has(entry[0] + ".y"):
						v2.y = _to_float(uprops[entry[0] + ".y"])
					lay[entry[1]] = v2
				for entry in [["m_StartCorner", "corner"], ["m_StartAxis", "axis"], ["m_Constraint", "constraint"], ["m_ConstraintCount", "count"]]:
					if uprops.has(entry[0]):
						lay[entry[1]] = _to_int(uprops[entry[0]])
			else:
				if uprops.has("m_Spacing"):
					lay["spacing"] = _to_float(uprops["m_Spacing"])
				for entry in [["m_ChildControlWidth", "control_w"], ["m_ChildControlHeight", "control_h"], ["m_ChildForceExpandWidth", "expand_w"], ["m_ChildForceExpandHeight", "expand_h"],
						["m_ChildScaleWidth", "scale_w"], ["m_ChildScaleHeight", "scale_h"], ["m_ReverseArrangement", "reverse"]]:
					if uprops.has(entry[0]):
						lay[entry[1]] = _to_int(uprops[entry[0]]) != 0
			_override_enabled(lay, uprops)
			ctl.set_meta("unidot_layout", lay)
			if bool(lay.get("enabled", true)):
				_add_helper(ctl, "UnidotLayout", layout_group_script, _scene_root(ctl))
		"ContentSizeFitter":
			var fit: Dictionary = (ctl.get_meta("unidot_fitter") as Dictionary).duplicate() if ctl.has_meta("unidot_fitter") else {"h": 0, "v": 0}
			if uprops.has("m_HorizontalFit"):
				fit["h"] = _to_int(uprops["m_HorizontalFit"])
			if uprops.has("m_VerticalFit"):
				fit["v"] = _to_int(uprops["m_VerticalFit"])
			_override_enabled(fit, uprops)
			ctl.set_meta("unidot_fitter", fit)
			if bool(fit.get("enabled", true)):
				_add_helper(ctl, "UnidotLayout", layout_group_script, _scene_root(ctl))
		"AspectRatioFitter":
			var asp: Dictionary = (ctl.get_meta("unidot_aspect") as Dictionary).duplicate() if ctl.has_meta("unidot_aspect") else {"mode": 0, "ratio": 1.0}
			if uprops.has("m_AspectMode"):
				asp["mode"] = _to_int(uprops["m_AspectMode"])
			if uprops.has("m_AspectRatio"):
				asp["ratio"] = maxf(_to_float(uprops["m_AspectRatio"]), 0.001)
			_override_enabled(asp, uprops)
			ctl.set_meta("unidot_aspect", asp)
			if bool(asp.get("enabled", true)) and int(asp["mode"]) != 0:
				_add_helper(ctl, "UnidotLayout", layout_group_script, _scene_root(ctl))
		_:
			pass


func _override_text(tmp: bool, ctl: Control, uprops: Dictionary) -> void:
	var changes: Dictionary = {}
	var fields: Array = [["m_text", "text"], ["m_fontSize", "size"], ["m_fontStyle", "style"], ["m_enableAutoSizing", "auto"], ["m_fontSizeMin", "min"], ["m_fontSizeMax", "max"], ["m_overflowMode", "overflow"], ["m_isRichText", "rich"]]
	if not tmp:
		fields = [["m_Text", "text"], ["m_FontData.m_FontSize", "size"], ["m_FontData.m_FontStyle", "style"], ["m_FontData.m_BestFit", "auto"], ["m_FontData.m_MinSize", "min"], ["m_FontData.m_MaxSize", "max"], ["m_FontData.m_RichText", "rich"]]
	for entry in fields:
		if not uprops.has(entry[0]):
			continue
		var v = uprops[entry[0]]
		match entry[1]:
			"text":
				changes["text"] = str(v) if v != null else ""
			"size", "min", "max":
				changes[entry[1]] = _to_float(v)
			"style":
				changes["style"] = _to_int(v) if tmp else (_to_int(v) & 3)
			"overflow":
				changes["overflow"] = _to_int(v)
			_:
				changes[entry[1]] = _to_int(v) != 0
	var current: Dictionary = UiText.settings(ctl)
	if tmp:
		if uprops.has("m_TextWrappingMode"):
			changes["wrap"] = _to_int(uprops["m_TextWrappingMode"]) in [1, 2]
		elif uprops.has("m_enableWordWrapping"):
			changes["wrap"] = _to_int(uprops["m_enableWordWrapping"]) != 0
	elif uprops.has("m_FontData.m_HorizontalOverflow") or uprops.has("m_FontData.m_VerticalOverflow"):
		var wraps: bool = _to_int(uprops["m_FontData.m_HorizontalOverflow"]) == 0 if uprops.has("m_FontData.m_HorizontalOverflow") else bool(current["wrap"])
		var cut: bool = _to_int(uprops["m_FontData.m_VerticalOverflow"]) == 0 if uprops.has("m_FontData.m_VerticalOverflow") else int(current["overflow"]) != 0
		changes["wrap"] = wraps
		changes["overflow"] = 3 if wraps and cut else 0
	if ctl is RichTextLabel:
		if tmp:
			var ha: int = _to_int(uprops.get("m_HorizontalAlignment", -1))
			var va: int = _to_int(uprops.get("m_VerticalAlignment", -1))
			if _to_int(uprops.get("m_textAlignment", 65535)) != 65535:
				ha = _to_int(uprops["m_textAlignment"]) & 0xFF
				va = _to_int(uprops["m_textAlignment"]) & 0xFF00
			if ha >= 0:
				ctl.horizontal_alignment = _tmp_halign(ha)
			if va >= 0:
				ctl.vertical_alignment = _tmp_valign(va)
		elif uprops.has("m_FontData.m_Alignment"):
			var align: int = _to_int(uprops["m_FontData.m_Alignment"])
			ctl.horizontal_alignment = [HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_RIGHT][align % 3]
			ctl.vertical_alignment = [VERTICAL_ALIGNMENT_TOP, VERTICAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_BOTTOM][clampi(int(align / 3), 0, 2)]
		if not changes.is_empty() and ctl.has_meta(UiText.META):
			UiText.update(ctl, changes)
			if UiText.needs_layout(UiText.settings(ctl)):
				_add_helper(ctl, UiText.HELPER, text_fit_script, _scene_root(ctl))
	var color_key: String = "m_fontColor" if tmp else "m_Color"
	var graphic: Dictionary = {}
	if _has_field(uprops, color_key):
		graphic["color"] = _color_override(uprops, color_key, Graphic.color(ctl))
	if uprops.has("m_Enabled"):
		graphic["enabled"] = _to_int(uprops["m_Enabled"]) != 0
	if not graphic.is_empty() and ctl is RichTextLabel:
		Graphic.update(ctl, graphic)


## `m_Enabled` of a layout component: the settings stay, with `enabled: false` (an instance
## cannot store the removal of metadata its prefab has).
func _override_enabled(cfg: Dictionary, uprops: Dictionary) -> void:
	if uprops.has("m_Enabled"):
		if _to_int(uprops["m_Enabled"]) != 0:
			cfg.erase("enabled")
		else:
			cfg["enabled"] = false


## The root of the scene being built that `n` is in (the owner of everything saved with it).
func _scene_root(n: Node) -> Node:
	var o: Node = n
	while o.owner != null:
		o = o.owner
	return o


func _override_selectable(kind: String, ctl: Control, uprops: Dictionary) -> void:
	var cfg: Dictionary = (ctl.get_meta(selectable_script.META) as Dictionary).duplicate(true) if ctl.has_meta(selectable_script.META) else {"transition": 1}
	if uprops.has("m_Interactable"):
		var on: bool = _to_int(uprops["m_Interactable"]) != 0
		if ctl is BaseButton:
			ctl.disabled = not on
		elif ctl is Slider or ctl is LineEdit:
			ctl.editable = on
	if uprops.has("m_Transition"):
		cfg["transition"] = _to_int(uprops["m_Transition"])
	if _has_field(uprops, "m_Colors"):
		var block: Dictionary = selectable_script.DEFAULT_COLORS.duplicate()
		block.merge(cfg.get("colors", {}), true)
		for pair in [["m_Colors.m_NormalColor", "normalColor"], ["m_Colors.m_HighlightedColor", "highlightedColor"], ["m_Colors.m_PressedColor", "pressedColor"], ["m_Colors.m_SelectedColor", "selectedColor"], ["m_Colors.m_DisabledColor", "disabledColor"]]:
			if _has_field(uprops, pair[0]):
				block[pair[1]] = _color_override(uprops, pair[0], block[pair[1]])
		if uprops.has("m_Colors.m_ColorMultiplier"):
			block["colorMultiplier"] = _to_float(uprops["m_Colors.m_ColorMultiplier"])
		if uprops.has("m_Colors.m_FadeDuration"):
			block["fadeDuration"] = _to_float(uprops["m_Colors.m_FadeDuration"])
		cfg["colors"] = block
	if uprops.has("m_Direction") and kind in ["Slider", "Scrollbar"]:
		cfg["direction"] = _to_int(uprops["m_Direction"])
	ctl.set_meta(selectable_script.META, cfg)
	match kind:
		"Toggle":
			if uprops.has("m_IsOn") and ctl is BaseButton:
				ctl.button_pressed = _to_int(uprops["m_IsOn"]) != 0
		"Slider", "Scrollbar":
			if ctl is Range:
				if kind == "Scrollbar" and (uprops.has("m_Size") or uprops.has("m_Direction")):
					var sbar: Dictionary = (ctl.get_meta("unidot_scrollbar") as Dictionary).duplicate() if ctl.has_meta("unidot_scrollbar") else {}
					if uprops.has("m_Size"):
						sbar["size"] = _to_float(uprops["m_Size"])
					if uprops.has("m_Direction"):
						sbar["direction"] = _to_int(uprops["m_Direction"])
					ctl.set_meta("unidot_scrollbar", sbar)
				if kind == "Slider":
					if uprops.has("m_MinValue"):
						ctl.min_value = _to_float(uprops["m_MinValue"])
					if uprops.has("m_MaxValue"):
						ctl.max_value = _to_float(uprops["m_MaxValue"])
					if uprops.has("m_WholeNumbers"):
						ctl.rounded = _to_int(uprops["m_WholeNumbers"]) != 0
						ctl.step = 1.0 if ctl.rounded else 0.0
				if uprops.has("m_Value"):
					ctl.value = _to_float(uprops["m_Value"])
		"InputField", "TMP_InputField":
			if ctl is LineEdit:
				if uprops.has("m_Text"):
					ctl.text = str(uprops["m_Text"]) if uprops["m_Text"] != null else ""
				if uprops.has("m_CharacterLimit"):
					ctl.max_length = _to_int(uprops["m_CharacterLimit"])
		"Dropdown", "TMP_Dropdown":
			if ctl is OptionButton and uprops.has("m_Value"):
				ctl.selected = _to_int(uprops["m_Value"])
	# (what the selectable drives - tint, check mark, fill and handle - follows when the scene
	# is complete: _finish_widgets)


func _tmp_halign(ha: int) -> int:
	match ha:
		2, 32:
			return HORIZONTAL_ALIGNMENT_CENTER
		4:
			return HORIZONTAL_ALIGNMENT_RIGHT
		8, 16:
			return HORIZONTAL_ALIGNMENT_FILL
	return HORIZONTAL_ALIGNMENT_LEFT


func _tmp_valign(va: int) -> int:
	match va:
		512, 2048, 4096, 8192:
			return VERTICAL_ALIGNMENT_CENTER
		1024:
			return VERTICAL_ALIGNMENT_BOTTOM
	return VERTICAL_ALIGNMENT_TOP


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
