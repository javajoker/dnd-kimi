# ① 主屏（营地）（docs/framework/04-UI-UX设计文档.md §①；07 §4.2 主屏闲置兜底快照；12 §4 帮助入口；12 §5 主屏热点图）
# - 视觉层 = 可交互绘卷（HomeScroll，烬港夜景程序化占位，12 §5 落位状态）；热点与兜底条指向同一 navigate 信号
#   （12 §5：热点图是皮肤，文字入口是骨架，两者功能等价——兜底条为无障碍与辨识度兜底）；
# - 营地图景随褪墨度（global.doom_clock）变化文案与绘卷视觉（04 §①/§4 ①：状态板的可视化）；
# - 五入口：战役入口（进行中带"继续"）、事件中心（未读角标）、背包图鉴、角色、历史卷轴；
# - 运营位（框架级占位，内容由投放决定）+ 帮助入口（手势图鉴，12 §4）+ 手动"记录抄本"（07 §4.2）；
# - 壳铁律：只读 Board、发信号；写板与存档由 main 流程控制器执行。
class_name ScreenHome
extends Control

signal navigate(screen_id: StringName)
signal save_requested   # 手动"记录抄本"（07 §4.2 手动时机）
signal idle_timeout     # 主屏闲置（07 §4.2 兜底快照）
signal tutorial_done          # 启动卡看完/跳过（12 §4；写板由 main 落）
signal retrain_requested      # 帮助页「重学教程」（12 §4：可重学；清触发记录由 main 落）

const IDLE_SAVE_SEC := 2.0

var doom_label: Label
var scroll: HomeScroll            # 可交互绘卷（12 §5：热点=皮肤）
var fallback_bar: Container       # 底部文字入口兜底条（12 §5：骨架，与热点功能等价）
var campaign_button: Button
var quests_button: Button
var inventory_button: Button
var character_button: Button
var history_button: Button
var save_button: Button
var help_button: Button
var saved_label: Label
var idle_timer: Timer
var _help_overlay: PanelContainer
var tutorial: TutorialOverlay # 启动卡（12 §4 第一层：首次启动 3 页核心手势，可跳过）

func _ready() -> void:
	_build()
	size = get_viewport().get_visible_rect().size # 根 Control 父级为纯 Node：显式落视口尺寸（锚定无参照）
	idle_timer = Timer.new()
	idle_timer.wait_time = IDLE_SAVE_SEC
	idle_timer.one_shot = true
	idle_timer.timeout.connect(func() -> void: idle_timeout.emit())
	add_child(idle_timer)
	idle_timer.start()

func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 8)
	add_child(margin)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	margin.add_child(v)
	var title := Label.new()
	title.text = TextsZh.HOME_TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	v.add_child(title)
	doom_label = Label.new()
	doom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	doom_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(doom_label)
	# 可交互绘卷（12 §5 ①：五热点承载入口；热点与兜底条同信号，两路径功能等价）
	scroll = HomeScroll.new()
	scroll.custom_minimum_size = Vector2(0, 330)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.hotspot_pressed.connect(func(id: StringName) -> void: navigate.emit(id))
	v.add_child(scroll)
	var op := Label.new()
	op.text = TextsZh.HOME_OP_SLOT
	op.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	op.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	op.add_theme_font_size_override("font_size", 11)
	op.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(op)
	# 底部文字入口兜底条（12 §5：无障碍与辨识度兜底；热点图是皮肤，文字入口是骨架）
	fallback_bar = VBoxContainer.new()
	fallback_bar.add_theme_constant_override("separation", 4)
	v.add_child(fallback_bar)
	var row1 := HBoxContainer.new()
	row1.alignment = BoxContainer.ALIGNMENT_CENTER
	fallback_bar.add_child(row1)
	campaign_button = _entry(row1, TextsZh.HOME_ENTRY_CAMPAIGN, &"entry")
	quests_button = _entry(row1, TextsZh.HOME_ENTRY_QUESTS, &"quests")
	inventory_button = _entry(row1, TextsZh.HOME_ENTRY_INVENTORY, &"inventory")
	var row2 := HBoxContainer.new()
	row2.alignment = BoxContainer.ALIGNMENT_CENTER
	fallback_bar.add_child(row2)
	character_button = _entry(row2, TextsZh.HOME_ENTRY_CHARACTER, &"character")
	history_button = _entry(row2, TextsZh.HOME_ENTRY_HISTORY, &"history")
	save_button = Button.new()
	save_button.text = TextsZh.HOME_SAVE
	save_button.custom_minimum_size = Vector2(0, 44)
	save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_button.pressed.connect(func() -> void:
		saved_label.text = TextsZh.HOME_SAVED
		save_requested.emit())
	row2.add_child(save_button)
	help_button = Button.new()
	help_button.text = TextsZh.HOME_HELP
	help_button.custom_minimum_size = Vector2(0, 44)
	help_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	help_button.pressed.connect(_toggle_help)
	row2.add_child(help_button)
	saved_label = Label.new()
	saved_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	saved_label.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6))
	v.add_child(saved_label)
	_build_help()

func _entry(parent: Container, label: String, screen_id: StringName) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(0, 44) # 12 §6：可触目标最小 44×44pt
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(func() -> void: navigate.emit(screen_id))
	parent.add_child(b)
	return b

## 刷新（只读 Board）。quest_badge = 进行中事件数；continuable = 存在可继续的战役进度/存档。
func bind(board: Board, quest_badge: int, continuable: bool) -> void:
	doom_label.text = TextsZh.home_doom_text(board.get_doom_clock())
	campaign_button.text = "%s（%s）" % [TextsZh.HOME_ENTRY_CAMPAIGN, TextsZh.HOME_CONTINUE] \
		if continuable else TextsZh.HOME_ENTRY_CAMPAIGN
	quests_button.text = "%s ◆%d" % [TextsZh.HOME_ENTRY_QUESTS, quest_badge] \
		if quest_badge > 0 else TextsZh.HOME_ENTRY_QUESTS
	scroll.set_state(board.get_doom_clock(), quest_badge) # 绘卷随状态板变化（12 §5；04 §4 ①）
	saved_label.text = ""
	if idle_timer != null:
		idle_timer.start() # 回到主屏重新计闲置（07 §4.2）

# ---------------------------------------------------------------- 帮助页 · 手势图鉴（12 §4）

func _build_help() -> void:
	_help_overlay = PanelContainer.new()
	_help_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_help_overlay.visible = false
	add_child(_help_overlay)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 6)
	_help_overlay.add_child(v)
	var title := Label.new()
	title.text = TextsZh.HELP_TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	v.add_child(title)
	for line: String in TextsZh.HELP_LINES:
		var l := Label.new()
		l.text = line
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(340, 0)
		v.add_child(l)
	var close := Button.new()
	close.text = TextsZh.COMMON_BACK
	close.pressed.connect(_toggle_help)
	v.add_child(close)
	var retrain := Button.new() # 重学入口（12 §4：可重学——清触发记录并重放启动卡，写板由 main 落）
	retrain.text = TextsZh.HELP_RETRAIN
	retrain.pressed.connect(func() -> void: retrain_requested.emit())
	v.add_child(retrain)

func _toggle_help() -> void:
	_help_overlay.visible = not _help_overlay.visible

## 启动卡（12 §4 第一层：首次启动一次性，"跳过"常驻）。
func show_launch_tutorial() -> void:
	if tutorial == null:
		tutorial = TutorialOverlay.new()
		tutorial.launch_finished.connect(func() -> void: tutorial_done.emit())
		add_child(tutorial)
	tutorial.show_launch()

## 测试探针。
func is_help_visible() -> bool:
	return _help_overlay.visible

func debug_force_idle() -> void:
	idle_timer.stop()
	idle_timeout.emit()
