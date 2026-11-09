# ⑥ 背包与图鉴（docs/framework/04-UI-UX设计文档.md §⑥；tech/02 §7 items.json 四重身份；
# docs/framework/10-道具与图鉴规范.md §1 标签体系 / §3 系列归世界观 / §4 集齐奖励白名单）
# - 背包页：四重身份筛选（数值装备/检定工具/分支钥匙/图鉴信物）+ 详情弹层
#   （属性 / 检定修正 / 分支提示「它似乎能在某处派上用场」，04 §⑥）；
# - 图鉴页：四系列收集进度（worldview §9）、已解锁 Lore 条目、集齐奖励预告（10 §4：永不卖数值）；
# - 只读视图：数据全部来自 Board.get_inv()/get_lore() 与 pack 表，本屏不写板（godot-dev §2）。
class_name ScreenInventory
extends Control

signal back_requested
signal equip_requested(skin_id: String)     # 外观页装备（写板走 main → Cosmetics，06 §3）
signal unequip_requested                    # 外观页卸下（回落默认皮）
signal skin_purchase_requested(skin_id: String) # 商店外观商品购买确认（半屏弹层，06 §6）

const ROLE_ORDER: Array[String] = ["stat", "check_mod", "branch_key", "codex"] # 10 §1 四重身份

var filter_row: HBoxContainer
var bag_box: VBoxContainer
var codex_box: VBoxContainer
var cos_box: VBoxContainer
var back_button: Button
var info_popup: InfoPopup
var skin_popup: ShopPopup # 外观商品购买半屏弹层（复用 ShopPopup，06 §6）

var _inv: Dictionary = {}
var _items: Dictionary = {}
var _lore_ids: Array = []
var _lore_defs: Array = []
var _texts: Dictionary = {} # pack.texts（tech/02 §1.1：图鉴正文 text_ref 外置解析）
var _filter := "" # "" = 全部
var _skins: Array = []        # 注册表皮肤定义（数据驱动，06 §7）
var _skins_owned: Array = []  # 已持有 skin_id
var _skin_equipped := ""      # 当前装备 skin_id

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
	# 外观页（06 §3/§6：外观商品挂在 ⑥ 背包图鉴外观页，不新增全局导航）
	var cos_head := Label.new()
	cos_head.text = "【%s】" % TextsZh.INV_COSMETIC
	cos_box = VBoxContainer.new()
	cos_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cos_box.add_child(cos_head)
	var cos_note := Label.new()
	cos_note.text = TextsZh.COSMETIC_PURE_NOTE
	cos_note.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	cos_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cos_box.add_child(cos_note)
	cols.add_child(cos_box)
	back_button = Button.new()
	back_button.text = TextsZh.COMMON_BACK
	back_button.pressed.connect(func() -> void: back_requested.emit())
	v.add_child(back_button)
	info_popup = InfoPopup.new()
	add_child(info_popup)
	skin_popup = ShopPopup.new()
	add_child(skin_popup)
	skin_popup.purchase_confirmed.connect(func(skin_id: String) -> void:
		skin_purchase_requested.emit(skin_id)) # 确认 → main 落板；本屏不写板（godot-dev §2）

func _add_filter(label: String, role: String) -> void:
	var b := Button.new()
	b.text = label
	b.pressed.connect(func() -> void:
		_filter = role
		_render_bag())
	filter_row.add_child(b)

## 绑定只读数据：inv = Board.get_inv()；items_table = pack.items；lore_ids = Board.get_lore()；
## lore_defs = pack.lore（lore.json：系列归属声明，10 §3）；texts = pack.texts（tech/02 §1.1 图鉴正文）。
func bind(inv: Dictionary, items_table: Dictionary, lore_ids: Array, lore_defs: Array = [],
		texts: Dictionary = {}) -> void:
	_inv = inv
	_items = items_table
	_lore_ids = lore_ids
	_lore_defs = lore_defs
	_texts = texts
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
		if _lore_ids.has(lid):
			# 已解锁条目 = 按钮等价路径（12 §1），点按弹正文（tech/02 §10 text_ref 外置，§1.1 解析）
			var b := Button.new()
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.text = "📜 %s（%s）" % [str(d.get("title", lid)), str(d.get("source", ""))]
			b.pressed.connect(func() -> void: show_lore_detail(lid))
			codex_box.add_child(b)
		else:
			var l2 := Label.new()
			l2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l2.text = "📜 %s" % TextsZh.CODEX_LOCKED_TITLE
			l2.modulate = Color(0.5, 0.5, 0.55)
			codex_box.add_child(l2)

## 图鉴条目详情：标题 + 来源 + text_ref 正文（tech/02 §1.1：键缺失即空串，仅显标题/来源）。
func show_lore_detail(lore_id: String) -> void:
	for e: Variant in _lore_defs:
		var d: Dictionary = e
		if str(d.get("id", "")) != lore_id:
			continue
		var lines: Array = ["来源：%s" % str(d.get("source", ""))]
		var body := StoryVM.lore_text(_texts, d)
		if body != "":
			lines.append(body)
		info_popup.show_info(str(d.get("title", lore_id)), lines)
		return

## 测试探针：当前筛选与背包条目数。
func filter_state() -> String:
	return _filter

func bag_entry_count() -> int:
	var n := 0
	for child: Node in bag_box.get_children():
		if child is Button:
			n += 1
	return n

# ---------------------------------------------------------------- 外观页（06 §3/§6/§7；10 §4 集齐奖励）

## 绑定外观页只读数据：skins = 注册表定义；owned = 已持有 id；equipped = 当前装备 id。
func bind_cosmetics(skins: Array, owned: Array, equipped: String) -> void:
	_skins = skins
	_skins_owned = owned
	_skin_equipped = equipped
	_render_cosmetics()

## 外观页：皮肤列表（预览色块 + 名称 + 获得途径 + 装备/卸下/获取；未获得灰显，06 §3.1 可见但锁定同手法）。
func _render_cosmetics() -> void:
	for child: Node in cos_box.get_children():
		if child is HBoxContainer:
			child.queue_free()
	for e: Variant in _skins:
		var def: Dictionary = e
		var skin_id := str(def.get("id", ""))
		var owned := _skins_owned.has(skin_id)
		var pal: Dictionary = def.get("palette", {})
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		# 预览色块：骰面主色 + 描边（注册表调色板直渲，纯呈现）
		var swatch := PanelContainer.new()
		swatch.custom_minimum_size = Vector2(28, 28)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(str(pal.get("face", "#e8c76a")))
		sb.border_color = Color(str(pal.get("edge", "#6b4f16")))
		sb.set_border_width_all(3)
		sb.set_corner_radius_all(4)
		swatch.add_theme_stylebox_override("panel", sb)
		row.add_child(swatch)
		var text_v := VBoxContainer.new()
		text_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_l := Label.new()
		name_l.text = str(def.get("name", skin_id))
		text_v.add_child(name_l)
		var src_l := Label.new()
		src_l.text = TextsZh.cosmetic_source_line(def)
		src_l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		text_v.add_child(src_l)
		row.add_child(text_v)
		var btn := Button.new()
		if owned and skin_id == _skin_equipped:
			btn.text = TextsZh.COSMETIC_UNEQUIP
			btn.pressed.connect(func() -> void: unequip_requested.emit())
		elif owned:
			btn.text = TextsZh.COSMETIC_EQUIP
			var sid := skin_id
			btn.pressed.connect(func() -> void: equip_requested.emit(sid))
		elif str((def.get("grant", {}) as Dictionary).get("kind", "")) == "shop":
			var price := str((def.get("shop", {}) as Dictionary).get("price_text", ""))
			btn.text = "%s %s" % [TextsZh.LOCK_ACQUIRE, price]
			var sid2 := skin_id
			btn.pressed.connect(func() -> void:
				skin_popup.open(sid2, str(def.get("name", sid2)), price,
					TextsZh.cosmetic_shop_line(str(def.get("name", sid2)), price)))
		else:
			btn.text = TextsZh.COSMETIC_NOT_OWNED
			btn.disabled = true # 未获得灰显（非卖途径：呈现获得条件，不出购买入口）
		row.add_child(btn)
		if not owned:
			row.modulate = Color(0.55, 0.55, 0.6) # 未获得整行灰显
		cos_box.add_child(row)

## 测试探针：外观页条目数与指定皮肤按钮文案。
func cosmetic_entry_count() -> int:
	var n := 0
	for child: Node in cos_box.get_children():
		if child is HBoxContainer:
			n += 1
	return n

func cosmetic_button_text(skin_id: String) -> String:
	var idx := 0
	for e: Variant in _skins:
		var child := cos_box.get_child(2 + idx) # 前两子节点 = 栏头 + 纯演出注记
		if str((e as Dictionary).get("id", "")) == skin_id and child is HBoxContainer:
			for c: Node in (child as HBoxContainer).get_children():
				if c is Button:
					return (c as Button).text
		idx += 1
	return ""
