# 存档系统（docs/framework/07-世界状态机规范.md §4）
# - 快照内容（§4.1）：save_version / board 全量 / event_tail 锚点 / bindings（内容包+规则包版本表）/
#   rng 状态 / meta（周目、创建与保存时间戳、进度摘要、图进度、成长数据）——JSON 存 user://saves/；
# - 时机（§4.2）：遭遇结算完成（主快照点）+ 主屏闲置（兜底）+ 主屏手动"记录抄本"；
#   遭遇进行中不存档——本类不感知时机，由调用方（main）在遭遇外调用；☰「保存并回主屏」=
#   回到遭遇进入前快照（09 §7），本类负责快照往返一致性；
# - 兼容（§4.3）：save_version + 迁移链逐级升级；当前 v2 直通，v1→v2 迁移器 = 旧包内成长簿记键
#   （<pack>.xp_total/level/attr_points/attrs/attr_granted）并入 global.growth.*（tech/04 §8 规则4，
#   迁移链首用例）；未来版本快照拒绝并明示。
class_name SaveSystem
extends RefCounted

const SAVE_VERSION := 2
const SAVE_DIR := "user://saves"
const SLOT_DEFAULT := "slot1"

## 汇总快照。graph_state 由 StoryGraph.serialize() 提供（进度摘要落 meta，07 §4.1）。
static func make_snapshot(board: Board, stream: EventStream, rng: Rng,
		bindings: Dictionary, meta: Dictionary) -> Dictionary:
	var m := meta.duplicate(true)
	m["saved_at"] = Time.get_datetime_string_from_system(false, true)
	return {
		"save_version": SAVE_VERSION,
		"board": board.serialize(),
		"event_tail": stream.tail(),
		"bindings": bindings.duplicate(true),
		"rng_seed": rng.save_state(),
		"meta": m,
	}

## 写盘（JSON）。返回是否成功。
static func write(snapshot: Dictionary, slot: String = SLOT_DEFAULT) -> bool:
	var err := DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	if err != OK:
		push_error("SaveSystem: 创建存档目录失败 err=%d" % err)
		return false
	var f := FileAccess.open(_path(slot), FileAccess.WRITE)
	if f == null:
		push_error("SaveSystem: 无法写入 %s err=%d" % [_path(slot), FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(snapshot))
	f.close()
	return true

## 读档：{ok, snapshot} 或 {ok:false, error}。无档不算错误（ok:false, error="empty"）。
static func read(slot: String = SLOT_DEFAULT) -> Dictionary:
	if not FileAccess.file_exists(_path(slot)):
		return {"ok": false, "error": "empty"}
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path(slot)))
	if raw == null or not (raw is Dictionary):
		return {"ok": false, "error": "corrupt"}
	return {"ok": true, "snapshot": raw}

## 迁移链入口（§4.3）：按 save_version 逐级升级。v2 直通；> 当前版本拒绝（未来存档不降级读取）。
static func migrate(snapshot: Dictionary) -> Dictionary:
	var v := int(snapshot.get("save_version", 0))
	if v <= 0:
		return {"ok": false, "error": "missing save_version"}
	if v > SAVE_VERSION:
		return {"ok": false, "error": "存档来自更新版本（v%d > v%d），请升级游戏" % [v, SAVE_VERSION]}
	var s := snapshot
	while v < SAVE_VERSION: # 逐级升级（框架保持最近 2 个大版本，§4.3）
		match v:
			1:
				s = _migrate_v1_to_v2(s)
			_:
				return {"ok": false, "error": "无 v%d 迁移器" % v}
		v += 1
	return {"ok": true, "snapshot": s}

## v1→v2（tech/04 §8 规则4）：旧包内成长簿记键并入 global.growth.* 后删除旧键。
## xp_total → growth.xp（累加）；level → growth.level（与门槛表重算取大，防漏升）；
## attr_points → growth.attr_points（累加；旧档缺 level 键 = 升级点从未发放，按重算等级补发）；
## attrs 字典 → growth.attrs.<attr> 平铺键（累加）；attr_granted 簿记废止（新制升级即发放）。
static func _migrate_v1_to_v2(snapshot: Dictionary) -> Dictionary:
	var s := snapshot.duplicate(true)
	s["save_version"] = 2
	var board: Dictionary = (s.get("board", {}) as Dictionary).duplicate(true)
	var data: Dictionary = board.get("data", {})
	var prov: Dictionary = board.get("provenance", {})
	var xp := int(data.get("campaign01.xp_total", 0))
	var had_level_key: bool = data.has("campaign01.level")
	var lv := int(data.get("campaign01.level", 1))
	var points := int(data.get("campaign01.attr_points", 0))
	var attrs: Dictionary = (data.get("campaign01.attrs", {}) as Dictionary)
	if xp > 0:
		data["global.growth.xp"] = int(data.get("global.growth.xp", 0)) + xp
		lv = maxi(lv, LightV1.level_for_xp(xp)) # 门槛表重算取大（11 §6；防旧档漏升）
	if xp > 0 or had_level_key:
		if not had_level_key:
			points += (lv - 1) * LightV1.LEVEL_ATTR_POINTS # 旧档从未发放的升级点补发
		data["global.growth.level"] = maxi(lv, int(data.get("global.growth.level", 1)))
	if points != 0:
		data["global.growth.attr_points"] = int(data.get("global.growth.attr_points", 0)) + points
	for attr: Variant in attrs.keys():
		var k := "global.growth.attrs.%s" % str(attr)
		data[k] = int(data.get(k, 0)) + int(attrs[attr])
	for old_key: String in ["campaign01.xp_total", "campaign01.level", "campaign01.attr_points",
			"campaign01.attrs", "campaign01.attr_granted"]:
		data.erase(old_key)
		prov.erase(old_key)
	board["data"] = data
	board["provenance"] = prov
	s["board"] = board
	return s

## 应用快照到运行态：Board 全量 + RNG 状态（事件流锚点由调用方记录，不重演历史）。
static func apply(snapshot: Dictionary, board: Board, rng: Rng) -> void:
	board.deserialize(snapshot.get("board", {}))
	rng.load_state(snapshot.get("rng_seed", {}))

## 便捷：是否存在可读存档。
static func has_save(slot: String = SLOT_DEFAULT) -> bool:
	return FileAccess.file_exists(_path(slot))

static func _path(slot: String) -> String:
	return SAVE_DIR.path_join("%s.json" % slot)
