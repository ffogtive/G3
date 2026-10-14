extends RefCounted
## T0: C++ spawnJam == web goldens (native/tests/golden/spawn_stage{1,5,6}.json + rng_trace_stage{1,5,6}.json).
##
## 가설: ❓ the C++ port draws the same tagged RNG sequence as the JS (trace = the contract, NATIVE_PORT 3-3),
##       so every car/obstacle/opp field matches bit-for-bit (s within 1e-6 is the stated bar).
## Also checks TrafficBridge.stage_setup() (main.js setupStage + boss.js villain records) against the goldens,
## and that the GDScript fallback spawns a plausible jam. SKIPs the C++ part when the ext is not built.

const GOLDEN: String = "res://tests/golden"
const STAGES: Array[int] = [1, 5, 6]
const S_TOL: float = 1e-6
const _DB := preload("res://core/db.gd")

var _fails: int = 0


func run() -> int:
	var tables: Dictionary = _DB.load_traffic_tables()
	var stages: Variant = _DB.load_json(_DB.DATA_DIR + "/stages.json")
	var native: bool = TrafficBridge.native_available()
	for id: int in STAGES:
		var golden: Dictionary = _DB.load_json("%s/spawn_stage%d.json" % [GOLDEN, id])
		var stage: Dictionary = _DB.find_stage(stages, id)
		_check(not stage.is_empty() and not golden.is_empty(), "stage %d: stages.json record + golden loaded" % id)
		if stage.is_empty() or golden.is_empty():
			continue
		_check_setup(id, stage, tables, golden)
		if native:
			_check_native(id, stage, tables, golden)
		_check_fallback(id, stage, tables)
	var st1: Dictionary = _DB.find_stage(stages, 1)
	if native:
		_check_bridge(st1, tables, false)
	_check_bridge(st1, tables, true)
	if not native:
		print("SKIP test_spawn: C++ Traffic not built — native spawn goldens not checked (bash tools/godot/build_ext.sh)")
	return _fails


func _check_setup(id: int, stage: Dictionary, tables: Dictionary, golden: Dictionary) -> void:
	var info: Dictionary = TrafficBridge.stage_setup(stage, tables)
	var gs: Dictionary = golden["setup"]
	_check(is_equal_approx(float(info["front_s"]), float(gs["frontS"])) and int(info["start_lane"]) == int(gs["startLane"])
			and bool(info["no_shoulder"]) == bool(gs["noShoulder"]),
			"stage %d: stage_setup frontS %.3f lane %d noShoulder %s == golden" % [id, info["front_s"], info["start_lane"], info["no_shoulder"]])
	var gv: Array = golden["villains"]
	var vs: Array = info["villains"]
	var ok: bool = gv.size() == vs.size()
	for i: int in mini(gv.size(), vs.size()):
		var a: Dictionary = vs[i]
		var b: Dictionary = gv[i]
		ok = ok and float(a["s"]) == float(b["s"]) and float(a["x"]) == float(b["x"]) and float(a["len"]) == float(b["len"]) \
				and float(a["w"]) == float(b["w"]) and float(a["vNominal"]) == float(b["vNominal"])
	_check(ok, "stage %d: %d villain record(s) (s, x, len, w, vNominal) == golden" % [id, gv.size()])
	_check(TrafficBridge.is_night(stage, tables) == bool(gs["night"]), "stage %d: night == %s" % [id, gs["night"]])


func _check_native(id: int, stage: Dictionary, tables: Dictionary, golden: Dictionary) -> void:
	var tr: Object = ClassDB.instantiate(&"Traffic")
	_check(bool(tr.call(&"configure", tables)), "stage %d: configure()" % id)
	if id == STAGES[0]:
		var missing: PackedStringArray = tr.call(&"get_missing_params")
		_check(missing.is_empty(), "configure: %d tunables read from config.json, missing %s" % [tr.call(&"get_loaded_params"), missing])
	var gp: Dictionary = golden["player"]
	tr.call(&"set_trace", true)
	var gs: Dictionary = golden["setup"]
	var ok_spawn: bool = tr.call(&"spawn_jam", stage, golden["villains"], {"s": gp["s"], "lane": gp["lane"], "len": gp["len"], "w": gp["w"]},
			int(gs["seed"]), bool(gs["night"]))
	_check(ok_spawn, "stage %d: spawn_jam(seed %d)" % [id, gs["seed"]])

	# RNG: draw count, next value, tagged trace
	var rng: Dictionary = golden["rng"]
	_check(int(tr.call(&"get_rng_draws")) == int(rng["draws"]), "stage %d: %d spawn draws (golden %d)" % [id, tr.call(&"get_rng_draws"), rng["draws"]])
	_check(float(tr.call(&"peek_rng")) == float((rng["next"] as Dictionary)["f"]),
			"stage %d: next draw %.10f == golden %.10f" % [id, tr.call(&"peek_rng"), (rng["next"] as Dictionary)["f"]])
	var trace: Array = tr.call(&"take_trace")
	var gtrace: Dictionary = _DB.load_json("%s/rng_trace_stage%d.json" % [GOLDEN, id])
	var calls: Array = gtrace.get("calls", [])
	var first_bad: int = -1
	for i: int in maxi(trace.size(), calls.size()):
		if i >= trace.size() or i >= calls.size():
			first_bad = i
			break
		var c: Dictionary = calls[i]
		if str((trace[i] as Array)[0]) != str(c["tag"]) or int((trace[i] as Array)[1]) != int(c["u32"]):
			first_bad = i
			break
	_check(first_bad < 0, "stage %d: rng trace %d calls, tags + u32 == rng_trace_stage%d.json%s" % [id, trace.size(), id,
			"" if first_bad < 0 else " (first diff at #%d: got %s want %s)" % [first_bad,
				trace[first_bad] if first_bad < trace.size() else "<end>", calls[first_bad] if first_bad < calls.size() else "<end>"]])

	# cars
	var cars: Array = tr.call(&"get_car_specs")
	var gcars: Array = golden["cars"]
	_check(cars.size() == gcars.size(), "stage %d: %d cars (golden %d)" % [id, cars.size(), gcars.size()])
	var bad: Array[String] = []
	var max_ds: float = 0.0
	for i: int in mini(cars.size(), gcars.size()):
		var a: Dictionary = cars[i]
		var b: Dictionary = gcars[i]
		max_ds = maxf(max_ds, absf(float(a["s"]) - float(b["s"])))
		var why: String = _diff_car(a, b)
		if not why.is_empty() and bad.size() < 4:
			bad.append("car %d: %s" % [b["id"], why])
	_check(bad.is_empty() and max_ds <= S_TOL, "stage %d: cars id/kind/lane/s/x/v/len/w/wall/cheater/personal/phase/color/seed/variant/mini == golden (max |ds| %s) %s"
			% [id, str(max_ds), bad])
	var walls: int = 0
	var minis: int = 0
	var fr: Array = golden["frontRow"]
	for c: Dictionary in cars:
		walls += 1 if bool(c["is_wall"]) else 0
		minis += 1 if c["mini"] != null else 0
		if bool(c["is_wall"]):
			var lane_idx: int = int(c["lane"])
			_check(fr[lane_idx] != null and int(fr[lane_idx]) == int(c["id"]), "stage %d: frontRow[%d] == car %d" % [id, lane_idx, c["id"]])
	var counts: Dictionary = golden["counts"]
	_check(walls == int(counts["walls"]) and minis == int(counts["minis"]), "stage %d: walls %d minis %d == golden" % [id, walls, minis])

	# obstacles
	var obs: Array = tr.call(&"get_obstacles")
	var gobs: Array = golden["obstacles"]
	var ob_ok: bool = obs.size() == gobs.size()
	var ob_why: String = ""
	for i: int in mini(obs.size(), gobs.size()):
		var a: Dictionary = obs[i]
		var b: Dictionary = gobs[i]
		for k: String in ["id", "kind", "s", "x", "len", "w", "smash", "hazard"]:
			if a[k] != b[k] and not (a[k] is float and b[k] is float and float(a[k]) == float(b[k])) \
					and not (typeof(a[k]) in [TYPE_INT, TYPE_FLOAT] and typeof(b[k]) in [TYPE_INT, TYPE_FLOAT] and float(a[k]) == float(b[k])):
				ob_ok = false
				ob_why = "obstacle %d.%s %.17g != %.17g" % [b["id"], k, a[k], b[k]] if a[k] is float else "obstacle %d.%s %s != %s" % [b["id"], k, a[k], b[k]]
		var da: Dictionary = a["detail"]
		var db: Dictionary = b["detail"]
		if str(b["kind"]) == "breakdown":
			for k: String in ["carKind", "carLen", "color", "rotY", "triangle", "variant"]:
				if not _same(da.get(k), db.get(k)):
					ob_ok = false
					ob_why = "obstacle %d.detail.%s %s != %s" % [b["id"], k, da.get(k), db.get(k)]
		elif str(b["kind"]) == "debris":
			var ba: Array = da.get("boxes", [])
			var bb: Array = db.get("boxes", [])
			var same_boxes: bool = ba.size() == bb.size() and _same(da.get("tireX"), db.get("tireX"))
			for j: int in mini(ba.size(), bb.size()):
				for k: String in ["x", "z", "rotY"]:
					same_boxes = same_boxes and _same((ba[j] as Dictionary)[k], (bb[j] as Dictionary)[k])
			if not same_boxes:
				ob_ok = false
				ob_why = "obstacle %d debris pieces differ" % b["id"]
	_check(ob_ok, "stage %d: %d obstacles (id, kind, s, x, len, w, smash, hazard, detail) == golden %s" % [id, gobs.size(), ob_why])

	# opposite carriageway
	var opp: Array = tr.call(&"get_opp")
	var gopp: Array = golden["opp"]
	var opp_ok: bool = opp.size() == gopp.size()
	for i: int in mini(opp.size(), gopp.size()):
		var a: Dictionary = opp[i]
		var b: Dictionary = gopp[i]
		opp_ok = opp_ok and int(a["j"]) == int(b["j"]) and str(a["kind"]) == str(b["kind"]) and _same(a["s"], b["s"]) \
				and _same(a["v"], b["v"]) and int(a["color"]) == int(b["color"])
	_check(opp_ok, "stage %d: %d opposite cars (j, kind, s, v, color) == golden" % [id, gopp.size()])

	# traffic state
	var info: Dictionary = tr.call(&"get_info")
	var gt: Dictionary = golden["traffic"]
	var lk: PackedStringArray = info["lane_kind"]
	_check(_same(info["front_line"], gt["frontLine"]) and _same(info["front_v"], gt["frontV"]) and _same(info["s_tail"], gt["sTail"])
			and bool(info["zigzag"]) == bool(gt["zigzag"]) and bool(info["shoulder_closed"]) == bool(gt["shoulderClosed"])
			and Array(lk) == (gt["laneKind"] as Array),
			"stage %d: traffic state frontLine/frontV/sTail/zigzag/shoulderClosed/laneKind == golden" % id)
	var ga: Dictionary = gt["approach"]
	_check(str(info["shoulder"]) == str(ga["shoulder"]) and bool(info["gap_check"]) == bool(ga["gapCheck"])
			and bool(info["fatigue"]) == bool(ga["fatigue"]) and _same(info["rubber"], ga["rubber"]) and _same(info["rage_horn"], ga["rageHorn"]),
			"stage %d: approach {shoulder %s gapCheck %s fatigue %s rubber %s rageHorn %s} == golden" % [id, info["shoulder"], info["gap_check"],
				info["fatigue"], info["rubber"], info["rage_horn"]])


func _diff_car(a: Dictionary, b: Dictionary) -> String:
	var pairs: Array = [["id", "id"], ["kind_name", "kind"], ["lane", "lane"], ["x", "x"], ["v", "v"], ["len", "len"], ["w", "w"],
		["is_wall", "isWall"], ["is_cheater", "isCheater"], ["personal", "personal"], ["phase", "phase"], ["color", "color"],
		["seed", "seed"], ["variant", "variant"], ["slow", "slow"], ["lc_t", "lcT"], ["lc_dur", "lcDur"], ["v_free", "vFree"]]
	for p: Array in pairs:
		if not _same(a[p[0]], b[p[1]]):
			return "%s %s != %s" % [p[1], a[p[0]], b[p[1]]]
	if absf(float(a["s"]) - float(b["s"])) > S_TOL:
		return "s %.9f != %.9f" % [a["s"], b["s"]]
	if bool(b["isWall"]) and not _same(a["wall_offset"], b["wallOffset"]):
		return "wallOffset"
	if bool(b["isCheater"]) and not _same(a["cheater_v"], b["cheaterV"]):
		return "cheaterV %s != %s" % [a["cheater_v"], b["cheaterV"]]
	var ma: Variant = a["mini"]
	var mb: Variant = b["mini"]
	if (ma == null) != (mb == null):
		return "mini presence"
	if mb != null:
		var x: Dictionary = ma
		var y: Dictionary = mb
		if str(x["type"]) != str(y["type"]) or not _same(x["cool"], y["cool"]) or not _same(x["hp"], y["hp"]):
			return "mini %s != %s" % [x, y]
	return ""


func _check_fallback(id: int, stage: Dictionary, tables: Dictionary) -> void:
	var br := TrafficBridge.new()
	br.setup(stage, tables, -1, true)
	var n: int = br.count_npc()
	var buf := PackedFloat32Array()
	br.read_into(buf)
	var ok_buf: bool = buf.size() == br.count() * TrafficBridge.STRIDE and br.count() == n + 26
	var lanes_ok: bool = true
	for i: int in n:
		var lane: int = int(buf[i * TrafficBridge.STRIDE + 2])
		lanes_ok = lanes_ok and lane >= 0 and lane <= 4 and int(buf[i * TrafficBridge.STRIDE + 1]) >= 0
	_check(not br.is_native() and n > 40 and ok_buf and lanes_ok and br.kind_names().size() > 8,
			"stage %d: GDScript fallback spawns %d cars + 26 opposite, buffer %d floats, kinds valid" % [id, n, buf.size()])


## The fixed sim<->view interface (TrafficBridge) behaves the same on both backends.
func _check_bridge(stage: Dictionary, tables: Dictionary, fallback: bool) -> void:
	var tag: String = "bridge[%s]" % ("gdscript" if fallback else "c++")
	var br := TrafficBridge.new()
	br.setup(stage, tables, -1, fallback)
	_check(br.is_native() == not fallback, "%s: backend selected" % tag)
	var names: PackedStringArray = br.kind_names()
	_check(names.has("sedan") and names.has("bus") and br.count() == br.count_npc() + 26, "%s: kind_names() %d kinds, count() %d = %d NPC + 26 opposite"
			% [tag, names.size(), br.count(), br.count_npc()])
	var ps: float = 0.0
	for k: int in 600:
		ps += 1.0 * Cfg.TICK
		br.step(Cfg.TICK, {"lane": 3.0, "s": ps, "v": 1.0, "x": Cfg.lane_x(3)})
	var buf := PackedFloat32Array()
	br.read_into(buf)
	var n: int = br.count()
	var ok: bool = buf.size() == n * TrafficBridge.STRIDE
	var seen: Dictionary = {}
	for i: int in n:
		var o: int = i * TrafficBridge.STRIDE
		var id: int = int(buf[o])
		var lane: int = int(buf[o + 2])
		seen[id] = true
		if i < br.count_npc():
			ok = ok and lane >= 0 and lane <= 4 and int(buf[o + 1]) >= 0 and int(buf[o + 1]) < names.size()
		else:
			ok = ok and lane <= -1 and lane >= -4 and is_equal_approx(buf[o + 5], PI) and id >= TrafficBridge.OPP_ID_BASE
		ok = ok and is_finite(buf[o + 3]) and is_finite(buf[o + 4]) and int(buf[o + 7]) >= 0 and int(buf[o + 7]) < 256
	_check(ok and seen.size() == n, "%s: read_into() after 600 ticks: %d records x %d floats, unique ids, lanes/kinds/lamp bits in range"
			% [tag, n, TrafficBridge.STRIDE])
	var mid := PackedFloat32Array()
	br.read_into(mid, 0.5)
	_check(mid.size() == buf.size(), "%s: read_into(buf, alpha 0.5) (interpolated)" % tag)
	var ev: Array[Dictionary] = br.events()
	var ev2: Array[Dictionary] = br.events()
	_check(ev2.is_empty(), "%s: events() drains (%d events after 600 ticks)" % [tag, ev.size()])
	var h: Dictionary = br.honk(3, ps)
	_check(str(h.get("kind", "?")) in ["", "cheater", "yield", "letin", "noway", "villain", "tired"] and h.has("id"),
			"%s: honk(3, s) -> {kind '%s', id %s}" % [tag, h.get("kind"), h.get("id")])
	var hr: Array[Dictionary] = br.events()
	_check(hr.size() >= 1 and str(hr[-1]["type"]) == "honk_reply", "%s: honk raises a honk_reply event" % tag)
	_check(br.request_lane(3, 1, ps) == false and typeof(br.request_lane(3, 2, ps)) == TYPE_BOOL, "%s: request_lane() rejects a 2-lane jump, answers adjacent" % tag)
	var specs: Array[Dictionary] = br.car_specs()
	_check(specs.size() == n and str(specs[0]["kind_name"]) == names[int(specs[0]["kind"])], "%s: car_specs() %d records, kind_name == kind_names()[kind]" % [tag, specs.size()])
	# MultiMesh transforms. Layout (basis.x.x, basis.y.x, basis.z.x, origin.x, … per row) was verified by a
	# MultiMesh.buffer round trip under Xvfb + Mobile; headless uses a dummy RenderingServer that does not
	# read buffers back, so decode it here.
	var ids := PackedInt32Array()
	for i: int in n:
		ids.append(int(buf[i * TrafficBridge.STRIDE]))
	ids.append(-12345)  # unknown id -> zero scale
	var tb: PackedFloat32Array = br.transforms_for(ids, 1.0)
	var tf_ok: bool = tb.size() == ids.size() * 12
	for i: int in ids.size():
		if not tf_ok:
			break
		var b: int = i * 12
		var got := Transform3D(Basis(Vector3(tb[b], tb[b + 4], tb[b + 8]), Vector3(tb[b + 1], tb[b + 5], tb[b + 9]),
				Vector3(tb[b + 2], tb[b + 6], tb[b + 10])), Vector3(tb[b + 3], tb[b + 7], tb[b + 11]))
		if i == n:
			tf_ok = got.basis.get_scale().is_zero_approx()
			continue
		var o: int = i * TrafficBridge.STRIDE
		var want := Transform3D(Basis(Vector3.UP, buf[o + 5]), Vector3(buf[o + 3], 0.0, -buf[o + 4]))
		tf_ok = got.is_equal_approx(want)
	_check(tf_ok, "%s: transforms_for() == Transform3D(Basis(UP, yaw), (x, 0, -s)) in MultiMesh buffer layout, unknown id -> zero scale" % tag)


func _same(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == null and b == null
	if typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT]:
		return float(a) == float(b)
	if typeof(a) == TYPE_BOOL or typeof(b) == TYPE_BOOL:
		return bool(a) == bool(b)
	return str(a) == str(b)


func _check(ok: bool, what: String) -> void:
	if ok:
		print("PASS test_spawn: %s" % what)
	else:
		_fails += 1
		print("FAIL test_spawn: %s" % what)
