extends RefCounted
## T0: SaveGame (core/save_game.gd) — atomic write, .bak fallback, schema migration, future-schema guard (NATIVE_PARITY D1).
##
## 가설: ✅ tmp + rename + .bak (never refreshed from a corrupt main) survives a corrupt main file; schema 0 (web
##       lane1.progress.v1, ver 3 or v0.2) migrates to schema 1 with main.js:loadProgress's id remap; a newer schema
##       is never overwritten.

const DIR: String = "user://test_meta/save"
const _SaveGame := preload("res://core/save_game.gd")

var _fails: int = 0


func run() -> int:
	var sg: Node = _SaveGame.new()
	sg.path = DIR.path_join("progress.json")
	var p: String = sg.path
	sg.call(&"wipe")

	_check((sg.call(&"load_progress") as Dictionary).is_empty() and sg.last_source == "none", "no file -> {} (source none)")

	# Round trip + backup rotation.
	var a: Dictionary = {"unlocked": 3, "wallet": 190000, "stars": {"1": 3, "2": 1}, "owned": ["car_porter"]}
	_check(sg.call(&"save_progress", a) == OK and FileAccess.file_exists(p) and not FileAccess.file_exists(p + ".tmp"), "save: main written, no .tmp left")
	var back: Dictionary = sg.call(&"load_progress")
	_check(int(back["schema"]) == _SaveGame.SCHEMA and int(back["wallet"]) == 190000 and int(back["stars"]["1"]) == 3
		and back["owned"] == ["car_porter"] and sg.last_source == "main", "load: same data + schema %d (source main)" % _SaveGame.SCHEMA)
	var b: Dictionary = a.duplicate(true)
	b["wallet"] = 250000
	sg.call(&"save_progress", b)
	_check(int((_json(p + ".bak") as Dictionary).get("wallet", -1)) == 190000 and int((_json(p) as Dictionary).get("wallet", -1)) == 250000,
		"second save: previous main rotated to .bak")

	# Corrupt main: read .bak, keep the bad file as .corrupt, and a later save never copies it over the good .bak.
	_write(p, "{\"wallet\": 99, \"unlo")
	var rec: Dictionary = sg.call(&"load_progress")
	_check(int(rec.get("wallet", -1)) == 190000 and sg.last_source == "bak" and FileAccess.file_exists(p + ".corrupt"),
		"corrupt main -> .bak data (wallet 190000), bad file kept as .corrupt")
	rec["wallet"] = 260000
	_check(sg.call(&"save_progress", rec) == OK, "save after recovery")
	_check(int((_json(p + ".bak") as Dictionary).get("wallet", -1)) == 190000 and int((_json(p) as Dictionary).get("wallet", -1)) == 260000,
		"corrupt main was not rotated into .bak (good backup kept)")
	_write(p, "")
	_write(p + ".bak", "not json")
	_check((sg.call(&"load_progress") as Dictionary).is_empty() and sg.last_source == "none", "main and .bak both unreadable -> {} (fresh)")
	_write(p, "[1, 2, 3]")
	_check((sg.call(&"load_progress") as Dictionary).is_empty(), "a JSON array is not a save -> {}")

	# Web saves (main.js:loadProgress): ver 3 kept as-is, v0.2 ids remapped 1,2,3,4,5 -> 1,11,4,9,50, non-saves -> fresh.
	var v3: Dictionary = _SaveGame.migrate({"ver": 3, "unlocked": 12, "stars": {"1": 3, "11": 2}, "best": {"1": 500}, "wallet": 1000,
		"subs": 20, "album": {"1": {"stars": 3, "count": 2}}, "owned": ["pas_4k"], "equip": {"car": "car_hatch"}})
	_check(int(v3["schema"]) == 1 and not v3.has("ver") and int(v3["unlocked"]) == 12 and v3["stars"] == {"1": 3, "11": 2}
		and v3["owned"] == ["pas_4k"], "web v3 save -> schema 1, data unchanged")
	var v02: Dictionary = _SaveGame.migrate({"unlocked": 5, "stars": {"1": 3, "2": 2, "3": 1, "4": 2, "5": 3}, "best": {"3": 700, "4": 900},
		"album": {"5": {"stars": 3}}})
	_check(v02["stars"] == {"1": 3, "11": 2, "4": 1, "9": 2, "50": 3} and v02["best"] == {"4": 700, "9": 900} and (v02["album"] as Dictionary).has("50"),
		"web v0.2 save -> ids remapped into a new dict (3->4 and 4->9 do not collide)")
	_check(_SaveGame.migrate({"wallet": 5}) == {"schema": 1} and _SaveGame.migrate({}) == {"schema": 1},
		"dict without numeric 'unlocked' -> fresh schema-1 progress (web: not a save)")
	_check(_SaveGame.migrate({"schema": 1, "wallet": 7}) == {"schema": 1, "wallet": 7}, "schema 1 is left alone")

	# A file from a newer build is read but never overwritten.
	sg.call(&"wipe")
	var future: String = "{\"schema\": %d, \"wallet\": 777, \"newField\": true}" % (_SaveGame.SCHEMA + 1)
	_write(p, future)
	var fut: Dictionary = sg.call(&"load_progress")
	_check(sg.read_only and int(fut["wallet"]) == 777 and bool(fut["newField"]), "schema %d file loads read-only, unknown keys kept" % (_SaveGame.SCHEMA + 1))
	_check(sg.call(&"save_progress", {"wallet": 1}) == ERR_UNAVAILABLE and FileAccess.get_file_as_string(p) == future, "save refused, newer file untouched")
	sg.call(&"wipe")
	sg.call(&"load_progress")
	_check(not sg.read_only, "read_only clears on the next load")

	sg.call(&"wipe")
	sg.free()
	return _fails


func _write(path: String, text: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null


func _check(ok: bool, what: String) -> void:
	if ok:
		print("PASS ", what)
	else:
		_fails += 1
		print("FAIL ", what)
