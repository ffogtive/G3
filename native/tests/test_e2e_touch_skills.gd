extends RefCounted
## E2E (device feedback 2026-10-14 round 2 #4 + #3): every rage tier and both items used once in 1-1 through real
## touches on the HUD rects (tests/skills_touch_run.gd), native traffic and the GDScript fallback (the iPhone path).
## 가설: ❓ view/game.gd wiring (LaneInput 분노 / item1 / item2 / skip → GameSim → skill events → Hud, FightFx (SkillFx +
##       SkillCues), CameraRig) lets a touch player cast t1 (jam + fight), mv_jump, t3, mv_drone and an executing t5,
##       see the equipped finisher, skip it, and reach the result card — with 압정 held the whole fight and 0 honks.
##   godot47 --headless --path native -s res://tests/run_tests.gd -- --suite=e2e --filter=touch_skills
## r3 C3: a second run per backend taps the 분노 rect in the boss phase BEFORE the front lock (the iPhone complaint
## "분노 채워서 버튼 누르는데 범위에 안 닿아"): the tap must be a t1_wave that takes villain HP (+ the rage_horn shoulder
## clear, tagged via t1_wave), with the HUD on the fight face.

const SUITE := "e2e"
const GameScene: PackedScene = preload("res://view/game.tscn")
const Run := preload("res://tests/skills_touch_run.gd")
const LOADOUT: Dictionary = {"finish": "rocket", "items": ["mv_jump", "mv_drone"], "jump": true, "drone": true}

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " e2e_touch_skills: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	var au: Node = tree.root.get_node_or_null(^"Audio")
	if au != null:
		au.set(&"manual_clock", true)
	var modes: Array[bool] = [true]
	if TrafficBridge.native_available():
		modes.push_front(false)
	for fb: bool in modes:
		await _one(tree, fb, 1007)
		await _prelock(tree, fb, 1007)
	if au != null:
		au.set(&"manual_clock", false)
	return _fails


static func make(tree: SceneTree, parent: Node, fb: bool, sd: int) -> Game:
	var g: Game = GameScene.instantiate() as Game
	g.manual = true
	g.with_debug_panel = false
	g.seed = sd
	g.autoplay = true
	g.traffic_mode = "fallback" if fb else "auto"
	g.loadout = LOADOUT.duplicate(true)
	parent.add_child(g)
	return g


func _one(tree: SceneTree, fb: bool, sd: int) -> void:
	var tag: String = "%s seed %d" % ["fallback" if fb else "native", sd]
	var g: Game = make(tree, tree.root, fb, sd)
	await tree.process_frame
	await tree.process_frame
	var t0: int = Time.get_ticks_msec()
	var au: Node = g.audio
	var played0: int = int(au.get(&"played")) if au != null else 0
	var r = Run.new(g, tree.root)
	await r.run()
	var n: Dictionary = r.notes
	_check(g.sim.bridge.is_native() != fb, "%s: runs the %s traffic" % [tag, "fallback" if fb else "native"])
	_check(r.errors.is_empty(), "%s: run completed (%s)" % [tag, ", ".join(r.errors)])
	var zn: Dictionary = n.get("zones", {})
	_check(bool(zn.get("items", false)) and (zn.get("overlaps", ["?"]) as PackedStringArray).is_empty(),
		"%s: item1 / item2 zones registered, all touch zones disjoint %s" % [tag, ",".join(zn.get("overlaps", PackedStringArray()))])
	var j: Dictionary = n.get("jam_t1", {})
	_check(bool(j.get("ok", false)) and str(j.get("id", "")) == "t1_horn" and bool(j.get("rage_horn", false)) and int(j.get("face", 0)) == 1,
		"%s: jam 분노 tap → t1_horn + rage_horn, HUD face t%d" % [tag, int(j.get("face", 0))])
	_check(int(n.get("jam_fire_honks", -1)) == 0, "%s: 압정 held in the jam → %d honks" % [tag, int(n.get("jam_fire_honks", -1))])
	for row: Array in [["t1", 1, "t1_wave"], ["t3", 3, "t3_carpet"], ["t5", 5, "t5_finish"]]:
		var d: Dictionary = n.get(row[0], {})
		_check(bool(d.get("ok", false)) and str(d.get("id", "")) == row[2] and bool(d.get("hit", false)) and int(d.get("face", 0)) == int(row[1])
			and bool(d.get("fire_held", false)),
			"%s: 분노 tap (압정 held) → %s tier %d hit=%s, HUD face showed t%d" % [tag, str(d.get("id", "?")), int(d.get("tier", 0)),
			d.get("hit", false), int(d.get("face", 0))])
	for row: Array in [["jump", "mv_jump"], ["drone", "mv_drone"]]:
		var d2: Dictionary = n.get(row[0], {})
		_check(bool(d2.get("ok", false)) and str(d2.get("id", "")) == row[1] and bool(d2.get("hit", false)) and bool(d2.get("fire_held", false)),
			"%s: item tap (압정 held) → %s hit=%s fire still held=%s" % [tag, str(d2.get("id", "?")), d2.get("hit", false), d2.get("fire_held", false)])
	var t3fx: Dictionary = (n.get("t3", {}) as Dictionary).get("fx", {})
	_check(int(t3fx.get("tacks", 0)) > 0 or int(t3fx.get("decals", 0)) > 0, "%s: t3 → SkillFx carpet (tacks %d, decals %d)" % [tag,
		int(t3fx.get("tacks", 0)), int(t3fx.get("decals", 0))])
	var t5: Dictionary = n.get("t5", {})
	_check(bool(t5.get("killed", false)) and float(t5.get("execute_line", 0.0)) > 0.0,
		"%s: t5 at MAX under the execute line kills (HUD execute line %.2f)" % [tag, float(t5.get("execute_line", 0.0))])
	var fin: Dictionary = n.get("finisher", {})
	var cues: Array = fin.get("cues", [])
	var cue_txt: String = " ".join(PackedStringArray(cues))
	_check(bool(fin.get("ok", false)) and str(fin.get("id", "")) == "rocket" and str(fin.get("cam", "")) == "rocket" and str(fin.get("hud", "")) == "rocket",
		"%s: finisher %s → camera %s, HUD face %s" % [tag, str(fin.get("id", "?")), str(fin.get("cam", "?")), str(fin.get("hud", "?"))])
	_check(cue_txt.contains("haptic:skillT5Charge") and cue_txt.contains("sfx:") and cue_txt.contains("haptic:skillT3Hit"),
		"%s: SkillCues played the skill audio / haptics (%d cues)" % [tag, cues.size()])
	var played: int = (int(au.get(&"played")) if au != null else 0) - played0
	_check(au == null or played > 30, "%s: Audio played %d SFX over the run" % [tag, played])
	var sk: Dictionary = n.get("skip", {})
	_check(bool(sk.get("ok", false)) and r.hint_mismatch == 0, "%s: open-screen tap while armed → skip {%s}; HUD skip hint = sim skip_ready on every frame (%d off)" % [
		tag, str(sk.get("what", "")), r.hint_mismatch])
	_check(int(n.get("fight_honks", -1)) == 0 and not r.horn_down_seen and not r.fire_drop_seen,
		"%s: no honk bleed (fight honks %d, horn down %s), 압정 never dropped by another tap" % [tag, int(n.get("fight_honks", -1)), r.horn_down_seen])
	_check(g.phase == &"result" and g.hud.card_open(), "%s: result card" % tag)
	var starts: Dictionary = {}
	var casts: PackedStringArray = []
	for e: Dictionary in r.events:
		if str(e.get("type", "")) == "skill_start":
			if not str(e.get("_ph", "")).ends_with("/pilot"):  # r3 C3: the autopilot's own pre-lock taps are t1_wave now
				starts[str(e.get("id", ""))] = int(starts.get(str(e.get("id", "")), 0)) + 1
			casts.append("%s@%s" % [str(e.get("id", "")), str(e.get("_ph", ""))])
	_check(int(starts.get("t1_wave", 0)) == 1 and int(starts.get("t3_carpet", 0)) == 1 and int(starts.get("t5_finish", 0)) == 1,
		"%s: each fight tier exactly once by touch (t3 was a 0.2 s hold) %s" % [tag, starts])
	print("INFO e2e_touch_skills: %s casts %s" % [tag, " ".join(casts)])
	print("INFO e2e_touch_skills: %s topped up [%s] boss %.1f s phases %s (%d ms wall)" % [tag, "; ".join(r.topped),
		float((g.st.get("result", {}) as Dictionary).get("boss_time_s", 0.0)), ",".join(g.phase_log), Time.get_ticks_msec() - t0])
	g.event_tap = Callable()
	g.queue_free()
	await tree.process_frame


## r3 C3: the autopilot drives to the boss phase; before the lock a human finger taps 분노 at 1 segment.
func _prelock(tree: SceneTree, fb: bool, sd: int) -> void:
	var tag: String = "%s seed %d pre-lock" % ["fallback" if fb else "native", sd]
	var g: Game = make(tree, tree.root, fb, sd)
	await tree.process_frame
	await tree.process_frame
	var r = Run.new(g, tree.root)
	var sim: GameSim = g.sim
	var reached: bool = r.until(func() -> bool: return g.phase == &"boss" and not sim.front_locked and sim.boss.any_alive(), 100.0)
	_check(reached, "%s: autopilot reaches the boss phase before the lock" % tag)
	if not reached:
		g.queue_free()
		await tree.process_frame
		return
	r.hand_over()
	r.want_tier(1)
	var hp0: float = 0.0
	for v: Dictionary in sim.boss.alive():
		hp0 += float(v["hp"])
	var face: String = str(((g.st.get("skills", {}) as Dictionary)).get("face", ""))
	var locked_at_tap: bool = sim.front_locked
	var e: Dictionary = r.cast_rage(1, "pre_t1")
	var i0: int = int((r.notes["pre_t1"] as Dictionary)["i0"])
	var hit: Dictionary = r.wait_hit(i0, "t1_wave", 1.0)
	var hp1: float = 0.0
	for v: Dictionary in sim.boss.villains:
		hp1 += maxf(0.0, float(v["hp"]))
	var rh: Dictionary = r.ev_since(i0, "rage_horn")
	_check(not locked_at_tap and str(e.get("id", "")) == "t1_wave" and not hit.is_empty() and hp1 < hp0 - 0.5,
		"%s: 분노 rect tap → %s, villain HP %.1f → %.1f (skill_hit %s)" % [tag, str(e.get("id", "?")), hp0, hp1, str(not hit.is_empty())])
	_check(not rh.is_empty() and str(rh.get("via", "")) == "t1_wave" and r.ev_since(i0, "skill_denied").is_empty(),
		"%s: same tap clears the shoulder (rage_horn via %s), no denial" % [tag, str(rh.get("via", "?"))])
	_check(face == "wave" and int((r.notes["pre_t1"] as Dictionary).get("face", 0)) == 1,
		"%s: HUD before the tap: state face '%s', next tier t%d" % [tag, face, int((r.notes["pre_t1"] as Dictionary).get("face", 0))])
	g.event_tap = Callable()
	g.queue_free()
	await tree.process_frame
