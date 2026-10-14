extends RefCounted
## r3 C2: stand-in signature for the stages whose sig module is not ported yet (BEHAVIORS has only occupy, so 1-2..1-10
## had no window at all and the fight was tacks ×1 + rage dmgOut only). A metronome "빈틈": once the front lock is made,
## every `period` s of BossSim time a `dur` s window opens (vulnerable 1.5 → BossSim's P0#7 window = tacks ×vulnMul,
## attacks blocked, the running telegraph cancelled at the open tick), announced with the villain bubble
## "헉헉… (빈틈!)" and a stun event (the HUD "경직!" pop, the gold "약점!" reticle). No motion of its own: motion() only
## watches the window edge (it is the one hook BossSim calls every tick), the villain keeps its spawn / phase movement.
## GameSim attaches it when the stage's sig has no module and config.boss.genericWindow.on != false; a real signature
## module in BEHAVIORS replaces it automatically. Hooks: init / on_lock / motion / vulnerable / blocked / window_left /
## hint (+ windows for tests). No RNG.
## Config (config.boss.genericWindow): period 4.5, dur 1.2, first = period − dur (s after the lock to the first open).
## GameSim may set `cfg` before BossSim.spawn; otherwise init() reads res://data/config.json once.
##
## 가설: ✅ (r3design/combat/combo_proto.gd, hpMul 1.6–1.7) a 1.2 s window every 4.5 s gives the unported stages the
##       same "read the tell, then burst" beat 1-1 has, and with the combo milestones brings 1-2..1-4 from 41–60 s of
##       tacks to 14–20 s; ❓ anchored at the lock (prototype: absolute BossSim.time) the first window comes 3.3 s in.

const _DB := preload("res://core/db.gd")
const BUBBLE: String = "헉헉… (빈틈!)"

static var _file_cfg: Dictionary = {}
static var _file_loaded: bool = false

## config.boss.genericWindow ({} = read from res://data/config.json in init()).
var cfg: Dictionary = {}
var period: float = 4.5
var dur: float = 1.2
var first: float = 3.3
var hint: String = "발사 꾹 · 빈틈 노려"
## BossSim.time of the front lock (−1 = not locked yet: no windows before the lock).
var t0: float = -1.0
## Windows opened so far (index of the last announced window + 1).
var opened: int = 0
var _announced: Dictionary = {}   # villain index -> last window index announced


func init(B: BossSim, _stage: Dictionary) -> void:
	var c: Dictionary = cfg
	if c.is_empty():
		c = _load_cfg()
	period = maxf(0.5, float(c.get("period", 4.5)))
	dur = clampf(float(c.get("dur", 1.2)), 0.05, period - 0.05)
	first = float(c.get("first", period - dur))
	hint = str(c.get("hint", hint))
	t0 = -1.0
	opened = 0
	_announced = {}
	B.sig = {"generic": true}


static func _load_cfg() -> Dictionary:
	if not _file_loaded:
		_file_loaded = true
		var conf: Variant = _DB.load_json(_DB.DATA_DIR + "/config.json")
		if conf is Dictionary:
			var gw: Variant = ((conf as Dictionary).get("boss", {}) as Dictionary).get("genericWindow", {})
			_file_cfg = gw if gw is Dictionary else {}
	return _file_cfg


## GameSim calls it at the front lock: the window clock starts here.
func on_lock(B: BossSim) -> void:
	if t0 < 0.0:
		t0 = B.time


## Index of the window open at BossSim time t (−1 = closed).
func _idx_at(t: float) -> int:
	if t0 < 0.0:
		return -1
	var k: float = t - t0 - first
	if k < 0.0:
		return -1
	var i: int = floori(k / period)
	return i if k - i * period < dur else -1


func _left_at(t: float) -> float:
	var i: int = _idx_at(t)
	if i < 0:
		return 0.0
	return maxf(0.0, t0 + first + i * period + dur - t)


## Window edge only (no movement). Also anchors the clock when a caller set front_locked without GameSim's on_lock
## (tests): ctx.player_behind is false once the fight is locked.
func motion(B: BossSim, v: Dictionary, _dt: float, ctx: Dictionary) -> void:
	if t0 < 0.0:
		if ctx.get("phase", &"") == &"boss" and not bool(ctx.get("player_behind", true)):
			t0 = B.time
		else:
			return
	var i: int = _idx_at(B.time)
	if i < 0:
		return
	var vi: int = int(v["index"])
	if int(_announced.get(vi, -1)) >= i:
		return
	var fresh: bool = opened <= i
	_announced[vi] = i
	opened = maxi(opened, i + 1)
	B.cancel_attack(v)
	var left: float = _left_at(B.time)
	B.pending.append({"type": "stun", "id": vi, "dur": left, "generic": true})
	if fresh:
		B.pending.append({"type": "bubble", "who": "villain", "id": vi, "text": BUBBLE, "kind": "score", "dur": minf(1.2, left)})


func blocked(B: BossSim, _v: Dictionary) -> bool:
	return _idx_at(B.time) >= 0


## Web multiplier (1.5 in the window); BossSim maps > 1 to the P0#7 window.
func vulnerable(B: BossSim, _v: Dictionary) -> float:
	return 1.5 if _idx_at(B.time) >= 0 else 1.0


## Seconds left in the current window (0 = closed) for the HUD / autopilot.
func window_left(B: BossSim) -> float:
	return _left_at(B.time)


## Test helper: [open, close] BossSim times of the first n windows ([] before the lock).
func windows(n: int) -> Array:
	var out: Array = []
	if t0 < 0.0:
		return out
	for i: int in n:
		var a: float = t0 + first + i * period
		out.append([a, a + dur])
	return out
