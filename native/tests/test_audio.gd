extends RefCounted
## Audio bake + autoload (NATIVE_PORT 3-8 오디오, M1c). 가설: every file in audio_bake.json loads as an AudioStream
## with the manifest's duration and loop flags (music/amb/engine loop, SFX one-shot), the bus layout carries the web
## dynamics on Master, and the Audio autoload's crossfade / voice limits / engine / duck behave like audio.js.

const MANIFEST: String = "res://audio/audio_bake.json"
## every name game/js plays (grep "audio.play(" + cheerHorns) — the native game must find them all
const WEB_NAMES: Array[String] = ["horn", "hornShort", "hornTruck", "hornAngry", "tack", "hit", "pop", "explosion",
	"whoosh", "bump", "laneChange", "ui", "uiConfirm", "rageFull", "super", "superHit", "brakeScreech", "warn", "throw",
	"splat", "launch", "twinkle", "stageClear", "star", "cutin", "blink", "tauntBlip", "go", "cheer"]

var _fails: int = 0


func _check(ok: bool, msg: String) -> void:
	print(("PASS " if ok else "FAIL ") + msg)
	if not ok:
		_fails += 1


func run() -> int:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	_check(parsed is Dictionary, "audio: manifest %s parses" % MANIFEST)
	if not parsed is Dictionary:
		return _fails
	var man: Dictionary = parsed
	_files(man)
	_buses()
	await _autoload(man)
	return _fails


func _load(path: String) -> AudioStream:
	return load(path) as AudioStream if ResourceLoader.exists(path) else null


func _files(man: Dictionary) -> void:
	var bad: PackedStringArray = PackedStringArray()
	var total: int = 0
	var n: int = 0
	for n_sfx: String in man["sfx"]:
		var m: Dictionary = man["sfx"][n_sfx]
		for f: String in m["files"]:
			var st: AudioStreamWAV = _load("res://audio/" + f) as AudioStreamWAV
			n += 1
			var sec: float = float(m["seconds"])   # variants: the longest take
			var len_ok: bool = st != null and st.get_length() > 0.0 and st.get_length() <= sec * 1.02 + 0.02 \
				and (m["files"].size() > 1 or absf(st.get_length() - sec) <= sec * 0.02 + 0.02)
			if not len_ok or st.loop_mode != AudioStreamWAV.LOOP_DISABLED:
				bad.append(f)
	for group: String in ["music", "amb", "engine"]:
		for k: String in man[group]:
			if not (man[group][k] is Dictionary) or not (man[group][k] as Dictionary).has("file"):
				continue
			var m: Dictionary = man[group][k]
			var path: String = "res://audio/" + str(m["file"])
			var st: AudioStream = _load(path)
			n += 1
			var ok: bool = st != null and st.get_length() > 0.0 and absf(st.get_length() - float(m["seconds"])) < 0.02
			if st is AudioStreamOggVorbis:
				var o: AudioStreamOggVorbis = st
				ok = ok and o.loop and absf(o.loop_offset - float(m["loop_offset"])) < 1e-3 and o.bpm == 0.0
			elif st is AudioStreamWAV:
				var w: AudioStreamWAV = st
				ok = ok and w.loop_mode == AudioStreamWAV.LOOP_FORWARD and w.loop_begin == 0
			else:
				ok = false
			ok = ok and bool(m["loop"]) and float(m["seam"]) <= maxf(3.0 * float(m["seam_ref"]), 1e-3)
			if not ok:
				bad.append(str(m["file"]))
	_check(bad.is_empty() and n >= 40, "audio: %d baked files load, durations match, loops set (music/amb/engine), one-shots unlooped %s" % [n, bad])
	var d: DirAccess = DirAccess.open("res://audio")
	for f: String in d.get_files():
		if f.ends_with(".wav") or f.ends_with(".ogg"):
			total += FileAccess.get_file_as_bytes("res://audio/" + f).size()
	_check(total > 0 and total <= 6 * 1024 * 1024, "audio: total baked size %.2f MB <= 6 MB" % (float(total) / 1048576.0))
	var music: Dictionary = man["music"]
	_check(music.has("jam") and music.has("boss") and music.has("release") and music.has("menu")
		and float(music["release"]["loop_offset"]) > 3.0, "audio: 4 songs, release keeps its 2-bar intro (loop_offset %.3f s)"
		% float(music.get("release", {}).get("loop_offset", 0.0)))


func _buses() -> void:
	var layout: AudioBusLayout = load("res://default_bus_layout.tres") as AudioBusLayout
	_check(layout != null, "audio: default_bus_layout.tres loads")
	var ok: bool = true
	for b: StringName in [&"Music", &"Amb", &"SFX", &"SFX_L", &"SFX_R"]:
		ok = ok and AudioServer.get_bus_index(b) > 0
	var has_comp: bool = false
	var has_lim: bool = false
	for e: int in AudioServer.get_bus_effect_count(0):
		var fx: AudioEffect = AudioServer.get_bus_effect(0, e)
		if fx is AudioEffectCompressor:
			has_comp = (fx as AudioEffectCompressor).threshold == -10.0 and (fx as AudioEffectCompressor).ratio == 6.0
		has_lim = has_lim or fx is AudioEffectHardLimiter
	var l: int = AudioServer.get_bus_index(&"SFX_L")
	_check(ok and has_comp and has_lim and l > 0 and AudioServer.get_bus_send(l) == &"SFX"
		and AudioServer.get_bus_effect(l, 0) is AudioEffectPanner,
		"audio: buses Music/Amb/SFX(+L/R panners), Master = Compressor(-10 dB, 6:1) + HardLimiter")


func _autoload(man: Dictionary) -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var a: Node = tree.root.get_node_or_null(^"Audio")
	_check(a != null, "audio: Audio autoload present")
	if a == null:
		return
	var was_muted: bool = bool(a.get(&"muted"))
	a.call(&"set_muted", false)
	a.set(&"manual_clock", true)
	var missing: PackedStringArray = PackedStringArray()
	for n: String in WEB_NAMES + ["caltrop", "siren"]:
		if not bool(a.call(&"has_sfx", StringName(n))):
			missing.append(n)
	_check(missing.is_empty(), "audio: every web SFX name (+ caltrop/siren aliases) is playable %s" % missing)

	# crossfade 0.6 s
	a.call(&"music", &"jam")
	a.call(&"advance", 0.3)
	var st: Dictionary = a.call(&"debug_state")
	var g_mid: float = _mus_gain(st, &"jam")
	a.call(&"advance", 0.35)
	a.call(&"music", &"boss")
	a.call(&"advance", 0.3)
	st = a.call(&"debug_state")
	var x_jam: float = _mus_gain(st, &"jam")
	var x_boss: float = _mus_gain(st, &"boss")
	a.call(&"advance", 0.35)
	st = a.call(&"debug_state")
	_check(absf(g_mid - 0.5) < 0.05 and absf(x_jam - 0.5) < 0.05 and absf(x_boss - 0.5) < 0.05
		and _mus_gain(st, &"boss") == 1.0 and _mus_gain(st, &"jam") == 0.0 and StringName(st["music"]) == &"boss",
		"audio: music crossfade 0.6 s (jam in %.2f @0.3 s; jam→boss %.2f/%.2f @0.3 s)" % [g_mid, x_jam, x_boss])

	# voice limits (audio.js admit): horn gap 50 ms, max 3 overlapping (dur 0.5 s); pop staggers instead of dropping
	a.call(&"advance", 1.0)
	var r: Array[bool] = []
	for i: int in 5:
		r.append(bool(a.call(&"sfx", &"horn", {"volume": 0.5})))
		a.call(&"advance", 0.02 if i == 0 else 0.06)
	var pop1: bool = bool(a.call(&"sfx", &"pop"))
	var pop2: bool = bool(a.call(&"sfx", &"pop"))
	_check(r == [true, false, true, true, false] and pop1 and pop2 and not bool(a.call(&"sfx", &"nope")),
		"audio: horn gap/max voices %s, pop x2 staggered, unknown name rejected" % [r])

	# release enters on the cheer grid: phase(release) → cheer, music after 0.6 s → 1 bar after beat0
	a.call(&"advance", 1.0)
	a.call(&"phase", &"release")
	var t0: float = float((a.call(&"debug_state") as Dictionary)["t"])
	a.call(&"advance", 0.7)
	st = a.call(&"debug_state")
	var pend: Dictionary = st["pending_music"]
	var beat0: float = float(man["sfx"]["cheer"]["beat0"])
	var bar: float = 240.0 / float(man["music"]["release"]["bpm"])
	var want_at: float = t0 + beat0 + bar
	_check(not pend.is_empty() and absf(float(pend.get("at", 0.0)) - want_at) < 1e-3 and _mus_gain(st, &"boss") == 0.0,
		"audio: cheer retires boss music, release scheduled 1 bar after the cheer downbeat (+%.3f s)" % (float(pend.get("at", 0.0)) - t0))
	a.call(&"advance", 1.3)
	st = a.call(&"debug_state")
	_check(_mus_gain(st, &"release") == 1.0 and StringName(st["music"]) == &"release", "audio: release music playing at full gain")

	# engine: web gear model → pitch; idles out 0.5 s after the last call
	for i: int in 60:
		a.call(&"engine", 20.0, true)
		a.call(&"advance", 1.0 / 60.0)
	st = a.call(&"debug_state")
	var eng: Dictionary = st["engine"]
	var em: Dictionary = man["engine"]["model"]
	# v=20 → gear 2 (15..24): fr = 5/9, rpm = 0.38 + 0.62·fr, f = 30 + 105·rpm
	var rpm: float = float(em["rpm"][2]) + float(em["rpm"][3]) * (5.0 / 9.0)
	var want_pitch: float = (float(em["f"][0]) + float(em["f"][1]) * rpm) / float(man["engine"]["lo"]["f_ref"])
	var live_lvl: float = float(eng["lvl"])
	a.call(&"advance", 2.0)
	var idle: Dictionary = (a.call(&"debug_state") as Dictionary)["engine"]
	_check(absf(float(eng["pitch"]) - want_pitch) < 0.01 and float(eng["w_hi"]) > 0.99 and live_lvl > 0.05 and float(idle["lvl"]) < 1e-3,
		"audio: engine pitch %.3f (want %.3f), boost → hi layer, idle after 0.5 s (lvl %.3f → %.4f)" % [float(eng["pitch"]), want_pitch, live_lvl, float(idle["lvl"])])

	# duck
	var mb: int = AudioServer.get_bus_index(&"Music")
	a.call(&"duck", true)
	a.call(&"advance", 0.1)
	var ducked: float = AudioServer.get_bus_volume_db(mb)
	a.call(&"duck", false)
	a.call(&"advance", 0.6)
	_check(ducked < -11.0 and absf(AudioServer.get_bus_volume_db(mb)) < 0.01, "audio: duck(true) Music bus %.1f dB, duck(false) → 0 dB" % ducked)

	# mute
	a.call(&"set_muted", true)
	var m_ok: bool = AudioServer.is_bus_mute(0) and not bool(a.call(&"sfx", &"horn"))
	a.call(&"set_muted", false)
	_check(m_ok and not AudioServer.is_bus_mute(0), "audio: mute silences Master and drops SFX")

	a.call(&"music", &"")
	a.call(&"ambience", &"")
	a.call(&"advance", 1.0)
	a.set(&"manual_clock", false)
	a.call(&"set_muted", was_muted)
	a.call(&"stop_all")
	# the mix thread frees stopped playbacks a few buffers later (wall clock); quitting earlier reports them as leaked
	var t_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t_ms < 200:
		await tree.process_frame


func _mus_gain(st: Dictionary, name: StringName) -> float:
	var g: float = 0.0
	for m: Dictionary in st["mus"]:
		if StringName(m["name"]) == name:
			g = maxf(g, float(m["gain"]))
	return g
