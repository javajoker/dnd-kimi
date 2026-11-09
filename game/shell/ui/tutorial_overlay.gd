# 教程组件（docs/framework/12-手势与交互规范.md §4：三层结构，可跳过、可重学、跳过不丢信息）
# - 启动卡：首次启动 3 页核心手势卡（全屏，"跳过"常驻，下一页按钮 + 右滑翻页——手势自身即教程内容）；
# - 情境提示：半透明遮罩 + 文案，非模态（mouse_filter=PASS，不阻塞底层操作），点任意处继续；
# - 触发记录写板（global.tutorial.<id>）由 main 流程控制器负责——本组件只发信号（壳不写板，godot-dev §2）；
# - 文本是内容数据（TextsZh 集中），结构由框架恒定（12 §4）。
class_name TutorialOverlay
extends Control

signal launch_finished            # 启动卡看完或跳过
signal hint_dismissed(id: String) # 情境提示被点走

var _dim: ColorRect
var _card_panel: PanelContainer
var _card_label: Label
var _page_label: Label
var _next_button: Button
var _hint_bar: PanelContainer
var _hint_label: Label
var _hint_id := ""
var _page := 0
var _rec := GestureRecognizer.new()

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 半透明遮罩（情境提示用；非模态：PASS，点击穿透底层，12 §4）
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.35)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_PASS
	_dim.visible = false
	add_child(_dim)
	# 启动卡（全屏卡，12 §4 第一层：不透明遮底，专注 3 页核心手势）
	_card_panel = PanelContainer.new()
	_card_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_card_panel.visible = false
	var card_bg := StyleBoxFlat.new()
	card_bg.bg_color = Color(0.06, 0.06, 0.1, 1.0)
	_card_panel.add_theme_stylebox_override("panel", card_bg)
	add_child(_card_panel)
	var cv := VBoxContainer.new()
	cv.alignment = BoxContainer.ALIGNMENT_CENTER
	cv.add_theme_constant_override("separation", 14)
	_card_panel.add_child(cv)
	var title := Label.new()
	title.text = TextsZh.HELP_TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	cv.add_child(title)
	_card_label = Label.new()
	_card_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_label.custom_minimum_size = Vector2(320, 120)
	_card_label.add_theme_font_size_override("font_size", 18)
	cv.add_child(_card_label)
	_page_label = Label.new()
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	cv.add_child(_page_label)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	cv.add_child(row)
	_next_button = Button.new()
	_next_button.text = TextsZh.TUT_NEXT
	_next_button.custom_minimum_size = Vector2(140, 44) # 12 §6 可触目标 ≥44pt
	_next_button.pressed.connect(next_page)
	row.add_child(_next_button)
	var skip := Button.new()
	skip.text = TextsZh.TUT_SKIP # 「跳过」常驻（12 §4）
	skip.custom_minimum_size = Vector2(140, 44)
	skip.pressed.connect(finish_launch)
	row.add_child(skip)
	# 情境提示条（底部半透明显示，高亮目标区由宿主以常态高亮承担——视觉稿阶段留白）
	_hint_bar = PanelContainer.new()
	_hint_bar.anchor_left = 0.05
	_hint_bar.anchor_right = 0.95
	_hint_bar.anchor_top = 0.72
	_hint_bar.anchor_bottom = 0.92
	_hint_bar.mouse_filter = Control.MOUSE_FILTER_PASS
	_hint_bar.visible = false
	add_child(_hint_bar)
	var hv := VBoxContainer.new()
	_hint_bar.add_child(hv)
	_hint_label = Label.new()
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.add_theme_font_size_override("font_size", 16)
	hv.add_child(_hint_label)
	var dismiss := Label.new()
	dismiss.text = TextsZh.TUT_DISMISS
	dismiss.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	dismiss.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	hv.add_child(dismiss)
	# 右滑翻页（启动卡自身即教程内容，12 §4）：识别器只在本组件可见时工作
	_rec.h_swiped.connect(func(dir: int, _pos: Vector2) -> void:
		if _card_panel.visible and dir < 0:
			next_page())

func _input(event: InputEvent) -> void:
	if not visible:
		return
	var now := Time.get_ticks_msec()
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			_rec.press(0, mb.position, now)
		else:
			_rec.release(0, mb.position, now)
			# 情境提示：点任意处继续（12 §4 非模态——不吞事件，底层照常响应）
			if _hint_bar.visible:
				_dismiss_hint()
	elif event is InputEventMouseMotion:
		_rec.move(0, (event as InputEventMouseMotion).position, now)
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_rec.press(st.index, st.position, now)
		else:
			_rec.release(st.index, st.position, now)
			if _hint_bar.visible:
				_dismiss_hint()
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		_rec.move(sd.index, sd.position, now)

# ---------------------------------------------------------------- 启动卡（首次启动 3 页，12 §4 第一层）

func show_launch() -> void:
	_page = 0
	_card_panel.visible = true
	_render_page()

func next_page() -> void:
	if _page + 1 >= TextsZh.TUT_CARDS.size():
		finish_launch()
		return
	_page += 1
	_render_page()

func finish_launch() -> void:
	_card_panel.visible = false
	launch_finished.emit()

func is_launch_visible() -> bool:
	return _card_panel.visible

func _render_page() -> void:
	_card_label.text = TextsZh.TUT_CARDS[_page]
	_page_label.text = "%d / %d" % [_page + 1, TextsZh.TUT_CARDS.size()]
	_next_button.text = TextsZh.TUT_NEXT if _page + 1 < TextsZh.TUT_CARDS.size() else TextsZh.TUT_SKIP

# ---------------------------------------------------------------- 情境提示（首次进入某情境，每类一次，12 §4 第二层）

func show_hint(id: String, text: String) -> void:
	_hint_id = id
	_hint_label.text = text
	_dim.visible = true
	_hint_bar.visible = true

func is_hint_visible() -> bool:
	return _hint_bar.visible

func current_hint() -> String:
	return _hint_id if _hint_bar.visible else ""

func _dismiss_hint() -> void:
	_dim.visible = false
	_hint_bar.visible = false
	var id := _hint_id
	_hint_id = ""
	hint_dismissed.emit(id)
