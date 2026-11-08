# 条件求值器 + 效果执行器（docs/tech/02-内容包格式规范.md §4.6 通用条件与效果词汇表）
# 条件：flag.<id> / rep.<faction> / clock / item.<id> / alignment(ink_gt/blank_gt) / bond.<npc> /
#       bond_max / all / any；同一条件字典内多个键为隐式 AND。
# 效果：write+value / clock / rep.<faction> / alignment / give_item / remove_item / xp / bond.<npc> / lore
#       —— 凡 07 定义了落板键的一律经 Board 写板（自动产出对应事件；lore → global.lore，07 §2 约束）；
#       xp 在 07 无落板键，只产出 xp.gain 事件（见交付说明"待裁决"）。
class_name Conditions
extends RefCounted

var _board: Board

func _init(board: Board) -> void:
	_board = board

# ---------------------------------------------------------------- 条件求值

## ctx = { pack_id }：包内旗标省略前缀时按本包命名空间解析（tech/02 §4.6 表注、07 §3 铁律1）。
func evaluate(cond: Dictionary, ctx: Dictionary = {}) -> bool:
	var pack_id := str(ctx.get("pack_id", ""))
	for key: Variant in cond.keys():
		if not _eval_one(str(key), cond[key], pack_id, ctx):
			return false
	return true

func _eval_one(key: String, expected: Variant, pack_id: String, ctx: Dictionary) -> bool:
	if key == "all":
		for sub: Variant in expected:
			if not evaluate(sub, ctx):
				return false
		return true
	if key == "any":
		for sub: Variant in expected:
			if evaluate(sub, ctx):
				return true
		return false
	if key == "clock":
		return _cmp(_board.get_doom_clock(), expected)
	if key == "alignment":
		return _eval_alignment(expected)
	if key == "bond_max":
		return _cmp(_bond_max(), expected)
	if key.begins_with("flag."):
		var full := _qualify_flag(key.substr(5), pack_id)
		return bool(_board.read(full)) == bool(expected)
	if key.begins_with("rep."):
		return _cmp(_board.get_rep(key.substr(4)), expected)
	if key.begins_with("item."):
		return _eval_item(key.substr(5), expected)
	if key.begins_with("bond."):
		return _cmp(_board.get_bond(key.substr(5)), expected)
	push_warning("Conditions: 未登记的条件键 '%s'（tech/02 §4.6），按 false 处理" % key)
	return false

## 倾向轴（07 §2：0=全留白，100=全墨守）。ink_gt n ↔ alignment > n；blank_gt n ↔ (100-alignment) > n。
func _eval_alignment(expected: Variant) -> bool:
	var v := _board.get_alignment()
	if expected is Dictionary:
		if expected.has("ink_gt"):
			return v > int(expected["ink_gt"])
		if expected.has("blank_gt"):
			return (100 - v) > int(expected["blank_gt"])
	return _cmp(v, expected)

## 持有（bool）或持有数量（{">=": n} 等）。
func _eval_item(item_id: String, expected: Variant) -> bool:
	var count := _board.item_count(item_id)
	if expected is bool:
		return (count > 0) == expected
	return _cmp(count, expected)

func _bond_max() -> int:
	var m := 0
	for key: String in _board.keys_with_prefix("global.bond."):
		m = maxi(m, int(_board.read(key)))
	return m

# ---------------------------------------------------------------- 效果执行

## ctx = { pack_id, node_id, event_id, source? }：溯源三要素随每次写板落记录（07 §1）。
func apply_effects(effects: Array, ctx: Dictionary = {}) -> void:
	for effect: Variant in effects:
		apply_effect(effect, ctx)

func apply_effect(effect: Dictionary, ctx: Dictionary = {}) -> void:
	var pack_id := str(ctx.get("pack_id", ""))
	var node_id := str(ctx.get("node_id", ""))
	var source := StringName(str(ctx.get("source", "graph")))
	var prov := {
		"event_id": int(ctx.get("event_id", 0)),
		"node_id": node_id,
		"pack_id": pack_id,
	}
	for key: Variant in effect.keys():
		var k := str(key)
		if k == "value": # write 的伴生键，随 write 一并处理
			continue
		if k == "write":
			_board.write(_qualify_flag(str(effect["write"]), pack_id), effect.get("value", true), prov)
		elif k == "clock":
			_board.write("global.doom_clock", _board.get_doom_clock() + int(effect[k]), prov)
		elif k == "alignment":
			_board.write("global.alignment", _board.get_alignment() + int(effect[k]), prov)
		elif k == "give_item":
			_board.give_item(str(effect[k]), 1, prov)
		elif k == "remove_item":
			_board.remove_item(str(effect[k]), 1, prov)
		elif k == "xp":
			_board.stream.emit(EventTypes.XP_GAIN,
				{"amount": int(effect[k]), "provenance": prov.duplicate()}, source, node_id)
		elif k == "lore":
			# 落板 global.lore（Set<lore_id>，07 §2 约束；全局白名单任何包可写，07 §3），
			# Board 写板即产 lore.unlock 事件并带溯源（tech/02 §4.6）。
			_board.unlock_lore(str(effect[k]), prov)
		elif k.begins_with("rep."):
			var bk := "global.rep." + k.substr(4)
			_board.write(bk, int(_board.read(bk)) + int(effect[k]), prov)
		elif k.begins_with("bond."):
			var bk2 := "global.bond." + k.substr(5)
			_board.write(bk2, int(_board.read(bk2)) + int(effect[k]), prov)
		else:
			push_warning("Conditions: 未登记的效果键 '%s'（tech/02 §4.6），已跳过" % k)

# ---------------------------------------------------------------- 内部

## 包内旗标省略前缀 → 自动解析为本包命名空间；已带前缀（含跨包读）按全键处理（07 §3）。
static func _qualify_flag(flag_id: String, pack_id: String) -> String:
	if "." in flag_id or pack_id.is_empty():
		return flag_id
	return pack_id + "." + flag_id

## 阈值比较：{">=": n} / {"<=": n} / {">": n} / {"<": n} / {"==": n} / {"!=": n}；非字典按相等。
static func _cmp(actual: int, expected: Variant) -> bool:
	if expected is Dictionary:
		for op: Variant in expected.keys():
			var n := int(expected[op])
			match str(op):
				">=":
					if actual < n:
						return false
				"<=":
					if actual > n:
						return false
				">":
					if actual <= n:
						return false
				"<":
					if actual >= n:
						return false
				"==", "=":
					if actual != n:
						return false
				"!=":
					if actual == n:
						return false
				_:
					push_warning("Conditions: 未知比较符 '%s'" % str(op))
					return false
		return true
	return actual == int(expected)
