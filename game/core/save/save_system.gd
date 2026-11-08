# 存档系统（docs/framework/07-世界状态机规范.md §4）
# - 快照内容（§4.1）：save_version / board 全量 / event_tail 锚点 / bindings（内容包+规则包版本表）/
#   rng 状态 / meta（周目、创建与保存时间戳、进度摘要、图进度、成长数据）——JSON 存 user://saves/；
# - 时机（§4.2）：遭遇结算完成（主快照点）+ 主屏闲置（兜底）+ 主屏手动"记录抄本"；
#   遭遇进行中不存档——本类不感知时机，由调用方（main）在遭遇外调用；☰「保存并回主屏」=
#   回到遭遇进入前快照（09 §7），本类负责快照往返一致性；
# - 兼容（§4.3）：save_version + 迁移链入口；当前 v1 直通，未来版本快照拒绝并明示。
class_name SaveSystem
extends RefCounted

const SAVE_VERSION := 1
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

## 迁移链入口（§4.3）：按 save_version 逐级升级。v1 直通；> 当前版本拒绝（未来存档不降级读取）。
static func migrate(snapshot: Dictionary) -> Dictionary:
	var v := int(snapshot.get("save_version", 0))
	if v <= 0:
		return {"ok": false, "error": "missing save_version"}
	if v > SAVE_VERSION:
		return {"ok": false, "error": "存档来自更新版本（v%d > v%d），请升级游戏" % [v, SAVE_VERSION]}
	# v1 → v1 直通；后续版本在此逐级挂迁移器（框架保持最近 2 个大版本，§4.3）
	return {"ok": true, "snapshot": snapshot}

## 应用快照到运行态：Board 全量 + RNG 状态（事件流锚点由调用方记录，不重演历史）。
static func apply(snapshot: Dictionary, board: Board, rng: Rng) -> void:
	board.deserialize(snapshot.get("board", {}))
	rng.load_state(snapshot.get("rng_seed", {}))

## 便捷：是否存在可读存档。
static func has_save(slot: String = SLOT_DEFAULT) -> bool:
	return FileAccess.file_exists(_path(slot))

static func _path(slot: String) -> String:
	return SAVE_DIR.path_join("%s.json" % slot)
