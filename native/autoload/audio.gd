extends Node
## Audio autoload "Audio" (docs/NATIVE_PORT.md 3-8 오디오; autoload order 3-1: DB SaveGame InputBuffer Audio Haptics …).
##
## 가설: the web's synthesized audio, baked pre-compressor by tools/bake-audio.mjs into res://audio (manifest
##       audio_bake.json = single truth for files, loop points, levels and the web voice-limit table), replayed on
##       Music/Amb/SFX buses into a Master Compressor+HardLimiter (default_bus_layout.tres = the web compressor and
##       0.93 clipper), sounds like the web: same mix, same voice caps, engine pitch following the web gear model.
##
## API (fixed interface, wired by view/game.gd):
##   music(name)                 crossfade 0.6 s to mus_<name>.ogg (menu/jam/boss/release); &"" stops. "release"
##                               right after sfx(&"cheer") enters on the cheer's bar grid like audio.js startSong().
##   sfx(name, {volume,pitch,pan,delay}) -> bool   one-shot; web admit(): per-name max/gap/stagger, 40 live voices.
##   engine(speed_ms, boost)     continuous: eng_lo/eng_hi pitched to the web rpm (gears), road noise ∝ (v/40)^1.5;
##                               boost=true ↔ web throttle 1.0 (jam push), false ↔ 0.4. Idles out 0.5 s after the last call.
##   duck(on, amount=0.75)       Music bus down (60 ms) / back (540 ms); duck_for(s, amount) = web audio.duck(amount, s).
##   extras: ambience(&"jam"|&"free"|&""), phase(p) = web enterPhase() audio, set_muted(), is_muted().
## Mute: SaveGame progress {"muted": true} or {"settings": {"muted"|"sound"}} or user arg --mute (like ?mute=1).
## Time runs on the wall clock (not Engine.time_scale: the kill slow-mo must not slow the music) and keeps running
## while the tree is paused. Nothing here is random (variants are round-robin), so it stays deterministic.
##
## iOS audio session (project.godot [audio] general/ios/session_category): Godot 4.7 enum Ambient(0, default) /
## Multi Route / Play and Record / Playback(3) / Record / Solo Ambient, plus general/ios/mix_with_others (default
## false); https://docs.godotengine.org/en/stable/classes/class_projectsettings.html#class-projectsettings-property-audio-general-ios-session-category
## We set Playback with mix_with_others off: the device report was "배경음도 없고", and Ambient/Solo Ambient are
## silenced by the ring/silent switch, Playback is not (AVAudioSession.Category.playback, Apple docs). Mixing off =
## the game owns the output like Solo Ambient. ❓ re-evaluate on device (players may expect the silent switch to work).

signal muted_changed(on: bool)

const MANIFEST_PATH: String = "res://audio/audio_bake.json"
const AUDIO_DIR: String = "res://audio/"
const XFADE_S: float = 0.6
const AMB_IN_S: Dictionary = {&"jam": 1.2, &"free": 3.0}   # audio.js startAmb(): jam 1.2 s ramp, wind 3.5 s swell
const AMB_OUT_S: float = 0.6
const CHEER_MUSIC_OUT_S: float = 0.25                       # cheerHorns(): boss/jam music gives way in 0.25 s
const MAX_LIVE: int = 40                                    # audio.js MAX_LIVE
const DUCK_ATTACK_S: float = 0.06
const DUCK_RELEASE_S: float = 0.54
const ENGINE_IDLE_S: float = 0.5
const PAN_DEADZONE: float = 0.2                             # |pan| below → centre bus, else SFX_L / SFX_R (±0.55)
const ALIASES: Dictionary = {&"caltrop": &"tack", &"siren": &"warn", &"fanfare": &"stageClear", &"kill": &"superHit"}
## web enterPhase() (game/js/main.js:420-530): [music or null=keep, ambience or null=keep, sfx list, duck [amount, s]]
const PHASES: Dictionary = {
	&"title": [&"menu", &"", [], []],
	&"intro": [&"jam", &"jam", [], []],
	&"jam": [&"jam", &"jam", [[&"go", 1.0]], []],
	&"boss": [&"boss", null, [[&"warn", 1.0], [&"hornAngry", 0.5]], []],
	&"kill": [null, null, [[&"superHit", 1.0]], [0.75, 2.6]],
	&"wreck": [null, null, [[&"explosion", 1.0]], [0.7, 2.5]],
	&"release": [null, &"", [[&"cheer", 1.0]], []],
	&"cruise": [null, &"free", [], []],
}
const RELEASE_MUSIC_DELAY_S: float = 0.6                    # main.js: setTimeout(startMusic('release'), 600)

var muted: bool = false
var manual_clock: bool = false   ## tests: true = _process does nothing, drive advance(dt) by hand
var played: int = 0
var dropped: int = 0

var _t: float = 0.0
var _last_us: int = 0
var _man: Dictionary = {}
var _sfx_meta: Dictionary = {}       # StringName → Dictionary (web table row + files + gain_db)
var _sfx_streams: Dictionary = {}    # StringName → Array[AudioStream]
var _sfx_rr: Dictionary = {}         # StringName → int (variant round-robin)
var _pools: Dictionary = {}          # StringName → Array[AudioStreamPlayer]
var _lim_last: Dictionary = {}       # StringName → float
var _lim_ends: Dictionary = {}       # StringName → PackedFloat64Array
var _live: PackedFloat64Array = PackedFloat64Array()
var _pending_sfx: Array[Dictionary] = []
var _loop_streams: Dictionary = {}   # "mus_jam" … → AudioStream
var _loop_meta: Dictionary = {}

var _mus: Array[_Fader] = []
var _music: StringName = &""
var _music_req: Dictionary = {}      # {name, at}: delayed music() call (release after cheer)
var _music_start: Dictionary = {}    # {name, at}: grid-aligned start
var _cheer_t0: float = -1e9
var _amb: Array[_Fader] = []
var _ambience: StringName = &""
var _duck: float = 1.0
var _duck_target: float = 1.0
var _duck_until: float = -1.0
var _bg_muted: bool = false

var _eng: Dictionary = {}            # lo/hi/road → _Fader
var _eng_call: float = -1e9
var _eng_v: float = 0.0
var _eng_th: float = 0.4
var _eng_pitch: float = 1.0
var _eng_w: float = 0.0              # 0 = lo layer, 1 = hi layer
var _eng_lvl: float = 0.0
var _eng_road: float = 0.0


## One looping player with a linear-amplitude fade (music, ambience, engine layers).
class _Fader:
	var player: AudioStreamPlayer
	var name: StringName = &""
	var gain: float = 0.0
	var target: float = 0.0
	var rate: float = 1.0            # gain units per second
	var db: float = 0.0              # baked gain_db

	func _init(p: AudioStreamPlayer) -> void:
		player = p

	func fade(to: float, seconds: float) -> void:
		target = to
		rate = absf(to - gain) / maxf(seconds, 0.0001)
		if seconds <= 0.0:
			gain = to

	func step(dt: float) -> void:
		gain = move_toward(gain, target, rate * dt)
		if gain <= 0.0 and target <= 0.0:
			if player.playing:
				player.stop()
			name = &""
		else:
			player.volume_db = linear_to_db(maxf(gain, 1e-5)) + db


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_us = Time.get_ticks_usec()
	_load_manifest()
	for i: int in 2:
		_mus.append(_Fader.new(_player(&"Music")))
		_amb.append(_Fader.new(_player(&"Amb")))
	for k: StringName in [&"lo", &"hi", &"road"]:
		_eng[k] = _Fader.new(_player(&"SFX"))
	set_muted(_saved_mute() or OS.get_cmdline_user_args().has("--mute"))


func _player(bus: StringName) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = bus if AudioServer.get_bus_index(bus) >= 0 else &"Master"
	add_child(p)
	return p


# ───────────────────────────── loading
func _load_manifest() -> void:
	if not FileAccess.file_exists(MANIFEST_PATH):
		push_warning("Audio: %s missing (run node tools/bake-audio.mjs)" % MANIFEST_PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not parsed is Dictionary:
		push_warning("Audio: bad manifest")
		return
	_man = parsed
	var sfx: Dictionary = _man.get("sfx", {})
	for n: String in sfx:
		var m: Dictionary = sfx[n]
		var list: Array[AudioStream] = []
		for f: String in m.get("files", []):
			var st: AudioStream = _load_stream(AUDIO_DIR + f, false, 0.0)
			if st != null:
				list.append(st)
		if list.is_empty():
			continue
		_sfx_meta[StringName(n)] = m
		_sfx_streams[StringName(n)] = list
	for group: String in ["music", "amb", "engine"]:
		var g: Dictionary = _man.get(group, {})
		for k: String in g:
			if not g[k] is Dictionary or not (g[k] as Dictionary).has("file"):
				continue
			var m: Dictionary = g[k]
			var st: AudioStream = _load_stream(AUDIO_DIR + str(m["file"]), true, float(m.get("loop_offset", 0.0)))
			if st != null:
				var key: String = str(m["file"]).get_basename()
				_loop_streams[key] = st
				_loop_meta[key] = m


## Imported resource first; a fresh checkout without .godot/imported falls back to the raw file with the same
## loop settings the .import files carry (bake-audio.mjs writes both).
func _load_stream(path: String, loop: bool, loop_offset: float) -> AudioStream:
	var st: AudioStream = null
	if ResourceLoader.exists(path):
		st = load(path) as AudioStream
	if st == null and FileAccess.file_exists(path):
		if path.ends_with(".ogg"):
			var o: AudioStreamOggVorbis = AudioStreamOggVorbis.load_from_file(path)
			if o != null:
				o.loop = loop
				o.loop_offset = loop_offset
			st = o
		else:
			st = AudioStreamWAV.load_from_file(path, {"edit/loop_mode": 2 if loop else 0, "edit/loop_begin": 0, "edit/loop_end": -1})
	if st == null:
		push_warning("Audio: missing %s" % path)
	return st


# ───────────────────────────── public API
func has_sfx(name: StringName) -> bool:
	return _sfx_meta.has(ALIASES.get(name, name))


func sfx_names() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for n: StringName in _sfx_meta:
		out.append(str(n))
	return out


func sfx(name: StringName, opts: Dictionary = {}) -> bool:
	var n: StringName = ALIASES.get(name, name)
	if muted or not _sfx_meta.has(n):
		return false
	var m: Dictionary = _sfx_meta[n]
	var vol: float = clampf(float(opts.get("volume", 1.0)), 0.0, 4.0)
	if vol <= 0.0:
		return false
	var at: float = _admit(n, m, _t + clampf(float(opts.get("delay", 0.0)), 0.0, 10.0))
	if at < 0.0:
		dropped += 1
		return false
	var job: Dictionary = {"name": n, "at": at, "vol": vol, "pitch": clampf(float(opts.get("pitch", 1.0)), 0.25, 4.0),
		"pan": clampf(float(opts.get("pan", 0.0)), -1.0, 1.0)}
	if n == &"cheer":
		# cheerHorns(): jam/boss music retires in 0.25 s; the release song then enters on this grid
		_fade_music_out(CHEER_MUSIC_OUT_S)
		_music = &""
		_music_start = {}
		_cheer_t0 = at + float(m.get("beat0", 0.0))
	if at > _t + 0.0005:
		_pending_sfx.append(job)
	else:
		_play_now(job)
	played += 1
	return true


func music(name: StringName) -> void:
	if name == _music:
		return
	_music_req = {}
	if name == &"":
		_music = &""
		_music_start = {}
		_fade_music_out(XFADE_S)
		return
	var key: String = "mus_" + str(name)
	if not _loop_streams.has(key):
		push_warning("Audio: no music '%s'" % name)
		return
	_music = name
	var at: float = _t
	if name == &"release" and _cheer_t0 > -1e8:
		# audio.js startSong(): enter on the cheer grid (same tick → same downbeat, else the next bar boundary)
		var bar: float = 240.0 / float(_loop_meta[key].get("bpm", 130))
		var rel: float = _t - _cheer_t0
		if rel <= 0.0 and rel > -1.0:
			at = maxf(_t, _cheer_t0)
		elif rel > 0.0 and rel < 2.0 * bar:
			at = _cheer_t0 + maxf(1.0, ceilf(rel / bar - 0.02)) * bar
	if at > _t + 0.0005:
		_fade_music_out(XFADE_S)
		_music_start = {"name": name, "at": at}
	else:
		_music_start = {}
		_start_music(name, maxf(0.0, _t - at), XFADE_S if at == _t else 0.0)


func ambience(name: StringName) -> void:
	if name == _ambience:
		return
	_ambience = name
	for f: _Fader in _amb:
		if f.name != &"":
			f.fade(0.0, AMB_OUT_S)
	var key: String = "amb_" + str(name)
	if name == &"" or not _loop_streams.has(key):
		return
	var f: _Fader = _amb[0] if _amb[0].gain <= _amb[1].gain else _amb[1]
	f.gain = 0.0
	_start_loop(f, name, key, 0.0)
	f.fade(1.0, float(AMB_IN_S.get(name, 1.0)))


func engine(speed_ms: float, boost: bool, throttle: float = -1.0) -> void:
	var em: Dictionary = _man.get("engine", {}).get("model", {})
	if em.is_empty() or not _loop_streams.has("eng_lo"):
		return
	var th_pair: Array = em.get("throttle", [1.0, 0.4])
	_eng_th = clampf(throttle, 0.0, 1.0) if throttle >= 0.0 else (float(th_pair[0]) if boost else float(th_pair[1]))
	_eng_v = clampf(speed_ms, 0.0, float(em.get("vmax", 45)))
	_eng_call = _t
	for k: StringName in [&"lo", &"hi", &"road"]:
		var f: _Fader = _eng[k]
		if f.name == &"":
			_start_loop(f, k, "eng_road" if k == &"road" else "eng_" + str(k), 0.0)
			f.gain = 0.0


func duck(on: bool, amount: float = 0.75) -> void:
	_duck_target = (1.0 - clampf(amount, 0.0, 1.0)) if on else 1.0
	_duck_until = -1.0


## web audio.duck(amount, seconds): down 60 ms, hold, back over 540 ms.
func duck_for(seconds: float, amount: float = 0.75) -> void:
	duck(true, amount)
	_duck_until = _t + DUCK_ATTACK_S + clampf(seconds, 0.0, 30.0)


func phase(p: StringName) -> void:
	if not PHASES.has(p):
		return
	var row: Array = PHASES[p]
	for s: Array in row[2]:
		sfx(s[0], {"volume": s[1]})
	if row[0] != null:
		music(row[0])
	if row[1] != null:
		ambience(row[1])
	if not (row[3] as Array).is_empty():
		duck_for(float(row[3][1]), float(row[3][0]))
	if p == &"release":
		_music_req = {"name": &"release", "at": _t + RELEASE_MUSIC_DELAY_S}


func set_muted(on: bool) -> void:
	muted = on
	_apply_master_mute()
	muted_changed.emit(on)


func is_muted() -> bool:
	return muted


func current_music() -> StringName:
	return _music


func current_ambience() -> StringName:
	return _ambience


## For tests/HUD debug: the engine's current pitch scale and layer gains, music fader gains, duck gain.
func debug_state() -> Dictionary:
	var mus: Array = []
	for f: _Fader in _mus:
		mus.append({"name": f.name, "gain": f.gain, "playing": f.player.playing})
	return {"t": _t, "music": _music, "mus": mus, "ambience": _ambience, "duck": _duck, "pending_music": _music_start.duplicate(),
		"engine": {"pitch": _eng_pitch, "w_hi": _eng_w, "lvl": _eng_lvl, "road": _eng_road,
		"lo": (_eng[&"lo"] as _Fader).gain if _eng.has(&"lo") else 0.0}, "played": played, "dropped": dropped}


# ───────────────────────────── internals
func _process(_delta: float) -> void:
	var now: int = Time.get_ticks_usec()
	var dt: float = clampf(float(now - _last_us) / 1e6, 0.0, 0.25)
	_last_us = now
	if not manual_clock:
		advance(dt)


func advance(dt: float) -> void:
	_t += dt
	var i: int = 0
	while i < _pending_sfx.size():
		if _pending_sfx[i]["at"] <= _t:
			_play_now(_pending_sfx[i])
			_pending_sfx.remove_at(i)
		else:
			i += 1
	if not _music_req.is_empty() and _t >= float(_music_req["at"]):
		var n: StringName = _music_req["name"]
		_music_req = {}
		if _music == &"":   # nobody picked other music meanwhile
			music(n)
	if not _music_start.is_empty() and _t >= float(_music_start["at"]):
		var n2: StringName = _music_start["name"]
		var late: float = _t - float(_music_start["at"])
		_music_start = {}
		_start_music(n2, late, 0.0)
	for f: _Fader in _mus:
		f.step(dt)
	for f: _Fader in _amb:
		f.step(dt)
	if _duck_until >= 0.0 and _t >= _duck_until:
		duck(false)
	var dr: float = (1.0 / DUCK_ATTACK_S) if _duck_target < _duck else (1.0 / DUCK_RELEASE_S)
	_duck = move_toward(_duck, _duck_target, dr * dt)
	var mb: int = AudioServer.get_bus_index(&"Music")
	if mb >= 0:
		AudioServer.set_bus_volume_db(mb, linear_to_db(maxf(_duck, 1e-4)))
	_step_engine(dt)


func _step_engine(dt: float) -> void:
	if _eng.is_empty() or (_eng[&"lo"] as _Fader).name == &"":
		return
	var em: Dictionary = _man["engine"]["model"]
	var lo: Dictionary = _loop_meta.get("eng_lo", {})
	var hi: Dictionary = _loop_meta.get("eng_hi", {})
	var idle: bool = _t - _eng_call > ENGINE_IDLE_S
	# audio.js setEngine(): gear → rpm (drops on upshift) → f, level; setTargetAtTime k 0.07 (pitch) / 0.1 (gain) / 0.2 (road)
	var gears: Array = em["gears"]
	var gi: int = 0
	while gi < gears.size() - 2 and _eng_v >= float(gears[gi + 1]):
		gi += 1
	var fr: float = clampf((_eng_v - float(gears[gi])) / (float(gears[gi + 1]) - float(gears[gi])), 0.0, 1.0)
	var rc: Array = em["rpm"]
	var rpm: float = (float(rc[0]) + float(rc[1]) * fr) if gi == 0 else (float(rc[2]) + float(rc[3]) * fr)
	var fc: Array = em["f"]
	var lc: Array = em["lvl"]
	var f_hz: float = float(fc[0]) + float(fc[1]) * rpm
	var lvl: float = 0.0 if idle else float(lc[0]) + float(lc[1]) * _eng_th + float(lc[2]) * rpm
	var th_lo: float = float(lo.get("th", 0.4))
	var th_hi: float = float(hi.get("th", 1.0))
	var w: float = clampf((_eng_th - th_lo) / maxf(th_hi - th_lo, 1e-3), 0.0, 1.0)
	var rd: Array = em["road"]
	var road: float = 0.0 if idle else pow(_eng_v / float(rd[1]), float(rd[2]))   # × gain_ref baked in eng_road
	var k_gain: float = 0.15 if idle else 0.1
	_eng_pitch += (f_hz / float(lo.get("f_ref", 60.0)) - _eng_pitch) * (1.0 - exp(-dt / 0.07))
	_eng_w += (w - _eng_w) * (1.0 - exp(-dt / 0.1))
	_eng_lvl += (lvl - _eng_lvl) * (1.0 - exp(-dt / k_gain))
	_eng_road += (road - _eng_road) * (1.0 - exp(-dt / (0.15 if idle else 0.2)))
	var parts: Dictionary = {&"lo": (1.0 - _eng_w) * _eng_lvl / maxf(float(lo.get("lvl_ref", 0.04)), 1e-4),
		&"hi": _eng_w * _eng_lvl / maxf(float(hi.get("lvl_ref", 0.06)), 1e-4), &"road": _eng_road}
	for k: StringName in parts:
		var f: _Fader = _eng[k]
		f.gain = float(parts[k])
		f.target = f.gain
		f.player.pitch_scale = maxf(_eng_pitch, 0.05) if k != &"road" else 1.0
		f.player.volume_db = linear_to_db(maxf(f.gain, 1e-5)) + f.db
	if idle and _eng_lvl < 1e-4 and _eng_road < 1e-3:
		for k2: StringName in parts:
			var f2: _Fader = _eng[k2]
			f2.player.stop()
			f2.name = &""


func _start_loop(f: _Fader, name: StringName, key: String, from: float) -> void:
	f.name = name
	f.db = float(_loop_meta[key].get("gain_db", 0.0))
	f.player.stream = _loop_streams[key]
	f.player.volume_db = linear_to_db(maxf(f.gain, 1e-5)) + f.db
	f.player.play(from)


func _start_music(name: StringName, from: float, fade_in: float) -> void:
	_fade_music_out(XFADE_S)
	var f: _Fader = _mus[0] if _mus[0].gain <= _mus[1].gain else _mus[1]
	f.gain = 0.0
	_start_loop(f, name, "mus_" + str(name), from)
	f.fade(1.0, fade_in)


func _fade_music_out(seconds: float) -> void:
	for f: _Fader in _mus:
		if f.name != &"" and f.target > 0.0:
			f.fade(0.0, seconds)


## audio.js admit(): per-name min re-trigger gap (or stagger when allowed), per-name max overlapping voices
## (occupancy = the table's dur), global 40 live voices of which priority-2 sounds may exceed the cap.
func _admit(n: StringName, m: Dictionary, t: float) -> float:
	var last: float = float(_lim_last.get(n, -1e9))
	var at: float = t
	if absf(at - last) < float(m.get("gap", 0.05)):
		var stagger: float = float(m.get("stagger", 0.0))
		if stagger > 0.0 and last + stagger - t < 0.4:
			at = last + stagger
		else:
			return -1.0
	var ends: PackedFloat64Array = PackedFloat64Array()
	for e: float in _lim_ends.get(n, PackedFloat64Array()):
		if e > at:
			ends.append(e)
	if ends.size() >= int(m.get("max", 2)):
		_lim_ends[n] = ends
		return -1.0
	var live: PackedFloat64Array = PackedFloat64Array()
	for e2: float in _live:
		if e2 > at:
			live.append(e2)
	_live = live
	if _live.size() >= MAX_LIVE and int(m.get("pri", 1)) < 2:
		return -1.0
	var dur: float = float(m.get("dur", 0.3))
	_lim_last[n] = at
	ends.append(at + dur)
	_lim_ends[n] = ends
	_live.append(at + dur)
	return at


func _play_now(job: Dictionary) -> void:
	var n: StringName = job["name"]
	var m: Dictionary = _sfx_meta[n]
	var streams: Array = _sfx_streams[n]
	if not _pools.has(n):
		var pool: Array[AudioStreamPlayer] = []
		for i: int in int(m.get("max", 2)) + 1:
			pool.append(_player(&"SFX"))
		_pools[n] = pool
	var best: AudioStreamPlayer = null
	for p: AudioStreamPlayer in _pools[n]:
		if not p.playing:
			best = p
			break
		if best == null or p.get_playback_position() > best.get_playback_position():
			best = p   # steal the oldest voice
	var rr: int = int(_sfx_rr.get(n, 0))
	_sfx_rr[n] = rr + 1
	var pan: float = float(job["pan"])
	var bus: StringName = &"SFX_L" if pan < -PAN_DEADZONE else (&"SFX_R" if pan > PAN_DEADZONE else &"SFX")
	best.bus = bus if AudioServer.get_bus_index(bus) >= 0 else &"SFX"
	best.stream = streams[rr % streams.size()]
	best.pitch_scale = float(job["pitch"])
	best.volume_db = linear_to_db(float(job["vol"])) + float(m.get("gain_db", 0.0))
	best.play()


func _saved_mute() -> bool:
	var sg: Node = get_node_or_null(^"/root/SaveGame")
	if sg == null or not sg.has_method(&"load_progress"):
		return false
	var d: Variant = sg.call(&"load_progress")
	if not d is Dictionary:
		return false
	var prog: Dictionary = d
	if prog.get("muted", false) == true:
		return true
	var st: Variant = prog.get("settings", {})
	if st is Dictionary:
		var s: Dictionary = st
		return s.get("muted", false) == true or s.get("sound", true) == false
	return false


func _apply_master_mute() -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index(&"Master"), muted or _bg_muted)


## Stop every voice before the tree goes away, so no AudioStreamPlayback outlives its stream at exit.
func stop_all() -> void:
	for c: Node in get_children():
		if c is AudioStreamPlayer:
			(c as AudioStreamPlayer).stop()
	_pending_sfx.clear()


func _exit_tree() -> void:
	stop_all()


func _notification(what: int) -> void:
	# web: visibilitychange → suspend. iOS backgrounding sends APPLICATION_PAUSED / RESUMED.
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_bg_muted = true
		_apply_master_mute()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_bg_muted = false
		_apply_master_mute()
