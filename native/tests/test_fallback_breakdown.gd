## T0: the GDScript fallback (no C++ ext) gives its breakdown obstacle the render detail the view needs.
## 가설: ✅ game._breakdown_cars() skips obstacles without detail.carKind → fallback breakdowns must carry it (Codex review).
extends RefCounted

const _DB := preload("res://core/db.gd")


func run() -> int:
	var fails := 0
	var tables: Dictionary = _DB.load_traffic_tables()
	var stage: Dictionary = _DB.find_stage(_DB.load_json(_DB.DATA_DIR + "/stages.json"), 1)
	var tb := TrafficBridge.new()
	tb.setup(stage, tables, -1, true)
	var bd := 0
	for o: Variant in tb.obstacles():
		var d: Dictionary = o
		if str(d.get("kind", "")) != "breakdown":
			continue
		bd += 1
		var det: Dictionary = d.get("detail", {})
		if not det.has("carKind") or str(det["carKind"]).is_empty():
			print("FAIL fallback breakdown %s has no detail.carKind" % d.get("id"))
			fails += 1
	if bd == 0:
		print("FAIL fallback produced no breakdown obstacle for stage 1")
		fails += 1
	else:
		print("PASS fallback breakdowns carry render detail (%d)" % bd)
	return fails
