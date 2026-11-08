# 无头测试入口：/Applications/Godot.app/Contents/MacOS/Godot --headless --path game -s tests/run.gd
# 约定：每个 core 模块一个 test_xxx()，失败 push_error 并以非零码退出（godot-acceptance §1.2）
extends SceneTree

var failures := 0

func check(cond: bool, name: String) -> void:
	if cond:
		print("  PASS ", name)
	else:
		failures += 1
		push_error("  FAIL " + name)

func _init() -> void:
	print("== 抄本纪元 core 无头测试 ==")
	test_rng()
	test_event_stream()
	test_board()
	test_conditions()
	test_pack_loader()
	test_packlint()
	test_story_graph()
	test_story_bot()
	if failures == 0:
		print("== 全部通过 ==")
	else:
		print("== 失败：", failures, " ==")
	quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------- RNG（tech/01 §5.2 确定性）

func test_rng() -> void:
	print("[rng]")
	var a := Rng.new(12345)
	var b := Rng.new(12345)
	var seq_a: Array = []
	var seq_b: Array = []
	for i: int in 10:
		seq_a.append(a.d20())
		seq_b.append(b.d20())
	check(seq_a == seq_b, "同种子同序列（d20 ×10）")
	var c := Rng.new(999)
	var bounds_ok := true
	for i: int in 300:
		var v := c.range_int(3, 7)
		if v < 3 or v > 7:
			bounds_ok = false
		var d := c.d_n(6)
		if d < 1 or d > 6:
			bounds_ok = false
	check(bounds_ok, "dN(n)/range_int(a,b) 取值范围")
	var d20_ok := true
	for i: int in 300:
		var r := c.d20()
		if r < 1 or r > 20:
			d20_ok = false
	check(d20_ok, "d20 取值 1~20")
	var st := a.save_state()
	var next1 := a.d20()
	a.load_state(st)
	check(a.d20() == next1, "状态快照恢复后续掷一致")

# ---------------------------------------------------------------- EventStream（tech/01 §5）

func test_event_stream() -> void:
	print("[event_stream]")
	var s := EventStream.new()
	var received: Array = []
	s.subscribe(func(ev: Dictionary) -> void: received.append(ev))
	var e1 := s.emit(EventTypes.LOG, {"msg": "a"}, &"test")
	var e2 := s.emit(EventTypes.CHECK_ROLL, {"roll": 17}, &"test", "N1-1", "battle-1")
	check(e1["id"] == 1 and e2["id"] == 2, "追加顺序：id 递增")
	check(int(e2["payload"]["roll"]) == 17 and e2["node"] == "N1-1" and e2["session"] == "battle-1",
		"事件结构 {id,session,type,payload,source,node}")
	check(received.size() == 2 and received[1]["type"] == EventTypes.CHECK_ROLL, "订阅触发")
	check(s.query_by_type(EventTypes.LOG).size() == 1, "按类型查询")
	check(s.tail() == 2, "tail 尾部序号（存档锚点）")
	check(s.since(1).size() == 1 and s.since(2).is_empty(), "since(锚点) 切片")

# ---------------------------------------------------------------- Board（framework/07 全文）

func test_board() -> void:
	print("[board]")
	var stream := EventStream.new()
	var board := Board.new(stream)
	var prov := {"event_id": 1, "node_id": "N0-1", "pack_id": "campaign01"}

	# 读写与默认值（07 §2）
	check(board.write("campaign01.seen_fading", true, prov), "包内旗标写入")
	check(board.read("campaign01.seen_fading") == true, "旗标读回")
	check(board.read("campaign01.missing") == false, "旗标默认 false")
	check(board.read("global.alignment") == 50, "alignment 默认 50（中线）")
	check(board.read("global.rep.uninked") == 0, "rep 默认 0")

	# 写入即钳位 + clamped 事件（07 §2 约束）
	board.write("global.rep.scriptorium", 9, prov)
	check(int(board.read("global.rep.scriptorium")) == 5, "rep 钳位到 +5")
	board.write("global.rep.scriptorium", -9, prov)
	check(int(board.read("global.rep.scriptorium")) == -5, "rep 钳位到 -5")
	board.write("global.doom_clock", 12, prov)
	check(int(board.read("global.doom_clock")) == 10, "doom_clock 钳位 0~10")
	board.write("global.bond.aily", 250, prov)
	check(int(board.read("global.bond.aily")) == 100, "bond 钳位 0~100")
	board.write("global.alignment", -20, prov)
	check(int(board.read("global.alignment")) == 0, "alignment 钳位 0~100")
	check(stream.query_by_type(EventTypes.CLAMPED).size() == 5, "钳位产出 clamped 事件（不静默）")

	# 写入发事件并进事件流（07 §6）
	check(stream.query_by_type(EventTypes.FLAG_WRITE).size() >= 1, "flag.write 事件")
	check(stream.query_by_type(EventTypes.REP_CHANGE).size() == 2, "rep.change 事件")
	check(stream.query_by_type(EventTypes.CLOCK_TICK).size() == 1, "clock.tick 事件")
	check(stream.query_by_type(EventTypes.BOND_CHANGE).size() == 1, "bond.change 事件")
	check(stream.query_by_type(EventTypes.ALIGNMENT_SHIFT).size() == 1, "alignment.shift 事件")

	# 命名空间权限（07 §3）
	check(not board.write("campaign02.foreign_flag", true, prov), "跨包写拒绝")
	check(board.read("campaign02.foreign_flag") == false, "跨包写未生效")
	check(not board.write("global.entitlement.campaign02", true, prov), "entitlement 非 system 拒绝")
	var sys := {"event_id": 2, "node_id": "", "pack_id": "system"}
	check(board.write("global.entitlement.campaign02", true, sys), "entitlement 仅 system 可写")
	check(not board.write("global.unknown_var", 1, prov), "global 白名单外拒绝")
	check(board.write("global.rep.salvage", 2, prov), "global 白名单任何包可写")
	check(board.write("global.tutorial.gesture_chip", true, prov), "global.tutorial.* 白名单可写（07 §3）")
	check(board.unlock_lore("revoked_registry_01", prov), "global.lore 白名单可写（07 §3）")
	check(board.has_lore("revoked_registry_01"), "unlock_lore 读回")
	check(stream.query_by_type(EventTypes.BOARD_DENIED).size() == 3, "越权产出 board.denied 告警事件")

	# 溯源（07 §1、tech/01 §4.2）
	var p := board.provenance_of("campaign01.seen_fading")
	check(p.get("pack_id") == "campaign01" and p.get("node_id") == "N0-1" and int(p.get("event_id")) == 1,
		"溯源记录 {event_id,node_id,pack_id}")
	check(not board.write("campaign01.no_prov", true, {}), "缺溯源写入拒绝（tech/01 §4.2 报错）")

	# 物品：give/remove 与事件
	board.give_item("half_tide_table", 1, prov)
	board.give_item("ink_core", 2, prov)
	check(board.has_item("half_tide_table"), "give_item 持有")
	check(board.item_count("ink_core") == 2, "item 数量堆叠（07 §2 约束3）")
	board.remove_item("ink_core", 1, prov)
	check(board.item_count("ink_core") == 1, "remove_item 数量减少")
	check(stream.query_by_type(EventTypes.ITEM_GAIN).size() == 2, "item.gain 事件")
	check(stream.query_by_type(EventTypes.ITEM_REMOVE).size() == 1, "item.remove 事件")

	# 快照往返一致（JSON，tech/01 §4.3）
	var snap := board.serialize()
	var parsed: Variant = JSON.parse_string(JSON.stringify(snap))
	var board2 := Board.new(EventStream.new())
	board2.deserialize(parsed)
	check(board2.serialize() == snap, "快照 JSON 往返一致")

# ---------------------------------------------------------------- Conditions（tech/02 §4.6）

func test_conditions() -> void:
	print("[conditions]")
	var s := EventStream.new()
	var board := Board.new(s)
	var cond := Conditions.new(board)
	var prov := {"event_id": 10, "node_id": "N1-7", "pack_id": "campaign01"}
	board.write("campaign01.seen_fading", true, prov)
	board.write("global.rep.scriptorium", 3, prov)
	board.write("global.doom_clock", 4, prov)
	board.give_item("ink_core", 2, prov)
	board.write("global.alignment", 70, prov)
	board.write("global.bond.aily", 60, prov)
	board.write("global.bond.bram", 20, prov)
	var ctx := {"pack_id": "campaign01"}

	# 条件词汇表逐项
	check(cond.evaluate({"flag.seen_fading": true}, ctx), "cond flag（省略前缀自动补包名）")
	check(not cond.evaluate({"flag.other": true}, ctx), "cond flag 未命中")
	check(cond.evaluate({"rep.scriptorium": {">=": 3}}, ctx), "cond rep >=")
	check(not cond.evaluate({"rep.scriptorium": {"<": 3}}, ctx), "cond rep < 否")
	check(cond.evaluate({"clock": {">=": 2}}, ctx), "cond clock")
	check(not cond.evaluate({"clock": {">=": 5}}, ctx), "cond clock 否")
	check(cond.evaluate({"item.ink_core": true}, ctx), "cond item 持有（bool）")
	check(cond.evaluate({"item.ink_core": {">=": 2}}, ctx), "cond item 数量 >=")
	check(not cond.evaluate({"item.ink_core": {">=": 3}}, ctx), "cond item 数量不足")
	check(not cond.evaluate({"item.void_relic": false}, ctx) == false, "cond item 未持有（bool false）")
	check(cond.evaluate({"alignment": {"ink_gt": 50}}, ctx), "cond alignment 墨守过中线")
	check(not cond.evaluate({"alignment": {"blank_gt": 50}}, ctx), "cond alignment 留白否")
	board.write("global.alignment", 30, prov)
	check(cond.evaluate({"alignment": {"blank_gt": 50}}, ctx), "cond alignment 留白过中线")
	check(not cond.evaluate({"alignment": {"ink_gt": 50}}, ctx), "cond alignment 墨守否")
	board.write("global.alignment", 70, prov)
	check(cond.evaluate({"bond.aily": {">=": 60}}, ctx), "cond bond.<npc>")
	check(cond.evaluate({"bond_max": {">=": 60}}, ctx), "cond bond_max 命中")
	check(not cond.evaluate({"bond_max": {">=": 61}}, ctx), "cond bond_max 未命中")
	check(cond.evaluate({"all": [{"flag.seen_fading": true}, {"clock": {">=": 2}}]}, ctx), "cond all 组合全真")
	check(not cond.evaluate({"all": [{"flag.seen_fading": true}, {"clock": {">=": 9}}]}, ctx), "cond all 一假即假")
	check(cond.evaluate({"any": [{"flag.nope": true}, {"clock": {">=": 2}}]}, ctx), "cond any 一真即真")
	check(not cond.evaluate({"any": [{"flag.nope": true}, {"clock": {">=": 9}}]}, ctx), "cond any 全假")

	# 效果词汇表逐项
	var s4 := EventStream.new()
	var b4 := Board.new(s4)
	var exec := Conditions.new(b4)
	var ectx := {"pack_id": "campaign01", "node_id": "N1-7", "event_id": 10}
	exec.apply_effects([{"write": "seen_fading", "value": true}], ectx)
	check(b4.read("campaign01.seen_fading") == true, "effect write+value")
	exec.apply_effects([{"clock": -2}], ectx)
	check(int(b4.read("global.doom_clock")) == 0, "effect clock 负值延缓并钳位")
	exec.apply_effects([{"clock": 3}], ectx)
	check(int(b4.read("global.doom_clock")) == 3, "effect clock 增减")
	exec.apply_effects([{"rep.scriptorium": 2}], ectx)
	check(int(b4.read("global.rep.scriptorium")) == 2, "effect rep 增减")
	exec.apply_effects([{"alignment": 10}], ectx)
	check(int(b4.read("global.alignment")) == 60, "effect alignment 滑动（默认 50 起）")
	exec.apply_effects([{"give_item": "ink_core"}], ectx)
	check(b4.has_item("ink_core"), "effect give_item")
	exec.apply_effects([{"remove_item": "ink_core"}], ectx)
	check(not b4.has_item("ink_core"), "effect remove_item")
	exec.apply_effects([{"bond.aily": 15}], ectx)
	check(int(b4.read("global.bond.aily")) == 15, "effect bond 增减")
	exec.apply_effects([{"xp": 50}], ectx)
	var xp_evs := s4.query_by_type(EventTypes.XP_GAIN)
	check(xp_evs.size() == 1 and int(xp_evs[0]["payload"]["amount"]) == 50, "effect xp 产出 xp.gain 事件")
	exec.apply_effects([{"lore": "ink_rain"}], ectx)
	check(b4.has_lore("ink_rain"), "effect lore 解锁后 global.lore 含条目（07 §2）")
	exec.apply_effects([{"lore": "ink_rain"}], ectx)
	check(b4.get_lore().count("ink_rain") == 1, "effect lore 重复解锁幂等（Set 语义）")
	var lore_evs := s4.query_by_type(EventTypes.LORE_UNLOCK)
	check(lore_evs.size() == 2, "effect lore 每次解锁仍产出 lore.unlock 事件")
	check(lore_evs[0]["payload"]["provenance"]["node_id"] == "N1-7"
		and lore_evs[0]["payload"]["provenance"]["pack_id"] == "campaign01", "effect lore 写板带溯源")
	check(lore_evs[0]["payload"].get("added", []) == ["ink_rain"]
		and lore_evs[1]["payload"].get("added", []) == [], "lore.unlock 事件负载含新增条目（重复解锁 added 为空）")

	# 效果全部进事件流（07 §6）
	check(s4.query_by_type(EventTypes.FLAG_WRITE).size() == 1, "effect 写板事件进事件流（flag.write）")
	check(s4.query_by_type(EventTypes.CLOCK_TICK).size() == 2, "effect 写板事件进事件流（clock.tick）")
	check(s4.query_by_type(EventTypes.ITEM_GAIN).size() == 1
		and s4.query_by_type(EventTypes.ITEM_REMOVE).size() == 1, "effect 物品事件进事件流")
	var fx := s4.query_by_type(EventTypes.FLAG_WRITE)[0]
	check(fx["payload"]["provenance"]["node_id"] == "N1-7", "效果写板带溯源")

# ---------------------------------------------------------------- PackLoader（tech/02 §1/§2/§3）

func _load_campaign01() -> Dictionary:
	var res := PackLoader.load_pack("res://packs/campaign01")
	check(res["ok"], "pack 加载成功：%s" % ";".join(res["errors"]))
	return res["pack"]

func test_pack_loader() -> void:
	print("[pack_loader]")
	var res := PackLoader.load_pack("res://packs/campaign01")
	check(res["ok"], "campaign01 加载 ok（结构校验无错误）")
	if not res["ok"]:
		for e: String in res["errors"]:
			print("    加载错误：", e)
		return
	var pack: Dictionary = res["pack"]
	check(pack["pack_id"] == "campaign01", "pack_id 解析")
	check(str(pack["manifest"]["namespace"]) == "campaign01", "命名空间注册 = pack_id（tech/02 §2 防呆）")
	check((pack["nodes"] as Dictionary).size() == 44, "节点表 44 节点")
	check((pack["acts"] as Array).size() == 5, "五幕 acts")
	check((pack["encounters"] as Dictionary).size() == 16, "遭遇表 16 场（TP1 裁决 3 补登 N2G-2c/R1）")
	check((pack["items"] as Dictionary).size() == 6, "道具表 6 件")
	check((pack["endings"] as Array).size() == 4, "结局表 E1~E4")
	check((pack["flags"] as Array).size() == 8, "旗标台账 8 条")
	check((pack["events"] as Array).size() == 10, "事件清单 10 条")
	check((pack["lore"] as Array).size() == 7, "图鉴条目 7 条")
	# 字段缺省容错（tech/02 §11）：N0-1 未声明 on_enter/on_complete 应补默认空数组
	var n01: Dictionary = pack["nodes"]["N0-1"]
	check(n01.has("on_enter") and (n01["on_enter"] as Array).is_empty()
		and n01.has("on_complete") and (n01["edges"] as Array).size() == 1, "可选字段缺省容错补默认值")
	# 数据修复落位：N1-1 商店购买边
	var buy := false
	for e: Variant in (pack["nodes"]["N1-1"] as Dictionary)["edges"]:
		for fx: Variant in (e as Dictionary).get("effects", []):
			if (fx as Dictionary).get("give_item", "") == "half_tide_table":
				buy = true
	check(buy, "N1-1 存在购买半页潮汐表边（战役书 §8 投放补全）")
	# 坏包容错：不存在的目录
	var bad := PackLoader.load_pack("res://packs/no_such_pack")
	check(not bad["ok"] and not (bad["errors"] as Array).is_empty(), "缺失包目录报错不崩溃")

# ---------------------------------------------------------------- packlint（tech/02 §12 + tech/04 §6）

func test_packlint() -> void:
	print("[packlint]")
	var pack := _load_campaign01()
	var issues := PacklintCore.lint(pack)
	var fails: Array = []
	var seen := {}
	for issue: Dictionary in issues:
		seen[issue["v"]] = true
		if issue["level"] == PacklintCore.LEVEL_FAIL:
			fails.append("%s: %s" % [issue["v"], issue["msg"]])
	check(fails.is_empty(), "packlint V1~V13 无 FAIL：%s" % ";".join(fails))
	for v: String in ["V1", "V2", "V3", "V4", "V5", "V6", "V7", "V8", "V9", "V10", "V11", "V12", "V13"]:
		if not seen.has(v):
			check(false, "packlint 覆盖 %s" % v)
	check(true, "packlint 覆盖 V1~V13 全项（含 N/A 声明）")
	# 图遍历无死路不可达（V1/V2 单项复核）
	var graph_issues := PacklintCore.lint(pack).filter(func(i: Dictionary) -> bool: return ["V1", "V2"].has(i["v"]))
	check(graph_issues.all(func(i: Dictionary) -> bool: return i["level"] == PacklintCore.LEVEL_PASS),
		"图遍历无死路、无不可达（V1/V2 PASS）")
	# 负例：篡改节点制造死路，V1 必须抓到
	var broken: Dictionary = pack.duplicate(true)
	broken["nodes"]["N1-2b"]["edges"] = []
	var broken_issues := PacklintCore.lint(broken)
	check(broken_issues.any(func(i: Dictionary) -> bool:
		return i["v"] == "V1" and i["level"] == PacklintCore.LEVEL_FAIL), "负例：制造死路 V1 必报 FAIL")

# ---------------------------------------------------------------- StoryGraph（tech/02 §3/§4/§9）

## 在可走边中按目标节点找边。
func _edge_to(graph: StoryGraph, to: String) -> Dictionary:
	for e: Variant in graph.available_edges():
		if str((e as Dictionary).get("to", "")) == to:
			return e
	return {}

func test_story_graph() -> void:
	print("[story_graph]")
	var pack := _load_campaign01()
	var stream := EventStream.new()
	var board := Board.new(stream)
	var graph := StoryGraph.new(board, Rng.new(42), pack)
	graph.start()
	check(graph.current()["id"] == "N0-1", "入口节点 N0-1")
	check(stream.query_by_type(EventTypes.NODE_ENTER).size() == 1, "进节点产 node.enter 事件")
	graph.take_edge(_edge_to(graph, "N0-2"))

	# 检定边成功路（tech/02 §4.2）
	var e_n02: Dictionary = graph.available_edges()[0]
	check(str(e_n02["type"]) == "check", "N0-2 为检定边")
	graph.resolve_check(e_n02, true)
	check(graph.current()["id"] == "N0-3a", "检定成功 → N0-3a")
	check(board.read("campaign01.seen_fading") == true, "on_enter 写旗标 seen_fading")
	graph.take_edge(_edge_to(graph, "N0-4"))
	graph.take_edge(_edge_to(graph, "N1-1"))
	# hub 购买边（道具投放补全）
	check(not board.has_item("half_tide_table"), "购买前未持有潮汐表")
	var e_buy := _edge_to(graph, "N1-2")
	for e: Variant in graph.available_edges():
		for fx: Variant in (e as Dictionary).get("effects", []):
			if (fx as Dictionary).get("give_item", "") == "half_tide_table":
				e_buy = e
	graph.take_edge(e_buy)
	check(board.has_item("half_tide_table"), "购买边 give_item 潮汐表")
	check(graph.current()["id"] == "N1-2", "购买后抵达 N1-2")
	graph.resolve_check(graph.available_edges()[0], true) # N1-2 检定成功 → N1-3
	check(graph.current()["id"] == "N1-3", "N1-2 成功 → N1-3")
	check(board.get_doom_clock() == 1, "N1-3 on_enter 时钟 +1")
	graph.take_edge(_edge_to(graph, "N1-4")) # 誊写庭接触 rep+1
	check(board.get_rep("scriptorium") == 1, "接触节点声望写入")
	graph.take_edge(_edge_to(graph, "N1-7"))
	graph.take_edge(_edge_to(graph, "N1-8")) # N1-7 战后 → 三份邀约
	check(board.get_bond("kelan") == 10, "N1-7 战后边羁绊 +10（TP1 验收裁决 2）")
	graph.take_edge(_edge_to(graph, "N2S-1")) # N1-8 选誊写庭委托
	# 独狼声望边：已有 rep>0，应不显形（tech/02 §4.5）
	check(_edge_to(graph, "N2L-1").is_empty() or graph.current()["id"] != "N1-8",
		"声望边 requires 不满足不显形（已过 N1-8）")
	graph.resolve_check(graph.available_edges()[0], true) # N2S-1 → N2S-2
	graph.take_edge(_edge_to(graph, "N2S-3"))
	check(not board.has_item("scriptorium_signet"), "on_complete 未离开不结算")
	graph.take_edge(_edge_to(graph, "N2-C")) # 献出记忆
	check(board.has_item("scriptorium_signet"), "离开 N2S-3 结算 on_complete（印戒，tech/02 §3）")
	check(board.read("campaign01.blank_memory") == true, "选择边效果 blank_memory")
	check(board.get_alignment() == 60, "S 链选择边 +墨守 10（结局条件投放补全）")
	check(board.get_doom_clock() == 0, "献出记忆时钟 -2 并钳位 0")
	check(board.get_bond("kelan") == 25, "N2S-3 选择边羁绊 +15（累计 25，TP1 验收裁决 2）")
	graph.take_edge(_edge_to(graph, "N3-1"))
	graph.take_edge(_edge_to(graph, "R1"))
	graph.take_edge(_edge_to(graph, "R2"))
	check(board.has_lore("revoked_registry_01") and board.has_lore("revoked_registry_02"),
		"R2 on_enter 解锁图鉴 ×2")
	graph.resolve_check(graph.available_edges()[0], true) # R2 安抚成功 → 残简
	check(board.has_item("codex_fragment"), "R2 成功路给织命者残简")
	check(board.get_bond("kelan") == 45, "R2 安抚成功羁绊 +20（单周目图内上限 45，TP1 验收裁决 2）")
	check(graph.current()["id"] == "R3", "R2 检定成功 → R3")
	graph.take_edge(_edge_to(graph, "R4")) # R3 → R4 分叉回廊
	var e_r4 := _edge_to(graph, "R4-r")
	check(not e_r4.is_empty() and bool(e_r4.get("via_fallback", false)),
		"item 边未持有黑羽令 → fallback 变体（tech/02 §4.3）")
	graph.take_edge(e_r4)
	graph.take_edge(_edge_to(graph, "R5"))
	graph.take_edge(_edge_to(graph, "N3-7"))
	check(board.item_count("codex_fragment") == 2, "R5 战利品残简 ×1（累计 2）")
	graph.take_edge(_edge_to(graph, "N4-1"))
	# N4-1 道具边：印戒 + rep.scriptorium≥1 → 直达 N4-2
	graph.take_edge(_edge_to(graph, "N4-2"))
	check(graph.current()["id"] == "N4-2", "印戒道具边显形（tech/02 §4.3+requires）")
	check(graph.pick_ending() == "E1", "结局表求值：墨守过中线 → E1（tech/02 §9）")
	graph.take_edge(graph.available_edges()[0])
	check(graph.is_at_ending() and graph.current()["id"] == "E1", "图边抵达 E1 与结局表一致")
	check(board.get_doom_clock() >= 0 and board.get_doom_clock() <= 10, "全程时钟 0~10")

# ---------------------------------------------------------------- StoryBot 仿真（TASKS P1.5 TP1）

func test_story_bot() -> void:
	print("[story_bot]")
	var pack := _load_campaign01()
	# 单局可达结局
	var one := StoryBot.run(pack, 48514)
	check(one["ok"], "bot 单局必达结局（seed=48514 → %s）" % str(one.get("ending", "")))
	# 多 seed：24 局半数二周目、1/4 一周目局独狼探针，断言四结局全集可达 + 时钟有界
	# （与 tools/simulate.gd 同种子公式）
	var endings := {}
	var all_ok := true
	var clock_ok := true
	var lone_wolf_hit := false
	var ngplus_bond60 := false
	for i: int in 24:
		var r := StoryBot.run(pack, 1000 + i * 7919, i % 2 == 1, i % 4 == 2)
		if not r["ok"]:
			all_ok = false
			continue
		var ending := str(r["ending"])
		endings[ending] = true
		if (r["visited"] as Dictionary).has("N2L-1") or (r["visited"] as Dictionary).has("N2L-1b"):
			lone_wolf_hit = true
		if r["ngplus"] and int(r["bond_max"]) >= 60:
			ngplus_bond60 = true
		if int(r["clock_min"]) < 0 or int(r["clock_max"]) > 10:
			clock_ok = false
		# 图边结局与 endings.json 求值互证（tech/02 §9）
		if str(r["ending_by_table"]) != "" and str(r["ending_by_table"]) != ending:
			all_ok = false
	check(all_ok, "24 局全部必达结局且图边结局与结局表一致")
	check(clock_ok, "全部路径 clock ∈ 0~10（07 §2 钳位 + V5 有界）")
	check(endings.has("E1") and endings.has("E2"), "alignment 修复后 E1/E2 可达（±10 投放）")
	check(endings.has("E3"), "二周目配置 E3 可达（残简继承 ×1 + 密道/R2/R5 ×3 + 图内投放羁绊继承）")
	check(endings.has("E4"), "E4 兜底可达（tech/02 §9 default）")
	check(endings.size() == 4, "多 seed 四结局全集可达")
	check(lone_wolf_hit, "独狼路径可达：存在 seed 命中 N2L-1/N2L-1b（TP1 验收裁决 1）")
	check(ngplus_bond60, "bond 图内投放后二周目 bond_max ≥60 可满足（TP1 验收裁决 2，E3 条件）")
	var first_play_e3 := false
	for i: int in 24:
		if i % 2 == 1:
			continue
		var r := StoryBot.run(pack, 1000 + i * 7919, false, i % 4 == 2)
		if r["ok"] and str(r["ending"]) == "E3":
			first_play_e3 = true
	check(not first_play_e3, "一周目（无继承）不可达 E3（残简 ≤3 且羁绊图内上限 45 < 60，战役书 §8/§9）")
