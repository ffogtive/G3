extends RefCounted
## docs/SKILLS.md §7-1 e2e gate: the autopilot's skill policy plays 1-1 on GameSim with a loadout (jump + drone, the
## finish rotating rocket / balloon / heli / ufo) for 5 seeds × {native traffic, GDScript fallback = the iPhone build}.
##   가설: with skills.hpMul 1.25 the boss fight stays 10–20 s of real time while the skills (t3 / t5 at least once)
##         and items fire, every cast keeps its real-time budget (t1 0.5, t3 1.2, t5 2.5, items 1.0 s; a cast that overlaps
##         the other channel is exempt: the other cast's hitstop / slow-mo stretches its sim-time hits) and the finish
##         releases the jam at done + releaseDelay.
## r3 combat (C1 압정 콤보 + C2 generic window / HP-fraction damage / hpMul 1.7 + C3 t1 reach), 1-1..1-4 × 5 seeds ×
## {native, fallback} × three players, timed from the front lock to the kill (real s):
##   pilot  = Autopilot with skills (rage in windows, items)                        gate 10–16 s
##   tacks  = the same driver, but no rage / items once locked (압정 + combo only)   gate 13–21 s
##   sloppy = tacks with a lazy thumb (압정 held 1.1 s of every 1.6 s = 69 %)        gate ≤ 26 s
## The window is the median of the 5 seeds (the prototype's numbers were medians; its own 1-1 / 1-2 pilot runs went
## 7.7–10.3 s); every single run stays ≤ the upper bound and ≥ FLOOR_S (a fight that is over before it starts).
## Plus per run: ×20 타이어 저격 ≥ 1, ×10 따다닥 2–8, the first ×20 ≤ FIRST_C20_MAX s after the lock, and 0
## skill_denied{target} in the boss phase. These C2 windows are measured with the 병목 plug OFF (options.neck = false): they
## tune the fight after the front lock, and with the plug the pre-lock 압정 phase (tacks and combos already hit the villain
## from boss entry) eats into lock → kill.
## r3 integration — the shipped game (plug ON by default, neck.json default.enabled): pilot + tacks × 5 seeds × both paths,
## the same per-run gates (lock → kill ≥ FLOOR_S and ≤ the upper bound, ×20 ≥ 1, ×10 2–8, 0 denied{target}, finisher), and
## the boss segment (boss entry → kill, the time the player is fighting) median within NECK_DELTA of the plug-off median:
## the plug moves damage before the lock and may add one valve wait (1-3 quiet 3 s + react), nothing more.
## 1-5..1-10 (generic window, global hpMul, no gate of their own yet): the pilot on seed 1007 × both paths in the shipped game
## reaches the result card with a lock → kill ≤ REST_MAX_S and 0 skill_denied{target}.
##   가설: ✅ (r3design/combat/combo_proto.gd, hpMul 1.7) the milestones + the generic window bring 압정-only fights from
##         41–60 s (1-2..1-4) to 14–21 s on both traffic paths; ❓ the first ×20 lands 4.7–6.9 s after the lock.
##   가설(r3 통합): ✅ with the plug on, lock → kill drops (1-1 pilot median 10.9 → 6.6 s) but boss → kill stays (13.6 → 12.5 s);
##         ~~raise 1-1 skillHpMul for the 10 s lock → kill floor~~ → rejected: it would lengthen the boss segment the
##         player actually feels (피드백 2 '너무 오래 걸린다').
## Runs in the e2e suite: godot47 --headless --path native -s res://tests/run_tests.gd -- --suite=e2e

const SUITE := "e2e"
const _DB := preload("res://core/db.gd")
const SEEDS: Array[int] = [1007, 3, 11, 42, 77]
const STAGES: Array[int] = [1, 2, 3, 4]
const FINISHES: Array[String] = ["rocket", "balloon", "heli", "ufo"]
const POLICIES: Array[String] = ["pilot", "tacks", "sloppy"]
const STAGES_REST: Array[int] = [5, 6, 7, 8, 9, 10]
const REST_MAX_S: float = 40.0
const LIMIT_S: float = 240.0
## Real-time budget per cast id. t1_wave: dur 0.5 or its farthest hit delay + 0.15 (60 m → 0.5 + 0.15 s, r3 C3).
const BUDGET: Dictionary = {"t1_horn": 0.5, "t1_wave": 0.65, "t3_carpet": 1.2, "t5_finish": 2.5, "mv_jump": 1.0, "mv_drone": 1.0, "mv_tow": 1.0,
	"c5_double": 0.3, "c10_burst": 0.4, "c20_snipe": 0.5}
## Lock → kill real s gates per policy [min, max] (r3 C2 acceptance) on the 5-seed median; max also per run.
const GATE: Dictionary = {"pilot": [10.0, 16.0], "tacks": [13.0, 21.0], "sloppy": [0.0, 26.0]}
const FLOOR_S: float = 6.0
## The combo counts before the lock too (C1: boss phase 잠금 전후), so the first ×20 lands earlier than the prototype's
## 4.7–6.9 s (it counted from the lock): the gate only says the big one comes early in every fight.
const FIRST_C20_MAX: float = 8.0
## Shipped game (plug on) boss → kill median − plug-off median, s: [min, max] (r3 integration).
const NECK_DELTA: Array[float] = [-2.5, 4.0]
const NECK_POLICIES: Array[String] = ["pilot", "tacks"]

var _fails: int = 0


## GameSim with a player policy on top of the autopilot: no fight skills (tacks / sloppy) and the lazy thumb (sloppy).
class PolicySim extends GameSim:
	var no_fight_skills: bool = false
	var duty: bool = false
	var duty_held: bool = true

	func input(cmd: StringName, value: Variant = null) -> void:
		var locked: bool = phase == &"boss" and front_locked
		if no_fight_skills and locked and cmd in [&"rage", &"item1", &"item2"]:
			return
		if duty and cmd == &"fire" and locked:
			value = bool(value) and duty_held
		super.input(cmd, value)


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " e2e_skills: " + what)
	if not ok:
		_fails += 1


func _pct(a: Array, q: float) -> float:
	if a.is_empty():
		return NAN
	var b: Array = a.duplicate()
	b.sort()
	return float(b[clampi(int(floor(q * (b.size() - 1))), 0, b.size() - 1)])


func run() -> int:
	var stages_db: Variant = _DB.load_json("res://data/stages.json")
	var skc: Dictionary = (_DB.load_traffic_tables()["config"] as Dictionary).get("skills", {})
	var fc: Dictionary = skc.get("finish", {})
	var tiers: Dictionary = {}
	var summary: Array[String] = []
	var backends: Array[bool] = [true]
	if TrafficBridge.native_available():
		backends.push_front(false)
	else:
		print("SKIP e2e_skills: C++ Traffic not loaded (native path)")
	var off_boss: Dictionary = {}  # "sid:fb:pol" -> plug-off boss → kill median
	for sid: int in STAGES:
		var stage: Dictionary = _DB.find_stage(stages_db, sid)
		for fb: bool in backends:
			for pol: String in POLICIES:
				var fights: Array = []
				var bosses: Array = []
				var firsts: Array = []
				var c10s: Array = []
				var c20s: Array = []
				var c5s: Array = []
				for i: int in SEEDS.size():
					var r: Dictionary = _one(stage, fb, pol, SEEDS[i], FINISHES[(i + sid + (1 if fb else 0)) % FINISHES.size()], fc, skc, tiers,
						-1.0, {"neck": false})
					bosses.append(float(r["boss"]))
					fights.append(float(r["fight"]))
					if float(r["first_c20"]) >= 0.0:
						firsts.append(float(r["first_c20"]))
					c5s.append(int(r["c5"]))
					c10s.append(int(r["c10"]))
					c20s.append(int(r["c20"]))
				var g: Array = GATE[pol]
				var med: float = _pct(fights, 0.5)
				_check(med >= float(g[0]) and med <= float(g[1]), "1-%d %s %s: lock → kill median %.1f s in %.0f–%.0f s (%s)" % [sid,
					"fallback" if fb else "native", pol, med, float(g[0]), float(g[1]), ", ".join(PackedStringArray(fights.map(func(x: float) -> String: return "%.1f" % x)))])
				var line: String = "1-%d %s %-6s lock→kill med %5.1f [%5.1f..%5.1f]  c5 %s c10 %s c20 %s  firstC20 med %4.1f [%4.1f..%4.1f]" % [sid,
					"FB " if fb else "CPP", pol, _pct(fights, 0.5), _pct(fights, 0.0), _pct(fights, 1.0), str(c5s), str(c10s), str(c20s),
					_pct(firsts, 0.5), _pct(firsts, 0.0), _pct(firsts, 1.0)]
				summary.append(line)
				print("INFO e2e_skills: " + line)
				off_boss["%d:%s:%s" % [sid, fb, pol]] = _pct(bosses, 0.5)
	# r3 integration: the shipped game (plug on by default) — per-run gates + the boss segment vs plug off
	for sid: int in STAGES:
		var stage2: Dictionary = _DB.find_stage(stages_db, sid)
		for fb: bool in backends:
			for pol: String in NECK_POLICIES:
				var nb: Array = []
				var nf: Array = []
				for i: int in SEEDS.size():
					var nr: Dictionary = _one(stage2, fb, pol, SEEDS[i], FINISHES[(i + sid + (1 if fb else 0)) % FINISHES.size()], fc, skc, tiers,
						-1.0, {}, true)
					nb.append(float(nr["boss"]))
					nf.append(float(nr["fight"]))
				var off_med: float = float(off_boss.get("%d:%s:%s" % [sid, fb, pol], NAN))
				var on_med: float = _pct(nb, 0.5)
				var d: float = on_med - off_med
				_check(is_finite(d) and d >= NECK_DELTA[0] and d <= NECK_DELTA[1],
					"1-%d %s %s, plug on (shipped): boss → kill median %.1f s vs plug off %.1f s (Δ %+.1f in %+.1f..%+.1f; lock → kill med %.1f)" % [
					sid, "fallback" if fb else "native", pol, on_med, off_med, d, NECK_DELTA[0], NECK_DELTA[1], _pct(nf, 0.5)])
				var nline: String = "1-%d %s %-6s plug on: boss→kill med %5.1f (off %5.1f, Δ %+.1f)  lock→kill med %5.1f [%5.1f..%5.1f]" % [sid,
					"FB " if fb else "CPP", pol, on_med, off_med, d, _pct(nf, 0.5), _pct(nf, 0.0), _pct(nf, 1.0)]
				summary.append(nline)
				print("INFO e2e_skills: " + nline)
	for sid: int in STAGES_REST:
		for fb: bool in backends:
			var rr: Dictionary = _one(_DB.find_stage(stages_db, sid), fb, "pilot", SEEDS[0], FINISHES[sid % FINISHES.size()], fc, skc, tiers, REST_MAX_S)
			summary.append("1-%d %s pilot  lock→kill %5.1f (seed %d)  c5 %d c10 %d c20 %d" % [sid, "FB " if fb else "CPP", float(rr["fight"]),
				SEEDS[0], int(rr["c5"]), int(rr["c10"]), int(rr["c20"])])
	print("INFO e2e_skills: skill uses %s" % str(tiers))
	for line: String in summary:
		print("INFO e2e_skills summary: " + line)
	return _fails


## One run to the result card. Returns {fight (lock → kill real s), boss (boss entry → kill real s), first_c20 (real s after
## the lock, −1 = none), c5, c10, c20}.
## max_s >= 0: a 1-5..1-10 completion run (only the result card, lock → kill ≤ max_s and 0 denied{target} are gated).
## opts: extra tables.options (e.g. {"neck": false}). shipped: the plug-on run of the shipped game — the first-×20 timing
## (lock based) is not gated there: the combo already counts behind the plug.
func _one(stage: Dictionary, fb: bool, pol: String, sd: int, fin: String, fc: Dictionary, skc: Dictionary, tiers: Dictionary,
		max_s: float = -1.0, opts: Dictionary = {}, shipped: bool = false) -> Dictionary:
	var sid: int = int(stage.get("id", 0))
	var tables: Dictionary = _DB.load_traffic_tables()
	tables["options"] = {"loadout": {"finish": fin, "items": ["mv_jump", "mv_drone"]}}
	(tables["options"] as Dictionary).merge(opts, true)
	var sim := PolicySim.new()
	sim.force_fallback = fb
	sim.no_fight_skills = pol != "pilot"
	sim.duty = pol == "sloppy"
	sim.setup(stage, tables, sd)
	sim.autopilot = Autopilot.new(sd * 13 + 1)
	var boss_t0: float = -1.0
	var lock_t: float = -1.0
	var kill_t: float = -1.0
	var rel_t: float = -1.0
	var first_c20: float = -1.0
	var duty_t: float = 0.0
	var ms: Dictionary = {"c5": 0, "c10": 0, "c20": 0}
	var denied_target: int = 0
	var starts: Dictionary = {}
	var overlap: Dictionary = {}   # chan -> another channel was casting too (its hitstop / slow-mo stretches this one)
	var shared: int = 0
	var over: Array[String] = []
	var finishers: Array[String] = []
	var used: Dictionary = {}
	var stop: StringName = &"result" if pol == "pilot" else &"release"  # tacks / sloppy only need the kill
	while sim.time < LIMIT_S and sim.phase != &"result" and sim.phase != stop:
		if sim.duty and sim.phase == &"boss" and sim.front_locked:
			duty_t += Cfg.TICK
			var held: bool = fmod(duty_t, 1.6) < 1.1
			if held != sim.duty_held:
				sim.duty_held = held
				sim.input(&"fire", sim.autopilot.fire)
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			match str(e["type"]):
				"phase":
					if e["phase"] == &"boss" and boss_t0 < 0.0:
						boss_t0 = sim.real_time
					elif e["phase"] == &"kill":
						kill_t = sim.real_time
					elif e["phase"] == &"release":
						rel_t = sim.real_time
				"lock":
					lock_t = sim.real_time
				"combo_milestone":
					var mid: String = str(e["id"])
					ms[mid] = int(ms.get(mid, 0)) + 1
					if mid == "c20" and first_c20 < 0.0 and lock_t >= 0.0:
						first_c20 = sim.real_time - lock_t
				"skill_denied":
					if str(e.get("reason", "")) == "target" and sim.phase == &"boss":
						denied_target += 1
				"skill_start":
					var ch: String = str(e["chan"])
					used[str(e["id"])] = int(used.get(str(e["id"]), 0)) + 1
					if ch == "combo":
						continue
					var other: String = "item" if ch == "rage" else "rage"
					starts[ch] = sim.real_time
					overlap[ch] = starts.has(other)
					if starts.has(other):
						overlap[other] = true
				"skill_end":
					var ch2: String = str(e["chan"])
					if ch2 == "combo":
						continue
					var took: float = sim.real_time - float(starts.get(ch2, sim.real_time))
					if bool(overlap.get(ch2, false)):
						shared += 1
					elif took > float(BUDGET.get(str(e["id"]), 2.5)) + 2.0 * Cfg.TICK:
						over.append("%s %.2f s" % [str(e["id"]), took])
					starts.erase(ch2)
					overlap.erase(ch2)
				"finisher":
					finishers.append(str(e["id"]))
	var plug: String = ", plug off" if opts.get("neck") == false else (", plug on" if sim.neck.has_plug_stage() else "")
	var name: String = "1-%d %s %s seed %d (%s%s)" % [sid, "fallback" if fb else "native", pol, sd, fin, plug]
	var fight: float = kill_t - lock_t if kill_t > 0.0 and lock_t > 0.0 else INF
	var budget_rel: float = float((fc.get(fin, {}) as Dictionary).get("done", 2.5)) + float(fc.get("releaseDelay", 0.3))
	for k: Variant in used.keys():
		tiers[k] = int(tiers.get(k, 0)) + int(used[k])
	print("INFO e2e_skills: %s → %s at %.1f s, lock→kill %.1f s real (boss %.1f s real / %.1f s sim), kill → release %.2f s, combos c5 %d c10 %d c20 %d (first c20 %+.1f s), used %s (%d overlapped), hp %d" % [
		name, sim.phase, sim.real_time, fight, kill_t - boss_t0, sim.boss_clock, rel_t - kill_t, int(ms["c5"]), int(ms["c10"]), int(ms["c20"]),
		first_c20, str(used), shared, sim.hp])
	_check(sim.phase == stop and sim.bridge.is_native() != fb, "%s: reaches the %s on the %s traffic" % [name,
		"result card" if pol == "pilot" else "release", "fallback" if fb else "native"])
	var ret: Dictionary = {"fight": fight, "boss": kill_t - boss_t0 if kill_t > 0.0 and boss_t0 >= 0.0 else INF, "first_c20": first_c20,
		"c5": int(ms["c5"]), "c10": int(ms["c10"]), "c20": int(ms["c20"])}
	if max_s >= 0.0:
		_check(fight <= max_s and denied_target == 0 and finishers == [fin], "%s: lock → kill %.1f s ≤ %.0f s, 0 denied{target} (%d), finisher %s" % [
			name, fight, max_s, denied_target, str(finishers)])
		return ret
	var g: Array = GATE[pol]
	_check(fight >= FLOOR_S and fight <= float(g[1]) and sim.boss_clock >= float(skc.get("minKillT", 6.0)),
		"%s: lock → kill %.1f s real in %.0f–%.0f s, %.1f s sim ≥ minKillT" % [name, fight, FLOOR_S, float(g[1]), sim.boss_clock])
	_check(denied_target == 0, "%s: 0 skill_denied{target} in the boss phase (%d)" % [name, denied_target])
	if shipped:
		_check(int(ms["c20"]) >= 1 and int(ms["c10"]) >= 2 and int(ms["c10"]) <= 8,
			"%s: ×20 타이어 저격 %d ≥ 1, ×10 따다닥 %d in 2–8" % [name, int(ms["c20"]), int(ms["c10"])])
	else:
		_check(int(ms["c20"]) >= 1 and int(ms["c10"]) >= 2 and int(ms["c10"]) <= 8 and first_c20 >= 0.0 and first_c20 <= FIRST_C20_MAX,
			"%s: ×20 타이어 저격 %d ≥ 1 (first %.1f s after the lock ≤ %.0f), ×10 따다닥 %d in 2–8" % [name, int(ms["c20"]), first_c20,
			FIRST_C20_MAX, int(ms["c10"])])
	if pol == "pilot":
		_check(int(used.get("t3_carpet", 0)) + int(used.get("t5_finish", 0)) >= 1 and finishers == [fin],
			"%s: t3 or t5 used (t3 %d, t5 %d), finished by finisher %s" % [name, int(used.get("t3_carpet", 0)), int(used.get("t5_finish", 0)), str(finishers)])
		_check(over.is_empty() and rel_t - kill_t <= budget_rel + 0.05,
			"%s: casts alone within the real-time budget %s, kill → release %.2f ≤ %.2f s (done + releaseDelay)" % [name, str(over),
			rel_t - kill_t, budget_rel])
	else:
		_check(finishers == [fin], "%s: finished by finisher %s" % [name, str(finishers)])
	return ret
