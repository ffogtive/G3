class_name ScrMeta
extends RefCounted
## The one door from the screens to the progress model. Wraps /root/Progress (native/meta/progress.gd, the real
## autoload), a private Progress on its own save file (tests / shots), or a ScrProgressStub when meta/ is absent,
## and forwards the CONTRACT names (meta/README.md API). Return shapes are normalised here: buy() → bool,
## daily_villain() → stage id, record_result() keeps the real keys (subs_gained, unlocks, missions[{done}], stats).

var p: Object
var is_stub: bool = false


const PROGRESS_SCRIPT: String = "res://meta/progress.gd"
const SAVE_SCRIPT: String = "res://core/save_game.gd"


## The Progress autoload when registered, else a private model on `fallback_path` (owned by `host`).
static func resolve(host: Node, fallback_path: String = "user://progress.json") -> ScrMeta:
	var real: Node = host.get_tree().root.get_node_or_null(^"Progress") if host.is_inside_tree() else null
	if real != null:
		return bind_to(real)
	return private(host, fallback_path)


## A Progress (or, without meta/, a ScrProgressStub) bound to its own save file — never touches the player's save.
## seed: optional web-shaped progress written to that file first (shots, tests). wipe: start from an empty file.
static func private(host: Node, path: String, seed: Dictionary = {}, wipe: bool = false) -> ScrMeta:
	var sg: Node = (load(SAVE_SCRIPT) as GDScript).new()
	sg.set(&"path", path)
	if wipe or not seed.is_empty():
		sg.call(&"wipe")
	if not seed.is_empty():
		sg.call(&"save_progress", seed)
	var obj: Node
	if ResourceLoader.exists(PROGRESS_SCRIPT):
		obj = (load(PROGRESS_SCRIPT) as GDScript).new()
		obj.name = "PrivateProgress"
		obj.add_child(sg)
		obj.call(&"setup", sg)
		# Progress._ready() binds /root/SaveGame (read only); rebind the private store right after it.
		obj.ready.connect(func() -> void: obj.call(&"setup", sg), CONNECT_ONE_SHOT)
	else:
		sg.free()
		obj = ScrProgressStub.new(path)
		obj.name = "ProgressStub"
	host.add_child(obj)
	return bind_to(obj)


static func bind_to(obj: Object) -> ScrMeta:
	var m := ScrMeta.new()
	m.p = obj
	m.is_stub = obj is ScrProgressStub
	return m


func _call(names: Array[StringName], args: Array = [], fallback: Variant = null) -> Variant:
	for n: StringName in names:
		if p.has_method(n):
			return p.callv(n, args)
	return fallback


func _prop(name: StringName, fallback: Variant) -> Variant:
	if name in p:
		return p.get(name)
	return fallback


# ── stages
func stages() -> Array:
	return _call([&"stages"], [], [])


func chapters() -> Array:
	return _call([&"chapters"], [], [])


func stage(id: int) -> Dictionary:
	var d: Variant = _call([&"stage"], [id])
	if d is Dictionary:
		return d
	for st: Dictionary in stages():
		if int(st["id"]) == id:
			return st
	return {}


func is_unlocked(id: int) -> bool:
	return bool(_call([&"is_unlocked"], [id], id == 1))


func best(id: int) -> Dictionary:
	var b: Variant = _call([&"best"], [id], {})
	return b if b is Dictionary else {"score": int(b)}


func stars_of(id: int) -> int:
	if p.has_method(&"stars_of"):
		return int(p.call(&"stars_of", id))
	return clampi(int(best(id).get("stars", 0)), 0, 3)


func next_stage_id() -> int:
	var v: Variant = _call([&"next_stage_id"])
	if v != null:
		return int(v)
	var last: int = 1
	for st: Dictionary in stages():
		if is_unlocked(int(st["id"])):
			last = int(st["id"])
	return last


func missions_for(id: int) -> Array:
	return _call([&"missions_for"], [id], [])


func record_result(id: int, result: Dictionary) -> Dictionary:
	var r: Dictionary = _call([&"record_result"], [id, result], {})
	var done: Array = []
	for m: Variant in r.get("missions", []):
		done.append(bool((m as Dictionary).get("done", false)) if m is Dictionary else bool(m))
	r["missions_done"] = done
	return r


func album_entry(id: int) -> Dictionary:
	var a: Variant = _call([&"album_entry", &"album"], [id])
	if a is Dictionary:
		return a
	var d: Variant = _prop(&"data", {})
	if d is Dictionary and (d as Dictionary).get("album") is Dictionary:
		var e: Variant = (d["album"] as Dictionary).get(str(id))
		return e if e is Dictionary else {}
	return {}


## ui.js albumGot: an album entry with count/stars/photo, or (pre-album saves) a cleared stage.
func album_got(id: int) -> bool:
	if p.has_method(&"album_has"):
		return bool(p.call(&"album_has", id))
	var a: Dictionary = album_entry(id)
	if int(a.get("count", 0)) > 0 or int(a.get("stars", 0)) > 0 or (a.get("photo") is String and not str(a["photo"]).is_empty()):
		return true
	return stars_of(id) > 0


# ── wallet
func wallet() -> int:
	return int(_prop(&"wallet", _call([&"get_wallet"], [], 0)))


func subs() -> int:
	return int(_prop(&"subs", _call([&"get_subs"], [], 0)))


# ── shop
func shop_items() -> Array:
	return _call([&"shop_items"], [], [])


func item(id: String) -> Dictionary:
	for it: Dictionary in shop_items():
		if str(it["id"]) == id:
			return it
	return {}


func owns(id: String) -> bool:
	var v: Variant = _call([&"owns", &"is_owned"], [id])
	if v != null:
		return bool(v)
	return int(item(id).get("price", 1)) <= 0


func equipped(cat: String) -> String:
	return str(_call([&"equipped", &"equipped_id"], [cat], ""))


func can_buy(id: String) -> bool:
	return bool(_call([&"can_buy"], [id], false))


func buy(id: String) -> bool:
	var v: Variant = _call([&"buy"], [id], false)
	return bool((v as Dictionary).get("ok", false)) if v is Dictionary else bool(v)


func equip(id: String) -> bool:
	return bool(_call([&"equip"], [id], false))


func loadout() -> Dictionary:
	return _call([&"loadout"], [], {})


func daily_villain() -> int:
	var v: Variant = _call([&"daily_villain"], [], 1)
	return int((v as Dictionary).get("id", 1)) if v is Dictionary else int(v)


# ── settings
func get_setting(key: String) -> Variant:
	var v: Variant = _call([&"get_setting", &"setting"], [key])
	if v != null:
		return v
	var s: Variant = _prop(&"settings", {})
	return (s as Dictionary).get(key, ScrProgressStub.SETTINGS_DEFAULT.get(key)) if s is Dictionary else ScrProgressStub.SETTINGS_DEFAULT.get(key)


func set_setting(key: String, value: Variant) -> void:
	_call([&"set_setting"], [key, value])


## r3 S1 run index (meta/progress.gd plays / next_play / begin_play; the stub counts runs without a skip list).
func plays(id: int) -> int:
	return maxi(0, int(_call([&"plays"], [id], 0)))


func next_play(id: int) -> int:
	return maxi(0, int(_call([&"next_play", &"plays"], [id], 0)))


func begin_play(id: int) -> int:
	return maxi(0, int(_call([&"begin_play"], [id], 0)))


func mini_count(id: int) -> int:
	var v: Variant = _call([&"mini_count"], [id])
	return int(v) if v != null else 0
