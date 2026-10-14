extends Node
## Progress autoload — the player's meta state and the web's economy rules (NATIVE_PARITY A3, A5-A9, A12, A14, A16,
## A20, A21, D1-D8; contract in native/meta/README.md).
## State (web progress shape + native settings): unlocked, stars{id}, best{id}, wallet, subs, album{id}, owned[], equip{},
## settings{}, daily{}. Stage keys are strings (JSON). Persisted through the SaveGame autoload after every change.
## Formulas: Rewards (meta/rewards.gd = rewards.js) composed like main.js:showResult 549-571. Progress is the single
## evaluator of stars and payout for a result (NATIVE_PARITY 7 G4): the game reports facts, Progress decides.
##
## 가설: ✅ porting rewards.js/main.js result math + config SHOP effects + the SAVE migration into one autoload makes
##       stars, wallet, unlocks, garage effects and the album persist across launches with the web's numbers.

signal changed(what: StringName)   ## &"progress" (after record_result), &"shop" (buy/equip), &"reset"
signal setting_changed(key: String, value: Variant)

const SETTINGS_DEFAULT: Dictionary = {"music": true, "sfx": true, "haptics": true, "battery60": false, "left_hand": false,
	"dev_items": false}  # dev_items: Debug builds only (settings row + app loadout), never read by a release build
const SLOT_CATS: Array[String] = ["car", "weapon", "finish"]
## loadout() keys with their values when no owned item sets them (item.effect in shop.json overrides, pay_mul multiplies).
const LOADOUT_EFFECT_BASE: Dictionary = {"pay_mul": 1.0, "airbag": 0, "trot": false, "coffee": false, "rage_start_segs": 0,
	"jump": false, "jump_cool": 4.0, "drone": false, "drone_every": 0.7}
const PHOTO_MAX_W: int = 480

## The SaveGame node used for disk I/O (default: the autoload). Tests give a private one with its own path.
var store: Node = null
## Overrides for deterministic tests: album 'at' (ms since epoch) and the daily-villain date (yyyymmdd).
var now_ms_override: int = -1
var today_override: int = -1
var last_save_error: Error = OK

var _p: Dictionary = {}
var _stages: Array = []
var _index: Dictionary = {}      # stage id -> index in _stages
var _items: Array = []
var _item: Dictionary = {}       # item id -> item
var _defaults: Dictionary = {}
var _eco: Dictionary = {}
var _tune_hp: Dictionary = {}
var _minis_cfg: Dictionary = {}
var _chapters_meta: Array = []


func _ready() -> void:
	setup(get_node_or_null(^"/root/SaveGame"))


## (Re)binds tables and the store, then loads. Safe to call again (tests).
func setup(p_store: Node) -> void:
	store = p_store
	_load_tables()
	reload()


func reload() -> void:
	var raw: Dictionary = store.call(&"load_progress") if store != null else {}
	_p = _normalize(raw)


## Fresh progress (dev menu / tests). Writes it unless save is false.
func reset(save: bool = true) -> void:
	_p = _normalize({})
	if save:
		_save()
	changed.emit(&"reset")


## Deep copy of the whole state (debug panel, tests).
func state() -> Dictionary:
	return _p.duplicate(true)


# ───────────────────────────── wallet / channel

var wallet: int:
	get:
		return int(_p.get("wallet", 0))

var subs: int:
	get:
		return int(_p.get("subs", 0))


# ───────────────────────────── stages / chapters

func stages() -> Array:
	return _stages


func stage(id: int) -> Dictionary:
	var i: int = stage_index(id)
	return _stages[i] if i >= 0 else {}


func stage_index(id: int) -> int:
	return int(_index.get(id, -1))


## Count of open stages in stage order (web `unlocked`, 1..N).
func unlocked_count() -> int:
	return clampi(int(_p.get("unlocked", 1)), 1, maxi(1, _stages.size()))


func is_unlocked(id: int) -> bool:
	var i: int = stage_index(id)
	return i >= 0 and i < unlocked_count()


## START button target (ui.js:showTitle startIdx = unlocked - 1).
func next_stage_id() -> int:
	return int((_stages[unlocked_count() - 1] as Dictionary).get("id", 1)) if not _stages.is_empty() else 1


func stars_of(id: int) -> int:
	return clampi(int((_p["stars"] as Dictionary).get(str(id), 0)), 0, 3)


func total_stars() -> int:
	var t: int = 0
	for k: Variant in (_p["stars"] as Dictionary):
		t += clampi(int(_p["stars"][k]), 0, 3)
	return t


## {stars, score, cleared, count, photo, fine, at} for a stage (zeros when never cleared).
func best(id: int) -> Dictionary:
	var a: Dictionary = album_entry(id)
	var s: int = stars_of(id)
	return {"stars": s, "score": int((_p["best"] as Dictionary).get(str(id), 0)), "cleared": s > 0,
		"count": int(a.get("count", 0)), "photo": str(a.get("photo", "")), "fine": int(a.get("fine", 0)), "at": int(a.get("at", 0))}


## chapters.json + per-chapter progress (ui.js:groupChapters/chapTabs/renderChapter): {no, name, setting, theme,
## stage_ids, total, cleared, stars, stars_max, locked (first stage locked), complete}.
func chapters() -> Array:
	var meta: Dictionary = {}
	for c: Variant in _chapters_meta:
		if c is Dictionary and not meta.has(int(c.get("no", 0))):
			meta[int(c["no"])] = c
	var groups: Dictionary = {}
	var order: Array[int] = []
	var prev: int = 1
	for i: int in _stages.size():
		var st: Dictionary = _stages[i]
		var ch: int = int(st.get("chapter", 0)) if st.get("chapter") != null else 0
		if ch < 1:
			ch = prev
		prev = ch
		if not groups.has(ch):
			groups[ch] = []
			order.append(ch)
		(groups[ch] as Array).append(i)
	order.sort()
	var out: Array = []
	var unl: int = unlocked_count()
	for no: int in order:
		var idx: Array = groups[no]
		var ids: Array[int] = []
		var cleared: int = 0
		var stars: int = 0
		for i: Variant in idx:
			var id: int = int((_stages[int(i)] as Dictionary).get("id", 0))
			ids.append(id)
			var s: int = stars_of(id)
			stars += s
			cleared += 1 if s > 0 else 0
		var m: Dictionary = meta.get(no, {})
		out.append({"no": no, "name": str(m.get("name", "")), "setting": str(m.get("setting", "")), "theme": str(m.get("theme", "")),
			"stage_ids": ids, "total": ids.size(), "cleared": cleared, "stars": stars, "stars_max": ids.size() * 3,
			"locked": int(idx[0]) >= unl, "complete": ids.size() > 0 and cleared == ids.size()})
	return out


## Three ★ missions (main.js:stageMissions 541-548): [{id, label}]. minis_total = the spawned mini count when known
## (game loaded); -1 uses the planned count (traffic.js:209 stage.minis ?? min(max, base + floor(difficulty/per))).
func missions_for(id: int, minis_total: int = -1) -> Array[Dictionary]:
	var st: Dictionary = stage(id)
	var n: int = minis_total if minis_total >= 0 else planned_minis(st)
	var hp_min: int = int(_eco.get("star2Hp", 60))
	var no_tow: bool = bool(_eco.get("star2NoTow", false))
	var hp_label: String = Rewards.line("main.js:545", "내구도 60 이상으로 클리어")
	if no_tow:
		hp_label = "내구도 %d 이상 · 견인 0회" % hp_min
	elif hp_min != 60:
		hp_label = "내구도 %d 이상으로 클리어" % hp_min
	return [
		{"id": "clear", "label": Rewards.line("main.js:544#1", "원인 해결 (구조 완료 · 압정 금지)") if st.get("honkOnly") == true
			else Rewards.line("main.js:544#2", "원인 제거 (참교육 완료)")},
		{"id": "hp", "label": hp_label},
		{"id": "minis", "label": Rewards.line("main.js:546#1", "잔챙이 빌런 ${n}명 전원 참교육").replace("${n}", str(n)) if n > 0
			else Rewards.line("main.js:546#2", "잔챙이 빌런 없음 (자동 달성)")},
	]


func planned_minis(st: Dictionary) -> int:
	if st.get("minis") != null:
		return int(st["minis"])
	var d: Variant = st.get("difficulty") if st.get("difficulty") != null else st.get("id", 1)
	return mini(int(_minis_cfg.get("max", 4)), int(_minis_cfg.get("base", 2)) + int(floorf(float(d) / float(_minis_cfg.get("perDifficulty", 3)))))


# ───────────────────────────── result → reward

## Applies a stage_finished result (NATIVE_PARITY 7 G1) and saves. Facts read from `result` (aliases in brackets):
##   cleared, aborted, hp_end [hp], hp_max, min_hp, tows [fails, retries], minis_done, minis_total, missions_done
##   (fallback when hp/minis are absent) [missions: [{done}]], cath (else from bumps/boss_time_s/supers/max_combo),
##   freed, cheaters, mini_fines, score, seed (else from time_s), time_s, photo (Image or user:// path), stats (boss lines),
##   retry_mul [pay_mul] (only when no tow count is given).
## Returns everything the reward timeline shows: {stage_id, cleared, stars, prev_stars, new_stars, missions[{id,label,done}],
##   score, best_score, new_best, fine, base, bonus, star_mult, item_pay_mul, retry_mul, replay_mul, pay_mul, payout,
##   views, subs_gained, comments, milestone, wallet_before, wallet, subs_before, subs, violation, villain_name, card,
##   case, cause, stage_name, photo, album_count, unlocks[ids], next_id, is_last, stats[{label,value}], seed, tows}.
## A result that is not cleared (or aborted) changes nothing and returns payout 0. A result without `cleared` (GameSim's
## state().result, built only in phase result) counts as cleared when it has the sim's `missions` / `stars`.
func record_result(id: int, result: Dictionary) -> Dictionary:
	var st: Dictionary = stage(id)
	var cleared: bool = bool(result.get("cleared", result.has("missions") or result.has("stars"))) and not bool(result.get("aborted", false))
	var base_out: Dictionary = {"stage_id": id, "cleared": cleared, "payout": 0, "new_stars": 0, "subs_gained": 0, "unlocks": [],
		"wallet": wallet, "subs": subs, "milestone": "", "next_id": _next_id(id), "is_last": stage_index(id) == _stages.size() - 1}
	if st.is_empty() or not cleared:
		return base_out
	var tows: int = int(result.get("tows", result.get("fails", result.get("retries", 0))))
	var missions: Array[Dictionary] = missions_for(id, int(result.get("minis_total", -1)))
	var done: Array[bool] = _missions_done(result, tows)
	var stars: int = 0
	for k: int in 3:
		missions[k]["done"] = done[k]
		stars += 1 if done[k] else 0
	var prev_stars: int = stars_of(id)
	var has_tows: bool = result.has("tows") or result.has("fails") or result.has("retries")
	var retry: float = Rewards.retry_mul(tows, float(_tune_hp.get("retryPayStep", 0.2)), float(_tune_hp.get("retryPayMin", 0.6))) \
		if has_tows else float(result.get("retry_mul", result.get("pay_mul", 1.0)))
	var replay: float = float(_eco.get("replayMul", 1.0)) if prev_stars > 0 and stars <= prev_stars else 1.0
	var lo: Dictionary = loadout()
	var item_mul: float = float(lo["pay_mul"])
	var pay_mul: float = item_mul * retry * replay   # main.js:567 (4K ? 1.25 : 1) * payRetryMul, then P0#9 replay
	var cath: int = int(result["cath"]) if result.has("cath") else Rewards.catharsis(int(result.get("bumps", 0)),
		float(result.get("boss_time_s", 0.0)), int(result.get("supers", 0)), int(result.get("max_combo", 0)))
	var freed: int = int(result.get("freed", 0))
	var seed: int = int(result["seed"]) if result.has("seed") else Rewards.seed_from_time(float(result.get("time_s", 0.0)), int(_eco.get("seedTimeMod", 997)))
	var reward: Dictionary = Rewards.compute_reward(st, {"stars": stars, "cath": cath, "freed": freed,
		"cheaters": int(result.get("cheaters", 0)), "mini_fines": int(result.get("mini_fines", result.get("miniFines", 0))),
		"pay_mul": pay_mul}, seed, _eco)
	var key: String = str(id)
	var prev_album: Dictionary = (_p["album"] as Dictionary).get(key, {})
	var photo: String = ""
	if prev_album.is_empty() or stars >= int(prev_album.get("stars", 0)):
		photo = _store_photo(id, result.get("photo"))
	var wallet_before: int = wallet
	var subs_before: int = subs
	var milestone: String = Rewards.apply_reward(_p, st, reward, photo, _now_ms(), _eco)
	var idx: int = stage_index(id)
	var old_unl: int = unlocked_count()
	_p["unlocked"] = mini(_stages.size(), maxi(int(_p["unlocked"]), idx + 2))   # main.js:569
	var unlocks: Array[int] = []
	for i: int in range(old_unl, unlocked_count()):
		unlocks.append(int((_stages[i] as Dictionary).get("id", 0)))
	_p["stars"][key] = maxi(prev_stars, stars)                                  # main.js:570
	var score: int = int(result.get("score", 0))
	var prev_best: int = int((_p["best"] as Dictionary).get(key, 0))
	_p["best"][key] = maxi(prev_best, score)                                    # main.js:571
	_save()
	changed.emit(&"progress")
	var stats: Array = Rewards.result_stats(st, freed, int(result.get("hp_end", result.get("hp", 0))),
		int(result.get("hp_max", lo["hp_max"])), tows, int(result.get("minis_done", 0)), int(result.get("minis_total", 0)),
		float(result.get("time_s", 0.0)), cath)
	for s: Variant in result.get("stats", []):
		if s is Dictionary:
			stats.append(s)
	var album_now: Dictionary = (_p["album"] as Dictionary).get(key, {})
	var sm: Array = _eco.get("starMult", [1, 1, 1.5, 2])
	return {
		"stage_id": id, "cleared": true, "stars": stars, "prev_stars": prev_stars, "new_stars": maxi(0, stars - prev_stars),
		"missions": missions, "score": score, "best_score": int(_p["best"][key]), "new_best": score > prev_best,
		"fine": reward["fine"], "base": reward["base"], "bonus": reward["bonus"], "star_mult": float(sm[stars]) if stars < sm.size() else 1.0,
		"item_pay_mul": item_mul, "retry_mul": retry, "replay_mul": replay, "pay_mul": pay_mul, "payout": reward["payout"],
		"views": reward["views"], "subs_gained": reward["subs_gain"], "comments": reward["comments"], "milestone": milestone,
		"wallet_before": wallet_before, "wallet": wallet, "subs_before": subs_before, "subs": subs,
		"violation": reward["violation"], "villain_name": reward["villain_name"], "card": reward["card"],
		"case": case_of(st), "cause": str(st.get("cause", "")), "stage_name": "%s · %s" % [st.get("highway", ""), st.get("direction", "")],
		"photo": str(album_now.get("photo", "")), "album_count": int(album_now.get("count", 0)),
		"unlocks": unlocks, "next_id": _next_id(id), "is_last": idx == _stages.size() - 1, "stats": stats, "seed": seed, "tows": tows,
	}


## Card kind of a stage: "fine" | "crime" | "rescue" | "warn" (cards.json caseOf; ui.js:caseKind).
func case_of(st: Dictionary) -> String:
	var cards: Variant = DB.get_table(&"cards")
	var case_map: Dictionary = (cards as Dictionary).get("caseOf", {}) if cards is Dictionary else {}
	return str(case_map.get(str(st.get("card", "고지서")), "fine"))


func _missions_done(result: Dictionary, tows: int) -> Array[bool]:
	var no_tow: bool = bool(_eco.get("star2NoTow", false))
	var given: Array = []
	if result.get("missions_done") is Array:
		given = result["missions_done"]
	elif result.get("missions") is Array:
		for m: Variant in result["missions"]:
			given.append(bool((m as Dictionary).get("done", false)) if m is Dictionary else bool(m))
	var m1: bool = false
	if result.has("hp_end") or result.has("hp"):
		var hp: int = int(result.get("hp_end", result.get("hp", 0)))
		if str(_eco.get("star2HpSource", "end")) == "min" and result.has("min_hp"):
			hp = int(result["min_hp"])
		m1 = hp >= int(_eco.get("star2Hp", 60))
	elif given.size() > 1:
		m1 = bool(given[1])
	if no_tow and tows > 0:
		m1 = false
	var m2: bool = true
	if result.has("minis_total"):
		m2 = int(result.get("minis_done", 0)) >= int(result["minis_total"])
	elif given.size() > 2:
		m2 = bool(given[2])
	return [true, m1, m2]


func _next_id(id: int) -> int:
	var i: int = stage_index(id)
	return int((_stages[i + 1] as Dictionary).get("id", -1)) if i >= 0 and i + 1 < _stages.size() else -1


# ───────────────────────────── album

func album_entry(id: int) -> Dictionary:
	var a: Variant = (_p["album"] as Dictionary).get(str(id))
	return (a as Dictionary).duplicate() if a is Dictionary else {}


## ui.js:albumGot: an entry with a count/stars/photo, or a cleared stage (pre-album saves).
func album_has(id: int) -> bool:
	var a: Dictionary = album_entry(id)
	return int(a.get("count", 0)) > 0 or int(a.get("stars", 0)) > 0 or not str(a.get("photo", "")).is_empty() or stars_of(id) > 0


func album_count() -> int:
	var n: int = 0
	for st: Variant in _stages:
		n += 1 if album_has(int((st as Dictionary).get("id", 0))) else 0
	return n


## 누적 범칙금 (A14): sum of the collected entries' fine.
func album_fine_total() -> int:
	var t: int = 0
	for k: Variant in (_p["album"] as Dictionary):
		t += int((_p["album"][k] as Dictionary).get("fine", 0))
	return t


func _store_photo(id: int, photo: Variant) -> String:
	if photo is String:
		return photo
	if not (photo is Image) or (photo as Image).is_empty():
		return ""
	var img: Image = (photo as Image).duplicate() as Image
	if img.get_width() > PHOTO_MAX_W:
		img.resize(PHOTO_MAX_W, maxi(1, roundi(float(img.get_height()) * PHOTO_MAX_W / img.get_width())), Image.INTERPOLATE_BILINEAR)
	var dir: String = _save_dir().path_join("album")
	DirAccess.make_dir_recursive_absolute(dir)
	var p: String = dir.path_join("stage_%d.jpg" % id)
	return p if img.save_jpg(p, 0.82) == OK else ""


# ───────────────────────────── shop (main.js:onBuy/onEquip 185-206, config.js SHOP)

## shop.json items (copies) with {owned, equipped, can_buy} flags, in shop order.
func shop_items() -> Array:
	var out: Array = []
	for it: Variant in _items:
		var d: Dictionary = (it as Dictionary).duplicate(true)
		var iid: String = str(d.get("id", ""))
		d["owned"] = owns(iid)
		d["equipped"] = SLOT_CATS.has(str(d.get("cat", ""))) and equipped(str(d["cat"])) == iid
		d["can_buy"] = can_buy(iid)
		out.append(d)
	return out


func item(id: String) -> Dictionary:
	return _item.get(id, {})


## Free items are always owned (main.js:186).
func owns(id: String) -> bool:
	var it: Dictionary = item(id)
	return not it.is_empty() and (int(it.get("price", 0)) == 0 or (_p["owned"] as Array).has(id))


## Equipped item id of a slot category (car/weapon/finish), falling back to the shop default.
func equipped(cat: String) -> String:
	var id: String = str((_p["equip"] as Dictionary).get(cat, ""))
	if owns(id) and str(item(id).get("cat", "")) == cat:
		return id
	return str(_defaults.get(cat, ""))


func can_buy(id: String) -> bool:
	var it: Dictionary = item(id)
	return not it.is_empty() and not owns(id) and wallet >= int(it.get("price", 0))


## {ok, reason: "" | "unknown" | "owned" | "funds", short (₩ missing), wallet, equipped (slot items auto-equip)}.
func buy(id: String) -> Dictionary:
	var it: Dictionary = item(id)
	if it.is_empty():
		return {"ok": false, "reason": "unknown", "short": 0, "wallet": wallet, "equipped": false}
	if owns(id):
		return {"ok": false, "reason": "owned", "short": 0, "wallet": wallet, "equipped": false}
	var price: int = int(it.get("price", 0))
	if wallet < price:
		return {"ok": false, "reason": "funds", "short": price - wallet, "wallet": wallet, "equipped": false}
	_p["wallet"] = wallet - price
	(_p["owned"] as Array).append(id)
	var slot: bool = SLOT_CATS.has(str(it.get("cat", "")))
	if slot:
		_p["equip"][str(it["cat"])] = id
	_save()
	changed.emit(&"shop")
	return {"ok": true, "reason": "", "short": 0, "wallet": wallet, "equipped": slot}


## Slot items only (car/weapon/finish), and only when owned. Move/passive items apply while owned.
func equip(id: String) -> bool:
	var it: Dictionary = item(id)
	if it.is_empty() or not owns(id) or not SLOT_CATS.has(str(it.get("cat", ""))):
		return false
	_p["equip"][str(it["cat"])] = id
	_save()
	changed.emit(&"shop")
	return true


func owned_count() -> int:
	var n: int = 0
	for it: Variant in _items:
		n += 1 if owns(str((it as Dictionary).get("id", ""))) else 0
	return n


## Garage badge (ui.js:updateTitleShop): unowned items the wallet covers.
func affordable_count() -> int:
	var n: int = 0
	for it: Variant in _items:
		n += 1 if can_buy(str((it as Dictionary).get("id", ""))) else 0
	return n


## What the game applies at setupStage (main.js:374-388, NATIVE_PARITY D8/G3). The game reads only this dict:
## {car, car_kind, speed, armor, hp_max, tow, siren, weapon_id, weapon{id, proj, dmg, rate, spread, slow}, finish_id,
##  finish (style: rocket|balloon|heli|ufo), pay_mul, airbag, trot, coffee, rage_start_segs, jump, jump_cool, drone, drone_every}.
func loadout() -> Dictionary:
	var car: Dictionary = item(equipped("car"))
	var wpn: Dictionary = item(equipped("weapon"))
	var fin_id: String = equipped("finish")
	var cs: Dictionary = car.get("stats", {})
	var out: Dictionary = {
		"car": str(car.get("id", "")), "car_kind": str(car.get("kind", "player")),
		"speed": float(cs.get("speed", 1.0)), "armor": int(cs.get("armor", 0)),
		"hp_max": int(cs["hp"]) if cs.get("hp") != null else int(_tune_hp.get("max", 100)),
		"tow": bool(cs.get("tow", false)), "siren": bool(cs.get("siren", false)),
		"weapon_id": str(wpn.get("id", "")),
		"weapon": {"id": str(wpn.get("id", "")), "proj": str(wpn.get("proj", "tack")), "dmg": float(wpn.get("dmg", 4.0)),
			"rate": float(wpn.get("rate", 7.0)), "spread": int(wpn.get("spread", 1)), "slow": float(wpn.get("slow", 0.0))},
		"finish_id": fin_id, "finish": fin_id.trim_prefix("fin_") if not fin_id.is_empty() else "rocket",
	}
	out.merge(LOADOUT_EFFECT_BASE.duplicate())
	for it: Variant in _items:
		var d: Dictionary = it
		if SLOT_CATS.has(str(d.get("cat", ""))) or not (d.get("effect") is Dictionary) or not owns(str(d.get("id", ""))):
			continue
		for k: Variant in (d["effect"] as Dictionary):
			var v: Variant = d["effect"][k]
			out[k] = float(out[k]) * float(v) if k == "pay_mul" else v
	for k: String in ["airbag", "rage_start_segs"]:
		out[k] = int(out[k])
	for k: String in ["jump_cool", "drone_every", "pay_mul"]:
		out[k] = float(out[k])
	return out


# ───────────────────────────── daily villain (native, NATIVE_PARITY A21)

## Today's villain: Mulberry32(yyyymmdd) picks one of the open stages. The pick is stored with its date, so it stays the
## same across launches that day even after more stages unlock. {id, date}.
func daily_villain() -> Dictionary:
	var date: int = today_override if today_override >= 0 else _today()
	var dv: Dictionary = _p.get("daily", {}) if _p.get("daily") is Dictionary else {}
	if int(dv.get("date", 0)) == date and stage_index(int(dv.get("id", -1))) >= 0:
		return {"id": int(dv["id"]), "date": date}
	var rng := Mulberry32.new(date)
	var i: int = mini(unlocked_count() - 1, floori(rng.next_float() * unlocked_count()))
	var id: int = int((_stages[i] as Dictionary).get("id", 1)) if not _stages.is_empty() else 1
	_p["daily"] = {"date": date, "id": id}
	_save()
	return {"id": id, "date": date}


static func _today() -> int:
	var d: Dictionary = Time.get_date_dict_from_system()
	return int(d["year"]) * 10000 + int(d["month"]) * 100 + int(d["day"])


# ───────────────────────────── settings (native, NATIVE_PARITY A20; applied by FI: buses, Haptics, max_fps, HUD side)

func settings() -> Dictionary:
	return (_p["settings"] as Dictionary).duplicate()


func get_setting(key: String) -> Variant:
	return (_p["settings"] as Dictionary).get(key, SETTINGS_DEFAULT.get(key))


func set_setting(key: String, value: Variant) -> bool:
	if not SETTINGS_DEFAULT.has(key) or typeof(value) != typeof(SETTINGS_DEFAULT[key]):
		push_error("Progress: unknown setting or wrong type: %s=%s" % [key, value])
		return false
	if _p["settings"].get(key) == value:
		return true
	_p["settings"][key] = value
	_save()
	setting_changed.emit(key, value)
	return true


# ───────────────────────────── internals

func _load_tables() -> void:
	var st: Variant = DB.get_table(&"stages")
	_stages = ((st as Dictionary).get("stages", []) as Array) if st is Dictionary else []
	_index.clear()
	for i: int in _stages.size():
		_index[int((_stages[i] as Dictionary).get("id", 0))] = i
	var ch: Variant = DB.get_table(&"chapters")
	_chapters_meta = ((ch as Dictionary).get("chapters", []) as Array) if ch is Dictionary else []
	var shop: Variant = DB.get_table(&"shop")
	var sd: Dictionary = shop if shop is Dictionary else {}
	_items = sd.get("items", [])
	_item.clear()
	for it: Variant in _items:
		_item[str((it as Dictionary).get("id", ""))] = it
	_defaults = sd.get("defaults", {})
	_eco = (sd.get("economy", {}) as Dictionary).duplicate(true)
	var cfg: Variant = DB.get_table(&"config")
	var tune: Dictionary = (cfg as Dictionary).get("tune", {}) if cfg is Dictionary else {}
	_tune_hp = tune.get("hp", {})
	var spawn: Dictionary = ((cfg as Dictionary).get("traffic", {}) as Dictionary).get("spawn", {}) if cfg is Dictionary else {}
	_minis_cfg = spawn.get("minis", {})


## Any loaded dict (migrated by SaveGame) -> the typed in-memory shape. Unknown keys are kept (forward compatibility).
func _normalize(raw: Dictionary) -> Dictionary:
	var p: Dictionary = raw.duplicate(true)
	p["unlocked"] = clampi(int(p.get("unlocked", 1)), 1, maxi(1, _stages.size()))
	p["wallet"] = maxi(0, int(p.get("wallet", 0)))
	p["subs"] = maxi(0, int(p.get("subs", 0)))
	for k: String in ["stars", "best"]:
		var src: Dictionary = p.get(k, {}) if p.get(k) is Dictionary else {}
		var d: Dictionary = {}
		for id: Variant in src:
			d[str(id)] = int(src[id])
		p[k] = d
	var album: Dictionary = {}
	var asrc: Dictionary = p.get("album", {}) if p.get("album") is Dictionary else {}
	for id: Variant in asrc:
		var e: Dictionary = asrc[id] if asrc[id] is Dictionary else {}
		album[str(id)] = {"stars": int(e.get("stars", 0)), "fine": int(e.get("fine", 0)),
			"photo": str(e["photo"]) if e.get("photo") is String else "", "at": int(e.get("at", 0)), "count": int(e.get("count", 0))}
	p["album"] = album
	var owned: Array = []
	for id: Variant in (p.get("owned", []) if p.get("owned") is Array else []):
		if not owned.has(str(id)):
			owned.append(str(id))
	p["owned"] = owned
	var equip: Dictionary = _defaults.duplicate()
	if p.get("equip") is Dictionary:
		for k: Variant in p["equip"]:
			equip[str(k)] = str(p["equip"][k])
	p["equip"] = equip
	var settings: Dictionary = SETTINGS_DEFAULT.duplicate()
	if p.get("settings") is Dictionary:
		for k: Variant in p["settings"]:
			if SETTINGS_DEFAULT.has(str(k)) and typeof(p["settings"][k]) == typeof(SETTINGS_DEFAULT[str(k)]):
				settings[str(k)] = p["settings"][k]
	p["settings"] = settings
	if p.get("daily") is Dictionary:
		p["daily"] = {"date": int(p["daily"].get("date", 0)), "id": int(p["daily"].get("id", 0))}
	else:
		p.erase("daily")
	p.erase("schema")
	return p


func _save() -> void:
	if store == null:
		return
	last_save_error = store.call(&"save_progress", _p)
	if last_save_error != OK:
		push_warning("Progress: save failed (%s)" % error_string(last_save_error))


func _save_dir() -> String:
	return str(store.get(&"path")).get_base_dir() if store != null else "user://"


func _now_ms() -> int:
	return now_ms_override if now_ms_override >= 0 else int(Time.get_unix_time_from_system() * 1000.0)
