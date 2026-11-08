# 节点流程视图模型 + 故事侧事件文案（双壳共用内容源；godot-dev §7：禁止复制两份横/竖逻辑）
# 壳只渲染本模块产出的纯数据 Dictionary / 文案字符串；图状态一律经 StoryGraph 只读 API 取（§2 铁律）。
class_name StoryVM
extends RefCounted

const FUTURE_PREVIEW := 4 # 推进条未来房间预告格数（04 §④.2：未来房间只显示门剪影）

## 当前节点完整视图模型：双壳 show_story(vm) 唯一输入。
static func build(graph: StoryGraph, board: Board, pack: Dictionary) -> Dictionary:
	var node := graph.current()
	var nid := graph.current_id
	var vm := {
		"id": nid,
		"type": str(node.get("type", "")),
		"title": str(node.get("title", nid)),
		"text": str(node.get("summary", "")), # tech/02 §3：title/summary 为节点显示文本（无段落字段，见交付留白）
		"clock": board.get_doom_clock(),
		"forecast": graph.next_clock_trigger(),   # 最近逼近项（状态栏带角标）
		"forecasts": graph.clock_forecasts(),      # 全部逼近项（时间钟弹层，04 §3.1）
		"party": graph.party_status(),             # 队伍 HP 概览（04 §3.1）
		"quest_badge": graph.quest_badge_count(),  # 事件中心角标（04 §⑤）
		"edges": [],
		"rooms": [], "room_index": 0, "room_titles": {},
	}
	if str(node.get("type", "")) == "hub":
		vm["gold"] = graph.get_gold()
		vm["stock"] = graph.hub_stock()
		var rumors: Array = []
		for r: Variant in graph.hub_rumors():
			rumors.append(rumor_text(r))
		vm["rumors"] = rumors
	for e: Variant in graph.available_edges():
		(vm["edges"] as Array).append(edge_display(e, graph, pack))
	# 推进条：已访房间（visit_log）+ 未来预告（沿首条边纯数据预览，不触碰图状态）
	var rooms: Array = graph.visit_log.duplicate()
	var titles := {}
	for rid: Variant in rooms:
		titles[str(rid)] = str((pack["nodes"] as Dictionary).get(str(rid), {}).get("title", str(rid)))
	for fid: String in _future_rooms(pack, nid, FUTURE_PREVIEW):
		rooms.append(fid)
		titles[fid] = str((pack["nodes"] as Dictionary).get(fid, {}).get("title", fid))
	vm["rooms"] = rooms
	vm["room_index"] = graph.visit_log.size() - 1
	vm["room_titles"] = titles
	return vm

## 选项/检定按钮文案：检定带技能·难度·DC·修正（04 §④.3 检定房一键快掷）；
## 触及声望的选项带 faction 角标（任务书：对话选项带声望角标；数据来源 = 边效果 ∪ 目标节点 on_enter ∪ requires）。
static func edge_display(e: Dictionary, graph: StoryGraph, pack: Dictionary) -> Dictionary:
	var d := {"type": str(e.get("type", "")), "label": str(e.get("label", ""))}
	if d["type"] == "check":
		var skill := str(e.get("skill", ""))
		var diff := str(e.get("difficulty", "medium"))
		d["label"] = "%s：%s（%s DC %d · 修正 %+d）" % [TextsZh.STORY_CHECK,
			str(TextsZh.SKILL_NAMES.get(skill, skill)), str(TextsZh.DIFF_NAMES.get(diff, diff)),
			LightV1.dc_for(diff), graph.check_mod(skill)]
		d["check"] = true
	if d["label"].is_empty():
		d["label"] = TextsZh.STORY_CONTINUE
	var factions: Array = []
	var scan: Array = (e.get("effects", []) as Array).duplicate()
	scan.append(e.get("requires", {}))
	var target: Dictionary = (pack["nodes"] as Dictionary).get(str(e.get("to", "")), {})
	scan.append_array(target.get("on_enter", []))
	for fx: Variant in scan:
		if not (fx is Dictionary):
			continue
		for k: Variant in (fx as Dictionary).keys():
			var ks := str(k)
			if ks.begins_with("rep."):
				var f := ks.substr(4)
				if not factions.has(f):
					factions.append(f)
	var badges: Array = []
	for f: String in factions:
		badges.append("%s %+d" % [str(TextsZh.FACTION_NAMES.get(f, f)), graph.board.get_rep(f)])
	if not badges.is_empty():
		d["label"] += "　〔%s〕" % " ".join(badges)
	return d

## 传闻文案：只复述事件清单中已登记的名称/目标（不再创作，tech/02 §5 数据源）。
static func rumor_text(def: Dictionary) -> String:
	return "传闻：有人说起「%s」——%s。" % [str(def.get("name", "")), str(def.get("objective", ""))]

## 未来房间预览：沿每个节点首条边（check 取 success 目标）纯数据行走，不实例化、不写板。
static func _future_rooms(pack: Dictionary, from_id: String, limit: int) -> Array[String]:
	var out: Array[String] = []
	var cur := from_id
	var guard := 0
	while out.size() < limit and guard < 32:
		guard += 1
		var node: Dictionary = (pack["nodes"] as Dictionary).get(cur, {})
		var edges: Array = node.get("edges", [])
		if edges.is_empty():
			break
		var e: Dictionary = edges[0]
		var to := str(e.get("to", e.get("success", "")))
		if to.is_empty() or to == cur:
			break
		out.append(to)
		cur = to
	return out

## 状态反馈 toast 文案（事件流驱动，双壳同源）：返回 "" = 不产生 toast。
## 簿记键（成长/金币/HP/模式选择）不打扰玩家（与 04 §⑨ 结算过滤同一口径）。
static func toast_text(ev: Dictionary, pack: Dictionary = {}) -> String:
	var p: Dictionary = ev.get("payload", {})
	match StringName(ev["type"]):
		EventTypes.FLAG_WRITE:
			var key := str(p.get("key", ""))
			if key.begins_with("global.growth.") or key.begins_with("campaign01.attr") \
					or key == "campaign01.xp_total" \
					or key == "campaign01.level" or key == "campaign01.gold" \
					or key.begins_with("campaign01.hp.") or key.begins_with("global.mode_choice."):
				return ""
			return "旗标更新：%s" % key
		EventTypes.REP_CHANGE:
			var f := str(p.get("key", "")).trim_prefix("global.rep.")
			return "声望：%s %+d（%d）" % [str(TextsZh.FACTION_NAMES.get(f, f)),
				int(p.get("delta", 0)), int(p.get("value", 0))]
		EventTypes.ITEM_GAIN:
			var iid := str(p.get("item_id", ""))
			var name := str((pack.get("items", {}) as Dictionary).get(iid, {}).get("name", iid)) \
				if not pack.is_empty() else iid
			return "获得：%s ×%d" % [name, int(p.get("count", 1))]
		EventTypes.ITEM_REMOVE:
			var iid2 := str(p.get("item_id", ""))
			var name2 := str((pack.get("items", {}) as Dictionary).get(iid2, {}).get("name", iid2)) \
				if not pack.is_empty() else iid2
			return "消耗：%s ×%d" % [name2, int(p.get("count", 1))]
		EventTypes.QUEST_TRIGGER:
			return "事件触发：%s" % str(p.get("name", p.get("id", "")))
		EventTypes.QUEST_SETTLE:
			return "事件完结：%s" % str(p.get("name", p.get("id", "")))
		EventTypes.LORE_UNLOCK:
			var added: Array = p.get("added", [])
			return "" if added.is_empty() else "图鉴新增：%s" % "、".join(added)
		EventTypes.LOG:
			# 内容侧显式标记 toast 的日志（hub 传闻/休整等）上浮为 toast
			return str(p.get("msg", "")) if bool(p.get("toast", false)) else ""
	return ""
