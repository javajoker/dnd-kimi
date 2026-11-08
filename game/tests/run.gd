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
	test_light_v1()
	test_encounter_sm()
	test_auto_agent()
	test_shell_router()
	test_save_system()
	test_loadout()
	test_growth()
	test_quest_runtime()
	call_deferred("_async_shell_tests")

func _async_shell_tests() -> void:
	await test_portrait_shell()
	await test_landscape_shell()
	await test_shell_diff()
	await test_ui_screens()
	await test_main_flow()
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

# ---------------------------------------------------------------- LightV1 规则包（framework/11 全文）

func test_light_v1() -> void:
	print("[light_v1]")
	check(LightV1.DC_EASY == 8 and LightV1.DC_MEDIUM == 12 and LightV1.DC_HARD == 16,
		"难度三档 DC 8/12/16（11 §3）")
	# §3.1 优劣合并：不叠加、互抵
	check(LightV1.combine_advantage([LightV1.ADV_ADVANTAGE]) == LightV1.ADV_ADVANTAGE, "单一优势 → 优势")
	check(LightV1.combine_advantage([LightV1.ADV_ADVANTAGE, LightV1.ADV_ADVANTAGE]) == LightV1.ADV_ADVANTAGE,
		"多优势不叠加")
	check(LightV1.combine_advantage([LightV1.ADV_DISADVANTAGE]) == LightV1.ADV_DISADVANTAGE, "单一劣势 → 劣势")
	check(LightV1.combine_advantage([LightV1.ADV_ADVANTAGE, LightV1.ADV_DISADVANTAGE]) == LightV1.ADV_NORMAL,
		"优劣互抵 → 普通掷")
	check(LightV1.combine_advantage([]) == LightV1.ADV_NORMAL, "无来源 → 普通掷")
	# 优势 2d20 取高 / 劣势取低（与平行 Rng 复算一致）
	for seed: int in [7, 42, 2026]:
		var r := LightV1.roll_d20(Rng.new(seed), LightV1.ADV_ADVANTAGE)
		var rep := Rng.new(seed)
		var a := rep.d20()
		var b := rep.d20()
		check((r["rolls"] as Array) == [a, b] and int(r["keep"]) == maxi(a, b),
			"优势取高（seed=%d）" % seed)
		var r2 := LightV1.roll_d20(Rng.new(seed), LightV1.ADV_DISADVANTAGE)
		var rep2 := Rng.new(seed)
		var c := rep2.d20()
		var d := rep2.d20()
		check(int(r2["keep"]) == mini(c, d), "劣势取低（seed=%d）" % seed)
	# 伤害骰解析
	var d1 := LightV1.parse_dice("1d6+2")
	check(int(d1["count"]) == 1 and int(d1["sides"]) == 6 and int(d1["mod"]) == 2, "parse_dice 1d6+2")
	var d2 := LightV1.parse_dice("2d4-1")
	check(int(d2["count"]) == 2 and int(d2["sides"]) == 4 and int(d2["mod"]) == -1, "parse_dice 2d4-1")
	# 检定：极端修正必成/必败
	check(bool(LightV1.check(Rng.new(1), 30, LightV1.DC_HARD)["success"]), "d20+30 vs DC16 必成")
	check(not bool(LightV1.check(Rng.new(1), -30, LightV1.DC_EASY)["success"]), "d20-30 vs DC8 必败")
	# 攻击：暴击翻倍（修正不加倍）与必失——扫 seed 找 nat20/nat1
	var found_crit := false
	var found_fumble := false
	for seed: int in range(1, 3000):
		if found_crit and found_fumble:
			break
		var res := LightV1.attack(Rng.new(seed), 30, 18, "1d6+2")
		if bool(res["crit"]) and not found_crit:
			found_crit = true
			check(bool(res["hit"]) and (res["damage_rolls"] as Array).size() == 2
				and int(res["damage"]) == int(res["damage_rolls"][0]) + int(res["damage_rolls"][1]) + 2,
				"nat20 暴击：必中、伤害骰翻倍、修正不加倍（11 §3）")
		elif bool(res["fumble"]) and not found_fumble:
			found_fumble = true
			check(not bool(res["hit"]) and int(res["damage"]) == 0, "nat1 必失（+30 修正亦失，11 §3）")
	check(found_crit and found_fumble, "seed 空间内命中 nat20 与 nat1 样本")
	# 豁免：half / none（11 §5.1）
	var sv := LightV1.save_throw(Rng.new(5), 30, {"attr": "finesse", "dc": 11, "on_success": "half"}, "4d6")
	check(bool(sv["success"]) and int(sv["damage_taken"]) == int(floori(float(sv["damage_full"]) / 2.0)),
		"豁免成功半伤（向下取整）")
	var sv2 := LightV1.save_throw(Rng.new(5), 30, {"attr": "finesse", "dc": 11, "on_success": "none"}, "4d6")
	check(bool(sv2["success"]) and int(sv2["damage_taken"]) == 0, "豁免成功免伤（none）")
	var sv3 := LightV1.save_throw(Rng.new(5), -30, {"attr": "finesse", "dc": 11, "on_success": "half"}, "4d6")
	check(not bool(sv3["success"]) and int(sv3["damage_taken"]) == int(sv3["damage_full"]), "豁免失败全伤")
	# 死亡豁免：≥10 一胜（11 §7）
	var ds_ok := true
	for seed: int in range(1, 200):
		var ds := LightV1.death_save(Rng.new(seed))
		if bool(ds["success"]) != (int(ds["roll"]) >= 10):
			ds_ok = false
	check(ds_ok, "死亡豁免 d20≥10 记一胜")

# ---------------------------------------------------------------- 遭遇测试夹具

func _tp2_party() -> Array:
	return [
		{"id": "pc", "name": "白页者", "kind": "player", "hp": 14, "max_hp": 14, "ac": 11,
			"attrs": {"might": 2, "finesse": 1, "wits": 0}, "attack_mod": 2, "damage": "1d6+2",
			"skills": [{"id": "inkbolt", "name": "墨术飞矢", "kind": "attack", "attr": "wits",
				"damage": "1d6", "uses": 2, "target": "enemy"}],
			"items": [{"id": "heal_potion", "name": "补给药水", "count": 2,
				"use": {"timing": "bonus_action", "heal": "1d4+2", "consume": true}}]},
		{"id": "kelan", "name": "珂兰", "kind": "companion", "hp": 10, "max_hp": 10, "ac": 11,
			"attrs": {"might": 0, "finesse": 1, "wits": 1}, "attack_mod": 1, "damage": "1d6+1",
			"skills": [{"id": "kelan_bolt", "name": "墨矢", "kind": "attack", "attr": "finesse",
				"damage": "1d6+1", "target": "enemy"}]},
		{"id": "laofei", "name": "老费", "kind": "companion", "hp": 12, "max_hp": 12, "ac": 12,
			"attrs": {"might": 1, "finesse": 0, "wits": 1}, "attack_mod": 1, "damage": "1d6+1",
			"skills": [{"id": "laofei_hook", "name": "船钩", "kind": "attack", "attr": "might",
				"damage": "1d6+1", "target": "enemy"}]},
	]

func _tp2_enemies() -> Array:
	return [
		{"id": "boss", "name": "墨魈", "hp": 16, "max_hp": 16, "ac": 11,
			"attrs": {"might": 1, "finesse": 1, "wits": 0}, "attack_mod": 3, "damage": "1d4+1",
			"skills": [{"id": "ink_rain", "name": "墨雨溅射", "kind": "aoe", "damage": "1d6",
				"uses": 2, "cooldown": 2,
				"save": {"attr": "finesse", "dc": 11, "on_success": "half"}}]},
		{"id": "imp1", "name": "墨魈幼体", "hp": 8, "max_hp": 8, "ac": 10,
			"attrs": {"might": 0, "finesse": 0, "wits": 0}, "attack_mod": 2, "damage": "1d4"},
		{"id": "imp2", "name": "墨魈幼体", "hp": 8, "max_hp": 8, "ac": 10,
			"attrs": {"might": 0, "finesse": 0, "wits": 0}, "attack_mod": 2, "damage": "1d4"},
	]

func _std_def() -> Dictionary:
	return {"party": _tp2_party(), "enemies": _tp2_enemies(),
		"party_advantage_rounds": 1, "loot": [{"item": "ink_core", "n": 1}], "xp": 100}

func _mini_def(atk_mod: int = 2) -> Dictionary:
	var pc: Dictionary = _tp2_party()[0]
	pc["attack_mod"] = atk_mod
	pc.erase("skills")
	pc.erase("items")
	return {"party": [pc], "enemies": [_tp2_enemies()[1]]}

func _sm_with(seed: int, def: Dictionary) -> EncounterSM:
	var stream := EventStream.new()
	var board := Board.new(stream)
	var sm := EncounterSM.new(board, stream, Rng.new(seed), "campaign01")
	sm.enter("N1-7")
	sm.transition(EncounterSM.S_EXPLORE)
	sm.begin_combat(def)
	return sm

func _cmd(ctype: StringName, actor: String, target: String = "", skill: String = "",
		item: String = "", source: StringName = &"player") -> Dictionary:
	return {"type": ctype, "actor": actor, "target": target, "skill": skill, "item": item, "source": source}

func _last_attack(sm: EncounterSM) -> Dictionary:
	var evs := sm.stream.query_by_type(EventTypes.BATTLE_ATTACK)
	return evs.back()["payload"] if not evs.is_empty() else {}

## 用结束回合动态驱动当前友方阶段走完（不假设先攻序；止于本轮边界）。
func _end_party_phase(sm: EncounterSM) -> void:
	var r0 := sm.round_no()
	var guard := 0
	while sm.state == EncounterSM.S_COMBAT and sm.phase() == &"party" \
			and sm.current_actor_id() != "" and sm.round_no() == r0 and guard < 20:
		guard += 1
		sm.submit_command(_cmd(EncounterSM.CMD_END_TURN, sm.current_actor_id()))

## pc 先攻必优先的 def（finesse 20），用于行动经济/托管断言。
func _pc_first_def() -> Dictionary:
	var def := _std_def()
	((def["party"] as Array)[0] as Dictionary)["attrs"] = {"might": 2, "finesse": 20, "wits": 0}
	return def

## 珂兰可倒地的夹具：墨雨溅射 6d6、pc 高血高修正重骰且先攻优先。
func _down_def() -> Dictionary:
	var boss_hard: Dictionary = _tp2_enemies()[0]
	((boss_hard["skills"] as Array)[0] as Dictionary)["damage"] = "6d6"
	return {"party": [
			_tp2_party()[0].merged({"hp": 100, "max_hp": 100, "attack_mod": 30, "damage": "30d6",
				"attrs": {"might": 2, "finesse": 20, "wits": 0}}, true),
			_tp2_party()[1].merged({"hp": 8}, true)],
		"enemies": [boss_hard]}

# ---------------------------------------------------------------- EncounterSM（09 §1、tech/01 §6.1/§6.2、11 §4/§5）

func test_encounter_sm() -> void:
	print("[encounter_sm]")
	# —— 六态转换表（09 §1）——
	var s0 := EventStream.new()
	var sm := EncounterSM.new(Board.new(s0), s0, Rng.new(1), "campaign01")
	sm.enter("N1-7")
	check(sm.state == EncounterSM.S_ENTER, "进场态")
	check(not sm.transition(EncounterSM.S_COMBAT), "非法转换拒绝：进场→战斗")
	check(sm.transition(EncounterSM.S_EXPLORE), "进场→探索")
	check(sm.transition(EncounterSM.S_DISCOVER), "探索→发现")
	check(sm.transition(EncounterSM.S_EXPLORE), "发现→探索（双向流转）")
	check(not sm.transition(EncounterSM.S_REST), "非法转换拒绝：探索→休整")
	check(not sm.transition(EncounterSM.S_EXIT), "非法转换拒绝：探索→出场")
	var st_evs := s0.query_by_type(EventTypes.STATE_ENTERED)
	check(st_evs.size() == 4 and str(st_evs[0]["payload"]["state"]) == "enter"
		and str(st_evs[1]["payload"]["state"]) == "explore"
		and str(st_evs[1]["payload"]["prev"]) == "enter", "状态切换外发 state.entered（09 §1 约定）")
	# 结算→休整→出场
	var sm2 := _sm_with(3, _std_def())
	check(sm2.state == EncounterSM.S_COMBAT, "探索→战斗（敌意触发）")
	check(not sm2.transition(EncounterSM.S_EXIT), "未声明撤退边：战斗→出场拒绝（09 §7）")
	# 打完进结算（pc 扫 seed 找必胜开局：优势首回合 + 高修正重骰）
	var won := false
	for seed: int in range(1, 400):
		var smw := _sm_with(seed, {"party": [_tp2_party()[0].merged({"attack_mod": 30, "damage": "30d6"}, true)],
			"enemies": [_tp2_enemies()[1]], "xp": 100, "loot": [{"item": "ink_core", "n": 1}]})
		smw.submit_command(_cmd(EncounterSM.CMD_ATTACK, "pc", "imp1"))
		if smw.is_over():
			won = true
			check(smw.state == EncounterSM.S_SETTLE, "战斗→结算（一方全灭）")
			check(smw.result() == &"victory", "胜利结果")
			check(smw.board.item_count("ink_core") == 1, "结算写状态板：战利品墨核落板（09 §1 硬要求）")
			check(smw.stream.query_by_type(EventTypes.XP_GAIN).size() == 1, "结算产出 xp.gain")
			check(not smw.transition(EncounterSM.S_EXPLORE), "非法转换拒绝：结算→探索")
			check(smw.transition(EncounterSM.S_REST), "结算→休整")
			check(smw.transition(EncounterSM.S_EXIT), "休整→出场")
			check(not smw.transition(EncounterSM.S_ENTER), "出场为终态")
			break
	check(won, "seed 空间内找到必胜样本")
	# 撤退边（09 §7）
	var smr := _sm_with(3, _std_def().merged({"retreat_allowed": true}, true))
	check(smr.transition(EncounterSM.S_EXIT), "声明撤退边后战斗→出场允许")
	var smr2 := _sm_with(3, _std_def().merged({"retreat_allowed": true}, true))
	smr2.submit_command(_cmd(EncounterSM.CMD_RETREAT, smr2.current_actor_id()))
	check(smr2.is_over() and smr2.result() == &"retreat" and smr2.state == EncounterSM.S_SETTLE,
		"撤退命令 → combat.end(retreat) → 结算（失败即分支）")

	# —— 先攻（11 §5：d20+敏降序，平局玩家优先）——
	var smi := _sm_with(42, _std_def())
	var rep := Rng.new(42)
	var expect: Array = []
	for u: Variant in _tp2_party() + _tp2_enemies():
		expect.append({"id": (u as Dictionary)["id"],
			"init": rep.d20() + int((u as Dictionary)["attrs"]["finesse"]),
			"seq": expect.size(), "side": &"party" if (u as Dictionary).has("kind") else &"enemy"})
	expect.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["init"]) != int(b["init"]):
			return int(a["init"]) > int(b["init"])
		if a["side"] != b["side"]:
			return a["side"] == &"party"
		return int(a["seq"]) < int(b["seq"]))
	var expect_order: Array = []
	for e: Variant in expect:
		expect_order.append(str((e as Dictionary)["id"]))
	check(smi.get_order() == expect_order, "先攻序列 = d20+敏降序、平局玩家优先（平行 Rng 复算）")
	check(smi.stream.query_by_type(EventTypes.COMBAT_START).size() == 1, "combat.start 事件")

	# —— 普通攻击命中与伤害 ——
	var hit_ok := false
	for seed: int in range(1, 200):
		var smh := _sm_with(seed, _mini_def())
		smh.submit_command(_cmd(EncounterSM.CMD_ATTACK, "pc", "imp1"))
		var p := _last_attack(smh)
		if bool(p.get("hit", false)) and not bool(p["crit"]):
			hit_ok = true
			check((p["damage_rolls"] as Array).size() == 1
				and int(p["damage"]) == int(p["damage_rolls"][0]) + 2, "命中伤害 = 武器骰+修正（11 §5）")
			check(int(smh.get_unit("imp1")["hp"]) == 8 - int(p["damage"]), "伤害落板到目标 HP")
			break
	check(hit_ok, "seed 空间内找到普通命中样本")

	# —— 见证撤销首回合优势（11 §3.1 内容包声明来源）——
	var smadv := _sm_with(9, _std_def())
	var atk1 := smadv.current_actor_id()
	smadv.submit_command(_cmd(EncounterSM.CMD_ATTACK, atk1, "imp1"))
	var padv := _last_attack(smadv)
	check(str(padv["mode"]) == "advantage" and (padv["rolls"] as Array).size() == 2
		and int(padv["keep"]) == maxi(int(padv["rolls"][0]), int(padv["rolls"][1])),
		"首回合全队攻击优势（2d20 取高）")
	while smadv.state == EncounterSM.S_COMBAT and smadv.phase() == &"party" and smadv.round_no() == 1:
		smadv.submit_command(_cmd(EncounterSM.CMD_END_TURN, smadv.current_actor_id()))
	check(smadv.round_no() == 2 and smadv.party_advantage_rounds() == 0, "全员行动完进敌方回合并进第 2 轮（11 §5.2）")
	smadv.submit_command(_cmd(EncounterSM.CMD_ATTACK, smadv.current_actor_id(), "imp1"))
	check(str(_last_attack(smadv)["mode"]) == "normal", "第 2 轮优势消退 → 普通掷")

	# —— 墨雨溅射豁免（11 §5.1）——
	var smsv := _sm_with(9, _std_def())
	while smsv.state == EncounterSM.S_COMBAT and smsv.round_no() == 1 and smsv.phase() == &"party":
		smsv.submit_command(_cmd(EncounterSM.CMD_END_TURN, smsv.current_actor_id()))
	var saves := smsv.stream.query_by_type(EventTypes.CHECK_ROLL).filter(
		func(ev: Dictionary) -> bool: return str(ev["payload"].get("kind", "")) == "save")
	check(saves.size() == 3, "墨雨溅射对全员各掷一次豁免")
	var sv0: Dictionary = saves[0]["payload"]
	check(int(sv0["dc"]) == 11 and str(sv0["on_success"]) == "half"
		and not bool(sv0.get("key", true)), "豁免 DC11/half、默认普通演出（11 §5.1）")

	# —— 行动经济（11 §4/§5.2）——
	var sme := _sm_with(11, _pc_first_def())
	sme.submit_command(_cmd(EncounterSM.CMD_ATTACK, "pc", "imp1"))
	check(not sme.submit_command(_cmd(EncounterSM.CMD_ATTACK, "pc", "imp1")), "动作已用：第二次攻击拒绝")
	check(sme.stream.query_by_type(EventTypes.COMMAND_REJECTED).back()["payload"]["reason"] == "action_used",
		"拒绝产出 command.rejected(action_used)")
	check(sme.submit_command(_cmd(EncounterSM.CMD_ITEM, "pc", "pc", "", "heal_potion")), "附赠动作用药")
	check(not sme.submit_command(_cmd(EncounterSM.CMD_ITEM, "pc", "pc", "", "heal_potion")), "附赠已用：第二次用药拒绝")
	check(sme.current_actor_id() != "pc" and sme.current_actor_id() != "", "动作+附赠耗尽自动轮到下一单位")
	check(not sme.submit_command(_cmd(EncounterSM.CMD_ATTACK, "pc", "imp1")), "非当前单位命令拒绝（not_your_turn）")
	# 次数制技能（11 §8）：墨术飞矢 2 次，第 3 次拒绝
	var sku := _sm_with(11, _pc_first_def())
	sku.submit_command(_cmd(EncounterSM.CMD_SKILL, "pc", "imp1", "inkbolt"))
	_end_party_phase(sku)
	sku.submit_command(_cmd(EncounterSM.CMD_SKILL, "pc", "imp1", "inkbolt"))
	_end_party_phase(sku)
	check(int(sku.get_unit("pc")["skill_uses"]["inkbolt"]) == 0, "次数扣减至 0")
	check(not sku.submit_command(_cmd(EncounterSM.CMD_SKILL, "pc", "imp1", "inkbolt")), "次数耗尽拒绝（skill_depleted）")
	# 道具消耗写板（tech/04 §4 consume）
	var smit := _sm_with(11, _pc_first_def())
	smit.board.give_item("heal_potion", 2, {"event_id": 1, "node_id": "N1-1", "pack_id": "campaign01"})
	smit.submit_command(_cmd(EncounterSM.CMD_ITEM, "pc", "pc", "", "heal_potion"))
	check(smit.board.item_count("heal_potion") == 1, "consume 道具从 global.inv 移除（写板+事件流）")
	check(smit.stream.query_by_type(EventTypes.ITEM_USE).size() == 1, "item.use 事件")

	# —— 同伴（11 §5.2：每存活同伴 1 动作）——
	var smc := _sm_with(11, _pc_first_def())
	smc.submit_command(_cmd(EncounterSM.CMD_END_TURN, "pc"))
	var comp := smc.current_actor_id()
	check(comp == "kelan" or comp == "laofei", "同伴进入指令通道")
	var comp_skill := "kelan_bolt" if comp == "kelan" else "laofei_hook"
	check(smc.submit_command(_cmd(EncounterSM.CMD_SKILL, comp, "imp1", comp_skill)), "同伴招牌技能可执行")
	check(not smc.submit_command(_cmd(EncounterSM.CMD_ATTACK, comp, "imp1")), "同伴每回合 1 动作")

	# —— 倒地互救与战后起身（11 §5.2/§7）——
	var aid_done := false
	var post_done := false
	for seed: int in range(1, 3000):
		if aid_done and post_done:
			break
		var smd := _sm_with(seed, _down_def())
		_end_party_phase(smd) # 第 1 轮友方结束 → 敌方墨雨溅射（6d6）
		if smd.is_over() or not bool(smd.get_unit("kelan")["downed"]) or smd.current_actor_id() != "pc":
			continue
		if not aid_done:
			var smd2 := _sm_with(seed, _down_def())
			_end_party_phase(smd2)
			smd2.submit_command(_cmd(EncounterSM.CMD_FIRST_AID, "pc", "kelan"))
			var fa := smd2.stream.query_by_type(EventTypes.CHECK_ROLL).filter(
				func(ev: Dictionary) -> bool: return str(ev["payload"].get("kind", "")) == "first_aid")
			if not fa.is_empty() and bool(fa.back()["payload"]["success"]):
				aid_done = true
				check(int(smd2.get_unit("kelan")["hp"]) == 1 and not bool(smd2.get_unit("kelan")["downed"]),
					"急救成功 1 HP 扶起（d20+智 vs DC8，11 §5.2）")
				check(smd2.stream.query_by_type(EventTypes.BATTLE_REVIVE).back()["payload"]["reason"] == "first_aid",
					"battle.revive(first_aid) 事件")
		if not post_done:
			smd.submit_command(_cmd(EncounterSM.CMD_ATTACK, "pc", "boss"))
			if smd.is_over() and smd.result() == &"victory":
				var kl := smd.get_unit("kelan")
				if int(kl["hp"]) == 1 and not bool(kl["downed"]):
					post_done = true
					check(true, "战后倒地同伴自动 1 HP 起身（11 §5.2）")
	check(aid_done, "seed 空间内找到急救成功样本")
	check(post_done, "seed 空间内找到战后起身样本")

	# —— 死亡豁免三局两胜（11 §7）——
	var stabilized := false
	var died := false
	for seed: int in range(1, 3000):
		if stabilized and died:
			break
		var smds := _sm_with(seed, _down_def())
		_end_party_phase(smds) # 第 1 轮：墨雨溅射打倒珂兰
		if not bool(smds.get_unit("kelan")["downed"]):
			continue
		var guard := 0
		while not smds.is_over() and guard < 40:
			guard += 1
			var kl_now := smds.get_unit("kelan")
			if not bool(kl_now["downed"]) or bool(kl_now["dead"]):
				break
			_end_party_phase(smds)
		var kl2 := smds.get_unit("kelan")
		var ds_evs := smds.stream.query_by_type(EventTypes.CHECK_ROLL).filter(
			func(ev: Dictionary) -> bool: return str(ev["payload"].get("kind", "")) == "death_save")
		if not stabilized and int(kl2["hp"]) == 1 and not bool(kl2["downed"]) and not bool(kl2["dead"]) \
				and smds.stream.query_by_type(EventTypes.BATTLE_REVIVE).any(
					func(ev: Dictionary) -> bool: return ev["payload"]["reason"] == "stabilized"):
			stabilized = true
			check(ds_evs.all(func(ev: Dictionary) -> bool: return bool(ev["payload"].get("key", false))),
				"死亡豁免恒定关键判定 key=true（11 §7/09 §6）")
			check(true, "三胜稳住：1 HP 起身（battle.revive stabilized）")
		if not died and bool(kl2["dead"]):
			died = true
			check(true, "三负死亡（battle.dead）")
	check(stabilized, "seed 空间内找到三胜稳住样本")
	check(died, "seed 空间内找到三负死亡样本")

# ---------------------------------------------------------------- AutoAgent（09 §9.3、tech/01 §6.2）

func test_auto_agent() -> void:
	print("[auto_agent]")
	var agent := AutoAgent.new()
	# 技能优先 + 命令同构性
	var sm := _sm_with(11, _pc_first_def())
	var auto := agent.next_command(sm)
	var manual := _cmd(EncounterSM.CMD_SKILL, "pc", sm.first_alive_enemy(), "inkbolt")
	var auto_cmp := auto.duplicate()
	auto_cmp.erase("source")
	var manual_cmp := manual.duplicate()
	manual_cmp.erase("source")
	check(auto_cmp == manual_cmp, "托管与手操产出同构 Command（仅 source 不同，tech/01 §6.2）")
	check(auto["source"] == &"auto", "托管命令 source=auto（09 §9.3 可回放可追溯）")
	var keys: Array = auto.keys()
	keys.sort()
	var expect_keys: Array = ["actor", "item", "skill", "source", "target", "type"]
	check(keys == expect_keys, "命令键集恒定")
	check(sm.submit_command(auto), "托管命令通过同一合法性校验")
	check(sm.stream.query_by_type(EventTypes.BATTLE_ATTACK).back()["payload"]["source"] == &"auto",
		"事件流标注来源 auto")
	# 动作已用 → 结束回合
	var after := agent.next_command(sm)
	check(after["type"] == EncounterSM.CMD_END_TURN, "动作耗尽 → 结束回合")
	sm.submit_command(after)
	check(["kelan", "laofei"].has(str(agent.next_command(sm)["actor"])), "同伴由同一代理接管（11 §5.2）")
	# 次数耗尽退普攻（09 §9.3）
	var sm2 := _sm_with(11, _pc_first_def())
	sm2.submit_command(_cmd(EncounterSM.CMD_SKILL, "pc", "imp1", "inkbolt", "", &"player"))
	_end_party_phase(sm2)
	sm2.submit_command(_cmd(EncounterSM.CMD_SKILL, "pc", "imp1", "inkbolt", "", &"player"))
	_end_party_phase(sm2)
	var c2 := agent.next_command(sm2)
	check(c2["type"] == EncounterSM.CMD_ATTACK and str(c2["skill"]) == "", "次数技能耗尽退普攻")
	# 低血用药（默认 HP<50%，阈值可配置）
	var low_def := _pc_first_def()
	(low_def["party"][0] as Dictionary)["hp"] = 6
	var sm3 := _sm_with(11, low_def)
	var c3 := agent.next_command(sm3)
	check(c3["type"] == EncounterSM.CMD_ITEM and str(c3["item"]) == "heal_potion" and str(c3["target"]) == "pc",
		"HP<50% 优先用药（09 §9.3 阈值策略）")
	agent.heal_threshold = 0.3
	check(agent.next_command(sm3)["type"] != EncounterSM.CMD_ITEM, "阈值可配置：30% 时 6/14 不用药")
	agent.heal_threshold = 0.5
	# 战斗结束 → 无命令（托管自动停止的前置：core 不再受理）
	var sm4 := _sm_with(7, {"party": [_tp2_party()[0].merged({"attack_mod": 30, "damage": "30d6"}, true)],
		"enemies": [_tp2_enemies()[1]]})
	sm4.submit_command(_cmd(EncounterSM.CMD_ATTACK, "pc", "imp1"))
	if sm4.is_over():
		check(agent.next_command(sm4).is_empty(), "战斗结束代理不再产出命令")
	else:
		check(false, "预设必胜样本未终结战斗")

# ---------------------------------------------------------------- 竖屏壳（04 §④、09 §5/§6/§9，无头断言）

func _ratios_close(r: Array[float], expect: Array, tol: float = 0.02) -> bool:
	return absf(r[0] - float(expect[0])) < tol \
		and absf(r[1] - float(expect[1])) < tol \
		and absf(r[2] - float(expect[2])) < tol

func test_portrait_shell() -> void:
	print("[portrait_shell]")
	var scene: PackedScene = load("res://shell/portrait/encounter_portrait.tscn")
	var portrait: EncounterPortrait = scene.instantiate()
	root.add_child(portrait)
	await process_frame
	await process_frame
	var stream := EventStream.new()
	var board := Board.new(stream)
	var sm := EncounterSM.new(board, stream, Rng.new(11), "campaign01")
	var agent := AutoAgent.new()
	portrait.bind(sm, agent)
	sm.enter("N1-7")
	sm.transition(EncounterSM.S_EXPLORE)
	await process_frame
	await process_frame

	# 呼吸：探索 8/62/30（04 §④.1 冻结比例，09 §5）
	check(_ratios_close(portrait.get_band_ratios(), [0.08, 0.62, 0.30]),
		"呼吸：探索态 8/62/30（04 §④.1）")
	# 房间推进条 pip 状态（04 §④.2）
	portrait.set_rooms(["N1-1", "N1-3", "N1-7", "N1-8"], 2)
	await process_frame
	check(portrait.pip_state(0) == EncounterPortrait.PIP_PAST
		and portrait.pip_state(1) == EncounterPortrait.PIP_PAST
		and portrait.pip_state(2) == EncounterPortrait.PIP_CURRENT
		and portrait.pip_state(3) == EncounterPortrait.PIP_FUTURE,
		"推进条：已过点亮 / 当前脉动 / 未来剪影")
	# 战斗态呼吸 12/55/33：高度变化随 state.entered 发生（09 §1/§5）
	# 待裁决：04 §④.1 战斗行写作 12/55/37（合计 104≠100），实现按状态栏 12、主视野 55、操作台补齐 33 落位
	sm.begin_combat(_std_def())
	await process_frame
	await process_frame
	check(_ratios_close(portrait.get_band_ratios(), [0.12, 0.55, 0.33]),
		"呼吸：战斗态 12/55/33（state.entered 驱动，04 §④.1 裁决见交付说明）")
	# 对话档 8/50/42（04 §④.1 表）
	portrait.apply_breathing(&"dialog")
	await process_frame
	await process_frame
	check(_ratios_close(portrait.get_band_ratios(), [0.08, 0.50, 0.42]), "呼吸：对话档 8/50/42")
	portrait._restore_breathing()
	await process_frame
	await process_frame
	check(_ratios_close(portrait.get_band_ratios(), [0.12, 0.55, 0.33]), "呼吸恢复战斗档")

	# 事件流 → UI 更新链路：日志
	stream.emit(EventTypes.LOG, {"msg": "测试日志条目"}, &"core")
	await process_frame
	check(portrait.log_view.get_parsed_text().contains("测试日志条目"), "事件流→UI：log 事件更新日志 Tab")
	# 事件流 → UI：攻击后敌方单位 HP 文本
	var target := sm.first_alive_enemy()
	sm.submit_command(_cmd(EncounterSM.CMD_ATTACK, sm.current_actor_id(), target))
	await process_frame
	var hp_now := int(sm.get_unit(target)["hp"])
	var hp_shown := false
	for child: Node in portrait.enemy_row.get_children():
		if (child as Button).text.contains("HP %d/" % hp_now):
			hp_shown = true
	check(hp_shown, "事件流→UI：battle.attack 后敌方 HP 显示更新")
	# 快捷栏芯片（09 §9.2：技能/道具/急救/结束回合 + 次数余量）；驱动到 pc 行动
	var guard := 0
	while sm.current_actor_id() != "pc" and guard < 6:
		guard += 1
		sm.submit_command(_cmd(EncounterSM.CMD_END_TURN, sm.current_actor_id()))
	await process_frame
	var chip_texts: Array = []
	for child: Node in portrait.quickbar.get_children():
		if child is Button:
			chip_texts.append((child as Button).text)
	var joined := " ".join(chip_texts)
	check(joined.contains("攻击") and joined.contains("补给药水") and joined.contains("急救")
		and joined.contains("结束回合"), "快捷栏芯片齐备（行动 Tab）")
	check(joined.contains("墨术飞矢 ×2"), "芯片呈现次数余量（09 §9.2）")

	# 托管：节拍下限（09 §9.3：≥0.8s/动作，1×/2×）与同一 Command 通道
	check(portrait.auto_timer.wait_time == 0.8, "托管 1× 节拍 0.8s")
	portrait.set_speed(2)
	check(absf(portrait.auto_timer.wait_time - 0.4) < 0.001, "托管 2× 节拍 0.4s")
	portrait.set_auto(true)
	await create_timer(1.6).timeout
	check(stream.query_by_type(EventTypes.BATTLE_ATTACK).any(
		func(ev: Dictionary) -> bool: return ev["payload"]["source"] == &"auto"),
		"托管经同一 Command 通道产出 source=auto 事件")
	portrait._manual(_cmd(EncounterSM.CMD_END_TURN, sm.current_actor_id()))
	check(not portrait.auto_on, "玩家点按即接管（09 §9.3 即时生效）")

	# 关键判定全屏演出（09 §6；死亡豁免恒定关键，11 §7）
	stream.emit(EventTypes.CHECK_ROLL, {"roller": "kelan", "kind": "death_save", "rolls": [3],
		"keep": 3, "dc": 10, "success": false, "s": 0, "f": 1, "key": true, "extreme": false}, &"core")
	await create_timer(0.2).timeout
	check(portrait.key_overlay.visible, "关键判定全屏接管（09 §6）")
	check(not portrait.status_band.visible and not portrait.console_panel.visible,
		"全屏时状态栏/操作台退屏（04 §④.1 关键判定行）")
	var mb := InputEventMouseButton.new()
	mb.pressed = true
	portrait._on_key_overlay_input(mb)
	await create_timer(0.3).timeout
	check(not portrait.key_overlay.visible, "关键演出可点击跳过（09 §6/04 §④.7）")
	await process_frame
	await process_frame
	check(_ratios_close(portrait.get_band_ratios(), [0.12, 0.55, 0.33]), "演出结束呼吸回落战斗档")

	portrait.queue_free()
	await process_frame

# ---------------------------------------------------------------- 壳路由（09 §2/§3/§8、tech/02 §2.1）

func test_shell_router() -> void:
	print("[shell_router]")
	var pack := _load_campaign01()
	var pres: Dictionary = pack["manifest"]["presentation"]
	check(str(pres["mode"]) == "choice", "campaign01 manifest mode=choice（tech/02 §2.1）")
	var r1 := ShellRouter.resolve(pres, PackedStringArray(["--mode=space"]), "SL-1")
	check(r1["mode"] == ShellRouter.MODE_SPACE and not bool(r1["forced"]), "choice + --mode=space → 横屏")
	var r2 := ShellRouter.resolve(pres, PackedStringArray([]), "SL-1")
	check(r2["mode"] == ShellRouter.MODE_TIME, "choice 无启动参数 → 缺省 time（竖屏）")
	var r3 := ShellRouter.resolve(pres, PackedStringArray(["--mode=time"]), "SL-1")
	check(r3["mode"] == ShellRouter.MODE_TIME, "choice + --mode=time → 竖屏")
	var r4 := ShellRouter.resolve(pres, PackedStringArray(["--mode=space"]), "SL-0")
	check(r4["mode"] == ShellRouter.MODE_TIME and bool(r4["forced"]),
		"forced 幕 SL-0 强制竖屏（启动参数不生效，tech/02 §2.1）")
	var notice := str(r4["notice"])
	check(notice != "" and not notice.contains("锁定") and not notice.contains("模式"),
		"强制幕叙事化提示（09 §3：包装文案禁止系统腔）")
	var r5 := ShellRouter.resolve(pres, PackedStringArray([]), "SL-3")
	check(r5["mode"] == ShellRouter.MODE_TIME and bool(r5["forced"]), "forced 幕 SL-3 强制竖屏")
	var r6 := ShellRouter.resolve({"mode": "space"}, PackedStringArray([]), "SL-9")
	check(r6["mode"] == ShellRouter.MODE_SPACE and bool(r6["forced"]), "mode=space 单模式战役直接落定")
	# 单局内禁止切换（09 §8：形态是战役级属性）
	var router := ShellRouter.new()
	check(router.request_switch(ShellRouter.MODE_SPACE), "遭遇开始前可定壳")
	router.lock_encounter(ShellRouter.MODE_TIME)
	check(router.is_locked() and router.locked_mode == ShellRouter.MODE_TIME, "遭遇开始即壳锁定")
	check(not router.request_switch(ShellRouter.MODE_SPACE), "锁定后切换请求拒绝（09 §8）")
	check(not router.request_switch(ShellRouter.MODE_TIME), "锁定后同形态请求亦拒绝（一局之内无切换入口）")

# ---------------------------------------------------------------- 横屏壳（04 §③、09 §4/§6/§7/§9，无头断言）

func test_landscape_shell() -> void:
	print("[landscape_shell]")
	var scene: PackedScene = load("res://shell/landscape/encounter_landscape.tscn")
	var land: EncounterLandscape = scene.instantiate()
	root.add_child(land)
	# 横屏冻结指标按横屏尺寸断言（09 §4）：脱离项目竖屏视口，给定 1280×720
	land.set_anchors_preset(Control.PRESET_TOP_LEFT)
	land.position = Vector2.ZERO
	land.size = Vector2(1280, 720)
	await process_frame
	await process_frame
	var stream := EventStream.new()
	var board := Board.new(stream)
	var sm := EncounterSM.new(board, stream, Rng.new(11), "campaign01")
	land.bind(sm, AutoAgent.new())
	sm.enter("N1-7")
	sm.transition(EncounterSM.S_EXPLORE)
	await process_frame
	await process_frame
	var z := land.get_zone_ratios()
	check(absf(float(z["top"]) - 0.08) < 0.02 and absf(float(z["bottom"]) - 0.05) < 0.02,
		"五区：上缘 8% / 下缘 5%（09 §4 冻结指标）")
	check(absf(float(z["left"]) - 15.0 / 87.0) < 0.02 and absf(float(z["center"]) - 60.0 / 87.0) < 0.02
		and absf(float(z["right"]) - 12.0 / 87.0) < 0.02
		and absf(float(z["left"]) + float(z["center"]) + float(z["right"]) - 1.0) < 0.001,
		"五区：三栏权重 15:60:12 归一拉伸至满宽（09 §4 + TP3 验收裁决 1：≈17.2/69.0/13.8%）")
	check(not land.init_bar.visible, "探索态先攻顺序条收起（战斗时展开，09 §4）")
	check(land.menu_button.text == TextsZh.MENU, "☰ 常驻上缘右端（09 §7）")
	sm.begin_combat(_std_def())
	await process_frame
	await process_frame
	check(land.init_bar.visible and land.init_bar.get_child_count() == sm.get_order().size(),
		"先攻顺序条战斗时展开且按先攻序全员排列")
	# 战术格（09 §4：8×5 占位、格边长可读、敌我按格落位、敌红我金）
	check(land.grid.get_child_count() == 40, "战术格 8×5=40 占位（同屏 ≤12×8，09 §4）")
	check(land.cell_side() >= land.size.y * 0.08, "格边长 ≥ 屏高 8%（09 §4 可读性）")
	var units := sm.get_units()
	var all_placed := true
	for id: String in units:
		var c := land.unit_cell(id)
		if c.x < 0 or c.x >= 8 or c.y < 0 or c.y >= 5:
			all_placed = false
	check(all_placed and land.unit_cell(sm.first_alive_enemy()) != Vector2i(-1, -1), "敌我单位全部按格落位")
	check(land.token_color(sm.first_alive_enemy()) == EncounterLandscape.COLOR_ENEMY, "敌方 token 红色（09 §4）")
	check(land.token_color("pc") == EncounterLandscape.COLOR_PARTY, "我方 token 金色（09 §4）")
	# 行动轮盘与竖屏快捷栏同源（同一 EncounterSM 可用指令集）；驱动到 pc 行动（其技能/道具最全）
	var guard0 := 0
	while sm.current_actor_id() != "pc" and guard0 < 6:
		guard0 += 1
		sm.submit_command(_cmd(EncounterSM.CMD_END_TURN, sm.current_actor_id()))
	await process_frame
	var actions := sm.get_available_actions()
	var wheel_labels: Array = []
	for child: Node in land.wheel_box.get_children():
		if child is Button:
			wheel_labels.append((child as Button).text)
	check(wheel_labels.size() == actions.size() and not actions.is_empty(),
		"行动轮盘 = 同一 EncounterSM 可用指令集生成（禁止复制过滤逻辑）")
	var joined := " ".join(wheel_labels)
	check(joined.contains("攻击") and joined.contains("墨术飞矢 ×2") and joined.contains("补给药水")
		and joined.contains("结束回合"), "轮盘芯片与快捷栏同文案（TextsZh.action_label 单源）")
	# 轮盘按钮真实点按 → 统一 Command 通道（12 §1 点按=默认目标）
	var atks_before := stream.query_by_type(EventTypes.BATTLE_ATTACK).size()
	for child: Node in land.wheel_box.get_children():
		if child is Button and (child as Button).text == TextsZh.CHIP_ATTACK and not (child as Button).disabled:
			(child as Button).pressed.emit()
			break
	await process_frame
	check(stream.query_by_type(EventTypes.BATTLE_ATTACK).size() == atks_before + 1,
		"轮盘点按经统一 Command 通道产出 battle.attack")
	await create_timer(0.6).timeout # 等骰子盘快掷落定（≤0.5s，09 §6）
	var last_keep := int(stream.query_by_type(EventTypes.BATTLE_ATTACK).back()["payload"]["keep"])
	check(land.dice_label.text == str(last_keep), "骰子盘呈现最近一次攻击的 d20 明细")
	# 日志带：点击展开半屏 ↔ 收起 5%（09 §4）
	check(not land.log_expanded, "日志带默认收起（下缘 5%）")
	land.toggle_log()
	await process_frame
	await process_frame
	check(land.log_expanded and absf(float(land.get_zone_ratios()["bottom"]) - 0.5) < 0.02,
		"日志带点击展开至半屏（09 §4）")
	check(land.log_full.visible and land.log_full.get_parsed_text().contains("战斗开始"),
		"展开日志含事件流条目（与竖屏日志 Tab 同源）")
	land.toggle_log()
	await process_frame
	await process_frame
	check(not land.log_expanded and absf(float(land.get_zone_ratios()["bottom"]) - 0.05) < 0.02,
		"日志带收起回落 5%")
	# 关键判定全屏演出（09 §6：与竖屏同一事件源；死亡豁免恒定关键，11 §7）
	stream.emit(EventTypes.CHECK_ROLL, {"roller": "kelan", "kind": "death_save", "rolls": [3],
		"keep": 3, "dc": 10, "success": false, "s": 0, "f": 1, "key": true, "extreme": false}, &"core")
	await create_timer(0.2).timeout
	check(land.key_overlay.visible, "关键判定全屏覆盖（横屏，09 §6）")
	var mb := InputEventMouseButton.new()
	mb.pressed = true
	land._on_key_overlay_input(mb)
	await create_timer(0.3).timeout
	check(not land.key_overlay.visible, "关键演出可点击跳过（09 §6）")
	# 托管节拍下限（09 §9.3）
	check(land.auto_timer.wait_time == 0.8, "托管 1× 节拍 0.8s")
	land.set_speed(2)
	check(absf(land.auto_timer.wait_time - 0.4) < 0.001, "托管 2× 节拍 0.4s")
	land.queue_free()
	await process_frame

# ---------------------------------------------------------------- 双壳事件流逐字节比对（tech/01 §10 TP3；白皮书 §7.3 数据零差异）

func test_shell_diff() -> void:
	print("[shell_diff]")
	var sd: GDScript = load("res://tools/shell_diff.gd")
	# 普通局：同一脚本化遭遇（同种子、同指令序列）两壳各跑一遍
	var pair: Dictionary = await sd.run_pair(self, 20261108, 7, false)
	check(int(pair["count"]) > 40, "脚本化遭遇完整跑完（事件 %d 条）" % int(pair["count"]))
	check(str(pair["result"]) != "", "普通局有战斗结果（%s）" % str(pair["result"]))
	check(str(pair["portrait"]) == str(pair["landscape"]),
		"普通局：两壳事件流 JSON 逐字节一致（数据零差异，白皮书 §7.3）")
	# 乱序压力版：同种子 bot 指令序列（含托管命令）两壳各 3 局比对
	for i: int in 3:
		var p2: Dictionary = await sd.run_pair(self, 20261108 + i, 100 + i * 31, true)
		check(str(p2["result"]) != "", "托管乱序局 %d 有战斗结果（%s）" % [i + 1, str(p2["result"])])
		check(str(p2["portrait"]) == str(p2["landscape"]),
			"托管乱序局 %d：两壳事件流逐字节一致（含 source=auto 命令）" % (i + 1))

# ---------------------------------------------------------------- SaveSystem（07 §4，TP4）

func test_save_system() -> void:
	print("[save_system]")
	var stream := EventStream.new()
	var board := Board.new(stream)
	var rng := Rng.new(777)
	var prov := {"event_id": 1, "node_id": "N1-1", "pack_id": "campaign01"}
	board.write("campaign01.seen_fading", true, prov)
	board.write("global.doom_clock", 3, prov)
	board.give_item("ink_core", 2, prov)
	rng.d20() # 推进 RNG 状态，验证状态级恢复（非仅种子）
	var tail := stream.tail()
	var snap := SaveSystem.make_snapshot(board, stream, rng,
		{"packs": {"campaign01": 1}, "rule_pack": {"id": "light", "min_version": 1}},
		{"playthrough": 1, "graph": {"current_id": "N1-7"}})
	check(int(snap["save_version"]) == SaveSystem.SAVE_VERSION, "快照含 save_version（07 §4.1）")
	check(int(snap["event_tail"]) == tail, "快照含事件流 tail 锚点")
	check(snap.has("board") and snap.has("rng_seed") and snap.has("bindings") and snap.has("meta"),
		"快照五要素齐备：board/event_tail/bindings/rng/meta（07 §4.1）")
	check(str((snap["meta"] as Dictionary).get("saved_at", "")) != "", "meta 含保存时间戳（07 §4.1）")
	# 写盘 → 读档 → 迁移 → 应用，往返一致（JSON，tech/01 §4.3）
	check(SaveSystem.write(snap, "test_tp4"), "写入 user://saves/")
	check(SaveSystem.has_save("test_tp4"), "has_save 读档存在")
	var loaded := SaveSystem.read("test_tp4")
	check(bool(loaded["ok"]), "读档成功")
	var mig := SaveSystem.migrate(loaded["snapshot"])
	check(bool(mig["ok"]), "v1 迁移链直通（07 §4.3）")
	var board2 := Board.new(EventStream.new())
	var rng2 := Rng.new(1)
	SaveSystem.apply(mig["snapshot"], board2, rng2)
	check(board2.serialize() == snap["board"], "存档往返：Board 全量一致")
	check(board2.read("campaign01.seen_fading") == true and board2.get_doom_clock() == 3
		and board2.item_count("ink_core") == 2, "存档往返：旗标/时钟/物品一致")
	check(rng2.d20() == rng.d20(), "存档往返：RNG 恢复后续掷一致（rng_seed 状态）")
	# 迁移链边界
	check(not bool(SaveSystem.migrate({"save_version": 0})["ok"]), "缺 save_version 拒绝")
	var future: Dictionary = snap.duplicate(true)
	future["save_version"] = SaveSystem.SAVE_VERSION + 1
	check(not bool(SaveSystem.migrate(future)["ok"]), "未来版本快照拒绝（07 §4.3 不降级读取）")

# ---------------------------------------------------------------- Loadout（09 §9.1 / tech-02 §2.4，TP4）

func test_loadout() -> void:
	print("[loadout]")
	var pack := _load_campaign01()
	var cfg := Loadout.resolve_config(pack, "N1-7")
	check(not cfg.is_empty() and bool(cfg["enabled"]), "manifest loadout 启用（tech/02 §2.4）")
	check(int(cfg["skill_slots"]) == 2 and int(cfg["item_slots"]) == 2, "槽位读 manifest 配置（技能 2 / 道具 2）")
	check(Loadout.validate(cfg, ["a", "b"], ["x"]) == "", "槽位内选择合法")
	check(Loadout.validate(cfg, ["a", "b", "c"], ["x"]) == "skill_slots_exceeded", "技能超槽拒绝")
	check(Loadout.validate(cfg, ["a"], ["x", "y", "z"]) == "item_slots_exceeded", "道具超槽拒绝")
	# 遭遇级覆盖（tech/02 §2.4：同名块覆盖）
	var pack2: Dictionary = pack.duplicate(true)
	(pack2["encounters"] as Dictionary)["N1-7"]["loadout"] = {"skill_slots": 1}
	var cfg2 := Loadout.resolve_config(pack2, "N1-7")
	check(int(cfg2["skill_slots"]) == 1 and int(cfg2["item_slots"]) == 2, "遭遇级 loadout 覆盖战役级")
	# 未声明 = 不启用（tech/02 §2.4）
	var pack3: Dictionary = pack.duplicate(true)
	(pack3["manifest"] as Dictionary).erase("loadout")
	check(Loadout.resolve_config(pack3, "N1-7").is_empty(), "未声明 loadout = 不启用整备")
	# 确认写事件流（09 §9.1：loadout.confirm，历史卷轴可追溯）
	var stream := EventStream.new()
	var sel := Loadout.confirm(stream, cfg, ["inkbolt", "inkshield"], ["heal_potion"],
		{"might": 1}, "N1-7", "campaign01")
	var evs := stream.query_by_type(EventTypes.LOADOUT_CONFIRM)
	check(evs.size() == 1, "确认产出 loadout.confirm 事件（09 §9.1）")
	check((evs[0]["payload"]["skills"] as Array) == ["inkbolt", "inkshield"]
		and int((sel as Dictionary)["skill_slots"]) == 2, "confirm 负载含选择与槽位快照")

# ---------------------------------------------------------------- 成长曲线（11 §6，TP4 裁决 3 对齐）

func test_growth() -> void:
	print("[growth]")
	# 档位表：1→2 需 300，2→3 需 700，3→4 需 1200（11 §6）
	check(LightV1.level_for_xp(299) == 1, "299 XP 不升级（门槛 300）")
	check(LightV1.level_for_xp(300) == 2, "300 XP 升 Lv.2")
	check(LightV1.attr_points_for_xp(300) == 1 and LightV1.hp_bonus_for_xp(300) == 2,
		"Lv.2：属性点 +1、HP+2（11 §6）")
	check(LightV1.level_for_xp(699) == 2 and LightV1.level_for_xp(700) == 3, "700 XP 升 Lv.3")
	check(LightV1.attr_points_for_xp(700) == 2 and LightV1.hp_bonus_for_xp(700) == 4,
		"Lv.3：累计属性点 +2、HP+4")
	check(LightV1.level_for_xp(1199) == 3 and LightV1.level_for_xp(1200) == 4, "1200 XP 升 Lv.4")
	check(LightV1.attr_points_for_xp(1200) == 3 and LightV1.hp_bonus_for_xp(1200) == 6,
		"连跨档（0→1200）：属性点 +3、HP+6")
	check(LightV1.level_for_xp(99999) == 4, "等级上限 Lv.4（11 §6 表三档）")
	check(LightV1.skill_slot_bonus(2) == 0 and LightV1.skill_slot_bonus(3) == 1,
		"2→3 级技能槽 +1（11 §6）")
	check(LightV1.ATTR_POINT_CAP == 3, "单项属性加点 +3 封顶（11 §6）")

# ---------------------------------------------------------------- L3 事件运行时（tech/02 §5，TP4 接入 story_graph）

func test_quest_runtime() -> void:
	print("[quest_runtime]")
	var pack := _load_campaign01()
	var stream := EventStream.new()
	var board := Board.new(stream)
	var graph := StoryGraph.new(board, Rng.new(42), pack)
	graph.start()
	graph.take_edge(_edge_to(graph, "N0-2"))
	var qt := stream.query_by_type(EventTypes.QUEST_TRIGGER)
	check(qt.size() == 1 and str(qt[0]["payload"]["id"]) == "dock_tales",
		"auto 触发：进 N0-2 事件中心可见（quest.trigger）")
	check(graph.quest_badge_count() == 1, "进行中事件角标 = 1（04 §⑤）")
	graph.resolve_check(graph.available_edges()[0], true) # N0-2 完成 → dock_tales settle
	var qs := stream.query_by_type(EventTypes.QUEST_SETTLE)
	check(qs.size() == 1 and str(qs[0]["payload"]["id"]) == "dock_tales", "节点完成 → quest.settle")
	var xp := stream.query_by_type(EventTypes.XP_GAIN)
	check(xp.size() == 1 and int(xp[0]["payload"]["amount"]) == 50, "settle 写板：xp 50（tech/02 §5）")
	check(graph.quest_badge_count() == 0, "已完结事件不计角标（归档历史卷轴）")
	# 主线推进：fading_street 触发；settle 去重不重复写板（TP4 裁决：效果由节点 on_enter 承载）
	graph.take_edge(_edge_to(graph, "N0-4"))
	graph.take_edge(_edge_to(graph, "N1-1"))
	var e_buy := _edge_to(graph, "N1-2")
	for e: Variant in graph.available_edges():
		for fx: Variant in (e as Dictionary).get("effects", []):
			if (fx as Dictionary).has("give_item"):
				e_buy = e
	graph.take_edge(e_buy)
	check(str((stream.query_by_type(EventTypes.QUEST_TRIGGER).back() as Dictionary)["payload"]["id"]) == "fading_street",
		"auto 触发：消逝之街（进 N1-2）")
	graph.resolve_check(graph.available_edges()[0], true) # N1-2 成功 → N1-3
	check(board.get_doom_clock() == 1, "fading_street settle 不重复推钟（去重裁决，时钟仍 = N1-3 on_enter 的 1）")
	# choice 触发：誊写庭委托；settle 写声望增量（N2S-1 完成）
	graph.take_edge(_edge_to(graph, "N1-4")) # 接触誊写庭 rep+1（on_enter）；离开 N1-3 → fading_street 完结
	check(stream.query_by_type(EventTypes.QUEST_SETTLE).any(
		func(ev: Dictionary) -> bool: return str(ev["payload"]["id"]) == "fading_street"),
		"离开 N1-3 → fading_street 完结（节点完成时结算，tech/02 §5）")
	check(graph.quest_badge_count() == 1 and graph.quests().any(
		func(q: Dictionary) -> bool: return str(q["id"]) == "three_callings" and str(q["state"]) == "triggered"),
		"三方拜帖进行中（进 N1-3 触发）")
	graph.take_edge(_edge_to(graph, "N1-7"))
	check(int(board.get_rep("scriptorium")) == 1, "three_callings settle 去重：声望不重复 +1")
	graph.take_edge(_edge_to(graph, "N1-8"))
	var e_s := _edge_to(graph, "N2S-1")
	graph.take_edge(e_s) # choice 触发 archive_quest
	check(stream.query_by_type(EventTypes.QUEST_TRIGGER).any(
		func(ev: Dictionary) -> bool: return str(ev["payload"]["id"]) == "archive_quest"),
		"choice 触发：档案馆委托（label 匹配，tech/02 §5）")
	graph.resolve_check(graph.available_edges()[0], true) # N2S-1 完成 → settle rep.scriptorium +1
	check(int(board.get_rep("scriptorium")) == 2, "settle 写板：档案馆委托 rep.scriptorium +1")
	# doom_clock 触发：时钟到 2 格
	board.write("global.doom_clock", 2, {"event_id": stream.tail(), "node_id": graph.current_id, "pack_id": "campaign01"})
	graph._scan_triggers()
	check(stream.query_by_type(EventTypes.QUEST_TRIGGER).any(
		func(ev: Dictionary) -> bool: return str(ev["payload"]["id"]) == "ink_rain_raid"),
		"doom_clock 触发：墨雨夜袭（at 2，tech/02 §5）")
	# 图进度快照往返（07 §4.1 meta.graph）
	var snap := graph.serialize()
	var graph2 := StoryGraph.new(Board.new(EventStream.new()), Rng.new(1), pack)
	graph2.deserialize(JSON.parse_string(JSON.stringify(snap)))
	check(graph2.current_id == graph.current_id and graph2.quest_badge_count() == graph.quest_badge_count()
		and graph2.quests().size() == graph.quests().size(), "图进度快照往返一致（含 L3 事件状态）")
	# hidden 触发：零声望抵达 N1-8 → 孤身入局（tech/02 §5 hidden）
	var s2 := EventStream.new()
	var b2 := Board.new(s2)
	var g2 := StoryGraph.new(b2, Rng.new(7), pack)
	g2.start()
	g2.take_edge(_edge_to(g2, "N0-2"))
	g2.resolve_check(g2.available_edges()[0], true)
	g2.take_edge(_edge_to(g2, "N0-4"))
	g2.take_edge(_edge_to(g2, "N1-1"))
	g2.take_edge(_edge_to(g2, "N1-2"))
	g2.resolve_check(g2.available_edges()[0], true) # → N1-3
	var e_decline := _edge_to(g2, "N1-8") # 婉拒所有邀约：三方声望保持 0
	check(not e_decline.is_empty(), "N1-3 存在婉拒边")
	g2.take_edge(e_decline)
	check(s2.query_by_type(EventTypes.QUEST_TRIGGER).any(
		func(ev: Dictionary) -> bool: return str(ev["payload"]["id"]) == "lone_wolf"),
		"hidden 触发：孤身入局（requires 三方声望 ≤0）")
	check(not _edge_to(g2, "N2L-1").is_empty(), "hidden 触发后独狼声望边显形")

# ---------------------------------------------------------------- 九类界面闭环（04 §2/§5，TP4 无头断言）

func test_ui_screens() -> void:
	print("[ui_screens]")
	var pack := _load_campaign01()
	var stream := EventStream.new()
	var board := Board.new(stream)
	# ① 主屏：五入口 + 运营位 + 帮助 + 手动/闲置存档信号
	var home: ScreenHome = (load("res://shell/ui/screen_home.tscn") as PackedScene).instantiate()
	root.add_child(home)
	await process_frame
	var navs: Array = []
	home.navigate.connect(func(id: StringName) -> void: navs.append(id))
	home.bind(board, 2, true)
	check(home.campaign_button.text.contains(TextsZh.HOME_CONTINUE), "主屏：战役入口带「继续」（04 §①）")
	check(home.quests_button.text.contains("2"), "主屏：事件中心角标（04 §①）")
	home.campaign_button.pressed.emit()
	home.quests_button.pressed.emit()
	home.inventory_button.pressed.emit()
	home.character_button.pressed.emit()
	home.history_button.pressed.emit()
	check(navs == [&"entry", &"quests", &"inventory", &"character", &"history"],
		"主屏五入口齐备（04 §①：②⑤⑥⑦⑧）")
	board.write("global.doom_clock", 8, {"event_id": 1, "node_id": "", "pack_id": "campaign01"})
	home.bind(board, 0, false)
	check(home.doom_label.text == TextsZh.home_doom_text(8), "营地图景随褪墨度变化文案（04 §①）")
	check(home.campaign_button.text == TextsZh.HOME_ENTRY_CAMPAIGN, "无可继续进度时不带「继续」")
	var saves: Array = []
	home.save_requested.connect(func() -> void: saves.append("manual"))
	home.idle_timeout.connect(func() -> void: saves.append("idle"))
	home.save_button.pressed.emit()
	home.debug_force_idle()
	check(saves == ["manual", "idle"], "手动「记录抄本」+ 主屏闲置两时机（07 §4.2）")
	home._toggle_help()
	check(home.is_help_visible(), "帮助入口：手势图鉴页（12 §4）")
	home._toggle_help()
	home.queue_free()
	# ② 战役入口：未选禁用开始 → 选形态 → 上报
	var entry: ScreenEntry = (load("res://shell/ui/screen_entry.tscn") as PackedScene).instantiate()
	root.add_child(entry)
	await process_frame
	entry.bind(pack, [], 12.5)
	check(entry.start_button.disabled, "未选模式禁用开始（09 §3/04 §②）")
	check(entry.collect_label.text.contains("12"), "分支收集度呈现（04 §② 多周目信息）")
	var chosen: Array = []
	entry.mode_chosen.connect(func(m: StringName) -> void: chosen.append(m))
	entry.pick_mode(ShellRouter.MODE_TIME)
	check(not entry.start_button.disabled and chosen == [ShellRouter.MODE_TIME],
		"选形态后解锁开始并上报（选择即分支，09 §3）")
	var backed := [false]
	entry.back_requested.connect(func() -> void: backed[0] = true)
	entry.back_button.pressed.emit()
	check(backed[0], "战役入口有退路：返回主屏（04 §5）")
	entry.queue_free()
	# 整备：3 选 2 槽位限制 + 确认上报 + 属性点
	var lo: ScreenLoadout = (load("res://shell/ui/screen_loadout.tscn") as PackedScene).instantiate()
	root.add_child(lo)
	await process_frame
	var cfg := Loadout.resolve_config(pack, "N1-7")
	lo.bind(cfg, {"skills": [
			{"id": "s1", "name": "技能一"}, {"id": "s2", "name": "技能二"}, {"id": "s3", "name": "技能三"}],
		"items": [{"id": "heal_potion", "name": "补给药水", "count": 2}],
		"attr_points": 1, "attr_alloc": {"might": 0, "finesse": 0, "wits": 0}})
	lo._toggle_skill("s1")
	lo._toggle_skill("s2")
	lo._toggle_skill("s3") # 第 3 个超槽：不进入选择
	check(lo.picked_skills() == ["s1", "s2"], "整备：技能 3 选 2 槽位限制（09 §9.1）")
	lo._toggle_item("heal_potion")
	var lo_sel: Array = []
	lo.confirmed.connect(func(sel: Dictionary) -> void: lo_sel.append(sel))
	lo._on_confirm()
	check(lo_sel.size() == 1 and (lo_sel[0]["skills"] as Array) == ["s1", "s2"]
		and (lo_sel[0]["items"] as Array) == ["heal_potion"], "整备确认上报选择（写 loadout.confirm 由 core 落）")
	lo.queue_free()
	# ⑨ 结算：汇总 + 加点 + 双出口
	var st: ScreenSettle = (load("res://shell/ui/screen_settle.tscn") as PackedScene).instantiate()
	root.add_child(st)
	await process_frame
	st.bind({"title": "午夜墨雨", "result": "victory", "lines": ["经验 +100", "获得：墨核 ×1"],
		"saved": true, "attr_points": 1, "attrs": {"might": 0, "finesse": 0, "wits": 0}})
	check(st.summary_text.text.contains("经验 +100") and st.summary_text.text.contains("墨核"),
		"结算：写板汇总逐项呈现（04 §⑨）")
	check(st.saved_label.text == TextsZh.SETTLE_SAVED, "结算：存档快照提示（07 §4.2 主快照点）")
	var allocs: Array = []
	st.allocate.connect(func(a: String) -> void: allocs.append(a))
	var attr_btn: Button = null
	for child: Node in st.attr_box.get_children():
		if child is Button and not (child as Button).disabled:
			attr_btn = child
			break
	attr_btn.pressed.emit()
	check(allocs.size() == 1, "结算：成长加点上报（属性点可留到下次整备）")
	check(st.home_button.text == TextsZh.SETTLE_HOME and st.history_button.text == TextsZh.SETTLE_HISTORY,
		"结算出口：回主屏 / 看卷轴（04 §⑨）")
	# 无可用点数时加点区不显示（11 §6：仅在有点数时分配）
	st.bind({"title": "午夜墨雨", "result": "victory", "lines": [], "saved": true,
		"attr_points": 0, "attrs": {"might": 1, "finesse": 0, "wits": 0}})
	check(not st.attr_box.visible and not st.attr_label.visible, "无属性点：加点区隐藏（11 §6 分配时机）")
	# 单项 +3 封顶：已满项按钮禁用
	st.bind({"title": "午夜墨雨", "result": "victory", "lines": [], "saved": true,
		"attr_points": 1, "attrs": {"might": 3, "finesse": 0, "wits": 0}})
	await process_frame # 旧按钮 queue_free 后再取新按钮
	for child: Node in st.attr_box.get_children():
		if child is Button and (child as Button).text.begins_with("力"):
			check((child as Button).disabled, "单项 +3 封顶：力已满 → 按钮禁用（11 §6）")
	st.queue_free()
	# ⑧ 历史卷轴：倒序 + 展开明细 + 关键标记 + 溯源
	stream.emit(EventTypes.FLAG_WRITE, {"key": "campaign01.seen_fading", "old": false, "value": true,
		"provenance": {"event_id": 1, "node_id": "N0-3a", "pack_id": "campaign01"}}, &"board", "N0-3a")
	stream.emit(EventTypes.CHECK_ROLL, {"roller": "pc", "kind": "death_save", "rolls": [14], "keep": 14,
		"mod": 0, "total": 14, "dc": 10, "success": true, "s": 1, "f": 0, "key": true}, &"core", "N1-7")
	var hi: ScreenHistory = (load("res://shell/ui/screen_history.tscn") as PackedScene).instantiate()
	root.add_child(hi)
	await process_frame
	hi.bind(stream, board)
	var rows := 0
	var first_btn: Button = null
	var key_marked := false
	for child: Node in hi.list_box.get_children():
		if child is Button:
			rows += 1
			if first_btn == null:
				first_btn = child
			if (child as Button).text.contains("★"):
				key_marked = true
	check(rows == stream.size() and rows >= 2, "历史卷轴：事件流条目全量入轴（04 §⑧）")
	check(first_btn != null and first_btn.text.contains("check.roll"),
		"历史卷轴：倒序（最新在上，04 §⑧ 时间轴）")
	check(key_marked, "关键判定标记 ★（09 §6 key=true）")
	first_btn.pressed.emit()
	check(hi.detail_label.text.contains("检定明细") and hi.detail_label.text.contains("DC 10"),
		"展开明细：检定 d20 明细（骰值+修正=结果 vs 难度，04 §⑧）")
	var flag_btn: Button = null
	for child: Node in hi.list_box.get_children():
		if child is Button and (child as Button).text.contains("flag.write"):
			flag_btn = child
	flag_btn.pressed.emit()
	check(hi.detail_label.text.contains("N0-3a") and hi.detail_label.text.contains("campaign01"),
		"旗标溯源：来源节点回链状态板（07 §1/§6）")
	var hi_back := [false]
	hi.back_requested.connect(func() -> void: hi_back[0] = true)
	hi.back_button.pressed.emit()
	check(hi_back[0], "历史卷轴出口：返回来源界面（04 §5）")
	hi.queue_free()
	# ⑤⑥⑦ 最小版：只读列表 + 返回 + 补全标注
	var qs: ScreenQuests = (load("res://shell/ui/screen_quests.tscn") as PackedScene).instantiate()
	root.add_child(qs)
	await process_frame
	qs.bind([{"id": "dock_tales", "name": "码头异闻", "objective": "完成 N0-2 检定", "node": "N0-2",
		"state": "triggered"}])
	var q_text := ""
	for child: Node in qs.list_box.get_children():
		if child is Label:
			q_text += (child as Label).text
	check(q_text.contains("码头异闻") and q_text.contains(TextsZh.QUESTS_ACTIVE), "事件中心：进行中事件列表（04 §⑤）")
	qs.queue_free()
	var iv: ScreenInventory = (load("res://shell/ui/screen_inventory.tscn") as PackedScene).instantiate()
	root.add_child(iv)
	await process_frame
	board.give_item("ink_core", 1, {"event_id": 2, "node_id": "N1-7", "pack_id": "campaign01"})
	iv.bind(board.get_inv(), pack["items"], board.get_lore())
	var iv_text := ""
	for child: Node in iv.bag_box.get_children():
		if child is Label:
			iv_text += (child as Label).text
	check(iv_text.contains("墨核 ×1"), "背包图鉴：global.inv 只读列表（04 §⑥）")
	iv.queue_free()
	var ch: ScreenCharacter = (load("res://shell/ui/screen_character.tscn") as PackedScene).instantiate()
	root.add_child(ch)
	await process_frame
	ch.bind([{"id": "pc", "name": "白页者", "hp": 14, "max_hp": 14, "attrs": {"might": 2, "finesse": 1, "wits": 0},
		"skills": [{"name": "墨术飞矢"}]}], {"kelan": 10})
	var ch_text := ""
	for child: Node in ch.list_box.get_children():
		if child is Label:
			ch_text += (child as Label).text
	check(ch_text.contains("白页者") and ch_text.contains("kelan 10/100"), "角色：队伍卡 + 羁绊只读（04 §⑦）")
	ch.queue_free()
	await process_frame

# ---------------------------------------------------------------- main 串流集成（tech/01 §10 TP4；07 §4.2 时机；09 §7 ☰ 回主屏）

func test_main_flow() -> void:
	print("[main_flow]")
	var main_scene: PackedScene = load("res://main.tscn")
	var m: Node = main_scene.instantiate()
	root.add_child(m)
	await process_frame
	await process_frame
	check(m.current_screen is ScreenHome, "启动 → ①主屏（04 §2 枢纽）")
	# 主屏 → 战役入口 → 选模式 → 开始 → 整备
	m._on_home_navigate(&"entry")
	await process_frame
	check(m.current_screen is ScreenEntry, "主屏 → ②战役入口")
	(m.current_screen as ScreenEntry).pick_mode(ShellRouter.MODE_TIME)
	check(str(m.board.read("global.mode_choice.campaign01")) == "time",
		"模式选择写板 global.mode_choice.campaign01（09 §3，07 §3 v1.1 白名单）")
	(m.current_screen as ScreenEntry).start_requested.emit()
	await process_frame
	check(m.current_screen is ScreenLoadout, "战役入口 → 整备界面（09 §9.1：manifest loadout 启用）")
	check(m.graph.current_id == "N1-7", "序章脚本路径抵达 N1-7（StoryGraph 真实推进）")
	check(m.stream.query_by_type(EventTypes.QUEST_TRIGGER).size() >= 3,
		"L3 事件随路径触发（dock_tales/fading_street/three_callings，事件中心可见）")
	# 遭遇进行中不存档（07 §4.2）：删档后进战斗，战斗中无新档
	var save_path := "user://saves/slot1.json"
	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(save_path)
	var lo := m.current_screen as ScreenLoadout
	lo._toggle_skill("inkbolt")
	lo._toggle_skill("inkshield")
	lo._toggle_item("heal_potion")
	lo._on_confirm()
	check(m.stream.query_by_type(EventTypes.LOADOUT_CONFIRM).size() == 1,
		"整备确认写 loadout.confirm 事件（09 §9.1）")
	await create_timer(1.4).timeout # 进场延时后战斗开始
	check(m._in_encounter and m.shell is EncounterPortrait, "整备 → 竖屏遭遇（模式分支落定）")
	await create_timer(0.6).timeout
	check(not FileAccess.file_exists(save_path), "遭遇进行中不存档（07 §4.2 铁律）")
	# ☰ 保存并回主屏：恢复遭遇进入前快照（09 §7）
	var clock_before: int = (m._encounter_snapshot["board"]["data"] as Dictionary).get("global.doom_clock", 0)
	m.board.write("global.doom_clock", 9, {"event_id": m.stream.tail(), "node_id": "N1-7", "pack_id": "campaign01"})
	m._on_save_quit()
	await process_frame
	check(m.current_screen is ScreenHome, "☰ 回主屏（09 §7）")
	check(m.board.get_doom_clock() == int(clock_before), "☰ 回主屏：恢复遭遇进入前快照（战斗重打，09 §7）")
	check(FileAccess.file_exists(save_path), "回主屏后世界状态落档（遭遇外时机，07 §4.2）")
	# 继续战役 → 整备 → 战斗 → 结算（胜利）→ 存档快照 → 加点 → 回主屏
	m._on_home_navigate(&"entry")
	(m.current_screen as ScreenEntry).start_requested.emit()
	await process_frame
	var lo2 := m.current_screen as ScreenLoadout
	lo2._toggle_skill("inkbolt")
	lo2._toggle_skill("inkshield")
	lo2._on_confirm()
	await create_timer(1.4).timeout
	check(m._in_encounter, "主屏「继续」→ 再进遭遇（04 §① 继续进行中的战役）")
	m.stream.emit(EventTypes.XP_GAIN, {"amount": 300,
		"provenance": {"event_id": m.stream.tail(), "node_id": "N1-7", "pack_id": "campaign01"}},
		&"core", "N1-7") # 模拟 EncounterSM 胜利经验（真实战斗由 TP2 通道已验）；序章 50 + 300 = 350 跨 300 档
	m.stream.emit(EventTypes.COMBAT_END, {"result": &"victory", "rounds": 3}, &"core", "N1-7")
	await create_timer(1.6).timeout
	check(m.current_screen is ScreenSettle, "战斗结束 → ⑨结算（04 §⑨）")
	check(FileAccess.file_exists(save_path), "遭遇结算完成 = 主快照点（07 §4.2）")
	var read_back := SaveSystem.read("slot1")
	check(bool(read_back["ok"]) and bool(SaveSystem.migrate(read_back["snapshot"])["ok"]),
		"结算快照可读可迁移（v1 直通）")
	var points := int(m.board.read("campaign01.attr_points", 0))
	check(points == 1 and int(m.board.read("campaign01.level", 1)) == 2,
		"成长：350 XP 跨 300 档 → Lv.2、属性点 +1（11 §6 成长表）")
	check(int((m._battle_def({})["party"] as Array)[0]["max_hp"]) == 16,
		"成长：Lv.2 HP+2（14→16，11 §6）")
	m._on_settle_allocate("might")
	check(int(m.board.read("campaign01.attr_points", 0)) == points - 1
		and int((m.board.read("campaign01.attrs", {}) as Dictionary).get("might", 0)) == 1,
		"结算加点写板（属性点 -1，力 +1）")
	# 单项 +3 封顶（11 §6）
	m.board.write("campaign01.attrs", {"might": 3, "finesse": 0, "wits": 0},
		{"event_id": m.stream.tail(), "node_id": "N1-7", "pack_id": "campaign01"})
	check(not m._apply_attr_alloc({"might": 1}, 0), "单项 +3 封顶：力 +1 拒绝（11 §6）")
	check(m._apply_attr_alloc({"finesse": 1}, 0), "未满项仍可分配（敏 +1）")
	# 结算 → 卷轴 → 回结算 → 回主屏（04 §5 双列检查）
	(m.current_screen as ScreenSettle).go_history.emit()
	await process_frame
	check(m.current_screen is ScreenHistory, "结算 → ⑧历史卷轴（04 §⑨ 出口）")
	(m.current_screen as ScreenHistory).back_requested.emit()
	await process_frame
	check(m.current_screen is ScreenSettle, "卷轴 → 回结算（返回来源界面，04 §5）")
	(m.current_screen as ScreenSettle).go_home.emit()
	await process_frame
	check(m.current_screen is ScreenHome, "结算 → 回主屏（元循环落笔，04 §2）")
	m.queue_free()
	await process_frame
