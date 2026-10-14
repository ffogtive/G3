class_name NeckSim
extends RefCounted
## r3 A2: the bottleneck plug ("갓길 마개") + per-stage breakthrough valve (MVP), and the data side of A1 (approach pace)
## and A3 (checkpoints) from data/neck.json. Owned by GameSim; pure GDScript, so the C++ traffic and the GDScript
## fallback see the same plug (TrafficBridge.set_extras, guarded) and the same rules. Own RNG (seed*7+5): bubble lines
## only, no other stream moves.
##
## 가설: ✅ tightening the queue alone still locks in ~2.4 s because the last 22 m of the shoulder stay empty. A shoulder
##       extra 9 m behind the villain that only the stage's verb opens gives the approach its "할 일"; ❓ 4–10 s per
##       neck with the verb, the safety timer (1-1 6 s, else 8 s) as the floor for a player who does nothing.
##
## Plug: {id: PLUG_ID, s, x, w, len, v, alive, kind: "plug", role, car, phase: block|yield|open|gone}. s = F - back,
## F = max base_s of the alive villains, v = that villain's v, x = shoulder centre (1-4: the lane 3/4 boundary, so it
## blocks both). Created when the jam starts, once per run (an opened plug stays gone after a retry).
## Active (= the bottleneck) = plug blocking && phase boss before the front lock && player.s > F - activeDist. While
## active GameSim sends the traffic player mode "neck" (no stuck assist on either backend) and routes &"honk" here
## instead of TrafficBridge.honk.
## A valve honk counts only from the shoulder within `range` m of the plug's rear ("붙어서 빵": pulled up behind it); from
## beyond range it is "far" (sulk `stubborn` s + safetyPenalty); in range but more than `rudeV` m/s faster = "nudge"
## ('조금 더 붙어!', free); while it sulks an in-range honk is ignored (no refresh, no penalty) — r3 final, device review.
## Valves (data plug.valve): honk (n honks within `window` s; blink: 1-8 blinker first; passV/passFor: 1-6 pass slowly)
## · race (1-2: honk -> 0.8 s aside; the nose must get `advance` m past its rear by then or the thief takes it back) · quiet (1-3:
## within `near` m behind it, not pushing, no honk for `wait` s; honk near the duo = +penalty s + taunt) · push (1-4:
## shoulder honk pushes it into lane 3; lane-3 honk pushes it onto the shoulder, honks ignored blockFor s) · deaf
## (1-9: only rage) · none (1-5). Honk / race / push: a shoulder honk out of `range` m or one while stubborn makes it
## stubborn for `stubborn` s (0 = off, 1-1); spamN > 0: more than spamN honks within spamWin s -> ignored deafFor s.
## Common: verb chip after chipAt s; safety s after activation it gives way by itself (no bonus) — a far honk and a 1-3
## backfire push that back by safetyPenalty s (1-3: penalty), at most safetyMax s in all; a verb open = rage +
## plug.rage, score + plug.score; rage t1 (GameSim._rage_horn_effect) opens it at once (exit fly; bonus only on deaf).
## Exit cutin / zip / tow / fly runs exitDur s, then the plug is removed from the extras: cutin / zip nose towards lane 3
## (still on the shoulder) until clearAt × exitDur, then pull out ahead; tow hooks, then goes onto the verge; fly (rage)
## stops blocking at once.
## Events (GameSim forwards them): neck_active {valve, safety, chip} · neck_chip {chip} · neck_yield {valve, kind, dur}
##   · neck_block {reason} · neck_open {how: verb|rage|safety|lock|bump, bonus, exit, valve, t, s, x, id} · neck_gone {id}
##   · honk_reply {id, data, neck: true} · bubble {who: "neck" | "car" | "villain", id, text, kind, dur}.

const PLUG_ID: int = -1000
const DEFAULTS: Dictionary = {
	"enabled": false,
	"pace": {"approachVMul": 0.78, "frontGlue": true, "glue": {"every": 4, "floor": 0.35, "gapIn": 3.0, "gapOut": 5.0, "tau": 0.4}},
	"checkpoints": {"on": true, "at": [150, 100, 60], "atLong": [180, 130, 90, 50], "longJam": 200, "minLead": 15,
		"rage": 0.04, "rageLong": 0.03, "score": 100, "fastWindow": 8, "fastMul": 1.5},
	"plug": {"valve": "honk", "n": 1, "window": 1.5, "wait": 3.0, "safety": 8.0, "chip": "붙어서 빵 1번", "chipAt": 3.0,
		"back": 9.0, "len": 4.5, "w": 1.9, "car": "sedan", "kind": "cutter", "activeDist": 35.0, "range": 6.0, "rudeV": 3.0,
		"clearAt": 0.55,
		"exit": "cutin", "exitDur": 1.2, "stubborn": 2.0, "spamN": 0, "spamWin": 4.0, "deafFor": 5.0, "advance": 0.3,
		"near": 4.0, "duoRange": 40.0, "penalty": 2.0, "blockFor": 4.0, "blink": 0.0, "passV": 6.0, "passFor": 3.0,
		"straddle": false, "rage": 0.1, "score": 300, "rageReach": 26.0, "safetyPenalty": 1.0, "safetyMax": 4.0, "lines": {}},
}
const PLUG_VALVES: Array[String] = ["honk", "race", "quiet", "push", "deaf"]

var cfg: Dictionary = {}
var pc: Dictionary = {}
var enabled: bool = false
var valve: String = "none"
var rng := RandomNumberGenerator.new()
var plug: Dictionary = {}
var opened_once: bool = false
## Last open: {how, bonus, exit, valve, t}; {} until it opens.
var result: Dictionary = {}
## Honks this run that the neck answered (TrafficBridge.honk was not called for them).
var honks: int = 0

var _active: bool = false
var _t_active: float = 0.0
var _chip: String = ""
var _honk_t: Array[float] = []
var _stubborn: float = 0.0
var _stubborn_said: float = -99.0
var _deaf: float = 0.0
var _yield: Dictionary = {}
var _quiet: float = 0.0
var _quiet_extra: float = 0.0
var _push_block: float = 0.0
var _safety_extra: float = 0.0
var _exit: String = ""
var _exit_t: float = 0.0
var _off_s: float = 0.0
var _dv: float = 0.0
var _x_home: float = 9.0
var _x_exit: float = 9.0
var _clear_at: float = 0.55
var _t: float = 0.0


## table: data/neck.json ({} = DEFAULTS). force: bool overrides default.enabled (tests, shots), null = data.
func setup(table: Dictionary, stage: Dictionary, seed: int, force: Variant = null) -> void:
	cfg = NeckSim.merged(table, int(stage.get("id", 0)))
	pc = cfg["plug"]
	enabled = bool(force) if force is bool else bool(cfg.get("enabled", false))
	valve = str(pc.get("valve", "none"))
	rng.seed = seed * 7 + 5
	opened_once = false
	result = {}
	honks = 0
	_t = 0.0
	reset_attempt()


## DEFAULTS <- table.default <- table.byId[id], merged one level deep (pace / checkpoints / plug; plug.lines per key).
static func merged(table: Dictionary, id: int) -> Dictionary:
	var out: Dictionary = DEFAULTS.duplicate(true)
	var layers: Array = [table.get("default", {}), (table.get("byId", {}) as Dictionary).get(str(id), {}) if table.get("byId") is Dictionary else {}]
	for layer: Variant in layers:
		if not (layer is Dictionary):
			continue
		for k: Variant in (layer as Dictionary).keys():
			var val: Variant = (layer as Dictionary)[k]
			if val is Dictionary and out.get(k) is Dictionary:
				var dst: Dictionary = out[k]
				for k2: Variant in (val as Dictionary).keys():
					var v2: Variant = (val as Dictionary)[k2]
					if str(k2) == "lines" and v2 is Dictionary and dst.get("lines") is Dictionary:
						var ls: Dictionary = (dst["lines"] as Dictionary).duplicate(true)
						ls.merge((v2 as Dictionary).duplicate(true), true)
						dst["lines"] = ls
					else:
						dst[k2] = v2.duplicate(true) if (v2 is Dictionary or v2 is Array) else v2
			else:
				out[k] = val.duplicate(true) if (val is Dictionary or val is Array) else val
	return out


## A1: the villain's approach pace (approachVMul when frontGlue, else 1.0).
func pace_mul() -> float:
	var p: Dictionary = cfg.get("pace", {})
	return float(p.get("approachVMul", 0.78)) if bool(p.get("frontGlue", true)) else 1.0


## A1 front glue ({} = off): {every, floor, gapIn, gapOut, tau} when pace.frontGlue.
func glue_cfg() -> Dictionary:
	var p: Dictionary = cfg.get("pace", {})
	if not bool(p.get("frontGlue", true)) or not (p.get("glue") is Dictionary):
		return {}
	return p["glue"]


func has_plug_stage() -> bool:
	return enabled and PLUG_VALVES.has(valve)


## Per attempt (GameSim._setup_stage: setup and every retry): no plug until the jam starts.
func reset_attempt() -> void:
	plug = {}
	_act_tick_ok = false
	_active = false
	_t_active = 0.0
	_chip = ""
	_honk_t.clear()
	_stubborn = 0.0
	_stubborn_said = -99.0
	_deaf = 0.0
	_yield = {}
	_quiet = 0.0
	_quiet_extra = 0.0
	_push_block = 0.0
	_safety_extra = 0.0
	_exit = ""
	_exit_t = 0.0
	_off_s = 0.0
	_dv = 0.0


## GameSim._enter(&"jam"): creates the plug (once per run).
func start(sim: GameSim) -> void:
	if not has_plug_stage() or opened_once or not plug.is_empty():
		return
	var f: Array = _front(sim)
	if f.is_empty():
		return
	var straddle: bool = bool(pc.get("straddle", false))
	_x_home = (Cfg.lane_x(Cfg.SHOULDER_LANE - 1) + Cfg.lane_x(Cfg.SHOULDER_LANE)) * 0.5 if straddle else Cfg.lane_x(Cfg.SHOULDER_LANE)
	plug = {"id": PLUG_ID, "s": float(f[0]) - float(pc.get("back", 9.0)), "x": _x_home, "w": float(pc.get("w", 1.9)),
		"len": float(pc.get("len", 4.5)), "v": float(f[1]), "alive": true, "kind": "plug", "role": str(pc.get("kind", "cutter")),
		"car": str(pc.get("car", "sedan")), "phase": "block", "blinker": 0}


## [F, v]: the frontmost alive villain's base_s and v ([] when none is alive).
func _front(sim: GameSim) -> Array:
	var best: Dictionary = {}
	for v: Dictionary in sim.boss.villains:
		if bool(v["alive"]) and (best.is_empty() or float(v["base_s"]) > float(best["base_s"])):
			best = v
	return [] if best.is_empty() else [float(best["base_s"]), float(best["v"])]


func blocking() -> bool:
	return not plug.is_empty() and bool(plug["alive"]) and str(plug["phase"]) != "gone"


## The bottleneck is on: plug in block|yield, boss phase before the lock, player past F - activeDist — and, on the
## shoulder, nothing but the plug ahead of the player (a shoulder cheater stuck behind the plug is TrafficBridge.honk's:
## the bottleneck waits until it is gone). Cached per real tick.
func is_active(sim: GameSim) -> bool:
	if _act_at == sim.real_time and _act_tick_ok:
		return _act_val
	_act_at = sim.real_time
	_act_tick_ok = true
	_act_val = _is_active(sim)
	return _act_val


var _act_at: float = -1.0
var _act_tick_ok: bool = false
var _act_val: bool = false


func _is_active(sim: GameSim) -> bool:
	if plug.is_empty() or not (str(plug["phase"]) in ["block", "yield"]) or sim.phase != &"boss" or sim.front_locked:
		return false
	var f: Array = _front(sim)
	if f.is_empty() or sim.player.s <= float(f[0]) - float(pc.get("activeDist", 35.0)):
		return false
	if sim.player.lane == Cfg.SHOULDER_LANE and gap(sim) > 0.5:
		var g: Dictionary = sim.bridge.gap_ahead(Cfg.SHOULDER_LANE, sim.player.s + sim.player.len / 2.0)
		if str(g.get("type", "")) == "car" and float(g.get("gap", INF)) < gap(sim) - 0.5:
			return false
	return true


## Drops the per-tick is_active cache (state changed inside the tick: open / phase).
func _dirty() -> void:
	_act_tick_ok = false


## traffic.js occupies() on the plug (the C++ buckets and the fallback villain test use the same band).
func occupies(lane: int) -> bool:
	return blocking() and absf(float(plug["x"]) - Cfg.lane_x(lane)) < float(plug["w"]) / 2.0 + Cfg.LANE_W / 2.0 - 0.6


func rear() -> float:
	return float(plug["s"]) - float(plug["len"]) / 2.0


func front() -> float:
	return float(plug["s"]) + float(plug["len"]) / 2.0


## Gap from the player's nose to the plug's rear (negative = alongside / past it). INF without a plug.
func gap(sim: GameSim) -> float:
	if plug.is_empty():
		return INF
	return rear() - (sim.player.s + sim.player.len / 2.0)


func _shares_lane(p: PlayerSim) -> bool:
	for l: int in Cfg.SHOULDER_LANE + 1:
		if occupies(l) and p.occupies(l):
			return true
	return false


## The plug as the player's leader (GameSim._leader, both backends: with or without TrafficBridge.set_extras).
func leader_for(p: PlayerSim) -> Dictionary:
	if not blocking() or float(plug["s"]) <= p.s or not _shares_lane(p):
		return {}
	return {"id": PLUG_ID, "gap": rear() - (p.s + p.len / 2.0), "type": "extra", "v": float(plug["v"]), "smash": false, "neck": true}


## True when the plug is in `lane` and overlaps [s_lo, s_hi] (lane-change guard).
func blocks(lane: int, s_lo: float, s_hi: float) -> bool:
	return occupies(lane) and front() > s_lo and rear() < s_hi


## For TrafficBridge.set_extras: [{s, x, w, len, v, alive, kind}] ([] once it no longer blocks).
func extras() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if blocking():
		out.append({"s": float(plug["s"]), "x": float(plug["x"]), "w": float(plug["w"]), "len": float(plug["len"]),
			"v": float(plug["v"]), "alive": true, "kind": "plug"})
	return out


func chip() -> String:
	return _chip


## Seconds of activity after which it gives way by itself (+ the penalty bad honks earned).
func safety() -> float:
	return float(pc.get("safety", 8.0)) + _safety_extra


func _penalize(sec: float) -> void:
	_safety_extra = minf(float(pc.get("safetyMax", 4.0)), _safety_extra + sec)


# --- tick ---------------------------------------------------------------------------------------------

## Once per GameSim.step (sim dt), before the traffic step: plug position, valve timers, chip, safety, exit.
func tick(sim: GameSim, sdt: float) -> void:
	_t += sdt
	if plug.is_empty() or str(plug["phase"]) == "gone":
		return
	var f: Array = _front(sim)
	if f.is_empty() and str(plug["phase"]) in ["block", "yield"]:
		_open(sim, "lock")
	var back: float = float(pc.get("back", 9.0))
	var base_s: float = float(f[0]) - back if not f.is_empty() else float(plug["s"]) - _off_s
	var vv: float = float(f[1]) if not f.is_empty() else maxf(0.0, float(plug["v"]) - _dv)
	_stubborn = maxf(0.0, _stubborn - sdt)
	_deaf = maxf(0.0, _deaf - sdt)
	_push_block = maxf(0.0, _push_block - sdt)
	if str(plug["phase"]) == "open":
		_exit_t += sdt
		var late: bool = _exit_t >= _clear_at * float(pc.get("exitDur", 1.2))
		match _exit:
			"tow":
				_dv = maxf(-vv, _dv - 6.0 * sdt) if late else 0.0
				if late:
					_ease_x(_x_exit, 9.0, sdt)
			"fly":
				_dv = 12.0
				_ease_x(_x_exit, 7.0, sdt)
			_:
				var top: float = 3.0 if _exit == "zip" else 6.0
				_dv = minf(top, _dv + 14.0 * sdt) if late else minf(0.6, _dv + 2.0 * sdt)
				_ease_x(_x_exit if late else minf(float(plug["x"]), maxf(_x_exit, _x_nose())), 9.0 if late else 4.0, sdt)
		_off_s += _dv * sdt
		plug["s"] = base_s + _off_s
		plug["v"] = vv + _dv
		if _exit_t >= float(pc.get("exitDur", 1.2)):
			plug["phase"] = "gone"
			plug["alive"] = false
			sim._emit({"type": "neck_gone", "id": PLUG_ID})
		return
	plug["s"] = base_s
	plug["v"] = vv
	var act: bool = is_active(sim)
	if act and not _active:
		sim._emit({"type": "neck_active", "valve": valve, "safety": safety(), "chip": str(pc.get("chip", ""))})
		_say(sim, "block", "taunt", 1.6)
	_active = act
	if act:
		_t_active += sdt
		if _chip == "" and _t_active >= float(pc.get("chipAt", 3.0)):
			_chip = str(pc.get("chip", ""))
			sim._emit({"type": "neck_chip", "chip": _chip})
	if valve == "quiet":
		_tick_quiet(sim, sdt, act)
	if not _yield.is_empty():
		_tick_yield(sim, sdt)
	if str(plug["phase"]) == "open":
		return
	var tx: float = _x_home
	var rate: float = 6.0
	if not _yield.is_empty():
		tx = float(_yield.get("x", _x_home))
		rate = float(_yield.get("rate", 10.0))
	elif valve == "push" and _push_block > 0.0:
		tx = Cfg.lane_x(Cfg.SHOULDER_LANE)
	_ease_x(tx, rate, sdt)
	if act and _t_active >= safety():
		_say(sim, "safety", "warn", 1.4)
		_open(sim, "safety")


## Where a cutin / zip noses to before it leaves: as far into lane 3 as it can while still on the shoulder band.
func _x_nose() -> float:
	return Cfg.lane_x(Cfg.SHOULDER_LANE) - (float(plug["w"]) / 2.0 + Cfg.LANE_W / 2.0 - 0.6) + 0.35


func _ease_x(tx: float, rate: float, sdt: float) -> void:
	plug["x"] = float(plug["x"]) + (tx - float(plug["x"])) * (1.0 - exp(-sdt * rate))


func _tick_quiet(sim: GameSim, sdt: float, act: bool) -> void:
	var p: PlayerSim = sim.player
	var g: float = gap(sim)
	if act and p.lane == Cfg.SHOULDER_LANE and g >= -0.5 and g <= float(pc.get("near", 4.0)) and p.v - float(plug["v"]) < 1.0:
		_quiet += sdt
	else:
		_quiet = 0.0
	if _quiet >= float(pc.get("wait", 3.0)) + _quiet_extra:
		_say(sim, "open", "score", 1.2)
		_open(sim, "verb")


func _tick_yield(sim: GameSim, sdt: float) -> void:
	var p: PlayerSim = sim.player
	_yield["t"] = float(_yield["t"]) + sdt
	var t: float = float(_yield["t"])
	match str(_yield["kind"]):
		"race":
			var nose: float = p.s + p.len / 2.0
			if nose >= rear() + float(pc.get("advance", 0.3)):
				_yield = {}
				_open(sim, "verb")
			elif t >= float(_yield["dur"]):
				_yield = {}
				plug["phase"] = "block"
				_say(sim, "thief", "taunt", 1.3)
				sim._emit({"type": "neck_block", "reason": "thief"})
		"blink":
			plug["blinker"] = 1
			if t >= float(_yield["dur"]):
				_yield = {}
				plug["blinker"] = 0
				_say(sim, "open", "score", 1.2)
				_open(sim, "verb")
		"pass":
			var along: bool = p.s + p.len / 2.0 > rear() and p.s - p.len / 2.0 < front()
			if along and p.v > float(pc.get("passV", 6.0)) and not bool(_yield.get("bumped", false)):
				_yield["bumped"] = true
				var dmg: int = sim.apply_damage(float(sim.hpc.get("bumpDmg", 10)), "피해차 스침", "neck")
				sim._emit({"type": "bump", "id": PLUG_ID, "rel_v": p.v - float(plug["v"]), "push": false, "dmg": dmg, "neck": true})
				_say(sim, "bump", "angry", 1.2)
			if p.s - p.len / 2.0 > front():
				var bumped: bool = bool(_yield.get("bumped", false))
				_yield = {}
				_open(sim, "bump" if bumped else "verb")
			elif t >= float(_yield["dur"]) and not along:
				_yield = {}
				plug["phase"] = "block"
				sim._emit({"type": "neck_block", "reason": "timeout"})


# --- inputs -------------------------------------------------------------------------------------------

## A player honk while is_active() (GameSim routes it here instead of TrafficBridge.honk). Returns {kind, id}:
## kind noway | far | stubborn | deaf | nudge | spam | valve | backfire | pushed | busy.
func on_honk(sim: GameSim) -> Dictionary:
	honks += 1
	var p: PlayerSim = sim.player
	var g: float = gap(sim)
	# r3 final (device review major): "far" is a honk from beyond `range` m only. A honk on arrival (inside range, still
	# closing at the leash's v + sqrt(18·(gap − 1)), 5–7 m/s at 3–4 m) used to read as "far" (rudeV 3), started the sulk
	# and every later honk refreshed it + added safety penalty: eager tappers waited the 12 s safety on 6/9 stages.
	# Now: in range but faster than rudeV → "nudge" ('조금 더 붙어!', no sulk, no penalty); while sulking an in-range honk
	# is ignored (no refresh, no penalty); only a far honk sulks (`stubborn` s) and costs safetyPenalty.
	var in_range: bool = g <= float(pc.get("range", 6.0)) and g >= -float(plug["len"])
	var rude: bool = p.v - float(plug["v"]) > float(pc.get("rudeV", 3.0))
	var lane_ok: bool = p.lane == Cfg.SHOULDER_LANE or (valve == "push" and p.lane == Cfg.SHOULDER_LANE - 1)
	var r: String = ""
	if valve == "quiet":
		r = _honk_quiet(sim)
	elif not lane_ok:
		r = "noway"
		var L: Dictionary = sim.bridge.leader_of_player()
		if str(L.get("type", "")) == "car" and float(L.get("gap", INF)) < 20.0:
			sim._emit({"type": "bubble", "who": "car", "id": int(L["id"]), "text": _line("noway"), "kind": "warn", "dur": 1.2})
		else:
			_say(sim, "noway", "warn", 1.2)
	elif valve == "deaf":
		r = "deaf"
		_say(sim, "deaf", "warn", 1.2)
	elif str(plug["phase"]) == "yield":
		r = "busy"
		if str(_yield.get("kind", "")) == "blink" and float(pc.get("stubborn", 0.0)) > 0.0:
			_yield = {}
			plug["blinker"] = 0
			plug["phase"] = "block"
			_stubborn = float(pc.get("stubborn", 2.0))
			r = "stubborn"
			_say(sim, "stubborn", "angry", 1.2)
			sim._emit({"type": "neck_block", "reason": "spam"})
	elif not in_range:
		r = "far"
		if float(pc.get("stubborn", 0.0)) > 0.0:
			_stubborn = float(pc.get("stubborn", 2.0))
			_penalize(float(pc.get("safetyPenalty", 1.0)))
			_say(sim, "far", "taunt", 1.2)
	elif _deaf > 0.0 or (valve == "push" and _push_block > 0.0) or _stubborn > 0.0:
		r = "stubborn"  # ignored: the sulk / spam deafness / push block runs out on its own
		if _t - _stubborn_said > 1.4:
			_stubborn_said = _t
			_say(sim, "stubborn", "angry", 1.0)
	elif rude:
		r = "nudge"
		_say(sim, "closer", "warn", 0.9)
	else:
		r = _honk_valve(sim)
	sim._emit({"type": "honk_reply", "id": PLUG_ID, "data": r, "neck": true})
	return {"kind": r, "id": PLUG_ID}


func _honk_quiet(sim: GameSim) -> String:
	_quiet = 0.0
	for v: Dictionary in sim.boss.alive():
		if absf(float(v["s"]) - sim.player.s) < float(pc.get("duoRange", 40.0)):
			_quiet_extra += float(pc.get("penalty", 2.0))
			_penalize(float(pc.get("penalty", 2.0)))
			var lines: Array = (pc.get("lines", {}) as Dictionary).get("backfire", ["빵빵해봐야 소용없지~"])
			sim._emit({"type": "bubble", "who": "villain", "id": int(v["index"]), "text": str(lines[rng.randi_range(0, lines.size() - 1)]),
				"kind": "taunt", "dur": 1.6})
			return "backfire"
	return "noway"


func _honk_valve(sim: GameSim) -> String:
	var p: PlayerSim = sim.player
	match valve:
		"race":
			_yield = {"kind": "race", "t": 0.0, "dur": float(pc.get("window", 0.8)), "s0": p.s, "x": Cfg.lane_x(Cfg.SHOULDER_LANE - 1) + 1.25,
				"rate": 22.0}
			plug["phase"] = "yield"
			sim._emit({"type": "neck_yield", "valve": valve, "kind": "race", "dur": float(_yield["dur"])})
			return "valve"
		"push":
			if p.lane == Cfg.SHOULDER_LANE:
				_say(sim, "pushed", "angry", 1.0)
				_open(sim, "verb", Cfg.lane_x(Cfg.SHOULDER_LANE - 1))
				return "valve"
			_push_block = float(pc.get("blockFor", 4.0))
			_say(sim, "pushed", "angry", 1.2)
			sim._emit({"type": "neck_block", "reason": "pushed"})
			return "pushed"
		_:
			var now: float = _t
			var spam_n: int = int(pc.get("spamN", 0))
			_honk_t.append(now)
			var win: float = maxf(float(pc.get("window", 1.5)), float(pc.get("spamWin", 4.0)))
			while not _honk_t.is_empty() and now - _honk_t[0] > win:
				_honk_t.pop_front()
			if spam_n > 0:
				var k_spam: int = 0
				for ht: float in _honk_t:
					if now - ht <= float(pc.get("spamWin", 4.0)):
						k_spam += 1
				if k_spam > spam_n:
					_deaf = float(pc.get("deafFor", 5.0))
					_honk_t.clear()
					_say(sim, "stubborn", "angry", 1.4)
					sim._emit({"type": "neck_block", "reason": "spam"})
					return "spam"
			var need: int = maxi(1, int(pc.get("n", 1)))
			var k: int = 0
			for ht: float in _honk_t:
				if now - ht <= float(pc.get("window", 1.5)) + 1e-6:
					k += 1
			if k < need:
				_say(sim, "nudge", "warn", 0.9)
				return "nudge"
			_honk_t.clear()
			if float(pc.get("blink", 0.0)) > 0.0:
				_yield = {"kind": "blink", "t": 0.0, "dur": float(pc.get("blink", 1.0)), "x": _x_home, "rate": 6.0}
				plug["phase"] = "yield"
				sim._emit({"type": "neck_yield", "valve": valve, "kind": "blink", "dur": float(_yield["dur"])})
				return "valve"
			if str(pc.get("kind", "")) == "victim" and float(pc.get("passFor", 0.0)) > 0.0:
				_yield = {"kind": "pass", "t": 0.0, "dur": float(pc.get("passFor", 3.0)), "x": Cfg.lane_x(Cfg.SHOULDER_LANE) + 2.4,
					"rate": 9.0}
				plug["phase"] = "yield"
				sim._emit({"type": "neck_yield", "valve": valve, "kind": "pass", "dur": float(_yield["dur"])})
				return "valve"
			_say(sim, "open", "score", 1.2)
			_open(sim, "verb")
			return "valve"


## Rage t1 (GameSim._rage_horn_effect): opens the plug at once when the bottleneck is on or the plug is within
## rageReach m ahead. Returns true when it opened.
func on_rage(sim: GameSim) -> bool:
	if not blocking() or not (str(plug["phase"]) in ["block", "yield"]):
		return false
	var g: float = gap(sim)
	if not is_active(sim) and not (g <= float(pc.get("rageReach", 26.0)) and g >= -float(plug["len"])):
		return false
	_open(sim, "rage")
	return true


## Spec name for the GameSim hook: open("rage") == on_rage(sim); any other how opens it unconditionally.
func open(sim: GameSim, how: String) -> bool:
	if how == "rage":
		return on_rage(sim)
	if not blocking() or not (str(plug["phase"]) in ["block", "yield"]):
		return false
	_open(sim, how)
	return true


## The front lock: a plug still standing gives way (no bonus).
func on_lock(sim: GameSim) -> void:
	if blocking() and str(plug["phase"]) in ["block", "yield"]:
		_open(sim, "lock")


## Release / kill: no plug from now on.
func clear() -> void:
	_act_tick_ok = false
	if not plug.is_empty():
		plug["phase"] = "gone"
		plug["alive"] = false


## Starts the exit. x_exit: lateral target (NAN = by exit: cutin/zip half into lane 3, tow onto the verge).
func _open(sim: GameSim, how: String, x_exit: float = NAN) -> void:
	var bonus: bool = how == "verb" or (how == "rage" and valve == "deaf")
	_exit = "fly" if how == "rage" else (str(pc.get("exit", "cutin")) if how == "verb" or how == "bump" else "cutin")
	if not is_nan(x_exit):
		_x_exit = x_exit
	elif _exit == "tow":
		_x_exit = Cfg.lane_x(Cfg.SHOULDER_LANE) + 2.6
	else:
		_x_exit = Cfg.lane_x(Cfg.SHOULDER_LANE - 1) + 1.25
	_clear_at = 0.0 if how == "safety" else float(pc.get("clearAt", 0.55))  # it has been waiting: straight out
	if _exit == "fly":
		plug["alive"] = false
	plug["phase"] = "open"
	plug["blinker"] = 0
	_dirty()
	_yield = {}
	_exit_t = 0.0
	_dv = 0.0
	_off_s = 0.0
	opened_once = true
	if bonus:
		sim.add_rage(float(pc.get("rage", 0.1)))
		sim.score += int(pc.get("score", 300))
	result = {"how": how, "bonus": bonus, "exit": _exit, "valve": valve, "t": _t_active}
	sim._emit({"type": "neck_open", "how": how, "bonus": bonus, "exit": _exit, "valve": valve, "t": _t_active,
		"s": float(plug["s"]), "x": float(plug["x"]), "id": PLUG_ID})


func _line(key: String) -> String:
	var lines: Variant = (pc.get("lines", {}) as Dictionary).get(key)
	if not (lines is Array) or (lines as Array).is_empty():
		return ""
	return str((lines as Array)[rng.randi_range(0, (lines as Array).size() - 1)])


## Public bubble helper (GameSim's lane-change guard): who "neck", a line from plug.lines[key].
func say(sim: GameSim, key: String, kind: String, dur: float) -> void:
	_say(sim, key, kind, dur)


func _say(sim: GameSim, key: String, kind: String, dur: float) -> void:
	var text: String = _line(key)
	if text == "" or plug.is_empty():
		return
	sim._emit({"type": "bubble", "who": "neck", "id": PLUG_ID, "text": text, "kind": kind, "dur": dur})


## state().neck: {on, active, s, x, len, w, kind (role), car, valve, phase, chip, safety_left, exit, t, how, blinker,
## yield_left, id}. on = a plug exists this attempt (phase != gone).
func state(sim: GameSim) -> Dictionary:
	var on: bool = not plug.is_empty() and str(plug["phase"]) != "gone"
	var out: Dictionary = {"on": on, "active": is_active(sim), "valve": valve, "chip": _chip, "id": PLUG_ID,
		"phase": str(plug.get("phase", "gone")), "exit": _exit, "t": _t_active, "how": str(result.get("how", "")),
		"safety_left": maxf(0.0, safety() - _t_active) if on else 0.0, "enabled": has_plug_stage()}
	if not plug.is_empty():
		out.merge({"s": float(plug["s"]), "x": float(plug["x"]), "len": float(plug["len"]), "w": float(plug["w"]),
			"kind": str(plug["role"]), "car": str(plug["car"]), "v": float(plug["v"]), "blinker": int(plug.get("blinker", 0)),
			"exit_t": _exit_t, "yield_left": maxf(0.0, float(_yield.get("dur", 0.0)) - float(_yield.get("t", 0.0))) if not _yield.is_empty() else 0.0,
			"yield": str(_yield.get("kind", ""))}, true)
	return out
