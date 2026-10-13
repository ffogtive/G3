extends SceneTree
## Headless test runner (NATIVE_PORT 4-2, T0).
##   godot47 --headless --path native -s res://tests/run_tests.gd -- [--suite=unit|perf|all] [--filter=<substr>] [--list]
##
## Discovers res://tests/test_*.gd (sorted). Each test script:
##   - extends RefCounted (or Node; Nodes are added under /root while they run and freed afterwards),
##   - exposes `func run() -> int` returning its number of failures (it may `await`),
##   - may declare `const SUITE := "perf"` (default "unit"); --suite=all runs everything.
## Convention for output lines: "PASS ...", "FAIL ...", "INFO ...", "SKIP ...".
## A script that fails to load, lacks run(), errors out, or returns a non-int counts as 1 failure.
## Exit code = total failures, capped at 125 so an 8-bit exit status never wraps to 0.

const TEST_DIR: String = "res://tests"
const EXIT_CAP: int = 125

var _suite: String = "unit"
var _filter: String = ""
var _list_only: bool = false


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--suite="):
			_suite = arg.trim_prefix("--suite=")
		elif arg.begins_with("--filter="):
			_filter = arg.trim_prefix("--filter=")
		elif arg == "--list":
			_list_only = true
	_main.call_deferred()


func _main() -> void:
	# One frame so autoloads are in the tree and deferred setup has run before any test touches them.
	await process_frame
	var t0: int = Time.get_ticks_msec()
	var files: PackedStringArray = _discover()
	var total_fails: int = 0
	var ran: int = 0
	print("INFO runner: Godot %s, suite=%s, %d test file(s)" % [Engine.get_version_info().string, _suite, files.size()])
	for file: String in files:
		var path: String = TEST_DIR.path_join(file)
		var script: GDScript = load(path) as GDScript
		if script == null or not script.can_instantiate():
			print("FAIL %s: script did not load/compile" % file)
			total_fails += 1
			continue
		var suite: String = str(script.get_script_constant_map().get("SUITE", "unit"))
		if _suite != "all" and suite != _suite:
			continue
		if _list_only:
			print("LIST %s [%s]" % [file, suite])
			continue
		ran += 1
		var fails: int = await _run_one(file, script)
		total_fails += fails
	if _list_only:
		quit(0)
		return
	print("SUMMARY files=%d fails=%d time=%.2fs" % [ran, total_fails, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(mini(total_fails, EXIT_CAP))


func _discover() -> PackedStringArray:
	var out: PackedStringArray = []
	for file: String in DirAccess.get_files_at(TEST_DIR):
		if file.begins_with("test_") and file.ends_with(".gd") and (_filter.is_empty() or file.contains(_filter)):
			out.append(file)
	out.sort()
	return out


func _run_one(file: String, script: GDScript) -> int:
	var inst: Object = script.new()
	if inst == null or not inst.has_method(&"run"):
		print("FAIL %s: no run() method" % file)
		if inst is Node:
			(inst as Node).free()
		return 1
	if inst is Node:
		root.add_child(inst as Node)
	var t0: int = Time.get_ticks_usec()
	var result: Variant = await inst.call(&"run")
	var ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	if inst is Node:
		(inst as Node).queue_free()
	if typeof(result) != TYPE_INT:
		print("FAIL %s: run() returned %s (script error?) [%.1f ms]" % [file, type_string(typeof(result)), ms])
		return 1
	var fails: int = int(result)
	print("%s %s fails=%d [%.1f ms]" % ["DONE" if fails == 0 else "FAIL", file, fails, ms])
	return fails if fails >= 0 else 1
