# 整备（docs/framework/09-遭遇与双模式交互规范.md §9.1；docs/tech/02-内容包格式规范.md §2.4）
# - 战斗遭遇进场前的整备：技能备选 / 道具携带 / 未分配属性点三块；确认后进入进场态；
# - 限制与否、槽位数量全部由配置决定（manifest `loadout`，遭遇级同名块可覆盖；未声明 = 不启用）——
#   框架只执行，不做硬编码假设（tech/02 §2.4）；
# - 确认选择写入事件流 `loadout.confirm`（09 §9.1：历史卷轴可追溯"这局带了什么"）。
class_name Loadout
extends RefCounted

## 解析生效配置：遭遇级覆盖优先于战役级（tech/02 §2.4）。返回 {} = 不启用整备。
static func resolve_config(pack: Dictionary, encounter_id: String = "") -> Dictionary:
	var cfg: Dictionary = (pack.get("manifest", {}) as Dictionary).get("loadout", {})
	if encounter_id != "" and (pack.get("encounters", {}) as Dictionary).has(encounter_id):
		var enc: Dictionary = pack["encounters"][encounter_id]
		if enc.has("loadout"):
			cfg = (enc["loadout"] as Dictionary).merged(cfg, false) # 覆盖键以遭遇级为准
	if cfg.is_empty() or not bool(cfg.get("enabled", false)):
		return {}
	return cfg

## 校验选择是否满足槽位限制。返回 "" = 合法，否则拒绝原因（与 command.rejected 同款字符串语义）。
static func validate(config: Dictionary, picked_skills: Array, picked_items: Array) -> String:
	var skill_slots := int(config.get("skill_slots", 0))
	var item_slots := int(config.get("item_slots", 0))
	if picked_skills.size() > skill_slots:
		return "skill_slots_exceeded"
	if picked_items.size() > item_slots:
		return "item_slots_exceeded"
	return ""

## 确认整备：发 loadout.confirm 事件（09 §9.1）。返回选择副本（供战斗 def 组装）。
static func confirm(stream: EventStream, config: Dictionary, picked_skills: Array,
		picked_items: Array, attr_alloc: Dictionary, node_id: String, pack_id: String) -> Dictionary:
	var selection := {
		"skills": picked_skills.duplicate(),
		"items": picked_items.duplicate(),
		"attr_alloc": attr_alloc.duplicate(true),
		"skill_slots": int(config.get("skill_slots", 0)),
		"item_slots": int(config.get("item_slots", 0)),
		"source": &"player",
	}
	stream.emit(EventTypes.LOADOUT_CONFIRM, selection, &"core", node_id)
	return selection
