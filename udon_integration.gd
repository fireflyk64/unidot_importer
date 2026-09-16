# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## udon2godot integration.
##
## Attaches the SafeGDScript classes produced by `udon2godot` (https://github.com/…/udon2godot)
## to the nodes unidot creates for UdonSharp behaviours, fills their exported fields from the
## serialized MonoBehaviour (references are resolved once the whole scene exists), marks VRChat
## SDK components (pickups, stations, object sync/pool, mirrors, video players, scene descriptor)
## for the udon_runtime adapters, converts Unity UI hierarchies to Control nodes and wires
## UnityEvent persistent calls (Button.onClick → UdonBehaviour.SendCustomEvent).
##
## Enable it with the project settings
##   unidot/extra_plugins = ["res://addons/unidot_importer/udon_integration.gd"]
##   udon/manifest        = "res://converted/udon_manifest.json"   (written by udon2godot --manifest)
## A diagnostics report is written to `udon/import_report` (default res://udon_import_report.json).

const UDON_BEHAVIOUR_GUID := "45115577ef41a5b4ca741ed302693907"

## VRChat SDK component scripts by GUID (asset packages rarely ship the SDK, so the field
## signature fallback in `_identify_component` covers the rest).
const KNOWN_COMPONENTS := {
	"661092b4961be7145bfbe56e1e62337b": "VRC_Pickup",
}

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
	"e19747de3f5aca642ab2be37e372fb86": "Outline",
	"76c392e42b5098c458856cdf6ecaaaa1": "EventSystem",
	"4f231c4fb786f3946a6b90b886c48677": "StandaloneInputModule",
	"f4688fdb7df04437aeb418b961361dc5": "TextMeshProUGUI",
	"9541d86e2fd84c1d9990edf0852d74ab": "TextMeshPro",
	"2da0c512f12947e489f739169773d7ca": "TMP_InputField",
}

## Unity UI components that decide the Control class of a RectTransform GameObject (first wins).
const UI_PRIMARY_ORDER := ["Button", "Toggle", "Slider", "Scrollbar", "InputField", "TMP_InputField", "VRCUrlInputField", "Dropdown", "TMP_Dropdown", "ScrollRect", "Text", "TextMeshProUGUI", "Image", "RawImage"]

var database = null
var manifest_path: String = ""
var manifest: Dictionary = {}          # class name → manifest entry
var guid_to_class: Dictionary = {}     # script guid → class name
var script_to_class: Dictionary = {}   # res:// script path → class name
var _pending_refs: Array = []          # {owner, node, prop, index, ref, kind, elem}
var _pending_events: Array = []        # {owner, source, signal, ref, event, unbinds}
var _report: Dictionary = {
	"scripts_attached": 0,
	"unknown_scripts": {},
	"missing_proxies": [],
	"unresolved_references": [],
	"missing_resources": [],
	"unsupported_fields": [],
	"ui_nodes": 0,
	"events_wired": 0,
	"components": {},
}
var _unknown_seen: Dictionary = {}


func set_database(db) -> void:
	database = db
	_load_manifest()


func _load_manifest() -> void:
	manifest_path = str(ProjectSettings.get_setting("udon/manifest", "res://converted/udon_manifest.json"))
	manifest = {}
	guid_to_class = {}
	script_to_class = {}
	if not FileAccess.file_exists(manifest_path):
		push_warning("udon_integration: manifest not found at " + manifest_path + "; UdonSharp scripts will not be attached")
		return
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(manifest_path)) != OK:
		push_error("udon_integration: cannot parse " + manifest_path + ": " + json.get_error_message())
		return
	var data: Dictionary = json.data
	for cname in data.get("classes", {}):
		var entry: Dictionary = data["classes"][cname]
		entry["name"] = cname
		manifest[cname] = entry
		if entry.get("guid") != null:
			guid_to_class[str(entry["guid"])] = cname
		script_to_class[str(entry.get("script", ""))] = cname
	print("udon_integration: %d converted classes from %s" % [manifest.size(), manifest_path])


# ---------------------------------------------------------------------------------------------
# unidot plugin hooks
# ---------------------------------------------------------------------------------------------

func handle_monobehaviour(obj: RefCounted, state: RefCounted, node: Node, _existing: Node):
	if node == null:
		return null
	var guid: String = str(obj.monoscript[2]) if obj.monoscript[2] != null else ""
	var keys: Dictionary = obj.keys
	if guid == UDON_BEHAVIOUR_GUID:
		_handle_udon_behaviour(obj, state, node)
		return null
	if guid_to_class.has(guid):
		_attach_script(obj, state, node, manifest[guid_to_class[guid]])
		return null
	var kind: String = _identify_component(guid, keys)
	if kind == "":
		_note_unknown(guid, obj, node)
		return null
	if UI_COMPONENTS.values().has(kind) or kind in ["VRCUrlInputField", "TMP_Dropdown", "VRC_UiShape", "Shadow", "AspectRatioFitter"]:
		_configure_ui_component(kind, obj, state, node)
		return null
	_mark_component(kind, obj, state, node)
	return null


func handle_scripted_object(_obj: RefCounted):
	return null


func post_process_avatar(_obj: RefCounted, _state: RefCounted, _node: Node, _avatar_meta: RefCounted):
	pass


func initialize_skelleys(_state: RefCounted, _objs: Array, _is_prefab: bool):
	pass


func setup_post_children(game_object: RefCounted, state: RefCounted, node: Node, _avatar_meta: RefCounted):
	if node == null:
		return
	if node.has_meta("udon_canvas") and str(node.get_meta("udon_canvas").get("mode", "")) == "world":
		_finalize_world_canvas(node)
	# Inactive GameObjects: unidot hides them; udon_runtime's SetActive/activeSelf use process_mode
	# (no Start/Update/OnEnable until a script activates them), so mirror it here.
	if "enabled" in game_object and not game_object.enabled:
		node.process_mode = Node.PROCESS_MODE_DISABLED
	# Unity layer → Godot collision bit (udon_runtime's LayerMask helpers use bit i for layer i);
	# masks come from the project's layer collision matrix (udon/collision_matrix) or allow all,
	# matching Unity's default of colliding with everything.
	var layer: int = _to_int(game_object.keys.get("m_Layer", 0)) if "keys" in game_object else 0
	var matrix: Variant = ProjectSettings.get_setting("udon/collision_matrix", PackedInt32Array())
	var mask: int = 0xFFFFFFFF
	if matrix is PackedInt32Array and layer < matrix.size():
		mask = int(matrix[layer]) & 0xFFFFFFFF
	var bodies: Array = []
	if node is CollisionObject3D:
		bodies.append(node)
	for c in node.get_children():
		if c is CollisionObject3D and (String(c.name).ends_with("Collider") or String(c.name) == "CharacterController"):
			bodies.append(c)
	for b in bodies:
		b.collision_layer = 1 << clampi(layer, 0, 31)
		b.collision_mask = mask
	# Physics bodies scaled to (almost) zero — a Unity idiom for hiding — cannot be scaled in Godot;
	# udon_runtime hides them instead and reports the original scale (see U.set_local_scale).
	if node is CollisionObject3D:
		var sc: Vector3 = node.scale
		if absf(sc.x) < 1e-4 or absf(sc.y) < 1e-4 or absf(sc.z) < 1e-4:
			node.set_meta("udon_zero_scale", Vector3.ZERO)
			node.scale = Vector3.ONE
			node.visible = false
	if not node.has_meta("udon_behaviour"):
		return
	# An UdonBehaviour whose UdonSharp proxy component is missing (script not in the package):
	# fall back to the program asset's name, which UdonSharp keeps equal to the class name.
	if node.get_script() == null:
		var cfg: Dictionary = node.get_meta("udon_behaviour")
		var cname: String = str(cfg.get("program_class", ""))
		if manifest.has(cname):
			var script = load(manifest[cname]["script"])
			if script != null:
				node.set_script(script)
				node.set_meta("udon_class", cname)
				_report["scripts_attached"] += 1
				_report["missing_proxies"].append({"class": cname, "node": str(node.name), "note": "proxy MonoBehaviour missing; exported fields keep their defaults"})


func setup_post_prefab(_prefab_object: RefCounted, _state: RefCounted, _instanced_scene: Node):
	pass


func setup_post_scene(pkgasset: RefCounted, _root_objects: Array, _root_skelleys: Array, state: RefCounted, scene_contents: Node):
	var meta: Resource = pkgasset.parsed_meta
	var owner: Node = scene_contents
	var remaining: Array = []
	for e in _pending_refs:
		if e["owner"] != owner:
			remaining.append(e)
			continue
		_resolve_pending_ref(e, meta, state, scene_contents)
	_pending_refs = remaining
	remaining = []
	for e in _pending_events:
		if e["owner"] != owner:
			remaining.append(e)
			continue
		_resolve_pending_event(e, meta, state, scene_contents)
	_pending_events = remaining
	_save_report()


## Prefab-instance overrides of a scripted component (propertyPath → value / objectReference).
func convert_monobehaviour_properties(obj: RefCounted, node: Node, uprops: Dictionary) -> bool:
	if node == null:
		return false
	var guid: String = str(obj.monoscript[2]) if obj.monoscript[2] != null else ""
	if guid == UDON_BEHAVIOUR_GUID:
		var cfg: Dictionary = node.get_meta("udon_behaviour") if node.has_meta("udon_behaviour") else {}
		_udon_behaviour_config(uprops, cfg)
		node.set_meta("udon_behaviour", cfg)
		return true
	if guid_to_class.has(guid):
		var entry: Dictionary = manifest[guid_to_class[guid]]
		var host: Node = _script_host(node, entry)
		if host == null:
			return true
		for key in uprops:
			_apply_override(host, entry, str(key), uprops[key], obj, node)
		return true
	var kind: String = _identify_component(guid, obj.keys)
	if kind != "" and not UI_COMPONENTS.values().has(kind):
		var meta_key: String = _component_meta_key(kind)
		var cfg2: Dictionary = node.get_meta(meta_key) if node.has_meta(meta_key) else {}
		var conv: Dictionary = _component_config(kind, uprops, obj, node)
		for k in conv:
			cfg2[k] = conv[k]
		node.set_meta(meta_key, cfg2)
		return true
	return false


# ---------------------------------------------------------------------------------------------
# UdonSharp behaviours
# ---------------------------------------------------------------------------------------------

func _attach_script(obj: RefCounted, state: RefCounted, node: Node, entry: Dictionary) -> void:
	var script = load(str(entry["script"]))
	if script == null:
		_report["unsupported_fields"].append({"class": entry["name"], "field": "", "reason": "converted script missing: " + str(entry["script"])})
		return
	var host: Node = node
	if node.get_script() != null and node.get_script() != script:
		# a second UdonSharp behaviour on the same GameObject: it lives on a helper child that
		# udon_runtime's GetComponent treats as a component of the parent
		host = Node.new()
		host.name = str(entry["name"])
		host.set_meta("udon_component_child", true)
		state.add_child(host, node, obj)
		host.set_script(script)
	else:
		node.set_script(script)
		state.add_fileID(node, obj)
	host.set_meta("udon_class", str(entry["name"]))
	_report["scripts_attached"] += 1
	var keys: Dictionary = obj.keys
	# The UdonBehaviour the proxy is backed by resolves to the same node (UI events target it).
	var backing: Array = obj.get_ref(keys, "_udonSharpBackingUdonBehaviour")
	if backing[1] != 0 and (backing[2] == null or backing[2] == "" or backing[2] == obj.meta.guid):
		state.meta.fileid_to_nodepath[backing[1]] = state.scene_contents.get_path_to(host)
	for fname in entry.get("fields", {}):
		var f: Dictionary = entry["fields"][fname]
		if not f.get("exported", false):
			continue
		if not keys.has(fname):
			continue
		_assign_field(host, str(f["gd"]), f["ty"], keys[fname], obj, state, str(entry["name"]) + "." + str(fname))


func _script_host(node: Node, entry: Dictionary) -> Node:
	var cname: String = str(entry["name"])
	if node.has_meta("udon_class") and str(node.get_meta("udon_class")) == cname:
		return node
	for c in node.get_children():
		if c.has_meta("udon_component_child") and c.has_meta("udon_class") and str(c.get_meta("udon_class")) == cname:
			return c
	if node.get_script() != null:
		return node
	return null


## Convert one serialized field value and set it on the host (references are deferred).
func _assign_field(host: Node, prop: String, ty: Dictionary, raw, obj: RefCounted, state: RefCounted, what: String) -> void:
	var kind: String = str(ty.get("kind", "unknown"))
	match kind:
		"array":
			if typeof(raw) != TYPE_ARRAY:
				return
			var elem: Dictionary = ty.get("elem", {})
			var out: Array = []
			var ekind: String = str(elem.get("kind", "unknown"))
			for i in range(raw.size()):
				var v = raw[i]
				if _is_reference_kind(ekind):
					out.append(null)
					_defer_ref(host, prop, i, v, elem, obj, state, what)
				elif ekind == "resource":
					out.append(_resource_for(v, obj, what))
				else:
					out.append(_convert_value(v, elem, what))
			host.set(prop, out)
		"multiarray":
			_report["unsupported_fields"].append({"field": what, "reason": "multi-dimensional arrays are not serialized by Unity"})
		"resource":
			host.set(prop, _resource_for(raw, obj, what))
		_:
			if _is_reference_kind(kind):
				_defer_ref(host, prop, -1, raw, ty, obj, state, what)
			else:
				host.set(prop, _convert_value(raw, ty, what))


func _is_reference_kind(kind: String) -> bool:
	return kind in ["component", "gameobject", "behaviour", "object"]


func _defer_ref(host: Node, prop: String, index: int, raw, ty: Dictionary, obj: RefCounted, state: RefCounted, what: String) -> void:
	if typeof(raw) != TYPE_ARRAY or raw.size() < 4 or raw[1] == 0:
		return  # null reference
	_pending_refs.append({"owner": state.owner, "node": host, "prop": prop, "index": index, "ref": raw, "ty": ty, "what": what, "meta": obj.meta})


func _convert_value(raw, ty: Dictionary, what: String):
	var kind: String = str(ty.get("kind", "unknown"))
	var tname: String = str(ty.get("type", ""))
	match kind:
		"number":
			if tname in ["float", "double", "decimal"]:
				return _to_float(raw)
			return _to_int(raw)
		"bool":
			return _to_int(raw) != 0
		"string":
			if raw == null:
				return ""
			return str(raw)
		"enum":
			return _to_int(raw)
		"struct":
			return _convert_struct(raw, tname, what)
		_:
			return raw


func _convert_struct(raw, tname: String, what: String):
	match tname:
		"Vector2":
			if raw is Vector2:
				return raw
			if raw is Vector3:
				return Vector2(raw.x, raw.y)
		"Vector3":
			if raw is Vector3:
				return raw
			if raw is Vector2:
				return Vector3(raw.x, raw.y, 0.0)
		"Vector4":
			if raw is Quaternion:
				return Vector4(raw.x, raw.y, raw.z, raw.w)
			if raw is Vector3:
				return Vector4(raw.x, raw.y, raw.z, 0.0)
		"Quaternion":
			if raw is Quaternion:
				return raw
		"Color":
			if raw is Color:
				return raw
		"Color32":
			if raw is Color:
				return Color8(int(raw.r), int(raw.g), int(raw.b), int(raw.a))
		"Rect":
			if raw is Rect2:
				return raw
		"Vector2Int":
			if raw is Vector2:
				return Vector2i(raw)
			if raw is Vector3:
				return Vector2i(int(raw.x), int(raw.y))
		"Vector3Int":
			if raw is Vector3:
				return Vector3i(raw)
		"Bounds":
			if raw is Dictionary:
				var c: Vector3 = raw.get("m_Center", Vector3.ZERO)
				var e: Vector3 = raw.get("m_Extent", Vector3.ZERO)
				return AABB(c - e, e * 2.0)
		"LayerMask":
			if raw is Dictionary:
				return _to_int(raw.get("m_Bits", 0))
			return _to_int(raw)
		"AnimationCurve":
			return _curve_from(raw)
		"Gradient":
			return _gradient_from(raw)
		"VRCUrl":
			if raw is Dictionary:
				return str(raw.get("url", ""))
			return str(raw)
		"Matrix4x4":
			return Transform3D()
	if raw is Dictionary or raw is Array:
		_report["unsupported_fields"].append({"field": what, "reason": "struct " + tname + " kept as raw data"})
	return raw


func _curve_from(raw) -> Curve:
	var c := Curve.new()
	if not (raw is Dictionary):
		return c
	var keys: Array = raw.get("m_Curve", [])
	var first: bool = true
	for k in keys:
		var t: float = _to_float(k.get("time", 0.0))
		var v: float = _to_float(k.get("value", 0.0))
		if first:
			c.min_domain = t
			c.max_domain = t
			c.min_value = v
			c.max_value = v
			first = false
		c.min_domain = minf(c.min_domain, t)
		c.max_domain = maxf(c.max_domain, t)
		c.min_value = minf(c.min_value, v)
		c.max_value = maxf(c.max_value, v)
		c.add_point(Vector2(t, v), _to_float(k.get("inSlope", 0.0)), _to_float(k.get("outSlope", 0.0)))
	return c


func _gradient_from(raw) -> Gradient:
	var g := Gradient.new()
	if not (raw is Dictionary):
		return g
	var colors: PackedColorArray = []
	var offsets: PackedFloat32Array = []
	for i in range(8):
		var key: String = "key" + str(i)
		var ck: String = "ctime" + str(i)
		if not raw.has(key) or not raw.has(ck):
			continue
		var c = raw[key]
		if not (c is Color):
			continue
		var t: float = _to_float(raw[ck]) / 65535.0
		colors.append(c)
		offsets.append(t)
	var n: int = _to_int(raw.get("m_NumColorKeys", colors.size()))
	if n < colors.size():
		colors.resize(n)
		offsets.resize(n)
	if colors.size() > 0:
		g.offsets = offsets
		g.colors = colors
	return g


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


func _resource_for(ref, obj: RefCounted, what: String) -> Resource:
	if typeof(ref) != TYPE_ARRAY or ref.size() < 4 or ref[1] == 0:
		return null
	if obj.meta.lookup_meta(ref) == null and not database.guid_to_path.has(str(ref[2])):
		_report["missing_resources"].append({"field": what, "ref": str(ref[2]) + ":" + str(ref[1]), "reason": "asset not in package"})
		return null
	var res: Resource = obj.meta.get_godot_resource(ref, true)
	if res == null:
		_report["missing_resources"].append({"field": what, "ref": str(ref[2]) + ":" + str(ref[1])})
	return res


func _resolve_pending_ref(e: Dictionary, meta: Resource, state: RefCounted, scene_contents: Node) -> void:
	var node: Node = e["node"]
	if not is_instance_valid(node):
		return
	var ref: Array = e["ref"]
	var value = null
	var guid = ref[2]
	var same_file: bool = guid == null or str(guid) == "" or str(guid) == str(meta.guid)
	if same_file:
		var np: NodePath = meta.fileid_to_nodepath.get(ref[1], meta.prefab_fileid_to_nodepath.get(ref[1], NodePath()))
		if np != NodePath():
			value = scene_contents.get_node_or_null(np)
		if value == null:
			_report["unresolved_references"].append({"field": e["what"], "fileID": ref[1], "node": str(scene_contents.get_path_to(node))})
			return
		value = _component_node_for(value, e["ty"])
	else:
		var found_meta = meta.lookup_meta(ref)
		var path: String = str(found_meta.path) if found_meta != null else str(database.guid_to_path.get(str(guid), ""))
		if path.to_lower().ends_with(".prefab"):
			value = _prefab_template(str(guid), found_meta, ref, scene_contents, e["what"])
		else:
			value = _resource_for(ref, _fake_obj(meta), e["what"])
	if value == null:
		return
	if str(e["prop"]) == "@meta":
		# forward reference inside a component setting (a station's exit location, a pickup's
		# ExactGrip): patch the metadata entry the adapter reads
		var mk: String = str(e.get("meta_key", ""))
		if mk != "" and node.has_meta(mk) and value is Node:
			var cfg: Dictionary = node.get_meta(mk)
			cfg[str(e.get("cfg_key", ""))] = node.get_path_to(value)
			node.set_meta(mk, cfg)
		return
	if value is Node:
		# Node references are stored as NodePaths in metadata/udon_refs and bound by
		# udon_behaviour.gd at _ready: PackedScene only turns Node values into paths for
		# properties with a node-type hint, which sandbox scripts do not provide.
		_store_ref(node, str(e["prop"]), int(e["index"]), node.get_path_to(value))
		return
	if int(e["index"]) >= 0:
		var arr = node.get(e["prop"])
		if arr is Array and int(e["index"]) < arr.size():
			arr[int(e["index"])] = value
			node.set(e["prop"], arr)
	else:
		node.set(e["prop"], value)


func _store_ref(node: Node, prop: String, index: int, np: NodePath) -> void:
	var refs: Dictionary = node.get_meta("udon_refs") if node.has_meta("udon_refs") else {}
	if index >= 0:
		var arr: Array = refs.get(prop, []) if refs.get(prop) is Array else []
		var cur = node.get(prop)
		if cur is Array and arr.size() < cur.size():
			arr.resize(cur.size())
		if index >= arr.size():
			arr.resize(index + 1)
		arr[index] = np
		refs[prop] = arr
	else:
		refs[prop] = np
	node.set_meta("udon_refs", refs)


func _fake_obj(meta: Resource) -> RefCounted:
	var o := _RefHolder.new()
	o.meta = meta
	return o


class _RefHolder:
	extends RefCounted
	var meta: Resource = null


## A reference to a component resolves to the node standing in for it; a reference typed as a
## behaviour prefers the script host (the GameObject node or a helper child).
func _component_node_for(node: Node, ty: Dictionary) -> Node:
	var kind: String = str(ty.get("kind", ""))
	if kind == "behaviour":
		var cname: String = str(ty.get("type", ""))
		if node.has_meta("udon_class") and str(node.get_meta("udon_class")) == cname:
			return node
		for c in node.get_children():
			if c.has_meta("udon_component_child") and c.has_meta("udon_class") and str(c.get_meta("udon_class")) == cname:
				return c
	return node


## Prefab assets referenced by scripts become inactive template nodes under `UdonPrefabs`, which
## udon_runtime's Instantiate duplicates (the sandbox scripts export Node-typed fields).
func _prefab_template(guid: String, found_meta: Resource, ref: Array, scene_contents: Node, what: String) -> Node:
	var container: Node = scene_contents.get_node_or_null("UdonPrefabs")
	if container == null:
		container = Node3D.new()
		container.name = "UdonPrefabs"
		container.process_mode = Node.PROCESS_MODE_DISABLED
		container.visible = false
		scene_contents.add_child(container, true)
		container.owner = scene_contents
	var existing: Node = container.get_node_or_null(NodePath("P_" + guid))
	if existing != null:
		return existing
	var path: String = ""
	if found_meta != null:
		path = "res://" + str(found_meta.path)
	if path == "" or not ResourceLoader.exists(path):
		_report["missing_resources"].append({"field": what, "ref": guid + ":" + str(ref[1]), "reason": "prefab scene not imported yet"})
		return null
	var ps = load(path)
	if not (ps is PackedScene):
		_report["missing_resources"].append({"field": what, "ref": guid + ":" + str(ref[1]), "reason": "not a scene: " + path})
		return null
	var inst: Node = ps.instantiate()
	inst.name = "P_" + guid
	inst.set_meta("udon_prefab_template", true)
	container.add_child(inst, true)
	inst.owner = scene_contents
	return inst


# ---------------------------------------------------------------------------------------------
# UdonBehaviour component and VRChat SDK components
# ---------------------------------------------------------------------------------------------

func _handle_udon_behaviour(obj: RefCounted, state: RefCounted, node: Node) -> void:
	var cfg: Dictionary = node.get_meta("udon_behaviour") if node.has_meta("udon_behaviour") else {}
	_udon_behaviour_config(obj.keys, cfg)
	var src: Array = obj.get_ref(obj.keys, "programSource")
	if src[1] != 0:
		var m = obj.meta.lookup_meta(src)
		if m != null:
			cfg["program_class"] = str(m.path).get_file().get_basename()
	node.set_meta("udon_behaviour", cfg)
	state.add_fileID(node, obj)


func _udon_behaviour_config(keys: Dictionary, cfg: Dictionary) -> void:
	if keys.has("interactText"):
		cfg["interact_text"] = str(keys["interactText"])
	if keys.has("proximity"):
		cfg["proximity"] = _to_float(keys["proximity"])
	if keys.has("_syncMethod"):
		cfg["sync_method"] = _to_int(keys["_syncMethod"])
	if keys.has("m_Enabled"):
		cfg["enabled"] = _to_int(keys["m_Enabled"]) != 0


func _identify_component(guid: String, keys: Dictionary) -> String:
	if KNOWN_COMPONENTS.has(guid):
		return KNOWN_COMPONENTS[guid]
	if UI_COMPONENTS.has(guid):
		return UI_COMPONENTS[guid]
	var extra: Variant = ProjectSettings.get_setting("udon/component_guids", {})
	if extra is Dictionary and extra.has(guid):
		return str(extra[guid])
	# field-signature fallback (works without the SDK sources)
	if keys.has("m_EffectColor") and keys.has("m_EffectDistance"):
		return "Shadow"
	if keys.has("m_AspectMode") and keys.has("m_AspectRatio"):
		return "AspectRatioFitter"
	if keys.has("pickupable") and keys.has("AutoHold"):
		return "VRC_Pickup"
	if keys.has("PlayerMobility") and keys.has("disableStationExit"):
		return "VRCStation"
	if keys.has("SynchronizePhysics") and keys.has("AllowCollisionOwnershipTransfer") and not keys.has("programSource"):
		return "VRCObjectSync"
	if keys.has("Pool") and keys.size() < 20:
		return "VRCObjectPool"
	if keys.has("m_ReflectLayers") and keys.has("TurnOffMirrorOcclusion"):
		return "VRC_MirrorReflection"
	if keys.has("spawns") and keys.has("RespawnHeightY"):
		return "VRC_SceneDescriptor"
	if keys.has("blueprintId") and keys.has("Placement"):
		return "VRC_AvatarPedestal"
	if keys.has("roomId") and keys.has("roomName"):
		return "VRC_PortalMarker"
	if keys.has("videoURL") and keys.has("autoPlay"):
		return "VRCVideoPlayer"
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


func _component_meta_key(kind: String) -> String:
	match kind:
		"VRC_Pickup":
			return "udon_pickup"
		"VRCStation":
			return "udon_station"
		"VRCObjectSync":
			return "udon_object_sync"
		"VRCObjectPool":
			return "udon_object_pool"
		"VRC_MirrorReflection":
			return "udon_mirror"
		"VRC_SceneDescriptor":
			return "udon_scene_descriptor"
		"VRC_AvatarPedestal":
			return "udon_avatar_pedestal"
		"VRC_PortalMarker":
			return "udon_portal"
		"VRCVideoPlayer":
			return "udon_video"
	return "udon_" + kind.to_lower()


func _mark_component(kind: String, obj: RefCounted, state: RefCounted, node: Node) -> void:
	var meta_key: String = _component_meta_key(kind)
	var cfg: Dictionary = node.get_meta(meta_key) if node.has_meta(meta_key) else {}
	var conv: Dictionary = _component_config(kind, obj.keys, obj, node)
	for k in conv:
		cfg[k] = conv[k]
	node.set_meta(meta_key, cfg)
	node.add_to_group(meta_key, true)
	state.add_fileID(node, obj)
	_report["components"][kind] = int(_report["components"].get(kind, 0)) + 1


## Component fields → adapter settings (udon_runtime/udon_pickup.gd etc.). Node references are
## stored as NodePaths relative to the node, resolved by the adapter at runtime.
func _component_config(kind: String, keys: Dictionary, obj: RefCounted, node: Node) -> Dictionary:
	var c: Dictionary = {}
	_kind_of_cfg = kind
	match kind:
		"VRC_Pickup":
			_cfg_bool(c, keys, "pickupable", "pickupable")
			_cfg_str(c, keys, "InteractionText", "interaction_text")
			_cfg_str(c, keys, "UseText", "use_text")
			_cfg_float(c, keys, "proximity", "proximity")
			_cfg_int(c, keys, "orientation", "orientation")
			_cfg_int(c, keys, "AutoHold", "auto_hold")
			_cfg_bool(c, keys, "DisallowTheft", "disallow_theft")
			_cfg_bool(c, keys, "allowManipulationWhenEquipped", "allow_manipulation_when_equipped")
			_cfg_float(c, keys, "ThrowVelocityBoostMinSpeed", "throw_boost_min_speed")
			_cfg_float(c, keys, "ThrowVelocityBoostScale", "throw_boost_scale")
			_cfg_ref(c, keys, "ExactGrip", "exact_grip", obj, node)
			_cfg_ref(c, keys, "ExactGun", "exact_gun", obj, node)
		"VRCStation":
			_cfg_int(c, keys, "PlayerMobility", "player_mobility")
			_cfg_bool(c, keys, "seated", "seated")
			_cfg_bool(c, keys, "disableStationExit", "disable_station_exit")
			_cfg_bool(c, keys, "canUseStationFromStation", "can_use_station_from_station")
			_cfg_ref(c, keys, "stationEnterPlayerLocation", "enter_location", obj, node)
			_cfg_ref(c, keys, "stationExitPlayerLocation", "exit_location", obj, node)
		"VRCObjectSync":
			_cfg_bool(c, keys, "AllowCollisionOwnershipTransfer", "allow_collision_ownership_transfer")
			_cfg_bool(c, keys, "SynchronizePhysics", "synchronize_physics")
		"VRCObjectPool":
			if keys.has("Pool") and keys["Pool"] is Array:
				var paths: Array = []
				for r in keys["Pool"]:
					var np: NodePath = _nodepath_for_ref(r, obj, node)
					if np != NodePath():
						paths.append(np)
				c["pool"] = paths
		"VRC_MirrorReflection":
			_cfg_int(c, keys, "m_ReflectLayers", "reflect_layers")
		"VRC_SceneDescriptor":
			_cfg_float(c, keys, "RespawnHeightY", "respawn_height")
			_cfg_int(c, keys, "spawnOrder", "spawn_order")
			_cfg_int(c, keys, "spawnOrientation", "spawn_orientation")
			if keys.has("spawns") and keys["spawns"] is Array:
				var sp: Array = []
				for r in keys["spawns"]:
					var np: NodePath = _nodepath_for_ref(r, obj, node)
					if np != NodePath():
						sp.append(np)
				c["spawns"] = sp
			_cfg_ref(c, keys, "ReferenceCamera", "reference_camera", obj, node)
		"VRC_AvatarPedestal":
			_cfg_str(c, keys, "blueprintId", "blueprint_id")
		"VRC_PortalMarker":
			_cfg_str(c, keys, "roomId", "room_id")
			_cfg_str(c, keys, "roomName", "room_name")
		"VRCVideoPlayer":
			_cfg_bool(c, keys, "autoPlay", "auto_play")
			_cfg_bool(c, keys, "loop", "loop")
			if keys.has("videoURL") and keys["videoURL"] is Dictionary:
				c["url"] = str(keys["videoURL"].get("url", ""))
	return c


func _cfg_bool(c: Dictionary, keys: Dictionary, k: String, out: String) -> void:
	if keys.has(k):
		c[out] = _to_int(keys[k]) != 0

func _cfg_int(c: Dictionary, keys: Dictionary, k: String, out: String) -> void:
	if keys.has(k):
		var v = keys[k]
		c[out] = _to_int(v.get("m_Bits", 0)) if v is Dictionary else _to_int(v)

func _cfg_float(c: Dictionary, keys: Dictionary, k: String, out: String) -> void:
	if keys.has(k):
		c[out] = _to_float(keys[k])

func _cfg_str(c: Dictionary, keys: Dictionary, k: String, out: String) -> void:
	if keys.has(k):
		c[out] = str(keys[k]) if keys[k] != null else ""

func _cfg_ref(c: Dictionary, keys: Dictionary, k: String, out: String, obj: RefCounted, node: Node) -> void:
	if keys.has(k):
		var np: NodePath = _nodepath_for_ref(keys[k], obj, node, _component_meta_key(_kind_of_cfg), out)
		if np != NodePath():
			c[out] = np

var _kind_of_cfg: String = ""



## NodePath (relative to `node`) of a same-file reference; empty when it cannot be resolved yet.
## Component settings are stored in metadata, so unlike script fields they are resolved eagerly;
## unidot assigns node paths in creation order, so forward references fall back to a deferred fix.
func _nodepath_for_ref(ref, obj: RefCounted, node: Node, meta_key: String = "", cfg_key: String = "") -> NodePath:
	if typeof(ref) != TYPE_ARRAY or ref.size() < 4 or ref[1] == 0:
		return NodePath()
	var meta: Resource = obj.meta
	var np: NodePath = meta.fileid_to_nodepath.get(ref[1], meta.prefab_fileid_to_nodepath.get(ref[1], NodePath()))
	if np == NodePath():
		if meta_key != "":
			_pending_refs.append({"owner": _owner_of(node), "node": node, "prop": "@meta", "index": -1, "ref": ref, "ty": {"kind": "component"}, "what": "component setting " + cfg_key, "meta": meta, "meta_key": meta_key, "cfg_key": cfg_key})
		return NodePath()
	var root: Node = _owner_of(node)
	if root == null:
		return NodePath()
	var target: Node = root.get_node_or_null(np)
	if target == null:
		# the path is known but the node is not built yet (a child of this object, e.g. a station's
		# exit location): resolve once the scene is complete, like unknown fileIDs
		if meta_key != "":
			_pending_refs.append({"owner": root, "node": node, "prop": "@meta", "index": -1, "ref": ref, "ty": {"kind": "component"}, "what": "component setting " + cfg_key, "meta": meta, "meta_key": meta_key, "cfg_key": cfg_key})
		return NodePath()
	return node.get_path_to(target)


func _owner_of(node: Node) -> Node:
	var n: Node = node
	while n != null and n.owner != null:
		n = n.owner
	return n


func _note_unknown(guid: String, obj: RefCounted, node: Node) -> void:
	if guid == "" or _unknown_seen.has(guid):
		if guid != "":
			_report["unknown_scripts"][guid]["count"] += 1
		return
	_unknown_seen[guid] = true
	var fields: Array = []
	for k in obj.keys:
		var ks: String = str(k)
		if not ks.begins_with("m_") and ks != "serializedVersion":
			fields.append(ks)
	var m = obj.meta.lookup_meta(obj.monoscript)
	_report["unknown_scripts"][guid] = {"count": 1, "script_path": str(m.path) if m != null else "", "fields": fields.slice(0, 20), "example_node": str(node.name)}


# ---------------------------------------------------------------------------------------------
# Unity UI → Control nodes
# ---------------------------------------------------------------------------------------------

## GameObjects with a RectTransform become Controls; the class follows the main UI component.
func create_gameobject_node(go: RefCounted, state: RefCounted, new_parent: Node) -> Node:
	var transform = go.transform
	if transform == null or transform.type != "RectTransform":
		return null
	if go.GetComponent("Canvas") != null and not _inside_canvas(new_parent):
		return null  # a top-level Canvas GameObject stays a Node3D; see children_parent()
	var primary: String = ""
	var kinds: Array = []
	for component_ref in go.components:
		var component = go.meta.lookup(component_ref.values()[0])
		if component == null or component.type != "MonoBehaviour":
			continue
		var g: String = str(component.monoscript[2]) if component.monoscript[2] != null else ""
		var kind: String = _identify_component(g, component.keys)
		if kind != "":
			kinds.append(kind)
	for k in UI_PRIMARY_ORDER:
		if kinds.has(k):
			primary = k
			break
	var node: Control
	match primary:
		"Button":
			node = Button.new()
			node.flat = true
		"Toggle":
			node = Button.new()
			node.toggle_mode = true
			node.flat = true
		"Slider", "Scrollbar":
			node = HSlider.new()
		"InputField", "TMP_InputField", "VRCUrlInputField":
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
	node.name = go.name
	node.mouse_filter = Control.MOUSE_FILTER_PASS if primary == "" or primary in ["Text", "TextMeshProUGUI", "Image", "RawImage"] else Control.MOUSE_FILTER_STOP
	if primary in ["Text", "TextMeshProUGUI", "Image", "RawImage"]:
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	state.add_child(node, new_parent, transform)
	_configure_rect(node, transform.keys, go)
	node.visible = go.enabled if "enabled" in go else true
	_report["ui_nodes"] += 1
	return node


## Children of a Canvas GameObject are built inside its SubViewport (world space) or CanvasLayer.
## Is `n` inside a converted canvas (its viewport or layer)?
func _inside_canvas(n: Node) -> bool:
	var cur: Node = n
	while cur != null:
		if cur.has_meta("udon_canvas"):
			return true
		cur = cur.get_parent()
	return false


func children_parent(go: RefCounted, state: RefCounted, node: Node) -> Node:
	var canvas = go.GetComponent("Canvas")
	if canvas == null or node == null or node is Control:
		return null  # nested canvases are ordinary containers inside their parent's viewport
	var keys: Dictionary = canvas.keys
	var rt = go.transform
	var size: Vector2 = Vector2(100, 100)
	if rt != null and rt.keys.has("m_SizeDelta"):
		var sd = rt.keys["m_SizeDelta"]
		if sd is Vector2:
			size = sd
	var render_mode: int = _to_int(keys.get("m_RenderMode", 0))
	var scaler = go.GetComponent("MonoBehaviour")
	if render_mode == 2:
		return _apply_canvas_group(node, _world_canvas(node, size, rt, state))
	# screen space: a CanvasLayer with a root control sized to the reference resolution
	var ref_size: Vector2 = Vector2(1920, 1080)
	for component_ref in go.components:
		var component = go.meta.lookup(component_ref.values()[0])
		if component != null and component.type == "MonoBehaviour" and component.keys.has("m_ReferenceResolution"):
			var rr = component.keys["m_ReferenceResolution"]
			if rr is Vector2:
				ref_size = rr
	var layer := CanvasLayer.new()
	layer.name = "CanvasLayer"
	node.add_child(layer, true)
	layer.owner = state.owner
	var root := Control.new()
	root.name = "Canvas"
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	# an invisible full-window container: it must not swallow the clicks meant for the 3D world
	# (world canvases, pickups) behind it; its controls still receive theirs
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root, true)
	root.owner = state.owner
	node.set_meta("udon_canvas", {"mode": "overlay", "root": node.get_path_to(root), "size": ref_size})
	return _apply_canvas_group(node, root)


## A CanvasGroup on a canvas GameObject is converted before the canvas root Control exists
## (unidot's UnidotCanvasGroup leaves its settings on the container); apply them to the root.
func _apply_canvas_group(container: Node, root: Node) -> Node:
	if container != null and root is Control and container.has_meta("udon_canvas_group"):
		var cfg: Dictionary = container.get_meta("udon_canvas_group")
		root.modulate.a = clampf(float(cfg.get("alpha", 1.0)), 0.0, 1.0)
		root.mouse_filter = Control.MOUSE_FILTER_STOP if bool(cfg.get("interactable", true)) and bool(cfg.get("blocksRaycasts", true)) else Control.MOUSE_FILTER_IGNORE
		root.set_meta("udon_canvas_group", cfg)
		container.remove_meta("udon_canvas_group")
	return root


func _world_canvas(node: Node, size: Vector2, rt, state: RefCounted) -> Node:
	# Canvas units are metres at scale 1 (the RectTransform scale converts pixel-style layouts);
	# the viewport renders at `udon/canvas_pixels_per_metre` (default 1024) times the canvas scale.
	var ppm: float = float(ProjectSettings.get_setting("udon/canvas_pixels_per_metre", 1024.0))
	var gscale: Vector3 = node.global_transform.basis.get_scale() if node.is_inside_tree() else node.scale
	var k: float = maxf(ppm * maxf(gscale.x, 1e-6), 0.01)
	var units: Vector2 = Vector2(maxf(size.x, 1e-4), maxf(size.y, 1e-4))
	var w: int = clampi(int(ceil(units.x * k)), 1, 8192)
	var h: int = clampi(int(ceil(units.y * k)), 1, 8192)
	var vp := SubViewport.new()
	vp.name = "Viewport"
	vp.size = Vector2i(w, h)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.gui_embed_subwindows = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	node.add_child(vp, true)
	vp.owner = state.owner
	var root := Control.new()
	root.name = "Canvas"
	root.size = units
	root.scale = Vector2(k, k)
	vp.add_child(root, true)
	root.owner = state.owner
	# Unity draws the canvas in the local XY plane, readable from its -Z side; the quad faces
	# -Z (half-turn about Y) which also puts texture U along -X, matching the mirrored X axis.
	var pivot: Vector2 = Vector2(0.5, 0.5)
	if rt != null and rt.keys.get("m_Pivot") is Vector2:
		pivot = rt.keys["m_Pivot"]
	var plane := MeshInstance3D.new()
	plane.name = "CanvasPlane"
	var quad := QuadMesh.new()
	quad.size = units
	plane.mesh = quad
	var center := Vector3(-(0.5 - pivot.x) * units.x, (0.5 - pivot.y) * units.y, 0.0)
	plane.transform = Transform3D(Basis.from_euler(Vector3(0.0, PI, 0.0)), center)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	plane.material_override = mat
	node.add_child(plane, true)
	plane.owner = state.owner
	# udon_runtime's canvas plane script binds the viewport texture, refits the viewport to the
	# UI's real bounds and handles canvases nested inside other canvases at runtime.
	if ResourceLoader.exists("res://addons/udon_runtime/udon_canvas_plane.gd"):
		plane.set_script(load("res://addons/udon_runtime/udon_canvas_plane.gd"))
		plane.set("viewport_path", plane.get_path_to(vp))
	else:
		var vt := ViewportTexture.new()
		vt.viewport_path = state.owner.get_path_to(vp)
		mat.albedo_texture = vt
	var area := Area3D.new()
	area.name = "UiShape"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(units.x, units.y, 0.01)
	shape.shape = box
	area.add_child(shape, true)
	area.transform = plane.transform
	node.add_child(area, true)
	area.owner = state.owner
	shape.owner = state.owner
	area.add_to_group("udon_ui_shape", true)
	if rt != null:
		_store_rect_meta(node, rt.keys)
	node.set_meta("udon_canvas", {"mode": "world", "viewport": node.get_path_to(vp), "root": node.get_path_to(root), "plane": node.get_path_to(plane), "size": units, "k": k, "pivot": pivot, "offset": Vector2.ZERO, "plane_center": center})
	return root


func _store_rect_meta(node: Node, keys: Dictionary) -> void:
	var amin: Vector2 = keys.get("m_AnchorMin") if keys.get("m_AnchorMin") is Vector2 else Vector2(0.5, 0.5)
	var amax: Vector2 = keys.get("m_AnchorMax") if keys.get("m_AnchorMax") is Vector2 else Vector2(0.5, 0.5)
	var ap: Vector2 = keys.get("m_AnchoredPosition") if keys.get("m_AnchoredPosition") is Vector2 else Vector2.ZERO
	var sd: Vector2 = keys.get("m_SizeDelta") if keys.get("m_SizeDelta") is Vector2 else Vector2.ZERO
	var pv: Vector2 = keys.get("m_Pivot") if keys.get("m_Pivot") is Vector2 else Vector2(0.5, 0.5)
	var sc: Vector2 = Vector2.ONE
	if keys.get("m_LocalScale") is Vector3:
		sc = Vector2(keys["m_LocalScale"].x, keys["m_LocalScale"].y)
	node.set_meta("udon_rect", {"anchor_min": amin, "anchor_max": amax, "anchored_position": ap, "size_delta": sd, "pivot": pv, "scale": sc})


## Unity world canvases do not clip: children may extend far beyond the canvas rect (a 1×1 root
## with 300×100 menus is common). Once the UI tree exists, size the viewport to the union of the
## drawing controls and move the plane so the canvas keeps its world placement. Plain Controls
## (RectTransforms without a Graphic: menus, anchors, layout groups) are layout helpers whose rects
## can be far larger than their content (a 100×100 container scaled 200×) and do not count; their
## scale still applies to what they contain. Same rules as udon_canvas_plane.gd at runtime.
const MAX_VIEWPORT_PX := 8192.0

func _finalize_world_canvas(node: Node) -> void:
	var cfg: Dictionary = node.get_meta("udon_canvas")
	var vp: SubViewport = node.get_node_or_null(cfg.get("viewport", NodePath()))
	var root: Control = node.get_node_or_null(cfg.get("root", NodePath()))
	var plane: MeshInstance3D = node.get_node_or_null(cfg.get("plane", NodePath()))
	var area: Area3D = node.get_node_or_null(NodePath("UiShape"))
	if vp == null or root == null or plane == null:
		return
	var k: float = float(cfg.get("k", 1.0))
	var rsize: Vector2 = cfg.get("size", root.size)
	var union: Rect2 = Rect2(Vector2.ZERO, rsize)
	var rects: Array = []
	for c in root.get_children():
		_content_bounds(c, rsize, Transform2D.IDENTITY, rects)
	for r in rects:
		union = union.merge(r)
	# beyond the viewport limit the pixel density drops instead of stretching the texture
	if union.size.x * k > MAX_VIEWPORT_PX:
		k = MAX_VIEWPORT_PX / union.size.x
	if union.size.y * k > MAX_VIEWPORT_PX:
		k = MAX_VIEWPORT_PX / union.size.y
	k = maxf(k, 1e-4)
	root.scale = Vector2(k, k)
	cfg["k"] = k
	var w: int = clampi(int(ceil(union.size.x * k)), 1, int(MAX_VIEWPORT_PX))
	var h: int = clampi(int(ceil(union.size.y * k)), 1, int(MAX_VIEWPORT_PX))
	vp.size = Vector2i(w, h)
	root.position = -union.position * k
	var pv: Vector2 = cfg.get("pivot", Vector2(0.5, 0.5))
	var center: Vector3 = Vector3(pv.x * rsize.x - union.position.x - union.size.x * 0.5, (1.0 - pv.y) * rsize.y - union.position.y - union.size.y * 0.5, 0.0)
	var quad: QuadMesh = plane.mesh as QuadMesh
	if quad != null:
		quad.size = union.size
	plane.transform = Transform3D(Basis.from_euler(Vector3(0.0, PI, 0.0)), center)
	if area != null:
		area.transform = plane.transform
		var shape: CollisionShape3D = area.get_node_or_null("CollisionShape3D")
		if shape != null and shape.shape is BoxShape3D:
			shape.shape.size = Vector3(union.size.x, union.size.y, 0.01)
	cfg["plane_size"] = union.size
	cfg["offset"] = union.position
	cfg["plane_center"] = center
	node.set_meta("udon_canvas", cfg)


## Append the rect, in root units, of every drawing control at or below `c` (hidden ones included:
## menus toggled at runtime must fit the plane). Rects come from the anchor/offset values stored at
## import (the controls are not laid out yet); `to_root` maps c's parent space to root space and
## carries the ancestors' scale and rotation around their pivots, as Control.get_transform() does.
func _content_bounds(c: Node, parent_size: Vector2, to_root: Transform2D, out: Array) -> void:
	if not (c is Control):
		return
	var ctl: Control = c
	var left: float = ctl.anchor_left * parent_size.x + ctl.offset_left
	var right: float = ctl.anchor_right * parent_size.x + ctl.offset_right
	var top: float = ctl.anchor_top * parent_size.y + ctl.offset_top
	var bottom: float = ctl.anchor_bottom * parent_size.y + ctl.offset_bottom
	var size: Vector2 = Vector2(maxf(right - left, 0.0), maxf(bottom - top, 0.0))
	var pv: Vector2 = ctl.pivot_offset
	var local: Transform2D = Transform2D(0.0, Vector2(left, top) + pv) * Transform2D(ctl.rotation, ctl.scale, 0.0, Vector2.ZERO) * Transform2D(0.0, -pv)
	var xf: Transform2D = to_root * local
	if ctl.get_class() != "Control":
		out.append(xf * Rect2(Vector2.ZERO, size))
	for ch in ctl.get_children():
		_content_bounds(ch, size, xf, out)


## RectTransform → Control anchors/offsets (Unity Y-up, Godot Y-down).
func _configure_rect(node: Control, keys: Dictionary, go: RefCounted) -> void:
	var amin: Vector2 = keys.get("m_AnchorMin", Vector2(0.5, 0.5)) if keys.get("m_AnchorMin") is Vector2 else Vector2(0.5, 0.5)
	var amax: Vector2 = keys.get("m_AnchorMax", Vector2(0.5, 0.5)) if keys.get("m_AnchorMax") is Vector2 else Vector2(0.5, 0.5)
	var ap: Vector2 = keys.get("m_AnchoredPosition", Vector2.ZERO) if keys.get("m_AnchoredPosition") is Vector2 else Vector2.ZERO
	var sd: Vector2 = keys.get("m_SizeDelta", Vector2.ZERO) if keys.get("m_SizeDelta") is Vector2 else Vector2.ZERO
	var pv: Vector2 = keys.get("m_Pivot", Vector2(0.5, 0.5)) if keys.get("m_Pivot") is Vector2 else Vector2(0.5, 0.5)
	node.anchor_left = amin.x
	node.anchor_right = amax.x
	node.anchor_top = 1.0 - amax.y
	node.anchor_bottom = 1.0 - amin.y
	node.offset_left = ap.x - pv.x * sd.x
	node.offset_right = ap.x + (1.0 - pv.x) * sd.x
	node.offset_top = -ap.y - (1.0 - pv.y) * sd.y
	node.offset_bottom = -ap.y + pv.y * sd.y
	var rot = keys.get("m_LocalRotation")
	if rot is Quaternion:
		var e: Vector3 = Basis(rot.normalized()).get_euler(EULER_ORDER_YXZ)
		node.rotation = -e.z
	var sc = keys.get("m_LocalScale")
	if sc is Vector3:
		node.scale = Vector2(sc.x, sc.y)
	node.pivot_offset = Vector2(pv.x * sd.x, (1.0 - pv.y) * sd.y)
	node.set_meta("udon_rect", {"pivot": pv, "anchored_position": ap, "size_delta": sd})
	node.set_meta("udon_pivot", pv)


func _configure_ui_component(kind: String, obj: RefCounted, state: RefCounted, node: Node) -> void:
	state.add_fileID(node, obj)
	var keys: Dictionary = obj.keys
	var ctl: Control = node as Control
	if ctl == null:
		return
	match kind:
		"Image":
			var tex: Texture2D = _sprite_texture(obj.get_ref(keys, "m_Sprite"), obj)
			var col: Color = keys.get("m_Color", Color.WHITE) if keys.get("m_Color") is Color else Color.WHITE
			if ctl is TextureRect:
				ctl.texture = tex
				ctl.modulate = col
				if _to_int(keys.get("m_PreserveAspect", 0)) != 0:
					ctl.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			else:
				_apply_background(ctl, tex, col, keys)
		"RawImage":
			var tex2: Texture2D = _sprite_texture(obj.get_ref(keys, "m_Texture"), obj)
			var col2: Color = keys.get("m_Color", Color.WHITE) if keys.get("m_Color") is Color else Color.WHITE
			if ctl is TextureRect:
				ctl.texture = tex2
				ctl.modulate = col2
			else:
				_apply_background(ctl, tex2, col2, keys)
		"Text":
			_configure_text(ctl, keys, obj)
		"TextMeshProUGUI":
			_configure_tmp(ctl, keys, obj)
		"Button":
			if ctl is BaseButton:
				ctl.disabled = _to_int(keys.get("m_Interactable", 1)) == 0
			_queue_events(keys.get("m_OnClick"), ctl, "pressed", 0, state, obj)
		"Toggle":
			if ctl is BaseButton:
				ctl.button_pressed = _to_int(keys.get("m_IsOn", 0)) != 0
				ctl.disabled = _to_int(keys.get("m_Interactable", 1)) == 0
			_queue_events(keys.get("onValueChanged"), ctl, "toggled", 1, state, obj)
		"Slider", "Scrollbar":
			if ctl is Range:
				ctl.min_value = _to_float(keys.get("m_MinValue", 0.0))
				ctl.max_value = _to_float(keys.get("m_MaxValue", 1.0))
				ctl.rounded = _to_int(keys.get("m_WholeNumbers", 0)) != 0
				ctl.step = 1.0 if ctl.rounded else 0.0
				ctl.value = _to_float(keys.get("m_Value", 0.0))
			_queue_events(keys.get("m_OnValueChanged"), ctl, "value_changed", 1, state, obj)
		"InputField", "TMP_InputField", "VRCUrlInputField":
			if ctl is LineEdit:
				ctl.text = str(keys.get("m_Text", "")) if keys.get("m_Text") != null else ""
				ctl.max_length = _to_int(keys.get("m_CharacterLimit", 0))
				ctl.editable = _to_int(keys.get("m_Interactable", 1)) != 0
			_queue_events(keys.get("m_OnEndEdit"), ctl, "text_submitted", 1, state, obj)
			_queue_events(keys.get("m_OnValueChanged"), ctl, "text_changed", 1, state, obj)
			_queue_events(keys.get("m_OnSubmit"), ctl, "text_submitted", 1, state, obj)
		"Dropdown", "TMP_Dropdown":
			if ctl is OptionButton:
				var opts = keys.get("m_Options", {})
				if opts is Dictionary:
					for o in opts.get("m_Options", []):
						ctl.add_item(str(o.get("m_Text", "")) if o is Dictionary else str(o))
				ctl.selected = _to_int(keys.get("m_Value", 0))
			_queue_events(keys.get("m_OnValueChanged"), ctl, "item_selected", 1, state, obj)
		"ScrollRect":
			pass
		"Mask", "RectMask2D":
			ctl.clip_contents = true
			if kind == "Mask" and _to_int(keys.get("m_ShowMaskGraphic", 1)) == 0 and ctl is TextureRect:
				ctl.self_modulate.a = 0.0
		"LayoutElement":
			if _to_int(keys.get("m_IgnoreLayout", 0)) == 0:
				var mn := Vector2(maxf(float(keys.get("m_MinWidth", -1.0)), float(keys.get("m_PreferredWidth", -1.0))), maxf(float(keys.get("m_MinHeight", -1.0)), float(keys.get("m_PreferredHeight", -1.0))))
				ctl.custom_minimum_size = Vector2(maxf(mn.x, 0.0), maxf(mn.y, 0.0))
				if float(keys.get("m_FlexibleWidth", -1.0)) > 0.0:
					ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				if float(keys.get("m_FlexibleHeight", -1.0)) > 0.0:
					ctl.size_flags_vertical = Control.SIZE_EXPAND_FILL
		"Outline", "Shadow":
			# Unity text effects → theme overrides on the text control (also read by U.ui_effect_*)
			var ecol: Color = keys.get("m_EffectColor", Color(0, 0, 0, 0.5)) if keys.get("m_EffectColor") is Color else Color(0, 0, 0, 0.5)
			var edist: Vector2 = keys.get("m_EffectDistance", Vector2(1, -1)) if keys.get("m_EffectDistance") is Vector2 else Vector2(1, -1)
			var effect: String = "outline" if kind == "Outline" else "shadow"
			ctl.set_meta("udon_effect_" + effect, {"effectColor": ecol, "effectDistance": edist, "useGraphicAlpha": _to_int(keys.get("m_UseGraphicAlpha", 1)) != 0, "enabled": _to_int(keys.get("m_Enabled", 1)) != 0})
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
			var ratio: float = maxf(float(keys.get("m_AspectRatio", 1.0)), 0.001)
			var props: Dictionary = ctl.get_meta("udon_props") if ctl.has_meta("udon_props") else {}
			props["aspectMode"] = mode
			props["aspectRatio"] = ratio
			ctl.set_meta("udon_props", props)
			if mode == 1:
				ctl.size = Vector2(ctl.size.x, ctl.size.x / ratio)
			elif mode == 2:
				ctl.size = Vector2(ctl.size.y * ratio, ctl.size.y)
		"CanvasScaler", "GraphicRaycaster", "HorizontalLayoutGroup", "VerticalLayoutGroup", "GridLayoutGroup", "ContentSizeFitter", "EventSystem", "StandaloneInputModule", "VRC_UiShape":
			pass
		_:
			pass


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
		ctl.set_meta("udon_tmp", true)
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


## UnityEvent persistent calls: `SendCustomEvent("Name")` on an UdonBehaviour becomes a signal
## connection to the behaviour's node once the scene is complete.
func _queue_events(evt, source: Control, signal_name: String, unbinds: int, state: RefCounted, obj: RefCounted) -> void:
	if not (evt is Dictionary):
		return
	var calls = evt.get("m_PersistentCalls", {}).get("m_Calls", []) if evt.get("m_PersistentCalls") is Dictionary else []
	for call in calls:
		if not (call is Dictionary):
			continue
		if _to_int(call.get("m_CallState", 2)) == 0:
			continue
		var method: String = str(call.get("m_MethodName", ""))
		var target: Array = obj.get_ref(call, "m_Target")
		if target.size() < 4 or target[1] == 0:
			continue
		var args = call.get("m_Arguments", {})
		var event_name: String = ""
		if method == "SendCustomEvent" and args is Dictionary:
			event_name = str(args.get("m_StringArgument", ""))
		_pending_events.append({"owner": state.owner, "source": source, "signal": signal_name, "ref": target, "event": event_name, "method": method, "unbinds": unbinds, "args": args, "meta": obj.meta})


func _resolve_pending_event(e: Dictionary, meta: Resource, _state: RefCounted, scene_contents: Node) -> void:
	var source: Node = e["source"]
	if not is_instance_valid(source):
		return
	var ref: Array = e["ref"]
	var np: NodePath = meta.fileid_to_nodepath.get(ref[1], meta.prefab_fileid_to_nodepath.get(ref[1], NodePath()))
	var target: Node = scene_contents.get_node_or_null(np) if np != NodePath() else null
	if target == null:
		_report["unresolved_references"].append({"field": "UnityEvent " + str(e["signal"]) + " on " + str(source.name), "fileID": ref[1]})
		return
	var callable: Callable
	if e["method"] == "SendCustomEvent" and e["event"] != "":
		callable = Callable(target, "SendCustomEvent").bind(e["event"])
	elif e["method"] == "SetActive" or e["method"] == "set_enabled":
		var on: bool = _to_int(e["args"].get("m_BoolArgument", 0)) != 0 if e["args"] is Dictionary else true
		callable = Callable(target, "set_visible").bind(on)
	else:
		# other UnityEvent targets (Animator.SetTrigger, GameObject.SetActive with args, ...) are
		# reported so the world author can wire them by hand
		_report["unresolved_references"].append({"field": "UnityEvent " + str(e["signal"]) + " on " + str(source.name), "reason": "unsupported persistent call " + str(e["method"])})
		return
	if int(e["unbinds"]) > 0:
		callable = callable.unbind(int(e["unbinds"]))
	source.connect(e["signal"], callable, CONNECT_PERSIST)
	_report["events_wired"] += 1


# ---------------------------------------------------------------------------------------------
# prefab-instance overrides of script fields
# ---------------------------------------------------------------------------------------------

func _apply_override(host: Node, entry: Dictionary, path: String, value, obj: RefCounted, node: Node) -> void:
	# propertyPath: field | field.Array.size | field.Array.data[i] | field.x | field.r | field.m_Bits
	var parts: PackedStringArray = path.split(".")
	var fname: String = parts[0]
	var fields: Dictionary = entry.get("fields", {})
	if not fields.has(fname):
		return
	var f: Dictionary = fields[fname]
	var ty: Dictionary = f["ty"]
	var prop: String = str(f["gd"])
	if parts.size() == 1:
		if typeof(value) == TYPE_ARRAY:
			# object reference
			if _is_reference_kind(str(ty.get("kind", ""))):
				_pending_refs.append({"owner": _owner_of(node), "node": host, "prop": prop, "index": -1, "ref": value, "ty": ty, "what": str(entry["name"]) + "." + fname, "meta": obj.meta})
			elif str(ty.get("kind", "")) == "resource":
				host.set(prop, _resource_for(value, obj, fname))
		else:
			host.set(prop, _convert_value(value, ty, fname))
		return
	if parts.size() >= 3 and parts[1] == "Array":
		var arr = host.get(prop)
		if not (arr is Array):
			arr = []
		if parts[2] == "size":
			arr.resize(_to_int(value))
			host.set(prop, arr)
			return
		if parts[2].begins_with("data["):
			var idx: int = parts[2].substr(5, parts[2].length() - 6).to_int()
			if idx >= arr.size():
				arr.resize(idx + 1)
			var elem: Dictionary = ty.get("elem", {})
			if typeof(value) == TYPE_ARRAY:
				if _is_reference_kind(str(elem.get("kind", ""))):
					_pending_refs.append({"owner": _owner_of(node), "node": host, "prop": prop, "index": idx, "ref": value, "ty": elem, "what": str(entry["name"]) + "." + fname, "meta": obj.meta})
				elif str(elem.get("kind", "")) == "resource":
					arr[idx] = _resource_for(value, obj, fname)
			else:
				arr[idx] = _convert_value(value, elem, fname)
			host.set(prop, arr)
		return
	# sub-field of a struct (x/y/z/w/r/g/b/a/m_Bits)
	var cur = host.get(prop)
	var sub: String = parts[1]
	var fv: float = _to_float(value)
	match sub:
		"x", "y", "z", "w", "r", "g", "b", "a":
			if cur is Vector2 or cur is Vector3 or cur is Vector4 or cur is Quaternion or cur is Color:
				cur[sub] = fv
				host.set(prop, cur)
		"m_Bits":
			host.set(prop, _to_int(value))
		_:
			pass


# ---------------------------------------------------------------------------------------------
# diagnostics
# ---------------------------------------------------------------------------------------------

func _save_report() -> void:
	var path: String = str(ProjectSettings.get_setting("udon/import_report", "res://udon_import_report.json"))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_report, "  "))
	f.close()
