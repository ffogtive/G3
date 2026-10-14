extends RefCounted
## Boss-fight rules from DESIGN_REVIEW_2026-10-13 on GameSim (1-1):
##   P0#1 no pass-through soft-lock: flooring it on the shoulder never ends > 15 m past the villain before the lock;
##        with the lock made impossible the leash still holds it, and a player who parks in the villain's lane in
##        front of it (brake) is never driven through.
##   P0#2 lock-on range band: out of the villain lane ±1 tacks fall behind the car as "miss" events, lock.in_range
##        is false and the chip says which way; back in the band they hit.
##   P0#7 damage ×boss.vulnMul inside the signature window (occupy stun), small outside; bomb dmgOut outside.
##   r3 C2 generic window (behaviors/generic_window.gd): a stage whose sig has no ported module (1-2..1-10) opens a
##        1.2 s 빈틈 every 4.5 s of BossSim time after the lock (vulnerable → tacks ×vulnMul, no attack starts, the
##        bubble "헉헉… (빈틈!)" + a stun event at each open); 1-1 keeps occupy; boss.genericWindow.on = false turns it off.
##
## 가설: ✅ a speed leash (villain v + dv·(far − ahead)/far) and a villain that yields to a car right in front of
##       it remove both soft-locks without touching the lock rule itself.

const _DB := preload("res://core/db.gd")

var _fails: int = 0
var _stage: Dictionary = {}
var _tables: Dictionary = {}


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " boss_rules: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	_stage = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	_tables = _DB.load_traffic_tables()
	_floor_it(false)
	_floor_it(true)
	_park_in_front()
	_range_band()
	_damage_windows()
	for fb: bool in [false, true]:
		if not fb and not TrafficBridge.native_available():
			print("SKIP boss_rules: C++ Traffic not loaded (generic window, native path)")
			continue
		_generic_window(fb)
	_generic_window_attach()
	return _fails


func _sim(stage: Dictionary, seed: int = 7) -> GameSim:
	var sim := GameSim.new()
	sim.setup(stage, _tables, seed)
	return sim


## Runs until cond() or max_t sim seconds; returns true when cond() became true.
func _run(sim: GameSim, cond: Callable, max_t: float, each: Callable = Callable()) -> bool:
	var t_end: float = sim.time + max_t
	while sim.time < t_end:
		sim.step(Cfg.TICK)
		sim.events()
		if each.is_valid():
			each.call()
		if cond.call():
			return true
	return false


## Shoulder runner: right until the shoulder, honk when something blocks it, never brake.
func _shoulder_driver(sim: GameSim) -> Callable:
	var state: Dictionary = {"next": 0.0}
	return func() -> void:
		if sim.real_time < float(state["next"]) or not sim.is_jam_like():
			return
		state["next"] = sim.real_time + 0.25
		sim.sync_traffic_player()
		if sim.player.lane < Cfg.SHOULDER_LANE:
			sim.input(&"lane", 1)
		elif float(sim.bridge.gap_ahead(Cfg.SHOULDER_LANE, sim.player.s + sim.player.len / 2.0)["gap"]) < 10.0:
			sim.input(&"honk")
			if sim.bridge.can_merge(Cfg.SHOULDER_LANE - 1, 0.5) == 0:
				sim.input(&"lane", -1)


func _floor_it(no_lock: bool) -> void:
	var st: Dictionary = _stage.duplicate(true)
	if no_lock:
		st["fight"] = {"gap": 11, "lockAt": 9999}
	var sim: GameSim = _sim(st)
	sim.input(&"continue")
	var drive: Callable = _shoulder_driver(sim)
	var worst: Array[float] = [-INF]
	var each: Callable = func() -> void:
		drive.call()
		if sim.phase == &"boss" and not sim.front_locked:
			worst[0] = maxf(worst[0], sim.player.s - sim.boss.ref_s())
	var found: bool = _run(sim, func() -> bool: return sim.phase == &"boss", 120.0, each)
	_check(found, "%s: the shoulder runner discovers the villain (t=%.1f)" % ["no-lock" if no_lock else "1-1", sim.time])
	if no_lock:
		_run(sim, func() -> bool: return false, 25.0, each)
		_check(not sim.front_locked and worst[0] <= 15.0, "no-lock: 25 s past discovery the leash keeps the player ≤ 15 m ahead (max %.1f m)" % worst[0])
		_check(sim.hint().begins_with("지나쳤다"), "no-lock: the chip says the player passed it ('%s')" % sim.hint())
	else:
		_run(sim, func() -> bool: return sim.front_locked, 20.0, each)
		_check(sim.front_locked and worst[0] <= 15.0, "1-1: front lock reached, never > 15 m past the villain before it (max %.1f m)" % worst[0])


func _park_in_front() -> void:
	var st: Dictionary = _stage.duplicate(true)
	st["fight"] = {"gap": 11, "lockAt": 9999}
	var sim: GameSim = _sim(st)
	sim.input(&"continue")
	var drive: Callable = _shoulder_driver(sim)
	_run(sim, func() -> bool: return sim.phase == &"boss" and sim.player.s > sim.boss.ref_s() + 10.0, 120.0, drive)
	# cut across to the villain's lane (0) in front of it, then stand on the brake
	var moved: bool = _run(sim, func() -> bool: return sim.player.lane == 0 and not sim.player.changing_lane(), 6.0, func() -> void:
		if not sim.player.changing_lane():
			sim.input(&"lane", -1))
	_check(moved, "park: player reaches lane 0 in front of the villain (s %.1f vs villain %.1f)" % [sim.player.s, sim.boss.ref_s()])
	sim.input(&"brake", true)
	var v: Dictionary = sim.boss.villains[0]
	var overlap: Array[float] = [-INF]
	_run(sim, func() -> bool: return false, 12.0, func() -> void:
		overlap[0] = maxf(overlap[0], float(v["base_s"]) + float(v["len"]) / 2.0 - (sim.player.s - sim.player.len / 2.0)))
	_check(sim.player.v < 0.05, "park: braking stops the player (v %.2f)" % sim.player.v)
	_check(overlap[0] < 0.05 and float(v["v"]) < 0.3, "park: the villain stops behind instead of driving through (worst overlap %.2f m, v %.2f)" % [overlap[0], float(v["v"])])


func _lock_fight(seed: int = 7) -> GameSim:
	var sim: GameSim = _sim(_stage, seed)
	sim.autopilot = Autopilot.new(seed)
	_run(sim, func() -> bool: return sim.front_locked, 120.0)
	sim.autopilot = null
	sim.input(&"fire", false)
	return sim


func _range_band() -> void:
	var sim: GameSim = _lock_fight()
	_check(sim.front_locked, "band: autopilot reaches the front lock")
	_run(sim, func() -> bool: return sim.player.lane == 3 and not sim.player.changing_lane(), 4.0, func() -> void:
		if not sim.player.changing_lane() and sim.player.lane != 3:
			sim.input(&"lane", signi(3 - sim.player.lane)))
	sim.input(&"fire", true)
	var misses: Array[int] = [0]
	var hits: Array[int] = [0]
	var t_end: float = sim.time + 2.5
	while sim.time < t_end:
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			misses[0] += 1 if e["type"] == "miss" else 0
			hits[0] += 1 if e["type"] == "hit" else 0
	var st: Dictionary = sim.state()
	_check(sim.player.lane == 3 and misses[0] >= 3 and hits[0] == 0, "band: lane 3 (out of lane 0 ±1) → %d miss events, %d hits (lane %d)" % [misses[0], hits[0], sim.player.lane])
	_check(not bool(st["lock"]["in_range"]) and str(st["lock"]["reason"]) == "lane" and str(st["hint"]) == "◀ 원흉 차로로",
		"band: lock.in_range false, reason 'lane', chip '%s'" % st["hint"])
	_run(sim, func() -> bool: return sim.player.lane == 1 and not sim.player.changing_lane(), 4.0, func() -> void:
		if not sim.player.changing_lane() and sim.player.lane > 1:
			sim.input(&"lane", -1))
	hits[0] = 0
	t_end = sim.time + 1.5
	while sim.time < t_end and sim.phase == &"boss":
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			hits[0] += 1 if e["type"] == "hit" else 0
	_check(hits[0] >= 3 and bool(sim.state()["lock"]["in_range"]), "band: back in lane 1 → %d hits, in_range" % hits[0])


func _damage_windows() -> void:
	var sim: GameSim = _lock_fight(11)
	var b: BossSim = sim.boss
	var v: Dictionary = b.villains[0]
	var vm: float = float(sim.bc.get("vulnMul", 4.0))
	var tack: float = float(sim.wc["tack"]["dmg"])
	print("INFO boss_rules: P0#7 precondition stun_skill %.2f (a c20 snipe stun is a window too; cleared here)" % float(v.get("stun_skill", 0.0)))
	v["stun_skill"] = 0.0  # r3 final: the fight may have reached ×20 (stun 0.8 = a window) before this probe
	b.sig["stun"] = 0.0
	var out_d: float = float(b.damage(v, tack, tack * vm, false)["dmg"])
	b.sig["stun"] = 1.0
	var r_in: Dictionary = b.damage(v, tack, tack * vm, false)
	_check(is_equal_approx(out_d, tack) and is_equal_approx(float(r_in["dmg"]), tack * vm) and bool(r_in["window"]),
		"P0#7: tack %.1f outside the stun, %.1f inside (×%.0f)" % [out_d, float(r_in["dmg"]), vm])
	b.sig["stun"] = 0.0
	v["stun_skill"] = 0.0
	var bomb: Dictionary = sim.wc["bomb"]
	var bo: float = float(b.damage(v, float(bomb["dmgOut"]), float(bomb["dmg"]), false)["dmg"])
	_check(is_equal_approx(bo, float(bomb["dmgOut"])) and bo < float(bomb["dmg"]), "P0#7: rage bomb outside the window only %.0f (inside %.0f)" % [bo, float(bomb["dmg"])])


const GW_PATH: String = "res://sim/behaviors/generic_window.gd"


func _gw_of(sim: GameSim) -> bool:
	var beh: Object = sim.boss.beh
	return beh != null and beh.get_script() != null and (beh.get_script() as Script).resource_path == GW_PATH


func _generic_window_attach() -> void:
	var stages: Variant = _DB.load_json("res://data/stages.json")
	var s1: GameSim = _sim(_DB.find_stage(stages, 1))
	var occupy: bool = s1.boss.beh != null and (s1.boss.beh.get_script() as Script).resource_path.ends_with("occupy.gd")
	var gw_ids: Array[int] = []
	for sid: int in range(2, 11):
		if _gw_of(_sim(_DB.find_stage(stages, sid))):
			gw_ids.append(sid)
	_check(occupy and not _gw_of(s1) and gw_ids == [2, 3, 4, 5, 6, 7, 8, 9, 10],
		"generic window: 1-1 keeps occupy (no GW), 1-2..1-10 (sig not ported) get it %s" % str(gw_ids))
	var off: Dictionary = _DB.load_traffic_tables()
	var boss: Dictionary = (off["config"] as Dictionary).get("boss", {})
	var gw: Dictionary = (boss.get("genericWindow", {}) as Dictionary).duplicate()
	gw["on"] = false
	boss["genericWindow"] = gw
	var s2 := GameSim.new()
	s2.setup(_DB.find_stage(stages, 2), off, 7)
	_check(s2.boss.beh == null, "boss.genericWindow.on = false → 1-2 has no behaviour module")


## 1-2 by the autopilot to the lock, villain HP pinned high, then 16 s of fight: the GW windows open every period for
## dur s, no "attack" event starts inside one, each open has its bubble + stun event, tacks inside hit ×vulnMul.
func _generic_window(fb: bool) -> void:
	var tag: String = "fallback" if fb else "native"
	var stage: Dictionary = _DB.find_stage(_DB.load_json("res://data/stages.json"), 2)
	var sim := GameSim.new()
	sim.force_fallback = fb
	sim.setup(stage, _tables, 7)
	sim.autopilot = Autopilot.new(7)
	var lock_t: Array[float] = [-1.0]
	_run(sim, func() -> bool: return sim.front_locked, 120.0, func() -> void:
		if sim.front_locked and lock_t[0] < 0.0:
			lock_t[0] = sim.boss.time)
	if not sim.front_locked or not _gw_of(sim):
		_check(false, "%s GW: 1-2 reaches the lock with the generic window (locked %s, gw %s)" % [tag, sim.front_locked, _gw_of(sim)])
		return
	lock_t[0] = sim.boss.time
	var beh: Object = sim.boss.beh
	var period: float = float(beh.get("period"))
	var dur: float = float(beh.get("dur"))
	for v: Dictionary in sim.boss.villains:
		v["max_hp"] = 1e6
		v["hp"] = 1e6
	var opens: Array[float] = []
	var closes: Array[float] = []
	var was: bool = false
	var atk_in: int = 0
	var atk_out: int = 0
	var bubbles: int = 0
	var stuns: int = 0
	var win_hits: int = 0
	var vm: float = float(sim.bc.get("vulnMul", 4.0))
	var tack: float = float(sim.wc["tack"]["dmg"])
	var t_end: float = sim.time + 16.0
	while sim.time < t_end and sim.phase == &"boss":
		sim.step(Cfg.TICK)
		var wl: float = float(beh.call(&"window_left", sim.boss))
		var on: bool = wl > 0.0
		if on and not was:
			opens.append(sim.boss.time)
		elif was and not on:
			closes.append(sim.boss.time)
		was = on
		for e: Dictionary in sim.events():
			match str(e["type"]):
				"attack":
					if on:
						atk_in += 1
					else:
						atk_out += 1
				"bubble":
					bubbles += 1 if str(e.get("text", "")) == "헉헉… (빈틈!)" else 0
				"stun":
					stuns += 1 if bool(e.get("generic", false)) else 0
				"hit":
					if on and str(e.get("kind", "")) == "tack" and is_equal_approx(float(e["dmg"]), tack * vm) and bool(e["window"]):
						win_hits += 1
	var gaps_ok: bool = opens.size() >= 3
	for i: int in range(1, opens.size()):
		gaps_ok = gaps_ok and absf(opens[i] - opens[i - 1] - period) <= Cfg.TICK + 1e-6
	var durs_ok: bool = closes.size() >= 2
	for i: int in mini(opens.size(), closes.size()):
		durs_ok = durs_ok and absf(closes[i] - opens[i] - dur) <= Cfg.TICK + 1e-6
	var first: float = opens[0] - lock_t[0] if not opens.is_empty() else -1.0
	_check(gaps_ok and durs_ok and is_equal_approx(period, 4.5) and is_equal_approx(dur, 1.2),
		"%s GW 1-2: %d windows every %.2f s for %.2f s (opens %s)" % [tag, opens.size(), period, dur, str(opens.map(func(x: float) -> String: return "%.2f" % (x - lock_t[0])))])
	_check(absf(first - (period - dur)) <= 0.25, "%s GW: first window %.2f s after the lock (period − dur = %.1f)" % [tag, first, period - dur])
	_check(atk_in == 0 and atk_out >= 1, "%s GW: 0 attacks start inside a window (%d outside)" % [tag, atk_out])
	_check(bubbles == opens.size() and stuns >= opens.size(), "%s GW: each open → '헉헉… (빈틈!)' bubble (%d) + stun event (%d) for %d windows" % [tag, bubbles, stuns, opens.size()])
	_check(win_hits >= 3, "%s GW: tacks inside the window hit ×vulnMul (%d window hits of %.0f)" % [tag, win_hits, tack * vm])
	_check(str(sim.hint()) != "", "%s GW: hint chip '%s'" % [tag, sim.hint()])
