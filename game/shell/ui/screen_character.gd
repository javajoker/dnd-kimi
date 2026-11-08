# ⑦ 角色（docs/framework/04-UI-UX设计文档.md §⑦）
# 最小版：队伍角色卡只读列表（属性 / 技能 / 羁绊）；加点配装走整备界面（09 §9.1），
# 法术位 / 装备槽 / 状态效果等要素随内容接入补全。
class_name ScreenCharacter
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
	title.text = TextsZh.CHAR_TITLE
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
	wip.text = "（法术位 / 装备槽 / 状态效果 %s）" % TextsZh.COMMON_WIP
	wip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wip.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	v.add_child(wip)
	back_button = Button.new()
	back_button.text = TextsZh.COMMON_BACK
	back_button.pressed.connect(func() -> void: back_requested.emit())
	v.add_child(back_button)

## party = 角色 def 数组（{id,name,attrs,skills}）；bonds = {npc_id: value}。
func bind(party: Array, bonds: Dictionary) -> void:
	for child: Node in list_box.get_children():
		child.queue_free()
	for u: Variant in party:
		var d: Dictionary = u
		var attrs: Dictionary = d.get("attrs", {})
		var skill_names: Array = (d.get("skills", []) as Array).map(
			func(s: Variant) -> String: return str((s as Dictionary).get("name", "")))
		var l := Label.new()
		l.text = "%s　HP %d/%d　力%+.0f 敏%+.0f 智%+.0f\n　技能：%s" % [
			str(d.get("name", d.get("id", "?"))), int(d.get("hp", 0)), int(d.get("max_hp", 0)),
			float(attrs.get("might", 0)), float(attrs.get("finesse", 0)), float(attrs.get("wits", 0)),
			"、".join(skill_names) if not skill_names.is_empty() else "—"]
		list_box.add_child(l)
	if not bonds.is_empty():
		var head := Label.new()
		head.text = "【%s】" % TextsZh.CHAR_BOND
		list_box.add_child(head)
		for npc: String in bonds.keys():
			var l := Label.new()
			l.text = "%s %d/100" % [npc, int(bonds[npc])]
			list_box.add_child(l)
