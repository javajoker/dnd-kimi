# ⑨ 结算界面（docs/framework/04-UI-UX设计文档.md §⑨；07 §4.2 结算完成主快照点；09 §7 结算态正常离场）
# - 写板汇总逐项念给玩家听：经验 / 战利品 / 旗标 / 声望 / 时钟；
# - 成长加点（属性点，可留到下次整备）；存档快照由 main 在显示前完成（07 §4.2）；
# - 出口：下一遭遇（胜利后沿故事图边推进，summary.has_next 控制显隐）/ 回主屏 / 查看⑧历史卷轴（04 §⑨）；
#   胜利必经结算（04 §⑨：单局的句点，元循环的落笔处）。
# - 形态感知双布局（04 §④.8 横屏专版）：竖屏维持居中纵列；
#   横屏双区——左侧逐项念板列表（逐条入场动画），右侧成长加点区与出口按钮；
#   胜利演出横铺中央后收拢到结算布局。两形态同数据同操作路径（bind/信号完全一致）。
class_name ScreenSettle
extends Control

signal allocate(attr: String)
signal go_home
signal go_history
signal go_next

var form: StringName = ShellRouter.MODE_TIME # 战役形态（09 §8；04 §④.8）：time=竖屏居中，space=横屏双区

var summary_text: RichTextLabel # 汇总全文（竖屏呈现；横屏作数据探针，不进布局）
var saved_label: Label
var attr_label: Label
var attr_box: HBoxContainer
var keep_label: Label
var next_button: Button # 下一遭遇（仅胜利结算显示，04 §⑨）
var home_button: Button
var history_button: Button

# 横屏专版容器（04 §④.8；竖屏形态恒为 null，作布局形态探针）
var readout_zone: VBoxContainer # 左：逐项念板列表
var lines_box: VBoxContainer    # 念板条目（逐条入场动画）
var side_zone: VBoxContainer    # 右：成长加点区与出口
var victory_banner: Label       # 胜利演出（横铺中央 → 收拢）

var _built := false

## 设定呈现形态（main 依战役形态注入，09 §8）；已建布局则重建（数据由随后的 bind 落）。
func set_form(mode: StringName) -> void:
	form = mode
	if _built:
		_rebuild()

func _ready() -> void:
	_build()
	_built = true
	size = get_viewport().get_visible_rect().size # 根 Control 父级为纯 Node：显式落视口尺寸（锚定无参照）

func _rebuild() -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	readout_zone = null
	lines_box = null
	side_zone = null
	victory_banner = null
	_build()

func _build() -> void:
	if form == ShellRouter.MODE_SPACE:
		_build_landscape()
	else:
		_build_portrait()

func _make_common_widgets() -> void:
	# 两形态共用控件：同实例挂不同父容器（数据/信号路径唯一，不复制逻辑）
	saved_label = Label.new()
	saved_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	saved_label.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6))
	attr_label = Label.new()
	attr_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	attr_box = HBoxContainer.new()
	attr_box.alignment = BoxContainer.ALIGNMENT_CENTER
	attr_box.add_theme_constant_override("separation", 8)
	keep_label = Label.new()
	keep_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	keep_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	next_button = Button.new()
	next_button.text = TextsZh.SETTLE_NEXT
	next_button.visible = false # 仅胜利结算显示（bind 按 summary.has_next 控制）
	next_button.pressed.connect(func() -> void: go_next.emit())
	home_button = Button.new()
	home_button.text = TextsZh.SETTLE_HOME
	home_button.pressed.connect(func() -> void: go_home.emit())
	history_button = Button.new()
	history_button.text = TextsZh.SETTLE_HISTORY
	history_button.pressed.connect(func() -> void: go_history.emit())

## 竖屏：居中纵列（§④.8：竖屏布局不变）。
func _build_portrait() -> void:
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	summary_text = RichTextLabel.new()
	summary_text.bbcode_enabled = false
	summary_text.fit_content = true
	summary_text.custom_minimum_size = Vector2(340, 0)
	v.add_child(summary_text)
	_make_common_widgets()
	v.add_child(saved_label)
	v.add_child(attr_label)
	v.add_child(attr_box)
	v.add_child(keep_label)
	v.add_child(next_button)
	v.add_child(home_button)
	v.add_child(history_button)

## 横屏专版（04 §④.8）：左逐项念板列表（逐条入场）+ 右成长加点区与出口；胜利演出横铺中央。
func _build_landscape() -> void:
	var h := HBoxContainer.new()
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	h.add_theme_constant_override("separation", 24)
	add_child(h)
	# 左区：逐项念板列表
	readout_zone = VBoxContainer.new()
	readout_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	readout_zone.size_flags_stretch_ratio = 3.0
	readout_zone.add_theme_constant_override("separation", 8)
	h.add_child(readout_zone)
	lines_box = VBoxContainer.new()
	lines_box.add_theme_constant_override("separation", 6)
	readout_zone.add_child(lines_box)
	summary_text = RichTextLabel.new() # 数据探针（横屏不进布局；全文与竖屏同口径）
	summary_text.bbcode_enabled = false
	summary_text.visible = false
	add_child(summary_text)
	# 右区：成长加点区与出口按钮
	side_zone = VBoxContainer.new()
	side_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_zone.size_flags_stretch_ratio = 2.0
	side_zone.add_theme_constant_override("separation", 8)
	h.add_child(side_zone)
	_make_common_widgets()
	side_zone.add_child(saved_label)
	side_zone.add_child(attr_label)
	side_zone.add_child(attr_box)
	side_zone.add_child(keep_label)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_zone.add_child(spacer)
	next_button.custom_minimum_size = Vector2(200, 56)
	side_zone.add_child(next_button)
	home_button.custom_minimum_size = Vector2(200, 56)
	side_zone.add_child(home_button)
	history_button.custom_minimum_size = Vector2(200, 56)
	side_zone.add_child(history_button)
	# 胜利演出：横铺中央后收拢（04 §④.8）；覆盖层不吞输入
	victory_banner = Label.new()
	victory_banner.text = TextsZh.SETTLE_VICTORY
	victory_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	victory_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	victory_banner.add_theme_font_size_override("font_size", 72)
	victory_banner.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	victory_banner.set_anchors_preset(Control.PRESET_FULL_RECT)
	victory_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	victory_banner.visible = false
	add_child(victory_banner)

## summary = {title, result, lines[], saved, attr_points, attrs{}, has_next?, celebrate?}。
func bind(summary: Dictionary) -> void:
	next_button.visible = bool(summary.get("has_next", false)) # 下一遭遇出口：仅胜利结算（04 §⑨）
	var result_name: String = {"victory": TextsZh.SETTLE_VICTORY, "defeat": TextsZh.SETTLE_DEFEAT,
		"retreat": TextsZh.SETTLE_RETREAT, "slice": TextsZh.SETTLE_SLICE}.get(
			str(summary.get("result", "")), str(summary.get("result", "")))
	var lines: Array[String] = ["【%s】%s —— %s" % [TextsZh.SETTLE_TITLE,
		str(summary.get("title", "")), result_name], ""]
	lines.append_array(summary.get("lines", []))
	summary_text.text = "\n".join(lines)
	saved_label.text = TextsZh.SETTLE_SAVED if bool(summary.get("saved", false)) else ""
	_refresh_attrs(int(summary.get("attr_points", 0)), summary.get("attrs", {}))
	if form == ShellRouter.MODE_SPACE:
		_render_landscape_lines(lines)
		# 胜利演出横铺中央后收拢（04 §④.8；celebrate=false = 同场重绑不重播，如加点刷新）
		if str(summary.get("result", "")) == "victory" and bool(summary.get("celebrate", true)):
			_play_victory_banner()

## 横屏逐项念板：每条一行，逐条淡入入场（04 §④.8）。
func _render_landscape_lines(lines: Array[String]) -> void:
	if lines_box == null:
		return
	for child: Node in lines_box.get_children():
		child.queue_free()
	var i := 0
	for ln: String in lines:
		if ln.is_empty():
			continue
		var l := Label.new()
		l.text = ln
		if i == 0:
			l.add_theme_font_size_override("font_size", 24) # 标题行
		l.modulate.a = 0.0
		lines_box.add_child(l)
		var tw := create_tween()
		tw.tween_interval(0.08 * i)
		tw.tween_property(l, "modulate:a", 1.0, 0.25)
		i += 1

## 胜利演出（04 §④.8：横铺中央 → 收拢到结算布局）。总时长约 1.4s，纯呈现不写板。
func _play_victory_banner() -> void:
	if victory_banner == null:
		return
	victory_banner.pivot_offset = victory_banner.size / 2.0
	victory_banner.scale = Vector2(2.4, 2.4) # 横铺中央
	victory_banner.modulate.a = 0.0
	victory_banner.visible = true
	var tw := create_tween()
	tw.tween_property(victory_banner, "modulate:a", 1.0, 0.2)
	tw.parallel().tween_property(victory_banner, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK)
	tw.tween_interval(0.5)
	tw.tween_property(victory_banner, "scale", Vector2(0.4, 0.4), 0.3) # 收拢
	tw.parallel().tween_property(victory_banner, "modulate:a", 0.0, 0.3)
	tw.tween_callback(func() -> void: victory_banner.visible = false)

func _refresh_attrs(points: int, attrs: Dictionary) -> void:
	for child: Node in attr_box.get_children():
		child.queue_free()
	# 仅在有点数时显示加点区（11 §6：属性点可在结算或整备时分配；无点不占地）
	attr_label.visible = points > 0
	attr_box.visible = points > 0
	keep_label.visible = points > 0
	attr_label.text = "%s（可用 %d）" % [TextsZh.SETTLE_ATTR_TITLE, points]
	var names := {"might": "力", "finesse": "敏", "wits": "智"}
	for attr: String in ["might", "finesse", "wits"]:
		var b := Button.new()
		b.text = "%s %+d +" % [str(names[attr]), int(attrs.get(attr, 0))]
		b.disabled = points <= 0 or int(attrs.get(attr, 0)) >= LightV1.ATTR_POINT_CAP # 单项 +3 封顶（11 §6）
		b.pressed.connect(func() -> void: allocate.emit(attr))
		attr_box.add_child(b)
	keep_label.text = TextsZh.SETTLE_ATTR_KEEP if points > 0 else ""

## 布局形态探针（04 §④.8：横屏双区）。
func is_landscape_layout() -> bool:
	return readout_zone != null
