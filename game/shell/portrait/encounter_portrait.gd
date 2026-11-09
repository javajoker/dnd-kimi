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
## ☰「保存并回主屏」回调（09 §7：回到遭遇进入前快照，由 main 流程控制器接管；未接管时退出进程）。
var on_save_quit: Callable = Callable()
# ---- 节点流程故事态（04 §④.2/§④.3：节点即房间；内容源 StoryVM，壳只渲染）----
var story_cb := {} # {"edge": Callable(idx), "hub": Callable(action, arg)}
var _stream: EventStream = null
var _board: Board = null
var _pack: Dictionary = {}
var _story := false
var _vm: Dictionary = {}
var story_panel: VBoxContainer
var story_title: Label
var story_text: RichTextLabel
var clock_chip: Button
var quest_chip: Label
var hub_popup: HubPopup
var info_popup: InfoPopup

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
var dice3d: Dice3D                   # 关键判定 3D 物理演出层（14 清单 #2；结果由事件流给定）
var auto_timer: Timer
var menu_popup: PopupPanel
## 长按计时时钟（可注入，测试步进；生产缺省真实时钟）。长按判定不走 Timer，见 _poll_key_hold（12 §1）。
var hold_clock: Callable = func() -> int: return Time.get_ticks_msec()
var gestures: GestureLayer         # 手势层（12 §1~§3；透明覆盖，不吞事件，按钮等价路径不受影响）
var tutorial: TutorialOverlay      # 情境教程层（12 §4 第二层：半透明遮罩+高亮，非模态）
var path_line: Line2D              # 轨迹施法预览（12 §2.1：轨迹即弹道预览）
var review_popup: PanelContainer   # 房间回看弹层（04 §④.2：只读回看）
var review_list: VBoxContainer
var review_detail: Label

var _profile: StringName = &"explore"
var _selected_target := ""
var _pips: Array[Dictionary] = [] # {node, state}
var _pip_tween: Tween = null
var _key_queue: Array[Dictionary] = []
var _key_playing := false
var _key_skip := false
var _key_hold_start := -1          # 按住起点（hold_clock 毫秒；-1 = 未按住）
var _tray_rolling := false
var _rooms_snapshot := {}          # 推进条数据快照（回看用：{ids, titles, current}）
var _drag_uid := ""                # 拖动中的己方单位（12 §3.1 起点定语义）
var _drag_action := {}             # 快捷栏芯片拖动中的指令集条目（12 §3.6）
var _zoom := 1.0                   # 捏合缩放（竖屏：松手弹回 04 §④.4）

func _ready() -> void:
	_build_ui()
	auto_timer = Timer.new()
	auto_timer.wait_time = AUTO_INTERVAL
	auto_timer.timeout.connect(_on_auto_timeout)
	add_child(auto_timer)
	_setup_gestures()
	apply_breathing(&"explore")

# ---------------------------------------------------------------- UI 构建

func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# ① 状态栏带（04 §3.1：只放"看"的信息 + 低频操作）
	status_band = PanelContainer.new()
	status_band.name = "StatusBand"
	add_child(status_band)
	var band_h := HBoxContainer.new()
	band_h.add_theme_constant_override("separation", 8)
	status_band.add_child(band_h)
	clock_chip = Button.new() # 时间钟总览格：按下弹时间边预告（04 §3.1 例外交互）
	clock_chip.visible = false
	clock_chip.pressed.connect(_open_forecast)
	band_h.add_child(clock_chip)
	quest_chip = Label.new() # 事件中心角标（04 §⑤）
	quest_chip.visible = false
	band_h.add_child(quest_chip)
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
	# 故事态叙事面板（04 §④.3 房间呈现：scene 文本 / dialog NPC 文本；战斗时收起）
	story_panel = VBoxContainer.new()
	story_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	story_panel.visible = false
	main_v.add_child(story_panel)
	story_title = Label.new()
	story_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	story_title.add_theme_font_size_override("font_size", 20)
	story_panel.add_child(story_title)
	story_text = RichTextLabel.new()
	story_text.bbcode_enabled = false
	story_text.scroll_following = false
	story_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	story_panel.add_child(story_text)
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
	key_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	key_overlay.visible = false
	key_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	key_overlay.gui_input.connect(_on_key_overlay_input)
	add_child(key_overlay)
	# 3D D20 物理演出层（14 清单 #2）：垫在结果文案之下，长按仍由 key_overlay 仲裁（04 §④.7）
	dice3d = (load("res://shell/ui/dice_3d.tscn") as PackedScene).instantiate() as Dice3D
	key_overlay.add_child(dice3d)
	var key_v := VBoxContainer.new()
	key_v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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
	# 半屏弹层组件（04 §3.3，双壳共用）：hub 商店 / 时间边预告
	hub_popup = HubPopup.new()
	hub_popup.buy_requested.connect(func(item_id: String) -> void:
		if story_cb.has("hub"):
			story_cb["hub"].call("buy", item_id))
	hub_popup.rest_requested.connect(func() -> void:
		if story_cb.has("hub"):
			story_cb["hub"].call("rest", ""))
	add_child(hub_popup)
	info_popup = InfoPopup.new()
	add_child(info_popup)
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
		elif on_save_quit.is_valid():
			menu_popup.hide()
			on_save_quit.call() # 回遭遇进入前快照（09 §7），由 main 恢复并回主屏
		else:
			get_tree().quit())
	v.add_child(b_save)
	var b_help := Button.new()
	b_help.text = TextsZh.MENU_HELP
	b_help.pressed.connect(func() -> void:
		_log_line("手势帮助：%s" % "\n".join(TextsZh.HELP_LINES)))
	v.add_child(b_help)
	add_child(menu_popup)

func _open_menu() -> void:
	menu_popup.popup_centered(Vector2i(300, 160))

# ---------------------------------------------------------------- 手势接入（12 §2.2 竖屏映射；§3 冲突消解）
# 手势是效率层：全部手势指令与芯片/按钮同构（GestureCommands 单源），一切手势保留按钮等价路径。

func _setup_gestures() -> void:
	path_line = Line2D.new() # 轨迹预览（12 §2.1：轨迹即弹道预览）
	path_line.width = 2.0
	path_line.default_color = Color(1.0, 0.85, 0.4, 0.8)
	path_line.visible = false
	add_child(path_line)
	_build_review_popup()
	tutorial = TutorialOverlay.new() # 情境教程层（12 §4；触发记录写板由 main 负责）
	add_child(tutorial)
	gestures = GestureLayer.new()
	gestures.rec.target_probe = func(pos: Vector2) -> String: return _unit_id_at(pos)
	add_child(gestures)
	gestures.tapped.connect(_on_gesture_tap)
	gestures.long_pressed.connect(_on_gesture_long_press)
	gestures.drag_started.connect(_on_gesture_drag_started)
	gestures.drag_updated.connect(_on_gesture_drag_updated)
	gestures.dragged.connect(_on_gesture_dragged)
	gestures.path_cast.connect(_on_gesture_path)
	gestures.two_finger_tapped.connect(_on_gesture_two_finger_tap)
	gestures.pinched.connect(_on_gesture_pinch)
	gestures.pinch_ended.connect(_on_gesture_pinch_ended)
	gestures.h_swiped.connect(_on_gesture_h_swipe)
	gestures.v_swiped.connect(_on_gesture_v_swipe)

func _in(c: Control, pos: Vector2) -> bool:
	return c != null and c.visible and c.get_global_rect().has_point(pos)

## 命中测试：主视野单位卡（12 §3.1 起点定语义）。返回单位 id，空位返回 ""。
func _unit_id_at(pos: Vector2) -> String:
	if sm == null or _story:
		return ""
	for row: HBoxContainer in [enemy_row, party_row]:
		for child: Node in row.get_children():
			if child is Button and (child as Button).has_meta("unit_id") \
					and (child as Button).get_global_rect().has_point(pos):
				return str((child as Button).get_meta("unit_id"))
	return ""

## 快捷栏芯片命中（12 §3.6：起拖点在芯片上 = 使用拖动）。
func _chip_action_at(pos: Vector2) -> Dictionary:
	for child: Node in quickbar.get_children():
		if child is Button and (child as Button).has_meta("action") \
				and (child as Button).get_global_rect().has_point(pos):
			return (child as Button).get_meta("action")
	return {}

## 点按推进条 = 回看（04 §④.2；下滑手势的按钮等价路径，12 §1 铁律）。
func _on_gesture_tap(pos: Vector2) -> void:
	if _story and _in(progress_row, pos):
		_open_room_review()

## 长按单位 = 信息卡半屏弹层（12 §2.2：HP/AC/伤害骰/状态）。
func _on_gesture_long_press(pos: Vector2) -> void:
	var uid := _unit_id_at(pos)
	if uid == "" or sm == null:
		return
	var u := sm.get_unit(uid)
	info_popup.show_info(str(u["name"]), [
		"HP %d/%d　AC %d" % [int(u["hp"]), int(u["max_hp"]), int(u["ac"])],
		"伤害骰 %s　攻击修正 %+d" % [str(u["damage"]), int(u["attack_mod"])],
		"状态：%s" % ("倒地" if bool(u["downed"]) else ("死亡" if bool(u["dead"]) else "正常")),
		"先攻位次：%d" % (sm.get_order().find(uid) + 1),
	])

func _on_gesture_drag_started(info: Dictionary) -> void:
	_drag_uid = ""
	_drag_action = {}
	if sm == null:
		return
	var start: Vector2 = info["start"]
	var chip := _chip_action_at(start)
	if not chip.is_empty() and not bool(chip.get("disabled", false)):
		_drag_action = chip # 芯片拖动 = 指定目标使用（12 §3.6）
		return
	var uid := _unit_id_at(start)
	if uid != "" and uid == sm.current_actor_id():
		_drag_uid = uid # 拖动己方单位（当前行动单位）= 移动/轨迹（12 §3.1）

## 拖动中预览：轨迹虚线（12 §2.1）/ 落点提示；预览不即时生效，抬手确认（12 §3.2）。
func _on_gesture_drag_updated(info: Dictionary) -> void:
	if _drag_uid == "" and _drag_action.is_empty():
		return
	var pos: Vector2 = info["pos"]
	path_line.visible = true
	path_line.points = PackedVector2Array([info["start"], pos])
	var over := _unit_id_at(pos)
	if over != "" and sm != null and str(sm.get_unit(over).get("side", "")) == &"enemy":
		_flash(TextsZh.GESTURE_PATH_AIM % [
			_unit_name(_drag_uid) if _drag_uid != "" else str(_drag_action.get("name", "")),
			_unit_name(over)])

func _on_gesture_dragged(info: Dictionary) -> void:
	path_line.visible = false
	if _drag_uid == "" and _drag_action.is_empty():
		return
	var end: Vector2 = info["end"]
	var over := _unit_id_at(end)
	# 芯片拖动 → 目标单位 = 指定使用；落空 = 取消（12 §3.6）
	if not _drag_action.is_empty():
		var a := _drag_action
		_drag_action = {}
		if over != "":
			_manual(sm.command_from_action(a, over))
		else:
			_flash(TextsZh.GESTURE_CANCEL)
		return
	var uid := _drag_uid
	_drag_uid = ""
	if sm == null:
		return
	if over != "" and str(sm.get_unit(over).get("side", "")) == &"enemy":
		_manual(GestureCommands.cast_at(sm, over)) # 终点落敌 = 施法（12 §3.2）
		return
	# 落在空位：纵向拖动 = 调整站位（12 §2.2 前压/后撤），消耗移动段（11 §4）
	var d: Vector2 = info["delta"]
	if absf(d.y) > GestureRecognizer.DRAG_MIN_PT:
		_manual(GestureCommands.move_to(sm, "stance:forward" if d.y < 0.0 else "stance:back"))
	else:
		_flash(TextsZh.GESTURE_CANCEL)

## 拖动经过 ≥2 语义目标且终点落敌 = 轨迹施法（12 §1 path；与平拖同一出口）。
func _on_gesture_path(info: Dictionary) -> void:
	if _drag_uid != "" or not _drag_action.is_empty():
		_on_gesture_dragged(info)

## 双指点击：战斗 = 结束回合；故事态 = 首个检定边一键快掷（12 §2.2）。
func _on_gesture_two_finger_tap(pos: Vector2) -> void:
	if not _in(main_view, pos):
		return
	if sm != null and not _story:
		_manual(GestureCommands.end_turn(sm))
		return
	if _story and story_cb.has("edge"):
		var idx := 0
		for e: Variant in _vm.get("edges", []):
			if bool((e as Dictionary).get("check", false)):
				story_cb["edge"].call(idx)
				return
			idx += 1

## 捏合 = 全局俯瞰 ↔ 跟随镜头；竖屏松手弹回（04 §④.4）。
func _on_gesture_pinch(ratio: float, center: Vector2) -> void:
	if not _in(main_view, center):
		return
	_zoom = clampf(ratio, 0.7, 1.6)
	main_view.pivot_offset = main_view.size * 0.5
	main_view.scale = Vector2.ONE * _zoom

func _on_gesture_pinch_ended(_ratio: float, center: Vector2) -> void:
	if _zoom == 1.0:
		return
	var tw := create_tween()
	tw.tween_property(main_view, "scale", Vector2.ONE, 0.2) # 松手弹回（04 §④.4）
	_zoom = 1.0

## 横滑操作台 = 四 Tab 循环切换（12 §2.2；13 §3 Tab 循环）。
func _on_gesture_h_swipe(dir: int, pos: Vector2) -> void:
	if _in(console_panel, pos) and tabs.get_tab_count() > 0:
		tabs.current_tab = posmod(tabs.current_tab + dir, tabs.get_tab_count())

## 下滑推进条 = 已过房间回看（04 §④.2）。
func _on_gesture_v_swipe(dir: int, pos: Vector2) -> void:
	if dir > 0 and _story and _in(progress_row, pos):
		_open_room_review()

## 情境教程提示（12 §4 第二层；触发记录写板由 main 负责，壳只呈现）。
func show_tutorial_hint(id: String, text: String) -> void:
	tutorial.show_hint(id, text)

# ---------------------------------------------------------------- 房间回看（04 §④.2：已过点亮可回看；只读，已完成不重置）

func _build_review_popup() -> void:
	review_popup = PanelContainer.new()
	review_popup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	review_popup.visible = false
	add_child(review_popup)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	review_popup.add_child(v)
	var title := Label.new()
	title.text = TextsZh.ROOM_REVIEW_TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	v.add_child(title)
	var hint := Label.new()
	hint.text = TextsZh.ROOM_REVIEW_HINT
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	v.add_child(hint)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	review_list = VBoxContainer.new()
	review_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(review_list)
	review_detail = Label.new()
	review_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	review_detail.custom_minimum_size = Vector2(0, 90)
	v.add_child(review_detail)
	var close := Button.new()
	close.text = TextsZh.COMMON_BACK
	close.pressed.connect(func() -> void: review_popup.visible = false)
	v.add_child(close)

## 展开已过房间列表（只读回看：已完成检定与战斗不重置，04 §④.2）。
func _open_room_review() -> void:
	for child: Node in review_list.get_children():
		child.queue_free()
	review_detail.text = ""
	var ids: Array = _rooms_snapshot.get("ids", [])
	var titles: Dictionary = _rooms_snapshot.get("titles", {})
	var current := int(_rooms_snapshot.get("current", 0))
	for i: int in mini(current, ids.size()): # 已过房间（不含当前/未来）
		var rid := str(ids[i])
		var b := Button.new()
		b.text = "%d. %s" % [i + 1, str(titles.get(rid, rid))]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func() -> void: _review_room(rid))
		review_list.add_child(b)
	if review_list.get_child_count() == 0:
		var l := Label.new()
		l.text = "（尚无已过房间）"
		review_list.add_child(l)
	review_popup.visible = true

## 点房间 = 回看其摘要（只读 pack 数据，不触碰图状态、不写板）。
func _review_room(rid: String) -> void:
	var titles: Dictionary = _rooms_snapshot.get("titles", {})
	var node: Dictionary = (_pack.get("nodes", {}) as Dictionary).get(rid, {})
	review_detail.text = "【%s】\n%s" % [str(titles.get(rid, rid)), str(node.get("summary", ""))]

## 测试探针：回看弹层可见性。
func is_review_visible() -> bool:
	return review_popup.visible

# ---------------------------------------------------------------- 绑定与事件订阅（壳唯一输入：事件流 + 只读 getter）

func bind(p_sm: EncounterSM, p_agent: AutoAgent) -> void:
	sm = p_sm
	agent = p_agent
	_stream = sm.stream
	_stream.subscribe(_on_event)
	show_combat_layout() # 故事态 → 战斗态：同一壳内布局切换（04 §④.1 呼吸随状态切换）
	_restore_breathing()
	_refresh_all()

## 故事态绑定（节点流程）：内容源 StoryVM + 事件流；不含 EncounterSM。
func bind_story(p_stream: EventStream, p_board: Board, p_pack: Dictionary, callbacks: Dictionary) -> void:
	sm = null
	_stream = p_stream
	_board = p_board
	_pack = p_pack
	story_cb = callbacks
	_stream.subscribe(_on_event)
	_story = true

## 离场退订：壳随界面切换销毁时不得残留事件订阅（否则事件流持有失效 Callable）。
func _exit_tree() -> void:
	if _stream != null:
		_stream.unsubscribe(_on_event)
		_stream = null

func _on_event(ev: Dictionary) -> void:
	var line := BattleText.event_log_text(ev, _unit_name) # 日志文案两壳共享（battle_text.gd）
	if line != "":
		_log_line(line)
	var t := StringName(ev["type"])
	# 掷骰两级演出与战斗/故事同一事件源（09 §6）
	if t == EventTypes.CHECK_ROLL:
		var p: Dictionary = ev["payload"]
		if bool(p.get("key", false)):
			var q := p.duplicate(true)
			q["event_id"] = ev["id"]
			_play_key_roll(q) # 关键判定：全屏演出（09 §6）
		else:
			_tray_roll(p)
	if _story:
		# 状态反馈（任务书 §3）：旗标/声望/道具/事件 toast + 时钟角标，全经事件流驱动
		var toast := StoryVM.toast_text(ev, _pack)
		if toast != "":
			_flash(toast)
		if t == EventTypes.CLOCK_TICK and _board != null:
			_vm["clock"] = _board.get_doom_clock()
			_refresh_story_status()
		return
	match t:
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
		EventTypes.BATTLE_DOWN:
			_flash("%s 倒地！" % str(ev["payload"]["name"]))
		EventTypes.COMBAT_END:
			set_auto(false) # 遭遇结束托管自动停止（09 §9.3）
	_refresh_all()

# ---------------------------------------------------------------- 故事态（节点即房间，04 §④.2/§④.3）

## 呈现当前节点：呼吸对话档（04 §④.1 对话行）、推进条 pip 同步 story 节点、
## 主视野叙事文本、操作台选项列表（check=一键快掷 / dialog=选项带声望角标 / hub=三设施）。
func show_story(vm: Dictionary) -> void:
	_vm = vm
	_story = true
	apply_breathing(&"dialog")
	clock_chip.visible = true
	quest_chip.visible = true
	round_label.visible = false
	auto_button.visible = false
	speed_button.visible = false
	story_panel.visible = true
	enemy_row.visible = false
	party_row.visible = false
	_refresh_story_status()
	set_rooms(vm["rooms"], int(vm["room_index"]), vm["room_titles"]) # pip 同步 story 节点（04 §④.2）
	story_title.text = str(vm["title"])
	story_text.text = str(vm["text"])
	_refresh_story_options()
	tabs.current_tab = 0

## 战斗布局恢复（bind 进入遭遇时调用；故事面板收起，单位行/回合计/托管件归位）。
func show_combat_layout() -> void:
	_story = false
	story_panel.visible = false
	enemy_row.visible = true
	party_row.visible = true
	clock_chip.visible = false
	quest_chip.visible = false
	round_label.visible = true
	auto_button.visible = true
	speed_button.visible = true

func _refresh_story_status() -> void:
	clock_chip.text = TextsZh.STORY_CLOCK % int(_vm.get("clock", 0))
	var fc: Dictionary = _vm.get("forecast", {})
	if not fc.is_empty():
		clock_chip.text += " " + TextsZh.STORY_CLOCK_NEXT % [str(fc.get("name", "")), int(fc.get("at", 0))]
	quest_chip.text = TextsZh.STORY_QUEST_BADGE % int(_vm.get("quest_badge", 0))
	for child: Node in party_chips.get_children():
		child.queue_free()
	for p: Variant in _vm.get("party", []):
		var chip := Label.new()
		chip.text = " %s %d/%d " % [str((p as Dictionary)["name"]), int((p as Dictionary)["hp"]),
			int((p as Dictionary)["max_hp"])]
		party_chips.add_child(chip)

func _refresh_story_options() -> void:
	for child: Node in quickbar.get_children():
		child.queue_free()
	var idx := 0
	for e: Variant in _vm.get("edges", []):
		var i := idx
		_add_chip(str((e as Dictionary)["label"]), false, func() -> void:
			if story_cb.has("edge"):
				story_cb["edge"].call(i))
		idx += 1
	if str(_vm.get("type", "")) == "hub": # hub 三设施（战役书 §4 N1-1）
		_add_chip(TextsZh.HUB_SHOP, false, func() -> void: hub_popup.open(
			int(_vm.get("gold", 0)), _vm.get("stock", [])))
		_add_chip(TextsZh.HUB_REST, false, func() -> void:
			if story_cb.has("hub"):
				story_cb["hub"].call("rest", ""))
		_add_chip(TextsZh.HUB_RUMOR, false, func() -> void:
			if story_cb.has("hub"):
				story_cb["hub"].call("rumor", ""))

## 购买/休整后由 main 同步弹层货单与金币（弹层开着时刷新，不关弹层）。
func sync_hub_popup(vm: Dictionary) -> void:
	if hub_popup.visible:
		hub_popup.bind(int(vm.get("gold", 0)), vm.get("stock", []))

## 时间钟弹层：时间边逼近事件预告（04 §3.1 例外交互）。
func _open_forecast() -> void:
	var lines: Array = []
	for f: Variant in _vm.get("forecasts", []):
		lines.append("%s —— 时钟 %d 格触发（%s）" % [str((f as Dictionary).get("name", "")),
			int((f as Dictionary).get("at", 0)), str((f as Dictionary).get("objective", ""))])
	if lines.is_empty():
		lines.append(TextsZh.STORY_FORECAST_EMPTY)
	info_popup.show_info(TextsZh.STORY_FORECAST_TITLE, lines)

## 测试探针：当前故事选项按钮文案。
func story_option_texts() -> Array:
	var out: Array = []
	for child: Node in quickbar.get_children():
		if child is Button:
			out.append((child as Button).text)
	return out

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
	_rooms_snapshot = {"ids": room_ids.duplicate(), "titles": titles.duplicate(),
		"current": current_index} # 回看数据（04 §④.2）
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
		var chip := _add_chip(TextsZh.action_label(a), bool(a["disabled"]), func() -> void: press_action(a))
		chip.set_meta("action", a) # 芯片拖动 = 指定目标使用（12 §3.6）

func _add_chip(label: String, disabled: bool, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.disabled = disabled
	b.pressed.connect(on_press)
	quickbar.add_child(b)
	return b

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

# 骰子皮肤（06 §3/§7 外观商品位）：换肤 = 换调色板，纯呈现——只读 Board 外观旗标经
# Cosmetics.palette_of 取色，不进任何逻辑判定；渲染层对规则档位无感（godot-dev §2）。
func _dice_palette() -> Dictionary:
	var b: Board = null
	if _board != null:
		b = _board # 故事态（bind_story）
	elif sm != null:
		b = sm.board # 战斗态
	return Cosmetics.palette_of(b)

## 应用当前皮肤：骰面主色 = face、描边 = edge、明细行 = pip。
func _apply_dice_skin() -> void:
	var pal := _dice_palette()
	for lbl: Label in [dice_label, key_dice_label]:
		lbl.add_theme_color_override("font_color", pal["face"])
		lbl.add_theme_color_override("font_outline_color", pal["edge"])
		lbl.add_theme_constant_override("outline_size", 12)
	dice_detail.add_theme_color_override("font_color", (pal["pip"] as Color).lightened(0.35))

## 普通：骰子 Tab 托盘快掷（≤0.5s 出结果）。
func _tray_roll(p: Dictionary) -> void:
	if _tray_rolling:
		return
	_tray_rolling = true
	_apply_dice_skin()
	var visual := Rng.new(int(p.get("keep", 1)) * 7919 + 3) # 演出层视觉随机，与逻辑骰无关
	var keep := str(p.get("keep", "?"))
	for i: int in 5:
		dice_label.text = str(visual.d20())
		await get_tree().create_timer(0.07).timeout # 5×0.07=0.35s ≤0.5s
	dice_label.text = keep
	# 托盘动效轻量升级（14 #2：落定缩放回弹一拍，仍 ≤0.5s 总量）
	dice_label.pivot_offset = dice_label.size * 0.5
	var pop := create_tween()
	pop.tween_property(dice_label, "scale", Vector2(1.35, 1.35), 0.08)
	pop.tween_property(dice_label, "scale", Vector2.ONE, 0.14)
	var rolls: Array = p.get("rolls", [])
	dice_detail.text = "骰 %s 修正 %+d 合计 %d（%s）" % [str(rolls), int(p.get("mod", p.get("atk_mod", 0))),
		int(p.get("total", p.get("keep", 0))),
		TextsZh.RESULT_SUCCESS if bool(p.get("success", p.get("hit", false))) else TextsZh.RESULT_FAIL]
	_tray_rolling = false

## 关键：全屏 3D 物理演出（14 清单 #2 / 09 §6；长按 ≥400ms 跳过；死亡豁免恒定关键，11 §7）。
## 结果取事件流 keep 值，物理只是表演——落定顶面必为给定结果（骰子公正性，06 §4 同源）。
func _play_key_roll(p: Dictionary) -> void:
	_key_queue.append(p)
	if _key_playing:
		return
	_key_playing = true
	while not _key_queue.is_empty():
		var q: Dictionary = _key_queue.pop_front()
		apply_breathing(&"key_roll") # 全屏接管（04 §④.1 关键判定行）
		_apply_dice_skin() # 关键演出同皮肤（06 §7：换肤只换配色与描边）
		key_overlay.visible = true
		key_result_label.text = ""
		key_dice_label.visible = false # 2D 翻滚数字退役为托盘专属（14 #2）
		_key_skip = false
		_key_hold_start = -1 # 每场演出从"未按住"开始，防上一场的按住状态串场
		dice3d.play(int(q.get("keep", 1)), int(q.get("event_id", 1)) * 131 + 7, _dice_palette())
		while dice3d.is_playing():
			_poll_key_hold()
			if _key_skip:
				dice3d.request_skip()
			await get_tree().create_timer(0.05).timeout
		key_dice_label.visible = true
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
			_poll_key_hold() # 落定后也尊重长按（滚动已播完但按住仍生效）
		if not _key_skip:
			await get_tree().create_timer(0.7).timeout
		key_overlay.visible = false
		_restore_breathing()
	_key_playing = false

## 长按 ≥400ms 跳过（04 §④.7：一切演出可跳过（长按），防误触；12 §1 长按判定参数）：
## 按下记录起点，演出循环每拍轮询 hold_clock；未到时抬手 = 不跳过。
## 判定与真实时钟解耦：hold_clock 可注入，测试注入假时钟步进（与 GestureRecognizer 同一注入式时间风格）。
func _on_key_overlay_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if (event as InputEventMouseButton).pressed:
			_key_hold_start = int(hold_clock.call())
		else:
			_key_hold_start = -1
	elif event is InputEventScreenTouch:
		if (event as InputEventScreenTouch).pressed:
			_key_hold_start = int(hold_clock.call())
		else:
			_key_hold_start = -1

## 长按进度轮询：按住 ≥400ms（12 §1）即置跳过；判定只读 hold_clock，与帧计时无关。
func _poll_key_hold() -> void:
	if _key_hold_start >= 0 \
			and int(hold_clock.call()) - _key_hold_start >= GestureRecognizer.LONG_PRESS_MS:
		_key_hold_start = -1
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
	b.set_meta("unit_id", str(u["id"])) # 手势命中测试（12 §3.1 起点定语义）
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
