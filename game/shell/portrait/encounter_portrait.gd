# 竖屏遭遇壳（docs/framework/04-UI-UX设计文档.md §④；09 §5/§6/§7/§9；tech/01 §6.2）
# 铁律落位：
# - 壳只订阅事件流与读 Board/SM 公开只读 getter（godot-dev §2）；一切指令以 Command 对象
#   经 EncounterSM.submit_command 发给 core，壳不直接改任何战斗状态；
# - 三段呼吸（04 §④.1 冻结比例，09 §5）：高度变化只随 state.entered 与关键判定演出发生；
# - 掷骰两级演出（09 §6）：普通=骰子 Tab 托盘快掷（≤0.5s），关键=全屏覆盖层（可点击跳过）；
# - 托管（09 §9.3）：代理命令经 shell Timer 节拍下限 ≥0.8s/动作（1×/2×）发出，玩家点按即接管。
class_name EncounterPortrait
extends Control

# 呼吸比例表（04 §④.1 冻结，09 §5）：[状态栏带, 主视野, 操作台]
# 注：04 §④.1 战斗行原文 12/55/37 合计 104≠100（文档矛盾）——实现按"状态栏 12、主视野 55、
# 操作台补齐 33"落位（三段必须归一），待文档裁决修正（见 TP2 交付说明·待裁决清单）。
const BREATHING := {
	&"explore": [0.08, 0.62, 0.30],
	&"combat": [0.12, 0.55, 0.33],
	&"dialog": [0.08, 0.50, 0.42],
	&"key_roll": [0.0, 1.0, 0.0],
	&"settle": [0.08, 0.62, 0.30], # 结算过渡落回探索布局（04 §④.1）
}
# 遭遇六态 → 呼吸档（对话并入探索分支，tech/01 §6.1；对话档由演出层按需调用）
const STATE_PROFILE := {
	&"enter": &"explore",
	&"explore": &"explore",
	&"discover": &"explore",
	&"combat": &"combat",
	&"settle": &"settle",
	&"rest": &"settle",
	&"exit": &"settle",
}
const AUTO_INTERVAL := 0.8 # 09 §9.3：代理节拍下限（1×），2×=0.4s
const PIP_PAST := &"past"
const PIP_CURRENT := &"current"
const PIP_FUTURE := &"future"

var sm: EncounterSM = null
var agent: AutoAgent = null
var auto_on := false
var speed := 1

# ---- 节点（_ready 构建）----
var status_band: PanelContainer
var party_chips: HBoxContainer
var round_label: Label
var auto_button: Button
var speed_button: Button
var main_view: PanelContainer
var progress_row: HBoxContainer
var menu_button: Button
var enemy_row: HBoxContainer
var party_row: HBoxContainer
var flash_label: Label
var console_panel: PanelContainer
var tabs: TabContainer
var quickbar: HBoxContainer
var dice_label: Label
var dice_detail: Label
var log_view: RichTextLabel
var char_view: RichTextLabel
var key_overlay: ColorRect
var key_dice_label: Label
var key_result_label: Label
var auto_timer: Timer
var menu_popup: PopupPanel

var _profile: StringName = &"explore"
var _selected_target := ""
var _pips: Array[Dictionary] = [] # {node, state}
var _pip_tween: Tween = null
var _key_queue: Array[Dictionary] = []
var _key_playing := false
var _key_skip := false
var _tray_rolling := false

func _ready() -> void:
	_build_ui()
	auto_timer = Timer.new()
	auto_timer.wait_time = AUTO_INTERVAL
	auto_timer.timeout.connect(_on_auto_timeout)
	add_child(auto_timer)
	apply_breathing(&"explore")

# ---------------------------------------------------------------- UI 构建

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# ① 状态栏带（04 §3.1：只放"看"的信息 + 低频操作）
	status_band = PanelContainer.new()
	status_band.name = "StatusBand"
	add_child(status_band)
	var band_h := HBoxContainer.new()
	band_h.add_theme_constant_override("separation", 8)
	status_band.add_child(band_h)
	party_chips = HBoxContainer.new()
	party_chips.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	band_h.add_child(party_chips)
	round_label = Label.new()
	band_h.add_child(round_label)
	speed_button = Button.new()
	speed_button.text = "1×"
	speed_button.pressed.connect(func() -> void: set_speed(2 if speed == 1 else 1))
	band_h.add_child(speed_button)
	auto_button = Button.new()
	auto_button.text = TextsZh.AUTO_ON
	auto_button.pressed.connect(func() -> void: set_auto(not auto_on))
	band_h.add_child(auto_button)
	# ② 主视野（含房间推进条，04 §④.2：推进条在主视野顶部）
	main_view = PanelContainer.new()
	main_view.name = "MainView"
	add_child(main_view)
	var main_v := VBoxContainer.new()
	main_v.add_theme_constant_override("separation", 4)
	main_view.add_child(main_v)
	progress_row = HBoxContainer.new()
	progress_row.custom_minimum_size = Vector2(0, 26)
	progress_row.alignment = BoxContainer.ALIGNMENT_CENTER
	progress_row.add_theme_constant_override("separation", 10)
	main_v.add_child(progress_row)
	menu_button = Button.new()
	menu_button.text = TextsZh.MENU
	menu_button.pressed.connect(_open_menu)
	progress_row.add_child(menu_button) # ☰ 常驻：推进条右端（09 §7）
	enemy_row = HBoxContainer.new()
	enemy_row.alignment = BoxContainer.ALIGNMENT_CENTER
	enemy_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_v.add_child(enemy_row)
	flash_label = Label.new()
	flash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	flash_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	main_v.add_child(flash_label)
	party_row = HBoxContainer.new()
	party_row.alignment = BoxContainer.ALIGNMENT_CENTER
	party_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_v.add_child(party_row)
	# ③ 操作台四 Tab（04 §④.5）
	console_panel = PanelContainer.new()
	console_panel.name = "Console"
	add_child(console_panel)
	tabs = TabContainer.new()
	console_panel.add_child(tabs)
	var tab_action := VBoxContainer.new()
	tab_action.name = TextsZh.TAB_ACTION
	tabs.add_child(tab_action)
	quickbar = HBoxContainer.new()
	quickbar.add_theme_constant_override("separation", 6)
	tab_action.add_child(quickbar)
	var tab_dice := VBoxContainer.new()
	tab_dice.name = TextsZh.TAB_DICE
	tabs.add_child(tab_dice)
	dice_label = Label.new()
	dice_label.add_theme_font_size_override("font_size", 56)
	dice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tab_dice.add_child(dice_label)
	dice_detail = Label.new()
	dice_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tab_dice.add_child(dice_detail)
	log_view = RichTextLabel.new()
	log_view.name = TextsZh.TAB_LOG
	log_view.bbcode_enabled = false
	log_view.scroll_following = true
	tabs.add_child(log_view)
	char_view = RichTextLabel.new()
	char_view.name = TextsZh.TAB_CHAR
	char_view.bbcode_enabled = false
	tabs.add_child(char_view)
	# 全屏关键判定演出层（09 §6）
	key_overlay = ColorRect.new()
	key_overlay.name = "KeyOverlay"
	key_overlay.color = Color(0.02, 0.02, 0.08, 0.96)
	key_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	key_overlay.visible = false
	key_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	key_overlay.gui_input.connect(_on_key_overlay_input)
	add_child(key_overlay)
	var key_v := VBoxContainer.new()
	key_v.set_anchors_preset(Control.PRESET_FULL_RECT)
	key_v.alignment = BoxContainer.ALIGNMENT_CENTER
	key_overlay.add_child(key_v)
	key_dice_label = Label.new()
	key_dice_label.add_theme_font_size_override("font_size", 120)
	key_dice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	key_v.add_child(key_dice_label)
	key_result_label = Label.new()
	key_result_label.add_theme_font_size_override("font_size", 28)
	key_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	key_v.add_child(key_result_label)
	var hint := Label.new()
	hint.text = TextsZh.KEY_ROLL_HINT
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	key_v.add_child(hint)
	_build_menu()

func _build_menu() -> void:
	menu_popup = PopupPanel.new()
	var v := VBoxContainer.new()
	menu_popup.add_child(v)
	var b_continue := Button.new()
	b_continue.text = TextsZh.MENU_CONTINUE
	b_continue.pressed.connect(func() -> void: menu_popup.hide())
	v.add_child(b_continue)
	var confirm_quit := [false]
	var b_save := Button.new()
	b_save.text = TextsZh.MENU_SAVE_QUIT
	b_save.pressed.connect(func() -> void:
		if not confirm_quit[0]:
			confirm_quit[0] = true # 弹确认，文案明说进度影响（09 §7）
			b_save.text = TextsZh.MENU_CONFIRM_QUIT
		else:
			get_tree().quit())
	v.add_child(b_save)
	var b_help := Button.new()
	b_help.text = TextsZh.MENU_HELP
	b_help.pressed.connect(func() -> void:
		_log_line("手势帮助：点按芯片=默认目标使用；横滑切 Tab；长按单位看信息（12 §4）"))
	v.add_child(b_help)
	add_child(menu_popup)

func _open_menu() -> void:
	menu_popup.popup_centered(Vector2i(300, 160))

# ---------------------------------------------------------------- 绑定与事件订阅（壳唯一输入：事件流 + 只读 getter）

func bind(p_sm: EncounterSM, p_agent: AutoAgent) -> void:
	sm = p_sm
	agent = p_agent
	sm.stream.subscribe(_on_event)
	_restore_breathing()
	_refresh_all()

func _on_event(ev: Dictionary) -> void:
	var line := BattleText.event_log_text(ev, _unit_name) # 日志文案两壳共享（battle_text.gd）
	if line != "":
		_log_line(line)
	match StringName(ev["type"]):
		EventTypes.STATE_ENTERED:
			var st := StringName(ev["payload"]["state"])
			apply_breathing(STATE_PROFILE.get(st, &"explore"))
		EventTypes.COMBAT_START:
			_flash("遭遇战开始！")
		EventTypes.TURN_START:
			if str(ev["payload"].get("side", "")) == "party":
				round_label.text = "第 %d 轮" % int(ev["payload"]["round"])
		EventTypes.BATTLE_ATTACK:
			var p: Dictionary = ev["payload"]
			_flash(BattleText.attack_text(p))
			_tray_roll(p)
		EventTypes.CHECK_ROLL:
			var p: Dictionary = ev["payload"]
			if bool(p.get("key", false)):
				var q := p.duplicate(true)
				q["event_id"] = ev["id"]
				_play_key_roll(q) # 关键判定：全屏演出（09 §6）
			else:
				_tray_roll(p)
		EventTypes.BATTLE_DOWN:
			_flash("%s 倒地！" % str(ev["payload"]["name"]))
		EventTypes.COMBAT_END:
			set_auto(false) # 遭遇结束托管自动停止（09 §9.3）
	_refresh_all()

# ---------------------------------------------------------------- 呼吸（04 §④.1：高度变化只随状态切换发生）

func apply_breathing(profile: StringName) -> void:
	if not BREATHING.has(profile):
		return
	_profile = profile
	var r: Array = BREATHING[profile]
	var s: float = r[0]
	var m: float = r[1]
	status_band.visible = s > 0.001
	console_panel.visible = float(r[2]) > 0.001
	_set_band(status_band, 0.0, s)
	_set_band(main_view, s, s + m)
	_set_band(console_panel, s + m, 1.0)

func _set_band(c: Control, top: float, bottom: float) -> void:
	c.anchor_left = 0.0
	c.anchor_right = 1.0
	c.anchor_top = top
	c.anchor_bottom = bottom
	c.offset_left = 0
	c.offset_right = 0
	c.offset_top = 0
	c.offset_bottom = 0

func _restore_breathing() -> void:
	if sm != null and STATE_PROFILE.has(sm.state):
		apply_breathing(STATE_PROFILE[sm.state])
	else:
		apply_breathing(&"explore")

## 测试探针：三段实际像素占比 [状态栏, 主视野, 操作台]。
func get_band_ratios() -> Array[float]:
	var total := maxf(size.y, 1.0)
	return [status_band.size.y / total, main_view.size.y / total, console_panel.size.y / total]

# ---------------------------------------------------------------- 房间推进条（04 §④.2）

func set_rooms(room_ids: Array, current_index: int, titles: Dictionary = {}) -> void:
	for child: Node in progress_row.get_children():
		if child != menu_button:
			child.queue_free()
	_pips.clear()
	if _pip_tween != null:
		_pip_tween.kill()
		_pip_tween = null
	progress_row.move_child(menu_button, -1) # ☰ 保持右端
	for i: int in room_ids.size():
		var pip := Label.new()
		var st := PIP_CURRENT if i == current_index else (PIP_PAST if i < current_index else PIP_FUTURE)
		match st:
			PIP_PAST:
				pip.text = "●" # 已过：点亮
				pip.modulate = Color(0.9, 0.8, 0.4)
				pip.tooltip_text = str(titles.get(room_ids[i], room_ids[i]))
			PIP_CURRENT:
				pip.text = "◉" # 当前：脉动
				pip.modulate = Color(1.0, 1.0, 1.0)
				pip.tooltip_text = str(titles.get(room_ids[i], room_ids[i]))
				_pip_tween = create_tween().set_loops()
				_pip_tween.tween_property(pip, "modulate:a", 0.35, 0.5)
				_pip_tween.tween_property(pip, "modulate:a", 1.0, 0.5)
			PIP_FUTURE:
				pip.text = "▯" # 未来：门剪影（04 §④.2）
				pip.modulate = Color(0.35, 0.35, 0.4)
		progress_row.add_child(pip)
		progress_row.move_child(pip, i)
		_pips.append({"node": pip, "state": st, "id": str(room_ids[i])})

func pip_state(index: int) -> StringName:
	if index < 0 or index >= _pips.size():
		return &""
	return _pips[index]["state"]

# ---------------------------------------------------------------- 快捷栏芯片（09 §9.2：点按=默认目标；拖动留 TP4）

func _refresh_quickbar() -> void:
	for child: Node in quickbar.get_children():
		child.queue_free()
	if sm == null:
		return
	# 快捷栏内容 = EncounterSM 可用指令集（09 §9.2），与横屏行动轮盘同源，禁止壳内复制过滤逻辑
	var actions := sm.get_available_actions()
	if actions.is_empty():
		return
	var actor_label := Label.new()
	actor_label.text = "【%s】" % str(sm.get_unit(sm.current_actor_id())["name"])
	quickbar.add_child(actor_label)
	for a: Dictionary in actions:
		_add_chip(TextsZh.action_label(a), bool(a["disabled"]), func() -> void: press_action(a))

func _add_chip(label: String, disabled: bool, on_press: Callable) -> void:
	var b := Button.new()
	b.text = label
	b.disabled = disabled
	b.pressed.connect(on_press)
	quickbar.add_child(b)

## 手操命令：先接管托管（09 §9.3 一键接管即时生效），再走统一 Command 通道。
func _manual(cmd: Dictionary) -> void:
	if cmd.is_empty():
		return
	if auto_on:
		set_auto(false)
	if sm != null:
		sm.submit_command(cmd)

## 芯片点按（09 §9.2 点按=默认目标；enemy 目标优先用主视野点选，12 §1）。
func press_action(action: Dictionary) -> void:
	if sm == null:
		return
	var target := ""
	if str(action.get("target_kind", "")) == "enemy":
		target = _default_enemy_target()
	_manual(sm.command_from_action(action, target))

## 测试/比对探针：按下指令集第 i 项（默认目标，不经 UI 状态）。
func press_action_index(i: int) -> void:
	if sm == null:
		return
	var actions := sm.get_available_actions()
	if i >= 0 and i < actions.size():
		_manual(sm.command_from_action(actions[i]))

## 测试/比对探针：托管步进一次（与 _on_auto_timeout 同一通道，09 §9.3）。
func debug_step_auto() -> void:
	if sm == null or sm.is_over():
		return
	var cmd := agent.next_command(sm)
	if not cmd.is_empty():
		sm.submit_command(cmd)

# ---------------------------------------------------------------- 托管（09 §9.3：节拍下限 shell 侧 Timer ≥0.8s，1×/2×）

func set_auto(on: bool) -> void:
	auto_on = on
	auto_button.text = TextsZh.AUTO_OFF if on else TextsZh.AUTO_ON
	if on:
		auto_timer.start()
	else:
		auto_timer.stop()

func set_speed(mult: int) -> void:
	speed = clampi(mult, 1, 2)
	auto_timer.wait_time = AUTO_INTERVAL / float(speed)
	speed_button.text = "%d×" % speed

func _on_auto_timeout() -> void:
	if not auto_on or sm == null or sm.is_over():
		return
	var cmd := agent.next_command(sm) # core 侧只产出命令（09 §9.3）
	if not cmd.is_empty():
		sm.submit_command(cmd)

# ---------------------------------------------------------------- 掷骰演出（09 §6 两级）

## 普通：骰子 Tab 托盘快掷（≤0.5s 出结果）。
func _tray_roll(p: Dictionary) -> void:
	if _tray_rolling:
		return
	_tray_rolling = true
	var visual := Rng.new(int(p.get("keep", 1)) * 7919 + 3) # 演出层视觉随机，与逻辑骰无关
	var keep := str(p.get("keep", "?"))
	for i: int in 5:
		dice_label.text = str(visual.d20())
		await get_tree().create_timer(0.07).timeout # 5×0.07=0.35s ≤0.5s
	dice_label.text = keep
	var rolls: Array = p.get("rolls", [])
	dice_detail.text = "骰 %s 修正 %+d 合计 %d（%s）" % [str(rolls), int(p.get("mod", p.get("atk_mod", 0))),
		int(p.get("total", p.get("keep", 0))),
		TextsZh.RESULT_SUCCESS if bool(p.get("success", p.get("hit", false))) else TextsZh.RESULT_FAIL]
	_tray_rolling = false

## 关键：全屏覆盖层演出（可点击跳过；死亡豁免恒定关键，11 §7）。
func _play_key_roll(p: Dictionary) -> void:
	_key_queue.append(p)
	if _key_playing:
		return
	_key_playing = true
	while not _key_queue.is_empty():
		var q: Dictionary = _key_queue.pop_front()
		apply_breathing(&"key_roll") # 全屏接管（04 §④.1 关键判定行）
		key_overlay.visible = true
		key_result_label.text = ""
		_key_skip = false
		var visual := Rng.new(int(q.get("event_id", 1)) * 131 + 7)
		for i: int in 10:
			if _key_skip:
				break
			key_dice_label.text = str(visual.d20())
			await get_tree().create_timer(0.09).timeout
		key_dice_label.text = str(q.get("keep", "?"))
		var ok := bool(q.get("success", false))
		var extreme := bool(q.get("extreme", false))
		if extreme:
			key_result_label.text = TextsZh.RESULT_CRIT if ok else TextsZh.RESULT_FUMBLE # nat20/1 追加一档（09 §6）
		else:
			key_result_label.text = TextsZh.RESULT_SUCCESS if ok else TextsZh.RESULT_FAIL
		if str(q.get("kind", "")) == "death_save":
			key_result_label.text += "\n死亡豁免 %d 胜 %d 负" % [int(q.get("s", 0)), int(q.get("f", 0))]
		if not _key_skip:
			await get_tree().create_timer(0.7).timeout
		key_overlay.visible = false
		_restore_breathing()
	_key_playing = false

func _on_key_overlay_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_key_skip = true

## 调试/截图入口：与事件驱动同一演出管线。
func debug_show_key_roll(payload: Dictionary) -> void:
	_play_key_roll(payload)

# ---------------------------------------------------------------- 刷新（事件流 → UI 更新链路）

func _refresh_all() -> void:
	if sm == null:
		return
	_refresh_units()
	_refresh_quickbar()
	_refresh_chars()

func _refresh_units() -> void:
	for child: Node in enemy_row.get_children():
		child.queue_free()
	for child: Node in party_row.get_children():
		child.queue_free()
	for child: Node in party_chips.get_children():
		child.queue_free()
	if sm == null:
		return
	var units := sm.get_units()
	for id: String in sm.get_order():
		var u: Dictionary = units[id]
		if u["side"] == &"enemy":
			enemy_row.add_child(_unit_button(u))
		else:
			party_row.add_child(_unit_button(u))
			var chip := Label.new()
			chip.text = " %s %d/%d " % [u["name"], int(u["hp"]), int(u["max_hp"])]
			if bool(u["dead"]):
				chip.modulate = Color(0.4, 0.4, 0.4)
			elif bool(u["downed"]):
				chip.modulate = Color(1.0, 0.5, 0.4)
			party_chips.add_child(chip)

func _unit_button(u: Dictionary) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(104, 64)
	b.text = "%s\nHP %d/%d" % [u["name"], int(u["hp"]), int(u["max_hp"])]
	if bool(u["dead"]):
		b.disabled = true
		b.modulate = Color(0.35, 0.35, 0.35)
	elif bool(u["downed"]):
		b.modulate = Color(1.0, 0.55, 0.45)
	elif u["side"] == &"enemy":
		var id := str(u["id"])
		b.pressed.connect(func() -> void:
			_selected_target = id # 点选默认目标（12 §1 点按）
			_flash("目标：%s" % str(u["name"])))
		if _selected_target == id:
			b.modulate = Color(1.0, 0.9, 0.5)
	return b

func _refresh_chars() -> void:
	if sm == null:
		return
	var lines: Array[String] = []
	for id: String in sm.get_order():
		var u: Dictionary = sm.get_unit(id)
		var status := ""
		if bool(u["dead"]):
			status = "（死亡）"
		elif bool(u["downed"]):
			status = "（倒地 豁%d/%d）" % [int(u["death_saves"]["s"]), int(u["death_saves"]["f"])]
		lines.append("%s  HP %d/%d  AC %d  力%+.0f 敏%+.0f 智%+.0f%s" % [u["name"],
			int(u["hp"]), int(u["max_hp"]), int(u["ac"]),
			float((u["attrs"] as Dictionary).get("might", 0)),
			float((u["attrs"] as Dictionary).get("finesse", 0)),
			float((u["attrs"] as Dictionary).get("wits", 0)), status])
	char_view.text = "\n".join(lines)

# ---------------------------------------------------------------- 小部件

func _log_line(text: String) -> void:
	if log_view != null and text != "":
		log_view.append_text(text + "\n")

func _flash(text: String) -> void:
	flash_label.text = text
	flash_label.modulate = Color(1, 1, 1, 1)
	var tw := create_tween()
	tw.tween_property(flash_label, "modulate:a", 0.25, 1.2)

func _unit_name(id: String) -> String:
	if sm == null:
		return id
	return str(sm.get_unit(id).get("name", id))

func _default_enemy_target() -> String:
	if sm == null:
		return ""
	if _selected_target != "":
		var t := sm.get_unit(_selected_target)
		if not t.is_empty() and not bool(t["dead"]):
			return _selected_target
	return sm.first_alive_enemy()
