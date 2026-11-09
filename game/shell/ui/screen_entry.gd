# ② 战役入口（docs/framework/04-UI-UX设计文档.md §②；09 §3 战役入口模式分支规范）
# - 战役书卡：标题 / 推荐等级 / 预计时长 / 幕构成；模式分支区：双形态卡各附差异说明与推荐标签；
# - 未选模式禁用开始；选择写入 global.mode_choice.<campaign_id>（09 §3，写板由 main 执行，本壳只发信号）；
# - 强制模式：不呈现选择，以叙事化包装（09 §3 禁止系统腔）；
# - 多周目信息：已玩模式标记 + 分支收集占比。
class_name ScreenEntry
extends Control

signal mode_chosen(mode: StringName)
signal start_requested
signal back_requested
signal subgame_start(pack_id: String, mode: StringName) # 子游戏卡参战（04 §6）
signal acquire_requested(pack_id: String) # 锁定卡「获取」→ 购买半屏弹层（06 §3.1/§6）

var card_label: RichTextLabel
var mode_time_button: Button
var mode_space_button: Button
var mode_hint: Label
var collect_label: Label
var played_label: Label
var start_button: Button
var back_button: Button
var subgame_box: VBoxContainer
var shop_popup: ShopPopup

var selected_mode: StringName = &""

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
	title.text = TextsZh.ENTRY_TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	v.add_child(title)
	card_label = RichTextLabel.new()
	card_label.bbcode_enabled = false
	card_label.fit_content = true
	card_label.custom_minimum_size = Vector2(340, 0)
	v.add_child(card_label)
	mode_hint = Label.new()
	mode_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mode_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mode_hint.custom_minimum_size = Vector2(340, 0)
	v.add_child(mode_hint)
	var cards := HBoxContainer.new()
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	cards.add_theme_constant_override("separation", 12)
	v.add_child(cards)
	mode_time_button = _mode_card(cards, TextsZh.ENTRY_MODE_TIME, TextsZh.ENTRY_MODE_TIME_DESC,
		ShellRouter.MODE_TIME)
	mode_space_button = _mode_card(cards, TextsZh.ENTRY_MODE_SPACE, TextsZh.ENTRY_MODE_SPACE_DESC,
		ShellRouter.MODE_SPACE)
	played_label = Label.new()
	played_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(played_label)
	collect_label = Label.new()
	collect_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(collect_label)
	start_button = Button.new()
	start_button.text = TextsZh.ENTRY_START
	start_button.disabled = true # 未选模式禁用开始（任务书 TP4）
	start_button.pressed.connect(func() -> void: start_requested.emit())
	v.add_child(start_button)
	back_button = Button.new()
	back_button.text = TextsZh.COMMON_BACK
	back_button.pressed.connect(func() -> void: back_requested.emit())
	v.add_child(back_button)
	# 子游戏卡区（04 §6：pack_type=subgame 即入列，数据驱动；无子游戏包时保持为空不占位）
	subgame_box = VBoxContainer.new()
	subgame_box.alignment = BoxContainer.ALIGNMENT_CENTER
	subgame_box.add_theme_constant_override("separation", 6)
	v.add_child(subgame_box)
	# 购买半屏弹层（06 §6：不离开当前界面情境；04 §3.3）
	shop_popup = ShopPopup.new()
	add_child(shop_popup)

## 绑定子游戏卡（04 §6 特殊战役书卡）：cards = [{pack_id, name, level_min, stats, mode,
## locked, lock_text}]，全部由 manifest 数据驱动；mode=choice 呈现竖/横两个参战入口（概念设计 §5）。
## locked=true 时呈现锁定态（06 §3.1）：卡面与战绩照常可见 + 叙事化锁定文案 +「获取」按钮，
## 不隐藏、不弹"未购买"生硬弹窗；点亮后同卡直接呈现参战入口（购买即解锁无需重启）。
func bind_subgames(cards: Array) -> void:
	for child: Node in subgame_box.get_children():
		child.queue_free()
	if cards.is_empty():
		return
	var head := Label.new()
	head.text = TextsZh.ENTRY_SUBGAME_SECTION
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subgame_box.add_child(head)
	for card: Variant in cards:
		var c: Dictionary = card
		var pid := str(c.get("pack_id", ""))
		# 每卡一个命名容器（card_<pid>）：多子游戏共存时按包寻址（M4：arena + riddle_maze 双卡在架）
		var card_box := VBoxContainer.new()
		card_box.name = "card_" + pid
		card_box.alignment = BoxContainer.ALIGNMENT_CENTER
		card_box.add_theme_constant_override("separation", 6)
		subgame_box.add_child(card_box)
		var name_label := Label.new()
		name_label.text = "%s《%s》 %s" % [TextsZh.ENTRY_SUBGAME_TAG, str(c.get("name", c.get("pack_id", ""))),
			TextsZh.SUBGAME_LEVEL % int(c.get("level_min", 1))]
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card_box.add_child(name_label)
		var stats_label := Label.new()
		var st: Dictionary = c.get("stats", {})
		stats_label.text = TextsZh.SUBGAME_STATS % [int(st.get("wins", 0)), int(st.get("best", 0))]
		stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stats_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
		card_box.add_child(stats_label)
		if bool(c.get("locked", false)):
			# 锁定态（06 §3.1：可见但锁定，叙事化包装）
			var lock_label := Label.new()
			lock_label.text = str(c.get("lock_text", TextsZh.LOCK_ARENA))
			lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lock_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			lock_label.custom_minimum_size = Vector2(340, 0)
			lock_label.add_theme_color_override("font_color", Color(0.75, 0.68, 0.5))
			card_box.add_child(lock_label)
			var acquire_button := Button.new()
			acquire_button.text = TextsZh.LOCK_ACQUIRE
			acquire_button.custom_minimum_size = Vector2(150, 40)
			acquire_button.pressed.connect(func() -> void: acquire_requested.emit(pid))
			card_box.add_child(acquire_button)
			continue
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 12)
		card_box.add_child(row)
		var mode := str(c.get("mode", "choice"))
		if mode != "space":
			var bt := Button.new()
			bt.text = TextsZh.SUBGAME_ENTER_TIME
			bt.custom_minimum_size = Vector2(150, 40)
			bt.pressed.connect(func() -> void: subgame_start.emit(pid, ShellRouter.MODE_TIME))
			row.add_child(bt)
		if mode != "time":
			var bs := Button.new()
			bs.text = TextsZh.SUBGAME_ENTER_SPACE
			bs.custom_minimum_size = Vector2(150, 40)
			bs.pressed.connect(func() -> void: subgame_start.emit(pid, ShellRouter.MODE_SPACE))
			row.add_child(bs)

func _mode_card(parent: Container, name: String, desc: String, mode: StringName) -> Button:
	var card := VBoxContainer.new()
	card.custom_minimum_size = Vector2(150, 0)
	parent.add_child(card)
	var b := Button.new()
	b.text = name
	b.custom_minimum_size = Vector2(150, 44)
	b.pressed.connect(func() -> void: pick_mode(mode))
	card.add_child(b)
	var d := Label.new()
	d.text = desc
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.custom_minimum_size = Vector2(150, 0)
	d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	d.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	card.add_child(d)
	return b

## 选择形态（09 §3：一次分支，整场锁定）。壳只刷新呈现并上报，写板由 main 完成。
func pick_mode(mode: StringName) -> void:
	selected_mode = mode
	start_button.disabled = false
	var chosen := TextsZh.ENTRY_MODE_TIME if mode == ShellRouter.MODE_TIME else TextsZh.ENTRY_MODE_SPACE
	mode_hint.text = "%s%s" % [TextsZh.ENTRY_MODE_CHOSEN, chosen]
	mode_time_button.modulate = Color(1, 1, 0.6) if mode == ShellRouter.MODE_TIME else Color(1, 1, 1)
	mode_space_button.modulate = Color(1, 1, 0.6) if mode == ShellRouter.MODE_SPACE else Color(1, 1, 1)
	mode_chosen.emit(mode)

## 绑定战役包数据（只读）。played_modes = 已玩模式标记数组；collect_pct = 分支收集占比（0~100）。
func bind(pack: Dictionary, played_modes: Array, collect_pct: float) -> void:
	var manifest: Dictionary = pack["manifest"]
	var level: Array = manifest.get("recommended_level", [])
	var lines: Array[String] = [
		"《%s》" % str(manifest.get("name", pack.get("pack_id", ""))),
		"推荐等级 %s · 预计时长 %s" % ["~".join(level.map(func(x: Variant) -> String: return str(x))),
			str(manifest.get("estimated_hours", "?"))],
		"幕构成：%s" % " / ".join((pack.get("acts", []) as Array).map(
			func(a: Variant) -> String: return str((a as Dictionary).get("title", "")))),
	]
	card_label.text = "\n".join(lines)
	# 模式分支区（09 §3）：choice 呈现双卡；强制模式叙事化包装（禁系统腔）
	var pres: Dictionary = manifest.get("presentation", {})
	var recommend: Dictionary = pres.get("recommend", {})
	if str(pres.get("mode", "time")) == "choice":
		mode_hint.text = TextsZh.ENTRY_MODE_PICK
		mode_time_button.visible = true
		mode_space_button.visible = true
		if recommend.values().has("space"):
			mode_space_button.text += "\n〔框架推荐〕"
	else:
		var forced := ShellRouter.MODE_TIME if str(pres.get("mode", "time")) == "time" else ShellRouter.MODE_SPACE
		mode_hint.text = str(ShellRouter.NOTICE_FORCED.get(forced, "")) # 叙事化包装（09 §3）
		mode_time_button.visible = false
		mode_space_button.visible = false
		pick_mode(forced)
	if played_modes.is_empty():
		played_label.text = ""
	else:
		var names: Array = played_modes.map(func(m: Variant) -> String:
			return TextsZh.ENTRY_MODE_TIME if StringName(str(m)) == ShellRouter.MODE_TIME else TextsZh.ENTRY_MODE_SPACE)
		played_label.text = "%s%s" % [TextsZh.ENTRY_PLAYED, "、".join(names)]
	collect_label.text = "%s %.0f%%" % [TextsZh.ENTRY_COLLECT, collect_pct]
