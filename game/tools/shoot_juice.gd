# 打击感三件套 + 屏幕震动截图工具（14 清单 #3/#4 交付产物；不提交截图，输出 /tmp/juice_*.png）
# 用法（需显示服务，非 headless）：
#   /Applications/Godot.app/Contents/MacOS/Godot --path game -s tools/shoot_juice.gd
extends SceneTree

var _p: EncounterPortrait
var _sm: EncounterSM
var _stream: EventStream

func _init() -> void:
	call_deferred("_run")

func _snap(path: String) -> void:
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	img.save_png(path)
	print("[shoot] saved ", path)

func _atk(target: String, hit: bool, crit: bool, dmg: int) -> Dictionary:
	return {"attacker": "pc", "target": target, "hit": hit, "crit": crit, "fumble": false,
		"damage": dmg, "rolls": [20 if crit else 14], "keep": 20 if crit else 14,
		"atk_mod": 3, "target_ac": 11, "attacker_name": "白页者", "target_name": "小墨妖",
		"damage_rolls": [dmg]}

func _run() -> void:
	_p = (load("res://shell/portrait/encounter_portrait.tscn") as PackedScene).instantiate()
	root.add_child(_p)
	await process_frame
	_stream = EventStream.new()
	var board := Board.new(_stream)
	_sm = EncounterSM.new(board, _stream, Rng.new(11), "campaign01")
	_p.bind(_sm, AutoAgent.new())
	_sm.enter("N1-7")
	_sm.transition(EncounterSM.S_EXPLORE)
	var sd: GDScript = load("res://tools/shell_diff.gd")
	_sm.begin_combat(sd.battle_def())
	await process_frame
	await process_frame
	var target := _sm.first_alive_enemy()
	# ① 伤害数字飘字（暴击金色加大 + 普通白字 + 闪过灰字同屏）
	_stream.emit(EventTypes.BATTLE_ATTACK, _atk(target, true, true, 18), &"core", "N1-7")
	await create_timer(0.15).timeout
	_stream.emit(EventTypes.BATTLE_ATTACK, _atk(target, true, false, 9), &"core", "N1-7")
	_stream.emit(EventTypes.BATTLE_ATTACK, _atk("pc", false, false, 0), &"core", "N1-7")
	await create_timer(0.25).timeout # 飘字上飘中段
	await _snap("/tmp/juice_numbers.png")
	await create_timer(1.0).timeout # 等飘字散尽、震动归位
	# ② 击杀消散（墨色碎片粒子 + 单位淡出；单独发死亡事件，碎片团不被飘字遮挡）
	_stream.emit(EventTypes.BATTLE_DEAD, {"unit": target, "name": "小墨妖"}, &"core", "N1-7")
	await create_timer(0.2).timeout # 碎片飞散中段
	await _snap("/tmp/juice_dissolve.png")
	await create_timer(1.0).timeout
	# ③ 屏幕震动帧（暴击大震 5px/0.3s 进行中）
	var other := _sm.first_alive_enemy()
	if other == "":
		other = "pc"
	_stream.emit(EventTypes.BATTLE_ATTACK, _atk(other, true, true, 16), &"core", "N1-7")
	await create_timer(0.12).timeout # 大震进行中
	await _snap("/tmp/juice_shake.png")
	print("[shoot] done: numbers/dissolve/shake")
	quit()
