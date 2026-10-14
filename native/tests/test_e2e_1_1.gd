extends RefCounted
## E2E 1-1 (NATIVE_PORT M1b 합격, DESIGN_REVIEW P0 #1 #2 #6): the real game.tscn on GameSim, headless, played to the
## result card.
##   가설: game.gd wiring (fixed tick → GameSim → events → HUD / FX / audio / haptics → result card) completes 1-1 on
##         5 seeds with the autopilot, the 압정 button path (LaneInput fire:down → GameSim fire → hit / miss) works
##         when a human holds it, and a wreck in the fight goes fail card → retry → result with the tow on the card.
## Runs in its own suite (tools/native-check.sh e2e step): godot47 --headless --path native -s res://tests/run_tests.gd
##   -- --suite=e2e

const SUITE := "e2e"
const GameScene: PackedScene = preload("res://view/game.tscn")
const SEEDS: Array[int] = [1007, 3, 11, 42, 77]
const LIMIT_S: float = 150.0
const FRAME: int = 4                 # view refresh every 4 ticks (30 fps of sim time)
const ORDER: Array[StringName] = [&"intro", &"jam", &"boss", &"kill", &"release", &"result"]

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " e2e_1_1: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	var au: Node = tree.root.get_node_or_null(^"Audio")
	if au != null:
		au.set(&"manual_clock", true)  # the audio clock follows sim real time (voice gaps / delays are wall-clock on device)
	for sd: int in SEEDS:
		await _autoplay_run(tree, sd)
	await _button_run(tree)
	await _retry_run(tree)
	if au != null:
		au.set(&"manual_clock", false)
	return _fails


func _make(tree: SceneTree, sd: int, auto: bool) -> Game:
	var g: Game = GameScene.instantiate() as Game
	g.manual = true
	g.with_debug_panel = false
	g.seed = sd
	g.autoplay = auto
	tree.root.add_child(g)
	return g


## Advance until cond() or the sim-time limit; returns whether cond held.
func _until(g: Game, cond: Callable, limit_s: float) -> bool:
	var end: float = g.sim.real_time + limit_s
	var au: Node = g.audio
	while g.sim.real_time < end:
		g.advance_ticks(FRAME)
		if au != null:
			au.call(&"advance", FRAME / 120.0)
		if bool(cond.call()):
			return true
	return false


func _in_order(log: Array[StringName]) -> bool:
	var k: int = 0
	for p: StringName in log:
		if k < ORDER.size() and p == ORDER[k]:
			k += 1
	return k == ORDER.size()


func _autoplay_run(tree: SceneTree, sd: int) -> void:
	var g: Game = _make(tree, sd, true)
	var t0: int = Time.get_ticks_msec()
	var acc: Dictionary = {"err": 0.0, "reticle": false, "fire_btn": false}  # lambdas capture locals by value
	var reached: bool = _until(g, func() -> bool:
		if g.phase == &"boss":
			var v: Dictionary = (g.st["villains"] as Array)[0]
			var want: Vector3 = g.road.position(float(v["s"]), float(v["x"]))
			var got: Vector3 = g.villain_views[0].global_position
			acc["err"] = maxf(float(acc["err"]), Vector2(got.x - want.x, got.z - want.z).length())
			if g.sim.front_locked and g.hud.reticle.on_screen:
				acc["reticle"] = true
			if g.hud.button_sizes_pt().has("fire") and g.hud.lock_active:
				acc["fire_btn"] = true
		return g.phase == &"result" and g.hud.card_open(), LIMIT_S)
	var villain_err: float = float(acc["err"])
	var reticle_seen: bool = bool(acc["reticle"])
	var fire_btn: bool = bool(acc["fire_btn"])
	var res: Dictionary = g.st.get("result", {})
	var ec: Dictionary = g.event_counts
	print("INFO e2e_1_1: seed %d phases %s sim %.1f s boss %.1f s stars %d hp %d tows %d events fire=%d hit=%d miss=%d kill=%d sfx=%d haptics=%d (%d ms wall)" % [
		sd, ",".join(g.phase_log), g.sim.real_time, float(res.get("boss_time_s", 0.0)), int(res.get("stars", 0)), int(res.get("hp", 0)),
		int(res.get("tows", 0)), int(ec.get("fire", 0)), int(ec.get("hit", 0)), int(ec.get("miss", 0)), int(ec.get("kill", 0)),
		g.sfx_played, g.haptic_calls, Time.get_ticks_msec() - t0])
	_check(reached and _in_order(g.phase_log), "seed %d: intro → jam → boss → kill → release → result card within %.0f s (%.1f s)" % [
		sd, LIMIT_S, g.sim.real_time])
	_check(int(ec.get("fire", 0)) > 0 and int(ec.get("hit", 0)) > 0 and int(ec.get("kill", 0)) >= 1 and int(ec.get("release", 0)) == 1,
		"seed %d: fight events reach the view (fire %d, hit %d, kill %d, release %d)" % [sd, int(ec.get("fire", 0)), int(ec.get("hit", 0)),
		int(ec.get("kill", 0)), int(ec.get("release", 0))])
	_check(villain_err < 0.05 and reticle_seen and fire_btn, "seed %d: villain view follows the boss sim (max err %.3f m), reticle on screen after the lock, 압정 button up" % [
		sd, villain_err])
	_check(g.sfx_played > 20 and g.haptic_calls > 10, "seed %d: SFX (%d) and haptics (%d) fire from events" % [sd, g.sfx_played, g.haptic_calls])
	_check(not res.is_empty() and int(res.get("stars", 0)) >= 1 and float(res.get("time_s", 0.0)) > 0.0 and g.hud.result_card != null \
		and g.hud.result_card.is_open(), "seed %d: honest result card open (★%d, %.1f s, min HP %d)" % [sd, int(res.get("stars", 0)),
		float(res.get("time_s", 0.0)), int(res.get("min_hp", 0))])
	g.queue_free()
	await tree.process_frame


## A human on the 압정 button: autopilot to the front lock in range, then hand over and hold fire through LaneInput.
func _button_run(tree: SceneTree) -> void:
	var g: Game = _make(tree, 1007, true)
	var locked: bool = _until(g, func() -> bool:
		return g.phase == &"boss" and g.sim.front_locked and bool((g.st["lock"] as Dictionary).get("in_range", false)), 90.0)
	if not locked:
		_check(false, "button run: never got locked in range")
		g.queue_free()
		await tree.process_frame
		return
	g.sim.autopilot = null
	g.autoplay = false
	g.sim.input(&"fire", false)
	g.advance_ticks(FRAME)
	var f0: int = int(g.event_counts.get("fire", 0))
	var h0: int = int(g.event_counts.get("hit", 0)) + int(g.event_counts.get("miss", 0))
	g.input.inject("fire:down")
	_until(g, func() -> bool: return false, 1.2)
	var held: bool = g.hud.fire_down
	g.input.inject("fire:up")
	g.advance_ticks(FRAME * 4)
	var fired: int = int(g.event_counts.get("fire", 0)) - f0
	var landed: int = int(g.event_counts.get("hit", 0)) + int(g.event_counts.get("miss", 0)) - h0
	# r3 final: the volley keeps going weapons.tack.holdGrace s after the button is let go (a short thumb lift), then stops
	var grace: float = float(((g.sim.wc.get("tack", {}) as Dictionary).get("holdGrace", 0.0)))
	g.advance_ticks(ceili(grace * 120.0) + 2)
	var f1: int = int(g.event_counts.get("fire", 0))
	g.advance_ticks(120)
	_check(held and fired >= 3 and landed >= 2, "압정 held 1.2 s via LaneInput → %d fire events, %d hits / misses, HUD shows it held" % [fired, landed])
	_check(int(g.event_counts.get("fire", 0)) == f1, "released → no more tacks after holdGrace %.2f s" % grace)
	g.queue_free()
	await tree.process_frame


## Wreck in the fight → fail card → card retry (Hud.card_choice path) → back in the jam → result card counts the tow.
func _retry_run(tree: SceneTree) -> void:
	var g: Game = _make(tree, 3, true)
	if not _until(g, func() -> bool: return g.phase == &"boss" and g.sim.front_locked and g.sim.phase_real > 3.0, 90.0):
		_check(false, "retry run: never reached the locked fight")
		g.queue_free()
		await tree.process_frame
		return
	var pilot: Autopilot = g.sim.autopilot
	g.sim.autopilot = null  # it would press retry on the fail card at once
	g.sim.input(&"fire", false)
	g.sim.apply_damage(9999.0, "원흉 컵 투척 직격", "throw")
	var failed: bool = _until(g, func() -> bool: return g.phase == &"fail" and g.hud.card_open(), 10.0)
	_check(failed and g.hud.fail_card != null and g.hud.fail_card.is_open(), "HP 0 → wreck → fail card open (phase %s)" % g.phase)
	g.hud.card_choice.emit(&"retry")
	g.advance_ticks(FRAME)
	var back: bool = g.phase_log.size() >= 2 and g.phase_log[g.phase_log.size() - 1] in [&"jam", &"boss"] and &"jam" in g.phase_log.slice(g.phase_log.rfind(&"fail"))
	_check(back and int(g.event_counts.get("retry", 0)) == 1 and not g.hud.card_open() and g.input.enabled,
		"card retry → GameSim retry → jam (33 m behind the villain → boss), card closed, input back on (phases %s)" % ",".join(g.phase_log))
	g.sim.autopilot = pilot
	var done: bool = _until(g, func() -> bool: return g.phase == &"result" and g.hud.card_open(), LIMIT_S)
	var res: Dictionary = g.st.get("result", {})
	_check(done and int(res.get("tows", 0)) == 1 and int(res.get("min_hp", 100)) == 0 and not bool((res.get("missions", [{}, {"done": true}]) as Array)[1].get("done", true)),
		"after the retry the result card is honest: tows %d, min HP %d, ★2 failed, total %.1f s" % [int(res.get("tows", 0)),
		int(res.get("min_hp", -1)), float(res.get("time_s", 0.0))])
	g.queue_free()
	await tree.process_frame
