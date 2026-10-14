## r3 T2 (unit): the fallback _Creep spawns the same per-stage content as C++ spawn_jam ②③ (layout shape, not RNG bits).
## 가설: ✅ on the device (fallback) every open stage got the same breakdown 73 m + cones 143 m, no cheaters, no minis and no
##       lane kinds, so 1-1 … 1-10 all felt the same (feedback r3 #3) and 압정 in the jam had no target (#2).
## Checks, stages 1-1 … 1-10 × seeds 1-3:
##   - shoulder obstacle kinds/counts, cheater count, minis_total within ±1 of C++ (exact when the ext is missing: the
##     fallback must follow stage.shoulder / approach.shoulder itself)
##   - lane kinds = stage.jamShape.lanes; the pass lane (1-5 lane 0) is not held behind the front wall after 6 s
##   - cars_behind_front(8, 30) is non-empty (frontRage bubbles), mini_target / mini_hit work (hit → down)
##   - LAMP_MINI bits mark the minis in read_into()
extends RefCounted

const _DB := preload("res://core/db.gd")

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " fallback_spawn: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var st_all: Variant = _DB.load_json(_DB.DATA_DIR + "/stages.json")
	var native: bool = TrafficBridge.native_available()
	var bad: PackedStringArray = []
	var rows: int = 0
	for sid: int in range(1, 11):
		var stage: Dictionary = _DB.find_stage(st_all, sid)
		for seed: int in [1, 2, 3]:
			var fb: Dictionary = _content(stage, seed, true)
			var want: Dictionary = _content(stage, seed, false) if native else _expected(stage)
			rows += 1
			var diff: String = _compare(fb, want)
			if diff != "":
				bad.append("1-%d s%d %s" % [sid, seed, diff])
	_check(bad.is_empty(), "shoulder kinds/counts, cheaters, minis within ±1 of %s over %d stage×seed (%s)" % [
		"C++" if native else "the stage spec", rows, "; ".join(bad) if not bad.is_empty() else "all match"])
	_lane_kinds(st_all)
	_front_rage_and_minis(st_all)
	return _fails


## {kinds: {kind: n}, cheaters, minis, lane_kind}
func _content(stage: Dictionary, seed: int, fb: bool) -> Dictionary:
	var br := TrafficBridge.new()
	br.setup(stage, _DB.load_traffic_tables(), seed, fb)
	var kinds: Dictionary = {}
	for o: Variant in br.obstacles():
		var k: String = str((o as Dictionary).get("kind", ""))
		kinds[k] = int(kinds.get(k, 0)) + 1
	var cheaters: int = 0
	if br.is_native():
		for sp: Dictionary in br.native().call(&"get_car_specs"):
			cheaters += 1 if bool(sp.get("is_cheater", false)) else 0
	else:
		var buf := PackedFloat32Array()
		br.read_into(buf)
		for i: int in br.count_npc():
			cheaters += 1 if int(buf[i * TrafficBridge.STRIDE + 2]) == Cfg.SHOULDER_LANE else 0
	var buf2 := PackedFloat32Array()
	br.read_into(buf2)
	var minis: int = 0
	for i: int in br.count_npc():
		if int(buf2[i * TrafficBridge.STRIDE + 7]) & TrafficBridge.LAMP_MINI:
			minis += 1
	return {"kinds": kinds, "cheaters": cheaters, "minis": minis, "lane_kind": br.info().get("lane_kind", PackedStringArray())}


## Spec-derived content (C++ spawn_jam ③) for runs without the ext.
func _expected(stage: Dictionary) -> Dictionary:
	var tables: Dictionary = _DB.load_traffic_tables()
	var sp: Dictionary = tables["config"]["traffic"]["spawn"]
	var appr: Dictionary = TrafficBridge.stage_setup(stage, tables)["approach"]
	var mode: String = str(appr.get("shoulder", "open"))
	var spec: Array = stage.get("shoulder") if stage.get("shoulder") is Array else sp.get("shoulderFallbackSpec", [])
	if mode in ["closed", "none"]:
		spec = []
	elif mode == "crowded":
		var f: Array = []
		for e: Variant in spec:
			if str((e as Array)[0]) != "cheater":
				f.append(e)
		f.append(["cheater", int(sp.get("crowdedCheaters", 3))])
		spec = f
	elif mode == "dark":
		spec = sp.get("darkSpec", [])
	elif mode == "debris":
		spec = sp.get("debrisSpec", [])
	var kinds: Dictionary = {}
	var cheaters: int = 0
	for e: Variant in spec:
		var k: String = str((e as Array)[0])
		var n: int = int((e as Array)[1])
		if k == "cheater":
			cheaters += n
		else:
			kinds[k] = int(kinds.get(k, 0)) + n
	if mode == "blocked":
		kinds["cones"] = int(kinds.get("cones", 0)) + int((sp.get("blocked", {}) as Dictionary).get("count", 5))
	var diff: float = float(stage.get("difficulty", stage.get("id", 1)))
	var mn: Dictionary = sp.get("minis", {})
	var minis: int = int(stage["minis"]) if stage.get("minis") != null else mini(int(mn.get("max", 4)), int(mn.get("base", 2)) + floori(diff / float(mn.get("perDifficulty", 3))))
	return {"kinds": kinds, "cheaters": cheaters, "minis": minis}


func _compare(a: Dictionary, b: Dictionary) -> String:
	var out: PackedStringArray = []
	var keys: Dictionary = {}
	for k: Variant in (a["kinds"] as Dictionary).keys():
		keys[k] = true
	for k: Variant in (b["kinds"] as Dictionary).keys():
		keys[k] = true
	for k: Variant in keys.keys():
		var na: int = int((a["kinds"] as Dictionary).get(k, 0))
		var nb: int = int((b["kinds"] as Dictionary).get(k, 0))
		if absi(na - nb) > 1 or (na == 0) != (nb == 0):
			out.append("%s fb %d vs %d" % [k, na, nb])
	if absi(int(a["cheaters"]) - int(b["cheaters"])) > 1:
		out.append("cheaters fb %d vs %d" % [a["cheaters"], b["cheaters"]])
	if absi(int(a["minis"]) - int(b["minis"])) > 1 or (int(a["minis"]) == 0) != (int(b["minis"]) == 0):
		out.append("minis fb %d vs %d" % [a["minis"], b["minis"]])
	return " ".join(out)


func _lane_kinds(st_all: Variant) -> void:
	var bad: PackedStringArray = []
	for sid: int in range(1, 11):
		var stage: Dictionary = _DB.find_stage(st_all, sid)
		var br := TrafficBridge.new()
		br.setup(stage, _DB.load_traffic_tables(), 1, true)
		var lk: Variant = br.info().get("lane_kind", PackedStringArray())
		var want: Array = ["packed", "packed", "packed", "packed"]
		if stage.get("jamShape") is Dictionary and (stage["jamShape"] as Dictionary).get("lanes") is Array:
			var L: Array = stage["jamShape"]["lanes"]
			for i: int in mini(4, L.size()):
				if L[i] != null and str(L[i]) != "":
					want[i] = str(L[i])
		if not (lk is PackedStringArray) or Array(lk as PackedStringArray) != want:
			bad.append("1-%d %s want %s" % [sid, str(lk), str(want)])
	_check(bad.is_empty(), "fallback info().lane_kind follows jamShape.lanes on 1-1 … 1-10 (%s)" % ("; ".join(bad) if not bad.is_empty() else "ok"))
	# 1-5 lane 0 is a pass lane: no front wall, cars run ×passV past the villain's front line
	var st5: Dictionary = _DB.find_stage(st_all, 5)
	var br5 := TrafficBridge.new()
	br5.setup(st5, _DB.load_traffic_tables(), 1, true)
	var front: float = float(br5.setup_info()["front_s"])
	var si: Dictionary = br5.setup_info()
	var p: Dictionary = {"lane": float(si["start_lane"]), "s": float(si["start_s"]), "v": 0.0, "x": Cfg.lane_x(int(si["start_lane"])), "mode": "test"}
	var vmax0: float = 0.0
	for i: int in roundi(6.0 / Cfg.TICK):
		p["time"] = (i + 1) * Cfg.TICK
		br5.step(Cfg.TICK, p)
		br5.events()
	var ahead: int = 0
	for id: int in br5.cars_in_lane(0, front - 3.0, front + 400.0):
		ahead += 1
		vmax0 = maxf(vmax0, float(br5.car_info(id).get("v", 0.0)))
	_check(ahead >= 1 and vmax0 > 2.4 * 2.0, "1-5 fallback pass lane 0: %d cars past the front wall after 6 s (max v %.1f m/s > 2× jamSpeed)" % [ahead, vmax0])


func _front_rage_and_minis(st_all: Variant) -> void:
	var stage: Dictionary = _DB.find_stage(st_all, 1)
	var br := TrafficBridge.new()
	br.setup(stage, _DB.load_traffic_tables(), 1007, true)
	var cs: PackedInt32Array = br.cars_behind_front(8, 30.0)
	_check(cs.size() >= 1, "fallback cars_behind_front(8, 30) on 1-1 → %d cars (frontRage bubbles need ≥ 1)" % cs.size())
	# put the player right behind the first mini (lane 3) and shoot it down
	var buf := PackedFloat32Array()
	br.read_into(buf)
	var mid: int = 0
	var ms: float = 0.0
	for i: int in br.count_npc():
		if int(buf[i * TrafficBridge.STRIDE + 7]) & TrafficBridge.LAMP_MINI:
			mid = int(buf[i * TrafficBridge.STRIDE])
			ms = buf[i * TrafficBridge.STRIDE + 4]
			break
	if mid == 0:
		_check(false, "fallback 1-1 has a mini (LAMP_MINI)")
		return
	br.sync_player({"lane": 3.0, "s": ms - 12.0, "v": 0.0, "x": Cfg.lane_x(3)})
	var tgt: int = br.mini_target()
	var r1: String = br.mini_hit(mid, 4.0)
	var r2: String = br.mini_hit(mid, 4.0)
	var r3: String = br.mini_hit(mid, 4.0)
	br.read_into(buf)
	var lamp_off: bool = true
	for i: int in br.count_npc():
		if int(buf[i * TrafficBridge.STRIDE]) == mid:
			lamp_off = (int(buf[i * TrafficBridge.STRIDE + 7]) & TrafficBridge.LAMP_MINI) == 0
	_check(tgt == mid and r1 == "hit" and r2 == "hit" and r3 == "down" and lamp_off and br.mini_hit(mid, 4.0) == "",
		"fallback mini: target %d (want %d), hp 12 → hit/hit/down (%s/%s/%s), LAMP_MINI cleared %s" % [tgt, mid, r1, r2, r3, lamp_off])
