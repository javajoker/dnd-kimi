# ⑧ 历史卷轴（docs/framework/04-UI-UX设计文档.md §⑧；07 §6：历史卷轴 = 事件流视图 + 溯源回链状态板）
# - 事件流倒序时间轴；每条可展开明细：检定 d20 明细（骰值+修正=结果 vs 难度）、旗标溯源（来源节点）；
# - 关键判定标记（09 §6 key=true）；筛选与战报回放为呈现方向，最小版标注随内容接入补全（04 §⑧）。
class_name ScreenHistory
extends Control

signal back_requested

const PAGE_SIZE := 40

var list_box: VBoxContainer
var detail_label: RichTextLabel
var back_button: Button

var _stream: EventStream
var _board: Board
var _name_resolver: Callable = Callable()

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
	var wip := Label.new()
	wip.text = "（筛选 / 战报回放 %s）" % TextsZh.COMMON_WIP
	wip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wip.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	v.add_child(wip)
	back_button = Button.new()
	back_button.text = TextsZh.COMMON_BACK
	back_button.pressed.connect(func() -> void: back_requested.emit())
	v.add_child(back_button)

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
		var b := Button.new()
		b.text = _row_text(ev)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func() -> void: detail_label.text = _detail_text(ev))
		list_box.add_child(b)

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
