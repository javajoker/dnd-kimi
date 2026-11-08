# Hub 商店半屏弹层（04 §3.3；战役书 §4 N1-1：商店/休整）。双壳共用同一组件：
# 壳只负责弹出与本组件的信号转发；购买/休整的写板全部在 core（StoryGraph.hub_buy/hub_rest）。
class_name HubPopup
extends Control

signal buy_requested(item_id: String)
signal rest_requested

var gold_label: Label
var stock_box: VBoxContainer
var rest_button: Button
var close_button: Button

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			hide())
	add_child(dim)
	var panel := PanelContainer.new()
	# 半屏弹层：下 50%（04 §3.3 半屏弹层）
	panel.anchor_left = 0.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.5
	panel.anchor_bottom = 1.0
	add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	var title := Label.new()
	title.text = TextsZh.HUB_SHOP
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	v.add_child(title)
	gold_label = Label.new()
	gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(gold_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	stock_box = VBoxContainer.new()
	stock_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stock_box.add_theme_constant_override("separation", 4)
	scroll.add_child(stock_box)
	rest_button = Button.new()
	rest_button.text = "%s（%s）" % [TextsZh.HUB_REST, TextsZh.HUB_REST_HINT]
	rest_button.pressed.connect(func() -> void: rest_requested.emit())
	v.add_child(rest_button)
	close_button = Button.new()
	close_button.text = TextsZh.HUB_CLOSE
	close_button.pressed.connect(hide)
	v.add_child(close_button)
	hide()

## 填充货单与金币（数据来自 StoryVM.build 的 vm.stock / vm.gold）。
func bind(gold: int, stock: Array) -> void:
	gold_label.text = TextsZh.HUB_GOLD % gold
	for child: Node in stock_box.get_children():
		child.queue_free()
	for item: Variant in stock:
		var it: Dictionary = item
		var b := Button.new()
		b.text = "%s —— %d 金币%s" % [str(it.get("name", "")), int(it.get("price", 0)),
			"（持有 ×%d）" % int(it["owned"]) if int(it.get("owned", 0)) > 0 else ""]
		b.disabled = not bool(it.get("affordable", false))
		if b.disabled:
			b.text += "（%s）" % TextsZh.HUB_NO_GOLD.trim_suffix("。")
		var iid := str(it.get("id", ""))
		b.pressed.connect(func() -> void: buy_requested.emit(iid))
		stock_box.add_child(b)

func open(gold: int, stock: Array) -> void:
	bind(gold, stock)
	visible = true
