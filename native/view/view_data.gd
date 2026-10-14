class_name ViewData
extends RefCounted
## Data access for view code: goes through the DB autoload (res://core/db.gd) when the scene tree has it, and reads
## res://data/<name>.json directly otherwise (headless -s scripts, tools), with the same per-name cache semantics.

static var _cache: Dictionary = {}


static func table(table_name: String) -> Variant:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		var db: Node = tree.root.get_node_or_null(^"DB")
		if db != null and db.has_method(&"get_table"):
			return db.call(&"get_table", StringName(table_name))
	if _cache.has(table_name):
		return _cache[table_name]
	var path: String = "res://data/%s.json" % table_name
	var v: Variant = null
	if FileAccess.file_exists(path):
		v = JSON.parse_string(FileAccess.get_file_as_string(path))
	_cache[table_name] = v
	return v


## Stage dictionary by id from data/stages.json ({schema_version, stages:[…]}).
static func stage(id: int) -> Dictionary:
	var st: Variant = table("stages")
	if st is Dictionary:
		for s: Variant in (st as Dictionary).get("stages", []):
			if s is Dictionary and int((s as Dictionary).get("id", -1)) == id:
				return s
	return {"id": id, "sky": "day", "road": [{"type": "straight"}]}


## SKY preset (data/sky.json presets[name]); colours are 0xRRGGBB ints.
static func sky(sky_name: String) -> Dictionary:
	var sk: Variant = table("sky")
	if sk is Dictionary:
		var presets: Dictionary = (sk as Dictionary).get("presets", {})
		if presets.has(sky_name):
			return presets[sky_name]
		if presets.has("day"):
			return presets["day"]
	return {"bottom": 0xd8f0ff, "fog": 0xcfeaff, "fogFar": 420.0, "fogNear": 120.0, "hemiGround": 0x8a9a6a,
		"hemiI": 1.25, "hemiSky": 0xbfe4ff, "night": false, "sun": 0xfff4dc, "sunI": 2.6, "sunPos": [-40, 80, 30],
		"top": 0x5fb8ff}


static func hex(c: Variant) -> Color:
	return Color.hex((int(c) << 8) | 0xff)
