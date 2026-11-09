# ⑥ 背包与图鉴（docs/framework/04-UI-UX设计文档.md §⑥；tech/02 §7 items.json 四重身份；
# docs/framework/10-道具与图鉴规范.md §1 标签体系 / §3 系列归世界观 / §4 集齐奖励白名单）
# - 背包页：四重身份筛选（数值装备/检定工具/分支钥匙/图鉴信物）+ 详情弹层
#   （属性 / 检定修正 / 分支提示「它似乎能在某处派上用场」，04 §⑥）；
# - 图鉴页：四系列收集进度（worldview §9）、已解锁 Lore 条目、集齐奖励预告（10 §4：永不卖数值）；
# - 只读视图：数据全部来自 Board.get_inv()/get_lore() 与 pack 表，本屏不写板（godot-dev §2）。
class_name ScreenInventory
extends Control

signal back_requested

const ROLE_ORDER: Array[String] = ["stat", "check_mod", "branch_key", "codex"] # 10 §1 四重身份

var filter_row: HBoxContainer
var bag_box: VBoxContainer
var codex_box: VBoxContainer
var back_button: Button
var info_popup: InfoPopup

var _inv: Dictionary = {}
var _items: Dictionary = {}
var _lore_ids: Array = []
var _lore_defs: Array = []
var _filter := "" # "" = 全部

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
	# 身份筛选（04 §⑥：按身份筛选；点按 = 按钮等价路径）
	filter_row = HBoxContainer.new()
	filter_row.alignment = BoxContainer.ALIGNMENT_CENTER
	filter_row.add_theme_constant_override("separation", 6)
	v.add_child(filter_row)
	_add_filter(TextsZh.INV_FILTER_ALL, "")
	for r: String in ROLE_ORDER:
		_add_filter(str(TextsZh.INV_ROLE_NAMES[r]), r)
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
	back_button = Button.new()
	back_button.text = TextsZh.COMMON_BACK
	back_button.pressed.connect(func() -> void: back_requested.emit())
	v.add_child(back_button)
	info_popup = InfoPopup.new()
	add_child(info_popup)

func _add_filter(label: String, role: String) -> void:
	var b := Button.new()
	b.text = label
	b.pressed.connect(func() -> void:
		_filter = role
		_render_bag())
	filter_row.add_child(b)

## 绑定只读数据：inv = Board.get_inv()；items_table = pack.items；lore_ids = Board.get_lore()；
## lore_defs = pack.lore（lore.json：系列归属声明，10 §3）。
func bind(inv: Dictionary, items_table: Dictionary, lore_ids: Array, lore_defs: Array = []) -> void:
	_inv = inv
	_items = items_table
	_lore_ids = lore_ids
	_lore_defs = lore_defs
	_render_bag()
	_render_codex()

## 背包页：按身份筛选；点按道具 = 详情弹层（长按等价的按钮路径，12 §1 铁律）。
func _render_bag() -> void:
	for child: Node in bag_box.get_children():
		if child is Button:
			child.queue_free()
	for item_id: String in _inv.keys():
		var def: Dictionary = _items.get(item_id, {})
		var roles: Array = def.get("roles", [])
		if _filter != "" and not roles.has(_filter):
			continue
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "%s ×%d　%s" % [str(def.get("name", item_id)), int(_inv[item_id]),
			"〔%s〕" % "/".join(roles.map(func(r: Variant) -> String:
				return str(TextsZh.INV_ROLE_NAMES.get(str(r), str(r))))) if not roles.is_empty() else ""]
		var iid := item_id
		b.pressed.connect(func() -> void: show_item_detail(iid))
		bag_box.add_child(b)

## 道具详情：属性 / 检定修正 / 分支提示（04 §⑥ 详情弹层）。
func show_item_detail(item_id: String) -> void:
	var def: Dictionary = _items.get(item_id, {})
	var roles: Array = def.get("roles", [])
	var lines: Array[String] = []
	if not roles.is_empty():
		lines.append("身份：%s" % " / ".join(roles.map(func(r: Variant) -> String:
			return str(TextsZh.INV_ROLE_NAMES.get(str(r), str(r))))))
	if def.has("use"):
		var use: Dictionary = def["use"]
		if use.has("heal"):
			lines.append("使用：恢复 %s HP（附赠动作）" % str(use["heal"]))
		if bool(use.get("consume", false)):
			lines.append("消耗品")
	if roles.has("check_mod"):
		lines.append("检定修正：携带即生效（检定工具）")
	if roles.has("branch_key"):
		lines.append(TextsZh.INV_BRANCH_HINT) # 分支提示（04 §⑥ 示例句式）
	if def.has("price"):
		lines.append("价格：%d 金币" % int(def["price"]))
	if lines.is_empty():
		lines.append(str(def.get("name", item_id)))
	info_popup.show_info(str(def.get("name", item_id)), lines)

## 图鉴页：四系列进度 + 集齐奖励预告（10 §4 白名单）+ 已解锁 Lore 条目（lore.json × global.lore）。
func _render_codex() -> void:
	for child: Node in codex_box.get_children():
		if child is Label and (child as Label).text != "【%s】" % TextsZh.INV_CODEX:
			child.queue_free()
	for series_id: String in TextsZh.CODEX_SERIES:
		var total := 0
		var got := 0
		for e: Variant in _lore_defs:
			if str((e as Dictionary).get("series", "")) == series_id:
				total += 1
				if _lore_ids.has(str((e as Dictionary).get("id", ""))):
					got += 1
		var l := Label.new()
		l.text = TextsZh.CODEX_PROGRESS % [str(TextsZh.CODEX_SERIES[series_id]), got, total]
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		codex_box.add_child(l)
		var r := Label.new()
		r.text = TextsZh.CODEX_REWARD_LINE % str(TextsZh.CODEX_REWARDS.get(series_id, ""))
		r.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		codex_box.add_child(r)
	for e: Variant in _lore_defs:
		var d: Dictionary = e
		var lid := str(d.get("id", ""))
		var l2 := Label.new()
		l2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if _lore_ids.has(lid):
			l2.text = "📜 %s（%s）" % [str(d.get("title", lid)), str(d.get("source", ""))]
		else:
			l2.text = "📜 %s" % TextsZh.CODEX_LOCKED_TITLE
			l2.modulate = Color(0.5, 0.5, 0.55)
		codex_box.add_child(l2)

## 测试探针：当前筛选与背包条目数。
func filter_state() -> String:
	return _filter

func bag_entry_count() -> int:
	var n := 0
	for child: Node in bag_box.get_children():
		if child is Button:
			n += 1
	return n
