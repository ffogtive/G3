extends SceneTree
## Xvfb shots of the integrated 1-1 (game.tscn on GameSim, autopilot) at each phase — the device build's wiring, not
## the shot_fight rig:
##   xvfb-run -a -s "-screen 0 1280x1024x24" godot47 --path native --rendering-method mobile --audio-driver Dummy \
##       -s res://tests/shot_game.gd -- --out=/abs/dir [--seed=1007] [--size=585x1266] [--safe-pt=59,34]
## Saves final_jam, final_boss_approach (villain ahead, hint chip), final_boss_lock (reticle in range, tacks),
## final_kill, final_release, final_result (card at its end). Prints RESULT lines per shot.
## Exit 0 all moments reached · 1 a moment missing / reticle off screen · 2 cannot render.

const GameScene: PackedScene = preload("res://view/game.tscn")
const FRAME: int = 4

var _out: String = ""
var _seed: int = 1007
var _size := Vector2i(585, 1266)
var _vp: SubViewport
var _g: Game
var _ok: bool = true


func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		var v: String = kv[1] if kv.size() > 1 else "1"
		match kv[0]:
			"out":
				_out = v
			"seed":
				_seed = v.to_int()
			"size":
				var p: PackedStringArray = v.split("x")
				_size = Vector2i(p[0].to_int(), p[1].to_int())
	_main.call_deferred()


func _main() -> void:
	if _out.is_empty() or DisplayServer.get_name() == "headless":
		print("FAIL shot_game: need --out=<dir> and a real display (xvfb-run, no --headless)")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_vp = SubViewport.new()
	_vp.size = _size
	_vp.size_2d_override = Vector2i(540, roundi(540.0 * float(_size.y) / float(_size.x)))
	_vp.size_2d_override_stretch = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.audio_listener_enable_3d = false
	root.add_child(_vp)
	_g = GameScene.instantiate() as Game
	_g.manual = true
	_g.seed = _seed
	_g.autoplay = true
	_g.with_debug_panel = false
	_vp.add_child(_g)
	var lock_ok: Callable = func() -> bool:
		return _g.phase == &"boss" and _g.sim.front_locked and bool((_g.st["lock"] as Dictionary).get("in_range", false)) \
			and _g.hud.reticle.locked_for() > 0.8 and int(_g.fx.counts().get("glow", 0)) > 6
	var moments: Array = [
		["final_jam", func() -> bool: return _g.phase == &"jam" and _g.sim.phase_real > 3.0],
		["final_boss_approach", func() -> bool: return _g.phase == &"boss" and not _g.sim.front_locked and _g.sim.phase_real > 1.2],
		["final_boss_lock", lock_ok],
		["final_attack", func() -> bool: return _g.phase != &"boss" or int(_g.hazards.shown["beams"]) + int(_g.hazards.shown["items"]) \
			+ int(_g.hazards.shown["waves"]) > 0],
		["final_kill", func() -> bool: return _g.phase == &"kill" and _g.sim.phase_real > 0.35],
		["final_release", func() -> bool: return _g.phase == &"release" and _g.sim.phase_real > 1.75],
		["final_result", func() -> bool: return _g.phase == &"result" and _g.hud.card_open()],
	]
	for m: Array in moments:
		if not _until(m[1] as Callable, 90.0):
			print("FAIL shot_game: never reached %s (phase %s t=%.1f)" % [m[0], _g.phase, _g.sim.real_time])
			_ok = false
			continue
		if str(m[0]) == "final_attack" and _g.phase != &"boss":
			print("INFO shot_game: no telegraphed attack on screen before the kill (hazards never drawn)")
			continue
		if str(m[0]) == "final_result":
			_g.hud.result_card.seek(ResultCard.T_END)
		await _shot(str(m[0]))
		if str(m[0]) == "final_boss_lock" and not _g.hud.reticle.on_screen:
			print("FAIL shot_game: reticle off screen at the lock")
			_ok = false
	print("RESULT phases=%s events=%s sfx=%d haptics=%d" % [",".join(_g.phase_log), JSON.stringify(_g.event_counts), _g.sfx_played, _g.haptic_calls])
	print("RESULT ok=%s" % _ok)
	quit(0 if _ok else 1)


func _until(cond: Callable, limit_s: float) -> bool:
	var end: float = _g.sim.real_time + limit_s
	while _g.sim.real_time < end:
		_g.advance_ticks(FRAME)
		if bool(cond.call()):
			return true
	return false


func _shot(name: String) -> void:
	for i: int in 3:
		_g.render_step(0.0)
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = _vp.get_texture().get_image()
	img.save_png(_out.path_join(name + ".png"))
	var st: Dictionary = _g.st
	print("RESULT shot %s phase=%s t=%.2f hint='%s' lock=%s reticle_on=%s hazards=%s fx=%s card=%s draws=%d" % [name, _g.phase,
		_g.sim.real_time, str(st.get("hint", "")), JSON.stringify(st.get("lock", {})), _g.hud.reticle.on_screen,
		JSON.stringify(_g.hazards.shown), JSON.stringify(_g.fx.counts()), _g.hud.card_open(),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))])
