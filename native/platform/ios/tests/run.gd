extends SceneTree
## Standalone runner for test_haptics.gd (same contract as res://tests/run_tests.gd: run() -> int failures).
##   bash tools/mac/build_ios_ext.sh --host
##   godot47 --headless --path native -s res://platform/ios/tests/run.gd
## Exit code = failures (capped at 125). Kept here until the gate owner moves test_haptics.gd to res://tests/.

const TEST_PATH: String = "res://platform/ios/tests/test_haptics.gd"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var script: GDScript = load(TEST_PATH) as GDScript
	if script == null:
		print("FAIL %s: does not load" % TEST_PATH)
		quit(1)
		return
	var inst: Node = script.new() as Node
	root.add_child(inst)
	var result: Variant = await inst.call(&"run")
	inst.queue_free()
	var fails: int = int(result) if typeof(result) == TYPE_INT else 1
	print("SUMMARY test_haptics fails=%d" % fails)
	quit(mini(fails, 125))
