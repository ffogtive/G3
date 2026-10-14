extends RefCounted
## Discovery shim for `run_tests.gd -- --suite=perf`: the traffic p95 bench (res://tests/bench/bench_traffic.gd,
## writes res://build/perf.json). Budget: p95 ≤ 0.5 ms/tick at the stage-90 car count (NATIVE_PORT 2 / M1a).

const SUITE: String = "perf"


func run() -> int:
	return await ((load("res://tests/bench/bench_traffic.gd") as GDScript).new() as Object).call(&"run")
