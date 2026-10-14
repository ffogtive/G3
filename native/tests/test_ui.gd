extends RefCounted
## T0 UI / input / FX contract (M1b–M1d, DESIGN_REVIEW P0 #1 #2 #4 #6), against the IFACE-shaped UiStubState fixtures:
##  - input: 압정 zone hold = fire level + one edge per press, swipe down = brake held until the finger lifts, keys
##    Space/J fire, ↓/S brake, release_all clears, three fingers = debug_requested; old swipe / horn contract intact.
##  - HUD: 압정 / 분노 / 경적 / lanes ≥ 64 pt and inside the safe rect (59 / 34 pt notch + home bar), fire ring + reticle
##    follow lock.in_range, out of range points the player to the villain lane, hint chip one line ≤ 16 chars,
##    N1 bar = GameSim progress / distance, no debug badge in the HUD, phase visibility (kill hides the controls).
##  - reticle: on screen it sits exactly on Camera3D.unproject_position of the target car.
##  - camera P0#4: player + villain 30 m apart both land inside 70 % width and the band above the controls.
##  - result card P0#6: time / min HP / tows straight from the result, ★2 fails with a tow, "포상금 ×1.5" wording.
##  - FX: deterministic under a seed, kill explosion spawns and fully expires, release wave runs front → tail.
##  - world: gantry fade uses a depth pre-pass and dissolves completely near the camera (no lattice).
##  - r3 U1 (device feedback 4 "말풍선이 위에 빌런까지 거리 게이지바에 겹침"): bubble bodies never cover the top HUD
##    (bar · pill · villain plate · combo badge · neck chip) for anchors above / on / under the HUD, with and without a
##    notch: flip under the anchor, or dock under the HUD (one docked bubble per frame, red border for the villain).
##  - r3 U4: damage pops merge per target (tack stack), ≤ 2 live per target by priority, stay inside the safe rect,
##    and the kill clears the stale ones.
##  - r3 U2: combo badge n / 20-cell bar / next reward / timeout line / break states; neck verb chip clear of the HUD.
## 가설(r3 U1/U4): ✅ the overlap was the bubble body knowing only the N5 icon rects (side slide); a top guard from the
##       HUD + flip / dock makes it 0 by construction. ✅ a tack stack per target + a 2-per-target cap ends the
##       "column of numbers" over the villain.

const GameScene: PackedScene = preload("res://view/game.tscn")

var _fails: int = 0
var _tree: SceneTree


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " ui: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	_tree = Engine.get_main_loop() as SceneTree
	_input_contract()
	await _hud_contract()
	_result_model()
	await _fx_determinism()
	await _camera_and_reticle()
	await _gantry()
	await _bubble_guard()
	await _bubble_dock()
	await _pops_merge()
	await _combo_badge()
	return _fails


# ───────────────────────────── r3 fixtures (GameSim state() shapes: skills.combo, neck, checkpoints)

static func _combo(n: int, left: float = 1.2, next_n: int = 10, next_id: String = "c10", next_name: String = "따다닥") -> Dictionary:
	return {"n": n, "left": left, "next_n": next_n, "next_id": next_id, "next_name": next_name, "best": n, "timeout": 1.5,
		"cycle": 20, "marks": [5, 10, 15, 20]}


## Boss fight state with the r3 skills block (mode fight, t1 ready, face wave) + combo + an active neck chip.
static func _r3_boss(combo: Dictionary, neck_chip: String = "", prelock: bool = false) -> Dictionary:
	var st: Dictionary = UiStubState.boss(true)
	st["skills"] = {"segs": 1, "rage_tiers_ready": [1], "next_tier": 1, "mode": "fight", "execute_frac": 0.0, "active": {},
		"items": [], "skip_ready": false, "enabled": true, "face": "wave", "prelock": prelock, "chase": false, "combo": combo}
	if prelock:
		(st["lock"] as Dictionary)["active"] = false
	st["neck"] = {"on": neck_chip != "", "active": neck_chip != "", "valve": "honk", "chip": neck_chip, "id": -1000,
		"phase": "block" if neck_chip != "" else "gone", "exit": "", "t": 3.2, "how": "", "safety_left": 2.8, "enabled": true,
		"s": 245.0, "x": 9.0, "len": 4.5, "w": 1.9, "kind": "cutter", "car": "sedan", "v": 4.0, "blinker": 0, "exit_t": 0.0}
	return st


func _hud_with(safe_pt: Vector2) -> Array:
	var inp := LaneInput.new()
	_tree.root.add_child(inp)
	var hud := Hud.new()
	hud.manual = true
	_tree.root.add_child(hud)
	hud.bind_input(inp)
	hud.debug_safe_pt = safe_pt
	hud.apply_safe_area()
	return [hud, inp]


## U1: anchors y −200 / 0 / 60 / 300 × x across the 540 width × notch (0, 0) / (59, 34) × jam / boss (combo badge +
## neck chip shown): no bubble body meets the bar, pill, villain plate, combo badge or neck chip.
func _bubble_guard() -> void:
	var texts: Array[String] = ["빵!", "멀리서 빵빵? 흥!"]
	for safe_pt: Vector2 in [Vector2.ZERO, Vector2(59, 34)]:
		var hi: Array = _hud_with(safe_pt)
		var hud: Hud = hi[0]
		var b := Bubbles.new()
		hud.root.add_child(b)
		hud.root.move_child(b, 0)
		for ph: String in ["jam", "boss", "prelock"]:
			var st: Dictionary = UiStubState.jam(0.4) if ph == "jam" else _r3_boss(_combo(7), "붙어서 빵!", ph == "prelock")
			hud.apply_state(st)
			hud.advance(0.5)
			await _tree.process_frame
			hud.advance(0.05)
			hud.guard_bubbles(b)
			var rects: Array[Rect2] = []
			var names: PackedStringArray = []
			for c: Control in [hud._bar, hud._pill, hud._boss, hud._combo_w, hud._neck_chip]:
				if c.visible:
					rects.append(c.get_global_rect())
					names.append(str(c.name))
			var sr: Rect2 = hud.safe_rect()
			var bad: int = 0
			var legacy_bad: int = 0
			var n: int = 0
			var modes: Dictionary = {}
			var first: String = ""
			for y: float in [-200.0, 0.0, 60.0, 300.0]:
				for x: float in [8.0, 60.0, 150.0, 270.0, 400.0, 480.0, 532.0]:
					for text: String in texts:
						for kind: String in ["taunt", "angry"]:
							var e: Dictionary = b.layout_bubble(Vector2(x, y), text, kind)
							var lg: Dictionary = b.layout_bubble(Vector2(x, y), text, kind, true)
							n += 1
							modes[str(e["mode"])] = int(modes.get(str(e["mode"]), 0)) + 1
							var body: Rect2 = e["body"]
							var hit: bool = body.position.x < sr.position.x or body.end.x > sr.end.x or body.position.y < sr.position.y
							for r: Rect2 in rects:
								hit = hit or body.intersects(r)
								if (lg["body"] as Rect2).intersects(r):
									legacy_bad += 1
									break
							if hit:
								bad += 1
								if first.is_empty():
									first = "(%d, %d) %s → %s %s" % [x, y, text, e["mode"], body]
			var guard: float = hud.top_guard_y()
			var g_ok: bool = true
			for r: Rect2 in rects:
				g_ok = g_ok and guard >= r.end.y + 6.0 - 0.01
			_check(bad == 0 and n == 112 and g_ok and rects.size() >= 2,
				"U1 %s notch %s: %d/%d bubble bodies clear of [%s] (guard %.0f, modes %s; pre-r3 layout %d overlaps)%s" % [ph, safe_pt,
				n - bad, n, ",".join(names), guard, JSON.stringify(modes), legacy_bad, "" if first.is_empty() else " first bad " + first])
		hud.queue_free()
		(hi[1] as Node).queue_free()
	await _tree.process_frame


## U1: anchors above the guard dock under the HUD — the newest one only per frame, the villain's with a red border;
## an anchor under the guard whose body would reach the HUD flips under its anchor (tail up, tip on the anchor).
func _bubble_dock() -> void:
	var hi: Array = _hud_with(Vector2(59, 34))
	var hud: Hud = hi[0]
	var b := Bubbles.new()
	hud.root.add_child(b)
	hud.apply_state(_r3_boss(_combo(7)))
	hud.advance(0.5)
	await _tree.process_frame
	hud.guard_bubbles(b)
	var guard: float = hud.top_guard_y()
	b.step(1.0)
	b.show_bubble("h1", "끼워줘요~", "taunt", 3.0, func() -> Vector2: return Vector2(200, -100))
	b.step(1.1)
	b.show_bubble("v0", "어딜 감히!", "taunt", 3.0, func() -> Vector2: return Vector2(300, -40))
	b.step(1.2)
	b.show_bubble("h2", "흥!", "angry", 3.0, func() -> Vector2: return Vector2(100, 30))
	b.show_bubble("h3", "어서 가요", "thanks", 3.0, func() -> Vector2: return Vector2(270, 760))
	var lay: Array[Dictionary] = b.layout()
	var docked: Array[String] = []
	var keys: Array[String] = []
	for e: Dictionary in lay:
		keys.append(str(e["key"]))
		if str(e["mode"]) == "dock":
			docked.append(str(e["key"]))
	var dock_y: float = INF
	for e: Dictionary in lay:
		if str(e["mode"]) == "dock":
			dock_y = (e["body"] as Rect2).position.y
	_check(docked == ["h2"] and keys.has("h3") and not keys.has("h1") and not keys.has("v0") and absf(dock_y - (guard + 4.0)) < 0.5,
		"U1 dock: 3 anchors above the HUD → only the newest docks at guard + 4 (%s at %.0f, guard %.0f), the on-screen one still draws %s" % [
		str(docked), dock_y, guard, str(keys)])
	b.step(5.0)  # all expired
	b.show_bubble("v0", "어딜 감히!", "taunt", 3.0, func() -> Vector2: return Vector2(300, -40))
	var lv: Array[Dictionary] = b.layout()
	_check(lv.size() == 1 and str(lv[0]["mode"]) == "dock" and bool(lv[0]["villain"]) and (lv[0]["border"] as Color).is_equal_approx(Bubbles.VILLAIN_RED),
		"U1 dock: the villain's taunt docks with the red border")
	var anchor := Vector2(270, guard + 20.0)
	var fl: Dictionary = b.layout_bubble(anchor, "멀리서 빵빵? 흥!", "taunt")
	_check(str(fl["mode"]) == "flip" and (fl["body"] as Rect2).position.y >= anchor.y + 10.0 and (fl["tip"] as Vector2).distance_to(anchor) < 0.01,
		"U1 flip: anchor just under the HUD → body under the anchor, tail tip on it (%s %s)" % [fl["mode"], fl["body"]])
	var low: Dictionary = b.layout_bubble(Vector2(270, 700), "어서 가요", "thanks")
	_check(str(low["mode"]) == "up" and (low["body"] as Rect2).end.y <= 700.0 - 10.0, "U1: a bubble well under the HUD keeps the web look (body above its car)")
	hud.queue_free()
	(hi[1] as Node).queue_free()
	await _tree.process_frame


## U4: tack hits on one target stack into one number, ≤ 2 live pops per target, the pop rect stays inside the safe rect,
## the kill clears the stale pops.
func _pops_merge() -> void:
	var hi: Array = _hud_with(Vector2(59, 34))
	var hud: Hud = hi[0]
	var cam := Camera3D.new()
	hud.add_child(cam)
	hud.bind_world(cam, RoadGraph.new())
	hud.apply_state(UiStubState.boss(true))
	hud.advance(0.1)
	await _tree.process_frame
	var hit := func(dmg: float, window: bool = false, popped: int = 0) -> Dictionary:
		return {"type": "hit", "target_id": 0, "dmg": dmg, "window": window, "immune": false, "kind": "tack", "popped": popped, "s": 255.0, "x": -5.4}
	var counts: Array[int] = []
	for i: int in 5:
		hud.on_event(hit.call(4.0))
		counts.append(hud.pops.pop_count())
		hud.advance(0.2)
	var last: String = hud.pops.texts_pops()[-1] if not hud.pops.texts_pops().is_empty() else ""
	_check(counts.max() <= 2 and last == "-%d" % (5 * 4 * Hud.DMG_SHOW_MUL),
		"U4: 5 tack hits on one target in 1 s → %s pops, last text '%s' (want -%d)" % [str(counts), last, 5 * 4 * Hud.DMG_SHOW_MUL])
	hud.on_event(hit.call(4.0, true))
	var win_txt: String = hud.pops.texts_pops()[-1]
	_check(win_txt == "-%d!" % (6 * 4 * Hud.DMG_SHOW_MUL) and hud.pops.pop_count() == 1,
		"U4: a window hit joins the stack and turns it gold ('%s')" % win_txt)
	# priority cap: tack stack + 펑크 + t3 ticks + sum + 경직 on one target → ≤ 2 live at any time, sum + 펑크 kept
	hud.pops.clear_pops()
	var live_max: int = 0
	var evs: Array[Dictionary] = [hit.call(3.0), hit.call(3.0, false, 1)]
	for i: int in 4:
		evs.append({"type": "skill_hit", "chan": "rage", "tier": 3, "id": "t3_carpet", "target_id": 0, "idx": i, "n": 4, "dmg": 3.0,
			"window": false, "immune": false, "popped": 1 if i == 3 else 0, "killed": false, "s": 254.9, "x": -6.45})
	evs.append({"type": "stun", "id": 0, "dur": 0.6})
	for e: Dictionary in evs:
		hud.on_event(e)
		live_max = maxi(live_max, hud.pops.live_count("v0"))
		hud.advance(0.03)
	var live_txt: PackedStringArray = hud.pops.texts_pops(true)
	_check(live_max <= 2 and live_txt.has("-%d" % (12 * Hud.DMG_SHOW_MUL)) and live_txt.has("펑크!"),
		"U4: ≤ 2 live pops per target by priority (max %d; live %s)" % [live_max, live_txt])
	# x clamp: a big pop anchored at x = 5 stays whole inside the safe rect through its punch
	hud.pops.clear_pops()
	hud.pops.pop_screen(Vector2(5, 520), "치명! -150", "big")
	hud.pops.pop_screen(Vector2(536, 600), "치명! -150", "big")
	var sr: Rect2 = hud.safe_rect()
	var outside: int = 0
	var frames: int = 0
	for i: int in 16:
		for r: Rect2 in hud.pops.pop_rects():
			frames += 1
			if not sr.encloses(r):
				outside += 1
		hud.advance(0.05)
	_check(outside == 0 and frames >= 20, "U4: big pops anchored at x = 5 / 536 stay inside the safe rect (%d/%d rects out)" % [outside, frames])
	# kill: stale pops cleared, ≤ 1 left 0.2 s later
	hud.pops.clear_pops()
	for i: int in 3:
		hud.on_event(hit.call(4.0, false, 1 if i == 2 else 0))
		hud.advance(0.1)
	hud.on_event({"type": "skill_hit", "chan": "rage", "tier": 1, "id": "t1_wave", "target_id": 0, "idx": 0, "n": 1, "dmg": 9.0,
		"window": false, "immune": false, "popped": 0, "killed": false, "s": 254.9, "x": -6.45})
	hud.on_event({"type": "kill", "id": 0, "last": true, "s": 254.9, "x": -6.45})
	hud.advance(0.2)
	_check(hud.pops.pop_count() <= 1, "U4: 0.2 s after the kill ≤ 1 pop left (%d: %s)" % [hud.pops.pop_count(), hud.pops.texts_pops()])
	hud.queue_free()
	(hi[1] as Node).queue_free()
	await _tree.process_frame


## U2: combo badge (state.skills.combo) — n, 20-cell bar, next reward, timeout line, milestone pop beside it, break
## states; hidden outside the boss phase. Neck verb chip: shown with its text, clear of the top HUD, registered.
func _combo_badge() -> void:
	var hi: Array = _hud_with(Vector2.ZERO)
	var hud: Hud = hi[0]
	hud.apply_state(_r3_boss(_combo(7, 1.2)))
	hud.advance(0.3)
	await _tree.process_frame
	var cv: Dictionary = hud.combo_view()
	_check(str(cv.get("state", "")) == "live" and int(cv.get("n", 0)) == 7 and int(cv.get("cells", 0)) == 7 and str(cv.get("next", "")) == "따다닥"
		and absf(float(cv.get("left_frac", 0.0)) - 0.8) < 0.01 and hud._combo_w.visible,
		"U2 combo badge live: ×7, 7/20 cells, next '따다닥', timeout line 0.8 (%s)" % JSON.stringify(cv))
	hud.on_event({"type": "combo_milestone", "n": 10, "id": "c10", "target_id": 0, "skill": "c10_burst", "label": "따다닥!", "name": "따다닥"})
	hud.apply_state(_r3_boss(_combo(10, 1.5, 15, "c5", "따닥")))
	hud.advance(0.05)
	cv = hud.combo_view()
	_check(str(cv.get("pop", "")) == "따다닥!" and int(cv.get("cells", 0)) == 10 and str(cv.get("next", "")) == "따닥" and hud.banner.current() != "따다닥!",
		"U2 combo milestone: '따다닥!' pops beside the badge (not the centre banner), bar 10/20, next '따닥' (%s)" % JSON.stringify(cv))
	hud.apply_state(_r3_boss(_combo(20, 1.5, 25, "c5", "따닥")))
	hud.advance(0.05)
	var full: int = int(hud.combo_view().get("cells", 0))
	hud.on_event({"type": "combo_break", "reason": "hit", "n": 20})
	hud.apply_state(_r3_boss(_combo(0, 0.0, 5, "c5", "따닥")))
	hud.advance(0.1)
	cv = hud.combo_view()
	var broken: bool = str(cv.get("state", "")) == "broken" and str(cv.get("text", "")) == "콤보 끊김" and int(cv.get("n", 0)) == 20
	hud.advance(1.0)
	var off_after: String = str(hud.combo_view().get("state", ""))
	hud.apply_state(_r3_boss(_combo(6, 0.1, 10)))
	hud.advance(0.05)
	hud.on_event({"type": "combo_break", "reason": "timeout", "n": 6})
	hud.apply_state(_r3_boss(_combo(0, 0.0, 5, "c5", "따닥")))
	hud.advance(0.05)
	var fading: String = str(hud.combo_view().get("state", ""))
	_check(full == 20 and broken and off_after == "off" and fading == "fading",
		"U2 combo states: ×20 = full bar (%d), hit → grey '콤보 끊김' then off (%s), timeout → fade (%s)" % [full, off_after, fading])
	hud.apply_state(UiStubState.jam(0.4))
	hud.advance(0.5)
	_check(not hud._combo_w.visible, "U2 combo badge hidden outside the boss phase")
	# neck verb chip (boss before the lock)
	hud.apply_state(_r3_boss(_combo(0, 0.0, 5, "c5", "따닥"), "붙어서 빵!", true))
	hud.advance(0.5)
	await _tree.process_frame
	hud.advance(0.05)
	var chip_r: Rect2 = hud._neck_chip.get_global_rect()
	var clash: PackedStringArray = []
	for c: Control in [hud._bar, hud._pill, hud._boss, hud._combo_w, hud._btn_pause, hud._release_w]:
		if c.visible and c.get_global_rect().intersects(chip_r):
			clash.append(str(c.name))
	var reg: bool = false
	for r: Rect2 in hud.reserved_rects():
		reg = reg or r.encloses(chip_r)
	_check(hud._neck_chip.visible and hud.neck_chip_text() == "붙어서 빵!" and clash.is_empty() and reg and hud.safe_rect().encloses(chip_r)
		and hud.top_guard_y() >= chip_r.end.y + 6.0 - 0.01,
		"U2 neck chip '%s' shown at %s: clear of the top HUD %s, in reserved_rects %s, under the guard %.0f" % [hud.neck_chip_text(), chip_r,
		str(clash), reg, hud.top_guard_y()])
	hud.queue_free()
	(hi[1] as Node).queue_free()
	await _tree.process_frame


func _touch(inp: LaneInput, idx: int, pos: Vector2, pressed: bool) -> void:
	var t := InputEventScreenTouch.new()
	t.index = idx
	t.position = pos
	t.pressed = pressed
	inp.inject(t)


func _drag(inp: LaneInput, idx: int, pos: Vector2) -> void:
	var d := InputEventScreenDrag.new()
	d.index = idx
	d.position = pos
	inp.inject(d)


func _input_contract() -> void:
	var inp := LaneInput.new()
	_tree.root.add_child(inp)
	inp.pt_override = 1.0
	inp.set_zone("fire", Rect2(400, 900, 140, 140))
	_touch(inp, 0, Vector2(470, 970), true)
	var held: bool = inp.is_fire_down()
	var edge: bool = inp.consume_fire() and not inp.consume_fire()
	# swipe lanes with another finger while 압정 is held (multi-touch)
	_touch(inp, 1, Vector2(200, 600), true)
	_drag(inp, 1, Vector2(160, 602))
	var lane: int = inp.consume_lane()
	_touch(inp, 1, Vector2(160, 602), false)
	var still: bool = inp.is_fire_down()
	_touch(inp, 0, Vector2(470, 970), false)
	_check(held and edge and lane == -1 and still and not inp.is_fire_down(),
		"압정 zone: hold = fire level, one edge per press, lanes swipe while held, release = up")
	# swipe down = brake until the finger lifts
	_touch(inp, 2, Vector2(250, 500), true)
	_drag(inp, 2, Vector2(253, 530))
	var early: bool = inp.is_brake_down()
	_drag(inp, 2, Vector2(255, 548))
	var on: bool = inp.is_brake_down()
	_drag(inp, 2, Vector2(255, 640))
	var hold: bool = inp.is_brake_down()
	_touch(inp, 2, Vector2(255, 640), false)
	_check(not early and on and hold and not inp.is_brake_down() and inp.consume_lane() == 0 and not inp.consume_rage(),
		"swipe down ≥ 40 pt = brake held until the finger lifts (no lane / rage edge)")
	var k := InputEventKey.new()
	k.keycode = KEY_SPACE
	k.pressed = true
	inp.inject(k)
	var kf: bool = inp.is_fire_down()
	k.keycode = KEY_S
	inp.inject(k)
	var kb: bool = inp.is_brake_down()
	inp.release_all()
	_check(kf and kb and not inp.is_fire_down() and not inp.is_brake_down(), "keys Space = fire, S = brake; release_all clears both")
	var dbg: Array[int] = [0]
	inp.debug_requested.connect(func() -> void: dbg[0] += 1)
	for i: int in 3:
		_touch(inp, 10 + i, Vector2(100 + 50 * i, 400), true)
	for i: int in 3:
		_touch(inp, 10 + i, Vector2(100 + 50 * i, 400), false)
	_check(dbg[0] == 1, "three fingers down = debug_requested once (dev panel without an on-screen DBG tab)")
	# rvA: a fight chord (압정 held + ◀ held + a 분노 tap) must not open the dev panel on the Debug device build
	inp.set_zone("fire", Rect2(400, 800, 100, 100))
	inp.set_zone("left", Rect2(0, 800, 100, 100))
	inp.set_zone("rage", Rect2(400, 650, 100, 100))
	_touch(inp, 20, Vector2(450, 850), true)
	_touch(inp, 21, Vector2(50, 850), true)
	_touch(inp, 22, Vector2(450, 700), true)
	for i: int in 3:
		_touch(inp, 20 + i, Vector2.ZERO, false)
	inp.release_all()
	_check(dbg[0] == 1, "압정 + ◀ + 분노 (three button fingers) does not open the dev panel")
	inp.inject("fire:down")
	var injf: bool = inp.is_fire_down()
	inp.inject("fire:up")
	inp.inject("brake:down")
	var injb: bool = inp.is_brake_down()
	inp.inject("brake:up")
	_check(injf and injb and not inp.is_fire_down() and not inp.is_brake_down(), "inject fire:/brake: down/up")
	inp.queue_free()


func _hud_contract() -> void:
	var inp := LaneInput.new()
	_tree.root.add_child(inp)
	var hud := Hud.new()
	hud.manual = true
	_tree.root.add_child(hud)
	hud.bind_input(inp)
	hud.debug_safe_pt = Vector2(59, 34)
	hud.apply_safe_area()
	hud.apply_state(UiStubState.boss(true))
	hud.advance(0.5)
	await _tree.process_frame
	await _tree.process_frame
	hud._process(0.0)
	var sz: Dictionary = hud.button_sizes_pt()
	var small: PackedStringArray = []
	for n: String in sz:
		if float(sz[n]) < 64.0 - 0.01:
			small.append("%s=%.1f" % [n, float(sz[n])])
	_check(small.is_empty() and sz.size() == 5, "압정 / 분노 / 경적 / ◀ / ▶ all ≥ 64 pt %s %s" % [JSON.stringify(sz), " ".join(small)])
	var sr: Rect2 = hud.safe_rect().grow(4.5)
	var rects: Array[Rect2] = hud.reserved_rects()
	var inside: int = 0
	for r: Rect2 in rects:
		inside += 1 if sr.encloses(r) else 0
	_check(inside == rects.size() and rects.size() >= 10, "boss HUD widgets inside the safe rect (%d/%d)" % [inside, rects.size()])
	var fire_r: Rect2 = hud._btn_fire.get_global_rect()
	var rage_r: Rect2 = hud._btn_rage.get_global_rect()
	var horn_r: Rect2 = hud._btn_horn.get_global_rect()
	var right_r: Rect2 = hud._btn_right.get_global_rect()
	_check(not fire_r.intersects(rage_r) and not fire_r.intersects(horn_r) and not horn_r.intersects(right_r)
		and fire_r.position.x > hud.safe_rect().get_center().x and fire_r.end.y >= hud.safe_rect().end.y - 40.0,
		"압정 bottom-right thumb corner, no control overlaps another")
	_check(hud.lock_in_range and hud.reticle.target.get("in_range") == true and hud._chip.visible,
		"in range: fire ring + reticle green, hint chip shown")
	var chip: String = hud.hint_text
	_check(chip.length() <= 16 and not chip.contains("\n") and chip == "발사 꾹 · 경직 노려", "hint chip one line ≤ 16 chars ('%s')" % chip)
	hud.apply_state(UiStubState.boss(false))
	var t: Dictionary = hud.reticle.target
	_check(not hud.lock_in_range and t.get("in_range") == false and int(t.get("dir", 0)) == -1 and hud.hint_text == "◀ 원흉 차로로",
		"out of range (lane 4 vs villain lane 0): grey reticle, chevrons ◀, chip '◀ 원흉 차로로'")
	# N1 from GameSim's single progress value
	hud.apply_state(UiStubState.jam(0.4))
	_check(is_equal_approx(hud.shown.x, 0.4) and is_equal_approx(hud.shown.y, 102.0) and hud.distance_label() == "원흉까지 102 m",
		"N1: bar and '원흉까지 N m' come from state.progress / distance_m (%s)" % hud.distance_label())
	# events → pops / banners / flash
	var cam := Camera3D.new()
	hud.add_child(cam)
	hud.bind_world(cam, RoadGraph.new())
	for e: Dictionary in UiStubState.events_fight():
		hud.on_event(e)
	_check(hud.pops._pops.size() >= 3 and hud._last_damage.get("amount") == 12, "hit / miss / damage events → pops ('-4', '빗나감!', '-12')")
	hud.apply_state(UiStubState.boss(true))
	hud.apply_state(UiStubState.kill())
	hud.advance(0.6)
	_check(not hud._btn_fire.visible and not hud._chip.visible and hud._boss.visible and hud.banner.current() == "참교육 완료!",
		"kill: controls + chip fade out, villain plate stays, '참교육 완료!' banner")
	var dbg_named: bool = false
	for n: Node in hud.find_children("*", "", true, false):
		if n is Button and (n as Button).text == "DBG":
			dbg_named = true
	_check(not dbg_named, "no DBG badge in the HUD (dev panel: F1 / three-finger tap)")
	# fail card defaults from the last damage event (honest: reason, last hit, tows)
	hud.show_fail({})
	var fd: Dictionary = hud.fail_card.data
	_check(hud.card_open() and str(fd["reason"]) == "원흉 상향등" and int(fd["hp_lost"]) == 12 and int(fd["tows"]) >= 1 and not inp.enabled,
		"fail card: reason / last hit from the damage event, input disabled while open")
	var got: Array[StringName] = []
	hud.card_choice.connect(func(c: StringName) -> void: got.append(c))
	(hud.fail_card._btns["retry"] as Button).pressed.emit()
	hud.fail_card.seek(1.0)
	(hud.fail_card._btns["retry"] as Button).pressed.emit()
	_check(got == [&"retry"], "fail card: retry ignored before 0.45 s (anti mis-tap), then card_choice(&\"retry\")")
	hud.hide_cards()
	_check(not hud.card_open() and inp.enabled, "hide_cards re-enables input")
	hud.queue_free()
	inp.queue_free()
	await _tree.process_frame


func _result_model() -> void:
	var st: Dictionary = {"id": 1, "title": "1차선 정속주행러", "highway": "경부고속도로", "direction": "부산 방향", "route": 1,
		"fine": 40000, "payout": 40000, "violation": "고속도로 지정차로 위반(제60조) 범칙금 승용 4만원", "villains": [{"color": 0xd9c9a3, "name": "정속주행 김사장"}]}
	var m0: Dictionary = ResultCard.model(UiStubState.result(0), {}, st)
	var m1: Dictionary = ResultCard.model(UiStubState.result(1), {}, st)
	_check(int(m0["stars"]) == 3 and int(m1["stars"]) == 2 and not bool((m1["missions"] as Array)[1]["done"]),
		"P0#6: a tow fails ★2 (3★ clean run vs 2★ with 1 tow)")
	_check(is_equal_approx(float(m1["time_s"]), 69.5) and int(m1["min_hp"]) == 0 and int(m1["tows"]) == 1,
		"P0#6: card time / min HP / tows are the stage totals from the result (not reset by the retry)")
	_check(float(m1["payout"]) < float(m0["payout"]) and float(m0["payout"]) > 0.0,
		"payout from Rewards: retry multiplier + fewer stars pay less (%d vs %d)" % [int(m1["payout"]), int(m0["payout"])])
	var rec: Dictionary = {"stars": 1, "payout": 12345, "missions": [{"label": "a", "done": true}, {"label": "b", "done": false},
		{"label": "c", "done": false}], "wallet": 52345, "wallet_before": 40000, "stage_name": "X", "tows": 2}
	var m2: Dictionary = ResultCard.model(UiStubState.result(0), rec, st)
	_check(int(m2["stars"]) == 1 and int(m2["payout"]) == 12345 and int(m2["tows"]) == 2 and float(m2["wallet"]) == 52345.0,
		"Progress.record_result() wins over the sim's own numbers (single evaluator, NATIVE_PARITY G4)")
	var src: String = FileAccess.get_file_as_string("res://ui/result_card.gd")
	_check(src.contains("\"포상금 ×%s\"") and not src.contains("★×"), "multiplier wording '포상금 ×1.5', not '★×1.5' (P0#6)")


func _fx_determinism() -> void:
	var a: Array = []
	for run_i: int in 2:
		var fx := FightFx.new()
		fx.manual = true
		_tree.root.add_child(fx)
		fx.setup(RoadGraph.new(), 42, {}, 200.0, -45.0)
		fx.on_event({"type": "kill", "id": 0, "s": 272.0, "x": -5.4}, UiStubState.kill())
		for i: int in 30:
			fx.advance(1.0 / 30.0)
		var p: Dictionary = (fx._parts[0] as Array)[0] if not (fx._parts[0] as Array).is_empty() else {}
		a.append([fx.counts(), p.get("p", Vector3.ZERO)])
		if run_i == 1:
			for i: int in 150:
				fx.advance(1.0 / 30.0)
			var c: Dictionary = fx.counts()
			_check(int(c["lit"]) + int(c["glow"]) + int(c["smoke"]) == 0, "kill explosion + confetti fully expire within 6 s (%s)" % JSON.stringify(c))
			fx.on_event({"type": "release", "open_lane": 0}, UiStubState.kill())
			var s0: float = fx.wave_s
			fx.advance(0.5)
			_check(is_equal_approx(s0, 200.0) and fx.wave_s < s0 - 30.0, "release wave starts at the jam front (200) and runs to the tail")
		fx.queue_free()
	_check(JSON.stringify(a[0]) == JSON.stringify(a[1]) and int((a[0][0] as Dictionary)["lit"]) > 20,
		"FX deterministic under a seed (same particle state twice: %s)" % JSON.stringify(a[0][0]))
	await _tree.process_frame


func _camera_and_reticle() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(540, 1168)
	_tree.root.add_child(vp)
	var road := RoadGraph.new()
	var cam := CameraRig.new()
	cam.road = road
	vp.add_child(cam)
	cam.current = true
	# P0#4: villain 30 m behind in lane 0, player in lane 1 → both framed
	var st: Dictionary = UiStubState.boss(true)
	(st["villains"] as Array)[0]["s"] = 227.0
	cam.target_s = 257.0
	cam.target_x = RoadGraph.lane_x(1.0)
	cam.apply_state(st)
	cam.snap()
	var ok: bool = true
	var worst: String = ""
	var pts: Array[Vector3] = [road.position(257.0, RoadGraph.lane_x(1.0)), road.position(227.0, RoadGraph.lane_x(0.0))]
	for p: Vector3 in pts:
		var sp: Vector2 = cam.unproject_position(p)
		var fx: float = sp.x / 540.0
		var fy: float = sp.y / 1168.0
		if fx < 0.15 or fx > 0.85 or fy < CameraRig.FRAME_Y.x - 0.02 or fy > CameraRig.FRAME_Y.y + 0.02:
			ok = false
		worst += " (%.2f, %.2f)" % [fx, fy]
	_check(ok, "P0#4 boss framing: player and villain 30 m apart inside 70 %% width and the band above the controls k=%.2f%s" % [cam.frame_k, worst])
	var r := Reticle.new()
	vp.add_child(r)
	r.camera = cam
	r.road = road
	r.set_target({"s": 227.0, "x": RoadGraph.lane_x(0.0), "len": 4.9, "active": true, "in_range": true, "dir": 0})
	r.advance(0.1)
	var want: Vector2 = cam.unproject_position(road.position(227.0, RoadGraph.lane_x(0.0)) + Vector3(0, 0.9, 0))
	_check(r.on_screen and r.screen_pos.distance_to(want) < 0.01 and r.screen_r >= 34.0, "reticle sits on the unprojected target car (%s vs %s)" % [r.screen_pos, want])
	vp.queue_free()
	await _tree.process_frame


func _gantry() -> void:
	var g: Game = GameScene.instantiate() as Game
	g.manual = true
	g.with_debug_panel = false
	_tree.root.add_child(g)
	var o: Dictionary = g.world.overheads[0]
	var gs: float = float(o["s"])
	var mi: MeshInstance3D = o["node"]
	g.world.update_overheads(g.road.position(gs - 40.0, 0.0) + Vector3(0, 21, 0))
	var far_vis: bool = mi.visible and float(o["f"]) > 0.99
	g.world.update_overheads(g.road.position(gs - 22.0, 0.0) + Vector3(0, 21, 0))
	var mid_f: float = float(o["f"])
	g.world.update_overheads(g.road.position(gs - 8.0, 0.0) + Vector3(0, 21, 0))
	var near_hidden: bool = not mi.visible
	var pre: bool = (o["frame_fade"] as StandardMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	_check(far_vis and mid_f > 0.05 and mid_f < 0.95 and near_hidden and pre,
		"gantry: opaque far, depth-prepass fade mid (%.2f), fully hidden under the camera (no translucent lattice)" % mid_f)
	g.queue_free()
	await _tree.process_frame
