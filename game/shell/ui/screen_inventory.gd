# ⑥ 背包与图鉴（docs/framework/04-UI-UX设计文档.md §⑥；tech/02 §7 items.json 四重身份）
# 最小版：背包（global.inv 只读 + 道具表中文名 / 身份标签）与图鉴（global.lore 已解锁条目）两栏；
# 装备 / 筛选 / 详情弹层随内容接入补全。
class_name ScreenInventory
extends Control

signal back_requested

var bag_box: VBoxContainer
var codex_box: VBoxContainer
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
	title.text = TextsZh.INV_TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	v.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	var cols := HBoxContainer.new()
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(cols)
	var bag_head := Label.new()
	bag_head.text = "【%s】" % TextsZh.INV_BAG
	bag_box = VBoxContainer.new()
	bag_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bag_box.add_child(bag_head)
	cols.add_child(bag_box)
	var codex_head := Label.new()
	codex_head.text = "【%s】" % TextsZh.INV_CODEX
	codex_box = VBoxContainer.new()
	codex_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	codex_box.add_child(codex_head)
	cols.add_child(codex_box)
	var wip := Label.new()
	wip.text = "（装备 / 筛选 / 详情弹层 %s）" % TextsZh.COMMON_WIP
	wip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wip.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	v.add_child(wip)
	back_button = Button.new()
	back_button.text = TextsZh.COMMON_BACK
	back_button.pressed.connect(func() -> void: back_requested.emit())
	v.add_child(back_button)

## 绑定只读数据：inv = Board.get_inv()；items_table = pack.items；lore_ids = Board.get_lore()。
func bind(inv: Dictionary, items_table: Dictionary, lore_ids: Array) -> void:
	for child: Node in bag_box.get_children():
		if child is Button:
			child.queue_free()
	for child: Node in codex_box.get_children():
		if child is Label and (child as Label).text != "【%s】" % TextsZh.INV_CODEX:
			child.queue_free()
	for item_id: String in inv.keys():
		var def: Dictionary = items_table.get(item_id, {})
		var l := Label.new()
		var roles: Array = def.get("roles", [])
		l.text = "%s ×%d　%s" % [str(def.get("name", item_id)), int(inv[item_id]),
			"〔%s〕" % "/".join(roles.map(func(r: Variant) -> String: return str(r))) if not roles.is_empty() else ""]
		bag_box.add_child(l)
	for lore_id: Variant in lore_ids:
		var l := Label.new()
		l.text = "📜 %s" % str(lore_id)
		codex_box.add_child(l)
