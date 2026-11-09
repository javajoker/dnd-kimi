# 横屏遭遇壳（docs/framework/04-UI-UX设计文档.md §③；09 §4/§6/§7/§9；tech/01 §6.2/§10 TP3）
# 五区冻结指标（09 §4）：
#   上缘 8% 队伍状态条 + 先攻顺序条（战斗时展开）+ ☰（上缘右端，09 §7）；
#   左/中/右三栏为宽度相对权重 15:60:12，渲染时归一拉伸至满宽（≈17.2/69.0/13.8%，TP3 验收裁决 1）：
#   左栏 行动轮盘（与竖屏快捷栏同一 EncounterSM 可用指令集，禁止复制过滤逻辑）；
#   中央 战术格地图（8×5 占位，格边长 ≥ 屏高 8%，敌红我金）；
#   右栏 骰子盘（最近一次检定/攻击 d20 明细）；
#   下缘 5% 日志带，点击展开至半屏。
# 铁律落位：壳只订阅事件流 + 只读 getter（godot-dev §2）；指令一律经 submit_command；
# 掷骰演出与竖屏同一事件源（09 §6：普通快掷 ≤0.5s，关键全屏可跳过）；
# 单位格位是呈现层布局（内容数据可声明 pos，否则按阵营+先攻序确定性落位），不进事件流。
class_name EncounterLandscape
extends Control

const RATIO_TOP := 0.08
const RATIO_BOTTOM := 0.05
# 三栏宽度相对权重 15:60:12（09 §4），渲染时归一拉伸至满宽（TP3 验收裁决 1）
const WEIGHT_LEFT := 15.0
const WEIGHT_CENTER := 60.0
const WEIGHT_RIGHT := 12.0
const WEIGHT_SUM := WEIGHT_LEFT + WEIGHT_CENTER + WEIGHT_RIGHT
const RATIO_LEFT := WEIGHT_LEFT / WEIGHT_SUM     # ≈0.1724
const RATIO_CENTER := WEIGHT_CENTER / WEIGHT_SUM # ≈0.6897
const RATIO_RIGHT := WEIGHT_RIGHT / WEIGHT_SUM   # ≈0.1379
const LOG_EXPANDED_TOP := 0.5 # 09 §4：日志带展开至半屏
const GRID_COLS := 8
const GRID_ROWS := 5
const AUTO_INTERVAL := 0.8 # 09 §9.3：代理节拍下限（1×），2×=0.4s
const COLOR_ENEMY := Color(0.78, 0.28, 0.24) # 敌红（09 §4/任务指标）
const COLOR_PARTY := Color(0.88, 0.72, 0.32) # 我金
const COLOR_CELL := Color(0.10, 0.10, 0.14)
const COLOR_CELL_BORDER := Color(0.30, 0.30, 0.38)
const COLOR_CURRENT := Color(1.0, 1.0, 1.0)

var sm: EncounterSM = null
var agent: AutoAgent = null
var auto_on := false
var speed := 1
var log_expanded := false
## ☰「保存并回主屏」回调（09 §7：回到遭遇进入前快照，由 main 流程控制器接管；未接管时退出进程）。
var on_save_quit: Callable = Callable()
# ---- 节点流程故事态（04 §③：中央主视野渲染叙事/选项，非战斗态；内容源 StoryVM）----
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
var flash_label: Label
var wheel_title: Label
var hub_popup: HubPopup
var info_popup: InfoPopup

# ---- 节点（_ready 构建）----
var top_band: PanelContainer
var party_chips: HBoxContainer
var init_bar: HBoxContainer
var round_label: Label
var speed_button: Button
var auto_button: Button
var menu_button: Button
var left_wheel: PanelContainer
var wheel_actor: Label
var wheel_box: VBoxContainer
var center_map: PanelContainer
var grid: GridContainer
var right_dice: PanelContainer
var dice_label: Label
var dice_detail: Label
var log_band: PanelContainer
var log_last: Label
var log_toggle: Button
var log_full: RichTextLabel
var key_overlay: ColorRect
var key_dice_label: Label
var key_result_label: Label
var auto_timer: Timer
var menu_popup: PopupPanel
var key_hold_timer: Timer       # 长按 ≥400ms 跳过演出（04 §④.7；12 §1 长按判定参数）
var gestures: GestureLayer      # 手势层（12 §1~§3：透明覆盖，不吞事件）
var tutorial: TutorialOverlay   # 情境教程层（12 §4 第二层）
var path_line: Line2D           # 轨迹施法预览（12 §2.1）

var _cells: Array[PanelContainer] = []
var _grid_side := -1.0
var _unit_cells: Dictionary = {}  # id -> Vector2i
var _moved_cells: Dictionary = {} # id -> Vector2i：拖动移动的呈现层落位（格位是呈现层布局，不进事件流）
var _unit_colors: Dictionary = {} # id -> Color
var _selected_target := ""
var _log_lines: Array[String] = []
var _key_queue: Array[Dictionary] = []
var _key_playing := false
var _key_skip := false
var _tray_rolling := false
var _drag_uid := ""               # 拖动中的己方单位（12 §3.1 起点定语义）
var _drag_action := {}            # 轮盘芯片拖动中的指令集条目（12 §3.6）
var _zoom := 1.0                  # 捏合缩放累计（0.7~1.6，横屏持续生效；12 §2.1/任务书）
var _zoom0 := 1.0                 # 本次捏合会话起始倍率

func _ready() -> void:
	_build_ui()
	auto_timer = Timer.new()
	auto_timer.wait_time = AUTO_INTERVAL
	auto_timer.timeout.connect(_on_auto_timeout)
	add_child(auto_timer)
	key_hold_timer = Timer.new()
	key_hold_timer.wait_time = GestureRecognizer.LONG_PRESS_MS / 1000.0
	key_hold_timer.one_shot = true
	key_hold_timer.timeout.connect(func() -> void: _key_skip = true)
	add_child(key_hold_timer)
	_setup_gestures()

# ---------------------------------------------------------------- UI 构建（五区，09 §4）

func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 上缘 8%：队伍状态条 + 先攻顺序条（战斗时展开）+ ☰（右端）
	top_band = PanelContainer.new()
	top_band.name = "TopBand"
	add_child(top_band)
	_set_rect(top_band, 0.0, 0.0, 1.0, RATIO_TOP)
	var top_h := HBoxContainer.new()
	top_h.add_theme_constant_override("separation", 8)
	top_band.add_child(top_h)
	clock_chip = Button.new() # 时间钟总览格：按下弹时间边预告（04 §3.1 例外交互）
	clock_chip.visible = false
	clock_chip.pressed.connect(_open_forecast)
	top_h.add_child(clock_chip)
	quest_chip = Label.new() # 事件中心角标（04 §⑤）
	quest_chip.visible = false
	top_h.add_child(quest_chip)
	party_chips = HBoxContainer.new()
	top_h.add_child(party_chips)
	init_bar = HBoxContainer.new()
	init_bar.name = "InitBar"
	init_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	init_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	init_bar.add_theme_constant_override("separation", 4)
	init_bar.visible = false
	top_h.add_child(init_bar)
	round_label = Label.new()
	top_h.add_child(round_label)
	speed_button = Button.new()
	speed_button.text = "1×"
	speed_button.pressed.connect(func() -> void: set_speed(2 if speed == 1 else 1))
	top_h.add_child(speed_button)
	auto_button = Button.new()
	auto_button.text = TextsZh.AUTO_ON
	auto_button.pressed.connect(func() -> void: set_auto(not auto_on))
	top_h.add_child(auto_button)
	menu_button = Button.new()
	menu_button.text = TextsZh.MENU
	menu_button.pressed.connect(_open_menu)
	top_h.add_child(menu_button) # ☰ 常驻上缘右端（09 §7）
	# 左栏 15%：行动轮盘
	left_wheel = PanelContainer.new()
	left_wheel.name = "LeftWheel"
	add_child(left_wheel)
	_set_rect(left_wheel, 0.0, RATIO_TOP, RATIO_LEFT, 1.0 - RATIO_BOTTOM)
	var wheel_v := VBoxContainer.new()
	left_wheel.add_child(wheel_v)
	wheel_title = Label.new()
	wheel_title.text = TextsZh.ZONE_WHEEL
	wheel_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wheel_v.add_child(wheel_title)
	wheel_actor = Label.new()
	wheel_actor.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wheel_v.add_child(wheel_actor)
	wheel_box = VBoxContainer.new()
	wheel_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wheel_box.add_theme_constant_override("separation", 4)
	wheel_v.add_child(wheel_box)
	# 中央 60%：战术格地图
	center_map = PanelContainer.new()
	center_map.name = "CenterMap"
	add_child(center_map)
	_set_rect(center_map, RATIO_LEFT, RATIO_TOP, RATIO_LEFT + RATIO_CENTER, 1.0 - RATIO_BOTTOM)
	var center := CenterContainer.new()
	center_map.add_child(center)
	grid = GridContainer.new()
	grid.columns = GRID_COLS
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	center.add_child(grid)
	center_map.resized.connect(_layout_grid)
	# 故事态叙事面板（中央主视野，非战斗态；04 §③ 中央 60%）
	story_panel = VBoxContainer.new()
	story_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	story_panel.add_theme_constant_override("separation", 10)
	story_panel.visible = false
	center_map.add_child(story_panel)
	story_title = Label.new()
	story_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	story_title.add_theme_font_size_override("font_size", 22)
	story_panel.add_child(story_title)
	story_text = RichTextLabel.new()
	story_text.bbcode_enabled = false
	story_text.scroll_following = false
	story_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	story_text.add_theme_font_size_override("normal_font_size", 18)
	story_panel.add_child(story_text)
	# 右栏 12%：骰子盘
	right_dice = PanelContainer.new()
	right_dice.name = "RightDice"
	add_child(right_dice)
	_set_rect(right_dice, RATIO_LEFT + RATIO_CENTER, RATIO_TOP,
		RATIO_LEFT + RATIO_CENTER + RATIO_RIGHT, 1.0 - RATIO_BOTTOM)
	var dice_v := VBoxContainer.new()
	right_dice.add_child(dice_v)
	var dice_title := Label.new()
	dice_title.text = TextsZh.ZONE_DICE
	dice_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dice_v.add_child(dice_title)
	dice_label = Label.new()
	dice_label.add_theme_font_size_override("font_size", 48)
	dice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dice_v.add_child(dice_label)
	dice_detail = Label.new()
	dice_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dice_v.add_child(dice_detail)
	# 下缘 5%：日志带（点击展开半屏，09 §4）
	log_band = PanelContainer.new()
	log_band.name = "LogBand"
	add_child(log_band)
	_set_rect(log_band, 0.0, 1.0 - RATIO_BOTTOM, 1.0, 1.0)
	var log_v := VBoxContainer.new()
	log_band.add_child(log_v)
	var log_header := HBoxContainer.new()
	log_v.add_child(log_header)
	log_last = Label.new()
	log_last.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_last.clip_text = true
	log_header.add_child(log_last)
	log_toggle = Button.new()
	log_toggle.text = TextsZh.LOG_EXPAND
	log_toggle.pressed.connect(toggle_log)
	log_header.add_child(log_toggle)
	log_full = RichTextLabel.new()
	log_full.bbcode_enabled = false
	log_full.scroll_following = true
	log_full.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_full.visible = false
	log_v.add_child(log_full)
	# 关键判定全屏覆盖（09 §6，与竖屏同一事件源）
	key_overlay = ColorRect.new()
	key_overlay.name = "KeyOverlay"
	key_overlay.color = Color(0.02, 0.02, 0.08, 0.96)
	key_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	key_overlay.visible = false
	key_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	key_overlay.gui_input.connect(_on_key_overlay_input)
	add_child(key_overlay)
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
	# 状态反馈 toast（任务书 §3：旗标/声望/道具/事件，事件流驱动，与竖屏同一文案源 StoryVM）
	flash_label = Label.new()
	flash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	flash_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	flash_label.add_theme_font_size_override("font_size", 18)
	_set_rect(flash_label, 0.25, RATIO_TOP + 0.01, 0.75, RATIO_TOP + 0.07)
	flash_label.modulate = Color(1, 1, 1, 0)
	add_child(flash_label)
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
	_layout_grid()

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

func _set_rect(c: Control, l: float, t: float, r: float, b: float) -> void:
	c.anchor_left = l
	c.anchor_top = t
	c.anchor_right = r
	c.anchor_bottom = b
	c.offset_left = 0
	c.offset_top = 0
	c.offset_right = 0
	c.offset_bottom = 0

# ---------------------------------------------------------------- 战术格（09 §4：8×5 占位，格边长 ≥ 屏高 8%）

func _layout_grid() -> void:
	var side := cell_side()
	# 只有格边长实际变化才重建——重建会改变 grid 最小尺寸，否则 resized→重建→resized 死循环
	if _cells.size() == GRID_COLS * GRID_ROWS and absf(side - _grid_side) < 0.5:
		return
	_grid_side = side
	for child: Node in grid.get_children():
		child.queue_free()
	_cells.clear()
	for i: int in GRID_COLS * GRID_ROWS:
		var cell := PanelContainer.new()
		cell.custom_minimum_size = Vector2(side, side)
		cell.add_theme_stylebox_override("panel", _cell_style(COLOR_CELL, COLOR_CELL_BORDER))
		var idx := i
		cell.gui_input.connect(func(ev: InputEvent) -> void: _on_cell_input(idx, ev))
		grid.add_child(cell)
		_cells.append(cell)
	if sm != null:
		_refresh_grid()

## 格边长（扣除分隔缝，保证 grid 最小尺寸 ≤ 栏内可用区，不触发父容器膨胀）。
func cell_side() -> float:
	var sep := 2.0
	var w := maxf(center_map.size.x - float(GRID_COLS - 1) * sep, float(GRID_COLS))
	var h := maxf(center_map.size.y - float(GRID_ROWS - 1) * sep, float(GRID_ROWS))
	return floorf(minf(w / float(GRID_COLS), h / float(GRID_ROWS)))

## 点按敌格选目标（12 §1 点按；目标选择是 UI 状态，不进事件流）。
func _on_cell_input(idx: int, ev: InputEvent) -> void:
	if not (ev is InputEventMouseButton) or not (ev as InputEventMouseButton).pressed or sm == null:
		return
	for id: String in _unit_cells:
		var p: Vector2i = _unit_cells[id]
		if p.y * GRID_COLS + p.x != idx:
			continue
		var u := sm.get_unit(id)
		if u["side"] == &"enemy" and not bool(u["dead"]):
			_selected_target = id
			_refresh_grid()
		return

func _cell_style(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	return sb

## 单位格位：内容数据可声明 "pos": [x, y]；否则按阵营 + 先攻序确定性落位（呈现层，不进事件流）。
## 拖动移动的落位是同一呈现层（_moved_cells 覆盖，12 §2.1；移动段消耗经 CMD_MOVE 走 core）。
func _place_units() -> void:
	_unit_cells.clear()
	var enemies: Array[String] = []
	var party: Array[String] = []
	for id: String in sm.get_order():
		var u := sm.get_unit(id)
		if _moved_cells.has(id):
			_unit_cells[id] = _moved_cells[id]
		elif u.has("pos"):
			var pv: Array = u["pos"]
			_unit_cells[id] = Vector2i(clampi(int(pv[0]), 0, GRID_COLS - 1),
				clampi(int(pv[1]), 0, GRID_ROWS - 1))
		elif u["side"] == &"enemy":
			enemies.append(id)
		else:
			party.append(id)
	for i: int in enemies.size():
		_unit_cells[enemies[i]] = Vector2i(mini(1 + i * 2, GRID_COLS - 1), 0) # 敌上
	for i: int in party.size():
		_unit_cells[party[i]] = Vector2i(mini(1 + i * 2, GRID_COLS - 1), GRID_ROWS - 1) # 我下

func unit_cell(id: String) -> Vector2i:
	return _unit_cells.get(id, Vector2i(-1, -1))

func token_color(id: String) -> Color:
	return _unit_colors.get(id, Color.TRANSPARENT)

func _refresh_grid() -> void:
	if _cells.size() != GRID_COLS * GRID_ROWS:
		_layout_grid()
	_place_units()
	var current := sm.current_actor_id()
	for i: int in _cells.size():
		var cell := _cells[i]
		for child: Node in cell.get_children():
			child.queue_free()
		cell.add_theme_stylebox_override("panel", _cell_style(COLOR_CELL, COLOR_CELL_BORDER))
	_unit_colors.clear()
	for id: String in _unit_cells:
		var u := sm.get_unit(id)
		var pos: Vector2i = _unit_cells[id]
		var cell := _cells[pos.y * GRID_COLS + pos.x]
		var base := COLOR_ENEMY if u["side"] == &"enemy" else COLOR_PARTY
		var bg := base
		if bool(u["dead"]):
			bg = base.darkened(0.7)
		elif bool(u["downed"]):
			bg = base.darkened(0.35)
		bg.a = 0.5
		_unit_colors[id] = base
		var border := COLOR_CURRENT if id == current else COLOR_CELL_BORDER
		cell.add_theme_stylebox_override("panel", _cell_style(bg, border))
		var token := Label.new()
		token.text = "%s\n%d/%d" % [str(u["name"]), int(u["hp"]), int(u["max_hp"])]
		token.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		token.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		token.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		token.add_theme_color_override("font_color", Color.WHITE)
		cell.add_child(token)

# ---------------------------------------------------------------- 手势接入（12 §2.1 横屏映射；§3 冲突消解）
# 手势是效率层：全部手势指令与轮盘/芯片同构（GestureCommands 单源），按钮等价路径全通（12 §1 铁律）。

const MOVE_RANGE := 6 # 移动 ≤6 格（11 §4）；可达性由壳在拖动预览层约束，core 只管移动段消耗

func _setup_gestures() -> void:
	path_line = Line2D.new()
	path_line.width = 2.0
	path_line.default_color = Color(1.0, 0.85, 0.4, 0.8)
	path_line.visible = false
	add_child(path_line)
	tutorial = TutorialOverlay.new()
	add_child(tutorial)
	gestures = GestureLayer.new()
	gestures.rec.target_probe = func(pos: Vector2) -> String: return _unit_id_at(pos)
	add_child(gestures)
	gestures.long_pressed.connect(_on_gesture_long_press)
	gestures.drag_started.connect(_on_gesture_drag_started)
	gestures.drag_updated.connect(_on_gesture_drag_updated)
	gestures.dragged.connect(_on_gesture_dragged)
	gestures.path_cast.connect(_on_gesture_path)
	gestures.two_finger_tapped.connect(_on_gesture_two_finger_tap)
	gestures.pinched.connect(_on_gesture_pinch)
	gestures.pinch_ended.connect(_on_gesture_pinch_ended)

func _in(c: Control, pos: Vector2) -> bool:
	return c != null and c.visible and c.get_global_rect().has_point(pos)

## 视口坐标 → 战术格（不在图内返回 (-1,-1)）。
func _cell_at(pos: Vector2) -> Vector2i:
	if _story or not _in(center_map, pos) or _cells.is_empty():
		return Vector2i(-1, -1)
	for i: int in _cells.size():
		if _cells[i].get_global_rect().has_point(pos):
			return Vector2i(i % GRID_COLS, i / GRID_COLS)
	return Vector2i(-1, -1)

func _unit_at_cell(cell: Vector2i) -> String:
	if cell.x < 0:
		return ""
	for id: String in _unit_cells:
		if _unit_cells[id] == cell:
			return id
	return ""

func _unit_id_at(pos: Vector2) -> String:
	return _unit_at_cell(_cell_at(pos))

## 轮盘芯片命中（12 §3.6：起拖点在芯片上 = 使用拖动）。
func _chip_action_at(pos: Vector2) -> Dictionary:
	for child: Node in wheel_box.get_children():
		if child is Button and (child as Button).has_meta("action") \
				and (child as Button).get_global_rect().has_point(pos):
			return (child as Button).get_meta("action")
	return {}

## 长按单位 = 信息卡半屏弹层（12 §2.1：HP/AC/伤害骰/状态）。
func _on_gesture_long_press(pos: Vector2) -> void:
	var uid := _unit_id_at(pos)
	if uid == "" or sm == null:
		return
	var u := sm.get_unit(uid)
	info_popup.show_info(str(u["name"]), [
		"HP %d/%d　AC %d" % [int(u["hp"]), int(u["max_hp"]), int(u["ac"])],
		"伤害骰 %s　攻击修正 %+d" % [str(u["damage"]), int(u["attack_mod"])],
		"状态：%s" % ("倒地" if bool(u["downed"]) else ("死亡" if bool(u["dead"]) else "正常")),
		"格位：%s" % str(unit_cell(uid)),
	])

func _on_gesture_drag_started(info: Dictionary) -> void:
	_drag_uid = ""
	_drag_action = {}
	if sm == null:
		return
	var start: Vector2 = info["start"]
	var chip := _chip_action_at(start)
	if not chip.is_empty() and not bool(chip.get("disabled", false)):
		_drag_action = chip
		return
	var uid := _unit_id_at(start)
	if uid != "" and uid == sm.current_actor_id():
		_drag_uid = uid # 起点定语义：按在己方当前单位上 = 移动/轨迹（12 §3.1）

## 拖动中预览：可达落点高亮 / 轨迹预览（12 §2.1：显示可达范围与落点预览；预览不即时生效）。
func _on_gesture_drag_updated(info: Dictionary) -> void:
	if _drag_uid == "" and _drag_action.is_empty():
		return
	var pos: Vector2 = info["pos"]
	path_line.visible = true
	path_line.points = PackedVector2Array([info["start"], pos])
	var over := _unit_id_at(pos)
	if over != "" and sm != null and str(sm.get_unit(over).get("side", "")) == &"enemy":
		_flash(TextsZh.GESTURE_PATH_AIM % [
			str(sm.get_unit(_drag_uid)["name"]) if _drag_uid != "" else str(_drag_action.get("name", "")),
			str(sm.get_unit(over)["name"])])

func _on_gesture_dragged(info: Dictionary) -> void:
	path_line.visible = false
	if _drag_uid == "" and _drag_action.is_empty():
		return
	var end: Vector2 = info["end"]
	var over := _unit_id_at(end)
	if not _drag_action.is_empty():
		var a := _drag_action
		_drag_action = {}
		if over != "":
			_manual(sm.command_from_action(a, over)) # 芯片拖到目标 = 指定使用（12 §3.6）
		else:
			_flash(TextsZh.GESTURE_CANCEL) # 落空 = 取消
		return
	var uid := _drag_uid
	_drag_uid = ""
	if sm == null:
		return
	if over != "" and str(sm.get_unit(over).get("side", "")) == &"enemy":
		_manual(GestureCommands.cast_at(sm, over)) # 终点落敌 = 施法（12 §3.2）
		return
	# 落空格 = 移动（消耗移动段，11 §4）：可达 = 曼哈顿 ≤6 且无占用（壳层约束，core 记移动段）
	var cell := _cell_at(end)
	if cell.x >= 0 and _unit_at_cell(cell) == "":
		var from: Vector2i = unit_cell(uid)
		if from.x >= 0 and absi(cell.x - from.x) + absi(cell.y - from.y) <= MOVE_RANGE:
			# 呈现层落位以 core 受理为准（移动段耗尽/被拒 = 不挪子，事件流唯一真相）
			if _manual(GestureCommands.move_to(sm, "%d,%d" % [cell.x, cell.y])):
				_moved_cells[uid] = cell
				_refresh_grid()
				return
	_flash(TextsZh.GESTURE_CANCEL) # 不可达/被拒/落空 = 取消（12 §3.2/§3.5）

## 拖动经过 ≥2 语义目标且终点落敌 = 轨迹施法（12 §1 path；与平拖同一出口）。
func _on_gesture_path(info: Dictionary) -> void:
	if _drag_uid != "" or not _drag_action.is_empty():
		_on_gesture_dragged(info)

## 双指点击战场任意处 = 结束回合（12 §2.1）；故事态 = 首个检定边一键快掷（12 §2.2 同语义）。
func _on_gesture_two_finger_tap(pos: Vector2) -> void:
	if sm != null and not _story:
		if _in(center_map, pos):
			_manual(GestureCommands.end_turn(sm))
		return
	if _story and story_cb.has("edge") and _in(center_map, pos):
		var idx := 0
		for e: Variant in _vm.get("edges", []):
			if bool((e as Dictionary).get("check", false)):
				story_cb["edge"].call(idx)
				return
			idx += 1

## 捏合 = 战术格缩放 0.7~1.6（12 §2.1：8×5 全景 ↔ 局部跟随），横屏持续生效。
func _on_gesture_pinch(ratio: float, center: Vector2) -> void:
	if not _in(center_map, center):
		return
	_zoom = clampf(_zoom0 * ratio, 0.7, 1.6)
	grid.pivot_offset = grid.size * 0.5
	grid.scale = Vector2.ONE * _zoom

func _on_gesture_pinch_ended(_ratio: float, _center: Vector2) -> void:
	_zoom0 = _zoom

## 情境教程提示（12 §4 第二层；触发记录写板由 main 负责）。
func show_tutorial_hint(id: String, text: String) -> void:
	tutorial.show_hint(id, text)

# ---------------------------------------------------------------- 绑定与事件订阅（壳唯一输入：事件流 + 只读 getter）

func bind(p_sm: EncounterSM, p_agent: AutoAgent) -> void:
	sm = p_sm
	agent = p_agent
	_stream = sm.stream
	_stream.subscribe(_on_event)
	show_combat_layout() # 故事态 → 战斗态：同一壳内布局切换
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
	_refresh_all()

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
		# 状态反馈（任务书 §3）：toast + 时钟角标，全经事件流驱动
		var toast := StoryVM.toast_text(ev, _pack)
		if toast != "":
			_flash(toast)
		if t == EventTypes.CLOCK_TICK and _board != null:
			_vm["clock"] = _board.get_doom_clock()
			_refresh_story_status()
		return
	match t:
		EventTypes.STATE_ENTERED:
			init_bar.visible = StringName(ev["payload"]["state"]) == EncounterSM.S_COMBAT
		EventTypes.COMBAT_START:
			init_bar.visible = true # 先攻顺序条战斗时展开（09 §4）
		EventTypes.TURN_START:
			if str(ev["payload"].get("side", "")) == "party":
				round_label.text = "第 %d 轮" % int(ev["payload"]["round"])
		EventTypes.BATTLE_ATTACK:
			_tray_roll(ev["payload"])
		EventTypes.COMBAT_END:
			set_auto(false) # 遭遇结束托管自动停止（09 §9.3）
	_refresh_all()

# ---------------------------------------------------------------- 故事态（中央主视野叙事/选项，非战斗态）

## 呈现当前节点：中央主视野叙事文本（04 §③ 中央 60%）、左栏选项列表（与竖屏操作台同源 vm）。
func show_story(vm: Dictionary) -> void:
	_vm = vm
	_story = true
	clock_chip.visible = true
	quest_chip.visible = true
	round_label.visible = false
	auto_button.visible = false
	speed_button.visible = false
	init_bar.visible = false
	grid.visible = false
	story_panel.visible = true
	story_title.text = str(vm["title"])
	story_text.text = str(vm["text"])
	wheel_title.text = TextsZh.TAB_ACTION
	_refresh_story_status()
	_refresh_story_options()

## 战斗布局恢复（bind 进入遭遇时调用）。
func show_combat_layout() -> void:
	_story = false
	story_panel.visible = false
	grid.visible = true
	clock_chip.visible = false
	quest_chip.visible = false
	round_label.visible = true
	auto_button.visible = true
	speed_button.visible = true
	wheel_title.text = TextsZh.ZONE_WHEEL

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

## 左栏选项列表：与竖屏操作台同一 vm.edges（godot-dev §7 禁止复制过滤逻辑）。
func _refresh_story_options() -> void:
	for child: Node in wheel_box.get_children():
		child.queue_free()
	wheel_actor.text = ""
	var idx := 0
	for e: Variant in _vm.get("edges", []):
		var b := Button.new()
		b.text = str((e as Dictionary)["label"])
		var i := idx
		b.pressed.connect(func() -> void:
			if story_cb.has("edge"):
				story_cb["edge"].call(i))
		wheel_box.add_child(b)
		idx += 1
	if str(_vm.get("type", "")) == "hub": # hub 三设施（战役书 §4 N1-1）
		_add_story_chip(TextsZh.HUB_SHOP, func() -> void: hub_popup.open(
			int(_vm.get("gold", 0)), _vm.get("stock", [])))
		_add_story_chip(TextsZh.HUB_REST, func() -> void:
			if story_cb.has("hub"):
				story_cb["hub"].call("rest", ""))
		_add_story_chip(TextsZh.HUB_RUMOR, func() -> void:
			if story_cb.has("hub"):
				story_cb["hub"].call("rumor", ""))

func _add_story_chip(label: String, on_press: Callable) -> void:
	var b := Button.new()
	b.text = label
	b.pressed.connect(on_press)
	wheel_box.add_child(b)

## 购买/休整后由 main 同步弹层货单与金币。
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

func _flash(text: String) -> void:
	flash_label.text = text
	flash_label.modulate = Color(1, 1, 1, 1)
	var tw := create_tween()
	tw.tween_property(flash_label, "modulate:a", 0.0, 1.6)

## 测试探针：当前故事选项按钮文案。
func story_option_texts() -> Array:
	var out: Array = []
	for child: Node in wheel_box.get_children():
		if child is Button:
			out.append((child as Button).text)
	return out

# ---------------------------------------------------------------- 行动轮盘（左栏，与竖屏快捷栏同一指令集）

func _refresh_wheel() -> void:
	for child: Node in wheel_box.get_children():
		child.queue_free()
	if sm == null:
		return
	var actions := sm.get_available_actions() # 09 §9.2：内容 = 情境实时过滤，core 单源
	if actions.is_empty():
		wheel_actor.text = ""
		return
	wheel_actor.text = "【%s】" % str(sm.get_unit(sm.current_actor_id())["name"])
	for a: Dictionary in actions:
		var b := Button.new()
		b.text = TextsZh.action_label(a)
		b.disabled = bool(a["disabled"])
		b.set_meta("action", a) # 芯片拖动 = 指定目标使用（12 §3.6）
		var action := a
		b.pressed.connect(func() -> void: press_action(action))
		wheel_box.add_child(b)

## 轮盘点按（09 §9.2 点按=默认目标；enemy 目标优先用格地图点选，12 §1）。
func press_action(action: Dictionary) -> void:
	if sm == null:
		return
	var target := ""
	if str(action.get("target_kind", "")) == "enemy":
		if _selected_target != "":
			var t := sm.get_unit(_selected_target)
			if not t.is_empty() and not bool(t["dead"]):
				target = _selected_target
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

## 手操命令：先接管托管（09 §9.3 一键接管即时生效），再走统一 Command 通道；返回 core 是否受理。
func _manual(cmd: Dictionary) -> bool:
	if cmd.is_empty():
		return false
	if auto_on:
		set_auto(false) # 一键接管即时生效（09 §9.3）
	if sm != null:
		return sm.submit_command(cmd)
	return false

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

# ---------------------------------------------------------------- 掷骰演出（09 §6 两级，与竖屏同一事件源）

## 普通：骰子盘就地快掷（≤0.5s 出结果）。
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
	_key_playing = false

## 长按 ≥400ms 跳过（04 §④.7：一切演出可跳过（长按），防误触；12 §1 长按判定参数）。
func _on_key_overlay_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if (event as InputEventMouseButton).pressed:
			key_hold_timer.start()
		elif not key_hold_timer.is_stopped():
			key_hold_timer.stop()
	elif event is InputEventScreenTouch:
		if (event as InputEventScreenTouch).pressed:
			key_hold_timer.start()
		elif not key_hold_timer.is_stopped():
			key_hold_timer.stop()

# ---------------------------------------------------------------- 日志带（下缘 5%，点击展开半屏）

func toggle_log() -> void:
	log_expanded = not log_expanded
	if log_expanded:
		_set_rect(log_band, 0.0, LOG_EXPANDED_TOP, 1.0, 1.0) # 09 §4：展开至半屏
		log_full.visible = true
		log_full.text = "\n".join(_log_lines)
		log_toggle.text = TextsZh.LOG_COLLAPSE
	else:
		_set_rect(log_band, 0.0, 1.0 - RATIO_BOTTOM, 1.0, 1.0)
		log_full.visible = false
		log_toggle.text = TextsZh.LOG_EXPAND

func _log_line(text: String) -> void:
	if text == "":
		return
	_log_lines.append(text)
	log_last.text = text
	if log_expanded:
		log_full.append_text(text + "\n")

# ---------------------------------------------------------------- 刷新（事件流 → UI 更新链路）

func _refresh_all() -> void:
	if _story:
		return # 故事态由 show_story/_refresh_story_status 驱动
	if sm == null:
		return
	_refresh_top()
	_refresh_grid()
	_refresh_wheel()

func _refresh_top() -> void:
	for child: Node in party_chips.get_children():
		child.queue_free()
	for child: Node in init_bar.get_children():
		child.queue_free()
	if sm == null:
		return
	var current := sm.current_actor_id()
	for id: String in sm.get_order():
		var u := sm.get_unit(id)
		if u["side"] == &"party":
			var chip := Label.new()
			chip.text = " %s %d/%d " % [u["name"], int(u["hp"]), int(u["max_hp"])]
			if bool(u["dead"]):
				chip.modulate = Color(0.4, 0.4, 0.4)
			elif bool(u["downed"]):
				chip.modulate = Color(1.0, 0.5, 0.4)
			party_chips.add_child(chip)
		var tag := Label.new() # 先攻顺序条：按先攻序排列，敌红我金，当前行动单位高亮
		tag.text = str(u["name"])
		tag.add_theme_color_override("font_color",
			COLOR_ENEMY if u["side"] == &"enemy" else COLOR_PARTY)
		if id == current:
			tag.text = "▶" + tag.text
		init_bar.add_child(tag)

# ---------------------------------------------------------------- 测试探针与小部件

## 五区实际像素占比（冻结指标断言用）。
func get_zone_ratios() -> Dictionary:
	var w := maxf(size.x, 1.0)
	var h := maxf(size.y, 1.0)
	return {"top": top_band.size.y / h, "bottom": log_band.size.y / h,
		"left": left_wheel.size.x / w, "center": center_map.size.x / w,
		"right": right_dice.size.x / w}

func _unit_name(id: String) -> String:
	if sm == null:
		return id
	return str(sm.get_unit(id).get("name", id))
