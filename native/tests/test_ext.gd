extends RefCounted
## T0: the C++ "traffic" GDExtension loads headless and its M1-0 placeholder API behaves.
## SKIPs (0 fails, INFO line) when this platform's library has not been built, so a clean checkout or
## the Mac runs green without a Linux .so. Build it with: bash tools/godot/build_ext.sh
##
## Uses ClassDB / dynamic calls only, never the `Traffic` identifier, so this file still parses when
## the extension is absent.

const GDEXT_PATH: String = "res://ext/traffic.gdextension"
const CLASS: StringName = &"Traffic"
const TICK: float = 1.0 / 120.0

var _fails: int = 0


func run() -> int:
	if not FileAccess.file_exists(GDEXT_PATH):
		_check(false, "%s exists (tracked manifest)" % GDEXT_PATH)
		return _fails
	var lib: String = _library_for_this_platform()
	if lib.is_empty():
		print("SKIP test_ext: %s has no [libraries] entry for this platform" % GDEXT_PATH)
		return 0
	if not FileAccess.file_exists(lib) and not DirAccess.dir_exists_absolute(lib):  # .framework is a dir
		print("SKIP test_ext: %s not built (run tools/godot/build_ext.sh)" % lib)
		return 0

	var via: String = "extension_list.cfg"
	if not ClassDB.class_exists(CLASS):
		# Not registered by the editor scan yet (fresh .godot/): load the manifest explicitly.
		var status: GDExtensionManager.LoadStatus = GDExtensionManager.load_extension(GDEXT_PATH)
		via = "GDExtensionManager.load_extension -> %d" % status
	_check(ClassDB.class_exists(CLASS), "ClassDB.class_exists(&\"Traffic\") (%s, lib %s)" % [via, lib.get_file()])
	if not ClassDB.class_exists(CLASS):
		return _fails

	_check(ClassDB.is_parent_class(CLASS, &"RefCounted"), "Traffic extends RefCounted (sim objects are RefCounted, 3-2)")
	for m: StringName in [&"tick", &"count", &"get_tick_count", &"get_sim_time", &"build_info"]:
		_check(ClassDB.class_has_method(CLASS, m), "Traffic.%s is bound" % m)

	var traffic: Object = ClassDB.instantiate(CLASS)
	_check(traffic != null, "ClassDB.instantiate(Traffic)")
	if traffic == null:
		return _fails
	_check(int(traffic.call(&"count")) == 0, "count() == 0 before spawn")
	for i: int in 120:
		traffic.call(&"tick", TICK)
	_check(int(traffic.call(&"get_tick_count")) == 120, "120 ticks counted")
	var sim_time: float = float(traffic.call(&"get_sim_time"))
	_check(is_equal_approx(sim_time, 1.0), "120 x 1/120 s = 1.0 s sim time (got %.9f)" % sim_time)
	var info: String = str(ClassDB.class_call_static(CLASS, &"build_info"))
	_check(info.begins_with("traffic "), "build_info() = %s" % info)
	print("INFO test_ext: loaded=%s %s" % [GDExtensionManager.is_extension_loaded(GDEXT_PATH), info])
	return _fails


## Mirrors Godot's [libraries] lookup: the entry whose dot-separated tags are all active features,
## preferring the most specific one. Returns "" when nothing matches.
func _library_for_this_platform() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(GDEXT_PATH) != OK:
		return ""
	var best: String = ""
	var best_tags: int = -1
	for key: String in cfg.get_section_keys("libraries"):
		var tags: PackedStringArray = key.split(".")
		var all_match: bool = true
		for tag: String in tags:
			if not OS.has_feature(tag):
				all_match = false
				break
		if all_match and tags.size() > best_tags:
			best = str(cfg.get_value("libraries", key))
			best_tags = tags.size()
	return best


func _check(ok: bool, what: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		_fails += 1
