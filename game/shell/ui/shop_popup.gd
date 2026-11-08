# 商店购买半屏弹层（06 文档 §6：购买流程以半屏弹层完成，不离开当前界面情境；04 §3.3 半屏弹层规范）
# 壳组件：只呈现商品名/价格/叙事化文案并转发确认信号；点亮写板由 main → Entitlements.shop_purchase
# 完成（core 通道，Board system 写权限 + 单号溯源，06 §2.3）。弹层内不出现"未购买"系统腔（06 §3.1）。
class_name ShopPopup
extends Control

signal purchase_confirmed(pack_id: String)

var goods_label: Label
var line_label: Label
var confirm_button: Button
var cancel_button: Button
var _pack_id := ""

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
	# 半屏弹层：下 50%（04 §3.3）
	panel.anchor_left = 0.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.5
	panel.anchor_bottom = 1.0
	add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	var title := Label.new()
	title.text = TextsZh.SHOP_TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	v.add_child(title)
	goods_label = Label.new()
	goods_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(goods_label)
	line_label = Label.new()
	line_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	line_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line_label.add_theme_color_override("font_color", Color(0.75, 0.72, 0.66))
	v.add_child(line_label)
	confirm_button = Button.new()
	confirm_button.text = TextsZh.SHOP_CONFIRM
	confirm_button.custom_minimum_size = Vector2(0, 44)
	confirm_button.pressed.connect(func() -> void:
		hide()
		purchase_confirmed.emit(_pack_id))
	v.add_child(confirm_button)
	cancel_button = Button.new()
	cancel_button.text = TextsZh.SHOP_CANCEL
	cancel_button.pressed.connect(hide)
	v.add_child(cancel_button)
	hide()

## 打开弹层（数据来自运营配置价格表，06 §3.2：定价是运营侧数据）。
func open(pack_id: String, pack_name: String, price_text: String) -> void:
	_pack_id = pack_id
	goods_label.text = "%s · %s" % [pack_name, price_text]
	line_label.text = TextsZh.shop_line(pack_name, price_text)
	visible = true
