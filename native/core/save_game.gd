extends Node
## SaveGame autoload (stub, M1-0). Crash-safe JSON progress file (NATIVE_PORT 3-6):
##   write: progress.json.tmp -> previous progress.json copied to .bak -> rename .tmp over progress.json
##   read : progress.json, falling back to progress.json.bak when missing or unparsable.
## Version migration (web `lane1.progress.v1`, ver 1..3) lands with the real save schema in M1b.

const SAVE_VERSION: int = 3

## Overridable for tests (e.g. "user://test_progress.json").
var path: String = "user://progress.json"


func load_progress() -> Dictionary:
	for candidate: String in [path, path + ".bak"]:
		var data: Dictionary = _read(candidate)
		if not data.is_empty():
			return data
	return {}


func save_progress(data: Dictionary) -> Error:
	var payload: Dictionary = data.duplicate(true)
	if not payload.has("ver"):
		payload["ver"] = SAVE_VERSION
	var tmp: String = path + ".tmp"
	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	var ok: bool = f.store_string(JSON.stringify(payload, "", false))
	f.close()
	if not ok:
		return ERR_FILE_CANT_WRITE
	if FileAccess.file_exists(path):
		var bak_err: Error = DirAccess.copy_absolute(path, path + ".bak")
		if bak_err != OK:
			return bak_err
	return DirAccess.rename_absolute(tmp, path)


func _read(file_path: String) -> Dictionary:
	if not FileAccess.file_exists(file_path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(file_path))
	if parsed is Dictionary:
		return parsed
	return {}
