extends SceneTree
## Headless test runner (NATIVE_PORT 4-2, T0).
##   godot47 --headless --path native -s res://tests/run_tests.gd -- [--suite=unit|perf|all] [--filter=<substr>] [--list]
##
## Discovers res://tests/test_*.gd (sorted). Each test script:
##   - extends RefCounted (or Node; Nodes are added under /root while they run and freed afterwards),
##   - exposes `func run() -> int` returning its number of failures (it may `await`),
##   - may declare `const SUITE := "perf"` (default "unit"); --suite=all runs everything.
## Convention for output lines: "PASS ...", "FAIL ...", "INFO ...", "SKIP ...".
## A script that fails to load, lacks run(), or returns a non-int counts as 1 failure. Every GDScript
## runtime error raised while a test runs adds 1 failure too: GDScript carries on after such an error
## and a typed `-> int` function can still return 0, so the runner watches the log (OS.add_logger).
## Engine errors (push_error, C++ ERR_FAIL_*) are reported as INFO but not counted, so error-path
## tests stay possible.
## Exit code = total failures, capped at 125 so an 8-bit exit status never wraps to 0.

const TEST_DIR: String = "res://tests"
const EXIT_CAP: int = 125

## Counts errors logged while a test runs (called from any thread, hence the mutex).
class ErrorCounter extends Logger:
	var _mutex: Mutex = Mutex.new()
	var _script_errors: int = 0
	var _engine_errors: int = 0
	var _first_script_error: String = ""

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		_mutex.lock()
		if error_type == Logger.ERROR_TYPE_SCRIPT:
			_script_errors += 1
			if _first_script_error.is_empty():
				_first_script_error = "%s:%d %s %s" % [file, line, function, rationale if not rationale.is_empty() else code]
		elif error_type == Logger.ERROR_TYPE_ERROR:
			_engine_errors += 1
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	## Returns [script_errors, engine_errors, first_script_error] and resets the counters.
	func take() -> Array:
		_mutex.lock()
		var out: Array = [_script_errors, _engine_errors, _first_script_error]
		_script_errors = 0
		_engine_errors = 0
		_first_script_error = ""
		_mutex.unlock()
		return out


var _errors: ErrorCounter = ErrorCounter.new()
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
	OS.add_logger(_errors)
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
		_errors.take()
		var script: GDScript = load(path) as GDScript
		_errors.take()  # parse errors are already covered by the load failure below
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
	OS.remove_logger(_errors)
	if _list_only:
		quit(0)
		return
	print("SUMMARY files=%d fails=%d time=%.2fs" % [ran, total_fails, (Time.get_ticks_msec() - t0) / 1000.0])
	# game.tscn tests start music / SFX: stop them and let the mix thread free the playbacks (wall clock) before quitting,
	# otherwise the exit reports them as leaked resources (test_audio.gd teardown note)
	var au: Node = root.get_node_or_null(^"Audio")
	if au != null and au.has_method(&"stop_all"):
		au.call(&"stop_all")
		var t_ms: int = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t_ms < 250:
			await process_frame
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
	_errors.take()
	var t0: int = Time.get_ticks_usec()
	var result: Variant = await inst.call(&"run")
	var ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	if inst is Node:
		(inst as Node).queue_free()
	var logged: Array = _errors.take()
	var script_errors: int = int(logged[0])
	if int(logged[1]) > 0:
		print("INFO %s: %d engine error(s) logged (not counted)" % [file, int(logged[1])])
	var fails: int = 0
	if typeof(result) != TYPE_INT:
		print("FAIL %s: run() returned %s, not int" % [file, type_string(typeof(result))])
		fails = 1
	else:
		fails = int(result) if int(result) >= 0 else 1
	if script_errors > 0:
		print("FAIL %s: %d GDScript runtime error(s), first: %s" % [file, script_errors, logged[2]])
		fails += script_errors
	print("%s %s fails=%d [%.1f ms]" % ["DONE" if fails == 0 else "FAIL", file, fails, ms])
	return fails
