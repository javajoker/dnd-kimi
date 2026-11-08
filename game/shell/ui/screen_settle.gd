# ⑨ 结算界面（docs/framework/04-UI-UX设计文档.md §⑨；07 §4.2 结算完成主快照点；09 §7 结算态正常离场）
# - 写板汇总逐项念给玩家听：经验 / 战利品 / 旗标 / 声望 / 时钟；
# - 成长加点（属性点，可留到下次整备）；存档快照由 main 在显示前完成（07 §4.2）；
# - 出口：回主屏 / 查看⑧历史卷轴新增条目（04 §⑨）。
class_name ScreenSettle
extends Control

signal allocate(attr: String)
signal go_home
signal go_history

var summary_text: RichTextLabel
var saved_label: Label
var attr_label: Label
var attr_box: HBoxContainer
var keep_label: Label
var home_button: Button
var history_button: Button

func _ready() -> void:
	_build()
	size = get_viewport().get_visible_rect().size # 根 Control 父级为纯 Node：显式落视口尺寸（锚定无参照）

func _build() -> void:
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
	saved_label = Label.new()
	saved_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	saved_label.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6))
	v.add_child(saved_label)
	attr_label = Label.new()
	attr_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(attr_label)
	attr_box = HBoxContainer.new()
	attr_box.alignment = BoxContainer.ALIGNMENT_CENTER
	attr_box.add_theme_constant_override("separation", 8)
	v.add_child(attr_box)
	keep_label = Label.new()
	keep_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	keep_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	v.add_child(keep_label)
	home_button = Button.new()
	home_button.text = TextsZh.SETTLE_HOME
	home_button.pressed.connect(func() -> void: go_home.emit())
	v.add_child(home_button)
	history_button = Button.new()
	history_button.text = TextsZh.SETTLE_HISTORY
	history_button.pressed.connect(func() -> void: go_history.emit())
	v.add_child(history_button)

## summary = {title, result, lines[], saved, attr_points, attrs{}}。
func bind(summary: Dictionary) -> void:
	var result_name: String = {"victory": TextsZh.SETTLE_VICTORY, "defeat": TextsZh.SETTLE_DEFEAT,
		"retreat": TextsZh.SETTLE_RETREAT}.get(str(summary.get("result", "")), str(summary.get("result", "")))
	var lines: Array[String] = ["【%s】%s —— %s" % [TextsZh.SETTLE_TITLE,
		str(summary.get("title", "")), result_name], ""]
	lines.append_array(summary.get("lines", []))
	summary_text.text = "\n".join(lines)
	saved_label.text = TextsZh.SETTLE_SAVED if bool(summary.get("saved", false)) else ""
	_refresh_attrs(int(summary.get("attr_points", 0)), summary.get("attrs", {}))

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
