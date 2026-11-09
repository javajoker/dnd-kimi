# ⑤ 事件中心（docs/framework/04-UI-UX设计文档.md §⑤；tech/02 §5 events.json L3 实例清单）
# - 进行中事件：名称 / 目标 / 状态；可选事件（choice/hidden 触发）带「放弃」——
#   放弃写旗标 + quest.abandon 事件由 core（StoryGraph.abandon_quest）落，本屏只发信号（壳不写板）；
# - 已完结 / 已放弃自动归档至历史卷轴（04 §⑤：事件流即档案；战役跳转留白）。
class_name ScreenQuests
extends Control

signal back_requested
signal abandon_requested(quest_id: String) # 放弃可选事件（04 §⑤；写板在 core）

var list_box: VBoxContainer
var back_button: Button

func _ready() -> void:
	_build()
	size = get_viewport().get_visible_rect().size # 根 Control 父级为纯 Node：显式落视口尺寸（锚定无参照）

func _build() -> void:
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var title := Label.new()
	title.text = TextsZh.QUESTS_TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	v.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	list_box = VBoxContainer.new()
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_box)
	back_button = Button.new()
	back_button.text = TextsZh.COMMON_BACK
	back_button.pressed.connect(func() -> void: back_requested.emit())
	v.add_child(back_button)

## quests = StoryGraph.quests()：[{id,name,objective,node,state,optional}]。
func bind(quests: Array) -> void:
	for child: Node in list_box.get_children():
		child.queue_free()
	if quests.is_empty():
		var l := Label.new()
		l.text = TextsZh.QUESTS_EMPTY
		list_box.add_child(l)
		return
	for q: Variant in quests:
		var d: Dictionary = q
		var st := str(d["state"])
		var state_name := TextsZh.QUESTS_ACTIVE
		if st == "settled":
			state_name = TextsZh.QUESTS_DONE
		elif st == "abandoned":
			state_name = TextsZh.QUESTS_ABANDONED
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list_box.add_child(row)
		var l := Label.new()
		l.text = "◆ %s —— %s\n　%s（%s）" % [str(d["name"]), state_name, str(d["objective"]), str(d["node"])]
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		if st == "triggered" and bool(d.get("optional", false)):
			# 放弃可选事件（04 §⑤：写旗标 → 归档历史卷轴）
			var b := Button.new()
			b.text = TextsZh.QUESTS_ABANDON
			var qid := str(d["id"])
			b.pressed.connect(func() -> void: abandon_requested.emit(qid))
			row.add_child(b)

## 测试探针：进行中可选事件的放弃按钮数。
func abandon_button_count() -> int:
	var n := 0
	for row: Node in list_box.get_children():
		for child: Node in row.get_children():
			if child is Button and (child as Button).text == TextsZh.QUESTS_ABANDON:
				n += 1
	return n
