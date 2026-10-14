class_name ScrProgressStub
extends Node
## Fallback for the `Progress` autoload (native/meta/progress.gd, owned by the meta workflow) when it is not in the
## build: the CONTRACT API with the web rules and the same record_result() keys, so the screens never branch on it.
##   save  : web progress shape {unlocked, stars, best, wallet, subs, album, owned, equip} + settings through
##           core/save_game.gd (atomic tmp + rename + .bak; schema/web-v0.2 migration and read-only future files live there).
##   unlock: clearing stage index i → unlocked = max(unlocked, i + 2)   (main.js:showResult)
##   reward: rewards.js computeReward/applyReward (D3 payout, D4 views/subs/comments/milestones, D5 album)
##   shop  : price-0 items always owned; car/weapon/finish are single slots (buy auto-equips), move/passive always apply
## ScrMeta (screens/meta.gd) prefers /root/Progress when it exists and falls back to this.

signal changed
signal settings_changed(key: String, value: Variant)

const SaveGameScript: GDScript = preload("res://core/save_game.gd")
const SLOT_CATS: PackedStringArray = ["car", "weapon", "finish"]
const STAR_MULT: Array[float] = [1.0, 1.0, 1.5, 2.0]
const SETTINGS_DEFAULT: Dictionary = {"music": true, "sfx": true, "haptics": true, "battery60": false, "left_hand": false,
	"dev_items": false}  # dev_items: Debug builds only (settings row + app loadout), never read by a release build
const MILESTONES: Array = [[1000, "구독자 1천 돌파!"], [10000, "구독자 1만 돌파!"], [100000, "실버 참교육 버튼 획득!"],
	[1000000, "골드 참교육 버튼 획득!"]]
const COMMENTS: PackedStringArray = [
	"사이다 ㅋㅋㅋㅋㅋ", "10년 묵은 체증이 내려갔습니다", "이분 국가유공자 지정해라", "형님 고속도로 순찰대 하세요",
	"{v} 보고 혈압 올랐는데 덕분에 내려감", "저 이 구간 매일 다니는데 진짜 저런 차 있음", "비상등 깜빡이는 거 보고 울컥했다",
	"대~한민국 경적 소리 듣고 빵 터짐", "이게 나라다", "타이어 펑크 소리 ASMR로 10시간 부탁드립니다",
	"{v} 본인 등판 기다립니다 ㅋㅋ", "오늘도 참교육 감사합니다", "구독 누르고 갑니다", "1차선은 추월차선입니다 여러분",
	"블박 화질 무엇? 4K임?", "정속주행 아저씨들 이거 보세요", "보는 내가 다 시원하네", "알고리즘이 여기로 데려왔다",
]

var path: String = "user://progress.json"
var data: Dictionary = {}
var read_only: bool = false
var _save: Node
var _stages: Array = []
var _chapters: Array = []
var _shop: Array = []
var _defaults: Dictionary = {}
var _index: Dictionary = {}


func _init(save_path: String = "user://progress.json", autoload_data: bool = true) -> void:
	path = save_path
	_save = SaveGameScript.new()
	_save.set(&"path", path)
	add_child(_save)
	_load_tables()
	if autoload_data:
		load_progress()


func _load_tables() -> void:
	_stages = (_json("res://data/stages.json") as Dictionary).get("stages", [])
	_chapters = (_json("res://data/chapters.json") as Dictionary).get("chapters", [])
	var shop: Dictionary = _json("res://data/shop.json")
	_shop = shop.get("items", [])
	_defaults = shop.get("defaults", {})
	_index.clear()
	for i: int in _stages.size():
		_index[int((_stages[i] as Dictionary)["id"])] = i


static func _json(p: String) -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else null
	return v if v is Dictionary else {}


# ───────────────────────────── save / load
func load_progress() -> void:
	_save.set(&"path", path)
	data = migrate(_save.call(&"load_progress"))
	read_only = bool(_save.get(&"read_only"))
	changed.emit()


## Field defaults over whatever SaveGame loaded (SaveGame already did the schema / web v0.2 migration).
static func migrate(raw: Dictionary) -> Dictionary:
	var p: Dictionary = raw.duplicate(true)
	var o: Dictionary = {
		"unlocked": maxi(1, int(p.get("unlocked", 1))),
		"stars": _dict(p.get("stars")), "best": _dict(p.get("best")), "album": _dict(p.get("album")),
		"wallet": maxi(0, int(p.get("wallet", 0))), "subs": maxi(0, int(p.get("subs", 0))),
		"owned": (p.get("owned") as Array).duplicate() if p.get("owned") is Array else [],
		"equip": _dict(p.get("equip")), "settings": SETTINGS_DEFAULT.duplicate(),
	}
	if p.get("settings") is Dictionary:
		for k: String in SETTINGS_DEFAULT:
			if (p["settings"] as Dictionary).has(k):
				o["settings"][k] = bool(p["settings"][k])
	for k: Variant in p:
		if not o.has(k) and str(k) != "ver":
			o[k] = p[k]
	return o


static func _dict(v: Variant) -> Dictionary:
	return (v as Dictionary).duplicate(true) if v is Dictionary else {}


func save() -> Error:
	if read_only:
		return ERR_FILE_NO_PERMISSION
	var err: Error = _save.call(&"save_progress", data)
	changed.emit()
	return err


func reset() -> void:
	data = migrate({})
	read_only = false


# ───────────────────────────── stages
func stages() -> Array:
	return _stages


func chapters() -> Array:
	return _chapters


func stage(id: int) -> Dictionary:
	return _stages[_index[id]] if _index.has(id) else {}


func index_of(id: int) -> int:
	return int(_index.get(id, -1))


func unlocked_count() -> int:
	return clampi(int(data.get("unlocked", 1)), 1, maxi(1, _stages.size()))


func is_unlocked(id: int) -> bool:
	var i: int = index_of(id)
	return i >= 0 and i < unlocked_count()


## Web START target: the last unlocked stage (startIdx = unlocked − 1).
func next_stage_id() -> int:
	return int((_stages[unlocked_count() - 1] as Dictionary)["id"]) if not _stages.is_empty() else 1


func stars_of(id: int) -> int:
	return clampi(int(data["stars"].get(str(id), 0)), 0, 3)


func best(id: int) -> Dictionary:
	return {"stars": stars_of(id), "score": int(data["best"].get(str(id), 0))}


func album_entry(id: int) -> Dictionary:
	var a: Variant = data["album"].get(str(id))
	return (a as Dictionary).duplicate() if a is Dictionary else {}


## traffic.js: nMini = stage.minis ?? min(4, 2 + floor(difficulty / 3))
func mini_count(id: int) -> int:
	var st: Dictionary = stage(id)
	if st.get("minis") != null:
		return int(st["minis"])
	return mini(4, 2 + int(floor(float(st.get("difficulty", st.get("id", 1))) / 3.0)))


## main.js stageMissions()
func missions_for(id: int) -> Array:
	var st: Dictionary = stage(id)
	var n: int = mini_count(id)
	return [
		{"id": "clear", "label": "원인 해결 (구조 완료 · 압정 금지)" if st.get("honkOnly") == true else "원인 제거 (참교육 완료)"},
		{"id": "hp60", "label": "내구도 60 이상으로 클리어"},
		{"id": "minis", "label": ("잔챙이 빌런 %d명 전원 참교육" % n) if n > 0 else "잔챙이 빌런 없음 (자동 달성)"},
	]


## rewards.js pick(): LCG over a copy of the list.
static func pick_comments(n: int, seed: int, villain: String) -> PackedStringArray:
	var a: PackedStringArray = COMMENTS.duplicate()
	var out: PackedStringArray = []
	var x: int = seed if seed != 0 else 1
	while out.size() < n and a.size() > 0:
		x = (x * 9301 + 49297) % 233280
		var k: int = int(floor(float(x) / 233280.0 * a.size()))
		out.append(a[k].replace("{v}", villain))
		a.remove_at(k)
	return out


## Stage result → wallet/subs/stars/best/album/unlock, with the real Progress's return keys (meta/README.md):
## facts read: cleared, aborted, hp_end, hp_max, tows, minis_done, minis_total (else missions_done), score, freed, cath,
## cheaters, mini_fines, retry_mul, seed, time_s, photo (user:// path), stats (extra lines).
func record_result(id: int, r: Dictionary) -> Dictionary:
	var st: Dictionary = stage(id)
	var cleared: bool = bool(r.get("cleared", r.has("missions") or r.has("stars"))) and not bool(r.get("aborted", false))
	var out: Dictionary = {"stage_id": id, "cleared": cleared, "payout": 0, "new_stars": 0, "subs_gained": 0, "unlocks": [],
		"wallet": wallet, "subs": subs, "milestone": "", "next_id": _next_id(id), "is_last": index_of(id) == _stages.size() - 1}
	if st.is_empty() or not cleared:
		return out
	var given: Array = r.get("missions_done", []) if r.get("missions_done") is Array else []
	var done: Array = [true,
		int(r.get("hp_end", 0)) >= 60 if r.has("hp_end") else (given.size() > 1 and bool(given[1])),
		int(r.get("minis_done", 0)) >= int(r["minis_total"]) if r.has("minis_total") else (given.size() <= 2 or bool(given[2]))]
	var missions: Array = missions_for(id)
	var stars: int = 0
	for k: int in 3:
		missions[k]["done"] = done[k]
		stars += 1 if done[k] else 0
	var fine: int = int(st["fine"]) if st.get("fine") != null else 30000
	var base: int = int(st["payout"]) if st.get("payout") != null else fine
	var bonus: int = int(r.get("cheaters", 0)) * 10000 + int(r.get("mini_fines", 0))
	var tows: int = int(r.get("tows", 0))
	var retry: float = maxf(0.6, 1.0 - 0.2 * tows) if r.has("tows") else float(r.get("retry_mul", 1.0))
	var item_mul: float = float(loadout()["pay_mul"])
	var payout: int = int(roundf(((float(base) * STAR_MULT[stars] + float(bonus)) * item_mul * retry) / 100.0)) * 100
	var seed: int = int(r["seed"]) if r.has("seed") else int(floor(float(r.get("time_s", 0.0)) * 1000.0)) % 997 + 1
	var freed: int = int(r.get("freed", 0))
	var cath: int = int(r.get("cath", 70))
	var views: int = roundi(float(freed * 38 + cath * 950) * (0.85 + float((seed * 7919) % 100) / 300.0))
	var gain: int = maxi(12, roundi(float(views) * 0.011))
	var vname: String = ScrKit.villain_names(st)
	var score: int = int(r.get("score", 0))
	var wallet0: int = wallet
	var subs0: int = subs
	data["wallet"] = wallet0 + payout
	data["subs"] = subs0 + gain
	var key: String = str(id)
	var prev: Dictionary = album_entry(id)
	var photo: String = str(r["photo"]) if r.get("photo") is String else ""
	if prev.is_empty() or stars >= int(prev.get("stars", 0)):
		data["album"][key] = {"stars": maxi(stars, int(prev.get("stars", 0))), "fine": fine,
			"photo": photo if not photo.is_empty() else prev.get("photo"), "at": int(Time.get_unix_time_from_system() * 1000.0),
			"count": int(prev.get("count", 0)) + 1}
	else:
		data["album"][key]["count"] = int(prev.get("count", 0)) + 1
	var milestone: String = ""
	for m: Array in MILESTONES:
		if subs0 < int(m[0]) and subs >= int(m[0]):
			milestone = str(m[1])
	var prev_stars: int = stars_of(id)
	var prev_best: int = int(data["best"].get(key, 0))
	data["stars"][key] = maxi(prev_stars, stars)
	data["best"][key] = maxi(prev_best, score)
	var u0: int = unlocked_count()
	data["unlocked"] = mini(_stages.size(), maxi(u0, index_of(id) + 2))
	var unlocks: Array = []
	for i: int in range(u0, unlocked_count()):
		unlocks.append(int((_stages[i] as Dictionary)["id"]))
	save()
	var km: float = float(st.get("displayKm", 0.0))
	var t: float = float(r.get("time_s", 0.0))
	var hp_max: int = int(r.get("hp_max", 100))
	var stats: Array = [
		{"label": "해방된 차량", "value": "%s대" % ScrKit.fmt(freed)},
		{"label": "근거", "value": "%skm×4차로×125대/km" % (str(km).trim_suffix(".0"))},
		{"label": "아낀 시간 합계", "value": "%s시간" % ScrKit.fmt(roundf((km / 9.0 - km / 100.0) * 60.0 * freed / 60.0))},
		{"label": "남은 내구도", "value": "%d/%d%s" % [int(r.get("hp_end", 0)), hp_max, (" · 견인 %d회" % tows) if tows > 0 else ""]},
		{"label": "잔챙이 참교육", "value": "%d/%d" % [int(r.get("minis_done", 0)), int(r.get("minis_total", 0))]},
		{"label": "소요 시간", "value": "%d:%02d" % [int(t) / 60, int(t) % 60]},
		{"label": "속시원함 지수", "value": "%d%%" % cath},
	]
	for s2: Variant in r.get("stats", []):
		if s2 is Dictionary:
			stats.append(s2)
	out.merge({"stars": stars, "prev_stars": prev_stars, "new_stars": maxi(0, stars - prev_stars), "missions": missions,
		"score": score, "best_score": int(data["best"][key]), "new_best": score > prev_best, "fine": fine, "base": base, "bonus": bonus,
		"star_mult": STAR_MULT[stars], "item_pay_mul": item_mul, "retry_mul": retry, "pay_mul": item_mul * retry, "payout": payout,
		"views": views, "subs_gained": gain, "comments": Array(pick_comments(3, seed + id * 31, vname)), "milestone": milestone,
		"wallet_before": wallet0, "wallet": wallet, "subs_before": subs0, "subs": subs,
		"violation": str(st.get("violation", "도로교통법 위반")), "villain_name": vname, "card": str(st.get("card", "고지서")),
		"case": ScrKit.case_kind(st.get("card")), "cause": str(st.get("cause", "")), "photo": str(data["album"][key].get("photo", "")) if data["album"][key].get("photo") != null else "",
		"album_count": int(data["album"][key].get("count", 0)), "unlocks": unlocks, "stats": stats, "seed": seed, "tows": tows}, true)
	return out


func _next_id(id: int) -> int:
	var i: int = index_of(id)
	return int((_stages[i + 1] as Dictionary)["id"]) if i >= 0 and i + 1 < _stages.size() else -1


# ───────────────────────────── wallet · subs
var wallet: int:
	get:
		return int(data.get("wallet", 0))
	set(v):
		data["wallet"] = maxi(0, v)

var subs: int:
	get:
		return int(data.get("subs", 0))
	set(v):
		data["subs"] = maxi(0, v)


# ───────────────────────────── shop
func shop_items() -> Array:
	return _shop


func item(id: String) -> Dictionary:
	for it: Dictionary in _shop:
		if str(it["id"]) == id:
			return it
	return {}


func owns(id: String) -> bool:
	var it: Dictionary = item(id)
	if it.is_empty():
		return false
	return int(it.get("price", 0)) <= 0 or (data["owned"] as Array).has(id)


func equipped(cat: String) -> String:
	var want: String = str(data["equip"].get(cat, ""))
	var it: Dictionary = item(want)
	if not it.is_empty() and str(it["cat"]) == cat and owns(want):
		return want
	return str(_defaults.get(cat, ""))


func can_buy(id: String) -> bool:
	var it: Dictionary = item(id)
	return not it.is_empty() and not owns(id) and wallet >= int(it.get("price", 0))


func buy(id: String) -> Dictionary:
	var it: Dictionary = item(id)
	if it.is_empty() or owns(id) or wallet < int(it.get("price", 0)):
		return {"ok": false, "reason": "unknown" if it.is_empty() else ("owned" if owns(id) else "funds"),
			"short": maxi(0, int(it.get("price", 0)) - wallet), "wallet": wallet, "equipped": false}
	wallet -= int(it.get("price", 0))
	(data["owned"] as Array).append(id)
	var slot: bool = SLOT_CATS.has(str(it["cat"]))
	if slot:
		data["equip"][str(it["cat"])] = id
	save()
	return {"ok": true, "reason": "", "short": 0, "wallet": wallet, "equipped": slot}


func equip(id: String) -> bool:
	var it: Dictionary = item(id)
	if it.is_empty() or not owns(id) or not SLOT_CATS.has(str(it["cat"])):
		return false
	data["equip"][str(it["cat"])] = id
	save()
	return true


## Stat modifiers for GameSim (NATIVE_PARITY D8 / 7 G3), same keys as meta/progress.gd loadout(): slot items give
## car/weapon/finish, owned move/passive items merge their shop.json `effect` (pay_mul multiplies).
func loadout() -> Dictionary:
	var car: Dictionary = item(equipped("car"))
	var cs: Dictionary = car.get("stats", {})
	var w: Dictionary = item(equipped("weapon"))
	var fin: String = equipped("finish")
	var out: Dictionary = {
		"car": str(car.get("id", "car_hatch")), "car_kind": str(car.get("kind", "player")),
		"speed": float(cs.get("speed", 1.0)), "armor": int(cs.get("armor", 0)), "hp_max": int(cs.get("hp", 100)),
		"tow": bool(cs.get("tow", false)), "siren": bool(cs.get("siren", false)), "weapon_id": str(w.get("id", "wpn_tack")),
		"weapon": {"id": str(w.get("id", "wpn_tack")), "proj": str(w.get("proj", "tack")), "dmg": float(w.get("dmg", 4)),
			"rate": float(w.get("rate", 7)), "spread": int(w.get("spread", 1)), "slow": float(w.get("slow", 0.0))},
		"finish_id": fin, "finish": fin.trim_prefix("fin_") if not fin.is_empty() else "rocket",
		"pay_mul": 1.0, "airbag": 0, "trot": false, "coffee": false, "rage_start_segs": 0, "jump": false, "jump_cool": 4.0,
		"drone": false, "drone_every": 0.7,
	}
	for it: Dictionary in _shop:
		if SLOT_CATS.has(str(it.get("cat", ""))) or not (it.get("effect") is Dictionary) or not owns(str(it["id"])):
			continue
		for k: Variant in it["effect"]:
			out[k] = float(out[k]) * float(it["effect"][k]) if str(k) == "pay_mul" else it["effect"][k]
	for k: String in ["airbag", "rage_start_segs"]:
		out[k] = int(out[k])
	for k: String in ["jump_cool", "drone_every", "pay_mul"]:
		out[k] = float(out[k])
	return out


# ───────────────────────────── daily villain (native-new, NATIVE_PARITY A21)
## yyyymmdd → Mulberry32 → one of the unlocked stages. Same date = same stage on every launch.
func daily_villain(date_key: int = -1) -> Dictionary:
	if date_key < 0:
		var d: Dictionary = Time.get_date_dict_from_system()
		date_key = int(d["year"]) * 10000 + int(d["month"]) * 100 + int(d["day"])
	var n: int = unlocked_count()
	var r := Mulberry32.new(date_key)
	var id: int = int((_stages[mini(n - 1, int(floor(r.next_float() * n)))] as Dictionary)["id"]) if not _stages.is_empty() else 1
	return {"id": id, "date": date_key}


# ───────────────────────────── settings
func settings() -> Dictionary:
	return (data.get("settings", SETTINGS_DEFAULT) as Dictionary).duplicate()


func get_setting(key: String) -> Variant:
	return data.get("settings", {}).get(key, SETTINGS_DEFAULT.get(key))


func set_setting(key: String, value: Variant) -> bool:
	if not SETTINGS_DEFAULT.has(key):
		return false
	data["settings"][key] = bool(value)
	save()
	settings_changed.emit(key, value)
	return true
