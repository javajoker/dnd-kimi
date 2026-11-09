# 整备界面（docs/framework/09-遭遇与双模式交互规范.md §9.1；tech/02 §2.4 loadout 配置）
# - 战斗遭遇进场前：技能备选 / 道具携带 / 未分配属性点三块，确认后进入进场态；
# - 槽位限制读配置（manifest `loadout`，遭遇级可覆盖）——框架只执行，不硬编码；
# - 确认经 Loadout.confirm 写 `loadout.confirm` 事件（由 main 调用 core，本壳只发信号）。
# - 形态感知双布局（04 §④.8 横屏专版）：竖屏维持居中纵列（现状不变）；
#   横屏三段横列——左「技能备选」（芯片列，槽位计数）、中「道具携带 + 属性点」、
#   右「预设与开战」（预设卡 + 大号开战按钮居拇指右手区），队伍状态条置顶。
#   两形态同数据同操作路径（bind/toggle/confirm 信号完全一致），仅布局容器不同。
class_name ScreenLoadout
extends Control

signal confirmed(selection: Dictionary)
signal back_requested

var form: StringName = ShellRouter.MODE_TIME # 战役形态（09 §8；04 §④.8）：time=竖屏居中，space=横屏三段

var skill_box: VBoxContainer
var item_box: VBoxContainer
var attr_label: Label
var attr_box: HBoxContainer
var hint_label: Label
var confirm_button: Button
var back_button: Button

# 横屏专版容器（04 §④.8；竖屏形态恒为 null，作布局形态探针）
var party_bar: HBoxContainer    # 置顶队伍状态条
var cols: HBoxContainer         # 三段横列
var col_skills: VBoxContainer   # 左：技能备选
var col_items: VBoxContainer    # 中：道具携带 + 属性点
var col_right: VBoxContainer    # 右：预设与开战
var preset_label: Label         # 预设卡（当前选择摘要）
var preset_box: BoxContainer    # 系统预设按钮（09 §9.3；竖屏 = 标题下横排，横屏 = 右列预设卡内纵排）

var _config: Dictionary = {}
var _skills: Array = []          # 备选 [{id,name,desc}]
var _items: Array = []           # 备选 [{id,name,count}]
var _party: Array = []           # 队伍状态 [{id,name,hp,max_hp}]（graph.party_status()，04 §3.1 同口径）
var _basic_attacks: Array = []   # 角色普攻（恒定携带、不占槽位，tech/04 §2 basic_attack）
var _picked_skills: Array[String] = []
var _picked_items: Array[String] = []
var _attr_points := 0
var _attr_alloc := {"might": 0, "finesse": 0, "wits": 0}
var _attrs_base := {"might": 0, "finesse": 0, "wits": 0} # 板上已分配值（封顶判定，11 §6）
var _built := false

## 设定呈现形态（main 依战役形态注入，09 §8）；已建布局则重建并刷新（同数据重排）。
func set_form(mode: StringName) -> void:
	form = mode
	if _built:
		_rebuild()

func _ready() -> void:
	_build()
	_built = true
	size = get_viewport().get_visible_rect().size # 根 Control 父级为纯 Node：显式落视口尺寸（锚定无参照）

func _rebuild() -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	party_bar = null
	cols = null
	col_skills = null
	col_items = null
	col_right = null
	preset_label = null
	preset_box = null
	_build()
	_refresh()

func _build() -> void:
	if form == ShellRouter.MODE_SPACE:
		_build_landscape()
	else:
		_build_portrait()

## 竖屏：居中纵列（§④.8：竖屏布局不变）。
func _build_portrait() -> void:
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
	preset_box = HBoxContainer.new() # 系统预设一键套用（09 §9.3；无配置 = 空行不占地）
	(preset_box as HBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	preset_box.add_theme_constant_override("separation", 6)
	v.add_child(preset_box)
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

## 横屏专版（04 §④.8）：队伍状态条置顶 + 三段横列（左技能 / 中道具+属性点 / 右预设与开战）。
func _build_landscape() -> void:
	var root_v := VBoxContainer.new()
	root_v.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_v.add_theme_constant_override("separation", 12)
	add_child(root_v)
	# 置顶条：标题居左，队伍状态条居右（04 §④.8 队伍状态条置顶；数据源 = graph.party_status，04 §3.1 同口径）
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 16)
	root_v.add_child(top)
	var title := Label.new()
	title.text = TextsZh.LOADOUT_TITLE
	title.add_theme_font_size_override("font_size", 24)
	top.add_child(title)
	var top_spacer := Control.new()
	top_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(top_spacer)
	party_bar = HBoxContainer.new()
	party_bar.alignment = BoxContainer.ALIGNMENT_END
	party_bar.add_theme_constant_override("separation", 16)
	top.add_child(party_bar)
	# 三段横列
	cols = HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 24)
	root_v.add_child(cols)
	col_skills = VBoxContainer.new()
	col_skills.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_skills.add_theme_constant_override("separation", 6)
	cols.add_child(col_skills)
	skill_box = VBoxContainer.new()
	skill_box.add_theme_constant_override("separation", 4)
	col_skills.add_child(skill_box)
	col_items = VBoxContainer.new()
	col_items.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_items.add_theme_constant_override("separation", 6)
	cols.add_child(col_items)
	item_box = VBoxContainer.new()
	item_box.add_theme_constant_override("separation", 4)
	col_items.add_child(item_box)
	attr_label = Label.new()
	col_items.add_child(attr_label)
	attr_box = HBoxContainer.new()
	attr_box.add_theme_constant_override("separation", 6)
	col_items.add_child(attr_box)
	# 右列：预设卡 + 大号开战按钮（居拇指右手区，04 §④.8）
	col_right = VBoxContainer.new()
	col_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_right.add_theme_constant_override("separation", 8)
	cols.add_child(col_right)
	var preset_title := Label.new()
	preset_title.text = TextsZh.LOADOUT_PRESET_TITLE
	preset_title.add_theme_font_size_override("font_size", 18)
	col_right.add_child(preset_title)
	preset_box = VBoxContainer.new() # 系统预设一键套用（09 §9.3：预设卡可点击套用）
	preset_box.add_theme_constant_override("separation", 4)
	col_right.add_child(preset_box)
	preset_label = Label.new()
	preset_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preset_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	col_right.add_child(preset_label)
	var right_spacer := Control.new()
	right_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col_right.add_child(right_spacer)
	hint_label = Label.new()
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.4))
	col_right.add_child(hint_label)
	confirm_button = Button.new()
	confirm_button.text = TextsZh.LOADOUT_CONFIRM
	confirm_button.custom_minimum_size = Vector2(240, 72) # 大号开战按钮
	confirm_button.add_theme_font_size_override("font_size", 22)
	confirm_button.pressed.connect(_on_confirm)
	col_right.add_child(confirm_button)
	back_button = Button.new()
	back_button.text = TextsZh.COMMON_BACK
	back_button.pressed.connect(func() -> void: back_requested.emit())
	col_right.add_child(back_button)

## 绑定整备配置与备选数据（candidates = {skills[], items[], attr_points, attr_alloc, attrs, party[], basic_attacks[]}）。
func bind(config: Dictionary, candidates: Dictionary) -> void:
	_config = config
	_skills = candidates.get("skills", [])
	_items = candidates.get("items", [])
	_party = candidates.get("party", []) # 横屏队伍状态条数据源（竖屏忽略，04 §④.8）
	_basic_attacks = candidates.get("basic_attacks", []) # 普攻恒定携带（tech/04 §2）
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
	_refresh_party()
	_refresh_preset_box()
	_refresh_preset()

## 系统预设按钮（09 §9.3；配置驱动——manifest loadout.presets，tech/02 §2.4；无配置 = 不呈现）。
func _refresh_preset_box() -> void:
	if preset_box == null:
		return
	for child: Node in preset_box.get_children():
		child.queue_free()
	for p: Variant in _config.get("presets", []):
		var preset: Dictionary = p
		var b := Button.new()
		b.text = str(preset.get("name", preset.get("id", "")))
		b.tooltip_text = "%s / %s" % [str(preset.get("skills", [])), str(preset.get("items", []))]
		b.pressed.connect(func() -> void: _apply_preset(preset))
		preset_box.add_child(b)

## 一键套用预设（09 §9.3：简化重复操作，套用后可逐槽微调；预设只是槽位选择记录，不含数值加成）。
## 普攻（basic_attack）恒定携带不占槽位（tech/04 §2）；未习得技能 / 未持有道具跳过并提示。
func _apply_preset(preset: Dictionary) -> void:
	var skill_slots := int(_config.get("skill_slots", 0))
	var item_slots := int(_config.get("item_slots", 0))
	var missing: Array[String] = []
	_picked_skills.clear()
	_picked_items.clear()
	for sid: Variant in preset.get("skills", []):
		var s := str(sid)
		if _picked_skills.size() >= skill_slots:
			break
		if _basic_attacks.has(s):
			continue # 普攻恒定携带（tech/04 §2：basic_attack 亦属已习得）
		var known := false
		for sk: Variant in _skills:
			if str((sk as Dictionary)["id"]) == s:
				known = true
				break
		if known:
			_picked_skills.append(s)
		else:
			missing.append(s)
	for iid: Variant in preset.get("items", []):
		var it := str(iid)
		if _picked_items.size() >= item_slots:
			break
		var held := false
		for d: Variant in _items:
			if str((d as Dictionary)["id"]) == it:
				held = true
				break
		if held:
			_picked_items.append(it)
		else:
			missing.append(it)
	_refresh()
	if not missing.is_empty():
		hint_label.text = TextsZh.LOADOUT_PRESET_MISSING % "、".join(missing)

## 队伍状态条（04 §④.8 置顶；仅横屏有容器，竖屏 no-op）。
func _refresh_party() -> void:
	if party_bar == null:
		return
	for child: Node in party_bar.get_children():
		child.queue_free()
	for p: Variant in _party:
		var d: Dictionary = p
		var l := Label.new()
		l.text = TextsZh.LOADOUT_PARTY_ITEM % [str(d.get("name", "")), int(d.get("hp", 0)), int(d.get("max_hp", 0))]
		party_bar.add_child(l)

## 预设卡 = 当前选择摘要（04 §④.8 右列「预设与开战」；命名预设的保存/调用无数据规格，待裁决）。
func _refresh_preset() -> void:
	if preset_label == null:
		return
	var names: Array[String] = []
	for sk: Variant in _skills:
		var s: Dictionary = sk
		if _picked_skills.has(str(s["id"])):
			names.append(str(s.get("name", s["id"])))
	for it: Variant in _items:
		var d: Dictionary = it
		if _picked_items.has(str(d["id"])):
			names.append(str(d.get("name", d["id"])))
	preset_label.text = "、".join(names) if not names.is_empty() else TextsZh.LOADOUT_PRESET_EMPTY

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

## 布局形态探针（04 §④.8：横屏三段横列）。
func is_landscape_layout() -> bool:
	return cols != null
