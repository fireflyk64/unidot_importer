# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# SPDX-License-Identifier: MIT
@tool
extends EditorPlugin
## Command-line driver for the package importer, for CI and batch conversions:
##
##   godot --headless --editor --path <project> -- --unidot-import <package.unitypackage | AssetDir> \
##          [--unidot-text-scenes] [--unidot-text-resources] [--unidot-unsupported-components] \
##          [--unidot-verbose] [--unidot-log <file>] [--unidot-keep-open]
##
## The import runs exactly as from Project → Tools, with every asset selected. The editor quits
## when the import finishes (exit code 0, or 3 when assets failed to import) unless --unidot-keep-open.

const package_import_dialog_class := preload("../package_import_dialog.gd")
const asset_database_class := preload("../asset_database.gd")

var _dialog: RefCounted = null
# fields package_import_dialog.gd expects on its editor plugin
var package_import_dialog: RefCounted = null
var last_selected_dir: String = ""
var file_dialog_mode := EditorFileDialog.DISPLAY_LIST
var _poll: Timer = null
var _started: bool = false
var _args: Dictionary = {}
var _log_path: String = ""
var _keep_open: bool = false
var _ticks_idle: int = 0


func _enter_tree() -> void:
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < raw.size():
		var a: String = raw[i]
		if a.begins_with("--unidot-"):
			var key: String = a.substr(9)
			if i + 1 < raw.size() and not raw[i + 1].begins_with("--"):
				_args[key] = raw[i + 1]
				i += 1
			else:
				_args[key] = true
		i += 1
	if not _args.has("import"):
		return
	_log_path = str(_args.get("log", ""))
	_keep_open = _args.has("keep-open")
	print("[unidot headless] importing " + str(_args["import"]))
	_poll = Timer.new()
	_poll.wait_time = 0.5
	_poll.autostart = true
	_poll.process_callback = Timer.TIMER_PROCESS_IDLE
	get_editor_interface().get_base_control().add_child(_poll, true)
	_poll.timeout.connect(self._tick)


func _tick() -> void:
	var fs: EditorFileSystem = get_editor_interface().get_resource_filesystem()
	if not _started:
		# Wait for the editor's initial scan so imports of textures/models can run.
		if fs.is_scanning():
			_ticks_idle = 0
			return
		_ticks_idle += 1
		if _ticks_idle < 2:
			return
		_started = true
		_start()
		return
	if _dialog == null:
		return
	if _dialog.import_finished:
		_finish()


func _start() -> void:
	var path: String = str(_args["import"])
	if not path.begins_with("/") and not path.begins_with("res://") and not path.contains(":"):
		path = ProjectSettings.globalize_path("res://").path_join(path)
	if not (DirAccess.dir_exists_absolute(path) or FileAccess.file_exists(path)):
		push_error("[unidot headless] no such package or directory: " + path)
		_exit(2)
		return
	_dialog = package_import_dialog_class.new()
	_dialog.editor_plugin = self
	_dialog.auto_import = true
	_dialog._keep_open_on_import = true
	_dialog._show_importer_common()
	_dialog._selected_package(path)
	var db: Resource = _dialog.asset_database
	db.use_text_scenes = _args.has("text-scenes")
	db.use_text_resources = _args.has("text-resources")
	db.add_unsupported_components = _args.has("unsupported-components")
	db.enable_verbose_logs = _args.has("verbose")
	db.enable_unidot_keys = _args.has("unidot-keys")
	if _args.has("no-vrm"):
		db.vrm_spring_bones = false
	if _dialog.main_dialog != null:
		_dialog.main_dialog.hide()


func _finish() -> void:
	_poll.stop()
	var db: Resource = _dialog.asset_database
	var fails: int = 0
	var report: PackedStringArray = []
	var verbose: bool = _args.has("verbose")
	for path in db.path_to_meta:
		var meta = db.path_to_meta[path]
		if meta == null or not ("log_message_holder" in meta) or meta.log_message_holder == null:
			continue
		var holder = meta.log_message_holder
		fails += holder.fails.size()
		var lines: PackedStringArray = holder.all_logs if verbose else holder.warnings_fails
		for line in lines:
			report.append(str(path) + ": " + line)
	if _log_path != "":
		var f := FileAccess.open(_log_path, FileAccess.WRITE)
		if f != null:
			for line in report:
				f.store_line(line)
			f.close()
	print("[unidot headless] import finished; %d warning/fail lines, %d failures" % [report.size(), fails])
	if not _keep_open:
		_exit(3 if fails > 0 else 0)


func _exit(code: int) -> void:
	# Let pending deferred calls (scene saves, database save) run first.
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(code)
