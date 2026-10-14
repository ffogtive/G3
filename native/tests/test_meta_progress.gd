extends RefCounted
## T0: Progress autoload (native/meta/progress.gd) — unlock chain, ★/BEST/album keeping, buy/equip, loadout, persistence,
## settings, daily villain, chapters, missions, P0 #6/#9 switches, GameSim-style result aliases.
##
## 가설: ✅ Progress reproduces the web rules around a result (unlock = max(unlocked, i+2), ★/BEST keep the max, album
##       count++, slot items auto-equip, free items always owned) and keeps them across a reload from disk.

const DIR: String = "user://test_meta/progress"
const _SaveGame := preload("res://core/save_game.gd")
const _Progress := preload("res://meta/progress.gd")

var _fails: int = 0
var _nodes: Array[Node] = []


func run() -> int:
	var auto: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null(^"Progress")
	_check(auto != null and (auto.call(&"stages") as Array).size() == 100 and (auto.call(&"chapters") as Array).size() == 10,
		"autoload /root/Progress is registered (100 stages, 10 chapters)")

	var sg: Node = _store()
	var pr: Node = _progress(sg)
	pr.set(&"now_ms_override", 1760000000000)

	# Fresh progress.
	_check(pr.call(&"unlocked_count") == 1 and pr.call(&"next_stage_id") == 1 and pr.call(&"is_unlocked", 1) and not pr.call(&"is_unlocked", 2)
		and pr.wallet == 0 and pr.subs == 0, "fresh: only 1-1 open, START -> 1-1, ₩0, 0 subs")
	var lo: Dictionary = pr.call(&"loadout")
	_check(lo["car"] == "car_hatch" and lo["car_kind"] == "player" and lo["hp_max"] == 100 and lo["speed"] == 1.0 and lo["weapon_id"] == "wpn_tack"
		and lo["weapon"]["dmg"] == 4.0 and lo["weapon"]["rate"] == 7.0 and lo["finish"] == "rocket" and lo["pay_mul"] == 1.0
		and not lo["jump"] and not lo["drone"] and lo["airbag"] == 0 and lo["rage_start_segs"] == 0, "fresh loadout = web defaults (hatch, tack 4x7/s, rocket)")
	var m1: Array = pr.call(&"missions_for", 1)
	_check(m1.size() == 3 and m1[0]["label"] == "원인 제거 (참교육 완료)" and m1[1]["label"] == "내구도 60 이상으로 클리어"
		and m1[2]["label"] == "잔챙이 빌런 2명 전원 참교육" and m1[0]["id"] == "clear", "missions_for(1): web labels, planned 2 minis")
	_check((pr.call(&"missions_for", 36) as Array)[0]["label"] == "원인 해결 (구조 완료 · 압정 금지)"
		and (pr.call(&"missions_for", 1, 0) as Array)[2]["label"] == "잔챙이 빌런 없음 (자동 달성)", "honkOnly mission 1 label; 0 spawned minis -> auto")
	var chs: Array = pr.call(&"chapters")
	_check(chs.size() == 10 and not chs[0]["locked"] and chs[1]["locked"] and chs[0]["total"] == 10 and chs[0]["name"] == "1차로의 법칙",
		"chapters: CH1 open, CH2 locked, 10 stages each")

	# Unlock chain 1 -> 2 -> 3 (main.js:569), only on clear.
	var r1: Dictionary = pr.call(&"record_result", 1, _clear(80, 2, 2, 1, 100000))
	_check(r1["unlocks"] == [2] and pr.call(&"is_unlocked", 2) and not pr.call(&"is_unlocked", 3) and r1["next_id"] == 2 and r1["new_stars"] == 3
		and int(r1["payout"]) == 190000 and pr.wallet == 190000, "clear 1-1 ★3 -> unlocks [2] only, ₩190,000 (D3 table)")
	var r2: Dictionary = pr.call(&"record_result", 2, _clear(80, 3, 3, 2, 150000))
	_check(r2["unlocks"] == [3] and pr.call(&"is_unlocked", 3) and not pr.call(&"is_unlocked", 4) and pr.call(&"next_stage_id") == 3,
		"clear 1-2 -> unlocks [3], START -> 1-3")
	var w: int = pr.wallet
	var fail: Dictionary = pr.call(&"record_result", 3, {"cleared": false, "hp_end": 0, "tows": 2})
	var abort: Dictionary = pr.call(&"record_result", 3, {"cleared": true, "aborted": true})
	_check(int(fail["payout"]) == 0 and int(abort["payout"]) == 0 and pr.wallet == w and not pr.call(&"is_unlocked", 4) and pr.call(&"stars_of", 3) == 0,
		"not cleared / aborted -> no pay, no unlock, no ★")
	var rep: Dictionary = pr.call(&"record_result", 1, _clear(10, 0, 2, 0, 0))
	_check(rep["unlocks"] == [] and rep["stars"] == 1 and rep["new_stars"] == 0 and pr.call(&"stars_of", 1) == 3 and int(pr.call(&"best", 1)["count"]) == 2
		and int(pr.call(&"album_entry", 1)["stars"]) == 3, "replay 1-1 with ★1: ★ stays 3, album count 2, nothing unlocks")
	_check(pr.call(&"total_stars") == 6 and pr.call(&"album_count") == 2 and pr.call(&"album_fine_total") == 40000 + int(pr.call(&"stage", 2)["fine"]),
		"totals: ★6, album 2/100, 누적 범칙금 = Σ fine")

	# Shop: funds check, auto-equip, free items, passive effects, move items cannot be equipped.
	var poor: Dictionary = pr.call(&"buy", "car_patrol")
	_check(not poor["ok"] and poor["reason"] == "funds" and int(poor["short"]) == 900000 - pr.wallet and not pr.call(&"can_buy", "car_patrol"),
		"buy without funds -> reason funds, short = price - wallet")
	w = pr.wallet
	var bp: Dictionary = pr.call(&"buy", "car_porter")
	lo = pr.call(&"loadout")
	_check(bp["ok"] and bp["equipped"] and pr.wallet == w - 180000 and pr.call(&"owns", "car_porter") and pr.call(&"equipped", "car") == "car_porter"
		and lo["hp_max"] == 130 and lo["speed"] == 0.93 and lo["car_kind"] == "playerPorter", "buy 1톤 포터: -₩180,000, auto-equipped, loadout HP 130 / speed 0.93")
	_check((pr.call(&"buy", "car_porter") as Dictionary)["reason"] == "owned" and (pr.call(&"buy", "nope") as Dictionary)["reason"] == "unknown",
		"double buy -> owned, unknown id -> unknown")
	_check(pr.call(&"owns", "car_hatch") and pr.call(&"equip", "car_hatch") and pr.call(&"equipped", "car") == "car_hatch" and not pr.call(&"equip", "car_wrecker"),
		"free car always owned and equippable; unowned car cannot be equipped")
	pr.call(&"equip", "car_porter")
	var b4k: Dictionary = pr.call(&"buy", "pas_4k")
	lo = pr.call(&"loadout")
	_check(b4k["ok"] and not b4k["equipped"] and lo["pay_mul"] == 1.25 and not pr.call(&"equip", "pas_4k"), "passive 4K: owned = active (pay_mul 1.25), not equippable")
	var items: Array = pr.call(&"shop_items")
	var flags_ok: bool = items.size() == 18
	for it: Dictionary in items:
		if it["id"] == "car_porter":
			flags_ok = flags_ok and it["owned"] and it["equipped"]
		elif it["id"] == "car_hatch":
			flags_ok = flags_ok and it["owned"] and not it["equipped"]
	_check(flags_ok and pr.call(&"owned_count") == 5, "shop_items: 18 with owned/equipped flags; owned 5 (3 free + porter + 4K)")

	# 4K now applies to the payout: 1-3 ★3 base 40,000 ×2 + 0 -> ×1.25 -> ₩100,000.
	var r3: Dictionary = pr.call(&"record_result", 3, _clear(90, 3, 3, 0, 0))
	_check(int(r3["payout"]) == 100000 and float(r3["item_pay_mul"]) == 1.25 and r3["villain_name"] == "수다 듀오 2대", "owned 4K: 1-3 ★3 pays ₩100,000; duo name '수다 듀오 2대'")

	# Settings.
	_check(pr.call(&"get_setting", "music") == true and pr.call(&"get_setting", "battery60") == false, "settings defaults (music on, battery60 off)")
	_check(pr.call(&"set_setting", "battery60", true) and pr.call(&"set_setting", "left_hand", true) and not pr.call(&"set_setting", "music", 1)
		and not pr.call(&"set_setting", "bogus", true), "set_setting: known bool keys only")

	# Daily villain: same date -> same open stage, stored, stays after more unlocks.
	pr.set(&"today_override", 20261014)
	var dv: Dictionary = pr.call(&"daily_villain")
	_check(pr.call(&"is_unlocked", int(dv["id"])) and pr.call(&"daily_villain") == dv and dv["date"] == 20261014, "daily villain %d: open stage, same twice" % int(dv["id"]))

	# Persistence: a new Progress on the same file sees everything.
	var snap: Dictionary = pr.call(&"state")
	var pr2: Node = _progress(sg)
	pr2.set(&"today_override", 20261014)
	_check(pr2.call(&"state") == snap and pr2.call(&"get_setting", "left_hand") == true and pr2.call(&"equipped", "car") == "car_porter"
		and pr2.wallet == pr.wallet and pr2.call(&"daily_villain") == dv, "reload from disk: state, settings, equip, wallet, daily villain identical")
	var other_day: Array[int] = []
	var all_open: bool = true
	for d: int in [20261015, 20261016, 20261017, 20261018, 20261019, 20261020]:
		pr2.set(&"today_override", d)
		var x: int = int(pr2.call(&"daily_villain")["id"])
		other_day.append(x)
		all_open = all_open and pr2.call(&"is_unlocked", x)
	_check(all_open, "daily villain over 6 days %s: always an open stage" % str(other_day))

	# P0 switches (shop.json economy; defaults = web). star2NoTow, star2HpSource=min, replayMul.
	var eco: Dictionary = pr2.get(&"_eco")
	var saved_eco: Dictionary = eco.duplicate(true)
	var t_web: Dictionary = pr2.call(&"record_result", 4, _clear_tows(70, 50, 2))
	eco["star2NoTow"] = true
	_check(t_web["stars"] == 3 and (pr2.call(&"missions_for", 4) as Array)[1]["label"] == "내구도 60 이상 · 견인 0회", "web: ★2 with tows; P0#6 label when switched")
	var t_honest: Dictionary = pr2.call(&"record_result", 5, _clear_tows(70, 50, 1))
	eco["star2NoTow"] = false
	eco["star2HpSource"] = "min"
	var t_min: Dictionary = pr2.call(&"record_result", 6, _clear_tows(70, 50, 0))
	_check(t_honest["stars"] == 2 and t_min["stars"] == 2, "P0#6: star2NoTow fails ★2 on a tow; star2HpSource=min uses min_hp")
	eco["star2HpSource"] = "end"
	var base_rep: Dictionary = pr2.call(&"record_result", 3, _clear(90, 3, 3, 0, 0))
	eco["replayMul"] = 0.25
	var cut_rep: Dictionary = pr2.call(&"record_result", 3, _clear(90, 3, 3, 0, 0))
	var new_star: Dictionary = pr2.call(&"record_result", 7, _clear(90, 3, 3, 0, 0))
	_check(int(base_rep["payout"]) == 100000 and int(cut_rep["payout"]) == 25000 and float(new_star["replay_mul"]) == 1.0,
		"P0#9 replayMul 0.25: replay without new ★ pays 25%, first clear pays 100%")
	eco.merge(saved_eco, true)

	# GameSim-style result (sim/game_sim.gd _make_result keys): hp, tows, missions[{done}], no seed (from time_s).
	var gs: Dictionary = pr2.call(&"record_result", 8, {"cleared": true, "hp": 65, "hp_max": 100, "min_hp": 40, "tows": 0, "pay_mul": 1.0,
		"missions": [{"done": true}, {"done": true}, {"done": false}], "minis_done": 1, "minis_total": 3, "freed": 900, "cath": 70,
		"cheaters": 0, "score": 9000, "time_s": 48.25, "stats": [{"label": "깜빡이", "value": "12회"}]})
	_check(gs["stars"] == 2 and int(gs["seed"]) == 48250 % 997 + 1 and (gs["stats"] as Array).size() == 8 and gs["stats"][3]["value"] == "65/100"
		and gs["stats"][5]["value"] == "0:48" and gs["stats"][7]["label"] == "깜빡이", "GameSim-style result: aliases, seed from time_s, 7 web stat lines + boss stats")

	# Image photo -> user:// jpg, kept only when the entry is replaced.
	var img := Image.create(960, 540, false, Image.FORMAT_RGB8)
	img.fill(Color(0.2, 0.4, 0.6))
	var ph: Dictionary = pr2.call(&"record_result", 9, {"cleared": true, "hp_end": 90, "minis_done": 0, "minis_total": 0, "photo": img, "seed": 5})
	var pth: String = str(ph["photo"])
	var saved_img: Image = Image.load_from_file(pth) if FileAccess.file_exists(pth) else null
	_check(saved_img != null and saved_img.get_width() == _Progress.PHOTO_MAX_W, "photo Image saved as %s (%d px wide)" % [pth, saved_img.get_width() if saved_img else 0])
	var low: Dictionary = pr2.call(&"record_result", 9, {"cleared": true, "hp_end": 10, "minis_done": 0, "minis_total": 0, "photo": "user://other.jpg", "seed": 5})
	_check(str(low["photo"]) == pth and low["album_count"] == 2, "lower ★ replay keeps the old photo, count 2")

	_plays()

	if FileAccess.file_exists(pth):
		DirAccess.remove_absolute(pth)
	sg.call(&"wipe")
	for n: Node in _nodes:
		n.free()
	return _fails


## S1 (r3): plays{id} run index — begin_play returns the count before the increment, saves, survives a reload;
## a save without plays (every device save before r3, web saves) reads 0 everywhere; bad values read 0; next_play
## steps over seed_skip but never over run 0; reset clears it; app runs get Mulberry32.run_seed(id, n).
func _plays() -> void:
	var sg: Node = _store("plays.json")
	# A device save from before r3 (schema 1, no plays key) must load unchanged and read plays 0.
	var old: Dictionary = {"schema": 1, "unlocked": 3, "stars": {"1": 3, "2": 1}, "best": {"1": 5000}, "wallet": 77000, "subs": 12,
		"album": {}, "owned": ["car_porter"], "equip": {"car": "car_porter"}, "settings": {"music": false}}
	sg.call(&"save_progress", old)
	var pr: Node = _progress(sg)
	_check(pr.call(&"plays", 1) == 0 and pr.call(&"next_play", 1) == 0 and pr.call(&"plays", 99) == 0
		and pr.call(&"unlocked_count") == 3 and pr.wallet == 77000 and pr.call(&"stars_of", 1) == 3 and pr.call(&"equipped", "car") == "car_porter"
		and pr.call(&"get_setting", "music") == false, "pre-r3 save (no plays): loads unchanged, plays = 0 → first run is n = 0 (old seed)")
	_check(pr.call(&"begin_play", 1) == 0 and pr.call(&"begin_play", 1) == 1 and pr.call(&"begin_play", 1) == 2 and pr.call(&"plays", 1) == 3
		and pr.call(&"plays", 2) == 0 and pr.call(&"begin_play", 2) == 0, "begin_play returns 0, 1, 2 (count before ++), per stage")
	var disk: Dictionary = sg.call(&"load_progress")
	_check(disk.get("plays") is Dictionary and int(disk["plays"].get("1", -1)) == 3 and int(disk["plays"].get("2", -1)) == 1
		and int(disk.get("schema", 0)) == 1 and int(disk.get("wallet", 0)) == 77000, "plays saved as {\"1\": 3, \"2\": 1} in the same schema-1 file")
	var pr2: Node = _progress(sg)
	_check(pr2.call(&"plays", 1) == 3 and pr2.call(&"next_play", 1) == 3 and pr2.call(&"state") == pr.call(&"state"),
		"reload from disk: plays{1} = 3, state identical")
	pr2.set(&"seed_skip", {1: [3, 4, 6], 2: [0]})
	_check(pr2.call(&"next_play", 1) == 5 and pr2.call(&"begin_play", 1) == 5 and pr2.call(&"begin_play", 1) == 7 and pr2.call(&"plays", 1) == 8,
		"seed_skip {1: [3, 4, 6]}: next_play 5, begin_play 5 then 7")
	# r3 final (code review): the old check asked next_play(3) with no skip list for 1-3 — it could not fail. Now 1-3 has
	# plays 0 and lists run 0 itself: run 0 (the golden seed) is still the first run, then the list is honoured.
	pr2.set(&"seed_skip", {3: [0, 1]})
	_check(pr2.call(&"plays", 3) == 0 and pr2.call(&"next_play", 3) == 0 and pr2.call(&"begin_play", 3) == 0 and pr2.call(&"next_play", 3) == 2,
		"run 0 is never skipped: seed_skip {3: [0, 1]} with plays 0 → next_play 0, begin_play 0, then next_play 2")
	pr2.set(&"seed_skip", {2: [1]})
	_check(pr2.call(&"begin_play", 2) == 2, "seed_skip {2: [1]}: run 1 of 1-2 → 2")
	sg.call(&"save_progress", {"schema": 1, "unlocked": 1, "plays": {"1": -4, "2": "x", "3": 2.0, "4": 5}})
	var pr3: Node = _progress(sg)
	_check(pr3.call(&"plays", 1) == 0 and pr3.call(&"plays", 2) == 0 and pr3.call(&"plays", 3) == 2 and pr3.call(&"plays", 4) == 5,
		"bad plays values (negative, string) read 0; 2.0 (JSON number) reads 2")
	pr3.call(&"reset")
	_check(pr3.call(&"plays", 4) == 0 and (pr3.call(&"state") as Dictionary).get("plays") == {}, "reset clears plays")
	# Web progress (schema 0) migrates with plays 0.
	sg.call(&"wipe")
	var web := FileAccess.open(sg.path, FileAccess.WRITE)
	web.store_string(JSON.stringify({"ver": 3, "unlocked": 2, "stars": {"1": 2}, "best": {}, "wallet": 1000, "subs": 0, "album": {}}))
	web.close()
	var pr4: Node = _progress(sg)
	_check(pr4.call(&"plays", 1) == 0 and pr4.call(&"unlocked_count") == 2 and pr4.call(&"stars_of", 1) == 2, "web save (schema 0) migrates, plays 0")
	_check(pr4.call(&"begin_play", 1) == 0 and Mulberry32.run_seed(1, 0) == 1007 and Mulberry32.run_seed(1, pr4.call(&"begin_play", 1)) != 1007,
		"run 0 → seed 1007 (unchanged first run); run 1 → a different seed")
	sg.call(&"wipe")


func _store(file: String = "progress.json") -> Node:
	var sg: Node = _SaveGame.new()
	sg.path = DIR.path_join(file)
	sg.call(&"wipe")
	_nodes.append(sg)
	return sg


func _progress(sg: Node) -> Node:
	var pr: Node = _Progress.new()
	pr.call(&"setup", sg)
	_nodes.append(pr)
	return pr


static func _clear(hp: int, minis_done: int, minis_total: int, cheaters: int, mini_fines: int) -> Dictionary:
	return {"cleared": true, "hp_end": hp, "hp_max": 100, "minis_done": minis_done, "minis_total": minis_total, "tows": 0, "cath": 88,
		"freed": 1200, "cheaters": cheaters, "mini_fines": mini_fines, "seed": 1, "score": 30000, "time_s": 75.0}


static func _clear_tows(hp: int, min_hp: int, tows: int) -> Dictionary:
	var r: Dictionary = _clear(hp, 0, 0, 0, 0)
	r["min_hp"] = min_hp
	r["tows"] = tows
	return r


func _check(ok: bool, what: String) -> void:
	if ok:
		print("PASS ", what)
	else:
		_fails += 1
		print("FAIL ", what)
