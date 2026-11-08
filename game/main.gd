# 可玩引导（TASKS P1.5 TP2）：启动加载 packs/campaign01 → 直接进入脚本化竖屏战斗
# N1-7 午夜墨雨（战役书 §4 SL-1 / §7：教学 Boss 墨魈；encounters.json 登记 N1-7 battle/easy/max5）。
# 战斗数值取自 prototype/data.js 的轻规则切片并对齐 11 §8 武器骰表；
# 正式落位应为 packs 的 characters/skills/enemies.json（tech/04），TP2 以引导脚本承载（见交付留白）。
# 调试：`-- --tp2-shots` 自动推进战斗并截图到 /tmp/tp2_*.png（不提交）。
extends Node

const BATTLE_SEED := 20261108

var stream: EventStream
var board: Board
var sm: EncounterSM
var agent: AutoAgent
var portrait: EncounterPortrait
var settle_panel: PanelContainer
var settle_text: RichTextLabel
var _shots_mode := false

func _ready() -> void:
	_setup_cjk_font()
	_shots_mode = OS.get_cmdline_user_args().has("--tp2-shots")
	# 加载战役包（tech/02 §1/§2；TP1 加载管线复用）
	var res := PackLoader.load_pack("res://packs/campaign01")
	if not res["ok"]:
		push_error("campaign01 加载失败：%s" % ";".join(res["errors"]))
		return
	print("[main] campaign01 加载成功：", (res["pack"]["nodes"] as Dictionary).size(), " 节点")
	stream = EventStream.new()
	board = Board.new(stream)
	sm = EncounterSM.new(board, stream, Rng.new(BATTLE_SEED), "campaign01")
	agent = AutoAgent.new()
	portrait = load("res://shell/portrait/encounter_portrait.tscn").instantiate()
	add_child(portrait)
	portrait.bind(sm, agent)
	portrait.set_rooms(["N1-1", "N1-3", "N1-7", "N1-8"], 2,
		{"N1-1": "自由市广场", "N1-3": "见证撤销", "N1-7": "午夜墨雨", "N1-8": "三份邀约"})
	_build_settle_panel()
	stream.subscribe(_on_event)
	# 序章带入（叙事既定）：N1-1 商店补给药水 ×2、N1-3 见证撤销旗标（→ 首回合全队优势，11 §3.1 示例）
	var prov := {"event_id": 0, "node_id": "N1-1", "pack_id": "campaign01"}
	board.give_item("heal_potion", 2, prov)
	board.write("campaign01.witnessed_revocation", true,
		{"event_id": 0, "node_id": "N1-3", "pack_id": "campaign01"})
	# 进场 → 探索（开场事件流投递完毕，09 §1）
	sm.enter("N1-7")
	sm.transition(EncounterSM.S_EXPLORE)
	stream.emit(EventTypes.LOG, {"msg": "午夜，墨色的雨。雨点落地成字，字扭曲着立起——墨魈朝着广场上唯一的「空白」涌来。"},
		&"core", "N1-7")
	if _shots_mode:
		_run_shots()
	else:
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
	portrait.visible = false
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

# ---------------------------------------------------------------- 截图模式（--tp2-shots，证据留存 /tmp，不提交）

func _run_shots() -> void:
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

func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("[shots] ", path, " err=", err)
