# 可玩引导（TASKS P1.5 TP2/TP3）：启动加载 packs/campaign01 → 按 manifest presentation 路由壳形态
# → 进入脚本化遭遇 N1-7 午夜墨雨（战役书 §4 SL-1 / §7：教学 Boss 墨魈；encounters.json 登记 battle/easy/max5）。
# 壳路由（09 §2/§3/§8、tech/02 §2.1）：mode=choice 按启动参数 `-- --mode=space|time`（缺省 time）；
# forced 幕（SL-0/SL-3）强制竖屏并打印叙事化提示；遭遇开始后壳锁定，单局内禁止切换。
# 战斗数值取自 prototype/data.js 的轻规则切片并对齐 11 §8 武器骰表；
# 正式落位应为 packs 的 characters/skills/enemies.json（tech/04），TP2 以引导脚本承载（见交付留白）。
# 调试：`-- --tp2-shots` 竖屏自动推进并截图 /tmp/tp2_*.png；`-- --tp3-shot` 横屏战斗态截图
# /tmp/tp3_landscape.png（均不提交）。
extends Node

const BATTLE_SEED := 20261108
const BATTLE_NODE := "N1-7"
const BATTLE_LINE := "SL-1" # N1-7 属 SL-1「褪色的街」（nodes.json act 字段；SL-1 mode=choice）
const LANDSCAPE_SIZE := Vector2i(1280, 720)
const SHELL_SCENES := {
	&"time": "res://shell/portrait/encounter_portrait.tscn",
	&"space": "res://shell/landscape/encounter_landscape.tscn",
}

var stream: EventStream
var board: Board
var sm: EncounterSM
var agent: AutoAgent
var router := ShellRouter.new()
var shell: Control
var portrait: EncounterPortrait
var landscape: EncounterLandscape
var settle_panel: PanelContainer
var settle_text: RichTextLabel
var _shots_mode := "" # "", "tp2", "tp3"

func _ready() -> void:
	_setup_cjk_font()
	var args := OS.get_cmdline_user_args()
	if args.has("--tp2-shots"):
		_shots_mode = "tp2"
	elif args.has("--tp3-shot"):
		_shots_mode = "tp3"
	# 加载战役包（tech/02 §1/§2；TP1 加载管线复用）
	var res := PackLoader.load_pack("res://packs/campaign01")
	if not res["ok"]:
		push_error("campaign01 加载失败：%s" % ";".join(res["errors"]))
		return
	print("[main] campaign01 加载成功：", (res["pack"]["nodes"] as Dictionary).size(), " 节点")
	# 壳选择路由（09 §2/§3；tech/02 §2.1）：choice 按启动参数，forced 幕强制
	var presentation: Dictionary = (res["pack"]["manifest"] as Dictionary).get("presentation", {})
	var route := ShellRouter.resolve(presentation, args, BATTLE_LINE)
	if _shots_mode == "tp2":
		route["mode"] = ShellRouter.MODE_TIME # 截图模式固定壳，保持 TP2 证据可复现
	elif _shots_mode == "tp3":
		route["mode"] = ShellRouter.MODE_SPACE
	var mode: StringName = route["mode"]
	if str(route.get("notice", "")) != "":
		print("[main] ", route["notice"]) # 强制形态叙事化提示（09 §3）
	print("[main] 壳形态：", mode, "（", "强制" if bool(route["forced"]) else "玩家选择/默认", "）")
	if mode == ShellRouter.MODE_SPACE and DisplayServer.get_name() != "headless":
		get_window().size = LANDSCAPE_SIZE
		get_window().move_to_center()
	stream = EventStream.new()
	board = Board.new(stream)
	sm = EncounterSM.new(board, stream, Rng.new(BATTLE_SEED), "campaign01")
	agent = AutoAgent.new()
	shell = (load(SHELL_SCENES[mode]) as PackedScene).instantiate()
	add_child(shell)
	if shell is EncounterPortrait:
		portrait = shell
		portrait.bind(sm, agent)
		portrait.set_rooms(["N1-1", "N1-3", "N1-7", "N1-8"], 2,
			{"N1-1": "自由市广场", "N1-3": "见证撤销", "N1-7": "午夜墨雨", "N1-8": "三份邀约"})
	else:
		landscape = shell
		landscape.bind(sm, agent)
	_build_settle_panel()
	stream.subscribe(_on_event)
	# 序章带入（叙事既定）：N1-1 商店补给药水 ×2、N1-3 见证撤销旗标（→ 首回合全队优势，11 §3.1 示例）
	var prov := {"event_id": 0, "node_id": "N1-1", "pack_id": "campaign01"}
	board.give_item("heal_potion", 2, prov)
	board.write("campaign01.witnessed_revocation", true,
		{"event_id": 0, "node_id": "N1-3", "pack_id": "campaign01"})
	# 进场 → 探索（开场事件流投递完毕，09 §1）；遭遇开始即壳锁定（09 §8：单局内禁止切换）
	sm.enter(BATTLE_NODE)
	router.lock_encounter(mode)
	sm.transition(EncounterSM.S_EXPLORE)
	stream.emit(EventTypes.LOG, {"msg": "午夜，墨色的雨。雨点落地成字，字扭曲着立起——墨魈朝着广场上唯一的「空白」涌来。"},
		&"core", BATTLE_NODE)
	match _shots_mode:
		"tp2":
			_run_shots_tp2()
		"tp3":
			_run_shot_tp3()
		_:
			await get_tree().create_timer(1.5).timeout
			_start_battle()

# ---------------------------------------------------------------- 战斗脚本（N1-7 午夜墨雨）

func _battle_def() -> Dictionary:
	return {
		"party": [
			{"id": "pc", "name": "白页者", "kind": "player", "hp": 14, "max_hp": 14, "ac": 11,
				"attrs": {"might": 2, "finesse": 1, "wits": 0}, "attack_mod": 2, "damage": "1d6+2",
				"skills": [
					{"id": "inkbolt", "name": "墨术飞矢", "kind": "attack", "attr": "wits",
						"damage": "1d6", "uses": 2, "target": "enemy"},
					{"id": "inkshield", "name": "墨盾格挡", "kind": "utility", "uses": 1, "target": "self",
						"effect": {"attackers_disadvantage": true}},
				],
				"items": [{"id": "heal_potion", "name": "补给药水", "count": 2,
					"use": {"timing": "bonus_action", "heal": "1d4+2", "consume": true}}]},
			{"id": "kelan", "name": "珂兰", "kind": "companion", "hp": 10, "max_hp": 10, "ac": 11,
				"attrs": {"might": 0, "finesse": 1, "wits": 1}, "attack_mod": 1, "damage": "1d6+1",
				"skills": [{"id": "kelan_bolt", "name": "墨矢", "kind": "attack", "attr": "finesse",
					"damage": "1d6+1", "target": "enemy"}]},
			{"id": "laofei", "name": "老费", "kind": "companion", "hp": 12, "max_hp": 12, "ac": 12,
				"attrs": {"might": 1, "finesse": 0, "wits": 1}, "attack_mod": 1, "damage": "1d6+1",
				"skills": [{"id": "laofei_hook", "name": "船钩", "kind": "attack", "attr": "might",
					"damage": "1d6+1", "target": "enemy"}]},
		],
		"enemies": [
			{"id": "boss", "name": "墨魈", "hp": 16, "max_hp": 16, "ac": 11,
				"attrs": {"might": 1, "finesse": 1, "wits": 0}, "attack_mod": 3, "damage": "1d4+1",
				"skills": [{"id": "ink_rain", "name": "墨雨溅射", "kind": "aoe", "damage": "1d6",
					"uses": 2, "cooldown": 2,
					"save": {"attr": "finesse", "dc": 11, "on_success": "half"}}]},
			{"id": "imp1", "name": "墨魈幼体", "hp": 8, "max_hp": 8, "ac": 10,
				"attrs": {"might": 0, "finesse": 0, "wits": 0}, "attack_mod": 2, "damage": "1d4"},
			{"id": "imp2", "name": "墨魈幼体", "hp": 8, "max_hp": 8, "ac": 10,
				"attrs": {"might": 0, "finesse": 0, "wits": 0}, "attack_mod": 2, "damage": "1d4"},
		],
		"party_advantage_rounds": 1, # 「见证撤销」旗标 → 首回合全队攻击优势（11 §3.1 示例）
		"loot": [{"item": "ink_core", "n": 1}], # 战役书 §6 墨雨夜袭：经验 + 战利品
		"xp": 100,
	}

func _start_battle() -> void:
	if sm.state == EncounterSM.S_EXPLORE:
		sm.begin_combat(_battle_def())

# ---------------------------------------------------------------- 结算屏（04 §⑨ 简化版）

func _build_settle_panel() -> void:
	settle_panel = PanelContainer.new()
	settle_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	settle_panel.visible = false
	add_child(settle_panel)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	settle_panel.add_child(v)
	settle_text = RichTextLabel.new()
	settle_text.bbcode_enabled = false
	settle_text.custom_minimum_size = Vector2(340, 400)
	settle_text.fit_content = true
	v.add_child(settle_text)
	var quit_button := Button.new()
	quit_button.text = TextsZh.SETTLE_QUIT
	quit_button.pressed.connect(func() -> void: get_tree().quit())
	v.add_child(quit_button)

func _on_event(ev: Dictionary) -> void:
	if ev["type"] == EventTypes.COMBAT_END:
		_show_settle(str(ev["payload"]["result"]))

func _show_settle(result: String) -> void:
	await get_tree().create_timer(1.0).timeout
	var result_name: String = {"victory": TextsZh.SETTLE_VICTORY, "defeat": TextsZh.SETTLE_DEFEAT,
		"retreat": TextsZh.SETTLE_RETREAT}.get(result, result)
	var lines: Array[String] = ["【%s】午夜墨雨 —— %s" % [TextsZh.SETTLE_TITLE, result_name], ""]
	for ev: Dictionary in stream.query_by_type(EventTypes.XP_GAIN):
		lines.append("经验 +%d" % int(ev["payload"]["amount"]))
	for ev: Dictionary in stream.query_by_type(EventTypes.ITEM_GAIN):
		lines.append("获得：%s ×%d（新道具已入背包）" % [ev["payload"]["item_id"], int(ev["payload"]["count"])])
	for ev: Dictionary in stream.query_by_type(EventTypes.FLAG_WRITE):
		lines.append("旗标：%s" % str(ev["payload"]["key"]))
	lines.append("")
	lines.append("（简化结算屏：完整九类界面闭环属 TP4）")
	settle_text.text = "\n".join(lines)
	shell.visible = false
	settle_panel.visible = true

# ---------------------------------------------------------------- 中文字体（macOS 系统字体回退，仅为可读性）

func _setup_cjk_font() -> void:
	for path: String in ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc",
			"/System/Library/Fonts/STHeiti Light.ttc", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"]:
		if FileAccess.file_exists(path):
			var ff := FontFile.new()
			if ff.load_dynamic_font(path) == OK:
				ThemeDB.fallback_font = ff
				print("[main] CJK 字体：", path)
				return
	push_warning("[main] 未找到系统中文字体，界面文字可能无法渲染")

# ---------------------------------------------------------------- 截图模式（证据留存 /tmp，不提交）

## TP2：竖屏自动推进截图（保持原证据链可复现）。
func _run_shots_tp2() -> void:
	await get_tree().create_timer(1.2).timeout
	await _shot("/tmp/tp2_1_explore.png")
	_start_battle()
	await get_tree().create_timer(1.0).timeout
	await _shot("/tmp/tp2_2_combat.png")
	# 关键判定演出（与事件驱动同一管线，负载为演示用死亡豁免）
	portrait.debug_show_key_roll({"event_id": 9001, "kind": "death_save", "keep": 7,
		"success": false, "extreme": false, "s": 1, "f": 2, "key": true})
	await get_tree().create_timer(0.55).timeout
	await _shot("/tmp/tp2_3_keyroll.png")
	# 托管打完全场（09 §9.3：2× 节拍 0.4s/动作）
	portrait.set_speed(2)
	portrait.set_auto(true)
	var guard := 0
	while not sm.is_over() and guard < 300:
		guard += 1
		await get_tree().create_timer(0.2).timeout
	await get_tree().create_timer(1.6).timeout
	await _shot("/tmp/tp2_4_settle.png")
	print("[shots] 战斗结果：", sm.result(), " 回合数：", sm.round_no())
	get_tree().quit()

## TP3：横屏壳战斗态截图（tech/01 §10 TP3 证据）。
func _run_shot_tp3() -> void:
	await get_tree().create_timer(1.2).timeout
	_start_battle()
	# 托管推进数拍：先攻条/战术格/骰子盘/日志带均有内容（2× 节拍 0.4s，09 §9.3）
	landscape.set_speed(2)
	landscape.set_auto(true)
	await get_tree().create_timer(4.0).timeout
	landscape.set_auto(false)
	await get_tree().create_timer(0.6).timeout # 等骰子盘快掷落定
	await _shot("/tmp/tp3_landscape.png")
	print("[shots] 横屏战斗态：回合 ", sm.round_no(), " 结束=", sm.is_over())
	get_tree().quit()

func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("[shots] ", path, " err=", err)
