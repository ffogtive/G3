extends Node
## DB autoload. Lazily loads generated tables from res://data/<name>.json and caches them.
## The table set is produced by tools/content/build.mjs (NATIVE_PORT 3-6).

const DATA_DIR: String = "res://data"

var _tables: Dictionary[StringName, Variant] = {}


func has_table(table: StringName) -> bool:
	return _tables.has(table) or FileAccess.file_exists(_path_of(table))


## Returns the parsed JSON (Dictionary or Array), or null if the file is missing or invalid.
func get_table(table: StringName) -> Variant:
	if _tables.has(table):
		return _tables[table]
	var data: Variant = load_json(_path_of(table))
	if data != null:
		_tables[table] = data
	return data


func clear_cache() -> void:
	_tables.clear()


## Stage record from stages.json by id (empty Dictionary if unknown).
func stage(id: int) -> Dictionary:
	return find_stage(get_table(&"stages"), id)


## The tables the C++ traffic core reads (Traffic.configure / TrafficBridge.setup).
func traffic_tables() -> Dictionary:
	return {
		"config": get_table(&"config"),
		"vehicle_kinds": get_table(&"vehicle_kinds"),
		"mini_types": get_table(&"mini_types"),
		"approach": get_table(&"approach"),
	}


## Static helpers so RefCounted sim code and tests can read data without the autoload.
## Uses the ext's correctly rounded parser when it is loaded (Traffic.parse_json): Godot's JSON/to_float is
## 1 ulp off on 16-17 digit numbers, and stages.json/goldens carry shortest-round-trip JS doubles. Without
## the ext it falls back to JSON (fine for the GDScript traffic fallback, not for bit parity).
static func load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("DB: missing table %s" % path)
		return null
	if _exact_parser_available():
		return ClassDB.class_call_static(&"Traffic", &"parse_json", FileAccess.get_file_as_string(path))
	var json := JSON.new()
	var err: Error = json.parse(FileAccess.get_file_as_string(path))
	if err != OK:
		push_error("DB: %s:%d %s" % [path, json.get_error_line(), json.get_error_message()])
		return null
	return json.data


static func find_stage(stages_table: Variant, id: int) -> Dictionary:
	if not (stages_table is Dictionary):
		return {}
	for st: Variant in (stages_table as Dictionary).get("stages", []):
		if st is Dictionary and int((st as Dictionary).get("id", -1)) == id:
			return st as Dictionary
	return {}


static func load_traffic_tables() -> Dictionary:
	return {
		"config": load_json(DATA_DIR + "/config.json"),
		"vehicle_kinds": load_json(DATA_DIR + "/vehicle_kinds.json"),
		"mini_types": load_json(DATA_DIR + "/mini_types.json"),
		"approach": load_json(DATA_DIR + "/approach.json"),
	}


## Loads res://ext/traffic.gdextension on demand (a fresh .godot/ has not registered it yet).
## Tries the load at most once per process so the no-ext path does not repeat the loader's ERROR lines.
static var _ext_load_tried: bool = false


static func _exact_parser_available() -> bool:
	if ClassDB.class_exists(&"Traffic"):
		return true
	if not _ext_load_tried:
		_ext_load_tried = true
		const GDEXT: String = "res://ext/traffic.gdextension"
		if FileAccess.file_exists(GDEXT) and not GDExtensionManager.is_extension_loaded(GDEXT):
			GDExtensionManager.load_extension(GDEXT)
	return ClassDB.class_exists(&"Traffic")


func _path_of(table: StringName) -> String:
	return "%s/%s.json" % [DATA_DIR, table]
