extends Node
## SaveGame autoload (NATIVE_PORT 3-6, NATIVE_PARITY D1). Crash-safe JSON progress file with a schema number.
##   write: progress.json.tmp (flush + close) -> the current progress.json is copied to .bak only while it still parses
##          (a corrupt main never overwrites a good backup) -> rename .tmp over progress.json (atomic on POSIX/iOS).
##   read : progress.json; missing or unparsable -> progress.json.bak. An unparsable main is kept as .corrupt.
##   schema: data["schema"] == SCHEMA after migrate(). migrate() walks 0 -> SCHEMA, one step per schema:
##          0 = no "schema" key: a web `lane1.progress.v1` dict (main.js:loadProgress — ver 3, or v0.2 without ver,
##          whose stage ids 1..5 are remapped 1,11,4,9,50) or an empty/unknown dict (fresh progress).
##   A file written by a newer build (schema > SCHEMA) is loaded as-is but never overwritten (read_only), so installing
##   an older binary over a newer save cannot destroy it (MOBILE_BUILD rollback note).
## Field defaults (equip, settings, ...) are Progress's job (meta/progress.gd); this layer only versions the file.
##
## 가설: ✅ tmp + rename + .bak + "never back up a corrupt main" is enough for a single-writer mobile save: a crash at any
##       point leaves either the old main, the new main, or a good .bak.

const SCHEMA: int = 1
## main.js:41 v0.2 handmade ids -> v0.3 catalog ids (remapped into a new dict: 3->4 and 4->9 collide in place).
const WEB_V02_REMAP: Dictionary = {"1": "1", "2": "11", "3": "4", "4": "9", "5": "50"}
const WEB_REMAP_KEYS: Array[String] = ["stars", "best", "album"]

## Overridable for tests (e.g. "user://test_meta/progress.json").
var path: String = "user://progress.json"
## Set by load_progress(): "main" | "bak" | "none".
var last_source: String = ""
## True after loading a file from a newer schema: save_progress() refuses (ERR_UNAVAILABLE).
var read_only: bool = false


func load_progress() -> Dictionary:
	read_only = false
	last_source = "none"
	var main: Variant = _read(path)
	if main == null and FileAccess.file_exists(path):
		DirAccess.copy_absolute(path, path + ".corrupt")
		push_warning("SaveGame: %s is unreadable, kept as .corrupt; trying .bak" % path)
	var data: Variant = main
	if data != null:
		last_source = "main"
	else:
		data = _read(path + ".bak")
		if data != null:
			last_source = "bak"
	if data == null:
		return {}
	var d: Dictionary = data
	if int(d.get("schema", 0)) > SCHEMA:
		read_only = true
		push_warning("SaveGame: schema %d is newer than %d; loaded read-only" % [int(d["schema"]), SCHEMA])
		return d
	return migrate(d)


func save_progress(data: Dictionary) -> Error:
	if read_only:
		return ERR_UNAVAILABLE
	var payload: Dictionary = data.duplicate(true)
	payload["schema"] = SCHEMA
	var dir: String = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var tmp: String = path + ".tmp"
	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	var ok: bool = f.store_string(JSON.stringify(payload, "", true))
	f.flush()
	f.close()
	if not ok:
		return ERR_FILE_CANT_WRITE
	if _read(path) != null:
		var bak_err: Error = DirAccess.copy_absolute(path, path + ".bak")
		if bak_err != OK:
			return bak_err
	return DirAccess.rename_absolute(tmp, path)


## Removes the save, its backup and leftovers (tests and the dev reset only; the app never calls this).
func wipe() -> void:
	for p: String in [path, path + ".bak", path + ".tmp", path + ".corrupt"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


## Upgrades a loaded dict to SCHEMA (a copy). Schemas newer than SCHEMA are returned unchanged.
static func migrate(data: Dictionary) -> Dictionary:
	var d: Dictionary = data.duplicate(true)
	var s: int = int(d.get("schema", 0))
	while s < SCHEMA:
		match s:
			0:
				d = _schema0_to_1(d)
		s += 1
		d["schema"] = s
	return d


## Web progress (lane1.progress.v1) -> native schema 1. Mirrors main.js:loadProgress 37-46: a dict without a numeric
## `unlocked` is not a save (fresh progress); v0.2 (no `ver`) gets its stage ids remapped.
static func _schema0_to_1(p: Dictionary) -> Dictionary:
	var unlocked: Variant = p.get("unlocked")
	if not (unlocked is float or unlocked is int):
		return {"schema": 1}
	var out: Dictionary = p.duplicate(true)
	var ver: Variant = p.get("ver")
	if ver == null or (ver is float or ver is int) and float(ver) == 0.0:
		for k: String in WEB_REMAP_KEYS:
			var src: Dictionary = p.get(k, {}) if p.get(k) is Dictionary else {}
			var keys: Array = src.keys()
			keys.sort_custom(_js_key_order)   # Object.entries order: integer-like keys ascending, later wins
			var remapped: Dictionary = {}
			for id: Variant in keys:
				remapped[str(WEB_V02_REMAP.get(str(id), str(id)))] = src[id]
			out[k] = remapped
	out.erase("ver")
	return out


static func _js_key_order(a: Variant, b: Variant) -> bool:
	var sa: String = str(a)
	var sb: String = str(b)
	if sa.is_valid_int() and sb.is_valid_int():
		return int(sa) < int(sb)
	if sa.is_valid_int() != sb.is_valid_int():
		return sa.is_valid_int()
	return false


## Parsed Dictionary, or null when the file is missing or not a JSON object.
func _read(file_path: String) -> Variant:
	if not FileAccess.file_exists(file_path):
		return null
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(file_path)) != OK:
		return null
	return json.data if json.data is Dictionary else null
