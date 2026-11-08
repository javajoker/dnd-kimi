# 结局屏（docs/tech/02-内容包格式规范.md §9 结局分型；战役书 §9：N4-3 结局演出 + N4-4 尾声结算
# 合并于 ending 节点，campaign01 README 转写决策）
# - 四分型文案 = endings.json content 字段（壳不再创作，双壳同源 StoryVM 同口径）；
#   多周目钩子 = ngplus_hook 字段呈现（战役书 §9 表）；
# - 出口：「开始二周目」（NG+ 继承：残简 ×1 / 图鉴 / 权利，战役书 §8/§9）/「回主屏」（04 §2 元循环落笔）；
# - 结局快照由 main 在显示前落盘（07 §4.2 主快照点）。
class_name ScreenEnding
extends Control

signal ngplus_requested
signal go_home

var title_label: Label
var playthrough_label: Label
var content_text: RichTextLabel
var hook_label: Label
var saved_label: Label
var ngplus_button: Button
var home_button: Button

func _ready() -> void:
	_build()
	size = get_viewport().get_visible_rect().size # 根 Control 父级为纯 Node：显式落视口尺寸（锚定无参照）

func _build() -> void:
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 10)
	add_child(v)
	title_label = Label.new()
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 28)
	v.add_child(title_label)
	playthrough_label = Label.new()
	playthrough_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	playthrough_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	v.add_child(playthrough_label)
	content_text = RichTextLabel.new()
	content_text.bbcode_enabled = false
	content_text.fit_content = true
	content_text.custom_minimum_size = Vector2(360, 0)
	v.add_child(content_text)
	hook_label = Label.new()
	hook_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hook_label.add_theme_color_override("font_color", Color(0.75, 0.7, 0.5))
	v.add_child(hook_label)
	saved_label = Label.new()
	saved_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	saved_label.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6))
	v.add_child(saved_label)
	ngplus_button = Button.new()
	ngplus_button.text = TextsZh.ENDING_NGPLUS
	ngplus_button.pressed.connect(func() -> void: ngplus_requested.emit())
	v.add_child(ngplus_button)
	home_button = Button.new()
	home_button.text = TextsZh.ENDING_HOME
	home_button.pressed.connect(func() -> void: go_home.emit())
	v.add_child(home_button)

## d = {ending_id, title, content, hook, playthrough, saved}。
func bind(d: Dictionary) -> void:
	title_label.text = TextsZh.ENDING_TITLE % str(d.get("title", ""))
	playthrough_label.text = TextsZh.ENDING_PLAYTHROUGH % int(d.get("playthrough", 1))
	content_text.text = str(d.get("content", ""))
	hook_label.text = TextsZh.ENDING_HOOK % str(d.get("hook", "")) \
		if str(d.get("hook", "")) != "" else ""
	saved_label.text = TextsZh.ENDING_SAVED if bool(d.get("saved", false)) else ""
