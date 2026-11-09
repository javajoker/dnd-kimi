# 多周目继承执行器（docs/story/02-战役书-烬港残页.md §11 多周目继承清单·定稿；
# docs/tech/02-内容包格式规范.md §2.7 manifest.ngplus 声明块）
# - 唯一继承依据 = 战役包 manifest.ngplus（carries 共通清单 + per_ending 按结局解锁）；
#   本类纯数据驱动消费，不写死任何战役/结局的继承内容——改 manifest 即变。
# - 平衡原则（战役书 §11）：继承给"叙事位置与收集"，不给强度数值——只搬运图鉴/权利/外观/
#   残简/周目数与叙事旗标；成长（global.growth.*）/时间钟/倾向/声望/战利品一律不碰。
# - 触发口径（tech/02 §2.7）：per_ending 以旧板 <ns>.ending_<eid 小写> 旗标判定刚达成的结局，
#   不累加历史结局；已授予的皮肤/权利经 carries 永续（已获不降级，白皮书 §10.4）。
# - 写板溯源：global.* 键仅 system 可写（07 §3 / §3 v1.2），包内旗标/道具/图鉴归战役包命名空间；
#   全部写入经事件流（07 §6），渲染壳只读旗标做演出差异（text_variants，tech/02 §3）。
class_name NgPlus
extends RefCounted

## 执行继承：旧板 old → 新板（cosmetics 须已绑定新板）。conf = manifest.ngplus 块；
## ns = 战役包命名空间（manifest.namespace）。返回簿记 {ending, playthrough, fragments, flags, skin}。
## conf 为空 = 不继承（tech/02 §2.7 缺省语义：重开即全新状态），仍返回空簿记。
static func apply(old: Board, now: Board, stream: EventStream, cosmetics: Cosmetics,
		conf: Dictionary, ns: String) -> Dictionary:
	var out := {"ending": "", "playthrough": 0, "fragments": 0, "flags": [], "skin": ""}
	var sys_prov := {"event_id": stream.tail(), "node_id": "ngplus_boot", "pack_id": "system"}
	var pack_prov := {"event_id": stream.tail(), "node_id": "ngplus_boot", "pack_id": ns}
	var carries: Dictionary = conf.get("carries", {})
	# ---- 共通继承（战役书 §11：图鉴/权利/外观/残简×1/周目数）----
	if bool(carries.get("lore", false)):
		now.write("global.lore", old.get_lore(), pack_prov) # 图鉴保留（07 §2 全局白名单）
	if bool(carries.get("entitlements", false)):
		for key: String in old.keys_with_prefix("global.entitlement."):
			now.write(key, old.read(key), sys_prov) # 权利保留（仅 system 可写，07 §3）
	if bool(carries.get("cosmetics", false)):
		for key: String in old.keys_with_prefix("global.cosmetic."):
			now.write(key, old.read(key), sys_prov) # 外观旗标保留（07 §3 v1.2）
	var fragments := int(carries.get("codex_fragment", 0))
	var play_key := str(carries.get("playthrough", ""))
	if not play_key.is_empty():
		out["playthrough"] = int(old.read(play_key, 0)) + 1
		now.write(play_key, out["playthrough"], pack_prov) # 周目数簿记（07 §4.1 meta 数据源）
	# ---- per_ending 分项解锁（以刚达成的结局为触发，tech/02 §2.7）----
	var per_ending: Dictionary = conf.get("per_ending", {})
	for eid: Variant in per_ending.keys():
		if not bool(old.read("%s.ending_%s" % [ns, str(eid).to_lower()], false)):
			continue
		out["ending"] = str(eid)
		var unlock: Dictionary = per_ending[eid]
		for f: Variant in unlock.get("flags", []):
			var fid := str(f)
			if now.write("%s.%s" % [ns, fid], true, pack_prov):
				(out["flags"] as Array).append(fid)
		fragments += int(unlock.get("codex_fragment", 0)) # E4 追忆：残简再 ×1（战役书 §11）
		var skin_id := str(unlock.get("dice_skin", ""))
		if not skin_id.is_empty() and cosmetics != null:
			# E3 执笔者之骰：授予写 global.cosmetic.owned.*（06 §7 注册表运营侧登记；纯演出）
			if cosmetics.grant(skin_id, {"granted_by": "ngplus", "ending": str(eid)}):
				out["skin"] = skin_id
		break # 一局一结局：命中即停
	if fragments > 0:
		now.give_item("codex_fragment", fragments, pack_prov) # 织命者残简继承（战役书 §8 投放第 4 枚）
	out["fragments"] = fragments
	return out
