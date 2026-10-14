extends RefCounted
## Phase audio (NATIVE_PORT 3-8 오디오; device report "배경음도 없고"): game.tscn on GameSim (autopilot, seed 1007) with
## the Audio autoload on a manual clock that follows sim real time. Every view frame records (phase, music, ambience):
##   가설: game.gd routes each GameSim phase event to Audio.phase() (web enterPhase), so intro / jam play mus_jam with
##         the jam ambience, the fight plays mus_boss, the release cheer retires it and mus_release enters (after the
##         0.6 s web delay, on the cheer bar grid) and keeps playing through cruise / result with the wind ambience;
##         the engine loop runs while driving.

const GameScene: PackedScene = preload("res://view/game.tscn")
const FRAME: int = 4
## phase → [music, ambience] that must hold at the END of that phase (null = not checked).
const WANT_END: Dictionary = {
	&"intro": [&"jam", &"jam"], &"jam": [&"jam", &"jam"], &"boss": [&"boss", &"jam"], &"kill": [&"boss", &"jam"],
	&"release": [&"release", &""], &"cruise": [&"release", &"free"],
}

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " phase_audio: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	var au: Node = tree.root.get_node_or_null(^"Audio")
	if au == null:
		print("SKIP phase_audio: no Audio autoload")
		return 0
	var was_muted: bool = bool(au.call(&"is_muted"))
	au.call(&"set_muted", false)
	au.set(&"manual_clock", true)
	au.call(&"music", &"")
	au.call(&"ambience", &"")
	au.call(&"advance", 1.0)
	var g: Game = GameScene.instantiate() as Game
	g.manual = true
	g.with_debug_panel = false
	g.seed = 1007
	g.autoplay = true
	tree.root.add_child(g)
	var last: Dictionary = {}          # phase → [music, ambience] seen on its last frame
	var musics: Array[StringName] = []  # distinct music values in order
	var first_release_music: float = -1.0
	var release_t0: float = -1.0
	var engine_ok: bool = false
	while g.sim.real_time < 150.0 and g.phase != &"result":
		g.advance_ticks(FRAME)
		au.call(&"advance", FRAME / 120.0)
		var m: StringName = au.call(&"current_music")
		var a: StringName = au.call(&"current_ambience")
		last[g.phase] = [m, a]
		if musics.is_empty() or musics[musics.size() - 1] != m:
			musics.append(m)
		if g.phase == &"release" and release_t0 < 0.0:
			release_t0 = g.sim.real_time
		if m == &"release" and first_release_music < 0.0 and release_t0 >= 0.0:
			first_release_music = g.sim.real_time - release_t0
		if g.phase == &"jam" and not engine_ok and g.sim.phase_real > 2.0:
			# the live _process path: engine(v, boost) every frame while driving
			g.manual = false
			g._process(1.0 / 60.0)
			g.manual = true
			au.call(&"advance", 0.1)
			var es: Dictionary = (au.call(&"debug_state") as Dictionary).get("engine", {})
			engine_ok = float(es.get("pitch", 0.0)) > 0.0 and float(es.get("lo", 0.0)) > 0.0
	for k: int in 30:  # 1 s into the result
		g.advance_ticks(FRAME)
		au.call(&"advance", FRAME / 120.0)
	last[&"result"] = [au.call(&"current_music"), au.call(&"current_ambience")]
	print("INFO phase_audio: phases %s, music sequence %s, release music %.2f s after the release phase, last %s" % [
		",".join(g.phase_log), ",".join(musics), first_release_music, JSON.stringify(last)])
	_check(g.phase == &"result", "the run reached the result (%s)" % g.phase)
	for ph: StringName in WANT_END:
		var want: Array = WANT_END[ph]
		var got: Array = last.get(ph, [&"?", &"?"])
		_check(got[0] == want[0] and got[1] == want[1], "end of %s: music %s / ambience %s (want %s / %s)" % [ph, got[0], got[1], want[0], want[1]])
	_check((last[&"result"] as Array)[0] == &"release", "result: release music keeps playing (web keeps it through the card)")
	_check(musics.slice(0, 4) == [&"jam", &"boss", &"", &"release"] if musics.size() >= 4 else false,
		"music only changes at phase edges: jam → boss → (cheer) → release (%s)" % ",".join(musics))
	_check(first_release_music >= 0.55 and first_release_music < 0.75,
		"release music is requested %.2f s after the cheer (web main.js: setTimeout 600 ms; Audio then enters on the cheer bar)" % first_release_music)
	_check(engine_ok, "engine loop runs while driving (Audio.engine every frame from game._process)")
	g.queue_free()
	await tree.process_frame
	au.call(&"music", &"")
	au.call(&"ambience", &"")
	au.call(&"advance", 1.0)
	au.set(&"manual_clock", false)
	au.call(&"set_muted", was_muted)
	return _fails
