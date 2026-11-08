# ⑤ 事件中心（docs/framework/04-UI-UX设计文档.md §⑤；tech/02 §5 events.json L3 实例清单）
# 最小版：进行中事件只读列表（名称 / 目标 / 状态）；已完结归档提示；放弃/跳转随内容接入补全。
class_name ScreenQuests
extends Control

signal back_requested

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
	var wip := Label.new()
	wip.text = "（事件放弃 / 战役跳转 %s）" % TextsZh.COMMON_WIP
	wip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wip.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	v.add_child(wip)
	back_button = Button.new()
	back_button.text = TextsZh.COMMON_BACK
	back_button.pressed.connect(func() -> void: back_requested.emit())
	v.add_child(back_button)

## quests = StoryGraph.quests()：[{id,name,objective,node,state}]。
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
		var state_name: String = TextsZh.QUESTS_ACTIVE if str(d["state"]) == "triggered" else TextsZh.QUESTS_DONE
		var l := Label.new()
		l.text = "◆ %s —— %s\n　%s（%s）" % [str(d["name"]), state_name, str(d["objective"]), str(d["node"])]
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list_box.add_child(l)
