class_name SkillCues
extends Node
## Audio + haptic cues of the skill events (docs/SKILLS.md 2-3, 2-6, 3-3, 4; interface §6).
##
## 가설: ❓ one dispatcher per event, keyed on the sim's own ticks (skill_start = 예고, skill_hit = 임팩트, finisher beats from
##       the dying villain's death_t), keeps sound, haptic, flash and particles on the same tick: the impact cues never run
##       on a timer guessed from the cast, so hit-stop and slow-mo cannot pull them apart.
## 가설(r3 F1): ❓ the fight t1 sounded like a horn because its fx key was "t1" (= the jam horn's recipe with hornTruck).
##       Its own key "t1_wave" (sk_wave → superHit → explosion, no hornTruck) + combo keys c5/c10/c20 whose sounds land
##       one per sim hit (tack pitch steps 1.1/1.25/1.4) + combo haptics make the 충격파 and the combo read by ear/hand.
##
## Driven by FightFx.on_event (it already gets every drained GameSim event); FightFx.sync passes the state so finisher
## beats follow death_t. Events handled here (view/game.gd must not add its own audio / haptics for them):
##   skill_start, skill_hit, skill_end, skill_denied, tier_ready, item_ready, finisher, combo_break (r3 C1).
## Kept as they are in game.gd: rage_horn (jam t1 sound + rageFire), rage{full} (rageFull + its haptic), kill
## (explosion + villainKill), gone (twinkle), phase kill (superHit + duck) — so the t1 jam horn and an execute kill add
## nothing on top of those. A rage_horn of the same frame as a t1_wave cast (r3 C3 pre-lock t1) is owned here:
## owns_rage_horn() is true then, and game.gd should skip its hornTruck (the 충격파 must not sound like the horn).
## fx keys (fx_key): rage tiers "t1" (jam t1_horn) / "t1_wave" (fight 충격파; "t1" when no recipe) / "t3" / "t5", item
## ids, combo chan "c5" / "c10" / "c20" (from the id prefix c<N>_…). base_key() maps t1_wave → t1 for callers that
## only know the tier paths.
## Sound = config.skills.fx.<key>.sfx [[name, delay, volume, pitch]] when present (split at the skill's impact delay:
## entries before it play on skill_start, the rest on the first skill_hit, delay − impact; combo keys: one delay slot
## per sim hit, see _combo_hit), plus LAYERS: the baked native SFX (sk_*, fin_*; tools/bake-audio.mjs SKILL_SRC).
## Without config.skills.fx the DEFAULT stacks apply; RECIPE_DEFAULT gives t1_wave / c5 / c10 / c20 their banner,
## camera, flash and hitstop (= config C4 values) so the view works before / without config.
## Haptics are real-time (Haptics rule): immediate calls on the event tick, finisher beats via a real-time queue.
## Deterministic: no RNG (pitch steps come from the hit index).

const CONFIG_PATH: String = "res://data/config.json"

## Spec fallback stacks per fx key (= config.skills.fx.<key>.sfx, SKILLS.md §5).
const DEFAULT: Dictionary = {
	"t1": [["hornTruck", 0.0, 1.0, 1.0], ["superHit", 0.12, 0.5, 1.15]],
	# r3 C4/F1: the fight t1 is a shockwave, not a horn (no hornTruck)
	"t1_wave": [["sk_wave", 0.0, 1.0, 1.0], ["superHit", 0.12, 0.7, 1.0], ["explosion", 0.12, 0.35, 1.6]],
	# r3 combo milestones (main_overrides: c5 = the light c10: two tacks, no camera / flash)
	"c5": [["tack", 0.12, 0.85, 1.1], ["tack", 0.18, 0.85, 1.25]],
	"c10": [["tack", 0.15, 1.0, 1.1], ["tack", 0.21, 1.0, 1.25], ["tack", 0.27, 1.0, 1.4], ["crit", 0.27, 0.8, 1.0]],
	"c20": [["whoosh", 0.0, 0.8, 1.6], ["pop", 0.25, 1.0, 1.0], ["crit", 0.25, 0.9, 1.0], ["explosion", 0.25, 0.3, 1.5]],
	"t3": [["launch", 0.0, 0.7, 1.0], ["tack", 0.05, 0.6, 0.9], ["tack", 0.1, 0.6, 1.05], ["tack", 0.15, 0.6, 1.2]],
	"t5": [["rageFull", 0.0, 0.7, 0.8], ["super", 0.0, 0.6, 1.0], ["superHit", 0.35, 1.0, 1.0], ["explosion", 0.35, 0.95, 1.0]],
	"mv_jump": [["whoosh", 0.0, 0.6, 1.3], ["bump", 0.75, 1.0, 0.6], ["explosion", 0.75, 0.3, 1.6]],
	"mv_drone": [["whoosh", 0.0, 0.7, 1.5], ["explosion", 0.7, 0.35, 1.2], ["pop", 0.75, 0.5, 1.1], ["crit", 1.0, 0.6, 1.0]],
	"mv_tow": [["hornShort", 0.0, 0.8, 1.0], ["blink", 0.1, 0.6, 1.0], ["bump", 0.8, 0.9, 0.8], ["crit", 0.8, 0.6, 1.0]],
}
## Native layers on top of the stack: start / hit / hit_n (every multi-hit after the first) / pop (a tyre burst).
const LAYERS: Dictionary = {
	"t1": {"start": [["sk_wave", 0.03, 0.85, 1.0]], "hit": [["crit", 0.0, 0.45, 1.2]]},
	"t1_wave": {"hit": [["crit", 0.0, 0.45, 1.2]]},  # sk_wave is in the stack itself (delay 0)
	# t3 (rvB): the first impact had no sound of its own and sk_carpet peaked 120 ms early (peak 0.08 s into the wav,
	# so 0.32 lands it on the 0.4 s impact).
	"t3": {"start": [["sk_carpet", 0.32, 0.9, 1.0]], "hit": [["explosion", 0.0, 0.55, 1.4], ["superHit", 0.0, 0.5, 1.25]],
		"hit_n": [["hit", 0.0, 0.6, 1.0]], "pop": [["pop", 0.0, 1.0, 1.0], ["crit", 0.03, 0.7, 1.0]]},
	"t5": {"start": [["sk_charge", 0.0, 1.0, 1.0]], "hit": [["sk_wave", 0.0, 0.7, 0.8]]},
	"mv_jump": {"hit": [["sk_land", 0.0, 1.0, 1.0]]},
	"mv_drone": {"start": [["sk_drone", 0.0, 0.9, 1.0]], "hit_n": [["explosion", 0.0, 0.25, 1.3], ["pop", 0.02, 0.4, 1.2]]},
}
const HAPTIC_HIT: Dictionary = {"t1": "skillT1", "t1_wave": "skillT1", "t3": "skillT3Hit", "t5": "skillT5Impact",
	"mv_jump": "itemJumpLand", "mv_drone": "itemDrone", "mv_tow": "itemTow", "c5": "combo5", "c10": "combo10", "c20": "combo20"}
## View recipes used when config.skills.fx has no entry for the key (= the config C4 values; sfx come from DEFAULT).
## Flash contract (all recipes): alpha ≤ 0.45, ≤ 120 ms, never white.
const RECIPE_DEFAULT: Dictionary = {
	"t1_wave": {"banner": "충격파!!", "camera": {"punch": -5.0, "shake": 0.5, "kick": 0.6, "kickDur": 0.12},
		"flash": ["ffd23a", 0.25, 80]},
	"c5": {"banner": "따닥!"},
	"c10": {"banner": "따다닥!"},
	"c20": {"banner": "타이어 저격!", "hitstop": 0.04, "camera": {"punch": -2.0, "shake": 0.3}, "flash": ["ffd23a", 0.15, 60]},
}
## Combo hit delays (sim s after the combo cast) when config.skills.combo.<key>.delays is absent (r3 C1 + main_overrides).
const COMBO_DELAYS: Dictionary = {"c5": [0.12, 0.18], "c10": [0.15, 0.21, 0.27], "c20": [0.25]}
## Hitstop table (real s) when config has no value: t1 0.07, t3 0.11, t5 0.14, c20 0.04 (r3 C4), others 0.
const HITSTOP_DEFAULT: Dictionary = {"t1": 0.07, "t3": 0.11, "t5": 0.14, "c20": 0.04}
const COMBO_KEYS: PackedStringArray = ["c5", "c10", "c20"]
## Finisher cues: [beat, kind, name, volume, pitch] — beats are keys of the finish timeline (FinishBeats).
const FINISH: Dictionary = {
	"rocket": [["lift", "sfx", "fin_rocket", 1.0, 1.0], ["lift", "haptic", "finishRocket"]],
	"balloon": [["lift", "sfx", "fin_balloon", 1.0, 1.0], ["lift", "haptic", "finishBalloon"]],
	"heli": [["settle", "sfx", "fin_heli", 1.0, 1.0], ["settle", "haptic", "finishHeli"]],
	"ufo": [["settle", "sfx", "fin_ufo", 1.0, 1.0], ["beam", "sfx", "super", 0.5, 0.7], ["settle", "haptic", "finishUfo"]],
	"pullover": [["start", "sfx", "blink", 0.8, 1.0]],
}

## Tests: replaces config.skills (null = read res://data/config.json once).
static var override_cfg: Variant = null
static var _cfg_cache: Variant = null

var enabled: bool = true
## Real seconds (wall clock; advance() from FightFx._process with the unscaled delta, or by hand in shots).
var now: float = 0.0
## Last cues (tests / shot RESULT lines): "sfx:<name>@<delay>" / "haptic:<name>".
var cue_log: PackedStringArray = PackedStringArray()
## Last sounds with their full row (tests): {name, delay, vol, pitch}.
var sfx_log: Array[Dictionary] = []
var _queue: Array[Dictionary] = []   # {at, kind, name, vol, pitch}
var _fin: Dictionary = {}            # active finisher {id, target, done: {beat: true}}
var _hit_done: Dictionary = {}       # fx key -> {idx: real now}: one stack per hit index per cast (multi-target hits)
var _wave_frame: int = -1            # process frame of the last t1_wave cast (owns_rage_horn)
var _combo_n: int = 0                # state.skills.combo.n of the last sync (break fallback)
var _combo_phase: String = ""
var _break_at: float = -99.0         # real now of the last comboBreak haptic


## config.skills (or {}): read once, cached; tests set override_cfg.
static func cfg() -> Dictionary:
	if override_cfg is Dictionary:
		return override_cfg
	if _cfg_cache == null:
		_cfg_cache = {}
		if FileAccess.file_exists(CONFIG_PATH):
			var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
			if d is Dictionary and (d as Dictionary).get("skills") is Dictionary:
				_cfg_cache = (d as Dictionary)["skills"]
	return _cfg_cache


## fx key of an event: "t1" (jam t1_horn) / "t1_wave" (fight t1; "t1" without a recipe) / "t3" / "t5" for rage tiers,
## the item id for items, "c5" / "c10" / "c20" for the combo chan (id prefix c<N>, e.g. c10_burst / c20_snipe).
static func fx_key(e: Dictionary) -> String:
	var chan: String = str(e.get("chan", "rage"))
	var id: String = str(e.get("id", ""))
	if chan == "item":
		return id
	var ck: String = combo_key(id)
	if chan == "combo" or not ck.is_empty():
		return ck if not ck.is_empty() else str(e.get("key", id))
	var tier: int = int(e.get("tier", 0))
	if tier <= 0:
		tier = 5 if id.begins_with("t5") else 3 if id.begins_with("t3") else 1 if id.begins_with("t1") else 0
	if tier == 1 and id == "t1_wave":
		return "t1_wave" if not recipe("t1_wave").is_empty() else "t1"
	return "t%d" % tier if tier > 0 else id


## "c10" for "c10_burst" / "c10" (c + digits, then "_" or the end); "" otherwise.
static func combo_key(id: String) -> String:
	if id.length() < 2 or id[0] != "c":
		return ""
	var i: int = 1
	while i < id.length() and id[i] >= "0" and id[i] <= "9":
		i += 1
	if i == 1 or (i < id.length() and id[i] != "_"):
		return ""
	return id.substr(0, i)


static func is_combo(key: String) -> bool:
	return key in COMBO_KEYS or not combo_key(key).is_empty()


## The tier path of a key for callers that only know t1 / t3 / t5 (t1_wave → t1); other keys unchanged.
static func base_key(key: String) -> String:
	return "t1" if key == "t1_wave" else key


## View recipe of a fx key: config.skills.fx.<key> as a whole (banner, flash, camera, sfx, hitstop), else
## RECIPE_DEFAULT.<key> (t1_wave / c5 / c10 / c20), else {}.
static func recipe(key: String) -> Dictionary:
	var fx: Variant = cfg().get("fx", {})
	if fx is Dictionary and (fx as Dictionary).get(key) is Dictionary:
		return (fx as Dictionary)[key]
	return RECIPE_DEFAULT.get(key, {})


## Hitstop (real s) a key's impact asks for: config.skills.t1/t3/t5.hitstop for the rage tiers (t1_wave = t1), the
## recipe's hitstop for the combo keys; HITSTOP_DEFAULT when absent. The sim applies it (skills_sim._impact).
static func hitstop(key: String) -> float:
	var bk: String = base_key(key)
	if bk in ["t1", "t3", "t5"]:
		var t: Variant = cfg().get(bk, {})
		if t is Dictionary and (t as Dictionary).has("hitstop"):
			return float((t as Dictionary)["hitstop"])
		return float(HITSTOP_DEFAULT.get(bk, 0.0))
	return float(recipe(key).get("hitstop", 0.0))  # RECIPE_DEFAULT.c20 carries 0.04 when config has no c20


## Sim delays (s after the combo cast) of each hit of a combo key: config.skills.combo.<key>.delays (or .delay), else
## COMBO_DELAYS (c5 0.12/0.18, c10 0.15/0.21/0.27, c20 0.25).
static func combo_delays(key: String) -> Array:
	var cc: Variant = cfg().get("combo", {})
	if cc is Dictionary and (cc as Dictionary).get(key) is Dictionary:
		var k: Dictionary = (cc as Dictionary)[key]
		if k.get("delays") is Array and not (k["delays"] as Array).is_empty():
			return k["delays"]
		if k.has("delay"):
			return [float(k["delay"])]
	return COMBO_DELAYS.get(key, [0.0])


## Sim delay from the cast to the (first) impact of a fx key.
static func impact_delay(key: String) -> float:
	var c: Dictionary = cfg()
	if is_combo(key):
		return float(combo_delays(key)[0])
	match base_key(key):
		"t1", "t3", "t5":
			var bk: String = base_key(key)
			var t: Variant = c.get(bk, {})
			return float((t as Dictionary).get("delay", {"t1": 0.12, "t3": 0.4, "t5": 0.35}[bk])) if t is Dictionary else float({"t1": 0.12, "t3": 0.4, "t5": 0.35}[bk])
		"mv_jump":
			return float(_item(key).get("hop", 0.75))
		"mv_drone":
			return float(_item(key).get("delay", 0.7))
		"mv_tow":
			return float(_item(key).get("delay", 0.8))
	return 0.0


static func _item(id: String) -> Dictionary:
	var it: Variant = cfg().get("items", {})
	if it is Dictionary and (it as Dictionary).get(id) is Dictionary:
		return (it as Dictionary)[id]
	return {}


## Finish timeline of a finisher id (real s from the kill tick, = config.skills.finish.<id>); legacy BossSim numbers
## when config.skills is absent (rocket launch 0.85, prop finishes settle 0.8 then lift).
static func finish_beats(id: String) -> Dictionary:
	var f: Variant = cfg().get("finish", {})
	var out: Dictionary = {}
	if f is Dictionary and (f as Dictionary).get(id) is Dictionary:
		out = ((f as Dictionary)[id] as Dictionary).duplicate()
	else:
		out = {"rocket": {"settle": 0.5, "lift": 0.85, "twinkle": 2.0, "done": 2.15},
			"balloon": {"settle": 0.8, "lift": 0.8, "twinkle": 3.6, "done": 3.8},
			"heli": {"settle": 0.2, "hook": 0.8, "twinkle": 3.6, "done": 3.8},
			"ufo": {"settle": 0.3, "beam": 0.6, "twinkle": 3.0, "done": 3.2},
			"pullover": {"done": 2.2}}.get(id, {"done": 2.0})
	out["start"] = 0.0
	if not out.has("lift"):
		out["lift"] = float(out.get("hook", out.get("beam", out.get("settle", 0.5))))
	return out


func _process(delta: float) -> void:
	advance(delta)


func advance(dt: float) -> void:
	now += dt
	if _queue.is_empty():
		return
	var keep: Array[Dictionary] = []
	for q: Dictionary in _queue:
		if now + 1e-6 >= float(q["at"]):
			_fire(q)
		else:
			keep.append(q)
	_queue = keep


## Frame sync: finisher beats from the dying villain's death_t; combo break fallback from state.skills.combo.n (a drop
## from ≥ 5 inside the boss phase = comboBreak, when no combo_break event reached us: FightFx may not forward it).
func sync(st: Dictionary) -> void:
	var sk: Variant = st.get("skills")
	var cb: Variant = (sk as Dictionary).get("combo") if sk is Dictionary else null
	var ph: String = str(st.get("phase", ""))
	if cb is Dictionary:
		var n: int = int((cb as Dictionary).get("n", 0))
		if enabled and n < _combo_n and _combo_n >= 5 and ph == "boss" and _combo_phase == "boss":
			_combo_break()
		_combo_n = n
	_combo_phase = ph
	if _fin.is_empty():
		return
	var v: Dictionary = {}
	for q: Variant in st.get("villains", []):
		if int((q as Dictionary).get("id", -2)) == int(_fin["target"]):
			v = q
	if v.is_empty():
		return
	var dt_: float = float(v.get("death_t", 0.0))
	var beats: Dictionary = _fin["beats"]
	for row: Array in FINISH.get(str(_fin["id"]), []):
		var key: String = "%s:%s:%s" % [row[0], row[1], row[2]]
		if (_fin["done"] as Dictionary).has(key) or dt_ + 1e-6 < float(beats.get(str(row[0]), 0.0)):
			continue
		(_fin["done"] as Dictionary)[key] = true
		if str(row[1]) == "sfx":
			_sfx(str(row[2]), 0.0, float(row[3]), float(row[4]))
		else:
			_haptic(str(row[2]))
	if bool(v.get("gone", false)):
		_fin = {}


func on_event(e: Dictionary) -> void:
	if not enabled:
		return
	var ty: String = str(e.get("type", ""))
	match ty:
		"skill_start":
			var key: String = fx_key(e)
			if str(e.get("id", "")) == "t1_horn":
				return  # jam t1: the rage_horn event of the same tick already plays hornTruck + superHit + rageFire
			_hit_done.erase(key)
			if key == "t1_wave":
				_wave_frame = Engine.get_process_frames()
			var d0: float = impact_delay(key)
			for s: Array in _stack(key):
				if float(s[1]) < d0 - 1e-4:
					_sfx(str(s[0]), float(s[1]), float(s[2]), float(s[3]))
			for s: Array in (LAYERS.get(key, {}) as Dictionary).get("start", []):
				_sfx(str(s[0]), float(s[1]), float(s[2]), float(s[3]))
			match key:
				"t5":
					_haptic("skillT5Charge")
					var au: Node = _audio()
					if au != null and au.has_method(&"duck_for"):
						au.call(&"duck_for", 2.6, 0.75)
				"mv_jump":
					_haptic("laneChange")
		"skill_hit":
			var key2: String = fx_key(e)
			var idx: int = int(e.get("idx", 0))
			var killed: bool = bool(e.get("killed", false))
			var done: Dictionary = _hit_done.get(key2, {})
			var again: bool = done.has(idx) and now - float(done[idx]) < 0.25  # same hit on a 2nd target (1-3 duo)
			done[idx] = now
			_hit_done[key2] = done
			if again:
				if int(e.get("popped", 0)) > 0 and key2 != "c20":
					_sfx("pop", 0.0, 0.8, 1.05)
				return
			if is_combo(key2):
				_combo_hit(key2, idx, killed)
				return
			if idx == 0:
				var d1: float = impact_delay(key2)
				for s: Array in _stack(key2):
					var nm: String = str(s[0])
					if float(s[1]) < d1 - 1e-4:
						continue
					if killed and nm in ["superHit", "explosion"]:
						continue  # the kill tick plays them (Audio.phase kill + game.gd kill)
					_sfx(nm, float(s[1]) - d1, float(s[2]), float(s[3]))
				for s: Array in (LAYERS.get(key2, {}) as Dictionary).get("hit", []):
					if killed and str(s[0]) in ["superHit", "explosion"]:
						continue
					_sfx(str(s[0]), float(s[1]), float(s[2]), float(s[3]))
			else:
				for s: Array in (LAYERS.get(key2, {}) as Dictionary).get("hit_n", []):
					_sfx(str(s[0]), float(s[1]), float(s[2]), float(s[3]) * (1.0 + 0.06 * float(idx)))
			if int(e.get("popped", 0)) > 0:
				for s: Array in (LAYERS.get(key2, {}) as Dictionary).get("pop", [["pop", 0.0, 1.0, 1.0]]):
					_sfx(str(s[0]), float(s[1]), float(s[2]), float(s[3]))
				_haptic("tirePop")
			elif not (killed and key2 == "t5"):
				_haptic(str(HAPTIC_HIT.get(key2, "rageHit")))
		"skill_denied":
			_sfx("bump", 0.0, 0.35, 0.55)
			_haptic("skillDenied")
		"combo_break":
			if int(e.get("n", 5)) >= 5:
				_combo_break()
			_combo_n = 0
		"tier_ready":
			match int(e.get("tier", 0)):
				1:
					_sfx("sk_tier1", 0.0, 0.8, 1.0)
					_haptic("tierReady1")
				3:
					_sfx("sk_tier3", 0.0, 0.85, 1.0)
					_haptic("tierReady3")
				5:
					_sfx("sk_tierMax", 0.0, 0.7, 1.0)  # rage{full} of the same tick plays rageFull + its haptic
		"item_ready":
			_sfx("sk_tier1", 0.0, 0.45, 0.75)
			_haptic("tierReady1")
		"finisher":
			start_finish(str(e.get("id", "rocket")), int(e.get("target_id", -1)))
		"kill":
			if bool(e.get("last", true)) and _fin.is_empty() and not str(e.get("finish", "")).is_empty():
				start_finish(str(e.get("finish", "rocket")), int(e.get("id", -1)))


## Combo hit idx of a combo key: the stack's delays ≥ the first hit delay are slots, one per sim hit in order (c10:
## 0.15 → tack 1.1, 0.21 → tack 1.25, 0.27 → tack 1.4 + crit); slots past the last hit play on the last hit, offset by
## their delay difference. The hit haptic (combo5 / combo10 / combo20) goes on idx 0 only; c20's own pop is in its stack
## and combo20 carries the burst, so no extra tirePop.
func _combo_hit(key: String, idx: int, killed: bool) -> void:
	var delays: Array = combo_delays(key)
	var d0: float = float(delays[0])
	var nh: int = maxi(1, delays.size())
	var slots: Array[int] = []
	for s: Array in _stack(key):
		var ms: int = roundi(float(s[1]) * 1000.0)
		if float(s[1]) >= d0 - 1e-4 and not slots.has(ms):
			slots.append(ms)
	slots.sort()
	for s: Array in _stack(key):
		var ms2: int = roundi(float(s[1]) * 1000.0)
		var slot: int = slots.find(ms2)
		if slot < 0 or not (slot == idx or (idx == nh - 1 and slot > idx)):
			continue
		if killed and str(s[0]) in ["superHit", "explosion"]:
			continue
		var base: int = slots[mini(idx, slots.size() - 1)]
		_sfx(str(s[0]), float(ms2 - base) / 1000.0, float(s[2]), float(s[3]))
	for s: Array in (LAYERS.get(key, {}) as Dictionary).get("hit" if idx == 0 else "hit_n", []):
		_sfx(str(s[0]), float(s[1]), float(s[2]), float(s[3]))
	if idx == 0:
		_haptic(str(HAPTIC_HIT.get(key, "crit")))


## comboBreak once per break (the event and the state fallback can both see the same break).
func _combo_break() -> void:
	if now - _break_at < 0.3 and _break_at > -99.0:
		return
	_break_at = now
	_haptic("comboBreak")


## true when a t1_wave cast arrived in this process frame: the rage_horn of the same tick (r3 C3 pre-lock t1 also
## clears the shoulder) is part of the 충격파 — game.gd plays no hornTruck / superHit for it (SkillCues owns the sound).
func owns_rage_horn() -> bool:
	return _wave_frame >= 0 and Engine.get_process_frames() == _wave_frame


## A finisher began on target_id (the kill tick): its beats fire from sync() as death_t passes them.
func start_finish(id: String, target_id: int) -> void:
	if not _fin.is_empty() and int(_fin["target"]) == target_id:
		_fin["id"] = id  # the finisher event after the kill of the same tick: same villain, keep the beats done
		_fin["beats"] = finish_beats(id)
		return
	_fin = {"id": id, "target": target_id, "beats": finish_beats(id), "done": {}}


func _stack(key: String) -> Array:
	var r: Dictionary = recipe(key)
	if r.get("sfx") is Array:
		return r["sfx"]
	return DEFAULT.get(key, [])


func _audio() -> Node:
	return get_node_or_null(^"/root/Audio") if is_inside_tree() else null


func _sfx(name: String, delay: float, vol: float, pitch: float) -> void:
	_log("sfx:%s@%.2f" % [name, delay])
	sfx_log.append({"name": name, "delay": delay, "vol": vol, "pitch": pitch})
	if sfx_log.size() > 96:
		sfx_log = sfx_log.slice(sfx_log.size() - 96)
	var au: Node = _audio()
	if au != null and au.has_method(&"sfx"):
		au.call(&"sfx", StringName(name), {"delay": maxf(0.0, delay), "volume": vol, "pitch": pitch})


func _haptic(name: String, delay: float = 0.0) -> void:
	if delay > 1e-4:
		_queue.append({"at": now + delay, "kind": "haptic", "name": name})
		return
	_fire({"kind": "haptic", "name": name})


func _fire(q: Dictionary) -> void:
	_log("haptic:%s" % str(q["name"]))
	var h: Node = get_node_or_null(^"/root/Haptics") if is_inside_tree() else null
	if h != null and h.has_method(&"haptic"):
		h.call(&"haptic", str(q["name"]))


func _log(s: String) -> void:
	cue_log.append(s)
	if cue_log.size() > 96:
		cue_log = cue_log.slice(cue_log.size() - 96)
