# ⑧ 历史卷轴（docs/framework/04-UI-UX设计文档.md §⑧；07 §6：历史卷轴 = 事件流视图 + 溯源回链状态板）
# - 事件流倒序时间轴；每条可展开明细：检定 d20 明细（骰值+修正=结果 vs 难度）、旗标溯源（来源节点）；
# - 关键判定标记（09 §6 key=true）；筛选留白；
# - 战报回放（04 §⑧）：战斗条目「重演」= 事件流按节拍重放进只读战报视图——
#   最小版形态 = 节拍日志重演（BattleText 同一文案源，0.5s/拍，可跳过），纯演出、不可改结果：
#   只读事件流，不产生任何命令/写板。
class_name ScreenHistory
extends Control

signal back_requested

const PAGE_SIZE := 40
const REPLAY_BEAT := 0.5 # 节拍（秒/拍）

var list_box: VBoxContainer
var detail_label: RichTextLabel
var back_button: Button
var replay_panel: PanelContainer
var replay_view: RichTextLabel
var replay_hint: Label
var _replay_timer: Timer

var _stream: EventStream
var _board: Board
var _name_resolver: Callable = Callable()
var _replay_lines: Array[String] = []
var _replay_idx := 0

func _ready() -> void:
	_build()
	size = get_viewport().get_visible_rect().size # 根 Control 父级为纯 Node：显式落视口尺寸（锚定无参照）

func _build() -> void:
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var title := Label.new()
	title.text = TextsZh.HISTORY_TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	v.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	list_box = VBoxContainer.new()
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_box)
	detail_label = RichTextLabel.new()
	detail_label.bbcode_enabled = false
	detail_label.fit_content = true
	detail_label.custom_minimum_size = Vector2(0, 110)
	v.add_child(detail_label)
	back_button = Button.new()
	back_button.text = TextsZh.COMMON_BACK
	back_button.pressed.connect(func() -> void: back_requested.emit())
	v.add_child(back_button)
	_build_replay()

## 绑定事件流与状态板（只读）。name_resolver = func(unit_id) -> String（可选）。
func bind(stream: EventStream, board: Board, name_resolver: Callable = Callable()) -> void:
	_stream = stream
	_board = board
	_name_resolver = name_resolver
	_refresh()

func _refresh() -> void:
	for child: Node in list_box.get_children():
		child.queue_free()
	detail_label.text = ""
	var events := _stream.all()
	if events.is_empty():
		var l := Label.new()
		l.text = TextsZh.HISTORY_EMPTY
		list_box.add_child(l)
		return
	var shown := 0
	for i: int in range(events.size() - 1, -1, -1): # 倒序（04 §⑧ 时间轴）
		if shown >= PAGE_SIZE:
			break
		shown += 1
		var ev: Dictionary = events[i]
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list_box.add_child(row)
		var b := Button.new()
		b.text = _row_text(ev)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void: detail_label.text = _detail_text(ev))
		row.add_child(b)
		if StringName(ev["type"]) == EventTypes.COMBAT_START:
			# 战报回放（04 §⑧：重要战斗的事件流重演，纯演出不可改结果）
			var rb := Button.new()
			rb.text = TextsZh.HISTORY_REPLAY
			var start_id := int(ev["id"])
			rb.pressed.connect(func() -> void: start_replay(start_id))
			row.add_child(rb)

## 行摘要：序号 + 类型 + 关键标记 + 简述。
func _row_text(ev: Dictionary) -> String:
	var p: Dictionary = ev["payload"]
	var brief := ""
	match StringName(ev["type"]):
		EventTypes.CHECK_ROLL:
			brief = "%s %s vs DC%d %s" % [_name(str(p.get("roller", ""))), str(p.get("keep", "?")),
				int(p.get("dc", 0)), TextsZh.RESULT_SUCCESS if bool(p.get("success", false)) else TextsZh.RESULT_FAIL]
		EventTypes.BATTLE_ATTACK:
			brief = "%s → %s %s" % [_name(str(p.get("attacker", ""))), _name(str(p.get("target", ""))),
				"命中 %d" % int(p.get("damage", 0)) if bool(p.get("hit", false)) else "未命中"]
		EventTypes.FLAG_WRITE, EventTypes.REP_CHANGE, EventTypes.CLOCK_TICK, \
		EventTypes.BOND_CHANGE, EventTypes.ALIGNMENT_SHIFT:
			brief = str(p.get("key", ""))
		EventTypes.QUEST_TRIGGER, EventTypes.QUEST_SETTLE:
			brief = str(p.get("name", p.get("id", "")))
		EventTypes.LOG:
			brief = str(p.get("msg", "")).left(24)
		_:
			brief = str(p.get("msg", p.get("name", p.get("state", "")))).left(24)
	# 注：payload.key 在旗标事件中是字符串键名，关键判定标记只在 key 为布尔 true 时点亮（09 §6）
	var key_mark := " ★" if _is_key_roll(p) else ""
	return "#%d [%s]%s %s" % [int(ev["id"]), str(ev["type"]), key_mark, brief]

## 展开明细：检定 d20 明细 / 旗标溯源（07 §1 provenance → 来源节点）。
func _detail_text(ev: Dictionary) -> String:
	var p: Dictionary = ev["payload"]
	var lines: Array[String] = ["#%d [%s]%s" % [int(ev["id"]), str(ev["type"]),
		"　" + TextsZh.HISTORY_KEY_MARK if _is_key_roll(p) else ""]]
	match StringName(ev["type"]):
		EventTypes.CHECK_ROLL:
			lines.append("检定明细：骰 %s 取 %d 修正 %+d = %d vs DC %d → %s" % [
				str(p.get("rolls", [])), int(p.get("keep", 0)), int(p.get("mod", 0)),
				int(p.get("total", p.get("keep", 0))), int(p.get("dc", 0)),
				TextsZh.RESULT_SUCCESS if bool(p.get("success", false)) else TextsZh.RESULT_FAIL])
			if str(p.get("kind", "")) == "death_save":
				lines.append("死亡豁免 %d 胜 %d 负" % [int(p.get("s", 0)), int(p.get("f", 0))])
		EventTypes.BATTLE_ATTACK:
			lines.append("攻击明细：骰 %s 取 %d（%s）修正 %+d vs AC %d → %s" % [
				str(p.get("rolls", [])), int(p.get("keep", 0)), str(p.get("mode", "")),
				int(p.get("atk_mod", 0)), int(p.get("target_ac", 0)),
				"命中，伤害 %d %s" % [int(p.get("damage", 0)), str(p.get("damage_rolls", []))]
					if bool(p.get("hit", false)) else "未命中"])
		EventTypes.FLAG_WRITE, EventTypes.REP_CHANGE, EventTypes.CLOCK_TICK, \
		EventTypes.BOND_CHANGE, EventTypes.ALIGNMENT_SHIFT:
			lines.append("旗标变化：%s　%s → %s" % [str(p.get("key", "")),
				str(p.get("old", "")), str(p.get("value", ""))])
	var prov: Dictionary = p.get("provenance", {})
	if not prov.is_empty():
		lines.append(TextsZh.HISTORY_PROV % [str(prov.get("node_id", "?")), str(prov.get("pack_id", "?"))])
	elif str(ev.get("node", "")) != "":
		lines.append(TextsZh.HISTORY_PROV % [str(ev["node"]), str(ev.get("source", ""))])
	return "\n".join(lines)

func _name(id: String) -> String:
	if _name_resolver.is_valid():
		return str(_name_resolver.call(id))
	return id

## payload.key 在旗标类事件中是字符串键名；关键判定仅在 key 为布尔 true 时成立（09 §6）。
static func _is_key_roll(p: Dictionary) -> bool:
	var kv: Variant = p.get("key", false)
	return kv is bool and bool(kv)

# ---------------------------------------------------------------- 战报回放（04 §⑧：最小版 = 节拍日志重演，纯演出不可改结果）

func _build_replay() -> void:
	replay_panel = PanelContainer.new()
	replay_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	replay_panel.visible = false
	add_child(replay_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	replay_panel.add_child(v)
	var title := Label.new()
	title.text = TextsZh.REPLAY_TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	v.add_child(title)
	replay_view = RichTextLabel.new()
	replay_view.bbcode_enabled = false
	replay_view.scroll_following = true
	replay_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(replay_view)
	replay_hint = Label.new()
	replay_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	replay_hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	v.add_child(replay_hint)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(row)
	var skip := Button.new() # 跳过 = 直接播完（不丢信息，04 §④.7 同原则）
	skip.text = TextsZh.REPLAY_SKIP
	skip.pressed.connect(func() -> void: _replay_finish())
	row.add_child(skip)
	var close := Button.new()
	close.text = TextsZh.COMMON_BACK
	close.pressed.connect(func() -> void: _replay_close())
	row.add_child(close)
	_replay_timer = Timer.new()
	_replay_timer.wait_time = REPLAY_BEAT
	_replay_timer.timeout.connect(_replay_tick)
	add_child(_replay_timer)

## 重演一场战斗：截取 combat.start → 其后的 combat.end 之间的事件段，按节拍重放（只读）。
func start_replay(start_id: int) -> void:
	_replay_lines.clear()
	_replay_idx = 0
	for ev: Dictionary in _stream.all():
		if int(ev["id"]) < start_id:
			continue
		var line := BattleText.event_log_text(ev, _name)
		if line != "":
			_replay_lines.append(line)
		if StringName(ev["type"]) == EventTypes.COMBAT_END:
			break
	replay_view.text = ""
	replay_hint.text = ""
	replay_panel.visible = true
	if _replay_lines.is_empty():
		_replay_finish()
	else:
		_replay_timer.start()

func _replay_tick() -> void:
	if _replay_idx >= _replay_lines.size():
		_replay_finish()
		return
	replay_view.append_text(_replay_lines[_replay_idx] + "\n")
	_replay_idx += 1

func _replay_finish() -> void:
	_replay_timer.stop()
	while _replay_idx < _replay_lines.size():
		replay_view.append_text(_replay_lines[_replay_idx] + "\n")
		_replay_idx += 1
	replay_hint.text = TextsZh.REPLAY_DONE

func _replay_close() -> void:
	_replay_timer.stop()
	replay_panel.visible = false

## 测试探针。
func is_replay_visible() -> bool:
	return replay_panel.visible

func replay_text() -> String:
	return replay_view.get_parsed_text()
