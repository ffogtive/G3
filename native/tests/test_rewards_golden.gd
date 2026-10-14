extends RefCounted
## T0: Progress.record_result + Rewards == the frozen web (game/js/rewards.js composed like main.js:showResult).
## Golden: res://meta/tools/rewards_golden.json (node native/meta/tools/gen_rewards_golden.mjs): 7 results carried
## through one progress (1-1 ★3 -> 1-1 replay with 4K + 1 tow -> 1-3 duo -> 18 crime card + 3 tows -> 31 warn card ->
## 11 two villains -> 100 last stage), plus won()/shortNum() on 22 numbers.
##
## 가설: ✅ the web reward is a pure function of (stage, stars, cath, freed, cheaters, miniFines, payMult, seed), so the
##       native port reproduces payout, views, subs, comments, milestones, album, unlock, ★ and BEST exactly.

const GOLDEN: String = "res://meta/tools/rewards_golden.json"
const DIR: String = "user://test_meta/golden"
const _SaveGame := preload("res://core/save_game.gd")
const _Progress := preload("res://meta/progress.gd")

var _fails: int = 0


func run() -> int:
	var g: Variant = DB.load_json(GOLDEN)
	_check(g is Dictionary and (g as Dictionary).get("cases", []).size() == 7, "golden loaded (7 cases)")
	if not (g is Dictionary):
		return _fails
	var tune_hp: Dictionary = g["tune_hp"]
	var cfg_hp: Dictionary = (DB.get_table(&"config") as Dictionary)["tune"]["hp"]
	_check(float(tune_hp["retryPayStep"]) == float(cfg_hp["retryPayStep"]) and float(tune_hp["retryPayMin"]) == float(cfg_hp["retryPayMin"]),
		"web TUNE.hp retry pay step/min == config.json tune.hp")

	var sg: Node = _SaveGame.new()
	sg.path = DIR.path_join("progress.json")
	sg.call(&"wipe")
	var pr: Node = _Progress.new()
	pr.call(&"setup", sg)
	var k: int = 0
	for c: Dictionary in g["cases"]:
		k += 1
		var inp: Dictionary = c["in"]
		var id: int = int(inp["stage"])
		var tag: String = "case %d (stage %d)" % [k, id]
		# 4K ownership is an input of the web composition; set it without touching the wallet.
		var owned: Array = pr.get(&"_p")["owned"]
		owned.erase("pas_4k")
		if bool(inp["has4k"]):
			owned.append("pas_4k")
		pr.set(&"now_ms_override", int(c["at"]))
		var wr: Dictionary = c["reward"]
		# Pure Rewards vs rewards.js:computeReward.
		var pure: Dictionary = Rewards.compute_reward(pr.call(&"stage", id), {"stars": int(c["stars"]), "cath": int(inp["cath"]),
			"freed": int(inp["freed"]), "cheaters": int(inp["cheaters"]), "mini_fines": int(inp["mini_fines"]), "pay_mul": float(c["payMult"])}, int(inp["seed"]))
		_check(int(pure["payout"]) == int(wr["payout"]) and int(pure["views"]) == int(wr["views"]) and int(pure["subs_gain"]) == int(wr["subsGain"])
			and int(pure["bonus"]) == int(wr["bonus"]) and int(pure["fine"]) == int(wr["fine"]) and pure["comments"] == wr["comments"]
			and pure["villain_name"] == wr["villainName"] and pure["violation"] == wr["violation"] and pure["card"] == wr["card"],
			"%s Rewards.compute_reward == computeReward (payout %d, views %d, subs +%d)" % [tag, int(wr["payout"]), int(wr["views"]), int(wr["subsGain"])])
		# Full path through Progress.record_result (missions, retry/4K multiplier, applyReward, unlock, ★, BEST).
		var out: Dictionary = pr.call(&"record_result", id, {"cleared": true, "hp_end": inp["hp_end"], "hp_max": 100,
			"minis_done": inp["minis_done"], "minis_total": inp["minis_total"], "cath": inp["cath"], "freed": inp["freed"],
			"cheaters": inp["cheaters"], "mini_fines": inp["mini_fines"], "tows": inp["fails"], "seed": inp["seed"],
			"score": inp["score"], "photo": "user://album/%d.jpg" % id})
		var dones: Array = []
		for m: Dictionary in out["missions"]:
			dones.append(m["done"])
		_check(int(out["stars"]) == int(c["stars"]) and dones == c["missions"], "%s missions %s -> ★%d" % [tag, str(c["missions"]), int(c["stars"])])
		_check(float(out["pay_mul"]) == float(c["payMult"]), "%s pay multiplier %s == web payMult %s" % [tag, out["pay_mul"], c["payMult"]])
		_check(int(out["payout"]) == int(wr["payout"]) and int(out["subs_gained"]) == int(wr["subsGain"]) and int(out["views"]) == int(wr["views"])
			and out["comments"] == wr["comments"], "%s record_result payout/views/subs/comments == web" % tag)
		var ms: String = str(c["milestone"]) if c["milestone"] != null else ""
		_check(str(out["milestone"]) == ms, "%s milestone '%s'" % [tag, ms])
		var wp: Dictionary = c["progress"]
		var st: Dictionary = pr.call(&"state")
		_check(int(st["wallet"]) == int(wp["wallet"]) and int(st["subs"]) == int(wp["subs"]) and int(st["unlocked"]) == int(wp["unlocked"]),
			"%s wallet %d, subs %d, unlocked %d == web" % [tag, int(wp["wallet"]), int(wp["subs"]), int(wp["unlocked"])])
		_check(_int_map(st["stars"]) == _int_map(wp["stars"]) and _int_map(st["best"]) == _int_map(wp["best"]), "%s ★ and BEST maps == web" % tag)
		var album_ok: bool = (st["album"] as Dictionary).size() == (wp["album"] as Dictionary).size()
		for key: Variant in wp["album"]:
			var we: Dictionary = wp["album"][key]
			var ne: Dictionary = (st["album"] as Dictionary).get(str(key), {})
			album_ok = album_ok and int(ne.get("stars", -1)) == int(we["stars"]) and int(ne.get("fine", -1)) == int(we["fine"]) \
				and str(ne.get("photo", "")) == str(we["photo"]) and int(ne.get("at", -1)) == int(we["at"]) and int(ne.get("count", -1)) == int(we["count"])
		_check(album_ok, "%s album entries {stars, fine, photo, at, count} == web" % tag)

	for f: Dictionary in g["format"]:
		var n: int = int(f["n"])
		if Rewards.won(n) != str(f["won"]) or Rewards.short_num(n) != str(f["short"]):
			_check(false, "format %d: won '%s' short '%s' (web '%s' '%s')" % [n, Rewards.won(n), Rewards.short_num(n), f["won"], f["short"]])
	_check(true, "won()/short_num() == web on %d numbers (incl. toFixed ties 10500/11500/12500/99949)" % (g["format"] as Array).size())

	sg.call(&"wipe")
	pr.free()
	sg.free()
	return _fails


static func _int_map(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k: Variant in d:
		out[str(k)] = int(d[k])
	return out


func _check(ok: bool, what: String) -> void:
	if ok:
		print("PASS ", what)
	else:
		_fails += 1
		print("FAIL ", what)
