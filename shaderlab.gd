@tool
extends RefCounted
# Unity shader knowledge for material conversion.
#
# Unity materials reference either a built-in shader (guid 0000000000000000f000000000000000 +
# fileID) or a .shader asset written in ShaderLab. Godot cannot run either, so a material is
# converted by one of three strategies, in this order:
#   1. a hand-written Godot port: `<name>.gdshader` (see `port_file_name`) in one of the
#      directories listed in the project setting `unidot/shader_ports`; uniforms named like the
#      Unity properties (`_MainTex`, `_Color`, ...) receive the material's values;
#   2. a sky material for skybox shaders (procedural, panoramic, 6-sided, cubemap);
#   3. a StandardMaterial3D built from the Unity properties (as before), plus the render state
#      parsed from the ShaderLab source: blend mode, ZWrite, Cull, ZTest, render queue and whether
#      the shader is lit at all.
# `parse` summarises a .shader file; the summary is stored on the shader's asset meta
# (`shader_info`) during preprocessing so materials can read it regardless of import order.

const BUILTIN_GUID := "0000000000000000f000000000000000"

# fileIDs of the built-in shaders that matter for conversion (unity_builtin_extra).
const BUILTIN := {
	7: "Legacy Shaders/Diffuse",
	45: "Standard (Specular setup)",
	46: "Standard",
	47: "Autodesk Interactive",
	103: "Skybox/Cubemap",
	104: "Skybox/6 Sided",
	106: "Skybox/Procedural",
	108: "Skybox/Panoramic",
	210: "Particles/Standard Surface",
	211: "Particles/Standard Unlit",
	10750: "Unlit/Transparent",
	10751: "Unlit/Transparent Cutout",
	10752: "Unlit/Texture",
	10753: "Sprites/Default",
	10755: "Unlit/Color",
	10770: "UI/Default",
}

# UnityEngine.Rendering.BlendMode
const BLEND_MODE := {
	0: "Zero", 1: "One", 2: "DstColor", 3: "SrcColor", 4: "OneMinusDstColor", 5: "SrcAlpha",
	6: "OneMinusSrcColor", 7: "DstAlpha", 8: "OneMinusDstAlpha", 9: "SrcAlphaSaturate", 10: "OneMinusSrcAlpha",
}


static func builtin_info(fileid: int) -> Dictionary:
	var name: String = BUILTIN.get(fileid, "")
	var info: Dictionary = {"name": name, "builtin": true, "fileid": fileid, "tags": {}, "blend": [], "zwrite": "", "cull": "", "ztest": "", "lit": true, "properties": {}}
	if name.begins_with("Unlit/") or name == "Sprites/Default" or name == "UI/Default" or name == "Particles/Standard Unlit":
		info["lit"] = false
	if name == "Unlit/Transparent" or name == "Sprites/Default" or name == "UI/Default":
		info["blend"] = ["SrcAlpha", "OneMinusSrcAlpha"]
		info["zwrite"] = "Off"
		info["tags"] = {"Queue": "Transparent"}
	if name == "Sprites/Default" or name == "UI/Default":
		info["cull"] = "Off"
	if name == "Unlit/Transparent Cutout":
		info["tags"] = {"Queue": "AlphaTest"}
	if name.begins_with("Particles/Standard"):
		# blend state lives in the material's _SrcBlend/_DstBlend/_ZWrite/_Mode floats
		info["blend"] = ["[_SrcBlend]", "[_DstBlend]"]
		info["zwrite"] = "[_ZWrite]"
		info["particles"] = true
	if name.begins_with("Skybox/"):
		info["sky"] = name.trim_prefix("Skybox/")
	return info


static func strip_comments(text: String) -> String:
	var re_block := RegEx.new()
	re_block.compile("/\\*[\\s\\S]*?\\*/")
	var re_line := RegEx.new()
	re_line.compile("//[^\\n]*")
	return re_line.sub(re_block.sub(text, "", true), "", true)


## Summarise a ShaderLab source. Only the first SubShader is considered.
static func parse(text: String) -> Dictionary:
	var t := strip_comments(text)
	var info: Dictionary = {"name": "", "builtin": false, "tags": {}, "blend": [], "zwrite": "", "cull": "", "ztest": "", "lit": true, "properties": {}, "grabpass": false}
	var re := RegEx.new()
	re.compile("Shader\\s*\"([^\"]*)\"")
	var m := re.search(t)
	if m != null:
		info["name"] = m.get_string(1)
	# Properties { ... }
	var props := _block(t, "Properties")
	if props != "":
		re.compile("(?:\\[[^\\]]*\\]\\s*)*([A-Za-z_][A-Za-z0-9_]*)\\s*\\(\\s*\"([^\"]*)\"\\s*,\\s*([^)]*)\\)\\s*=\\s*(\"[^\"]*\"\\s*\\{[^}]*\\}|\\([^)]*\\)|[-+0-9.eE]+|[A-Za-z_][A-Za-z0-9_]*)")
		for pm in re.search_all(props):
			var ptype: String = pm.get_string(3).strip_edges()
			info["properties"][pm.get_string(1)] = {"type": ptype, "default": pm.get_string(4).strip_edges()}
	var sub := _block(t, "SubShader")
	if sub == "":
		sub = t
	# render state is ShaderLab outside the CG/HLSL program blocks
	var re_prog := RegEx.new()
	re_prog.compile("(CGPROGRAM|HLSLPROGRAM|GLSLPROGRAM)[\\s\\S]*?(ENDCG|ENDHLSL|ENDGLSL)")
	var state := re_prog.sub(sub, " ", true)
	# Tags { "Queue" = "Transparent" ... } (SubShader-level first, then Pass-level; first wins)
	re.compile("Tags\\s*\\{([^}]*)\\}")
	var re_kv := RegEx.new()
	re_kv.compile("\"([^\"]*)\"\\s*=\\s*\"([^\"]*)\"")
	for tm in re.search_all(sub):
		for kv in re_kv.search_all(tm.get_string(1)):
			if not info["tags"].has(kv.get_string(1)):
				info["tags"][kv.get_string(1)] = kv.get_string(2)
	re.compile("\\bBlend\\s+(?:\\d+\\s+)?([A-Za-z\\[\\]_]+)\\s+([A-Za-z\\[\\]_]+)")
	m = re.search(state)
	if m != null and m.get_string(1) != "Off":
		info["blend"] = [m.get_string(1), m.get_string(2)]
	re.compile("\\bZWrite\\s+([A-Za-z\\[\\]_]+)")
	m = re.search(state)
	if m != null:
		info["zwrite"] = m.get_string(1)
	re.compile("\\bCull\\s+([A-Za-z\\[\\]_]+)")
	m = re.search(state)
	if m != null:
		info["cull"] = m.get_string(1)
	re.compile("\\bZTest\\s+([A-Za-z\\[\\]_]+)")
	m = re.search(state)
	if m != null:
		info["ztest"] = m.get_string(1)
	info["grabpass"] = state.find("GrabPass") != -1
	re.compile("\\bLighting\\s+Off\\b")
	var lighting_off: bool = re.search(state) != null
	var lightmode: String = str(info["tags"].get("LightMode", ""))
	var lit: bool = sub.find("#pragma surface") != -1 or lightmode.begins_with("Forward") or lightmode == "UniversalForward" \
		or sub.find("multi_compile_fwdbase") != -1 or sub.find("_LightColor0") != -1 or sub.find("AutoLight.cginc") != -1 \
		or sub.find("Lighting.cginc") != -1 or sub.find("UnityPBSLighting") != -1
	info["lit"] = lit and not lighting_off
	if str(info["tags"].get("PreviewType", "")) == "Skybox" or str(info["tags"].get("Queue", "")).begins_with("Background"):
		info["sky"] = sky_kind_from_properties(info["properties"])
	return info


## Text inside the braces that follow `keyword` (first occurrence), "" when absent.
static func _block(t: String, keyword: String) -> String:
	var re := RegEx.new()
	re.compile("\\b" + keyword + "\\b\\s*\\{")
	var m := re.search(t)
	if m == null:
		return ""
	var start: int = m.get_end()
	var depth: int = 1
	var i: int = start
	while i < t.length():
		var c := t[i]
		if c == "{":
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0:
				return t.substr(start, i - start)
		i += 1
	return t.substr(start)


static func sky_kind_from_properties(props: Dictionary) -> String:
	if props.has("_FrontTex") and props.has("_BackTex"):
		return "6 Sided"
	if props.has("_SkyTint") or props.has("_AtmosphereThickness"):
		return "Procedural"
	if props.has("_Tex") and str(props["_Tex"].get("type", "")).to_upper().begins_with("CUBE"):
		return "Cubemap"
	if props.has("_MainTex"):
		return "Panoramic"
	return "Cubemap" if props.has("_Tex") else "Panoramic"


## Sky kind of a material from its shader info and, for shaders whose source is not available,
## from the property names the material carries.
static func sky_kind(info: Dictionary, texs: Dictionary, floats: Dictionary, colors: Dictionary) -> String:
	if info.has("sky") and str(info["sky"]) != "":
		return str(info["sky"])
	if info.get("name", "") != "":
		return ""
	# unknown shader: property signature
	if texs.has("_FrontTex") and texs.has("_BackTex") and texs.has("_UpTex"):
		return "6 Sided"
	if floats.has("_AtmosphereThickness") and colors.has("_SkyTint") and floats.has("_SunSize"):
		return "Procedural"
	return ""


static func port_file_name(shader_name: String) -> String:
	var s := shader_name.strip_edges().replace("/", "__").replace(" ", "_")
	var re := RegEx.new()
	re.compile("[^A-Za-z0-9_.]")
	return re.sub(s, "_", true) + ".gdshader"


static func port_dirs() -> PackedStringArray:
	var v: Variant = ProjectSettings.get_setting("unidot/shader_ports", PackedStringArray())
	var out := PackedStringArray()
	if v is PackedStringArray:
		out = v
	elif v is Array:
		for x in v:
			out.append(str(x))
	elif v is String and str(v) != "":
		out.append(str(v))
	return out


## Path of a hand-written Godot shader for a Unity shader name, "" when none is installed.
static func find_port(shader_name: String) -> String:
	if shader_name == "":
		return ""
	var fname := port_file_name(shader_name)
	for d in port_dirs():
		var p: String = str(d).rstrip("/") + "/" + fname
		if FileAccess.file_exists(p):
			return p
	return ""


static func resolve_blend(blend: Array, floats: Dictionary) -> Array:
	if blend.size() != 2:
		return []
	var out: Array = []
	for b in blend:
		var s := str(b)
		if s.begins_with("[") and s.ends_with("]"):
			var key := s.substr(1, s.length() - 2)
			if not floats.has(key):
				return []
			s = str(BLEND_MODE.get(int(floats[key]), ""))
			if s == "":
				return []
		out.append(s)
	return out


static func resolve_toggle(value: String, floats: Dictionary) -> String:
	if value.begins_with("[") and value.ends_with("]"):
		var key := value.substr(1, value.length() - 2)
		if floats.has(key):
			return "On" if float(floats[key]) != 0.0 else "Off"
		return ""
	return value


## Apply the shader's render state to a converted StandardMaterial3D. Returns a short description
## of what was applied (for the import log).
static func apply_render_state(mat: BaseMaterial3D, info: Dictionary, floats: Dictionary, kws: Dictionary) -> String:
	var notes: PackedStringArray = []
	if not info.get("lit", true):
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		notes.append("unlit")
	var queue: String = str(info.get("tags", {}).get("Queue", ""))
	var qname := queue
	var qoffset := 0
	for sep in ["+", "-"]:
		var idx := queue.find(sep)
		if idx != -1:
			qname = queue.substr(0, idx)
			qoffset = int(queue.substr(idx))
			break
	var blend := resolve_blend(info.get("blend", []), floats)
	var mode: int = int(floats.get("_Mode", 0.0))
	if info.get("particles", false) and blend.is_empty():
		# Particles/Standard rendering modes: 0 opaque, 1 cutout, 2 fade, 3 transparent, 4 additive, 5 subtractive, 6 modulate
		blend = [[], [], ["SrcAlpha", "OneMinusSrcAlpha"], ["One", "OneMinusSrcAlpha"], ["SrcAlpha", "One"], ["Zero", "OneMinusSrcColor"], ["DstColor", "OneMinusSrcAlpha"]][clampi(mode, 0, 6)]
	var transparent := false
	if blend.size() == 2 and not (blend[0] == "One" and blend[1] == "Zero"):
		transparent = true
		var key: String = blend[0] + "," + blend[1]
		match key:
			"SrcAlpha,OneMinusSrcAlpha":
				mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
			"One,One", "SrcAlpha,One", "OneMinusDstColor,One":
				mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			"DstColor,Zero", "Zero,SrcColor", "DstColor,OneMinusSrcAlpha", "DstColor,SrcColor":
				mat.blend_mode = BaseMaterial3D.BLEND_MODE_MUL
			"Zero,OneMinusSrcColor", "OneMinusDstColor,Zero":
				mat.blend_mode = BaseMaterial3D.BLEND_MODE_SUB
			"One,OneMinusSrcAlpha":
				mat.blend_mode = BaseMaterial3D.BLEND_MODE_PREMULT_ALPHA
			_:
				mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
		notes.append("blend " + key)
	elif qname == "Transparent" or qname == "Overlay" or info.get("grabpass", false):
		transparent = true
		notes.append("queue " + qname)
	elif mode == 2 or mode == 3:
		if not kws.get("_ALPHABLEND_ON", false) and not kws.get("_ALPHAPREMULTIPLY_ON", false):
			transparent = true
			notes.append("_Mode " + str(mode))
	if transparent:
		if mat.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	elif (qname == "AlphaTest" or mode == 1) and mat.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = float(floats.get("_Cutoff", 0.5))
		notes.append("cutout")
	var zwrite := resolve_toggle(str(info.get("zwrite", "")), floats)
	if zwrite == "Off":
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		notes.append("zwrite off")
	var ztest := str(info.get("ztest", ""))
	if ztest == "Always" or ztest == "Off":
		mat.no_depth_test = true
		notes.append("ztest always")
	var cull := resolve_toggle(str(info.get("cull", "")), floats)
	if cull == "Off" or cull == "Front" or cull == "Back":
		pass
	var cull_raw := str(info.get("cull", ""))
	if cull_raw.begins_with("["):
		# Unity CullMode: 0 Off, 1 Front, 2 Back
		var key := cull_raw.substr(1, cull_raw.length() - 2)
		if floats.has(key):
			cull_raw = ["Off", "Front", "Back"][clampi(int(floats[key]), 0, 2)]
		else:
			cull_raw = ""
	if cull_raw == "Off":
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		notes.append("cull off")
	elif cull_raw == "Front":
		mat.cull_mode = BaseMaterial3D.CULL_FRONT
		notes.append("cull front")
	if transparent and qoffset != 0:
		mat.render_priority = clampi(qoffset, -128, 127)
	return ", ".join(notes)


## Assign a material's Unity properties to the uniforms of a ported shader.
static func apply_port_uniforms(mat: ShaderMaterial, texs: Dictionary, floats: Dictionary, colors: Dictionary, textures: Callable) -> void:
	if mat.shader == null:
		return
	for u in mat.shader.get_shader_uniform_list(true):
		var uname: String = str(u.get("name", ""))
		var utype: int = int(u.get("type", TYPE_NIL))
		if utype == TYPE_OBJECT:
			if texs.has(uname):
				var tex: Texture = textures.call(uname)
				if tex != null:
					mat.set_shader_parameter(uname, tex)
			continue
		if uname.ends_with("_ST") and texs.has(uname.trim_suffix("_ST")):
			var env: Dictionary = texs[uname.trim_suffix("_ST")]
			var sc: Vector2 = env.get("m_Scale", Vector2(1, 1))
			var of: Vector2 = env.get("m_Offset", Vector2(0, 0))
			mat.set_shader_parameter(uname, Vector4(sc.x, sc.y, of.x, of.y))
			continue
		if floats.has(uname):
			match utype:
				TYPE_INT:
					mat.set_shader_parameter(uname, int(floats[uname]))
				TYPE_BOOL:
					mat.set_shader_parameter(uname, float(floats[uname]) != 0.0)
				_:
					mat.set_shader_parameter(uname, float(floats[uname]))
			continue
		if colors.has(uname):
			var c: Color = colors[uname]
			match utype:
				TYPE_COLOR, TYPE_VECTOR4:
					mat.set_shader_parameter(uname, c)
				TYPE_VECTOR3:
					mat.set_shader_parameter(uname, Vector3(c.r, c.g, c.b))
				TYPE_VECTOR2:
					mat.set_shader_parameter(uname, Vector2(c.r, c.g))
				_:
					mat.set_shader_parameter(uname, c)


# --- sky ---------------------------------------------------------------------------------------

## Unity's Skybox/Procedural approximated with a ProceduralSkyMaterial.
static func procedural_sky(floats: Dictionary, colors: Dictionary) -> ProceduralSkyMaterial:
	var sky := ProceduralSkyMaterial.new()
	var exposure: float = float(floats.get("_Exposure", 1.3)) / 1.3
	var thickness: float = clampf(float(floats.get("_AtmosphereThickness", 1.0)), 0.0, 5.0)
	var tint: Color = colors.get("_SkyTint", Color(0.5, 0.5, 0.5, 1.0))
	var ground: Color = colors.get("_GroundColor", Color(0.369, 0.349, 0.341, 1.0))
	var tint2 := Vector3(tint.r, tint.g, tint.b) * 2.0
	# Unity's default sky (thickness 1, grey tint, exposure 1.3): saturated blue zenith, pale horizon
	var top := Vector3(0.26, 0.45, 0.80) * tint2
	var horizon := Vector3(0.70, 0.82, 0.95) * tint2.lerp(Vector3.ONE, 0.5)
	var thick := sqrt(thickness)
	top = top * thick * exposure
	horizon = horizon * lerpf(1.0, thick, 0.5) * exposure
	sky.sky_top_color = Color(top.x, top.y, top.z)
	sky.sky_horizon_color = Color(horizon.x, horizon.y, horizon.z)
	sky.sky_curve = 0.1
	var gb: Color = ground * exposure
	var gh: Color = ground.lerp(Color(horizon.x, horizon.y, horizon.z), 0.5) * exposure
	sky.ground_bottom_color = Color(gb.r, gb.g, gb.b, 1.0)
	sky.ground_horizon_color = Color(gh.r, gh.g, gh.b, 1.0)
	sky.ground_curve = 0.02
	var sun_disk: int = int(floats.get("_SunDisk", 2))
	if sun_disk == 0:
		sky.sun_angle_max = 0.0
	else:
		sky.sun_angle_max = clampf(float(floats.get("_SunSize", 0.04)) * 60.0, 0.5, 30.0)
		sky.sun_curve = clampf(1.0 / maxf(float(floats.get("_SunSizeConvergence", 5.0)), 0.1), 0.02, 1.0)
	return sky


static func _face_image(tex: Texture) -> Image:
	if tex == null or not (tex is Texture2D):
		return null
	var img: Image = (tex as Texture2D).get_image()
	if img == null:
		return null
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8 and img.get_format() != Image.FORMAT_RGBAF:
		img.convert(Image.FORMAT_RGBA8 if not _is_float_format(img.get_format()) else Image.FORMAT_RGBAF)
	return img


static func _is_float_format(f: int) -> bool:
	return f in [Image.FORMAT_RF, Image.FORMAT_RGF, Image.FORMAT_RGBF, Image.FORMAT_RGBAF, Image.FORMAT_RH, Image.FORMAT_RGH, Image.FORMAT_RGBH, Image.FORMAT_RGBAH, Image.FORMAT_RGBE9995]


## Equirectangular panorama (Godot PanoramaSkyMaterial mapping) from six Unity skybox faces.
## `faces`: {"+x": Image, "-x": ..., "+y", "-y", "+z", "-z"} in Unity axes (+z = Front).
## `rotation_deg`: Unity _Rotation (about Y). `scale`: colour multiplier (tint × exposure).
static func equirect_from_faces(faces: Dictionary, width: int, rotation_deg: float, scale: Color) -> Image:
	var height: int = maxi(width / 2, 1)
	var out := Image.create(width, height, false, Image.FORMAT_RGBA8)
	# (normal, right, up) of each face as seen from inside, Unity axes
	var frames: Dictionary = {
		"+z": [Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
		"-z": [Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
		"+x": [Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)],
		"-x": [Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
		"+y": [Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)],
		"-y": [Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
	}
	var sizes: Dictionary = {}
	for k in faces:
		var im: Image = faces[k]
		sizes[k] = Vector2i(im.get_width(), im.get_height()) if im != null else Vector2i.ZERO
	var rot: float = deg_to_rad(rotation_deg)
	for j in range(height):
		var theta: float = (float(j) + 0.5) / float(height) * PI
		var st := sin(theta)
		var y := cos(theta)
		for i in range(width):
			var phi: float = (float(i) + 0.5) / float(width) * TAU
			# Godot direction for this panorama pixel, then Unity axes (mirror X), then skybox rotation
			var dg := Vector3(st * sin(phi), y, -st * cos(phi))
			var d := Vector3(-dg.x, dg.y, dg.z).rotated(Vector3.UP, -rot)
			var ax := absf(d.x)
			var ay := absf(d.y)
			var az := absf(d.z)
			var key: String
			if ax >= ay and ax >= az:
				key = "+x" if d.x > 0.0 else "-x"
			elif ay >= az:
				key = "+y" if d.y > 0.0 else "-y"
			else:
				key = "+z" if d.z > 0.0 else "-z"
			var im: Image = faces.get(key)
			if im == null:
				out.set_pixel(i, j, Color.BLACK)
				continue
			var fr: Array = frames[key]
			var dn: float = d.dot(fr[0])
			var s: float = d.dot(fr[1]) / dn
			var tt: float = d.dot(fr[2]) / dn
			var sz: Vector2i = sizes[key]
			var px: int = clampi(int((s + 1.0) * 0.5 * sz.x), 0, sz.x - 1)
			var py: int = clampi(int((1.0 - tt) * 0.5 * sz.y), 0, sz.y - 1)
			var c: Color = im.get_pixel(px, py)
			out.set_pixel(i, j, Color(c.r * scale.r, c.g * scale.g, c.b * scale.b, 1.0))
	return out


## Shift an equirectangular image horizontally by a skybox rotation and scale its colours.
static func adjust_equirect(src: Image, rotation_deg: float, scale: Color) -> Image:
	var w := src.get_width()
	var h := src.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var shift: int = int(round(-rotation_deg / 360.0 * w)) % w
	for j in range(h):
		for i in range(w):
			var c: Color = src.get_pixel((i + shift + w) % w, j)
			out.set_pixel(i, j, Color(c.r * scale.r, c.g * scale.g, c.b * scale.b, 1.0))
	return out


static func texture_from_image(img: Image) -> Texture2D:
	var t := PortableCompressedTexture2D.new()
	t.create_from_image(img, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)
	return t
