extends Node
## Discovery shim: runs the Haptics test that lives with the iOS extension (res://platform/ios/tests/test_haptics.gd,
## owned by the Mac/iOS tooling) inside run_tests.gd. It SKIPs by itself when the host IOSHaptics library is not built.

const SUITE: String = "unit"
const TEST_PATH: String = "res://platform/ios/tests/test_haptics.gd"


func run() -> int:
	var t: Node = (load(TEST_PATH) as GDScript).new() as Node
	add_child(t)
	var fails: int = await t.call(&"run")
	t.queue_free()
	return fails
