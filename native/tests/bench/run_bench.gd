extends SceneTree
## Standalone runner for the perf bench (tests/run_tests.gd only discovers tests/test_*.gd):
##   godot47 --headless --path native -s res://tests/bench/run_bench.gd
## Exit code = failures (0 = within budget).


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	await process_frame
	var bench: Object = (load("res://tests/bench/bench_traffic.gd") as GDScript).new()
	var fails: int = await bench.call(&"run")
	print("SUMMARY bench_traffic fails=%d" % fails)
	quit(mini(fails, 125))
