## Reader for the binary format of Odin Serializer, as far as VRChat uses it for
## `UdonBehaviour.serializedPublicVariablesBytesString`: a `UdonVariableTable` whose variables are
## `UdonVariable<T>` nodes with a `SymbolName` and a `Value`. UdonSharp 0.x keeps every serialized
## field of a behaviour there (there is no C# proxy component with YAML keys in those scenes).
##
## Entry stream: one tag byte, then a name (named tags), then the payload. Strings are a width
## flag (0 = 8 bit, 1 = UTF-16), an int32 length and the characters. Types are written once by
## name (tag 0x2F + id + string) and by id afterwards (tag 0x30).
##
## Decoded values: bool / int / float / String, `{"$ref": index}` for a Unity object (index into
## `publicVariablesUnityEngineObjects`), `{"$type": ..., name: value, "$items": [...]}` for nodes,
## and for primitive arrays `{"$prim": bytes_per_element, "count": n, "bytes": PackedByteArray}`.
extends RefCounted

const TAG_NAMED := [0x01, 0x03, 0x09, 0x0B, 0x0D, 0x0F, 0x11, 0x13, 0x15, 0x17, 0x19, 0x1B, 0x1D, 0x1F, 0x21, 0x23, 0x25, 0x27, 0x29, 0x2B, 0x2D, 0x32]

var _b: PackedByteArray
var _i: int = 0
var _types: Dictionary = {}
var failed: bool = false


## `{symbol: {"type": C# type name, "value": decoded value}}`; empty when the text is not a table.
static func decode_variable_table(base64_text: String) -> Dictionary:
	var out: Dictionary = {}
	if base64_text.strip_edges() == "":
		return out
	var reader = new()
	reader._b = Marshalls.base64_to_raw(base64_text.strip_edges())
	if reader._b.size() < 8:
		return out
	var entry: Array = reader._entry()
	if reader.failed or entry[0] != "node":
		return out
	var table: Dictionary = entry[2]
	var top: Dictionary = _named(table.get("$items", []))
	var variables = top.get("Variables")
	if not (variables is Dictionary):
		return out
	for v in variables.get("$items", []):
		var node = v[1] if (v is Array and v.size() == 2 and v[0] is String) else v
		if not (node is Dictionary):
			continue
		var fields: Dictionary = _named(node.get("$items", []))
		var symbol = fields.get("SymbolName")
		if symbol == null:
			continue
		var tname: String = str(node.get("$type", ""))
		var open: int = tname.find("[[")
		if open >= 0:
			tname = tname.substr(open + 2)
			var comma: int = tname.find(",")
			if comma >= 0:
				tname = tname.substr(0, comma)
		out[str(symbol)] = {"type": tname, "value": fields.get("Value")}
	return out


## Nodes written through ISerializable come as an array of named entries where each value is
## preceded by a `type` entry: [["type", T], [name, value], ...] → {name: value}.
static func _named(items: Array) -> Dictionary:
	var out: Dictionary = {}
	for it in items:
		if it is Array and it.size() == 2 and it[0] is String and it[0] != "type":
			out[it[0]] = it[1]
	return out


func _u8() -> int:
	if _i >= _b.size():
		failed = true
		return 0x31
	var v: int = _b[_i]
	_i += 1
	return v


func _i32() -> int:
	if _i + 4 > _b.size():
		failed = true
		return 0
	var v: int = _b.decode_s32(_i)
	_i += 4
	return v


func _i64() -> int:
	if _i + 8 > _b.size():
		failed = true
		return 0
	var v: int = _b.decode_s64(_i)
	_i += 8
	return v


func _string() -> String:
	var wide: int = _u8()
	var n: int = _i32()
	if n < 0 or failed:
		failed = true
		return ""
	var size: int = n * 2 if wide != 0 else n
	if _i + size > _b.size():
		failed = true
		return ""
	var chunk: PackedByteArray = _b.slice(_i, _i + size)
	_i += size
	return chunk.get_string_from_utf16() if wide != 0 else chunk.get_string_from_ascii()


func _type():
	var t: int = _u8()
	match t:
		0x2F:
			var id: int = _i32()
			var name: String = _string()
			_types[id] = name
			return name
		0x30:
			return _types.get(_i32(), "?")
		0x2E:
			return null
	failed = true
	return null


## One entry: [kind, name or null, value]; kinds: node, value, array, end, endarray, eos.
func _entry() -> Array:
	var t: int = _u8()
	if failed or t == 0x31:
		return ["eos", null, null]
	var name = _string() if TAG_NAMED.has(t) else null
	match t:
		0x01, 0x02:
			var ty = _type()
			_i32()  # reference id
			return ["node", name, _node(ty)]
		0x03, 0x04:
			return ["node", name, _node(_type())]
		0x05:
			return ["end", null, null]
		0x06:
			return ["array", name, _i64()]
		0x07:
			return ["endarray", null, null]
		0x08:
			var count: int = _i32()
			var bpe: int = _i32()
			var size: int = count * bpe
			if count < 0 or bpe <= 0 or _i + size > _b.size():
				failed = true
				return ["eos", null, null]
			var raw: PackedByteArray = _b.slice(_i, _i + size)
			_i += size
			return ["value", name, {"$prim": bpe, "count": count, "bytes": raw}]
		0x09, 0x0A:
			return ["value", name, {"$internal": _i32()}]
		0x0B, 0x0C:
			return ["value", name, {"$ref": _i32()}]
		0x0D, 0x0E:
			_i += 16
			return ["value", name, null]
		0x32, 0x33:
			return ["value", name, {"$refstr": _string()}]
	var k: int = t if t % 2 == 1 else t - 1  # the named form of the tag
	var v = null
	match k:
		0x0F:
			v = _b.decode_s8(_i)
			_i += 1
		0x11:
			v = _b.decode_u8(_i)
			_i += 1
		0x13:
			v = _b.decode_s16(_i)
			_i += 2
		0x15:
			v = _b.decode_u16(_i)
			_i += 2
		0x17:
			v = _b.decode_s32(_i)
			_i += 4
		0x19:
			v = _b.decode_u32(_i)
			_i += 4
		0x1B, 0x1D:
			v = _b.decode_s64(_i)
			_i += 8
		0x1F:
			v = _b.decode_float(_i)
			_i += 4
		0x21:
			v = _b.decode_double(_i)
			_i += 8
		0x23:
			_i += 16  # decimal: not used by Udon variables
		0x25:
			v = _b.slice(_i, _i + 2).get_string_from_utf16()
			_i += 2
		0x27:
			v = _string()
		0x29:
			_i += 16
		0x2B:
			v = _u8() != 0
		0x2D:
			v = null
		_:
			failed = true
			return ["eos", null, null]
	if _i > _b.size():
		failed = true
	return ["value", name, v]


func _node(type_name) -> Dictionary:
	var node: Dictionary = {"$type": type_name, "$items": []}
	while not failed:
		var e: Array = _entry()
		if e[0] == "end" or e[0] == "eos":
			break
		if e[0] == "array":
			var items: Array = []
			while not failed:
				var m: Array = _entry()
				if m[0] == "endarray" or m[0] == "eos":
					break
				items.append([m[1], m[2]] if m[1] != null else m[2])
			node["$items"] = items
			continue
		if e[1] == null:
			node["$items"].append(e[2])
		else:
			node[e[1]] = e[2]
	return node
