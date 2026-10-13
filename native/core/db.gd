extends Node
## DB autoload (stub, M1-0). Lazily loads generated tables from res://data/<name>.json and caches them.
## The table set is produced by tools/content/build.mjs (NATIVE_PORT 3-6); M1a fills in typed accessors.

const DATA_DIR: String = "res://data"

var _tables: Dictionary[StringName, Variant] = {}


func has_table(table: StringName) -> bool:
	return _tables.has(table) or FileAccess.file_exists(_path_of(table))


## Returns the parsed JSON (Dictionary or Array), or null if the file is missing or invalid.
func get_table(table: StringName) -> Variant:
	if _tables.has(table):
		return _tables[table]
	var path: String = _path_of(table)
	if not FileAccess.file_exists(path):
		push_error("DB: missing table %s" % path)
		return null
	var json := JSON.new()
	var err: Error = json.parse(FileAccess.get_file_as_string(path))
	if err != OK:
		push_error("DB: %s:%d %s" % [path, json.get_error_line(), json.get_error_message()])
		return null
	_tables[table] = json.data
	return json.data


func clear_cache() -> void:
	_tables.clear()


func _path_of(table: StringName) -> String:
	return "%s/%s.json" % [DATA_DIR, table]
