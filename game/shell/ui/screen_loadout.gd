# 整备界面（docs/framework/09-遭遇与双模式交互规范.md §9.1；tech/02 §2.4 loadout 配置）
# - 战斗遭遇进场前：技能备选 / 道具携带 / 未分配属性点三块，确认后进入进场态；
# - 槽位限制读配置（manifest `loadout`，遭遇级可覆盖）——框架只执行，不硬编码；
# - 确认经 Loadout.confirm 写 `loadout.confirm` 事件（由 main 调用 core，本壳只发信号）。
class_name ScreenLoadout
extends Control

signal confirmed(selection: Dictionary)
signal back_requested

var skill_box: VBoxContainer
var item_box: VBoxContainer
var attr_label: Label
var attr_box: HBoxContainer
var hint_label: Label
var confirm_button: Button
var back_button: Button

var _config: Dictionary = {}
var _skills: Array = []          # 备选 [{id,name,desc}]
var _items: Array = []           # 备选 [{id,name,count}]
var _picked_skills: Array[String] = []
var _picked_items: Array[String] = []
var _attr_points := 0
var _attr_alloc := {"might": 0, "finesse": 0, "wits": 0}
var _attrs_base := {"might": 0, "finesse": 0, "wits": 0} # 板上已分配值（封顶判定，11 §6）

func _ready() -> void:
	_build()
	size = get_viewport().get_visible_rect().size # 根 Control 父级为纯 Node：显式落视口尺寸（锚定无参照）

func _build() -> void:
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	var title := Label.new()
	title.text = TextsZh.LOADOUT_TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	v.add_child(title)
	skill_box = VBoxContainer.new()
	skill_box.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(skill_box)
	item_box = VBoxContainer.new()
	item_box.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(item_box)
	attr_label = Label.new()
	attr_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(attr_label)
	attr_box = HBoxContainer.new()
	attr_box.alignment = BoxContainer.ALIGNMENT_CENTER
	attr_box.add_theme_constant_override("separation", 6)
	v.add_child(attr_box)
	hint_label = Label.new()
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.4))
	v.add_child(hint_label)
	confirm_button = Button.new()
	confirm_button.text = TextsZh.LOADOUT_CONFIRM
	confirm_button.pressed.connect(_on_confirm)
	v.add_child(confirm_button)
	back_button = Button.new()
	back_button.text = TextsZh.COMMON_BACK
	back_button.pressed.connect(func() -> void: back_requested.emit())
	v.add_child(back_button)

## 绑定整备配置与备选数据（candidates = {skills[], items[], attr_points, attr_alloc}）。
func bind(config: Dictionary, candidates: Dictionary) -> void:
	_config = config
	_skills = candidates.get("skills", [])
	_items = candidates.get("items", [])
	_attr_points = int(candidates.get("attr_points", 0))
	_attr_alloc = (candidates.get("attr_alloc", {"might": 0, "finesse": 0, "wits": 0}) as Dictionary).duplicate()
	_attrs_base = (candidates.get("attrs", {"might": 0, "finesse": 0, "wits": 0}) as Dictionary).duplicate()
	_picked_skills.clear()
	_picked_items.clear()
	_refresh()

func _refresh() -> void:
	for child: Node in skill_box.get_children():
		child.queue_free()
	for child: Node in item_box.get_children():
		child.queue_free()
	for child: Node in attr_box.get_children():
		child.queue_free()
	var skill_slots := int(_config.get("skill_slots", 0))
	var item_slots := int(_config.get("item_slots", 0))
	var head := Label.new()
	head.text = TextsZh.LOADOUT_SKILLS % [_skills.size(), skill_slots]
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	skill_box.add_child(head)
	for sk: Variant in _skills:
		var s: Dictionary = sk
		var sid := str(s["id"])
		var picked := _picked_skills.has(sid)
		var b := Button.new()
		b.text = ("● " if picked else "○ ") + str(s.get("name", sid))
		b.disabled = not picked and _picked_skills.size() >= skill_slots # 槽位已满禁用（09 §9.1）
		b.pressed.connect(func() -> void: _toggle_skill(sid))
		skill_box.add_child(b)
	var ihead := Label.new()
	ihead.text = TextsZh.LOADOUT_ITEMS % item_slots
	ihead.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	item_box.add_child(ihead)
	for it: Variant in _items:
		var d: Dictionary = it
		var iid := str(d["id"])
		var picked := _picked_items.has(iid)
		var b := Button.new()
		b.text = ("● " if picked else "○ ") + "%s ×%d" % [str(d.get("name", iid)), int(d.get("count", 1))]
		b.disabled = not picked and _picked_items.size() >= item_slots
		b.pressed.connect(func() -> void: _toggle_item(iid))
		item_box.add_child(b)
	attr_label.text = TextsZh.LOADOUT_ATTRS % _attr_points
	var names := {"might": "力", "finesse": "敏", "wits": "智"}
	for attr: String in ["might", "finesse", "wits"]:
		var b := Button.new()
		b.text = "%s %+d +" % [str(names[attr]), int(_attr_alloc.get(attr, 0))]
		# 单项 ≤+3 封顶（11 §6）：已分配 + 本次预选合计判定
		var total_now := int(_attrs_base.get(attr, 0)) + int(_attr_alloc.get(attr, 0))
		b.disabled = _attr_points <= 0 or total_now >= LightV1.ATTR_POINT_CAP
		b.pressed.connect(func() -> void:
			_attr_alloc[attr] = int(_attr_alloc[attr]) + 1
			_attr_points -= 1
			_refresh())
		attr_box.add_child(b)
	hint_label.text = ""

func _toggle_skill(sid: String) -> void:
	if _picked_skills.has(sid):
		_picked_skills.erase(sid)
	elif _picked_skills.size() < int(_config.get("skill_slots", 0)):
		_picked_skills.append(sid)
	_refresh()

func _toggle_item(iid: String) -> void:
	if _picked_items.has(iid):
		_picked_items.erase(iid)
	elif _picked_items.size() < int(_config.get("item_slots", 0)):
		_picked_items.append(iid)
	_refresh()

func _on_confirm() -> void:
	var reason := Loadout.validate(_config, _picked_skills, _picked_items)
	if reason != "":
		hint_label.text = "%s：%s" % [TextsZh.LOADOUT_FULL, reason]
		return
	confirmed.emit({"skills": _picked_skills.duplicate(), "items": _picked_items.duplicate(),
		"attr_alloc": _attr_alloc.duplicate(), "attr_points_left": _attr_points})

## 测试探针。
func picked_skills() -> Array[String]:
	return _picked_skills.duplicate()

func picked_items() -> Array[String]:
	return _picked_items.duplicate()
