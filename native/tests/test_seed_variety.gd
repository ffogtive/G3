extends RefCounted
## S1 (r3, device feedback 3 "매번 빌런까지 가는데 너무 똑같고 지루하네"): run seeds.
##   가설: ✅ every run was the same because the game seed was always id*1000+7 (view/game.gd seed −1). The run index
##         n = Progress.begin_play(id) mixed into the seed (Mulberry32.run_seed) changes the spawn on every run ≥ 1
##         while run 0 and the goldens stay byte-identical, and the varied runs still play out (both backends).
## Checks:
##   1. run_seed(id, 0) == traffic_seed(id) == id*1000+7 (spawn goldens); mix32 = murmur3 fmix32 reference values;
##      run_seed n ≥ 1 is in [0, 2^31), never the n = 0 seed, no collisions over 10 stages × 200 runs.
##   2. Spawn hash (bridge buffer + car specs + obstacles right after GameSim.setup) for 1-1~1-10 × n = 0..19 on both
##      backends: n = 0 == the default seed (−1) spawn; ≥ 95 % of the n ≥ 1 pairs differ; a tow retry (_setup_stage)
##      re-spawns the same jam (same seed).
##   3. ScrApp + the real game.tscn: card START ×3 (the held game behind the card keeps next_play's seed), then pause
##      다시하기 → runs 0, 1, (2), 3 with seeds run_seed(1, n); Progress plays{1} = 4 on disk.
##   4. Autopilot to the result card for 1-1~1-10 × N × both backends (the 병목 plug forced off, and on = the shipped
##      default since the r3 integration):
##      100 % finish (skip list excluded), jam time (jam → boss phase) p90 ≤ 40 s per backend over the ten stages. Runs
##      that do not finish or whose jam is > BAD_JAM_S must be listed in Progress.SEED_SKIP (begin_play steps over them);
##      a stale SKIP entry fails in an unsharded --full run. jam → lock (includes the neck plug) is printed as INFO.
##   5. r3 final (feel review blocker): the sloppy human bot (tests/human_bot.gd: late thumb, takes every let-in, ▶ by
##      GameSim.lane_blocker) on 1-4 × n = 0..19 × both backends, rage pols save + rightspam: jam → boss ≤ HUMAN_JAM_S.
##      가설: ✅ 1-4 n2 (breakdown 99 m, cones 104–194 m) stalled ~110 s after a let-in into lane 3 because a shoulder cone
##      blocked the merge back (can_merge) while driving on the shoulder smashes them; ❓ with cones not blocking the ▶
##      merge (smashed on entry) every run is ≤ 40 s. `--full`: 1-1~1-10.
## Suite e2e. Default N = 0..2 (neck on: 0..1), ~3 min. `-- --full`: N = 0..19 for both neck modes (the S1 gate,
## ~30 min; --stages=1,2,3 shards it for speed, but the p90 and stale checks only run over all ten). `--neck=off|on|both`.
## `--n=K`: K runs (n = 0..K−1) in every neck mode (e.g. the r3 integration gate `--neck=on --n=5`).
##   godot47 --headless --path native -s res://tests/run_tests.gd -- --suite=e2e --filter=test_seed_variety [--full]

const SUITE := "e2e"
const _DB := preload("res://core/db.gd")
const _Progress := preload("res://meta/progress.gd")
const STAGES: Array[int] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
const LIMIT_S: float = 200.0
const JAM_P90_S: float = 40.0
## A run index whose jam is longer than this (or that never reaches the result) is a "bad seed" → Progress.SEED_SKIP.
## 50 s: 1-5's run 0 is 44 s (its jam is the longest by design); the others stay under 30 s on every run index.
const BAD_JAM_S: float = 50.0
## r3 final: the human-bot jam gate (section 5).
const HUMAN_JAM_S: float = 40.0
const _Human := preload("res://tests/human_bot.gd")
## murmur3 fmix32 reference values (python: h ^= h >> 16; h *= 0x85ebca6b; h ^= h >> 13; h *= 0xc2b2ae35; h ^= h >> 16).
const MIX_REF: Dictionary = {0: 0, 1: 1364076727, 2: 821347078, 0xDEADBEEF: 233162409, 0xFFFFFFFF: 2180083513}
## run_seed reference values [id, n, seed] (same python formula).
const RUN_REF: Array = [[1, 0, 1007], [1, 1, 1547009873], [1, 2, 1380466098], [4, 1, 1973121363], [4, 5, 21285967],
	[10, 3, 1830602489], [100, 4, 2034022899]]

var _fails: int = 0
var _full: bool = false
var _stages: Array[int] = STAGES.duplicate()
var _neck: String = ""
var _n_runs: int = -1
var _stage_tbl: Dictionary = {}
var _bad: Dictionary = {}   # "id:n" -> true, over every _autoplay call


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " seed_variety: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	for a: String in OS.get_cmdline_user_args():
		if a == "--full":
			_full = true
		elif a.begins_with("--stages="):
			_stages.clear()
			for x: String in a.trim_prefix("--stages=").split(",", false):
				_stages.append(x.to_int())
		elif a.begins_with("--neck="):
			_neck = a.trim_prefix("--neck=")
		elif a.begins_with("--n="):
			_n_runs = maxi(1, a.trim_prefix("--n=").to_int())
	_stage_tbl = _DB.load_json("res://data/stages.json")
	_math()
	_spawn_hashes()
	await _app_wiring()
	var n_off: int = _n_runs if _n_runs > 0 else (20 if _full else 3)
	var n_on: int = _n_runs if _n_runs > 0 else (20 if _full else 2)
	var mode: String = _neck if not _neck.is_empty() else "both"
	if mode in ["off", "both"]:
		_autoplay(n_off, false)
	if mode in ["on", "both"]:
		_autoplay(n_on, true)
	if _full and mode == "both" and _stages == STAGES:
		_stale_skips()
	_human_gate()
	return _fails


# ───────────────────────────── 1. seed math

func _math() -> void:
	var zero_ok: bool = true
	for id: int in range(1, 101):
		zero_ok = zero_ok and Mulberry32.run_seed(id, 0) == id * 1000 + 7 and Mulberry32.run_seed(id, 0) == Mulberry32.traffic_seed(id)
	_check(zero_ok, "run_seed(id, 0) == traffic_seed(id) == id*1000+7 for 1..100 (first run and goldens unchanged)")
	var mix_ok: bool = true
	for x: int in MIX_REF:
		mix_ok = mix_ok and Mulberry32.mix32(x) == int(MIX_REF[x])
	_check(mix_ok, "mix32 = murmur3 fmix32 (reference values)")
	var ref_ok: bool = true
	for r: Array in RUN_REF:
		ref_ok = ref_ok and Mulberry32.run_seed(int(r[0]), int(r[1])) == int(r[2])
	_check(ref_ok, "run_seed reference values (python formula)")
	var seen: Dictionary = {}
	var range_ok: bool = true
	var clash: int = 0
	for id: int in STAGES:
		for n: int in range(1, 201):
			var s: int = Mulberry32.run_seed(id, n)
			range_ok = range_ok and s >= 0 and s <= 0x7FFFFFFF and s != Mulberry32.traffic_seed(id)
			clash += 1 if seen.has(s) else 0
			seen[s] = true
	_check(range_ok and clash == 0, "run_seed n ≥ 1: in [0, 2^31), never the n = 0 seed, %d collisions over 10 × 200" % clash)
	var skip_ok: bool = true
	for id: Variant in _Progress.SEED_SKIP:
		for n: Variant in _Progress.SEED_SKIP[id]:
			skip_ok = skip_ok and int(n) >= 1
	_check(skip_ok, "Progress.SEED_SKIP never lists run 0 (%s)" % str(_Progress.SEED_SKIP))


# ───────────────────────────── 2. spawn hashes

func _spawn_hash(sim: GameSim) -> String:
	var br: TrafficBridge = sim.bridge
	var buf := PackedFloat32Array()
	buf.resize(br.count() * TrafficBridge.STRIDE)
	br.read_into(buf)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(buf.to_byte_array())
	ctx.update(var_to_bytes(br.car_specs()))
	ctx.update(var_to_bytes(br.obstacles()))
	return ctx.finish().hex_encode()


## Coarse layout a player would notice: the lane + kind of the 24 NPC cars nearest ahead of the player (s order) and the
## shoulder obstacle kinds at 10 m resolution. INFO only (the gate is the exact spawn hash).
func _layout_sig(sim: GameSim) -> String:
	var br: TrafficBridge = sim.bridge
	var n: int = br.count_npc()
	var buf := PackedFloat32Array()
	buf.resize(br.count() * TrafficBridge.STRIDE)
	br.read_into(buf)
	var names: PackedStringArray = br.kind_names()
	var ahead: Array = []
	for i: int in n:
		var o: int = i * TrafficBridge.STRIDE
		if buf[o + 4] > sim.player.s:
			ahead.append([buf[o + 4], roundi(buf[o + 2]), int(buf[o + 1])])
	ahead.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var parts: PackedStringArray = []
	for k: int in mini(24, ahead.size()):
		var kind: int = int(ahead[k][2])
		parts.append("%d%s" % [int(ahead[k][1]), names[kind] if kind >= 0 and kind < names.size() else "?"])
	for o: Variant in br.obstacles():
		parts.append("%s@%d" % [str((o as Dictionary).get("kind", "")), roundi(float((o as Dictionary).get("s", 0.0)) / 10.0)])
	return ",".join(parts)


## neck: true / false forces the 병목 plug (tables.options.neck); null = the data default (on since the r3 integration).
func _new_sim(id: int, sd: int, fb: bool, neck: Variant = null) -> GameSim:
	var tables: Dictionary = _DB.load_traffic_tables()
	if neck is bool:
		tables["options"] = {"neck": neck}
	var sim := GameSim.new()
	sim.force_fallback = fb
	sim.setup(_DB.find_stage(_stage_tbl, id), tables, sd)
	return sim


func _spawn_hashes() -> void:
	for fb: bool in [false, true]:
		var tag: String = "fallback" if fb else "native"
		var base_ok: bool = true
		var retry_ok: bool = true
		var worst: float = 2.0
		var worst_id: int = 0
		var lines: PackedStringArray = []
		for id: int in _stages:
			var def: String = _spawn_hash(_new_sim(id, -1, fb))
			var hashes: Array[String] = []
			var sigs: Dictionary = {}
			for n: int in 20:
				var sim: GameSim = _new_sim(id, Mulberry32.run_seed(id, n), fb)
				var h: String = _spawn_hash(sim)
				if n > 0:
					sigs[_layout_sig(sim)] = true
				if n == 0:
					base_ok = base_ok and h == def and sim.seed == id * 1000 + 7
				else:
					hashes.append(h)
				if n == 1:
					sim.call(&"_setup_stage")
					retry_ok = retry_ok and _spawn_hash(sim) == h
			var pairs: int = 0
			var diff: int = 0
			for i: int in hashes.size():
				for j: int in range(i + 1, hashes.size()):
					pairs += 1
					diff += 1 if hashes[i] != hashes[j] else 0
			var ratio: float = float(diff) / float(maxi(1, pairs))
			lines.append("1-%d %.0f%% (coarse layouts %d/19)" % [id, ratio * 100.0, sigs.size()])
			if ratio < worst:
				worst = ratio
				worst_id = id
		print("INFO seed_variety: %s spawn pairs that differ (n = 1..19): %s" % [tag, ", ".join(lines)])
		_check(base_ok, "%s: n = 0 spawn == default seed (−1 → id*1000+7) spawn on every stage" % tag)
		_check(worst >= 0.95, "%s: ≥ 95 %% of n ≥ 1 spawn pairs differ on every stage (worst 1-%d %.1f %%)" % [tag, worst_id, worst * 100.0])
		_check(retry_ok, "%s: tow retry (_setup_stage) re-spawns the same jam (same seed)" % tag)


# ───────────────────────────── 3. app → game.tscn

func _app_wiring() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	ScrKit.feedback_enabled = false
	var app := ScrApp.new()
	app.private_save = "user://test_seed_variety/app_%d.json" % OS.get_process_id()   # shards run in parallel
	app.game_scene_path = ScrApp.REAL_GAME
	tree.root.add_child(app)
	await tree.process_frame
	var seeds: Array[int] = []
	var held: Array[int] = []
	var ns: Array[int] = []
	var same_node: Array[bool] = []
	for k: int in 2:
		app.show_card(1)
		await tree.process_frame
		var hg: Node = app.game
		held.append(int(hg.get(&"seed")) if hg != null else -99)
		app.start_from_card()
		for i: int in 3:
			await tree.process_frame
		same_node.append(app.game == hg)
		seeds.append(_game_seed(app.game))
		ns.append(_app_int(app, &"run_n"))
		app.reward_menu()
		await tree.process_frame
	app.show_card(1)
	await tree.process_frame
	app.start_from_card()
	await tree.process_frame
	app.show_pause()
	await tree.process_frame
	app.pause_menu.retry_requested.emit()
	for i: int in 3:
		await tree.process_frame
	seeds.append(_game_seed(app.game))
	ns.append(_app_int(app, &"run_n"))
	var want: Array[int] = [Mulberry32.run_seed(1, 0), Mulberry32.run_seed(1, 1), Mulberry32.run_seed(1, 3)]
	print("INFO seed_variety: app runs n=%s seeds=%s held=%s want=%s" % [ns, seeds, held, want])
	_check(held == [want[0], want[1]] and same_node == [true, true],
		"held game behind the card is built with next_play's seed and START keeps that node")
	_check(ns == [0, 1, 3] and seeds == want and _app_int(app, &"run_seed") == want[2],
		"runs 0, 1 → seeds 1007, run_seed(1, 1); pause 다시하기 (after the card's run 2) → run 3, a new seed")
	var pr: Object = app.meta.p
	var disk: Dictionary = (pr.get(&"store") as Node).call(&"load_progress")
	_check(pr.has_method(&"plays") and int(pr.call(&"plays", 1)) == 4 and int((disk.get("plays", {}) as Dictionary).get("1", -1)) == 4
		and int(pr.call(&"plays", 2)) == 0,
		"Progress plays{1} = 4 (saved), plays{2} = 0")
	app.reward_menu()
	await tree.process_frame
	(pr.get(&"store") as Node).call(&"wipe")
	app.queue_free()
	await tree.process_frame


## A property of the app (−99 when this build's ScrApp has none: the pre-S1 code fails with a FAIL line, not an error).
static func _app_int(app: Node, prop: StringName) -> int:
	return int(app.get(prop)) if prop in app else -99


func _game_seed(g: Node) -> int:
	if g == null:
		return -99
	var sim: Variant = g.get(&"sim")
	return int((sim as GameSim).seed) if sim is GameSim else int(g.get(&"seed"))


# ───────────────────────────── 4. autopilot matrix

func _run(id: int, n: int, fb: bool, neck_on: bool) -> Dictionary:
	var sd: int = Mulberry32.run_seed(id, n)
	var sim: GameSim = _new_sim(id, sd, fb, neck_on)
	sim.autopilot = Autopilot.new(sd * 13 + 1)
	var t_jam: float = -1.0
	var t_boss: float = -1.0
	var t_lock: float = -1.0
	while sim.time < LIMIT_S and sim.phase != &"result":
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			match str(e.get("type", "")):
				"phase":
					if str(e["phase"]) == "jam" and t_jam < 0.0:
						t_jam = sim.time
					elif str(e["phase"]) == "boss" and t_boss < 0.0:
						t_boss = sim.time
				"lock":
					if t_lock < 0.0:
						t_lock = sim.time
	var r: Dictionary = sim.state().get("result", {}) if sim.state().get("result") is Dictionary else {}
	return {"done": sim.phase == &"result", "phase": str(sim.phase), "time": sim.time,
		"jam": t_boss - t_jam if t_boss >= 0.0 and t_jam >= 0.0 else -1.0,
		"lock": t_lock - t_jam if t_lock >= 0.0 and t_jam >= 0.0 else -1.0, "tows": int(r.get("tows", 0)), "seed": sd}


func _autoplay(n_runs: int, neck_on: bool) -> void:
	var tag_neck: String = "neck on" if neck_on else "neck off"
	var bad: Dictionary = {}   # id -> {n: true}
	for fb: bool in [false, true]:
		var tag: String = "%s, %s" % ["fallback" if fb else "native", tag_neck]
		var jams: Array[float] = []
		var locks: Array[float] = []
		var spread: PackedStringArray = []
		var done: int = 0
		var total: int = 0
		var t0: int = Time.get_ticks_msec()
		for id: int in _stages:
			var row: PackedStringArray = []
			var lo: float = INF
			var hi: float = -INF
			for n: int in n_runs:
				var r: Dictionary = _run(id, n, fb, neck_on)
				var skipped: bool = n > 0 and (_Progress.SEED_SKIP.get(id, []) as Array).has(n)
				var is_bad: bool = not bool(r["done"]) or float(r["jam"]) > BAD_JAM_S or float(r["jam"]) < 0.0
				if is_bad:
					if not bad.has(id):
						bad[id] = {}
					bad[id][n] = true
				row.append("%d:%s%.0f/%.0f%s" % [n, "" if r["done"] else "✗", float(r["jam"]), float(r["lock"]), "s" if not skipped else "s(skip)"])
				if skipped:
					continue
				total += 1
				done += 1 if r["done"] else 0
				if float(r["jam"]) >= 0.0:
					jams.append(float(r["jam"]))
					lo = minf(lo, float(r["jam"]))
					hi = maxf(hi, float(r["jam"]))
				if float(r["lock"]) >= 0.0:
					locks.append(float(r["lock"]))
			print("INFO seed_variety: %s 1-%d jam→boss/jam→lock %s" % [tag, id, " ".join(row)])
			spread.append("1-%d %.0f–%.0f" % [id, lo, hi])
		jams.sort()
		locks.sort()
		print("INFO seed_variety: %s jam→boss range per stage: %s; jam→lock p50 %.1f s p90 %.1f s" % [tag, ", ".join(spread),
			locks[locks.size() / 2] if not locks.is_empty() else -1.0,
			locks[mini(locks.size() - 1, int(ceilf(0.9 * locks.size())) - 1)] if not locks.is_empty() else -1.0])
		var p90: float = jams[mini(jams.size() - 1, int(ceilf(0.9 * jams.size())) - 1)] if not jams.is_empty() else -1.0
		var p50: float = jams[jams.size() / 2] if not jams.is_empty() else -1.0
		print("INFO seed_variety: %s — %d/%d finished, jam p50 %.1f s p90 %.1f s max %.1f s [%d ms]" % [tag, done, total, p50, p90,
			jams.back() if not jams.is_empty() else -1.0, Time.get_ticks_msec() - t0])
		_check(done == total, "%s: autopilot finishes %d/%d runs (1-%s × n < %d, skip list excluded)" % [tag, done, total,
			",".join(PackedStringArray(_stages.map(func(x: int) -> String: return str(x)))), n_runs])
		if _stages == STAGES:   # the gate is over all ten stages (1-5 alone runs ~36-44 s: a subset proves nothing)
			_check(p90 >= 0.0 and p90 <= JAM_P90_S, "%s: jam (jam → boss) p90 %.1f s ≤ %.0f s" % [tag, p90, JAM_P90_S])
	var missing: PackedStringArray = []
	for id: Variant in bad:
		for n: Variant in bad[id]:
			_bad["%d:%d" % [int(id), int(n)]] = true
			if int(n) == 0:
				missing.append("1-%d n=0 (run 0 cannot be skipped)" % int(id))
			elif not (_Progress.SEED_SKIP.get(int(id), []) as Array).has(int(n)):
				missing.append("1-%d n=%d" % [int(id), int(n)])
	print("INFO seed_variety: %s bad runs (no result or jam > %.0f s): %s" % [tag_neck, BAD_JAM_S, str(bad)])
	_check(missing.is_empty(), "%s: every bad run index is in Progress.SEED_SKIP (missing: %s)" % [tag_neck, ", ".join(missing)])


## --full over every stage and both neck modes: a SEED_SKIP entry that measured fine in both is stale.
func _stale_skips() -> void:
	var stale: PackedStringArray = []
	for id: Variant in _Progress.SEED_SKIP:
		for n: Variant in _Progress.SEED_SKIP[id]:
			if not _bad.has("%d:%d" % [int(id), int(n)]):
				stale.append("1-%d n=%d" % [int(id), int(n)])
	_check(stale.is_empty(), "--full: no stale Progress.SEED_SKIP entry (%s)" % ", ".join(stale))


# ───────────────────────────── 5. sloppy human (r3 final)

func _human_run(id: int, n: int, fb: bool, pol: String) -> Dictionary:
	var sd: int = Mulberry32.run_seed(id, n)
	var sim: GameSim = _new_sim(id, sd, fb)
	sim.autopilot = _Human.new(sd * 13 + 1 + 100003, pol)
	var t_jam: float = -1.0
	var t_boss: float = -1.0
	var letin: int = 0
	while sim.time < 120.0 and t_boss < 0.0 and sim.phase != &"result":
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			match str(e.get("type", "")):
				"phase":
					if str(e["phase"]) == "jam" and t_jam < 0.0:
						t_jam = sim.time
					elif str(e["phase"]) == "boss" and t_boss < 0.0:
						t_boss = sim.time
				"honk_reply":
					letin += 1 if str(e.get("data", "")) == "letin" else 0
	return {"jam": t_boss - t_jam if t_boss >= 0.0 and t_jam >= 0.0 else INF, "letin": letin}


func _human_gate() -> void:
	var ids: Array[int] = [4]
	if _full:
		ids = STAGES.duplicate()
	var ns: int = 20
	for fb: bool in [false, true]:
		var tag: String = "fallback" if fb else "native"
		for pol: String in ["save", "rightspam"]:
			var worst: float = 0.0
			var worst_at: String = ""
			var rows: PackedStringArray = []
			var t0: int = Time.get_ticks_msec()
			for id: int in ids:
				if not _stages.has(id):
					continue
				for n: int in ns:
					var r: Dictionary = _human_run(id, n, fb, pol)
					rows.append("1-%d/%d:%.0f%s" % [id, n, minf(999.0, float(r["jam"])), "L" if int(r["letin"]) > 0 else ""])
					if float(r["jam"]) > worst:
						worst = float(r["jam"])
						worst_at = "1-%d n=%d" % [id, n]
			if rows.is_empty():
				continue
			print("INFO seed_variety: human %s %s jam→boss (L = took a let-in) %s [%d ms]" % [pol, tag, " ".join(rows), Time.get_ticks_msec() - t0])
			_check(worst <= HUMAN_JAM_S, "human bot (%s, %s): jam → boss ≤ %.0f s on every run (worst %.1f s at %s)" % [pol, tag,
				HUMAN_JAM_S, minf(999.0, worst), worst_at])
