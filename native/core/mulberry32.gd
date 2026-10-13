class_name Mulberry32
extends RefCounted
## mulberry32 in GDScript, bit-identical to game/js/traffic.js and the C++ Rng32 (NATIVE_PORT 3-3).
## Always available (no GDExtension needed): world props loop (seed = id*7919+13), the GDScript traffic
## fallback, tests. GDScript ints are 64-bit signed, so every 32-bit step is masked and Math.imul is done in
## two 16-bit halves (no int64 overflow).

const MASK32: int = 0xFFFFFFFF
const INV_2_32: float = 1.0 / 4294967296.0

var _a: int = 0
var draws: int = 0


func _init(seed: int = 0) -> void:
	set_seed(seed)


func set_seed(seed: int) -> void:
	_a = seed & MASK32
	draws = 0


func next_u32() -> int:
	draws += 1
	_a = (_a + 0x6D2B79F5) & MASK32
	var t: int = Mulberry32.imul(_a ^ (_a >> 15), 1 | _a)
	t = ((t + Mulberry32.imul(t ^ (t >> 7), 61 | t)) & MASK32) ^ t
	return (t ^ (t >> 14)) & MASK32


## u32 / 2^32 in [0, 1) — the JS `rng()` value.
func next_float() -> float:
	return float(next_u32()) * INV_2_32


## Math.imul for unsigned 32-bit inputs; result in [0, 2^32).
static func imul(a: int, b: int) -> int:
	var lo: int = a * (b & 0xFFFF)
	var hi: int = ((a * (b >> 16)) & 0xFFFF) << 16
	return (lo + hi) & MASK32


## traffic seed (main.js:360) / world seed (world.js:132) from config.setup.
static func traffic_seed(stage_id: int) -> int:
	return stage_id * 1000 + 7


static func world_seed(stage_id: int) -> int:
	return stage_id * 7919 + 13
