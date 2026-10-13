class_name Sfx
extends Node
## Minimal SFX player for M1a (NATIVE_PORT 3-8 오디오): baked one-shots from res://audio/*.wav (tools/bake-audio.mjs,
## tapped BEFORE the web compressor), played on an "SFX" bus → Master, where Master carries the web chain's
## dynamics once: Compressor (−10 dB, 6:1, 3 / 220 ms) + HardLimiter (−0.6 dB ceiling). Voice cap per name like the
## web sfx table (horn: max 3, gap 50 ms); global cap 40.

const SOUNDS: Dictionary = {"horn": {"file": "res://audio/horn.wav", "max": 3, "gap": 0.05, "db": 0.0},
	"hornShort": {"file": "res://audio/hornShort.wav", "max": 3, "gap": 0.05, "db": 0.0}}
const MAX_VOICES: int = 40

var _streams: Dictionary = {}
var _pools: Dictionary = {}          # name → Array[AudioStreamPlayer]
var _last: Dictionary = {}
var played: int = 0
var dropped: int = 0
var muted: bool = false


func _ready() -> void:
	_ensure_buses()
	for n: String in SOUNDS:
		var spec: Dictionary = SOUNDS[n]
		var st: AudioStream = _load(str(spec["file"]))
		if st == null:
			continue
		_streams[n] = st
		var pool: Array[AudioStreamPlayer] = []
		for i: int in int(spec["max"]):
			var p := AudioStreamPlayer.new()
			p.stream = st
			p.bus = &"SFX"
			p.volume_db = float(spec["db"])
			add_child(p)
			pool.append(p)
		_pools[n] = pool


func _load(path: String) -> AudioStream:
	if ResourceLoader.exists(path):
		return load(path) as AudioStream
	if FileAccess.file_exists(path):  # not imported yet (fresh checkout, headless test)
		return AudioStreamWAV.load_from_file(path)
	push_warning("Sfx: missing %s (run node tools/bake-audio.mjs)" % path)
	return null


static func _ensure_buses() -> void:
	if AudioServer.get_bus_index(&"SFX") < 0:
		AudioServer.add_bus()
		var i: int = AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, &"SFX")
		AudioServer.set_bus_send(i, &"Master")
	var master: int = AudioServer.get_bus_index(&"Master")
	var has_comp: bool = false
	for e: int in AudioServer.get_bus_effect_count(master):
		if AudioServer.get_bus_effect(master, e) is AudioEffectCompressor:
			has_comp = true
	if not has_comp:
		var comp := AudioEffectCompressor.new()
		comp.threshold = -10.0
		comp.ratio = 6.0
		comp.attack_us = 3000.0
		comp.release_ms = 220.0
		AudioServer.add_bus_effect(master, comp)
		var lim := AudioEffectHardLimiter.new()
		lim.ceiling_db = -0.6
		AudioServer.add_bus_effect(master, lim)


func has_sound(n: String) -> bool:
	return _streams.has(n)


func play(n: String, pitch: float = 1.0) -> bool:
	if muted or not _pools.has(n):
		return false
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var spec: Dictionary = SOUNDS[n]
	if now - float(_last.get(n, -1e9)) < float(spec["gap"]):
		dropped += 1
		return false
	var busy: int = 0
	for pool: Array in _pools.values():
		for p: AudioStreamPlayer in pool:
			if p.playing:
				busy += 1
	if busy >= MAX_VOICES:
		dropped += 1
		return false
	for p: AudioStreamPlayer in _pools[n]:
		if not p.playing:
			p.pitch_scale = pitch
			p.play()
			_last[n] = now
			played += 1
			return true
	dropped += 1
	return false
