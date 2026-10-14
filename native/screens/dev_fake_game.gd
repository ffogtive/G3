class_name ScrFakeGame
extends Node
## Dev stand-in for res://view/game.tscn so the meta loop (dashboard → card → game → reward → dashboard) runs before
## the in-stage GameSim lands. Same surface the app expects from the real game:
##   in : stage_id: int, loadout: Dictionary, hosted: bool (set before add_child); intro_hold: bool + begin() (G2: the
##        app loads it behind the stage card held, then calls begin() on start)
##   out: stage_finished(result) once (CONTRACT + NATIVE_PARITY 7 G1 fields), pause_requested
## Buttons: 클리어 ★★★ / 클리어 HP 45 (★2) / 포기(메뉴) / 일시정지. auto_s ≥ 0 finishes by itself (★3) after that long.

signal stage_finished(result: Dictionary)
signal pause_requested

var stage_id: int = 1
var loadout: Dictionary = {}
var hosted: bool = false
## G2: true while the stage card is up (the intro "plays" but nothing counts); begin() releases it.
var intro_hold: bool = false
var began: int = 0
var auto_s: float = -1.0
var finished: bool = false
var elapsed: float = 0.0
var _layer: CanvasLayer


## Plausible result with the web formulas (main.js showResult): freed = displayKm × 4 lanes × 125/km,
## missions = [cleared, hp_end ≥ 60, all minis], cath 12..100, score = hits + freed·5 + cath·40.
static func make_result(id: int, minis_all: bool = true, hp_end: int = 82, aborted: bool = false) -> Dictionary:
	var st: Dictionary = (ScrProgressStub._json("res://data/stages.json") as Dictionary).get("stages", [])[clampi(id - 1, 0, 99)]
	var km: float = float(st.get("displayKm", 2.0))
	var freed: int = roundi(km * 4.0 * 125.0)
	var n_minis: int = mini(4, 2 + int(floor(float(st.get("difficulty", 1)) / 3.0)))
	var cath: int = 78 if hp_end >= 60 else 61
	var hits: int = 6000
	var t: float = 74.0 + float(id % 7) * 3.1
	return {
		"stage_id": id, "cleared": not aborted, "aborted": aborted, "time_s": t, "min_hp": mini(hp_end, 40), "hp_end": hp_end,
		"hp_max": int(loadout_default().get("hp_max", 100)), "tows": 0, "fails": 0, "retry_mul": 1.0,
		"payout_base": int(st.get("payout", st.get("fine", 30000))), "fine": int(st.get("fine", 30000)), "card": str(st.get("card", "고지서")),
		"missions_done": [not aborted, hp_end >= 60, minis_all], "villain_name": ScrKit.villain_names(st),
		"minis_done": n_minis if minis_all else 0, "minis_total": n_minis,
		"score": hits + freed * 5 + cath * 40, "freed": freed, "cath": cath, "cheaters": 1,
		"mini_fines": 50000 * n_minis if minis_all else 0, "seed": (id * 131 + 7) % 997 + 1, "photo": null,
		"stats": [],   # extra (boss) lines only: Progress builds the standard 7 lines from the facts above
	}


static func loadout_default() -> Dictionary:
	return {"hp_max": 100}


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 5
	add_child(_layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(root)
	var bd := ScrBackdrop.new()
	root.add_child(bd)
	var st: Dictionary = (ScrProgressStub._json("res://data/stages.json") as Dictionary).get("stages", [])[clampi(stage_id - 1, 0, 99)]
	var v: VBoxContainer = ScrKit.vbox(16)
	v.set_anchors_preset(Control.PRESET_CENTER)
	v.custom_minimum_size = Vector2(440, 0)
	v.position = Vector2(-220, -260)
	root.add_child(v)
	var head: PanelContainer = ScrKit.panel(ScrKit.sb(Color(0.05, 0.07, 0.1, 0.85), 20, 4, 6, Lane1Pal.INK, Vector4(16, 12, 16, 12)))
	var hv: VBoxContainer = ScrKit.vbox(4)
	hv.add_child(ScrKit.lbl("DEV FAKE GAME", 20, Lane1Pal.AMBER, true))
	hv.add_child(ScrKit.para("STAGE %d · %s" % [stage_id, ScrKit.stage_title(st)], 28, Color.WHITE, true))
	var lo: String = "차 %s · 무기 %s · 피니시 %s" % [str(loadout.get("car", "-")), str((loadout.get("weapon", {}) as Dictionary).get("id", "-")) if loadout.get("weapon") is Dictionary else "-", str(loadout.get("finish", "-"))]
	var lol: Label = ScrKit.para(lo, 16, Lane1Pal.MUTED_LT, false)
	lol.name = "Loadout"
	hv.add_child(lol)
	head.add_child(hv)
	v.add_child(head)
	for row: Array in [["Clear3", "클리어 ★★★", Lane1Pal.BTN_YELLOW], ["Clear2", "클리어 · HP 45 (★2)", Lane1Pal.BTN_GREEN],
			["Abort", "포기 (메뉴로)", Lane1Pal.BTN_GREY], ["Pause", "일시정지", Lane1Pal.BTN_BLUE]]:
		var b: ScrKit.Pill = ScrKit.pill(str(row[1]), row[2], 28)
		b.name = str(row[0])
		var id: String = str(row[0])
		ScrKit.tap(b, func() -> void: _on_button(id))
		v.add_child(b)


func _on_button(id: String) -> void:
	match id:
		"Clear3":
			finish(make_result(stage_id, true, 82))
		"Clear2":
			finish(make_result(stage_id, true, 45))
		"Abort":
			finish(make_result(stage_id, false, 30, true))
		"Pause":
			pause_requested.emit()


func begin() -> void:
	intro_hold = false
	began += 1


func _process(delta: float) -> void:
	if finished or auto_s < 0.0 or intro_hold:
		return
	elapsed += delta
	if elapsed >= auto_s:
		finish(make_result(stage_id, true, 82))


## Emits stage_finished once.
func finish(result: Dictionary) -> void:
	if finished:
		return
	finished = true
	stage_finished.emit(result)
