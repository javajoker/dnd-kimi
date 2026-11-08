# 世界状态板（docs/framework/07-世界状态机规范.md 全文；docs/tech/01-技术方案讨论稿.md §4）
# - 键格式 "<namespace>.<name>"；六类变量是同一键值上的六个语义标签（07 §1、tech/01 §4.1）。
# - 命名空间权限（07 §3）：包内旗标仅本包可写；global 白名单（rep/alignment/bond/inv/doom_clock/lore/tutorial.*/mode_choice.*/growth.*）
#   任何包可写；global.entitlement.* 仅 system 可写；越权一律拒绝并发 board.denied 告警事件。
# - 写入即钳位并产出 clamped 事件（07 §2 约束：不静默）。
# - 每次写入必须携带溯源 provenance={event_id, node_id, pack_id}（07 §1、tech/01 §4.2）。
# - 快照选择 JSON 序列化（tech/01 §4.3：Board 全量序列化（JSON））。
class_name Board
extends RefCounted

const REP_MIN := -5
const REP_MAX := 5
const CLOCK_MIN := 0
const CLOCK_MAX := 10
const BOND_MIN := 0
const BOND_MAX := 100
const ALIGNMENT_MIN := 0
const ALIGNMENT_MAX := 100
const ALIGNMENT_DEFAULT := 50

var stream: EventStream
var _data: Dictionary = {}
var _prov: Dictionary = {}

func _init(event_stream: EventStream = null) -> void:
	stream = event_stream if event_stream != null else EventStream.new()

# ---------------------------------------------------------------- 读取

## 读键；未写入时按语义标签给默认值（07 §2：flag=false、rep=0、clock=0、bond=0、alignment=50、inv={}）。
func read(key: String, default_value: Variant = null) -> Variant:
	if _data.has(key):
		return _data[key]
	if default_value != null:
		return default_value
	return _default_for(key)

func has(key: String) -> bool:
	return _data.has(key)

func get_rep(faction: String) -> int:
	return int(read("global.rep." + faction))

func get_bond(npc_id: String) -> int:
	return int(read("global.bond." + npc_id))

func get_doom_clock() -> int:
	return int(read("global.doom_clock"))

func get_alignment() -> int:
	return int(read("global.alignment"))

## 物品持有：存储为 {item_id: count} 计数字典——成员判定满足 07 §2 的 Set 语义，
## 计数支撑 tech/02 §4.6 的 item.<id> 数量查询与 07 §2 约束3（计数型旗标不落 Flag）。
func get_inv() -> Dictionary:
	return read("global.inv", {}).duplicate(true)

func has_item(item_id: String) -> bool:
	return item_count(item_id) > 0

func item_count(item_id: String) -> int:
	return int(read("global.inv", {}).get(item_id, 0))

## 图鉴条目解锁集合（07 §2 约束：global.lore，Set<lore_id>，全局白名单）。
func get_lore() -> Array:
	return (read("global.lore", []) as Array).duplicate()

func has_lore(lore_id: String) -> bool:
	return get_lore().has(lore_id)

## 解锁图鉴条目：集合语义，重复解锁幂等；每次写入仍产 lore.unlock 事件（tech/02 §4.6）。
func unlock_lore(lore_id: String, provenance: Dictionary) -> bool:
	var lore := get_lore()
	if not lore.has(lore_id):
		lore.append(lore_id)
	return write("global.lore", lore, provenance)

func keys_with_prefix(prefix: String) -> Array:
	var out: Array = []
	for key: String in _data.keys():
		if key.begins_with(prefix):
			out.append(key)
	return out

## 某键最近一次写入的溯源（历史卷轴"旗标追溯"数据来源，07 §1）。
func provenance_of(key: String) -> Dictionary:
	return _prov.get(key, {}).duplicate(true)

# ---------------------------------------------------------------- 写入

## 唯一写入入口。越权/缺溯源拒绝并返回 false；成功写入发对应事件进事件流。
func write(key: String, value: Variant, provenance: Dictionary) -> bool:
	if not _provenance_ok(provenance):
		push_error("Board.write 缺少溯源 provenance={event_id,node_id,pack_id}：key=%s（tech/01 §4.2）" % key)
		return false
	var pack_id := str(provenance.get("pack_id", ""))
	if not _can_write(key, pack_id):
		stream.emit(EventTypes.BOARD_DENIED,
			{"key": key, "pack_id": pack_id, "reason": "namespace"}, &"board")
		return false
	var clamp_res: Array = _clamp_value(key, value)
	var new_value: Variant = clamp_res[0]
	var was_clamped: bool = clamp_res[1]
	if key == "global.inv":
		_write_inv(new_value, provenance)
	else:
		var old_value: Variant = read(key)
		_data[key] = new_value
		_prov[key] = provenance.duplicate(true)
		_emit_state_event(key, old_value, new_value, provenance)
	if was_clamped:
		stream.emit(EventTypes.CLAMPED,
			{"key": key, "requested": value, "clamped_to": new_value, "provenance": provenance.duplicate(true)},
			&"board")
	return true

## 物品便捷写入（效果执行器 give_item/remove_item 的落板路径）。
func give_item(item_id: String, n: int, provenance: Dictionary) -> bool:
	var inv := get_inv()
	inv[item_id] = int(inv.get(item_id, 0)) + n
	return write("global.inv", inv, provenance)

func remove_item(item_id: String, n: int, provenance: Dictionary) -> bool:
	var inv := get_inv()
	var left: int = maxi(int(inv.get(item_id, 0)) - n, 0)
	if left == 0:
		inv.erase(item_id)
	else:
		inv[item_id] = left
	return write("global.inv", inv, provenance)

# ---------------------------------------------------------------- 快照（JSON 序列化，tech/01 §4.3）

## 全量快照：状态板 + 溯源表，全部 JSON 安全类型。
func serialize() -> Dictionary:
	return {"data": _data.duplicate(true), "provenance": _prov.duplicate(true)}

func deserialize(snapshot: Dictionary) -> void:
	# Godot JSON 把一切数字解析为 float；整值 float 归一为 int，保证快照往返逐字节一致。
	_data = _normalize_numbers((snapshot.get("data", {}) as Dictionary).duplicate(true))
	_prov = _normalize_numbers((snapshot.get("provenance", {}) as Dictionary).duplicate(true))

static func _normalize_numbers(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k: Variant in v.keys():
			out[k] = _normalize_numbers(v[k])
		return out
	if v is Array:
		var out: Array = []
		for item: Variant in v:
			out.append(_normalize_numbers(item))
		return out
	if v is float and v == floorf(v) and absf(v) < 9007199254740992.0:
		return int(v)
	return v

# ---------------------------------------------------------------- 内部

func _provenance_ok(provenance: Dictionary) -> bool:
	return provenance.has("event_id") and provenance.has("node_id") and provenance.has("pack_id")

## 命名空间写权限（07 §3 表）。
func _can_write(key: String, pack_id: String) -> bool:
	var ns := key.get_slice(".", 0)
	if ns == "global":
		if key.begins_with("global.entitlement."):
			return pack_id == "system"
		if key == "global.alignment" or key == "global.inv" or key == "global.doom_clock" or key == "global.lore":
			return true
		if key.begins_with("global.rep.") or key.begins_with("global.bond.") or key.begins_with("global.tutorial."):
			return true
		if key.begins_with("global.mode_choice."):
			return true # 战役入口模式选择（09 §3；07 §3 v1.1 补登记）
		if key.begins_with("global.growth."):
			return true # 成长簿记（07 §2 白名单；tech/04 §8：任何包 xp 效果即汇入）
		return false # global 白名单之外一律拒绝
	return ns == pack_id # 包内旗标仅本包可写；跨包写禁止

func _default_for(key: String) -> Variant:
	if key == "global.alignment":
		return ALIGNMENT_DEFAULT
	if key == "global.inv":
		return {}
	if key == "global.lore":
		return []
	if key == "global.doom_clock" or ".clock." in key:
		return 0
	if key.begins_with("global.rep.") or key.begins_with("global.bond."):
		return 0
	return false

## 按语义标签钳位（07 §2：写入时钳位，不静默）。返回 [值, 是否发生钳位]。
func _clamp_value(key: String, value: Variant) -> Array:
	if key == "global.inv":
		return [_normalize_inv(value), false]
	if key == "global.lore":
		return [_normalize_set(value), false]
	if key.begins_with("global.rep."):
		return _clamp_int(value, REP_MIN, REP_MAX)
	if key == "global.doom_clock" or ".clock." in key:
		return _clamp_int(value, CLOCK_MIN, CLOCK_MAX)
	if key.begins_with("global.bond."):
		return _clamp_int(value, BOND_MIN, BOND_MAX)
	if key == "global.alignment":
		return _clamp_int(value, ALIGNMENT_MIN, ALIGNMENT_MAX)
	return [value, false]

func _clamp_int(value: Variant, lo: int, hi: int) -> Array:
	var v := int(value)
	var c := clampi(v, lo, hi)
	return [c, c != v]

## inv 规整为 {item_id: count>0}；兼容数组（Set 写法）输入。
func _normalize_inv(value: Variant) -> Dictionary:
	var out := {}
	if value is Dictionary:
		for k: Variant in value.keys():
			var n := int(value[k])
			if n > 0:
				out[str(k)] = n
	elif value is Array:
		for k: Variant in value:
			out[str(k)] = 1
	return out

## Set 语义规整（global.lore，07 §2：Set<lore_id>）：去重字符串数组，JSON 安全。
func _normalize_set(value: Variant) -> Array:
	var out: Array = []
	var src: Array = []
	if value is Array:
		src = value
	elif value is Dictionary:
		src = value.keys()
	for v: Variant in src:
		var s := str(v)
		if not out.has(s):
			out.append(s)
	return out

func _write_inv(new_inv: Dictionary, provenance: Dictionary) -> void:
	var old := get_inv()
	_data["global.inv"] = new_inv.duplicate(true)
	_prov["global.inv"] = provenance.duplicate(true)
	for item_id: String in new_inv.keys():
		var gained: int = int(new_inv[item_id]) - int(old.get(item_id, 0))
		if gained > 0:
			stream.emit(EventTypes.ITEM_GAIN,
				{"item_id": item_id, "count": gained, "total": int(new_inv[item_id]),
					"provenance": provenance.duplicate(true)}, &"board")
	for item_id: String in old.keys():
		var lost: int = int(old[item_id]) - int(new_inv.get(item_id, 0))
		if lost > 0:
			stream.emit(EventTypes.ITEM_REMOVE,
				{"item_id": item_id, "count": lost, "total": int(new_inv.get(item_id, 0)),
					"provenance": provenance.duplicate(true)}, &"board")

## 按语义标签选事件类型（07 §6：状态板每一次变化都对应至少一条事件）。
func _emit_state_event(key: String, old_value: Variant, new_value: Variant, provenance: Dictionary) -> void:
	var type := EventTypes.FLAG_WRITE
	if key == "global.doom_clock" or ".clock." in key:
		type = EventTypes.CLOCK_TICK
	elif key.begins_with("global.rep."):
		type = EventTypes.REP_CHANGE
	elif key.begins_with("global.bond."):
		type = EventTypes.BOND_CHANGE
	elif key == "global.alignment":
		type = EventTypes.ALIGNMENT_SHIFT
	elif key.begins_with("global.entitlement."):
		type = EventTypes.ENTITLEMENT_CHANGE
	elif key == "global.lore":
		type = EventTypes.LORE_UNLOCK
	var payload := {
		"key": key,
		"old": old_value,
		"value": new_value,
		"provenance": provenance.duplicate(true),
	}
	if key == "global.lore" and old_value is Array and new_value is Array:
		var added: Array = []
		for e: Variant in new_value:
			if not (old_value as Array).has(e):
				added.append(e)
		payload["added"] = added
	if old_value is int and new_value is int:
		payload["delta"] = int(new_value) - int(old_value)
	stream.emit(type, payload, &"board")
