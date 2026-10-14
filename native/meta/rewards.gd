class_name Rewards
extends RefCounted
## game/js/rewards.js as pure static functions (computeReward, applyReward, villainNames, pick, won, shortNum), plus the
## main.js:showResult pieces that are not in-stage (catharsis, final score, retry pay multiplier, stat lines).
## Numbers follow JS double semantics (Math.round = js_round, toFixed = _to_fixed) so goldens from the frozen web match
## bit for bit (tests/test_rewards_golden.gd). Constants come from shop.json `economy` (defaults = web values); texts
## from lines.json (rewards.js:5 comments, rewards.js:12#n milestone labels).
##
## 가설: ✅ rewards.js has no hidden state: given (stage, r, seed) the reward is a pure function, and applyReward only
##       touches wallet/subs/album, so one static port serves Progress, the result screen and the oracle test.

const LINES_PATH: String = "res://data/lines.json"
const SHOP_PATH: String = "res://data/shop.json"

static var _lines: Dictionary = {}
static var _eco: Dictionary = {}


## Math.round: nearest integer, ties toward +infinity (C round() differs for negative ties).
static func js_round(x: float) -> float:
	var f: float = floorf(x)
	return f + 1.0 if x - f >= 0.5 else f


## shop.json `economy` (cached). Tests may pass their own dict to the functions below instead.
static func economy() -> Dictionary:
	if _eco.is_empty():
		var shop: Variant = DB.load_json(SHOP_PATH)
		if shop is Dictionary:
			_eco = ((shop as Dictionary).get("economy", {}) as Dictionary).duplicate(true)
	return _eco


## Texts of a lines.json inline entry (id = 'file:line[#n]'); [] when missing.
static func line_texts(id: String) -> Array:
	if _lines.is_empty():
		var doc: Variant = DB.load_json(LINES_PATH)
		if doc is Dictionary:
			for e: Variant in (doc as Dictionary).get("inline", []):
				if e is Dictionary:
					_lines[str((e as Dictionary).get("id", ""))] = (e as Dictionary).get("texts", [])
	return _lines.get(id, []) as Array


static func line(id: String, fallback: String) -> String:
	var t: Array = line_texts(id)
	return str(t[0]) if not t.is_empty() else fallback


static func comments_pool() -> Array:
	return line_texts("rewards.js:5")


## MILESTONES [[n, label]...] (rewards.js:11-13): thresholds from economy, labels from lines.json.
static func milestones(eco: Dictionary = {}) -> Array:
	var e: Dictionary = eco if not eco.is_empty() else economy()
	var out: Array = []
	var ns: Array = e.get("milestones", [1000, 10000, 100000, 1000000])
	for k: int in ns.size():
		out.append([int(ns[k]), line("rewards.js:12#%d" % (k + 1), "")])
	return out


## rewards.js:24 villainNames: 'OO 1호 & OO 2호' -> 'OO 2대'.
static func villain_names(villains: Array) -> String:
	var names: PackedStringArray = []
	for v: Variant in villains:
		names.append(str((v as Dictionary).get("name", "")) if v is Dictionary else "")
	if names.size() > 1:
		var all_numbered: bool = true
		for n: String in names:
			if not _ends_numbered(n):
				all_numbered = false
				break
		if all_numbered:
			return "%s %d대" % [names[0].substr(0, names[0].length() - 3), names.size()]
	return " & ".join(names)


static func _ends_numbered(n: String) -> bool:
	# / [1-3]호$/
	if n.length() < 3 or not n.ends_with("호") or n[n.length() - 3] != " ":
		return false
	var d: String = n[n.length() - 2]
	return d == "1" or d == "2" or d == "3"


## rewards.js:17 pick: LCG x = (x*9301 + 49297) % 233280, splice floor(x/233280 * len). seed 0 -> 1 (seed || 1).
static func pick(arr: Array, n: int, seed: int) -> Array:
	var a: Array = arr.duplicate()
	var out: Array = []
	var x: int = seed if seed != 0 else 1
	while out.size() < n and not a.is_empty():
		x = (x * 9301 + 49297) % 233280
		var i: int = floori(float(x) / 233280.0 * a.size())
		out.append(a[i])
		a.remove_at(i)
	return out


## rewards.js:34 computeReward. r: {stars, cath, freed, cheaters, mini_fines, pay_mul}.
## Returns web keys in snake_case: {fine, base, payout, bonus, views, subs_gain, comments, violation, villain_name, stars, card}.
static func compute_reward(stage: Dictionary, r: Dictionary, seed: int, eco: Dictionary = {}) -> Dictionary:
	var e: Dictionary = eco if not eco.is_empty() else economy()
	var fine: float = float(stage["fine"]) if stage.get("fine") != null else float(e.get("defaultFine", 30000))
	var base: float = float(stage["payout"]) if stage.get("payout") != null else fine
	var stars: int = int(r.get("stars", 0))
	var sm: Array = e.get("starMult", [1, 1, 1.5, 2])
	var mult: float = float(sm[stars]) if stars >= 0 and stars < sm.size() else 0.0
	if mult == 0.0:
		mult = 1.0
	var bonus: float = float(r.get("cheaters", 0)) * float(e.get("cheaterBonus", 10000)) + float(r.get("mini_fines", 0))
	var pay_mul: float = float(r.get("pay_mul", 1.0))
	if pay_mul == 0.0:
		pay_mul = 1.0
	var rnd: float = float(e.get("payRound", 100))
	var payout: float = js_round(((base * mult + bonus) * pay_mul) / rnd) * rnd
	var vw: Dictionary = e.get("views", {})
	var m: int = (seed * int(vw.get("seedMul", 7919))) % int(vw.get("seedMod", 100))
	var factor: float = float(vw.get("base", 0.85)) + float(m) / float(vw.get("seedDiv", 300))
	var views: float = js_round((float(r.get("freed", 0)) * float(vw.get("freed", 38)) + float(r.get("cath", 0)) * float(vw.get("cath", 950))) * factor)
	var sb: Dictionary = e.get("subs", {})
	var subs_gain: float = maxf(float(sb.get("min", 12)), js_round(views * float(sb.get("perView", 0.011))))
	var v_name: String = villain_names(stage.get("villains", []) as Array)
	var comments: Array = []
	for c: Variant in pick(comments_pool(), 3, seed + int(stage.get("id", 0)) * int(e.get("commentSeedMul", 31))):
		comments.append(_replace_first(str(c), "{v}", v_name))
	var violation: String = str(stage.get("violation", "")) if stage.get("violation") != null else ""
	var card: String = str(stage.get("card", "")) if stage.get("card") != null else ""
	return {
		"fine": int(fine), "base": int(base), "payout": int(payout), "bonus": int(bonus), "views": int(views),
		"subs_gain": int(subs_gain), "comments": comments,
		"violation": violation if not violation.is_empty() else line("rewards.js:40#1", "도로교통법 위반"),
		"villain_name": v_name, "stars": stars,
		"card": card if not card.is_empty() else line("rewards.js:40#2", "고지서"),
	}


## rewards.js:47 applyReward on a web-shaped progress dict (string stage keys). Returns the milestone label or "".
## The album entry is replaced when the new stars are >= the stored ones (photo kept when the new one is empty),
## otherwise only its count goes up.
static func apply_reward(progress: Dictionary, stage: Dictionary, reward: Dictionary, photo: String, at_ms: int, eco: Dictionary = {}) -> String:
	progress["wallet"] = int(progress.get("wallet", 0)) + int(reward["payout"])
	var before: int = int(progress.get("subs", 0))
	progress["subs"] = before + int(reward["subs_gain"])
	if not (progress.get("album") is Dictionary):
		progress["album"] = {}
	var album: Dictionary = progress["album"]
	var key: String = str(int(stage.get("id", 0)))
	var prev: Dictionary = album.get(key, {}) if album.get(key) is Dictionary else {}
	var stars: int = int(reward["stars"])
	if prev.is_empty() or stars >= int(prev.get("stars", 0)):
		var keep: String = str(prev.get("photo", "")) if prev.get("photo") != null else ""
		album[key] = {"stars": maxi(stars, int(prev.get("stars", 0))), "fine": int(reward["fine"]),
			"photo": photo if not photo.is_empty() else keep, "at": at_ms, "count": int(prev.get("count", 0)) + 1}
	else:
		prev["count"] = int(prev.get("count", 0)) + 1
	var milestone: String = ""
	for ms: Array in milestones(eco):
		if before < int(ms[0]) and int(progress["subs"]) >= int(ms[0]):
			milestone = str(ms[1])
	return milestone


## main.js:552-555 속시원함 지수.
static func catharsis(bumps: int, boss_time: float, supers: int, max_combo: int) -> int:
	var c: float = 70.0 + (12.0 if bumps == 0 else -minf(30.0, bumps * 5.0)) \
		+ (10.0 if boss_time < 14.0 else 4.0 if boss_time < 22.0 else -4.0) \
		+ (6.0 if supers > 0 else 0.0) + minf(8.0, max_combo / 5.0)
	return int(clampf(js_round(c), 12.0, 100.0))


## main.js:563 score = round(G.score + freed*5 + cath*40).
static func final_score(points: float, freed: int, cath: int) -> int:
	return int(js_round(points + freed * 5 + cath * 40))


## main.js:697 payRetryMul = max(retryPayMin, 1 - retryPayStep * fails); 1 without a retry (main.js:395).
static func retry_mul(fails: int, step: float = 0.2, min_mul: float = 0.6) -> float:
	return maxf(min_mul, 1.0 - step * fails) if fails > 0 else 1.0


## main.js:567 seed = floor(G.time*1000) % 997 + 1 (the web's G.time is wall-clock since boot; here the stage time).
static func seed_from_time(time_s: float, mod: int = 997) -> int:
	return int(floorf(time_s * 1000.0)) % mod + 1


## main.js:574-586 stat lines {label, value} for the result screen (boss behaviour stats appended by the caller).
static func result_stats(stage: Dictionary, freed: int, hp: int, hp_max: int, fails: int, minis_done: int, minis_total: int,
		time_s: float, cath: int, lanes: int = 4, density: int = 125) -> Array:
	var km: float = float(stage.get("displayKm", 0.0))
	var saved_min: float = (km / 9.0 - km / 100.0) * 60.0
	var saved_hours: int = int(js_round((saved_min * freed) / 60.0))
	var mm: int = int(floorf(time_s / 60.0))
	var ss: int = int(floorf(fmod(time_s, 60.0)))
	return [
		{"label": "해방된 차량", "value": "%s대" % group_digits(freed)},
		{"label": "근거", "value": "%skm×%d차로×%d대/km" % [js_num(km), lanes, density]},
		{"label": "아낀 시간 합계", "value": "%s시간" % group_digits(saved_hours)},
		{"label": "남은 내구도", "value": "%d/%d%s" % [hp, hp_max, (" · 견인 %d회" % fails) if fails > 0 else ""]},
		{"label": "잔챙이 참교육", "value": "%d/%d" % [minis_done, minis_total]},
		{"label": "소요 시간", "value": "%d:%02d" % [mm, ss]},
		{"label": "속시원함 지수", "value": "%d%%" % cath},
	]


## rewards.js:60 won: '₩' + Math.round(n).toLocaleString('ko-KR').
static func won(n: float) -> String:
	return "₩" + group_digits(int(js_round(n)))


## rewards.js:61 shortNum: >= 1만 -> (n/10000).toFixed(n >= 10만 ? 0 : 1) + '만', else ko-KR grouping.
static func short_num(n: int) -> String:
	if n < 10000:
		return group_digits(n)
	return _to_fixed_div10000(n, 0 if n >= 100000 else 1) + line("rewards.js:61", "만")


## Integer toLocaleString('ko-KR'): comma every 3 digits.
static func group_digits(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


## JS Number -> String for the values the result lines use (integral doubles print without '.0').
static func js_num(x: float) -> String:
	if x == floorf(x) and absf(x) < 1e15:
		return str(int(x))
	return String.num(x)


static func _replace_first(s: String, what: String, with: String) -> String:
	var i: int = s.find(what)
	return s if i < 0 else s.substr(0, i) + with + s.substr(i + what.length())


## (n / 10000).toFixed(d) for integer n >= 0, d in {0, 1}, exactly as JS: toFixed rounds the *double* n/10000, so a
## decimal tie (n % 1000 == 500) goes up or down with that double's rounding error (11500 -> '1.1', 10500 -> '1.1',
## 12500 -> '1.3'). The sign of (double(n/10000) - n/10000) is found exactly with a Dekker split.
static func _to_fixed_div10000(n: int, d: int) -> String:
	var den: int = 10000 if d == 0 else 1000
	var k: int = n / den
	var r: int = n - k * den
	if 2 * r > den:
		k += 1
	elif 2 * r == den:
		if d == 0:
			k += 1   # k + 0.5 is exact in binary: a real tie, toFixed picks the larger
		else:
			var x: float = float(n) / 10000.0
			var c: float = 134217729.0 * x
			var hi: float = c - (c - x)
			var lo: float = x - hi
			var err: float = (hi * 10000.0 - float(n)) + lo * 10000.0
			if err >= 0.0:
				k += 1
	if d == 0:
		return str(k)
	return "%d.%d" % [k / 10, k % 10]
