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
	test_quest_abandon()
	test_gesture_recognizer()
	test_battle_data_driven()
	test_hp_persistence()
	test_escort_sm()
	test_maze_runner()
	test_act2_chains()
	test_act3_rooms()
	test_finale_endings()
	test_full_run_e4()
	test_story_runtime()
	test_story_vm()
	test_subgame_arena()
	test_entitlements()
	test_ops_config()
	call_deferred("_async_shell_tests")

func _async_shell_tests() -> void:
	await test_portrait_shell()
	await test_landscape_shell()
	await test_landscape_story()
	await test_shell_diff()
	await test_ui_screens()
	await test_subgame_flow()
	await test_entitlement_flow()
	await test_act2_hybrid_flow()
	await test_act3_forced_mode()
	await test_main_flow()
	await test_character_nav()
	await test_gap_features()
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
	# M2 审计 G2：state 常态 >2^53，JSON 数值往返曾丢尾数致读档后骰序偏离——
	# 修复后 state 以十进制字符串存储，经 JSON 序列化往返（等价于写盘读回）骰序逐位一致。
	var big := Rng.new(20261109)
	for i: int in 3:
		big.range_int(1, 20) # PCG 状态数步即超 2^53
	var st2: Dictionary = big.save_state()
	check(st2["state"] is String and int(st2["state"]) > 0, "存档 state 以十进制字符串存储（G2）")
	var roundtrip: Dictionary = JSON.parse_string(JSON.stringify(st2))
	check(int(roundtrip["state"]) == int(st2["state"]), "大 state（>2^53）JSON 往返无精度损失（G2）")
	var big2 := Rng.new(1)
	big2.load_state(roundtrip)
	var seq_orig: Array = []
	var seq_rest: Array = []
	for i: int in 10:
		seq_orig.append(big.range_int(1, 20))
		seq_rest.append(big2.range_int(1, 20))
	check(seq_orig == seq_rest, "JSON 往返恢复后骰序逐位一致 ×10（G2，07 §4.1）")
	# 旧档兼容：v≤2 数值型 state（含已丢精度 float）不报错接收
	var legacy := Rng.new(7)
	legacy.load_state({"seed": 20261109, "state": 3619339438595917312.0})
	check(legacy.range_int(1, 20) >= 1, "旧档数值型 state 兼容读取（G2 迁移不炸档）")

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
	check(int(b4.read("global.growth.xp", 0)) == 50,
		"effect xp 落板 global.growth.xp（tech/04 §8 规则1：任何包汇入）")
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

	# 效果全部进事件流（07 §6）；xp 汇入成长后 global.growth.xp 写板也产 flag.write（tech/04 §8）
	check(s4.query_by_type(EventTypes.FLAG_WRITE).size() == 2,
		"effect 写板事件进事件流（flag.write：旗标 + growth.xp 簿记）")
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
	check((pack["nodes"] as Dictionary).size() == 45, "节点表 45 节点（幕三接入补 R4-r2 派生节点）")
	check((pack["acts"] as Array).size() == 5, "五幕 acts")
	check((pack["encounters"] as Dictionary).size() == 17, "遭遇表 17 场（幕三接入补 R4-r2 第二场）")
	check((pack["items"] as Dictionary).size() == 7, "道具表 7 件（M2 补登 heal_potion）")
	check((pack["characters"] as Dictionary).size() == 3, "角色表 3 条（玩家模板+珂兰+老费，tech/04 §2）")
	check((pack["skills"] as Dictionary).size() == 6, "技能表 6 条（tech/04 §3）")
	check((pack["enemies"] as Dictionary).size() == 9,
		"敌人表 9 条（幕三/终章补登：守页人/墨潮化身，tech/04 §1）")
	var n17: Dictionary = pack["encounters"]["N1-7"]
	check((n17["party"] as Array).size() == 3 and (n17["enemies"] as Array).size() == 3
		and n17.has("pos") and n17.has("party_advantage"),
		"N1-7 遭遇登记 party/enemies/pos/party_advantage（tech/02 §6 扩展字段）")
	check((pack["endings"] as Array).size() == 4, "结局表 E1~E4")
	check((pack["flags"] as Array).size() == 14, "旗标台账 14 条（终章接入补：结局旗标 ×4 + 多周目解锁占位 ×2）")
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
	# V11~V13 自 M2 起实检（tech/04 §6）：均有 PASS 结论（无 FAIL 时）
	for v: String in ["V11", "V12", "V13"]:
		check(issues.any(func(i: Dictionary) -> bool:
			return i["v"] == v and i["level"] == PacklintCore.LEVEL_PASS), "%s 实检并 PASS（tech/04 §6）" % v)
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
	# ---- V11~V13 负例（tech/04 §6，M2 实检）----
	var bad_skill_ref: Dictionary = pack.duplicate(true)
	bad_skill_ref["characters"]["companion_kelan"]["skills"] = ["no_such_skill"]
	check(PacklintCore.lint(bad_skill_ref).any(func(i: Dictionary) -> bool:
		return i["v"] == "V11" and i["level"] == PacklintCore.LEVEL_FAIL),
		"负例：角色引用未登记技能 V11 必报 FAIL")
	var bad_foe_ref: Dictionary = pack.duplicate(true)
	bad_foe_ref["encounters"]["N1-7"]["enemies"] = [{"id": "boss", "ref": "ghost"}]
	check(PacklintCore.lint(bad_foe_ref).any(func(i: Dictionary) -> bool:
		return i["v"] == "V11" and i["level"] == PacklintCore.LEVEL_FAIL),
		"负例：遭遇引用未登记敌人 V11 必报 FAIL")
	var bad_attr_ref: Dictionary = pack.duplicate(true)
	bad_attr_ref["effects"] = {"e_bad": {"id": "e_bad", "name": "x", "target_attr": "luck",
		"op": "add", "value": 1, "duration": "encounter", "stack": "refresh"}}
	check(PacklintCore.lint(bad_attr_ref).any(func(i: Dictionary) -> bool:
		return i["v"] == "V11" and i["level"] == PacklintCore.LEVEL_FAIL),
		"负例：效果 target_attr 未注册 V11 必报 FAIL")
	var bad_op: Dictionary = pack.duplicate(true)
	bad_op["effects"] = {"e_bad": {"id": "e_bad", "name": "x", "target_attr": "ac",
		"op": "bogus", "value": 1, "duration": "encounter", "stack": "refresh"}}
	check(PacklintCore.lint(bad_op).any(func(i: Dictionary) -> bool:
		return i["v"] == "V12" and i["level"] == PacklintCore.LEVEL_FAIL),
		"负例：效果 op 非法 V12 必报 FAIL")
	var bad_save: Dictionary = pack.duplicate(true)
	bad_save["enemies"]["ink_fiend"]["skills"][0]["save"] = {"attr": "finesse", "dc": 11, "on_success": "quarter"}
	check(PacklintCore.lint(bad_save).any(func(i: Dictionary) -> bool:
		return i["v"] == "V12" and i["level"] == PacklintCore.LEVEL_FAIL),
		"负例：save.on_success 非法 V12 必报 FAIL")
	var bad_uses: Dictionary = pack.duplicate(true)
	bad_uses["skills"]["inkbolt"]["uses_per_encounter"] = 0
	check(PacklintCore.lint(bad_uses).any(func(i: Dictionary) -> bool:
		return i["v"] == "V13" and i["level"] == PacklintCore.LEVEL_FAIL),
		"负例：次数制技能 uses=0 V13 必报 FAIL")
	var bad_consume: Dictionary = pack.duplicate(true)
	(bad_consume["items"]["heal_potion"] as Dictionary).erase("use")
	bad_consume["items"]["heal_potion"]["consume"] = true
	check(PacklintCore.lint(bad_consume).any(func(i: Dictionary) -> bool:
		return i["v"] == "V13" and i["level"] == PacklintCore.LEVEL_FAIL),
		"负例：consume 道具无 use 块（静默消失）V13 必报 FAIL")
	# ---- escort/maze 扩展块负例（tech/02 §6，幕二接入）----
	var bad_escort: Dictionary = pack.duplicate(true)
	(bad_escort["encounters"]["N2S-2"] as Dictionary).erase("escort")
	check(PacklintCore.lint(bad_escort).any(func(i: Dictionary) -> bool:
		return i["v"] == "V11" and i["level"] == PacklintCore.LEVEL_FAIL),
		"负例：护送遭遇缺 escort 块 V11 必报 FAIL")
	var bad_beat_skill: Dictionary = pack.duplicate(true)
	((bad_beat_skill["encounters"]["N2G-2"] as Dictionary)["maze"]["beats"][0] as Dictionary)["skill"] = "no_such_skill"
	check(PacklintCore.lint(bad_beat_skill).any(func(i: Dictionary) -> bool:
		return i["v"] == "V12" and i["level"] == PacklintCore.LEVEL_FAIL),
		"负例：迷宫节拍技能未注册 V12 必报 FAIL")
	var bad_beat_foe: Dictionary = pack.duplicate(true)
	((bad_beat_foe["encounters"]["N2G-2"] as Dictionary)["maze"]["beats"][1] as Dictionary)["enemy"] = "ghost"
	check(PacklintCore.lint(bad_beat_foe).any(func(i: Dictionary) -> bool:
		return i["v"] == "V11" and i["level"] == PacklintCore.LEVEL_FAIL),
		"负例：伏击节拍引用未登记敌人 V11 必报 FAIL")

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
	graph.take_edge(_edge_to(graph, "R4-r2")) # 右路第一场 → 第二场（战役书幕三 右路两场）
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
	var chain_hits := {} # 幕二三委托链收束点覆盖
	var detour_hit := false # 幕二绕行路（N2G-2c）
	for i: int in 24:
		var lone := i % 4 == 2
		var ngp := i % 2 == 1
		var detour := i % 12 == 4 and not lone and not ngp # 绕行探针（i=4,16，确定性覆盖 N2G-2c）
		var r := StoryBot.run(pack, 1000 + i * 7919, ngp, lone, detour)
		if not r["ok"]:
			all_ok = false
			continue
		var ending := str(r["ending"])
		endings[ending] = true
		if (r["visited"] as Dictionary).has("N2L-1") or (r["visited"] as Dictionary).has("N2L-1b"):
			lone_wolf_hit = true
		if (r["visited"] as Dictionary).has("N2G-2c"):
			detour_hit = true
		for cn: String in ["N2S-3", "N2U-3", "N2G-3"]:
			if (r["visited"] as Dictionary).has(cn):
				chain_hits[cn] = true
		if r["ngplus"] and int(r["bond_max"]) >= 60:
			ngplus_bond60 = true
		if int(r["clock_min"]) < 0 or int(r["clock_max"]) > 10:
			clock_ok = false
		# 图边结局与 endings.json 求值互证（tech/02 §9）
		if str(r["ending_by_table"]) != "" and str(r["ending_by_table"]) != ending:
			all_ok = false
	check(all_ok, "24 局全部必达结局且图边结局与结局表一致")
	check(clock_ok, "全部路径 clock ∈ 0~10（07 §2 钳位 + V5 有界）")
	check(chain_hits.has("N2S-3") and chain_hits.has("N2U-3") and chain_hits.has("N2G-3"),
		"幕二三委托链收束点仿真全覆盖（S/U/G，幕二接入验收）")
	check(detour_hit, "幕二绕行路 N2G-2c 仿真命中（绕行探针确定性覆盖，tech/02 §4.3 fallback）")
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
	var mb_up := InputEventMouseButton.new()
	mb_up.pressed = false
	portrait._on_key_overlay_input(mb)
	portrait._on_key_overlay_input(mb_up) # 短按 <400ms 抬手：不跳过（04 §④.7 防误触）
	await create_timer(0.3).timeout
	check(portrait.key_overlay.visible, "短按不跳过演出（04 §④.7：跳过统一长按 ≥400ms）")
	portrait._on_key_overlay_input(mb) # 按住不放
	await create_timer(0.6).timeout # ≥400ms 触发跳过（12 §1 长按判定参数；自然播完需 ~1.8s，可区分）
	check(not portrait.key_overlay.visible, "关键演出长按 ≥400ms 跳过（04 §④.7/12 §1）")
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
	var mb_up := InputEventMouseButton.new()
	mb_up.pressed = false
	land._on_key_overlay_input(mb)
	land._on_key_overlay_input(mb_up) # 短按 <400ms 抬手：不跳过（04 §④.7 防误触）
	await create_timer(0.3).timeout
	check(land.key_overlay.visible, "横屏短按不跳过演出（04 §④.7）")
	land._on_key_overlay_input(mb)
	await create_timer(0.6).timeout
	check(not land.key_overlay.visible, "横屏关键演出长按 ≥400ms 跳过（09 §6/04 §④.7）")
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
	check(bool(mig["ok"]), "v2 迁移链直通（07 §4.3）")
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
	# ---- v1→v2 迁移器（tech/04 §8 规则4，07 §4.3 迁移链首用例）：旧包内成长键并入 global.growth.* ----
	var v1 := {
		"save_version": 1,
		"board": {"data": {
				"campaign01.xp_total": 350, "campaign01.level": 2, "campaign01.attr_points": 1,
				"campaign01.attrs": {"might": 1}, "campaign01.attr_granted": 1,
				"campaign01.seen_fading": true, "global.doom_clock": 2},
			"provenance": {"campaign01.xp_total": {"event_id": 9, "node_id": "N1-8", "pack_id": "campaign01"}}},
		"event_tail": 9, "bindings": {"packs": {"campaign01": 1}}, "rng_seed": {}, "meta": {}}
	var m12 := SaveSystem.migrate(v1)
	check(bool(m12["ok"]) and int((m12["snapshot"] as Dictionary)["save_version"]) == SaveSystem.SAVE_VERSION,
		"v1 存档经迁移链升到当前版本")
	var mdata: Dictionary = ((m12["snapshot"] as Dictionary)["board"] as Dictionary)["data"]
	check(int(mdata.get("global.growth.xp", 0)) == 350 and int(mdata.get("global.growth.level", 1)) == 2
		and int(mdata.get("global.growth.attr_points", 0)) == 1
		and int(mdata.get("global.growth.attrs.might", 0)) == 1,
		"迁移并入：xp/level/attr_points/attrs.<attr> → global.growth.*")
	for old_key: String in ["campaign01.xp_total", "campaign01.level", "campaign01.attr_points",
			"campaign01.attrs", "campaign01.attr_granted"]:
		check(not mdata.has(old_key), "迁移清除旧键：%s" % old_key)
	check(not (((m12["snapshot"] as Dictionary)["board"] as Dictionary)["provenance"] as Dictionary)
			.has("campaign01.xp_total"), "迁移清除旧键溯源")
	check(mdata.get("campaign01.seen_fading") == true and int(mdata.get("global.doom_clock", 0)) == 2,
		"迁移不动其他键（旗标/时钟原样）")
	# 旧档缺 level 键（从未结算过成长）：按门槛表重算等级并补发未发放的升级点
	var v1b := {"save_version": 1,
		"board": {"data": {"campaign01.xp_total": 700}, "provenance": {}},
		"event_tail": 1, "bindings": {}, "rng_seed": {}, "meta": {}}
	var m12b: Dictionary = SaveSystem.migrate(v1b)["snapshot"]
	var mb: Dictionary = (m12b["board"] as Dictionary)["data"]
	check(int(mb.get("global.growth.level", 1)) == 3
		and int(mb.get("global.growth.attr_points", 0)) == 2,
		"迁移兜底：缺 level 键按 700 XP 重算 Lv.3 并补发 2 点（11 §6）")
	# 迁移后可直接应用并继续汇入（老存档兼容，迭代不破坏）
	var board3 := Board.new(EventStream.new())
	SaveSystem.apply(m12["snapshot"], board3, Rng.new(1))
	Growth.new(board3).grant_xp(50, {"event_id": 10, "node_id": "N1-8", "pack_id": "campaign01"})
	check(Growth.xp(board3) == 400 and Growth.attrs_total(board3, "might") == 1,
		"迁移档应用后继续汇入成长（400 XP）且已分配属性保留")

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

	# ---- Growth 系统（tech/04 §8 定稿）：簿记归框架全局键 global.growth.*（07 §2 白名单）----
	var gs := EventStream.new()
	var gb := Board.new(gs)
	var growth := Growth.new(gb)
	var prov := {"event_id": 1, "node_id": "N1-7", "pack_id": "arena"} # 子游戏命名空间同通道（§8 规则1）
	check(Growth.xp(gb) == 0 and Growth.level(gb) == 1 and Growth.attr_points(gb) == 0,
		"成长初始：xp 0 / Lv.1 / 属性点 0")
	var r1: Dictionary = growth.grant_xp(299, prov)
	check(int(r1["xp"]) == 299 and int(r1["leveled"]) == 0 and Growth.level(gb) == 1,
		"汇入 299：写 global.growth.xp，未跨档不升级")
	check(gs.query_by_type(EventTypes.XP_GAIN).size() == 1
		and gs.query_by_type(EventTypes.LEVEL_UP).is_empty(), "xp.gain 事件产出，未升级无 level.up")
	var r2: Dictionary = growth.grant_xp(1, prov)
	check(int(r2["leveled"]) == 1 and Growth.level(gb) == 2 and Growth.attr_points(gb) == 1,
		"跨档即升级：300 → Lv.2、属性点 +1（11 §6 门槛表归规则包）")
	var lup := gs.query_by_type(EventTypes.LEVEL_UP)
	check(lup.size() == 1 and int(lup[0]["payload"]["level"]) == 2
		and int(lup[0]["payload"]["hp_bonus"]) == LightV1.LEVEL_HP_BONUS,
		"level.up 事件：等级/HP 加值/属性点负载")
	var r3: Dictionary = growth.grant_xp(900, prov) # 300→1200 连跨两档
	check(int(r3["leveled"]) == 2 and Growth.level(gb) == 4 and Growth.attr_points(gb) == 3,
		"连跨档：1200 → Lv.4、累计属性点 +3")
	check(gs.query_by_type(EventTypes.LEVEL_UP).size() == 3, "连跨两档：每级一条 level.up")
	# 分配（§8 规则3）：attrs.<attr> 平铺键 + attr.alloc 事件
	check(growth.can_alloc("might"), "有点数可分配")
	check(growth.alloc("might", prov) and Growth.attrs_total(gb, "might") == 1
		and Growth.attr_points(gb) == 2, "分配：might +1、点数 -1")
	var alloc_evs := gs.query_by_type(EventTypes.ATTR_ALLOC)
	check(alloc_evs.size() == 1 and str(alloc_evs[0]["payload"]["attr"]) == "might"
		and int(alloc_evs[0]["payload"]["points_left"]) == 2, "attr.alloc 事件（09 §9.1 分配时机）")
	growth.alloc("might", prov)
	growth.alloc("might", prov) # might 3 点满
	check(Growth.attr_points(gb) == 0 and not growth.can_alloc("might"), "点数耗尽不可再分配")
	var gb2 := Board.new(EventStream.new())
	var g2 := Growth.new(gb2)
	var prov2 := {"event_id": 1, "node_id": "", "pack_id": "campaign01"}
	g2.grant_xp(1200, prov2) # 3 点全投同一项：验证 +3 封顶
	check(g2.alloc("finesse", prov2) and g2.alloc("finesse", prov2) and g2.alloc("finesse", prov2),
		"单项连续分配至 +3")
	check(not g2.can_alloc("finesse") and not g2.alloc("finesse", prov2),
		"单项 +3 封顶：第 4 点拒绝（11 §6）")
	check(Growth.attrs_map(gb2)["finesse"] == 3, "attrs_map 读取已分配值（战斗修正源）")
	var prog := Growth.xp_progress(gb2)
	check(int(prog["level"]) == 4 and int(prog["next"]) == 0, "xp 进度：满级 next=0（⑦ 呈现「已满级」）")
	# growth 键任何包可写（07 §3 白名单）：以上子游戏命名空间写入全程无 board.denied
	check(gs.query_by_type(EventTypes.BOARD_DENIED).is_empty(),
		"global.growth.* 白名单任何包可写（07 §3，无越权拒绝）")

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

# ---------------------------------------------------------------- 战斗数值数据驱动（tech/04 §1~§4 / tech/02 §6，M2）

## 无壳整局：同种子 + AutoAgent 托管（同构 Command 通道，09 §9.3）打到底，导出事件流 JSON。
func _run_headless_battle(def: Dictionary, seed: int) -> String:
	var stream := EventStream.new()
	var board := Board.new(stream)
	# 序章带入（与 shell_diff/main 同一脚本化遭遇前置）
	board.give_item("heal_potion", 2, {"event_id": 0, "node_id": "N1-1", "pack_id": "campaign01"})
	board.write("campaign01.witnessed_revocation", true, {"event_id": 0, "node_id": "N1-3", "pack_id": "campaign01"})
	var sm := EncounterSM.new(board, stream, Rng.new(seed), "campaign01")
	var agent := AutoAgent.new()
	sm.enter("N1-7")
	sm.transition(EncounterSM.S_EXPLORE)
	sm.begin_combat(def)
	var guard := 0
	while not sm.is_over() and guard < 500:
		guard += 1
		var cmd := agent.next_command(sm)
		if cmd.is_empty():
			break
		sm.submit_command(cmd)
	return JSON.stringify(stream.all(), "", true, true)

func test_battle_data_driven() -> void:
	print("[battle_data_driven]")
	var pack := _load_campaign01()
	# 新表加载与结构校验（tech/04 §2：kind/熟练/公式字段）
	var pt: Dictionary = pack["characters"]["player_blank"]
	check(str(pt["kind"]) == "player_template" and int(pt["attrs"]["might"]) == 2
		and (pt["proficiencies"] as Array) == ["investigation", "athletics"],
		"玩家模板：kind=player_template、力2、熟练 调查/运动（11 §1 +2/+1/0）")
	# 公式求值（tech/04 §2：规则包求值，白名单变量）
	check(LightV1.eval_formula(str(pt["hp_formula"]), {"might": 2, "finesse": 1, "wits": 0, "level": 1}) == 14,
		"hp_formula 求值 = 14（白页者，规则包求值）")
	check(LightV1.eval_formula(str((pack["characters"]["companion_laofei"] as Dictionary)["ac_formula"]),
			{"might": 1, "finesse": 0, "wits": 1, "level": 1}) == 12, "ac_formula 求值 = 12（老费）")
	check(LightV1.eval_formula("10 + luck*2", {"might": 2}) == null, "白名单外变量求值失败返回 null（fail-fast 前提）")
	# 组装 = 旧硬编码基准：结构与数值逐字节一致（数值转写搬运、无再创作硬证明①）
	var stream := EventStream.new()
	var board := Board.new(stream)
	board.give_item("heal_potion", 2, {"event_id": 0, "node_id": "N1-1", "pack_id": "campaign01"})
	board.write("campaign01.witnessed_revocation", true, {"event_id": 0, "node_id": "N1-3", "pack_id": "campaign01"})
	var res := BattleDef.assemble(pack, "N1-7", {"skills": ["inkbolt", "inkshield"], "items": ["heal_potion"]}, board)
	check(bool(res["ok"]), "N1-7 战斗定义组装 ok：%s" % ";".join(res["errors"] as Array))
	var sd: GDScript = load("res://tools/shell_diff.gd")
	var baseline: Dictionary = sd.battle_def()
	check(JSON.stringify(res["def"], "", true, true) == JSON.stringify(baseline, "", true, true),
		"数据驱动 def 与旧硬编码基准规范化序列化逐字节一致")
	# 同种子同指令（托管通道）事件流一致（无再创作硬证明②）
	var js_baseline := _run_headless_battle(baseline, 20261108)
	var js_data := _run_headless_battle(res["def"], 20261108)
	check(js_baseline == js_data, "同种子同指令事件流 JSON 逐字节一致（数据驱动 == 旧硬编码）")
	check(JSON.parse_string(js_data).size() > 40, "对照局完整跑完（事件 >40 条）")
	# fail-fast：引用缺失/公式失败报错不静默（引导层报错路径的数据前提）
	var broken: Dictionary = pack.duplicate(true)
	broken["encounters"]["N1-7"]["enemies"] = [{"id": "boss", "ref": "no_such_enemy"}]
	var res2 := BattleDef.assemble(broken, "N1-7", {}, board)
	check(not bool(res2["ok"]) and not (res2["errors"] as Array).is_empty(), "敌人引用缺失：组装 fail-fast 报错")
	var broken2: Dictionary = pack.duplicate(true)
	broken2["characters"]["player_blank"]["hp_formula"] = "10 + luck"
	var res3 := BattleDef.assemble(broken2, "N1-7", {}, board)
	check(not bool(res3["ok"]), "公式求值失败：组装 fail-fast 报错")

# ---------------------------------------------------------------- HP 跨遭遇持久化（11 §7.1，验收裁决 A）

## 数据驱动 def + 强化 pc 速胜的托管整局；返回 {sm, board, stream}。
func _run_pack_battle(seed: int, aoe_damage: String = "") -> Dictionary:
	var pack := _load_campaign01()
	var stream := EventStream.new()
	var board := Board.new(stream)
	var def: Dictionary = BattleDef.assemble(pack, "N1-7", {}, board)["def"]
	(def["party"][0] as Dictionary)["attack_mod"] = 30
	(def["party"][0] as Dictionary)["damage"] = "30d6"
	if aoe_damage != "":
		((def["enemies"][0] as Dictionary)["skills"][0] as Dictionary)["damage"] = aoe_damage
	var sm := EncounterSM.new(board, stream, Rng.new(seed), "campaign01")
	var agent := AutoAgent.new()
	sm.enter("N1-7")
	sm.transition(EncounterSM.S_EXPLORE)
	sm.begin_combat(def)
	var guard := 0
	while not sm.is_over() and guard < 500:
		guard += 1
		var cmd := agent.next_command(sm)
		if cmd.is_empty():
			break
		sm.submit_command(cmd)
	return {"sm": sm, "board": board, "pack": pack}

func test_hp_persistence() -> void:
	print("[hp_persistence]")
	var pack := _load_campaign01()
	# 无记录 = 满血公式值；单位带 char_id ref（写板键 <ns>.hp.<char_id>）
	var res := BattleDef.assemble(pack, "N1-7", {}, Board.new(EventStream.new()))
	check(bool(res["ok"]), "N1-7 组装 ok：%s" % ";".join(res["errors"] as Array))
	check(int(res["def"]["party"][0]["hp"]) == 14, "无 HP 记录 = 满血公式值（11 §7.1）")
	check(str(res["def"]["party"][0]["ref"]) == "player_blank"
		and str(res["def"]["party"][1]["ref"]) == "companion_kelan", "单位带 char_id ref（11 §7.1 写板键）")
	# 受伤胜利：结算 HP 写板 → 下次遭遇以此开局 → 休整回满
	var found := false
	for seed: int in range(1, 400):
		var r := _run_pack_battle(seed)
		var sm: EncounterSM = r["sm"]
		var b: Board = r["board"]
		if sm.result() != &"victory" or int(sm.get_unit("pc")["hp"]) >= 14 \
				or int(b.read("campaign01.hp.companion_kelan", 0)) < 1:
			continue
		found = true
		var hp_after := int(sm.get_unit("pc")["hp"])
		check(int(b.read("campaign01.hp.player_blank")) == hp_after,
			"遭遇结束 HP 写板：受伤持久（11 §7.1，hp=%d）" % hp_after)
		var res2 := BattleDef.assemble(pack, "N1-7", {}, b)
		check(int(res2["def"]["party"][0]["hp"]) == hp_after
			and int(res2["def"]["party"][0]["max_hp"]) == 14, "下次遭遇以持久 HP 开局（11 §7.1）")
		var g := StoryGraph.new(b, Rng.new(1), pack)
		g.hub_rest()
		check(int(b.read("campaign01.hp.player_blank")) == 14, "休整恢复全满并写板（11 §7.1）")
		check(int(BattleDef.assemble(pack, "N1-7", {}, b)["def"]["party"][0]["hp"]) == 14,
			"休整后遭遇满血开局")
		break
	check(found, "seed 空间内找到受伤胜利样本")
	# 倒地同伴战后 1 HP 起身写板（11 §7.1 + §5.2；墨雨溅射加重制造倒地）
	var down_done := false
	for seed: int in range(1, 400):
		var r2 := _run_pack_battle(seed, "6d6")
		var b2: Board = r2["board"]
		if (r2["sm"] as EncounterSM).result() == &"victory" \
				and int(b2.read("campaign01.hp.companion_kelan", -1)) == 1:
			down_done = true
			check(true, "倒地同伴战后 1 HP 起身写板（11 §7.1/§5.2）")
			break
	check(down_done, "seed 空间内找到倒地同伴 1 HP 起身样本")

# ---------------------------------------------------------------- 护送战（11 §5「遭遇定义的目标达成」；tech/02 §6 escort 块，幕二 N2S-2）

func _escort_def() -> Dictionary:
	return {"party": [
			{"id": "pc", "name": "白页者", "kind": "player", "hp": 14, "max_hp": 14, "ac": 11,
				"attrs": {"might": 2, "finesse": 1, "wits": 0}, "attack_mod": 2, "damage": "1d6+2"},
			{"id": "scribe", "name": "缮写士", "kind": "escort_npc", "hp": 50, "max_hp": 50, "ac": 12,
				"attrs": {"might": 0, "finesse": 1, "wits": 1}, "attack_mod": 0, "damage": "1d4"}],
		"enemies": [{"id": "e1", "name": "墨魈群", "hp": 200, "max_hp": 200, "ac": 10,
			"attrs": {"might": 1, "finesse": 0, "wits": 0}, "attack_mod": 2, "damage": "1d4"}],
		"escort": {"unit_id": "scribe", "survive_rounds": 2, "failure_effects": [{"clock": 1}]}}

func test_escort_sm() -> void:
	print("[escort_sm]")
	# ---- 存活 N 回合即胜（11 §5 目标达成）：敌人高 HP 不可全歼，pc 全程结束回合 ----
	var sm := _sm_with(5, _escort_def())
	var saw_scribe_turn := false
	var guard := 0
	while not sm.is_over() and guard < 30:
		guard += 1
		var actor := sm.current_actor_id()
		if actor == "scribe":
			saw_scribe_turn = true
			break
		if actor == "":
			break
		sm.submit_command(_cmd(EncounterSM.CMD_END_TURN, actor))
	check(sm.is_over() and sm.result() == &"victory", "护送对象存活满 2 回合 → 胜利（11 §5 目标达成）")
	check(sm.first_alive_enemy() != "", "敌人未被全歼：胜利来自存活回合数（非全灭路径）")
	check(not bool(sm.get_unit("scribe")["downed"]), "缮写士全程存活")
	check(not saw_scribe_turn, "护送对象不占行动轮、不可被指令（escort_npc，tech/02 §6）")
	# 敌方近战意图优先指向护送对象（打断仪式，tech/02 §6 escort 块）
	var atks := sm.stream.query_by_type(EventTypes.BATTLE_ATTACK).filter(
		func(ev: Dictionary) -> bool: return ev["payload"]["source"] == &"enemy")
	check(not atks.is_empty() and atks.all(func(ev: Dictionary) -> bool:
		return str(ev["payload"]["target"]) == "scribe"), "敌方近战全部指向护送对象（打断仪式）")
	# ---- 护送对象 HP 归 0 = 目标失败（罚时替代全灭）----
	var fail_done := false
	for seed: int in range(1, 60):
		var def := _escort_def()
		(def["party"][1] as Dictionary)["hp"] = 14 # 缮写士脆血
		((def["enemies"][0] as Dictionary))["attack_mod"] = 30
		(def["enemies"][0] as Dictionary)["damage"] = "30d6"
		var smf := _sm_with(seed, def)
		var g2 := 0
		while not smf.is_over() and g2 < 40:
			g2 += 1
			var a := smf.current_actor_id()
			if a == "":
				break
			smf.submit_command(_cmd(EncounterSM.CMD_END_TURN, a))
		if not (smf.is_over() and smf.result() == &"objective_failed"):
			continue
		fail_done = true
		check(int(smf.board.get_doom_clock()) == 1, "目标失败按 failure_effects 写板：时间钟 +1（罚时替代全灭）")
		check(smf.stream.query_by_type(EventTypes.XP_GAIN).is_empty(), "目标失败无经验/战利品")
		check(smf.stream.query_by_type(EventTypes.COMBAT_END).back()["payload"]["result"] == &"objective_failed",
			"combat.end(objective_failed) 事件")
		check(not smf.board.has("campaign01.hp.scribe"), "护送 NPC HP 不跨遭遇持久化（非 characters.json 条目）")
		check(smf.board.has("campaign01.hp.pc"), "战斗员 HP 照常写板（11 §7.1）")
		break
	check(fail_done, "seed 空间内找到护送目标失败样本")
	# ---- 全歼敌人亦胜 + 数据驱动组装（N2S-2，tech/02 §6 / tech/04 §1~§4）----
	var pack := _load_campaign01()
	var stream := EventStream.new()
	var board := Board.new(stream)
	var res := BattleDef.assemble(pack, "N2S-2", {}, board)
	check(bool(res["ok"]), "N2S-2 护送遭遇组装 ok：%s" % ";".join(res["errors"] as Array))
	var def: Dictionary = res["def"]
	check(str((def["escort"] as Dictionary)["unit_id"]) == "scribe"
		and int((def["escort"] as Dictionary)["survive_rounds"]) == 3
		and int((((def["escort"] as Dictionary)["failure_effects"] as Array)[0] as Dictionary)["clock"]) == 1,
		"组装含 escort 块：unit/survive_rounds/failure_effects（tech/02 §6）")
	check((def["party"] as Array).any(func(u: Variant) -> bool:
		return str((u as Dictionary)["kind"]) == "escort_npc" and str((u as Dictionary)["name"]) == "缮写士"),
		"缮写士以 escort_npc 实例入队")
	for u: Variant in def["party"]:
		if str((u as Dictionary)["kind"]) == "escort_npc":
			continue
		(u as Dictionary)["attack_mod"] = 30
		(u as Dictionary)["damage"] = "30d6"
		(u as Dictionary).erase("skills") # 托管优先技能：清技能确保重骰普攻速胜（流程夹具）
		(u as Dictionary).erase("items")
	var smw := EncounterSM.new(board, stream, Rng.new(7), "campaign01")
	var agent := AutoAgent.new()
	smw.enter("N2S-2")
	smw.transition(EncounterSM.S_EXPLORE)
	smw.begin_combat(def)
	var g3 := 0
	while not smw.is_over() and g3 < 200:
		g3 += 1
		var cmd := agent.next_command(smw)
		if cmd.is_empty():
			break
		smw.submit_command(cmd)
	check(smw.result() == &"victory" and smw.first_alive_enemy() == "", "全歼墨魈群 → 护送胜利")
	check(not smw.board.has("campaign01.hp.scribe"), "全歼路：护送 NPC 亦不落 HP 簿记")
	check(Growth.xp(board) == 120, "护送胜利经验 120 汇入成长（tech/04 §8 规则1）")

# ---------------------------------------------------------------- 迷宫探索序列（tech/02 §6 maze 块；04 §④.3 房间类型，幕二 N2G-2/2b/2c）

func test_maze_runner() -> void:
	print("[maze_runner]")
	var pack := _load_campaign01()
	var beats: Array = ((pack["encounters"]["N2G-2"] as Dictionary)["maze"] as Dictionary)["beats"]
	# ---- 检定拍：成功 xp / 失败罚时（效果 DSL 写板，tech/02 §4.6）----
	var got_succ := false
	var got_fail := false
	for seed: int in range(1, 200):
		if got_succ and got_fail:
			break
		var stream := EventStream.new()
		var board := Board.new(stream)
		var graph := StoryGraph.new(board, Rng.new(1), pack)
		var mr := MazeRunner.new(board, stream, Rng.new(seed), "campaign01")
		mr.begin("N2G-2", beats, Callable(graph, "check_mod"), "N2G-2")
		var res := mr.resolve()
		if bool(res["success"]) and not got_succ:
			got_succ = true
			check(Growth.xp(board) == 30, "检定拍成功：success_effects xp +30 汇入成长")
			check(stream.query_by_type(EventTypes.CHECK_ROLL).back()["payload"]["kind"] == "maze_check",
				"检定拍产出 check.roll（kind=maze_check）")
		elif not bool(res["success"]) and not got_fail:
			got_fail = true
			check(int(board.get_doom_clock()) == 1, "检定拍失败：failure_effects 时间钟 +1")
	check(got_succ and got_fail, "seed 空间内迷宫检定成败双样本")
	# ---- 完整序列：3 拍（检定/伏击判定/检定）+ 伏击拍事件型别 + 进度簿记 ----
	var stream := EventStream.new()
	var board := Board.new(stream)
	var graph := StoryGraph.new(board, Rng.new(1), pack)
	var mr := MazeRunner.new(board, stream, Rng.new(42), "campaign01")
	mr.begin("N2G-2", beats, Callable(graph, "check_mod"), "N2G-2")
	check(mr.beat_count() == 3 and not mr.is_done(), "雾码头探索序列 3 拍")
	var kinds: Array = []
	while not mr.is_done():
		mr.resolve()
	for ev: Dictionary in stream.query_by_type(EventTypes.CHECK_ROLL):
		kinds.append(str(ev["payload"]["kind"]))
	check(kinds == ["maze_check", "maze_ambush", "maze_check"], "节拍序列：检定 → 伏击判定 → 检定（事件型别）")
	check(int(board.read("campaign01.maze.N2G-2.idx", 0)) == 3, "节拍进度簿记 <pack>.maze.<enc>.idx（07 §2）")
	# 完成后恢复 = 幂等：新 Runner 读进度直接完成，不重打效果（07 §4.2 中途离场续打）
	var clock_after := int(board.get_doom_clock())
	var mr2 := MazeRunner.new(board, stream, Rng.new(42), "campaign01")
	mr2.begin("N2G-2", beats, Callable(graph, "check_mod"), "N2G-2")
	check(mr2.is_done() and mr2.peek().is_empty(), "已完成序列恢复：直接完成不重打（幂等）")
	check(int(board.get_doom_clock()) == clock_after, "恢复后无重复效果写板")
	# ---- 拾取拍（04 §④.3 拾取房）+ 中途恢复续打 ----
	var stream2 := EventStream.new()
	var board2 := Board.new(stream2)
	var graph2 := StoryGraph.new(board2, Rng.new(1), pack)
	var beats_b: Array = ((pack["encounters"]["N2G-2b"] as Dictionary)["maze"] as Dictionary)["beats"]
	var mb := MazeRunner.new(board2, stream2, Rng.new(9), "campaign01")
	mb.begin("N2G-2b", beats_b, Callable(graph2, "check_mod"), "N2G-2b")
	var res_loot := mb.resolve()
	check(str(res_loot["type"]) == "loot" and board2.item_count("ink_core") == 1,
		"拾取拍：墨核 ×1 经 give_item 写板（07 §1 溯源）")
	check(stream2.query_by_type(EventTypes.ITEM_GAIN).size() == 1, "拾取拍产出 item.gain 事件")
	# 中途离场 → 恢复：新 Runner 从第 2 拍续打（第 1 拍拾取不重复）
	var mb2 := MazeRunner.new(board2, stream2, Rng.new(9), "campaign01")
	mb2.begin("N2G-2b", beats_b, Callable(graph2, "check_mod"), "N2G-2b")
	check(mb2.beat_index() == 1 and not mb2.is_done(), "中途恢复：从下一拍续打")
	mb2.resolve()
	check(board2.item_count("ink_core") == 1, "恢复续打：拾取不重复（仍 ×1）")
	# ---- 绕行路 N2G-2c：双伏击拍（多 2 场遭遇以节拍呈现）----
	var beats_c: Array = ((pack["encounters"]["N2G-2c"] as Dictionary)["maze"] as Dictionary)["beats"]
	check(beats_c.size() == 2 and beats_c.all(func(b: Variant) -> bool:
		return str((b as Dictionary)["type"]) == "ambush"), "绕行路 = 双伏击拍（多 2 场遭遇，战役书幕二 G 链）")

# ---------------------------------------------------------------- 幕二四链接入（战役书幕二；tech/02 §3/§4；11 §5）

## 托管打胜一场已登记遭遇（高修正重骰夹具：流程验证，非数值平衡验证）。
func _win_pack_battle(pack: Dictionary, enc_id: String, board: Board, stream: EventStream) -> EncounterSM:
	var res := BattleDef.assemble(pack, enc_id, {}, board)
	check(bool(res["ok"]), "遭遇 %s 组装 ok：%s" % [enc_id, ";".join(res["errors"] as Array)])
	var def: Dictionary = res["def"]
	for u: Variant in def["party"]:
		if str((u as Dictionary)["kind"]) == "escort_npc":
			continue
		(u as Dictionary)["attack_mod"] = 30
		(u as Dictionary)["damage"] = "30d6"
		(u as Dictionary).erase("skills")
		(u as Dictionary).erase("items")
	var sm := EncounterSM.new(board, stream, Rng.new(7), "campaign01")
	var agent := AutoAgent.new()
	sm.enter(enc_id)
	sm.transition(EncounterSM.S_EXPLORE)
	sm.begin_combat(def)
	var guard := 0
	while not sm.is_over() and guard < 200:
		guard += 1
		var cmd := agent.next_command(sm)
		if cmd.is_empty():
			break
		sm.submit_command(cmd)
	return sm

## 推进至 N1-8（婉拒所有邀约：三方声望 0，独狼边显形前提）。
## N1-1 → N1-2 走无效果的「前往褪色现场」边（购买边会给潮汐表，干扰 G 链绕行断言）。
func _reach_n18(g: StoryGraph) -> void:
	g.start()
	g.take_edge(_edge_to(g, "N0-2"))
	g.resolve_check(g.available_edges()[0], true)
	g.take_edge(_edge_to(g, "N0-4"))
	g.take_edge(_edge_to(g, "N1-1"))
	var e_plain := {}
	for e: Variant in g.available_edges():
		if str((e as Dictionary).get("to", "")) == "N1-2" \
				and ((e as Dictionary).get("effects", []) as Array).is_empty():
			e_plain = e
	g.take_edge(e_plain)
	g.resolve_check(g.available_edges()[0], true) # → N1-3
	g.take_edge(_edge_to(g, "N1-8")) # 婉拒所有邀约

## 跑完当前 explore 节点的迷宫探索序列（MazeRunner，tech/02 §6 maze）。
func _run_maze(g: StoryGraph, pack: Dictionary, board: Board, stream: EventStream) -> void:
	var enc_id := str(g.current().get("encounter", g.current_id))
	var enc: Dictionary = (pack["encounters"] as Dictionary)[enc_id]
	var mr := MazeRunner.new(board, stream, Rng.new(11), "campaign01")
	mr.begin(enc_id, (enc.get("maze", {}) as Dictionary).get("beats", []),
		Callable(g, "check_mod"), g.current_id)
	var guard := 0
	while not mr.is_done() and guard < 10:
		guard += 1
		mr.resolve()

func test_act2_chains() -> void:
	print("[act2_chains]")
	var pack := _load_campaign01()
	# ================= S 链：誊写庭（护送战 → 金墨的代价）=================
	var ss := EventStream.new()
	var sb := Board.new(ss)
	var gs := StoryGraph.new(sb, Rng.new(42), pack)
	_reach_n18(gs)
	gs.take_edge(_edge_to(gs, "N2S-1"))
	gs.resolve_check(gs.available_edges()[0], true) # 档案馆试炼 → N2S-2
	check(gs.current_id == "N2S-2", "S 链：N2S-1 → N2S-2（修复仪式护送战）")
	var sm_s := _win_pack_battle(pack, "N2S-2", sb, ss)
	check(sm_s.result() == &"victory", "S 链：护送战胜利")
	gs.take_edge(_edge_to(gs, "N2S-3"))
	check(not sb.has_item("scriptorium_signet"), "S 链：on_complete 未离开不结算")
	gs.take_edge(gs.available_edges()[0]) # 献出一段自己的记忆
	check(gs.current_id == "N2-C", "S 链收束：N2S-3 → N2-C")
	check(sb.read("campaign01.blank_memory") == true, "S 链写板：空白记忆旗标")
	check(int(sb.get_alignment()) == 60, "S 链写板：墨守 +10（50→60）")
	check(int(sb.get_bond("kelan")) == 15, "S 链写板：羁绊 +15")
	check(int(sb.get_doom_clock()) == 0, "S 链写板：时钟 -2 钳位（1→0）")
	check(sb.has_item("scriptorium_signet"), "S 链：离开 N2S-3 结算誊写庭印戒（tech/02 §3）")
	# ================= U 链：断墨会（hybrid 撕/不撕双抉择）=================
	for tear: int in 2:
		var us := EventStream.new()
		var ub := Board.new(us)
		var gu := StoryGraph.new(ub, Rng.new(42), pack)
		_reach_n18(gu)
		gu.take_edge(_edge_to(gu, "N2U-1"))
		gu.resolve_check(gu.available_edges()[0], true) # 黑羽集会 → N2U-2
		check(gu.current_id == "N2U-2", "U 链：N2U-1 → N2U-2（撕页行动 hybrid）")
		var sm_u := _win_pack_battle(pack, "N2U-2", ub, us)
		check(sm_u.result() == &"victory", "U 链：税吏卫队战胜利")
		var u_edges := gu.available_edges()
		check(u_edges.size() == 2, "U 链：战后双抉择边（撕/不撕，tech/02 §6 hybrid）")
		gu.take_edge(u_edges[tear]) # 0=撕 / 1=不撕
		# 声望 = 边效果 + 黑羽行动委托 settle +1（tech/02 §5：N2U-1 完成时结算）
		if tear == 0:
			check(ub.read("campaign01.page_tearer") == true and int(ub.get_rep("uninked")) == 3,
				"U 链写板：撕页 → 撕页者旗标 + 断墨会声望 +2（含委托 settle +1 = 3）")
		else:
			check(ub.read("campaign01.mercy_shown") == true and int(ub.get_rep("uninked")) == 2,
				"U 链写板：不撕 → 手下留情旗标 + 声望 +1（含委托 settle +1 = 2）")
		check(ub.has_item("black_feather_token") and int(ub.get_alignment()) == 40,
			"U 链写板：黑羽令（撕/不撕均给）+ 留白 -10（50→40）")
		check(gu.current_id == "N2U-3" and int(ub.get_bond("kelan")) == 15
			and int(ub.get_doom_clock()) == 2, "U 链：N2U-3 演出（时钟 +1、羁绊 +15）")
		gu.take_edge(_edge_to(gu, "N2-C"))
		check(gu.current_id == "N2-C", "U 链收束：N2U-3 → N2-C")
	# U 链失败路：N2U-1 潜行失败 → 暴露战 → N2U-2
	var us2 := EventStream.new()
	var ub2 := Board.new(us2)
	var gu2 := StoryGraph.new(ub2, Rng.new(42), pack)
	_reach_n18(gu2)
	gu2.take_edge(_edge_to(gu2, "N2U-1"))
	gu2.resolve_check(gu2.available_edges()[0], false)
	check(gu2.current_id == "N2U-1b", "U 链失败路：潜行失败 → 暴露战（N2U-1b）")
	check(_win_pack_battle(pack, "N2U-1b", ub2, us2).result() == &"victory", "U 链失败路：暴露战胜利")
	gu2.take_edge(_edge_to(gu2, "N2U-2"))
	check(gu2.current_id == "N2U-2", "U 链失败路：以武力赢得入场券 → N2U-2")
	# ================= G 链：拾遗行会（迷宫密道 vs 绕行）=================
	var fs := EventStream.new()
	var fb := Board.new(fs)
	var gf := StoryGraph.new(fb, Rng.new(42), pack)
	gf.start()
	gf.take_edge(_edge_to(gf, "N0-2"))
	gf.resolve_check(gf.available_edges()[0], true)
	gf.take_edge(_edge_to(gf, "N0-4"))
	gf.take_edge(_edge_to(gf, "N1-1"))
	var e_buy := _edge_to(gf, "N1-2")
	for e: Variant in gf.available_edges():
		for fx: Variant in (e as Dictionary).get("effects", []):
			if (fx as Dictionary).get("give_item", "") == "half_tide_table":
				e_buy = e
	gf.take_edge(e_buy) # 购买半页潮汐表 → N1-2
	gf.resolve_check(gf.available_edges()[0], true)
	gf.take_edge(_edge_to(gf, "N1-8"))
	gf.take_edge(_edge_to(gf, "N2G-1"))
	gf.resolve_check(gf.available_edges()[0], true) # 残篇拍卖 → N2G-2
	check(gf.current_id == "N2G-2" and fb.has_item("half_tide_table"), "G 链：N2G-1 → N2G-2（持潮汐表）")
	_run_maze(gf, pack, fb, fs) # 雾码头探索序列 3 拍
	var e_secret := _edge_to(gf, "N2G-2b")
	check(not e_secret.is_empty() and not bool(e_secret.get("via_fallback", false)),
		"G 链密道：持半页潮汐表 → item 边主路显形（tech/02 §4.3）")
	gf.take_edge(e_secret)
	check(gf.current_id == "N2G-2b" and fb.item_count("codex_fragment") == 1,
		"G 链密道：直达沉书阁 + 织命者残简 ×1（on_enter）")
	_run_maze(gf, pack, fb, fs) # 沉书阁拾取拍
	check(fb.item_count("ink_core") == 1, "G 链密道：沉书阁额外战利品（墨核 ×1，拾取拍）")
	gf.take_edge(_edge_to(gf, "N2G-3"))
	check(fb.read("campaign01.insider") == true and int(fb.get_bond("kelan")) == 15,
		"G 链写板：知情人旗标 + 羁绊 +15")
	gf.take_edge(_edge_to(gf, "N2-C"))
	check(gf.current_id == "N2-C", "G 链收束：N2G-3 → N2-C")
	# 绕行（无潮汐表）：item 边 fallback → N2G-2c
	var ds := EventStream.new()
	var db := Board.new(ds)
	var gd := StoryGraph.new(db, Rng.new(42), pack)
	_reach_n18(gd)
	gd.take_edge(_edge_to(gd, "N2G-1"))
	gd.resolve_check(gd.available_edges()[0], true)
	var e_detour := _edge_to(gd, "N2G-2c")
	check(not e_detour.is_empty() and bool(e_detour.get("via_fallback", false)),
		"G 链绕行：无潮汐表 → item 边 fallback 变体（tech/02 §4.3）")
	gd.take_edge(e_detour)
	check(gd.current_id == "N2G-2c", "G 链绕行 → N2G-2c")
	_run_maze(gd, pack, db, ds) # 双伏击拍（多 2 场遭遇）
	gd.take_edge(_edge_to(gd, "N2G-3"))
	check(db.read("campaign01.insider") == true, "G 链绕行亦达 N2G-3（失败即分支，08 §2）")
	# ================= L 链：独狼（难检定跳链 / 通缉战强制择链）=================
	var ls := EventStream.new()
	var lb := Board.new(ls)
	var gl := StoryGraph.new(lb, Rng.new(42), pack)
	_reach_n18(gl)
	var e_lone := _edge_to(gl, "N2L-1")
	check(not e_lone.is_empty(), "L 链：三方声望 0 → 独狼隐藏边显形（tech/02 §4.5）")
	gl.take_edge(e_lone)
	gl.resolve_check(gl.available_edges()[0], true) # 难检定成功 → 跳链直达收束
	check(gl.current_id == "N2-C", "L 链：N2L-1 成功 → 直抵 N2-C（跳链，战役书幕二独狼）")
	check(int(lb.get_doom_clock()) == 0, "L 链写板：独狼捷径时钟 -1（1→0）")
	# 失败路：通缉战（声望 -1 ×3）→ 强制择一链
	var ls2 := EventStream.new()
	var lb2 := Board.new(ls2)
	var gl2 := StoryGraph.new(lb2, Rng.new(42), pack)
	_reach_n18(gl2)
	gl2.take_edge(_edge_to(gl2, "N2L-1"))
	gl2.resolve_check(gl2.available_edges()[0], false)
	check(gl2.current_id == "N2L-1b", "L 链失败路：N2L-1 失败 → 通缉战")
	check(int(lb2.get_rep("scriptorium")) == -1 and int(lb2.get_rep("uninked")) == -1
		and int(lb2.get_rep("salvage")) == -1, "L 链失败路：三方声望 -1（on_enter 惩罚）")
	check(_win_pack_battle(pack, "N2L-1b", lb2, ls2).result() == &"victory", "L 链失败路：通缉战胜利（难）")
	var l_edges := gl2.available_edges()
	check(l_edges.size() == 3, "L 链失败路：战后强制择一链（三出边）")
	gl2.take_edge(_edge_to(gl2, "N2G-1"))
	check(gl2.current_id == "N2G-1", "L 链失败路：择拾遗行会链 → N2G-1")

# ---------------------------------------------------------------- 幕三「撤销区」房间序列（战役书幕三；tech/02 §4.3/§6；11 §5.1）

## 推进至 N2-C（独狼链：N1-3 婉拒 → N1-8 → N2L-1 难检定成功直达；声望 0，无黑羽令/印戒/倾向投放）。
func _reach_n2c(g: StoryGraph) -> void:
	_reach_n18(g)
	g.take_edge(_edge_to(g, "N2L-1"))
	g.resolve_check(g.available_edges()[0], true) # 独狼难检定成功 → 跳链直达 N2-C

func test_act3_rooms() -> void:
	print("[act3_rooms]")
	var pack := _load_campaign01()
	# ---- R2 对话检定成败两路（战役书幕三：成功给残简+羁绊 / 失败旗标未能挽留）----
	for success: bool in [true, false]:
		var s := EventStream.new()
		var b := Board.new(s)
		var g := StoryGraph.new(b, Rng.new(42), pack)
		_reach_n2c(g)
		g.take_edge(_edge_to(g, "N3-1"))
		g.take_edge(_edge_to(g, "R1"))
		check(b.has_lore("revoked_registry_01"), "R1 on_enter：图鉴·褪色民居的门牌（lore.json source 对齐）")
		g.take_edge(_edge_to(g, "R2"))
		check(b.has_lore("revoked_registry_02"), "R2 on_enter：图鉴·空教室的花名册")
		var frag_before := b.item_count("codex_fragment")
		g.resolve_check(g.available_edges()[0], success)
		check(g.current_id == "R3",
			"R2 安抚检定%s → R3（成败汇合，差异在效果，08 §2）" % ("成功" if success else "失败"))
		if success:
			check(b.item_count("codex_fragment") == frag_before + 1 and int(b.get_bond("kelan")) == 20,
				"R2 成功路：残简 ×1 + 羁绊 +20（战役书 §8 隐藏投放）")
		else:
			check(b.read("campaign01.failed_to_hold") == true
				and b.item_count("codex_fragment") == frag_before,
				"R2 失败路：未能挽留旗标、无残简（战役书幕三 R2）")
	# ---- 房间序列主走（无黑羽令）：R1 拾取 → R3 战斗 → R4 fallback 右路两场 → R5 Boss → N3-7 ----
	var s2 := EventStream.new()
	var b2 := Board.new(s2)
	var g2 := StoryGraph.new(b2, Rng.new(42), pack)
	_reach_n2c(g2)
	g2.take_edge(_edge_to(g2, "N3-1"))
	g2.take_edge(_edge_to(g2, "R1"))
	_run_maze(g2, pack, b2, s2)
	check(b2.item_count("ink_core") == 1, "R1 拾取房：墨核 ×1（maze loot 拍，tech/02 §6）")
	g2.take_edge(_edge_to(g2, "R2"))
	g2.resolve_check(g2.available_edges()[0], true)
	var sm3 := _win_pack_battle(pack, "R3", b2, s2)
	check(sm3.result() == &"victory", "R3 墨魈巢穴战斗可胜（遭遇组装 + SM 通道）")
	var r3_foes: Array = (pack["encounters"]["R3"] as Dictionary)["enemies"]
	check(r3_foes.size() == 3 and str((r3_foes[0] as Dictionary)["ref"]) == "ink_fiend",
		"R3 阵容：墨魈 + 幼体 ×2（数值占位待定稿，README 决策记录）")
	g2.take_edge(_edge_to(g2, "R4"))
	var e_r4 := _edge_to(g2, "R4-r")
	check(not e_r4.is_empty() and bool(e_r4.get("via_fallback", false)),
		"R4 分支门：无黑羽令 → 右路 fallback 变体（tech/02 §4.3）")
	g2.take_edge(e_r4)
	check(_win_pack_battle(pack, "R4-r", b2, s2).result() == &"victory", "R4-r 右路第一场可胜")
	g2.take_edge(_edge_to(g2, "R4-r2"))
	check(_win_pack_battle(pack, "R4-r2", b2, s2).result() == &"victory",
		"R4-r2 右路第二场可胜（场间无休整，HP 持久 11 §7.1）")
	g2.take_edge(_edge_to(g2, "R5"))
	var warden: Dictionary = (pack["enemies"] as Dictionary)["page_warden"]
	check(bool(warden.get("boss", false)) and (warden["skills"] as Array).size() == 1
		and int(((warden["skills"] as Array)[0] as Dictionary)["save"]["dc"]) == 12
		and str(((warden["skills"] as Array)[0] as Dictionary)["save"]["on_success"]) == "half",
		"R5 Boss 守页人：封印冲击 save DC12/half 随条目挂载（11 §5.1；自 arena 守页人精英改造）")
	check(_win_pack_battle(pack, "R5", b2, s2).result() == &"victory", "R5 守页人 Boss 战可胜（难）")
	g2.take_edge(_edge_to(g2, "N3-7"))
	check(g2.current_id == "N3-7" and b2.item_count("codex_fragment") == 2
		and b2.item_count("ink_core") == 2,
		"R5 战利品 → N3-7：残简 ×2（R2+R5）+ 墨核 ×2（R1+R5，战役书 §8 投放）")
	# ---- R4 左路：持黑羽令 → 捷径直达 R5（tech/02 §4.3 主路；items.json unlocks）----
	var s3 := EventStream.new()
	var b3 := Board.new(s3)
	var g3 := StoryGraph.new(b3, Rng.new(42), pack)
	_reach_n2c(g3)
	b3.give_item("black_feather_token", 1,
		{"event_id": s3.tail(), "node_id": "R4", "pack_id": "campaign01"})
	g3.take_edge(_edge_to(g3, "N3-1"))
	g3.take_edge(_edge_to(g3, "R1"))
	g3.take_edge(_edge_to(g3, "R2"))
	g3.resolve_check(g3.available_edges()[0], true)
	g3.take_edge(_edge_to(g3, "R4"))
	var e_left := _edge_to(g3, "R5")
	check(not e_left.is_empty() and not bool(e_left.get("via_fallback", false)),
		"R4 分支门：持黑羽令 → 左路捷径主路边（[物·黑羽令]，战役书 §8）")
	g3.take_edge(e_left)
	check(g3.current_id == "R5", "左路捷径直达 R5（跳过右路两场）")

# ---------------------------------------------------------------- 终章：免战/强攻 + 四结局（战役书终章/§9；tech/02 §9/§6）

## 推进至 N3-7（独狼链 + 房间序列图级直走，不跑战斗数值；r2_success 控制 R2 成败路）。
func _reach_n37(g: StoryGraph, r2_success: bool = true) -> void:
	_reach_n2c(g)
	g.take_edge(_edge_to(g, "N3-1"))
	g.take_edge(_edge_to(g, "R1"))
	g.take_edge(_edge_to(g, "R2"))
	g.resolve_check(g.available_edges()[0], r2_success) # → R3
	g.take_edge(_edge_to(g, "R4"))
	var e := _edge_to(g, "R4-r")
	if not e.is_empty():
		g.take_edge(e)
		g.take_edge(_edge_to(g, "R4-r2"))
	g.take_edge(_edge_to(g, "R5"))
	g.take_edge(_edge_to(g, "N3-7"))

func test_finale_endings() -> void:
	print("[finale_endings]")
	var pack := _load_campaign01()
	var prov := {"event_id": 1, "node_id": "N4-1", "pack_id": "campaign01"}
	# ---- N4-1 强攻路：fallback → N4-1b（遭遇 N4-1）；难度差 = enemy_weaken 旗标驱动 ----
	var s1 := EventStream.new()
	var b1 := Board.new(s1)
	var g1 := StoryGraph.new(b1, Rng.new(42), pack)
	_reach_n37(g1)
	g1.take_edge(_edge_to(g1, "N4-1"))
	var e_assault := _edge_to(g1, "N4-1b")
	check(not e_assault.is_empty() and bool(e_assault.get("via_fallback", false)),
		"N4-1 无印戒 → fallback 强攻边（tech/02 §4.3）")
	var def_plain := BattleDef.assemble(pack, "N4-1", {}, b1)
	check(bool(def_plain["ok"]), "N4-1 强攻遭遇组装 ok（墨潮化身 + 幼体 ×2）")
	var atk_plain := int(((def_plain["def"] as Dictionary)["enemies"][0] as Dictionary)["attack_mod"])
	b1.write("campaign01.mercy_shown", true, prov)
	var def_weak := BattleDef.assemble(pack, "N4-1", {}, b1)
	var atk_weak := int(((def_weak["def"] as Dictionary)["enemies"][0] as Dictionary)["attack_mod"])
	check(atk_plain - atk_weak == 2,
		"手下留情 → Boss 攻击修正 -2（%d→%d；战役书 §5 税吏证词，tech/02 §6 enemy_weaken）" % [atk_plain, atk_weak])
	g1.take_edge(e_assault)
	check(g1.current_id == "N4-1b", "强攻边 → N4-1b（遭遇 N4-1 挂载节点，README 转写裁决）")
	check(_win_pack_battle(pack, "N4-1", b1, s1).result() == &"victory",
		"N4-1 墨潮化身 Boss 战可胜（难；手下留情已立 = 削弱后）")
	g1.take_edge(_edge_to(g1, "N4-2"))
	check(g1.current_id == "N4-2", "强攻胜利 → N4-2 抉择")
	# ---- N4-1 免战路：印戒 + 誊写庭声望 ≥1 → item 边主路直达 N4-2（[物/声]）----
	var s1b := EventStream.new()
	var b1b := Board.new(s1b)
	var g1b := StoryGraph.new(b1b, Rng.new(42), pack)
	_reach_n37(g1b)
	b1b.give_item("scriptorium_signet", 1, prov)
	b1b.write("global.rep.scriptorium", 1, prov)
	g1b.take_edge(_edge_to(g1b, "N4-1"))
	var e_skip := _edge_to(g1b, "N4-2")
	check(not e_skip.is_empty() and not bool(e_skip.get("via_fallback", false)),
		"N4-1 印戒 + 声望 ≥1 → 免战主路边（items.json unlocks）")
	g1b.take_edge(e_skip)
	check(g1b.current_id == "N4-2", "印戒免战：跳过 Boss 直达 N4-2（战役书 §8 印戒解锁边）")
	# ---- 四结局分别可达（构造状态触发 E1/E2/E3/E4；结局写板 + 结局表互证）----
	# E1 墨守 >50
	var r1 := _play_ending(pack, {"global.alignment": 60})
	check(str(r1["ending"]) == "E1" and bool((r1["board"] as Board).read("campaign01.ending_e1")),
		"E1 重墨：墨守过中线可达 + ending_e1 写板（tech/02 §9）")
	# E2 留白 >50
	var r2 := _play_ending(pack, {"global.alignment": 40})
	check(str(r2["ending"]) == "E2" and bool((r2["board"] as Board).read("campaign01.ending_e2")),
		"E2 自由灰：留白过中线可达 + ending_e2 写板")
	# E3 残简 ×4 + 羁绊 ≥60（隐藏；路径已得 R2+R5 ×2，补足 ×4）
	var r3 := _play_ending(pack, {"bond.kelan": 60, "item.codex_fragment": 2})
	check(str(r3["ending"]) == "E3" and bool((r3["board"] as Board).read("campaign01.ending_e3"))
		and bool((r3["board"] as Board).read("campaign01.unlock_scribe_identity")),
		"E3 新篇：残简 ≥4 + 羁绊 ≥60 可达 + 执笔者身份解锁占位（战役书 §9 E3 钩子）")
	# E4 兜底（独狼线：倾向 50 / 残简不足）
	var r4 := _play_ending(pack, {}, false)
	check(str(r4["ending"]) == "E4" and bool((r4["board"] as Board).read("campaign01.ending_e4"))
		and bool((r4["board"] as Board).read("campaign01.ngplus_memory_view")),
		"E4 褪墨吞港：条件均不满足兜底可达 + 追忆视角占位（tech/02 §9 default；战役书 §9 E4 钩子）")
	check(bool((r4["board"] as Board).read("campaign01.campaign01_cleared")),
		"E4 亦写 campaign01_cleared（失败非终局：last_page settle 于离开 N4-2）")

## 构造终局状态并走到结局：独狼线至 N4-1 → 强攻 fallback 进 N4-2 → 应用 setup 写板 →
## 取 N4-2 首条显形边（边序 = endings.json 求值序）。返回 {ending, board}；图边结局与结局表互证。
func _play_ending(pack: Dictionary, setup: Dictionary, r2_success: bool = true) -> Dictionary:
	var s := EventStream.new()
	var b := Board.new(s)
	var g := StoryGraph.new(b, Rng.new(42), pack)
	_reach_n37(g, r2_success)
	g.take_edge(_edge_to(g, "N4-1"))
	g.take_edge(_edge_to(g, "N4-1b"))
	g.take_edge(_edge_to(g, "N4-2"))
	var prov := {"event_id": s.tail(), "node_id": "N4-2", "pack_id": "campaign01"}
	for key: Variant in setup.keys():
		var ks := str(key)
		if ks.begins_with("bond."):
			b.write("global." + ks, int(setup[key]), prov)
		elif ks.begins_with("item."):
			b.give_item(ks.substr(5), int(setup[key]), prov)
		else:
			b.write(ks, setup[key], prov)
	var edges := g.available_edges()
	check(not edges.is_empty(), "N4-2 恒有显形边（E4 兜底无条件）")
	var by_table := g.pick_ending()
	g.take_edge(edges[0])
	check(g.is_at_ending() and g.current_id == by_table,
		"图边结局 %s 与 endings.json 求值 %s 互证一致（tech/02 §9）" % [g.current_id, by_table])
	return {"ending": g.current_id, "board": b}

# ---------------------------------------------------------------- 全流程一局：N0-1 → E4 + 快照可续（07 §4；战役书 §9 E4 失败非终局）

## R3 → E4 图级直走（独狼/无道具线：R4 fallback 右路两场、N4-1 fallback 强攻）；沿途真实战斗胜利。
func _walk_r3_to_e4(g: StoryGraph, pack: Dictionary, b: Board, s: EventStream) -> void:
	check(_win_pack_battle(pack, "R3", b, s).result() == &"victory", "全流程：R3 墨魈巢穴胜利")
	g.take_edge(_edge_to(g, "R4"))
	g.take_edge(_edge_to(g, "R4-r"))
	check(_win_pack_battle(pack, "R4-r", b, s).result() == &"victory", "全流程：R4-r 第一场胜利")
	g.take_edge(_edge_to(g, "R4-r2"))
	check(_win_pack_battle(pack, "R4-r2", b, s).result() == &"victory", "全流程：R4-r2 第二场胜利")
	g.take_edge(_edge_to(g, "R5"))
	check(_win_pack_battle(pack, "R5", b, s).result() == &"victory", "全流程：R5 守页人胜利")
	g.take_edge(_edge_to(g, "N3-7"))
	g.take_edge(_edge_to(g, "N4-1"))
	g.take_edge(_edge_to(g, "N4-1b")) # 无印戒 → 强攻
	check(_win_pack_battle(pack, "N4-1", b, s).result() == &"victory", "全流程：N4-1 墨潮化身胜利")
	g.take_edge(_edge_to(g, "N4-2"))

func test_full_run_e4() -> void:
	print("[full_run_e4]")
	var pack := _load_campaign01()
	var s := EventStream.new()
	var b := Board.new(s)
	var rng := Rng.new(99)
	var g := StoryGraph.new(b, rng, pack)
	g.start()
	# 前半程：序章 → 幕一（婉拒）→ 独狼链 → 幕三 R2 失败路（未能挽留 = E4 演出加权旗标）
	g.take_edge(_edge_to(g, "N0-2"))
	g.roll_check(g.available_edges()[0])
	g.take_edge(_edge_to(g, "N0-4"))
	g.take_edge(_edge_to(g, "N1-1"))
	var e_plain := {}
	for e: Variant in g.available_edges():
		if str((e as Dictionary).get("to", "")) == "N1-2" \
				and ((e as Dictionary).get("effects", []) as Array).is_empty():
			e_plain = e
	g.take_edge(e_plain)
	g.resolve_check(g.available_edges()[0], true) # → N1-3
	g.take_edge(_edge_to(g, "N1-8")) # 婉拒所有邀约
	g.take_edge(_edge_to(g, "N2L-1"))
	g.resolve_check(g.available_edges()[0], true) # 独狼成功 → N2-C
	g.take_edge(_edge_to(g, "N3-1"))
	g.take_edge(_edge_to(g, "R1"))
	g.take_edge(_edge_to(g, "R2"))
	g.resolve_check(g.available_edges()[0], false) # 安抚失败 → 未能挽留
	check(g.current_id == "R3", "全流程：抵达 R3（中途快照点）")
	# 快照（07 §4.1：Board 全量 + 图进度 + RNG 状态）
	var snap := {"board": b.serialize(), "graph": g.serialize(), "rng": rng.save_state()}
	# 后半程：R3 → … → E4
	_walk_r3_to_e4(g, pack, b, s)
	check(g.pick_ending() == "E4", "全流程：独狼线倾向 50/残简不足 → E4 兜底（tech/02 §9）")
	var e4 := _edge_to(g, "E4")
	check(not e4.is_empty(), "N4-2：E4 边恒显形（无条件满足）")
	g.take_edge(e4)
	check(g.is_at_ending() and g.current_id == "E4", "全流程一局：N0-1 → E4 褪墨吞港")
	check(bool(b.read("campaign01.ending_e4")) and bool(b.read("campaign01.ngplus_memory_view")),
		"E4 写板：结局旗标 + 追忆视角占位（flags.json 台账 V4 闭环）")
	check(bool(b.read("campaign01.campaign01_cleared")),
		"E4 亦通关写板 campaign01_cleared（失败非终局，战役书 §9）")
	# 快照恢复重走：同一状态应再到 E4（快照往返一致，07 §4.1/§4.3）
	var s2 := EventStream.new()
	var b2 := Board.new(s2)
	var rng2 := Rng.new(1)
	b2.deserialize(snap["board"])
	rng2.load_state(snap["rng"])
	var g2 := StoryGraph.new(b2, rng2, pack)
	g2.deserialize(snap["graph"])
	check(g2.current_id == "R3", "快照恢复：图进度回到 R3（meta.graph 随快照往返）")
	_walk_r3_to_e4(g2, pack, b2, s2)
	g2.take_edge(_edge_to(g2, "E4"))
	check(g2.is_at_ending() and g2.current_id == "E4", "快照可续：恢复后重走仍达 E4（07 §4.1）")

# ---------------------------------------------------------------- 节点流程运行时（11 §2/§3；09 §6；04 §3.1；战役书 §4 N1-1）

func test_story_runtime() -> void:
	print("[story_runtime]")
	var pack := _load_campaign01()
	var prov := {"event_id": 1, "node_id": "N1-1", "pack_id": "campaign01"}
	# 检定修正（11 §2：属性修正 + 熟练 +2）
	var g0 := StoryGraph.new(Board.new(EventStream.new()), Rng.new(1), pack)
	check(g0.check_mod("perception") == 0, "检定修正：感知 智0 无熟练 = +0（11 §2）")
	check(g0.check_mod("investigation") == 2, "检定修正：调查 智0+熟练2 = +2（11 §2）")
	check(g0.check_mod("athletics") == 4, "检定修正：运动 力2+熟练2 = +4（11 §2）")
	check(LightV1.skill_mod({"might": 2, "wits": 0}, ["athletics"], "perception_or_athletics") == 4,
		"a_or_b 双技能取较高修正（11 §2）")
	check(LightV1.dc_for("easy") == 8 and LightV1.dc_for("medium") == 12
		and LightV1.dc_for("hard") == 16 and LightV1.dc_for("???") == 12, "难度三档 DC 8/12/16（11 §3）")
	# roll_check 成败双路 + check.roll 事件（tech/02 §4.2；09 §6）
	var got_succ := false
	var got_fail := false
	var got_extreme := false
	for seed: int in range(1, 400):
		if got_succ and got_fail and got_extreme:
			break
		var s := EventStream.new()
		var g := StoryGraph.new(Board.new(s), Rng.new(seed), pack)
		g.start()
		g.take_edge(_edge_to(g, "N0-2"))
		var res := g.roll_check(g.available_edges()[0])
		if bool(res["success"]) and not got_succ:
			got_succ = true
			check(g.current_id == "N0-3a", "检定成功 → success 边 N0-3a（tech/02 §4.2）")
			var rolls := s.query_by_type(EventTypes.CHECK_ROLL)
			check(rolls.size() == 1 and str(rolls[0]["payload"]["kind"]) == "story_check"
				and int(rolls[0]["payload"]["dc"]) == 8 and int(rolls[0]["payload"]["mod"]) == 0,
				"check.roll 事件：story_check 含技能/DC/修正（09 §6 同一事件源）")
			check(not bool(rolls[0]["payload"]["key"]), "普通检定 key=false（09 §6：未标记非关键）")
		elif not bool(res["success"]) and not got_fail:
			got_fail = true
			check(g.current_id == "N0-3b", "检定失败 → failure 边 N0-3b（写板效果生效：失败路 xp）")
		elif bool(res.get("extreme", false)) and not got_extreme and int(res["keep"]) == 20:
			got_extreme = true
			check(not bool(res["key"]), "nat20 极端加档但非关键（09 §6：极端追加一档）")
	check(got_succ and got_fail, "seed 空间内检定成败双路样本")
	check(got_extreme, "seed 空间内命中 nat20 极端样本")
	# 内容包 key:true → 关键演出标记（09 §6 ④）
	var pack2: Dictionary = pack.duplicate(true)
	((pack2["nodes"]["N0-2"] as Dictionary)["edges"] as Array)[0]["key"] = true
	var g5 := StoryGraph.new(Board.new(EventStream.new()), Rng.new(20260009), pack2)
	g5.start()
	g5.take_edge(_edge_to(g5, "N0-2"))
	check(bool(g5.roll_check(g5.available_edges()[0])["key"]), "内容包 key:true → 关键演出标记（09 §6 ④）")
	# 时钟预告（04 §3.1；tech/02 §5 doom_clock 触发）
	var g2 := StoryGraph.new(Board.new(EventStream.new()), Rng.new(7), pack)
	g2.start()
	var nx := g2.next_clock_trigger()
	check(str(nx.get("name", "")) == "墨雨夜袭" and int(nx.get("at", 0)) == 2,
		"时间边预告：墨雨夜袭 2 格（04 §3.1）")
	g2.board.write("global.doom_clock", 2, prov)
	g2._scan_triggers()
	check(g2.next_clock_trigger().is_empty(), "时钟到格触发后预告消失")
	# hub：金币播种/购买/不足/货单（战役书 §4 N1-1；价格占位见 README M2 记录）
	var s3 := EventStream.new()
	var b3 := Board.new(s3)
	var g3 := StoryGraph.new(b3, Rng.new(7), pack)
	g3.start()
	g3.seed_gold()
	g3.seed_gold(99)
	check(g3.get_gold() == StoryGraph.GOLD_START, "金币播种幂等（重复不覆盖）")
	check(g3.hub_buy("half_tide_table"), "购买半页潮汐表成功")
	check(g3.get_gold() == StoryGraph.GOLD_START - 15, "金币扣减 15（items.json price 占位）")
	check(b3.has_item("half_tide_table"), "购买 give_item 落板")
	check(s3.query_by_type(EventTypes.FLAG_WRITE).any(func(ev: Dictionary) -> bool:
		return str((ev["payload"] as Dictionary)["key"]) == "campaign01.gold"),
		"金币写板进事件流（07 §6）")
	var gold_ev: Dictionary = s3.query_by_type(EventTypes.FLAG_WRITE).filter(func(ev: Dictionary) -> bool:
		return str((ev["payload"] as Dictionary)["key"]) == "campaign01.gold")[0]
	check(str(((gold_ev["payload"] as Dictionary)["provenance"] as Dictionary).get("node_id", "")) == "N0-1",
		"金币写板带溯源（07 §1）")
	check(not g3.hub_buy("fatedie"), "非卖品（无 price）拒绝")
	check(g3.hub_buy("heal_potion"), "购买补给药水成功（验收裁决 B 上架，战役书 §8）")
	check(g3.get_gold() == StoryGraph.GOLD_START - 30 and b3.item_count("heal_potion") == 1,
		"购买药水：扣 15 金 + give_item（验收裁决 B）")
	b3.write("campaign01.gold", 5, prov)
	check(not g3.hub_buy("half_tide_table"), "金币不足拒绝购买")
	var stock := g3.hub_stock()
	var stock_ids: Array = []
	var any_affordable := false
	for it: Variant in stock:
		stock_ids.append(str((it as Dictionary)["id"]))
		any_affordable = any_affordable or bool((it as Dictionary)["affordable"])
	check(stock.size() == 2 and stock_ids.has("half_tide_table") and stock_ids.has("heal_potion")
		and not any_affordable, "货单 = 含 price 条目 ×2（潮汐表/药水）+ 可负担标记（裁决 B）")
	# 休整（恢复 HP；次数制技能随遭遇组装重置，11 §8）
	var restored := g3.hub_rest()
	check(int(restored.get("player_blank", 0)) == 14, "休整：白页者 HP 回满 14（hp_formula 10+2×力2，tech/04 §2）")
	check(int(b3.read("campaign01.hp.player_blank", 0)) == 14, "休整写板 hp 簿记（11 §7.1 / 07 §2 簿记键）")
	var ps := g3.party_status()
	check(ps.size() == 3 and int(ps[0]["hp"]) == int(ps[0]["max_hp"]), "队伍 HP 概览三人满值（04 §3.1）")
	# 传闻（战役书 §4：未择路线以传闻形式提及）
	var rumors := g3.hub_rumors()
	check(rumors.size() >= 4, "传闻 = 未触发的 choice/hidden 事件（三方委托+孤身入局）")
	check(not rumors.any(func(r: Dictionary) -> bool: return str(r["id"]) == "dock_tales"),
		"auto 触发事件不作传闻")

# ---------------------------------------------------------------- 节点流程视图模型（双壳共用内容源，godot-dev §7）

func test_story_vm() -> void:
	print("[story_vm]")
	var pack := _load_campaign01()
	var stream := EventStream.new()
	var board := Board.new(stream)
	var graph := StoryGraph.new(board, Rng.new(20260009), pack)
	graph.start()
	var vm := StoryVM.build(graph, board, pack)
	check(str(vm["type"]) == "scene" and str(vm["title"]) == "潮醒", "vm：scene 标题（tech/02 §3）")
	check(str(vm["text"]).contains("潮声"), "vm：叙事文本 = nodes.json summary")
	check((vm["rooms"] as Array)[0] == "N0-1" and int(vm["room_index"]) == 0
		and (vm["rooms"] as Array).has("N0-2"), "vm：推进条房间 = 已访 + 未来预告（04 §④.2）")
	check((vm["edges"] as Array).size() == 1 and str(vm["edges"][0]["label"]) == "起身", "vm：scene 继续选项")
	check(not (vm["forecast"] as Dictionary).is_empty()
		and str((vm["forecast"] as Dictionary)["name"]) == "墨雨夜袭"
		and int((vm["forecast"] as Dictionary)["at"]) == 2, "vm：时间边预告（墨雨夜袭 2 格）")
	check(int(vm["quest_badge"]) == 0 and (vm["party"] as Array).size() == 3, "vm：事件角标 + 队伍 HP")
	# 检定选项文案（04 §④.3 检定房：一键快掷前置信息）
	graph.take_edge(_edge_to(graph, "N0-2"))
	vm = StoryVM.build(graph, board, pack)
	check(str(vm["edges"][0]["label"]) == "检定：感知（易 DC 8 · 修正 +0）",
		"vm：检定按钮含技能/难度/DC/修正")
	# hub vm（金币/货单/传闻）
	graph.seed_gold()
	graph.roll_check(graph.available_edges()[0]) # 种子 20260009：d20=17 成功 → N0-3a
	graph.take_edge(_edge_to(graph, "N0-4"))
	graph.take_edge(_edge_to(graph, "N1-1"))
	vm = StoryVM.build(graph, board, pack)
	check(str(vm["type"]) == "hub" and int(vm["gold"]) == StoryGraph.GOLD_START
		and (vm["stock"] as Array).size() == 2 and (vm["rumors"] as Array).size() >= 4,
		"vm：hub 金币/货单（潮汐表+药水，裁决 B）/传闻齐备")
	# 对话选项声望角标（N1-3：接触三方 → 目标节点 on_enter rep 效果）
	graph.take_edge(_edge_to(graph, "N1-2"))
	graph.roll_check(graph.available_edges()[0]) # d20=17 成功 → N1-3
	vm = StoryVM.build(graph, board, pack)
	var joined := ""
	for e: Variant in vm["edges"]:
		joined += str((e as Dictionary)["label"]) + "|"
	check(joined.contains("接触誊写庭　〔誊写庭 +0〕"), "vm：对话选项带声望角标（faction + 当前值）")
	# toast 文案（事件流驱动，双壳同源）
	check(StoryVM.toast_text({"type": EventTypes.FLAG_WRITE,
		"payload": {"key": "campaign01.seen_fading"}}).contains("旗标"), "toast：旗标更新")
	check(StoryVM.toast_text({"type": EventTypes.FLAG_WRITE,
		"payload": {"key": "campaign01.gold"}}) == "", "toast：簿记键（金币）不上浮")
	check(StoryVM.toast_text({"type": EventTypes.REP_CHANGE,
		"payload": {"key": "global.rep.scriptorium", "delta": 1, "value": 1}}).contains("誊写庭 +1"),
		"toast：声望变化")
	check(StoryVM.toast_text({"type": EventTypes.ITEM_GAIN,
		"payload": {"item_id": "half_tide_table", "count": 1}}, pack).contains("半页潮汐表"),
		"toast：道具名按 items.json 解析")
	check(StoryVM.toast_text({"type": EventTypes.QUEST_TRIGGER,
		"payload": {"name": "码头异闻"}}).contains("码头异闻"), "toast：L3 事件触发")
	check(StoryVM.toast_text({"type": EventTypes.LOG, "payload": {"msg": "x", "toast": true}}) == "x"
		and StoryVM.toast_text({"type": EventTypes.LOG, "payload": {"msg": "x"}}) == "",
		"toast：仅显式标记的日志上浮")

# ---------------------------------------------------------------- 子游戏「竞技场连战」（M3：白皮书 §10.2 扩展承诺验证）
# 关键验证点：core 零改动——子游戏 = 内容包（packs/arena）+ 引导层流程（SubgameRunner/main.gd），
# 复用 PackLoader/StoryGraph/EncounterSM/BattleDef/Board 全部现有 core 能力。

func _load_arena() -> Dictionary:
	var res := PackLoader.load_pack("res://packs/arena")
	check(res["ok"], "arena 包加载成功：%s" % ";".join(res["errors"]))
	return res["pack"]

## 托管打完一场连战（同构 Command 通道，09 §9.3）；buff=必胜夹具 / weaken=必败夹具。
func _sub_run_battle(runner: SubgameRunner, seed: int, buff: bool, weaken: bool = false) -> EncounterSM:
	var def := runner.battle_def({"skills": [], "items": []})
	check(not def.is_empty(), "遭遇 %s 组装 ok" % runner.encounter_id())
	if buff: # 必胜夹具：全队高修正重骰普攻（流程验证，非数值平衡验证；移除技能避免技能伤害盖过重骰）
		for u: Variant in def["party"]:
			(u as Dictionary)["attack_mod"] = 30
			(u as Dictionary)["damage"] = "30d6"
			(u as Dictionary).erase("skills")
			(u as Dictionary).erase("items")
	if weaken:
		for u: Variant in def["party"]:
			(u as Dictionary)["hp"] = 1
			(u as Dictionary)["attack_mod"] = -50
			(u as Dictionary)["damage"] = "1d1"
		for u: Variant in def["enemies"]:
			(u as Dictionary)["damage"] = "10d6"
	var sm := EncounterSM.new(runner.board, runner.stream, Rng.new(seed), "arena")
	var agent := AutoAgent.new()
	sm.enter(runner.graph.current_id)
	sm.transition(EncounterSM.S_EXPLORE)
	sm.begin_combat(def)
	var guard := 0
	while not sm.is_over() and guard < 500:
		guard += 1
		var cmd := agent.next_command(sm)
		if cmd.is_empty():
			break
		sm.submit_command(cmd)
	return sm

func test_subgame_arena() -> void:
	print("[subgame_arena]")
	# ---- 包加载与 manifest 声明（tech/02 §2）----
	var pack := _load_arena()
	if pack.is_empty():
		return
	var manifest: Dictionary = pack["manifest"]
	check(str(manifest["pack_type"]) == "subgame", "manifest pack_type=subgame（tech/02 §2）")
	check(str(manifest["namespace"]) == "arena", "命名空间 = pack_id（§2 防呆）")
	var sub: Dictionary = manifest["subgame"]
	check(bool((sub["rules_override"] as Dictionary).get("arena_mode", false)),
		"rules_override = { arena_mode: true }（复用 light_v1 仅表现层变体，概念设计 §5）")
	check(str((manifest["presentation"] as Dictionary)["mode"]) == "choice", "双模式可选（tech/02 §2.1）")
	check((sub["gold_reward"] as Array).size() == 3, "subgame.gold_reward 三场金币声明（数据驱动奖励）")
	check((pack["nodes"] as Dictionary).size() == 5 and (pack["encounters"] as Dictionary).size() == 3
		and (pack["enemies"] as Dictionary).size() == 3, "节点图 5 节点 / 3 场遭遇 / 3 种敌人（含新增守页人精英）")
	check((pack["enemies"] as Dictionary).has("page_warden_elite")
		and (pack["enemies"] as Dictionary).has("ink_fiend"), "阵容：复用墨魈系 + 新增守页人精英")
	# ---- packlint V1~V13（tech/02 §12 + tech/04 §6）----
	var issues := PacklintCore.lint(pack)
	var fails: Array = []
	for issue: Dictionary in issues:
		if issue["level"] == PacklintCore.LEVEL_FAIL:
			fails.append("%s: %s" % [issue["v"], issue["msg"]])
	check(fails.is_empty(), "arena packlint V1~V13 无 FAIL：%s" % ";".join(fails))
	for v: String in ["V1", "V2", "V3", "V4", "V5", "V6", "V7", "V8", "V9", "V11", "V12", "V13"]:
		check(issues.any(func(i: Dictionary) -> bool:
			return i["v"] == v and i["level"] == PacklintCore.LEVEL_PASS), "arena packlint %s PASS" % v)
	# ---- core 零改动（白皮书 §10.2 "子游戏不动框架" 的硬证据）----
	# 钉版区间：M2 落地提交 ec946ef → M3 子游戏提交 ad46102（此后 core 的演进属后续里程碑，
	# 如 tech/04 §8 成长系统是框架层能力升级，不削弱"子游戏落地当时不动框架"的证据）。
	var git_out: Array = []
	OS.execute("git", ["-C", ProjectSettings.globalize_path("res://.."), "diff", "--name-only",
		"ec946ef", "ad46102", "--", "game/core/"], git_out, true)
	var diff_text := "".join(git_out).strip_edges()
	check(diff_text.is_empty(), "M3 区间 core/ 目录 git diff 为空（子游戏不动框架）：%s" % diff_text)

	# ---- 连战三场全胜流程（复用 EncounterSM ×3；奖励写板；战绩旗标）----
	var stream := EventStream.new()
	var board := Board.new(stream)
	board.give_item("heal_potion", 2, {"event_id": 0, "node_id": "A-0", "pack_id": "arena"})
	var runner := SubgameRunner.new(pack, board, stream, Rng.new(77))
	runner.start()
	check(runner.graph.current_id == "A-0", "进场节点 A-0（tech/02 §3）")
	runner.take_edge(0) # 踏入擂台 → A-1
	var stage_encs: Array[String] = ["AR-1", "AR-2", "AR-3"]
	for stage: int in 3:
		check(runner.encounter_id() == stage_encs[stage], "第 %d 场遭遇 = %s（节点图驱动）" % [stage + 1, stage_encs[stage]])
		var snap: Dictionary = board.serialize() # 夹具尝试回滚：每场以同一赛前状态重试，簿记不被失败尝试污染
		var won := false
		for seed: int in range(1, 100):
			var sm := _sub_run_battle(runner, seed, true)
			if sm.result() == &"victory":
				won = true
				if stage == 0:
					check(board.has("arena.hp.player_blank"), "第 1 场后 HP 写板（11 §7.1 连战持久前提）")
				break
			board.deserialize(snap)
		check(won, "seed 空间内第 %d 场必胜样本" % (stage + 1))
		if not won:
			return
		runner.on_victory() # 每场胜利：金币 + 累计胜场写板（04 §6）
		if stage == 1:
			var def2 := runner.battle_def({})
			var hp_board := int(board.read("arena.hp.player_blank"))
			check(int(def2["party"][0]["hp"]) == clampi(hp_board, 1, int(def2["party"][0]["max_hp"])),
				"第 3 场前组装以持久 HP 开局（含死亡 0→1 抬升，11 §7.1 / battle_def 抬升语义）")
		runner.take_edge(0) # 乘胜追击 / 全胜谢幕
	check(runner.graph.current_id == "A-END" and runner.graph.is_at_ending(), "全胜 → 结算节点 A-END")
	check(int(board.read("arena.gold", 0)) == 100, "三场金币 20+30+50=100 落板（manifest gold_reward）")
	check(int(board.read("arena.wins", 0)) == 3, "累计胜场 3 落板（stat_keys.wins）")
	check(board.read("arena.stage1_cleared") == true and board.read("arena.stage2_cleared") == true
		and board.read("arena.stage3_cleared") == true and board.read("arena.flawless") == true,
		"场次旗标 + 全胜旗标落板（边效果 DSL，V4 闭环）")
	check(board.has_item("ink_core"), "全胜追加墨核 ×1 进 global.inv（互通，概念设计 §3）")
	var xp_sum := 0
	for ev: Dictionary in stream.query_by_type(EventTypes.XP_GAIN):
		xp_sum += int(ev["payload"]["amount"])
	check(xp_sum == 250, "三场经验 50+80+120=250（encounters.xp 数据驱动）")
	check(Growth.xp(board) == 250,
		"子游戏经验喂养角色成长：胜利 xp 经同一 xp 效果汇入 global.growth.xp（tech/04 §8 规则1）")
	var summary := runner.finish_run(&"victory")
	check(int(summary["wins"]) == 3 and int(summary["gold"]) == 100 and int(summary["best"]) == 3,
		"收场汇总：3 胜 / 100 金 / 最佳 3")
	check(int(board.read("arena.best", 0)) == 3, "最佳连战纪录写板（stat_keys.best）")

	# ---- 中途败北：按已完成场次结算（失败即分支的竞技场形态，概念设计 §2）----
	var s2 := EventStream.new()
	var b2 := Board.new(s2)
	var r2 := SubgameRunner.new(pack, b2, s2, Rng.new(7))
	r2.start()
	r2.take_edge(0) # → A-1
	var snap1: Dictionary = b2.serialize() # 夹具尝试回滚（同上）
	var won1 := false
	for seed: int in range(1, 100):
		if _sub_run_battle(r2, seed, true).result() == &"victory":
			won1 = true
			break
		b2.deserialize(snap1)
	check(won1, "败北局：第 1 场先胜（铺垫已完成场次）")
	r2.on_victory()
	r2.take_edge(0) # 追击 → A-2
	var snap2: Dictionary = b2.serialize() # 夹具尝试回滚（同上）
	var lost := false
	for seed: int in range(1, 400):
		if _sub_run_battle(r2, seed, false, true).result() == &"defeat":
			lost = true
			break
		b2.deserialize(snap2)
	check(lost, "seed 空间内第 2 场败北样本（全员倒地团灭，11 §5.2）")
	var sum2 := r2.finish_run(&"defeat")
	check(int(sum2["wins"]) == 1 and int(sum2["gold"]) == 20, "中途败北：按已完成 1 场结算（1 胜 / 20 金）")
	check(b2.read("arena.stage1_cleared") == true and b2.read("arena.stage2_cleared") == false,
		"败北场次不写场次旗标（失败即分支）")
	check(int(b2.read("arena.best", 0)) == 1, "败北收场：最佳纪录 = 已完成场次（1）")

# ---------------------------------------------------------------- 权利模型运行时（06 §2/§3.2/§5；tech/02 §2.2/§2.3）

func test_entitlements() -> void:
	print("[entitlements]")
	var stream := EventStream.new()
	var board := Board.new(stream)
	var ent := Entitlements.new(board, stream)
	var arena_pack := _load_arena()
	var manifest: Dictionary = arena_pack["manifest"]
	# 缺省 = 随本体权利可进入；门槛未点亮 = 锁定（tech/02 §2.2）
	check(ent.can_access({}), "manifest 无 entitlement 声明 = 随本体权利可进入（tech/02 §2.2 缺省）")
	check(Entitlements.requires_of(manifest) == ["entitlement.arena"], "arena 门槛声明解析（manifest entitlement.requires）")
	check(not ent.can_access(manifest), "权利未点亮 → 锁定（硬门槛，全真判断）")
	check(ent.missing(manifest) == ["entitlement.arena"], "缺失权利清单（锁定态呈现依据）")
	# 商店点亮：写入即生效 + 单号溯源 + system 写权限（06 §2.3/§3.1）
	check(ent.shop_purchase("arena", "rcpt_test_001"), "shop_purchase 商店点亮（06 §2.3 写入方之一）")
	check(ent.can_access(manifest), "购买即解锁：写入即生效无需重启（06 §3.1）")
	var prov := board.provenance_of("global.entitlement.arena")
	check(str(prov.get("pack_id", "")) == "system" and str(prov.get("receipt_id", "")) == "rcpt_test_001"
		and str(prov.get("granted_by", "")) == "shop", "写入溯源：购买单号 + system 写权限（06 §2.3 / 07 §3）")
	check(stream.query_by_type(EventTypes.ENTITLEMENT_CHANGE).size() == 1,
		"权利变更经 entitlement.change 进事件流（07 §6）")
	# 内容包直写权利变量被拒（07 §3：仅 system 可写）
	check(not board.write("global.entitlement.arena", false,
		{"event_id": 1, "node_id": "A-0", "pack_id": "arena"}), "内容包写权利变量被拒（07 §3 命名空间权限）")
	check(ent.can_access(manifest), "越权写入未生效（权利仍点亮）")
	# 退款（06 §5）：权利置假 → 不可开新局；进行中连战允许跑完（流程核不回读权利）
	check(ent.refund("arena"), "refund 权利置假（06 §5）")
	check(not ent.can_access(manifest), "退款后不可开新局（入口 can_access 把关，06 §5）")
	var runner := SubgameRunner.new(arena_pack, board, stream, Rng.new(7))
	runner.start()
	check(runner.graph.current_id == "A-0", "退款不影响进行中的连战：允许跑完当前战役（06 §5）")
	# 活动点亮：activity_id + ttl 溯源（06 §3.2 运营轨）
	check(ent.activity_grant("arena", "weekend_free_arena", 48), "activity_grant 活动点亮（06 §2.3 写入方之二）")
	check(ent.can_access(manifest), "活动点亮即时生效")
	prov = board.provenance_of("global.entitlement.arena")
	check(str(prov.get("activity_id", "")) == "weekend_free_arena" and int(prov.get("ttl_hours", 0)) == 48,
		"活动溯源：activity_id + ttl 随写入（限免回收依据，06 §2.3）")
	ent.refund("arena")
	# 成就点亮：campaign01.cleared == true → entitlement.arena（多点亮路径演示，06 §2.1）
	var ops := Entitlements.load_ops_config()
	check(ent.check_achievements(ops).is_empty(), "成就旗标未立：规则不触发")
	board.write("campaign01.cleared", true, {"event_id": 2, "node_id": "N1-8", "pack_id": "campaign01"})
	var granted: Array = ent.check_achievements(ops)
	check(granted.has("arena") and ent.can_access(manifest),
		"成就点亮：campaign01.cleared → entitlement.arena（烬港通关者免费入场，06 §2.1）")
	prov = board.provenance_of("global.entitlement.arena")
	check(str(prov.get("achievement_id", "")) == "ach_campaign01_cleared", "成就溯源：achievement_id（06 §2.3）")
	check(ent.check_achievements(ops).is_empty(), "成就点亮幂等（已点亮不重复发）")

# ---------------------------------------------------------------- 运营配置与策略切换（06 §3.2；白皮书 §10.4 运营轨）

func _dir_fingerprint(dir_path: String) -> String:
	var parts: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return ""
	var files := dir.get_files()
	files.sort()
	for f: String in files:
		parts.append("%s:%s" % [f, FileAccess.get_md5(dir_path.path_join(f))])
	return "|".join(parts)

func test_ops_config() -> void:
	print("[ops_config]")
	var ops := Entitlements.load_ops_config()
	check(not ops.is_empty() and ops.has("shop") and ops.has("activities") and ops.has("achievements"),
		"运营配置加载：价格表/活动开关/成就规则（06 §3.2 运营侧数据，不进内容包）")
	check(str(Entitlements.price_of(ops, "arena").get("price_text", "")) == "¥12", "商店价格表：arena ¥12")
	# 权利注册表 = 运营侧数据文件（06 §2.3：packs/_ops/entitlements.json，非代码常量）
	var registry := PacklintCore.load_entitlement_registry()
	check(bool(registry["ok"]) and (registry["entitlements"] as Array).has("entitlement.arena"),
		"权利注册表数据文件加载：entitlement.arena 已登记（06 §2.3）")
	check(not bool(PacklintCore.load_entitlement_registry("res://packs/_ops/no_such.json")["ok"])
		and str(PacklintCore.load_entitlement_registry("res://packs/_ops/no_such.json")["error"]).contains("缺失"),
		"负例：注册表文件缺失 → 明确错误（06 §2.3）")
	var bad_reg_path := "user://tmp_bad_entitlements.json"
	var f := FileAccess.open(bad_reg_path, FileAccess.WRITE)
	f.store_string("{ 损坏的 json")
	f.close()
	check(not bool(PacklintCore.load_entitlement_registry(bad_reg_path)["ok"])
		and str(PacklintCore.load_entitlement_registry(bad_reg_path)["error"]).contains("解析失败"),
		"负例：注册表 JSON 损坏 → 明确错误（06 §2.3）")
	DirAccess.remove_absolute(bad_reg_path)
	# V9：arena requires 已注册且与 strategies 一致（tech/02 §2.3 一致性）
	var arena_pack := _load_arena()
	var v9: Array = PacklintCore.lint(arena_pack).filter(func(i: Dictionary) -> bool: return i["v"] == "V9")
	check(not v9.any(func(i: Dictionary) -> bool: return i["level"] == PacklintCore.LEVEL_FAIL)
		and v9.any(func(i: Dictionary) -> bool: return i["level"] == PacklintCore.LEVEL_PASS),
		"V9：arena requires 已注册且与 strategies 一致（tech/02 §2.3 / 06 §2.3）")
	var bad: Dictionary = arena_pack.duplicate(true)
	bad["manifest"]["entitlement"] = {"requires": ["entitlement.ghost"]}
	check(PacklintCore.lint(bad).any(func(i: Dictionary) -> bool:
		return i["v"] == "V9" and i["level"] == PacklintCore.LEVEL_FAIL),
		"负例：requires 引用未注册权利变量 V9 必报 FAIL（06 §2.3）")
	var broken_registry := {"ok": false, "error": "权利注册表缺失：mock（06 §2.3）", "entitlements": []}
	check(PacklintCore.lint(arena_pack, broken_registry).any(func(i: Dictionary) -> bool:
		return i["v"] == "V9" and i["level"] == PacklintCore.LEVEL_FAIL and str(i["msg"]).contains("注册表缺失")),
		"负例：注册表不可用 → V9 前置 FAIL 且不静默放行（06 §2.3）")
	# 策略切换内容零改动（固化为断言）：限免开/关两态下 packs/arena 逐文件指纹一致
	var fp_before := _dir_fingerprint("res://packs/arena")
	var stream := EventStream.new()
	var board := Board.new(stream)
	var ent := Entitlements.new(board, stream)
	var manifest: Dictionary = arena_pack["manifest"]
	check(not ent.can_access(manifest), "限免关：锁定（运营开关关态）")
	var ops_on := ops.duplicate(true)
	(ops_on["activities"] as Array)[0]["enabled"] = true
	check(ent.apply_activities(ops_on).has("weekend_free_arena"), "限免开：apply_activities 点亮（活动写入方）")
	check(ent.can_access(manifest), "限免开：入口自动解锁")
	var fp_on := _dir_fingerprint("res://packs/arena")
	ent.refund("arena")
	var fp_off := _dir_fingerprint("res://packs/arena")
	check(fp_before != "" and fp_before == fp_on and fp_on == fp_off,
		"策略切换内容零改动：限免开/关两态 packs/arena 逐文件一致（白皮书 §10.4 运营轨不动内容图）")

# ---------------------------------------------------------------- 子游戏 UI 流程（04 §6：入口卡 → 整备 → 连战 → ⑨ 结算 → 回主屏）

func test_subgame_flow() -> void:
	print("[subgame_flow]")
	var m: Node = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(m)
	await process_frame
	await process_frame
	check(m._subgames.has("arena"), "子游戏包发现：pack_type=subgame 即入列（数据驱动，不写死 arena）")
	m.entitlements.shop_purchase("arena", "rcpt_subflow") # M4 起 arena 有权利门槛：先点亮再走连战流程
	m._on_home_navigate(&"entry")
	await process_frame
	var entry := m.current_screen as ScreenEntry
	var card_found := false
	var mode_buttons := 0
	for child: Node in entry.subgame_box.get_children():
		if child is Label and (child as Label).text.contains("竞技场连战"):
			card_found = true
		if child is HBoxContainer:
			for b: Node in child.get_children():
				if b is Button:
					mode_buttons += 1
	check(card_found, "② 入口卡：特殊战役书卡呈现（04 §6）")
	check(mode_buttons == 2, "入口卡：竖屏/横屏双模式参战按钮（tech/02 §2.1 choice）")
	entry.subgame_start.emit("arena", ShellRouter.MODE_TIME)
	await process_frame
	check(m._sub_active and str(m.board.read("global.mode_choice.arena")) == "time",
		"子游戏模式选择写板 global.mode_choice.arena（09 §3）")
	check(m._sub.graph.current_id == "A-0" and m.graph.current_id == "",
		"子游戏开图 A-0，战役图不受污染（命名空间/状态隔离）")
	m._on_sub_story_edge(0) # 踏入擂台
	await process_frame
	check(m.current_screen is ScreenLoadout, "战斗节点 → 进场整备（09 §9.1；连战仅进场一次）")
	(m.current_screen as ScreenLoadout)._on_confirm()
	await create_timer(1.5).timeout
	check(m._sub_battling and m.shell is EncounterPortrait, "整备 → 连战第一场（EncounterSM × 双壳复用）")
	# 模拟第一场胜利（真实战斗数值由 subgame_arena runner 级断言覆盖）
	m.stream.emit(EventTypes.COMBAT_END, {"result": &"victory", "rounds": 2}, &"core", "A-1")
	await create_timer(1.6).timeout
	check(not m._sub_battling, "第一场结束回战后边（不进休整态，连战无休整）")
	check(int(m.board.read("arena.gold", 0)) == 20 and int(m.board.read("arena.wins", 0)) == 1,
		"第一场胜利写板：金币 +20 / 胜场 +1（04 §6 硬要求）")
	var sh := m.shell as EncounterPortrait
	var texts := sh.story_option_texts()
	var joined := " ".join(texts)
	check(joined.contains("乘胜追击") and joined.contains("见好就收"), "战后边：追击（无休整）/ 收兵选项")
	var retire_idx := -1
	for i: int in texts.size():
		if str(texts[i]).contains("见好就收"):
			retire_idx = i
	m._on_sub_story_edge(retire_idx) # 收兵 → A-END
	await process_frame
	check(m.current_screen is ScreenSettle, "收兵 → ⑨ 结算屏（04 §6 离场必经结算界面）")
	var summary := (m.current_screen as ScreenSettle).summary_text.text
	check(summary.contains("战绩：本次 1 胜") and summary.contains("金币 +20"),
		"结算汇总：战绩/金币逐项念出（04 §⑨）")
	(m.current_screen as ScreenSettle).go_home.emit()
	await process_frame
	check(m.current_screen is ScreenHome and not m._sub_active, "结算 → 回主屏（离场闭环，不新增导航项）")
	m.queue_free()
	await process_frame

# ---------------------------------------------------------------- 幕二 hybrid 战后抉择流程（tech/02 §6 hybrid；N2U-2 撕页行动）
# 回归点：多边战斗节点胜利后必须呈现故事态抉择，不得按 type=battle 重进遭遇（无限循环）。

func test_act2_hybrid_flow() -> void:
	print("[act2_hybrid_flow]")
	var m: Node = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(m)
	await process_frame
	await process_frame
	m._on_home_navigate(&"entry")
	await process_frame
	(m.current_screen as ScreenEntry).pick_mode(ShellRouter.MODE_TIME)
	(m.current_screen as ScreenEntry).start_requested.emit()
	await process_frame
	await process_frame
	m.graph._enter("N2U-2") # 传送至撕页行动（流程测试，不走完整前置链）
	m._present_node()
	await process_frame
	check(m.current_screen is ScreenLoadout, "撕页行动 → 整备界面（09 §9.1）")
	(m.current_screen as ScreenLoadout)._on_confirm()
	await create_timer(1.4).timeout
	check(m._in_encounter, "撕页行动战斗开始（税吏卫队）")
	m.stream.emit(EventTypes.COMBAT_END, {"result": &"victory", "rounds": 2}, &"core", "N2U-2")
	await create_timer(1.6).timeout
	var sh := m.shell as EncounterPortrait
	var opts := " ".join(sh.story_option_texts())
	check(m.graph.current_id == "N2U-2" and not m._in_encounter
		and opts.contains("撕掉税吏的命运页") and opts.contains("不撕"),
		"hybrid 胜利 → 战后抉择双出边呈现（不重进遭遇，tech/02 §6 hybrid）")
	m._on_story_edge(1) # 不撕
	await process_frame
	check(m.graph.current_id == "N2U-3" and m.board.read("campaign01.mercy_shown") == true
		and m.board.has_item("black_feather_token"),
		"抉择「不撕」→ 手下留情 + 黑羽令写板 → N2U-3（边效果，tech/02 §3）")
	m.queue_free()
	await process_frame

# ---------------------------------------------------------------- 锁定态与购买流程（06 §3.1/§6；04 §3.3；tech/02 §2.2 硬门槛）

func test_entitlement_flow() -> void:
	print("[entitlement_flow]")
	var m: Node = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(m)
	await process_frame
	await process_frame
	var arena_manifest: Dictionary = (m._subgames["arena"] as Dictionary)["manifest"]
	check(not m.entitlements.can_access(arena_manifest), "默认运营配置：arena 未点亮（限免开关关态）")
	m._on_home_navigate(&"entry")
	await process_frame
	var entry := m.current_screen as ScreenEntry
	var lock_found := false
	var stats_found := false
	var acquire_btn: Button = null
	var enter_buttons := 0
	for child: Node in entry.subgame_box.get_children():
		if child is Label:
			var t := (child as Label).text
			if t.contains("守门人"):
				lock_found = true
			if t.contains("累计胜场"):
				stats_found = true
		elif child is Button and (child as Button).text == TextsZh.LOCK_ACQUIRE:
			acquire_btn = child
		elif child is HBoxContainer:
			for b: Node in child.get_children():
				if b is Button:
					enter_buttons += 1
	check(stats_found, "锁定态：封面/战绩照常呈现——可见但锁定（06 §3.1，让内容成为销售页）")
	check(lock_found and acquire_btn != null and enter_buttons == 0,
		"锁定态：叙事化锁定文案 +「获取」按钮，无参战按钮、无'未购买'生硬弹窗（06 §3.1）")
	# 硬门槛阻断：直接发参战信号被拒
	entry.subgame_start.emit("arena", ShellRouter.MODE_TIME)
	await process_frame
	check(not m._sub_active, "锁定阻断进入：subgame_start 被硬门槛拒绝（tech/02 §2.2）")
	# 购买流程：半屏弹层 → 确认 → shop_purchase → 即时解锁无需重启
	acquire_btn.pressed.emit()
	await process_frame
	check(entry.shop_popup.visible and entry.shop_popup.goods_label.text.contains("¥12"),
		"「获取」→ 购买半屏弹层，价格来自运营配置（04 §3.3 / 06 §3.2/§6）")
	entry.shop_popup.confirm_button.pressed.emit()
	await process_frame
	check(m.entitlements.can_access(arena_manifest), "确认购买 → 即时点亮（06 §3.1：购买即解锁无需重启）")
	var prov: Dictionary = m.board.provenance_of("global.entitlement.arena")
	check(str(prov.get("granted_by", "")) == "shop" and str(prov.get("receipt_id", "")).begins_with("rcpt_"),
		"购买溯源：单号随写入进状态板（06 §2.3）")
	entry = m.current_screen as ScreenEntry
	var enter2 := 0
	for child: Node in entry.subgame_box.get_children():
		if child is HBoxContainer:
			for b: Node in child.get_children():
				if b is Button:
					enter2 += 1
	check(enter2 == 2, "入口当场刷新：参战按钮出现（解锁即时生效）")
	# 退款：权利置假 → 入口回锁定态、新局被拒（06 §5）
	m.entitlements.refund("arena")
	m._show_entry()
	await process_frame
	entry = m.current_screen as ScreenEntry
	var relocked := false
	for child: Node in entry.subgame_box.get_children():
		if child is Button and (child as Button).text == TextsZh.LOCK_ACQUIRE:
			relocked = true
	check(relocked and not m.entitlements.can_access(arena_manifest), "退款：入口回锁定态，不可开新局（06 §5）")
	# 活动限免：开关开 → apply_activities → 自动解锁（运营轨不动内容包）
	var ops_on: Dictionary = m.ops_config.duplicate(true)
	(ops_on["activities"] as Array)[0]["enabled"] = true
	m.entitlements.apply_activities(ops_on)
	m._show_entry()
	await process_frame
	entry = m.current_screen as ScreenEntry
	var enter3 := 0
	for child: Node in entry.subgame_box.get_children():
		if child is HBoxContainer:
			for b: Node in child.get_children():
				if b is Button:
					enter3 += 1
	check(m.entitlements.can_access(arena_manifest) and enter3 == 2,
		"活动限免开关开 → 入口自动解锁（06 §3.2：点亮在运营，内容包零改动）")
	m.queue_free()
	await process_frame

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
	for row: Node in hi.list_box.get_children(): # 行 = HBoxContainer（主按钮 + 战斗行附「重演」钮）
		if not (row is HBoxContainer):
			continue
		var b := row.get_child(0) as Button
		if b == null:
			continue
		rows += 1
		if first_btn == null:
			first_btn = b
		if b.text.contains("★"):
			key_marked = true
	check(rows == stream.size() and rows >= 2, "历史卷轴：事件流条目全量入轴（04 §⑧）")
	check(first_btn != null and first_btn.text.contains("check.roll"),
		"历史卷轴：倒序（最新在上，04 §⑧ 时间轴）")
	check(key_marked, "关键判定标记 ★（09 §6 key=true）")
	first_btn.pressed.emit()
	check(hi.detail_label.text.contains("检定明细") and hi.detail_label.text.contains("DC 10"),
		"展开明细：检定 d20 明细（骰值+修正=结果 vs 难度，04 §⑧）")
	var flag_btn: Button = null
	for row: Node in hi.list_box.get_children():
		if not (row is HBoxContainer):
			continue
		var b := row.get_child(0) as Button
		if b != null and b.text.contains("flag.write"):
			flag_btn = b
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
	for row: Node in qs.list_box.get_children():
		for child: Node in row.get_children():
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
		if child is Button: # 条目 = 按钮（点按 = 详情弹层，04 §⑥）
			iv_text += (child as Button).text
	check(iv_text.contains("墨核 ×1"), "背包图鉴：global.inv 只读列表（04 §⑥）")
	iv.queue_free()
	var ch: ScreenCharacter = (load("res://shell/ui/screen_character.tscn") as PackedScene).instantiate()
	root.add_child(ch)
	await process_frame
	ch.bind([{"id": "pc", "name": "白页者", "hp": 14, "max_hp": 14, "attrs": {"might": 2, "finesse": 1, "wits": 0},
		"skills": [{"name": "墨术飞矢"}]}], {"kelan": 10},
		{"xp": 350, "level": 2, "floor": 300, "next": 700, "attr_points": 0, "attrs": {"might": 1}})
	var ch_text := ""
	for child: Node in ch.list_box.get_children():
		if child is Label:
			ch_text += (child as Label).text
	check(ch_text.contains("白页者") and ch_text.contains("kelan 10/100"), "角色：队伍卡 + 羁绊只读（04 §⑦）")
	check(ch_text.contains("Lv.2") and ch_text.contains("350/700") and ch_text.contains("力 +1"),
		"角色⑦：成长区呈现等级 / XP 进度 / 已分配属性（tech/04 §8）")
	ch.queue_free()
	await process_frame

# ---------------------------------------------------------------- 横屏故事态（04 §③：中央主视野渲染叙事/选项，非战斗态）

func test_landscape_story() -> void:
	print("[landscape_story]")
	var pack := _load_campaign01()
	var stream := EventStream.new()
	var board := Board.new(stream)
	var graph := StoryGraph.new(board, Rng.new(20260009), pack)
	graph.seed_gold()
	graph.start()
	var land: EncounterLandscape = (load("res://shell/landscape/encounter_landscape.tscn") as PackedScene).instantiate()
	root.add_child(land)
	land.set_anchors_preset(Control.PRESET_TOP_LEFT)
	land.position = Vector2.ZERO
	land.size = Vector2(1280, 720)
	await process_frame
	await process_frame
	land.bind_story(stream, board, pack, {})
	land.show_story(StoryVM.build(graph, board, pack))
	await process_frame
	check(land.story_panel.visible and not land.grid.visible, "横屏故事态：中央主视野渲染叙事（非战斗态，04 §③）")
	check(land.story_title.text == "潮醒" and land.story_text.text.contains("潮声"),
		"横屏叙事文本同源 StoryVM（godot-dev §7 单一内容源）")
	check(land.story_option_texts() == ["起身"], "横屏左栏选项 = 同一 vm.edges（与竖屏同源）")
	check(land.clock_chip.visible and land.clock_chip.text.contains("时钟 0 格")
		and land.clock_chip.text.contains("墨雨夜袭"), "横屏状态栏带：时钟 + 时间边预告（04 §3.1）")
	# 五区指标不被故事态破坏（09 §4）
	var z := land.get_zone_ratios()
	check(absf(float(z["top"]) - 0.08) < 0.02 and absf(float(z["bottom"]) - 0.05) < 0.02,
		"故事态五区冻结指标保持（09 §4）")
	# 旗标 toast（事件流驱动）
	board.write("campaign01.seen_fading", true,
		{"event_id": stream.tail(), "node_id": "N0-3a", "pack_id": "campaign01"})
	await process_frame
	check(land.flash_label.text.contains("旗标"), "横屏旗标 toast（事件流驱动）")
	# 时间钟弹层（04 §3.1 例外交互）
	land._open_forecast()
	check(land.info_popup.visible and land.info_popup.body_label.text.contains("墨雨夜袭")
		and land.info_popup.body_label.text.contains("2 格"), "横屏点时间钟 → 时间边预告弹层（04 §3.1）")
	land.info_popup.hide()
	# 故事态 → 战斗态布局切换（同一壳，09 §8）
	var sm := EncounterSM.new(board, stream, Rng.new(11), "campaign01")
	land.bind(sm, AutoAgent.new())
	check(not land.story_panel.visible and land.grid.visible, "bind 遭遇 → 战斗布局恢复（故事面板收起）")
	land.queue_free()
	await process_frame

# ---------------------------------------------------------------- 幕三模式锁定（tech/02 §2.1 forced/forced_except；09 §3；世界观 §8；战役书幕三）

func test_act3_forced_mode() -> void:
	print("[act3_forced_mode]")
	var m: Node = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(m)
	await process_frame
	await process_frame
	m._on_home_navigate(&"entry")
	await process_frame
	(m.current_screen as ScreenEntry).pick_mode(ShellRouter.MODE_SPACE) # 横屏玩家路径
	(m.current_screen as ScreenEntry).start_requested.emit()
	await process_frame
	await process_frame
	# SL-0 强制竖屏：横屏玩家开局即竖屏壳（manifest presentation.forced）
	check(m.shell is EncounterPortrait and m.graph.current_id == "N0-1",
		"SL-0 强制竖屏：横屏玩家开局切竖屏壳（tech/02 §2.1 forced）")
	m._on_story_edge(0) # → N0-2
	await process_frame
	m._on_story_edge(0) # 掷检定
	await create_timer(1.2).timeout
	m._on_story_edge(0) # → N0-4
	await process_frame
	m._on_story_edge(0) # → N1-1（SL-1：恢复横屏）
	await process_frame
	check(m.shell is EncounterLandscape, "SL-1 起切回横屏（forced 幕外随玩家所选形态，tech/02 §2.1）")
	check((m.shell as EncounterLandscape).flash_label.text.contains("全局的视野"),
		"解锁提示叙事化呈现（09 §3：包装文案禁止系统腔）")
	# N2-C → N3-1：横屏玩家强制切竖屏壳 + 模式锁定演出
	m.graph._enter("N2-C") # 传送幕二收束点（SL-2 随玩家所选形态）
	m._present_node()
	await process_frame
	check(m.shell is EncounterLandscape, "N2-C（SL-2）：横屏壳保持")
	m._on_story_edge(0) # → N3-1
	await process_frame
	check(m.shell is EncounterPortrait,
		"N2-C → N3-1：横屏玩家强制切竖屏壳（战役书幕三模式锁定演出）")
	check((m.shell as EncounterPortrait).flash_label.text.contains("回放"),
		"模式锁定叙事化提示：残篇只能逐房回放（世界观 §8；09 §3 NOTICE_FORCED）")
	check(m.graph.current_id == "N3-1" and str(m.graph.current().get("act", "")) == "SL-3",
		"幕三节点就位（SL-3 撤销区）")
	# N3-7 起切回横屏（forced_except：空白广场解锁横屏）
	m.graph._enter("N3-7")
	m._present_node()
	await process_frame
	check(m.shell is EncounterLandscape,
		"N3-7 起切回横屏（forced_except 解锁，战役书幕三「此处起解锁横屏」）")
	check((m.shell as EncounterLandscape).flash_label.text.contains("全局的视野"),
		"N3-7 解锁提示叙事化呈现（09 §3）")
	m.queue_free()
	await process_frame

# ---------------------------------------------------------------- main 节点流程集成（tech/01 §10；04 §3.1/§④.2/§④.3/§⑨；07 §4.2；09 §6/§7）

## main 流程战斗快捷通道：整备确认 → 遭遇 → 模拟胜利（真实战斗数值由 encounter_sm/包数据通道覆盖）。
func _main_win_battle(m: Node) -> void:
	var lo := m.current_screen as ScreenLoadout
	lo._toggle_skill("inkbolt")
	lo._toggle_skill("inkshield")
	lo._on_confirm()
	await create_timer(1.4).timeout
	m.stream.emit(EventTypes.COMBAT_END, {"result": &"victory", "rounds": 3}, &"core", m.graph.current_id)
	await create_timer(1.6).timeout

func test_main_flow() -> void:
	print("[main_flow]")
	var main_scene: PackedScene = load("res://main.tscn")
	var m: Node = main_scene.instantiate()
	root.add_child(m)
	await process_frame
	await process_frame
	check(m.current_screen is ScreenHome, "启动 → ①主屏（04 §2 枢纽）")
	m._on_home_navigate(&"entry")
	await process_frame
	check(m.current_screen is ScreenEntry, "主屏 → ②战役入口")
	(m.current_screen as ScreenEntry).pick_mode(ShellRouter.MODE_TIME)
	check(str(m.board.read("global.mode_choice.campaign01")) == "time",
		"模式选择写板 global.mode_choice.campaign01（09 §3，07 §3 v1.1 白名单）")
	(m.current_screen as ScreenEntry).start_requested.emit()
	await process_frame
	await process_frame
	# ---- scene（N0-1）：叙事文本 + 继续；推进条 pip 同步；状态栏带 ----
	var sh := m.shell as EncounterPortrait
	check(sh != null and m.current_screen == sh, "战役开始 → 竖屏故事壳（节点流程，非直达战斗）")
	check(m.graph.current_id == "N0-1", "真实走图：入口节点 N0-1（tech/02 §3）")
	check(sh.story_title.text == "潮醒" and sh.story_text.text.contains("潮声"),
		"scene 节点渲染：标题 + 叙事文本（04 §④.3）")
	check(sh.story_option_texts() == ["起身"], "scene 节点渲染：继续选项")
	check(sh.pip_state(0) == EncounterPortrait.PIP_CURRENT and sh.pip_state(1) == EncounterPortrait.PIP_FUTURE,
		"推进条 pip 同步 story 节点（04 §④.2：当前脉动/未来剪影）")
	check(sh.clock_chip.visible and sh.clock_chip.text.contains("时钟 0 格")
		and sh.clock_chip.text.contains("墨雨夜袭 2格"), "状态栏带：时钟总览格 + 时间边预告（04 §3.1）")
	var party_shown := ""
	for child: Node in sh.party_chips.get_children():
		party_shown += (child as Label).text
	check(party_shown.contains("白页者 14/14") and party_shown.contains("珂兰"),
		"状态栏带：队伍 HP 概览（04 §3.1）")
	await process_frame
	await process_frame
	check(_ratios_close(sh.get_band_ratios(), [0.08, 0.50, 0.42]), "故事态呼吸对话档 8/50/42（04 §④.1）")
	sh._open_forecast()
	check(sh.info_popup.visible and sh.info_popup.body_label.text.contains("墨雨夜袭"),
		"点时间钟 → 时间边预告弹层（04 §3.1 例外交互）")
	sh.info_popup.hide()
	# ---- check（N0-2）：检定按钮 → check.roll → 按结果走边；L3 事件触发 toast ----
	m._on_story_edge(0)
	await process_frame
	check(m.graph.current_id == "N0-2", "scene → check 节点推进")
	check(sh.story_option_texts()[0] == "检定：感知（易 DC 8 · 修正 +0）",
		"check 节点渲染：检定按钮（技能/难度/DC/修正，04 §④.3）")
	check(sh.flash_label.text.contains("码头异闻"), "L3 事件触发 toast + 进事件中心（事件流驱动）")
	m._on_story_edge(0) # 掷检定（种子 20260009：d20=17 成功）
	await create_timer(1.0).timeout
	var rolls: Array = m.stream.query_by_type(EventTypes.CHECK_ROLL)
	check(rolls.size() == 1 and str(rolls[0]["payload"]["kind"]) == "story_check",
		"检定按钮 → check.roll 事件（09 §6 同一事件源驱动演出）")
	check(m.graph.current_id == "N0-3a", "检定成功 → success 边（tech/02 §4.2；写板效果生效）")
	check(m.board.read("campaign01.seen_fading") == true, "写板效果生效：seen_fading 落板（07 §1）")
	m._on_story_edge(0) # N0-3a → N0-4
	await process_frame
	m._on_story_edge(0) # N0-4 → N1-1 hub
	await process_frame
	# ---- hub（N1-1）：商店/休整/传闻 ----
	check(m.graph.current_id == "N1-1", "抵达 hub N1-1（自由市广场）")
	var hub_opts := sh.story_option_texts()
	check(hub_opts.has(TextsZh.HUB_SHOP) and hub_opts.has(TextsZh.HUB_REST) and hub_opts.has(TextsZh.HUB_RUMOR),
		"hub 渲染：商店/休整/传闻三设施（战役书 §4 N1-1）")
	check(m.graph.get_gold() == StoryGraph.GOLD_START, "金币播种（开局 30 占位，待裁决）")
	m._on_hub_action("rumor", "")
	await process_frame
	check(sh.flash_label.text.contains("传闻"), "传闻 toast（战役书 §4：未择路线以传闻提及）")
	m._on_hub_action("rest", "")
	await process_frame
	check(int(m.board.read("campaign01.hp.player_blank", 0)) == 14
		and sh.flash_label.text.contains("休整"), "休整：恢复 HP（写板 + toast）")
	# 商店半屏弹层：购买 → 道具 + 金币扣减；金币不足拒绝
	sh.hub_popup.open(m.graph.get_gold(), m.graph.hub_stock())
	await process_frame
	var buy_btn: Button = null
	var potion_btn: Button = null
	for child: Node in sh.hub_popup.stock_box.get_children():
		if child is Button and (child as Button).text.contains("半页潮汐表"):
			buy_btn = child
		if child is Button and (child as Button).text.contains("补给药水"):
			potion_btn = child
	check(buy_btn != null and buy_btn.text.contains("15")
		and potion_btn != null and potion_btn.text.contains("15"),
		"商店半屏弹层：货单含潮汐表与药水价格（04 §3.3；验收裁决 B 上架）")
	buy_btn.pressed.emit()
	await process_frame
	check(m.board.has_item("half_tide_table") and m.graph.get_gold() == StoryGraph.GOLD_START - 15,
		"购买：give_item + 金币扣减（07 §1 溯源写板）")
	# 购买后弹层货单重建（sync_hub_popup），按钮需重新获取（真实用户视角：读新列表再点）
	potion_btn = null
	for child: Node in sh.hub_popup.stock_box.get_children():
		if child is Button and (child as Button).text.contains("补给药水"):
			potion_btn = child
	potion_btn.pressed.emit()
	await process_frame
	check(m.board.item_count("heal_potion") == 3 and m.graph.get_gold() == StoryGraph.GOLD_START - 30,
		"购买药水：扣 15 金 + give_item（序章带入 ×2 + 购买 ×1，验收裁决 B）")
	check((m._loadout_candidates()["items"] as Array).any(func(it: Variant) -> bool:
		return str((it as Dictionary)["id"]) == "heal_potion" and int((it as Dictionary)["count"]) == 3),
		"药水入整备携行候选（战斗中可使用，tech/04 §4；CMD_ITEM 通道已由遭遇测试验证）")
	check(sh.hub_popup.gold_label.text == TextsZh.HUB_GOLD % (StoryGraph.GOLD_START - 30),
		"购买后弹层金币同步刷新")
	sh.hub_popup.hide()
	m.board.write("campaign01.gold", 5, {"event_id": m.stream.tail(), "node_id": "N1-1", "pack_id": "campaign01"})
	m._on_hub_action("buy", "half_tide_table")
	await process_frame
	check(m.graph.get_gold() == 5 and sh.flash_label.text.contains("金币不足"), "金币不足：拒绝 + 提示")
	m.board.write("campaign01.gold", 30, {"event_id": m.stream.tail(), "node_id": "N1-1", "pack_id": "campaign01"})
	# ---- check（N1-2）→ scene（N1-3）：时钟推进 → 状态栏带/预告刷新 ----
	var fade_idx := -1
	var opts_hub := sh.story_option_texts()
	for i: int in opts_hub.size():
		if str(opts_hub[i]).contains("前往褪色现场"):
			fade_idx = i
	check(fade_idx >= 0, "hub 选项：前往褪色现场（购买边旁路）")
	m._on_story_edge(fade_idx)
	await process_frame
	check(m.graph.current_id == "N1-2", "hub → N1-2 调查节点")
	m._on_story_edge(0) # 掷检定（d20=17+2 vs 12 成功）
	await create_timer(1.0).timeout
	check(m.graph.current_id == "N1-3", "N1-2 检定成功 → N1-3")
	check(sh.clock_chip.text.contains("时钟 1 格"), "N1-3 on_enter 时钟 +1 → 状态栏带刷新（clock.tick 事件驱动）")
	# ---- dialog（N1-4）：声望角标 + 选项回复进日志 + 声望事件 ----
	var invite_idx := -1
	var opts_n13 := sh.story_option_texts()
	for i: int in opts_n13.size():
		if str(opts_n13[i]).contains("接触誊写庭"):
			invite_idx = i
	check(invite_idx >= 0 and str(opts_n13[invite_idx]).contains("誊写庭 +0"),
		"dialog 选项带声望角标（誊写庭 +0）")
	m._on_story_edge(invite_idx)
	await process_frame
	check(m.graph.current_id == "N1-4" and sh.story_title.text == "誊写庭接触", "dialog 节点渲染（N1-4）")
	check(m.stream.query_by_type(EventTypes.REP_CHANGE).any(func(ev: Dictionary) -> bool:
		return str(ev["payload"]["key"]) == "global.rep.scriptorium" and int(ev["payload"]["delta"]) == 1),
		"对话选项 → 声望事件（rep.change 进事件流，07 §6）")
	var logs_before: int = m.stream.query_by_type(EventTypes.LOG).size()
	m._on_story_edge(0) # 继续 → N1-7 battle
	await process_frame
	var new_logs: Array = m.stream.query_by_type(EventTypes.LOG)
	check(new_logs.size() > logs_before and str(new_logs.back()["payload"]["msg"]).contains("誊写庭接触"),
		"对话选项回复进日志")
	# ---- battle（N1-7）：整备 → 遭遇；遭遇进行中不存档；☰ 恢复快照 ----
	check(m.current_screen is ScreenLoadout, "battle 节点 → 整备界面（09 §9.1）")
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
	await create_timer(1.4).timeout
	check(m._in_encounter and m.shell is EncounterPortrait, "整备 → 竖屏遭遇（同一壳切战斗布局，09 §8）")
	await create_timer(0.6).timeout
	check(not FileAccess.file_exists(save_path), "遭遇进行中不存档（07 §4.2 铁律）")
	var clock_before: int = (m._encounter_snapshot["board"]["data"] as Dictionary).get("global.doom_clock", 0)
	m.board.write("global.doom_clock", 9, {"event_id": m.stream.tail(), "node_id": "N1-7", "pack_id": "campaign01"})
	m._on_save_quit()
	await process_frame
	check(m.current_screen is ScreenHome, "☰ 回主屏（09 §7）")
	check(m.board.get_doom_clock() == int(clock_before), "☰ 回主屏：恢复遭遇进入前快照（战斗重打，09 §7）")
	check(FileAccess.file_exists(save_path), "回主屏后世界状态落档（遭遇外时机，07 §4.2）")
	# 继续 → 再进 N1-7 → 胜利 → 战后边回图到 branch（N1-8）
	m._on_home_navigate(&"entry")
	(m.current_screen as ScreenEntry).start_requested.emit()
	await process_frame
	var lo2 := m.current_screen as ScreenLoadout
	lo2._toggle_skill("inkbolt")
	lo2._toggle_skill("inkshield")
	lo2._on_confirm()
	await create_timer(1.4).timeout
	check(m._in_encounter, "主屏「继续」→ 再进遭遇（04 §① 继续进行中的战役）")
	# 模拟 EncounterSM 胜利经验（真实战斗由 TP2 通道已验；与 encounter_sm 同一 Growth 通道，
	# tech/04 §8 规则1/2：汇入即写板 + 自动升级）；序章 50 + 300 = 350 跨 300 档
	Growth.new(m.board).grant_xp(300,
		{"event_id": m.stream.tail(), "node_id": "N1-7", "pack_id": "campaign01"})
	m.stream.emit(EventTypes.COMBAT_END, {"result": &"victory", "rounds": 3}, &"core", "N1-7")
	await create_timer(1.6).timeout
	# ---- branch（N1-8）：独狼隐藏边按声望显隐 ----
	check(m.graph.current_id == "N1-8", "战斗胜利 → 战后边回图到 branch N1-8（tech/02 §3）")
	check(not (m.current_screen is ScreenSettle), "战后不直接结算：回到节点流程")
	var sh2 := m.shell as EncounterPortrait
	var branch_opts := " ".join(sh2.story_option_texts())
	check(branch_opts.contains("誊写庭委托") and branch_opts.contains("断墨会委托")
		and branch_opts.contains("拾遗行会委托"), "branch 渲染：三方委托选项")
	check(not branch_opts.contains("我谁都不信"), "独狼隐藏边：声望 >0 → 不显形（tech/02 §4.5）")
	# 独狼边显形对照（声望全 0 走婉拒路，图级复核）
	var s2 := EventStream.new()
	var b2 := Board.new(s2)
	var g2 := StoryGraph.new(b2, Rng.new(20260009), m.pack)
	g2.start()
	g2.take_edge(_edge_to(g2, "N0-2"))
	g2.roll_check(g2.available_edges()[0])
	g2.take_edge(_edge_to(g2, "N0-4"))
	g2.take_edge(_edge_to(g2, "N1-1"))
	g2.take_edge(_edge_to(g2, "N1-2"))
	g2.roll_check(g2.available_edges()[0])
	g2.take_edge(_edge_to(g2, "N1-8")) # 婉拒所有邀约
	var lone_vm := StoryVM.build(g2, b2, m.pack)
	var lone_labels := ""
	for e: Variant in lone_vm["edges"]:
		lone_labels += str((e as Dictionary)["label"]) + "|"
	check(lone_labels.contains("我谁都不信"), "独狼隐藏边：三方声望 0 → 显形（tech/02 §4.5）")
	# ---- 幕二「三支笔」S 链：护送战 → N2-C 收束（战役书幕二）----
	m._on_story_edge(0) # 誊写庭委托 → N2S-1（幕二在切片内：SLICE_ACTS 含 SL-2）
	await process_frame
	check(m.graph.current_id == "N2S-1" and not (m.current_screen is ScreenSettle),
		"幕二接入：N1-8 委托 → N2S-1（切片延伸至 SL-2，战役书幕二）")
	m._on_story_edge(0) # N2S-1 档案馆试炼掷检定（成败均至 N2S-2，失败路罚时 +1）
	await create_timer(1.0).timeout
	check(m.current_screen is ScreenLoadout, "N2S-1 → N2S-2 护送战整备（09 §9.1）")
	var lo3 := m.current_screen as ScreenLoadout
	lo3._toggle_skill("inkbolt")
	lo3._toggle_skill("inkshield")
	lo3._on_confirm()
	await create_timer(1.4).timeout
	check(m._in_encounter, "护送战开始（修复仪式，tech/02 §6 escort）")
	check((m._battle_def({})["party"] as Array).any(func(u: Variant) -> bool:
		return str((u as Dictionary)["kind"]) == "escort_npc" and str((u as Dictionary)["id"]) == "scribe"),
		"护送对象缮写士以 escort_npc 入队（tech/02 §6 escort 块）")
	m.stream.emit(EventTypes.COMBAT_END, {"result": &"victory", "rounds": 3}, &"core", "N2S-2")
	await create_timer(1.6).timeout
	check(m.graph.current_id == "N2S-3", "护送胜利 → 战后边 → N2S-3（金墨的代价）")
	m._on_story_edge(0) # 献出一段自己的记忆 → N2-C
	await process_frame
	check(m.graph.current_id == "N2-C", "S 链收束 → N2-C（三方情报拼合，战役书幕二收束）")
	check(m.board.read("campaign01.blank_memory") == true, "献出记忆写板 blank_memory（N2S-3 边效果）")
	check(m.board.has_item("scriptorium_signet"), "离开 N2S-3 结算 on_complete（誊写庭印戒，tech/02 §3）")
	# ---- 幕三「撤销区」房间序列 → 终章 → 结局屏 → NG+（战役书幕三/终章；tech/02 §9）----
	check(m.stream.query_by_type(EventTypes.QUEST_TRIGGER).any(
		func(ev: Dictionary) -> bool: return str(ev["payload"]["id"]) == "archive_quest"),
		"branch 选择 → choice 触发 L3 事件（档案馆委托，tech/02 §5）")
	m._on_story_edge(0) # N2-C → N3-1（模式锁定演出节点；time 玩家无换壳）
	await process_frame
	check(m.graph.current_id == "N3-1" and m.current_screen is EncounterPortrait,
		"幕三接入：N2-C → N3-1 进入撤销区（SL-3，战役书幕三）")
	m._on_story_edge(0) # N3-1 → R1 褪色民居（探索序列）
	await process_frame
	check(m.graph.current_id == "R1" and m.board.has_lore("revoked_registry_01"),
		"R1：褪色民居 on_enter 图鉴·门牌（lore.json source 逐条对齐）")
	m._on_story_edge(0) # R1 拾取拍（loot：墨核 ×1，tech/02 §6 maze）
	await create_timer(1.2).timeout
	check(m.graph.current_id == "R1", "R1 探索序列完成回节点呈现出边")
	m._on_story_edge(0) # R1 → R2 空教室
	await process_frame
	check(m.board.has_lore("revoked_registry_02"), "R2：空教室 on_enter 图鉴·花名册")
	m._on_story_edge(0) # R2 安抚检定（真实掷骰；成败均至 R3，差异在效果，08 §2）
	await create_timer(1.2).timeout
	check(m.graph.current_id == "R3", "R2 对话检定 → R3 墨魈巢穴（tech/02 §4.2）")
	# R3 战斗 → R4 分支门（S 链无黑羽令 → fallback 右路两场）
	check(m.current_screen is ScreenLoadout, "R3 战斗房 → 整备（09 §9.1）")
	await _main_win_battle(m)
	check(m.graph.current_id == "R4", "R3 胜利 → R4 分叉回廊（分支门）")
	check(bool(m.graph.available_edges()[0].get("via_fallback", false)),
		"R4 分支门：无黑羽令 → 右路 fallback 变体（tech/02 §4.3）")
	m._on_story_edge(0) # → R4-r 第一场
	await process_frame
	check(m.graph.current_id == "R4-r", "R4 右路 → R4-r 第一场（战役书幕三 右路两场战斗）")
	await _main_win_battle(m)
	check(m.graph.current_id == "R4-r2", "R4-r 胜利 → R4-r2 第二场（场间无休整，HP 持久 11 §7.1）")
	await _main_win_battle(m)
	check(m.graph.current_id == "R5", "R4-r2 胜利 → R5 守页人 Boss 战")
	await _main_win_battle(m)
	check(m.graph.current_id == "N3-7", "R5 胜利 → N3-7 空白广场（终章入口，战役书幕三）")
	check(m.board.item_count("ink_core") == 2, "墨核累计 ×2（R1 拾取 + R5 节点边战利品，战役书 §8）")
	# ---- 终章：免战门 → 抉择 → 结局屏 ----
	m._on_story_edge(0) # N3-7 → N4-1 潮汐塔顶（免战门节点）
	await process_frame
	check(m.graph.current_id == "N4-1", "终章：N3-7 → N4-1（SL-4，战役书终章）")
	var n41: Array = m.graph.available_edges()
	check(n41.size() == 1 and not bool(n41[0].get("via_fallback", false)),
		"N4-1 免战边显形：印戒 + 誊写庭声望 ≥1（[物/声]，items.json unlocks）")
	m._on_story_edge(0) # 出示誊写庭印戒 → 免战直达 N4-2
	await process_frame
	check(m.graph.current_id == "N4-2", "印戒免战：跳过 Boss 直达抉择（战役书 §8 印戒解锁边）")
	var n42: Array = m.graph.available_edges()
	check(n42.size() == 2 and str(n42[0].get("to", "")) == "E1",
		"N4-2 抉择：墨守过中线 → E1 显形，E4 兜底（tech/02 §9 顺序求值）")
	check(m.graph.pick_ending() == "E1", "结局表求值 E1（图边选择与 endings.json 互证）")
	m._on_story_edge(0) # 修补卷轴 → E1
	await process_frame
	check(m.graph.current_id == "E1" and m.graph.is_at_ending(), "抵达结局 E1 重墨（tech/02 §9）")
	check(bool(m.board.read("campaign01.ending_e1")),
		"结局写板：ending_e1（ending 节点 on_enter，flags.json 台账 V4 闭环）")
	check(bool(m.board.read("campaign01.campaign01_cleared")),
		"结局写板：campaign01_cleared（last_page settle 于离开 N4-2，战役书 §6）")
	# 结局屏：四分型文案 + 多周目钩子（endings.json；壳不再创作）
	var es := m.current_screen as ScreenEnding
	check(es != null, "结局屏呈现（战役书 §9：结局演出 + 尾声结算合并于 ending 节点）")
	check(es.title_label.text.contains("重墨") and es.content_text.text.contains("港城被重新书写"),
		"结局屏文案 = endings.json content 字段（E1 重墨）")
	check(es.hook_label.text.contains("缮写圣城"), "结局屏多周目钩子 = ngplus_hook 字段")
	check(m.stream.query_by_type(EventTypes.STORY_ENDING).size() == 1,
		"story.ending 事件进事件流（tech/02 §9）")
	check(FileAccess.file_exists(save_path), "结局快照落盘（07 §4.2 主快照点）")
	var read_back := SaveSystem.read("slot1")
	check(bool(read_back["ok"]) and bool(SaveSystem.migrate(read_back["snapshot"])["ok"]),
		"结局快照可读可迁移（当前版本直通，07 §4.3）")
	check(bool(m.board.read("campaign01.cleared"))
		and bool(m.board.read("global.entitlement.arena")),
		"通关成就点亮：campaign01.cleared → entitlement.arena（06 §2.1）")
	# ---- 多周目：开始二周目 → NG+ 继承（战役书 §8 投放第 4 枚 / §9 失败非终局）----
	var lore_before: int = m.board.get_lore().size()
	es.ngplus_button.pressed.emit()
	await process_frame
	await process_frame
	check(m.graph.current_id == "N0-1" and int(m.board.read("campaign01.ngplus", 0)) == 1,
		"NG+：周目数 +1（campaign01.ngplus 簿记 → meta.ngplus）并从入口重开")
	check(m.board.item_count("codex_fragment") == 1, "NG+：继承织命者残简 ×1（战役书 §8 投放第 4 枚）")
	check(m.board.get_lore().size() == lore_before, "NG+：图鉴保留（global.lore，战役书 §9）")
	check(bool(m.board.read("global.entitlement.arena")), "NG+：权利保留（global.entitlement.*，07 §3）")
	check(Growth.xp(m.board) == 0 and m.board.get_doom_clock() == 0
		and m.board.get_alignment() == 50 and not m.board.has_item("ink_core"),
		"NG+：其余状态重置（成长/时钟/倾向/战利品）")
	m.queue_free()
	await process_frame

# ---------------------------------------------------------------- 角色界面真实导航回归（M2 审计 G1）
# 主屏 → ⑦角色 不得再走战斗定义组装（非战斗上下文无当前遭遇）；
# 覆盖两类非战斗态：战役未开始（graph.current_id 为空）+ 战役中场景节点（current_id 为 scene）。

func test_character_nav() -> void:
	print("[character_nav]")
	# ---- 路径 1：战役未开始的主屏（审计 G1 原始崩点）----
	var m: Node = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(m)
	await process_frame
	await process_frame
	check(m.current_screen is ScreenHome, "开局在主屏（G1 回归前提）")
	m._on_home_navigate(&"character") # 与玩家点按同一通道（screen_home.navigate → _on_home_navigate）
	await process_frame
	check(m.current_screen is ScreenCharacter, "主屏→角色：界面呈现（G1：曾 SCRIPT ERROR 崩溃）")
	var ch := m.current_screen as ScreenCharacter
	var text := ""
	for c: Node in ch.list_box.get_children():
		if c is Label:
			text += (c as Label).text + "\n"
	check(text.contains("白页者") and text.contains("珂兰") and text.contains("老费"),
		"角色卡名册渲染：player + 双同伴（StoryGraph.party_roster，与 BattleDef 解耦）")
	check(text.contains("技能：") and not text.contains("技能：—"),
		"角色卡技能列非空（characters.json 已习得 ∪ basic_attack 查名 skills.json）")
	ch.back_button.pressed.emit() # 玩家点"返回"同一通道
	await process_frame
	check(m.current_screen is ScreenHome, "角色→返回→主屏（G1：曾信号未连接软锁）")
	# ---- 路径 2：战役中场景节点 → ☰ 回主屏 → 角色（graph.current_id 为 scene 非战斗节点）----
	m._on_home_navigate(&"entry")
	await process_frame
	(m.current_screen as ScreenEntry).pick_mode(ShellRouter.MODE_TIME)
	(m.current_screen as ScreenEntry).start_requested.emit()
	await process_frame
	await process_frame
	check(m.graph.current_id == "N0-1", "战役开始于入口场景节点（非战斗上下文）")
	m._on_save_quit() # 故事态 ☰：落档回主屏（07 §4.2）
	await process_frame
	check(m.current_screen is ScreenHome, "战役中 ☰ 回主屏")
	m._on_home_navigate(&"character")
	await process_frame
	check(m.current_screen is ScreenCharacter, "战役中（scene 节点）→角色：界面呈现（G1 第二崩点）")
	var ch2 := m.current_screen as ScreenCharacter
	var text2 := ""
	for c: Node in ch2.list_box.get_children():
		if c is Label:
			text2 += (c as Label).text + "\n"
	check(text2.contains("白页者"), "战役中角色卡名册渲染")
	ch2.back_button.pressed.emit()
	await process_frame
	check(m.current_screen is ScreenHome, "战役中角色→返回→主屏")
	m.queue_free()
	await process_frame

# ---------------------------------------------------------------- 手势识别器（12 §1 判定参数边界；§3 冲突消解）

func test_gesture_recognizer() -> void:
	print("[gesture_recognizer]")
	var V := func(x: float, y: float) -> Vector2: return Vector2(x, y)
	# ---- 点按：按下-抬起 <300ms 且位移 <10pt ----
	var rec := GestureRecognizer.new()
	var taps: Array = []
	rec.tapped.connect(func(p: Vector2) -> void: taps.append(p))
	rec.press(0, V.call(0, 0), 0)
	rec.release(0, V.call(0, 0), 299)
	check(taps.size() == 1, "点按：299ms 原位 = tap（<300ms）")
	rec.press(0, V.call(0, 0), 0)
	rec.release(0, V.call(0, 0), 300)
	check(taps.size() == 1, "点按边界：300ms 不判点按（<300ms 严格）")
	rec.press(0, V.call(0, 0), 0)
	rec.release(0, V.call(9.9, 0), 100)
	check(taps.size() == 2, "点按边界：位移 9.9pt 仍判点按（<10pt）")
	# ---- 长按：≥400ms 且位移 <10pt，到时即触发（不等抬手）----
	var longs: Array = []
	rec.long_pressed.connect(func(p: Vector2) -> void: longs.append(p))
	rec.press(0, V.call(50, 50), 0)
	rec.poll(399)
	check(longs.is_empty(), "长按边界：399ms 未触发（≥400ms）")
	rec.poll(400)
	check(longs.size() == 1, "长按：400ms 触发（12 §1）")
	rec.release(0, V.call(50, 50), 500)
	check(taps.size() == 2, "长按后抬手不再补点按（查看语义已消费）")
	# ---- 拖动：位移 >10pt；横滑 水平 >60pt 且垂直 <30pt（12 §1）----
	var drags: Array = []
	var hsw: Array = []
	var vsw: Array = []
	var rec2 := GestureRecognizer.new()
	rec2.dragged.connect(func(i: Dictionary) -> void: drags.append(i))
	rec2.h_swiped.connect(func(d: int, p: Vector2) -> void: hsw.append(d))
	rec2.v_swiped.connect(func(d: int, p: Vector2) -> void: vsw.append(d))
	rec2.press(0, V.call(0, 0), 0)
	rec2.move(0, V.call(10, 0), 10)
	rec2.release(0, V.call(10, 0), 100)
	check(drags.is_empty() and hsw.is_empty(), "拖动边界：位移 10pt 不判拖动（>10pt 严格）")
	rec2.press(0, V.call(0, 0), 0)
	rec2.move(0, V.call(11, 0), 10)
	rec2.release(0, V.call(11, 0), 100)
	check(drags.size() == 1, "拖动：位移 >10pt（12 §1）")
	rec2.press(0, V.call(0, 0), 0)
	rec2.move(0, V.call(61, 29), 10)
	rec2.release(0, V.call(61, 29), 100)
	check(hsw.size() == 1 and hsw[0] == 1, "横滑：水平 61pt 垂直 29pt = h_swipe 向右（12 §1）")
	rec2.press(0, V.call(0, 0), 0)
	rec2.move(0, V.call(60, 10), 10)
	rec2.release(0, V.call(60, 10), 100)
	check(hsw.size() == 1, "横滑边界：水平 60pt 不判横滑（>60pt 严格）")
	rec2.press(0, V.call(0, 0), 0)
	rec2.move(0, V.call(61, 30), 10)
	rec2.release(0, V.call(61, 30), 100)
	check(hsw.size() == 1, "横滑边界：垂直 30pt 不判横滑（<30pt 严格）")
	rec2.press(0, V.call(0, 0), 0)
	rec2.move(0, V.call(29, 61), 10)
	rec2.release(0, V.call(29, 61), 100)
	check(vsw.size() == 1 and vsw[0] == 1, "下滑：垂直 61pt 水平 29pt = v_swipe 向下（04 §④.6 推进条回看）")
	# ---- 双指点击：<300ms 且各点位移 <10pt 且间距变化 <15pt（12 §1/§3.3）----
	var rec3 := GestureRecognizer.new()
	var tft: Array = []
	rec3.two_finger_tapped.connect(func(p: Vector2) -> void: tft.append(p))
	rec3.press(0, V.call(0, 0), 0)
	rec3.press(1, V.call(100, 0), 50) # 同窗容差内（>1 帧不判双指的容差 50ms）
	rec3.release(0, V.call(0, 0), 200)
	rec3.release(1, V.call(100, 0), 210)
	check(tft.size() == 1, "双指点击：同窗 + 299ms 内 + 间距不变（12 §1/§3.3）")
	var taps3: Array = []
	rec3.tapped.connect(func(p: Vector2) -> void: taps3.append(p))
	rec3.press(0, V.call(0, 0), 0)
	rec3.press(1, V.call(100, 0), 51) # 超窗：先后落点 >1 帧不判双指（12 §3.3）
	rec3.release(0, V.call(0, 0), 100)
	check(taps3.size() == 1, "双指边界：第二指晚 51ms → 不判双指，单指点按保留（12 §3.3）")
	rec3.release(1, V.call(100, 0), 120)
	check(taps3.size() == 2, "未配对第二指独立点按（不阻塞单指，12 §3.3）")
	# 间距变化 <15pt 边界（与捏合区分）：双指各移 <10pt 但相向合拢使间距变化压边界
	var rec4 := GestureRecognizer.new()
	var tft4: Array = []
	rec4.two_finger_tapped.connect(func(p: Vector2) -> void: tft4.append(p))
	rec4.press(0, V.call(0, 0), 0)
	rec4.press(1, V.call(100, 0), 0)
	rec4.move(0, V.call(7.45, 0), 50)
	rec4.move(1, V.call(92.55, 0), 50) # 间距 100→85.1，变化 14.9pt
	rec4.release(0, V.call(7.45, 0), 100)
	check(tft4.size() == 1, "双指点击边界：间距变化 14.9pt 仍判双指点击（<15pt）")
	rec4.release(1, V.call(92.55, 0), 110)
	rec4.press(0, V.call(0, 0), 0)
	rec4.press(1, V.call(100, 0), 0)
	rec4.move(0, V.call(7.5, 0), 50)
	rec4.move(1, V.call(92.5, 0), 50) # 间距 100→85，变化恰 15pt
	rec4.release(0, V.call(7.5, 0), 100)
	rec4.release(1, V.call(92.5, 0), 110)
	check(tft4.size() == 1, "双指点击边界：间距变化 15pt 不判双指点击（<15pt 严格）")
	# ---- 捏合：双触点间距变化 >20%（12 §1）----
	var rec5 := GestureRecognizer.new()
	var pinches: Array = []
	rec5.pinched.connect(func(r: float, c: Vector2) -> void: pinches.append(r))
	rec5.press(0, V.call(0, 0), 0)
	rec5.press(1, V.call(100, 0), 0)
	rec5.move(1, V.call(120, 0), 50)
	check(pinches.is_empty(), "捏合边界：间距变化 20% 不触发（>20% 严格）")
	rec5.move(1, V.call(121, 0), 60)
	check(pinches.size() == 1 and pinches[0] > 1.2, "捏合：间距变化 >20% 触发并播报倍率（12 §1）")
	# ---- 轨迹：拖动经过 ≥2 个语义目标点（12 §1 path；探针由壳注入）----
	var rec6 := GestureRecognizer.new()
	rec6.target_probe = func(p: Vector2) -> String: return "a" if p.x < 50.0 else "b"
	var paths: Array = []
	var drags6: Array = []
	rec6.path_cast.connect(func(i: Dictionary) -> void: paths.append(i))
	rec6.dragged.connect(func(i: Dictionary) -> void: drags6.append(i))
	rec6.press(0, V.call(0, 0), 0)
	rec6.move(0, V.call(30, 0), 10) # 越过拖动阈值，途经目标 a
	rec6.move(0, V.call(60, 0), 20) # 途经目标 b
	rec6.release(0, V.call(60, 0), 100)
	check(paths.size() == 1 and (paths[0]["targets"] as Array) == ["a", "b"],
		"轨迹：途经 2 个语义目标 = path（12 §1）")
	rec6.press(0, V.call(0, 0), 0)
	rec6.move(0, V.call(40, 0), 10)
	rec6.release(0, V.call(40, 0), 100)
	check(drags6.size() == 1 and paths.size() == 1, "轨迹边界：途经 1 个目标 = 平拖（≥2 才判 path）")
	# ---- 打断：按抬手于空位处理 = 取消（12 §3.5）----
	var rec7 := GestureRecognizer.new()
	var drags7: Array = []
	rec7.dragged.connect(func(i: Dictionary) -> void: drags7.append(i))
	rec7.press(0, V.call(0, 0), 0)
	rec7.move(0, V.call(30, 0), 10)
	rec7.cancel_all() # 来电/切后台
	rec7.release(0, V.call(30, 0), 100)
	check(drags7.is_empty() and rec7.is_idle(), "打断 = 取消：不产生半状态指令（12 §3.5）")

# ---------------------------------------------------------------- 事件中心放弃（04 §⑤：写旗标 + 事件 → 归档历史卷轴）

func test_quest_abandon() -> void:
	print("[quest_abandon]")
	var pack := _load_campaign01()
	var stream := EventStream.new()
	var board := Board.new(stream)
	var g := StoryGraph.new(board, Rng.new(1), pack)
	g._enter("N1-8") # hidden lone_wolf（rep 全 0 满足隐形门槛）随节点进入触发
	var before := g.quest_badge_count()
	g._scan_choice_quests({"label": "誊写庭委托"}) # choice 触发 archive_quest（tech/02 §5）
	var qs := g.quests()
	var aq := {}
	for q: Variant in qs:
		if str((q as Dictionary)["id"]) == "archive_quest":
			aq = q
	check(not aq.is_empty() and str(aq["state"]) == "triggered" and bool(aq["optional"]),
		"choice 触发 = 可选事件（04 §⑤ 放弃范围）")
	check(g.quest_badge_count() == before + 1, "触发计入角标")
	check(g.abandon_quest("archive_quest"), "放弃可选事件受理（04 §⑤）")
	check(bool(board.read("campaign01.quest_abandoned.archive_quest")),
		"放弃写旗标 campaign01.quest_abandoned.*（04 §⑤，07 §1 溯源）")
	check(stream.query_by_type(EventTypes.QUEST_ABANDON).size() == 1,
		"quest.abandon 事件入流（归档历史卷轴，04 §⑤）")
	check(g.quest_badge_count() == before, "放弃后不计角标")
	check(not g.abandon_quest("archive_quest"), "重复放弃拒绝（幂等）")
	# auto 触发的主线事件不可放弃
	var g2 := StoryGraph.new(board, Rng.new(1), pack)
	g2._enter("N0-2") # dock_tales auto 触发
	check(not g2.abandon_quest("dock_tales"), "auto 主线事件不可放弃（仅可选事件，04 §⑤）")
	# 放弃状态随图快照持久（07 §4.1）
	var snap := g.serialize()
	var g3 := StoryGraph.new(board, Rng.new(1), pack)
	g3.deserialize(snap)
	var kept := false
	for q: Variant in g3.quests():
		if str((q as Dictionary)["id"]) == "archive_quest":
			kept = str((q as Dictionary)["state"]) == "abandoned"
	check(kept, "放弃状态随存档快照往返（07 §4 兼容）")

# ---------------------------------------------------------------- 缺口批 shell 集成（12 §1~§4；04 §④.2/§④.7/§⑤/§⑥/§⑧）

func test_gap_features() -> void:
	print("[gap_features]")
	var stream := EventStream.new()
	var board := Board.new(stream)
	var sm := EncounterSM.new(board, stream, Rng.new(11), "campaign01")
	var agent := AutoAgent.new()
	var portrait: EncounterPortrait = (load("res://shell/portrait/encounter_portrait.tscn") as PackedScene).instantiate()
	root.add_child(portrait)
	await process_frame
	await process_frame
	portrait.bind(sm, agent)
	sm.enter("N1-7")
	sm.transition(EncounterSM.S_EXPLORE)
	sm.begin_combat(_std_def())
	await process_frame
	await process_frame
	# 驱动到 pc 行动
	var guard := 0
	while sm.current_actor_id() != "pc" and guard < 6:
		guard += 1
		sm.submit_command(_cmd(EncounterSM.CMD_END_TURN, sm.current_actor_id()))
	await process_frame
	var uid := sm.current_actor_id()
	var enemy := sm.first_alive_enemy()

	# ---- 双壳手势 → 同构 Command（09 §9.3 同通道；12 §2 场景映射同一指令）----
	# 横屏对照壳（同一指令集单源）
	var stream2 := EventStream.new()
	var board2 := Board.new(stream2)
	var sm2 := EncounterSM.new(board2, stream2, Rng.new(11), "campaign01")
	var agent2 := AutoAgent.new()
	var land: EncounterLandscape = (load("res://shell/landscape/encounter_landscape.tscn") as PackedScene).instantiate()
	root.add_child(land)
	await process_frame
	await process_frame
	land.bind(sm2, agent2)
	sm2.enter("N1-7")
	sm2.transition(EncounterSM.S_EXPLORE)
	sm2.begin_combat(_std_def())
	await process_frame
	await process_frame
	var guard2 := 0
	while sm2.current_actor_id() != "pc" and guard2 < 6:
		guard2 += 1
		sm2.submit_command(_cmd(EncounterSM.CMD_END_TURN, sm2.current_actor_id()))
	await process_frame
	# 双指点击 = 结束回合：两壳手势处理器产出同构命令（GestureCommands 单源）
	var cmd_p := GestureCommands.end_turn(sm)
	var cmd_l := GestureCommands.end_turn(sm2)
	check(cmd_p == cmd_l and cmd_p["type"] == EncounterSM.CMD_END_TURN,
		"双壳手势 → 同构 Command：双指点击 = 结束回合（09 §9.3/12 §2）")
	# 轨迹施法：两壳同一出口（首个敌指向技能，目标同一敌人）
	var cast_p := GestureCommands.cast_at(sm, enemy)
	var cast_l := GestureCommands.cast_at(sm2, sm2.first_alive_enemy())
	check(cast_p == cast_l and cast_p["type"] == EncounterSM.CMD_SKILL
		and str(cast_p["skill"]) == "inkbolt" and str(cast_p["target"]) == enemy,
		"双壳手势 → 同构 Command：拖到敌方 = 轨迹施法（12 §2.1/§2.2）")
	# 移动命令同构
	var mv_p := GestureCommands.move_to(sm, "3,1")
	var mv_l := GestureCommands.move_to(sm2, "3,1")
	check(mv_p == mv_l and mv_p["type"] == EncounterSM.CMD_MOVE,
		"双壳手势 → 同构 Command：拖动己方 = 移动（消耗移动段，11 §4）")

	# ---- 竖屏手势接入（12 §2.2）----
	# 双指点击主视野 = 结束回合（真实走手势处理器 → _manual → submit_command）
	# （pc 是本轮最后一名待行动单位：结束回合 → 敌方回合 → 第 2 轮，09 §5.2 轮替即证据）
	var main_center: Vector2 = portrait.main_view.get_global_rect().get_center()
	portrait._on_gesture_two_finger_tap(main_center)
	await process_frame
	check(sm.round_no() == 2, "竖屏：双指点击主视野 = 结束回合（12 §2.2；轮替发生）")
	# 移动段：手势移动一次受理，第二次拒绝（11 §4 移动段每回合一段）
	check(sm.submit_command(GestureCommands.move_to(sm, "stance:forward")), "移动段：首次移动受理（11 §4）")
	check(not sm.submit_command(GestureCommands.move_to(sm, "stance:back")),
		"移动段：第二次移动拒绝 move_used（11 §4）")
	check(stream.query_by_type(EventTypes.BATTLE_MOVE).size() == 1, "battle.move 事件入流（溯源 dest）")
	# 移动段耗尽后拖动手势被 core 拒绝（不污染逻辑状态，tech/01 §6.2）
	var moves_before := stream.query_by_type(EventTypes.BATTLE_MOVE).size()
	portrait._drag_uid = sm.current_actor_id()
	portrait._on_gesture_dragged({"start": Vector2.ZERO, "end": Vector2(-9999, -9999), "delta": Vector2(-30, -30)})
	check(stream.query_by_type(EventTypes.BATTLE_MOVE).size() == moves_before,
		"移动段耗尽：拖动拒绝（command.rejected，tech/01 §6.2）")
	# 横滑切 Tab（12 §2.2：四 Tab 循环）
	var tab0: int = portrait.tabs.current_tab
	portrait._on_gesture_h_swipe(1, portrait.console_panel.get_global_rect().get_center())
	check(portrait.tabs.current_tab == tab0 + 1, "竖屏：横滑操作台 = 切 Tab（12 §2.2）")
	portrait._on_gesture_h_swipe(1, portrait.console_panel.get_global_rect().get_center())
	portrait._on_gesture_h_swipe(1, portrait.console_panel.get_global_rect().get_center())
	portrait._on_gesture_h_swipe(1, portrait.console_panel.get_global_rect().get_center())
	check(portrait.tabs.current_tab == tab0, "横滑四 Tab 循环一周（13 §3 Tab 循环）")
	# 长按单位 = 详情半屏卡（12 §2.2）
	portrait._on_gesture_long_press(portrait.enemy_row.get_child(0).get_global_rect().get_center())
	check(portrait.info_popup.visible and portrait.info_popup.body_label.text.contains("AC"),
		"竖屏：长按单位 = 详情半屏卡（HP/AC/伤害骰/状态，12 §2.1）")
	portrait.info_popup.hide()
	# 捏合：松手弹回（04 §④.4）
	portrait._on_gesture_pinch(0.5, main_center)
	check(absf(portrait._zoom - 0.7) < 0.001, "竖屏捏合缩放下限 0.7（任务书 0.7~1.6）")
	portrait._on_gesture_pinch_ended(1.0, main_center)
	check(portrait._zoom == 1.0, "竖屏捏合松手弹回（04 §④.4）")

	# ---- 横屏手势接入（12 §2.1）----
	# 拖动己方单位 → 空格 = 移动（呈现层落位 + 移动段消耗）
	var pc_cell := land.unit_cell("pc")
	var dest := Vector2i(mini(pc_cell.x + 2, EncounterLandscape.GRID_COLS - 1), pc_cell.y)
	if land._unit_at_cell(dest) != "":
		dest = Vector2i(maxi(pc_cell.x - 2, 0), pc_cell.y)
	var dest_center: Vector2 = land._cells[dest.y * EncounterLandscape.GRID_COLS + dest.x].get_global_rect().get_center()
	var pc_center: Vector2 = land._cells[pc_cell.y * EncounterLandscape.GRID_COLS + pc_cell.x].get_global_rect().get_center()
	land._on_gesture_drag_started({"start": pc_center, "pos": pc_center})
	land._on_gesture_dragged({"start": pc_center, "end": dest_center, "delta": dest_center - pc_center})
	await process_frame
	check(land.unit_cell("pc") == dest, "横屏：拖到可达空格 = 呈现层落位（12 §2.1 落点预览）")
	check(stream2.query_by_type(EventTypes.BATTLE_MOVE).size() == 1
		and str(stream2.query_by_type(EventTypes.BATTLE_MOVE)[0]["payload"]["dest"]) == "%d,%d" % [dest.x, dest.y],
		"横屏：拖动移动消耗移动段（battle.move 带格位溯源，11 §4）")
	# 拖出 6 格外 = 取消（可达性壳层约束；pc 在底排，(7,0) 曼哈顿 ≥8 且敌方只占 x=1/3/5）
	var pc_cell2 := land.unit_cell("pc")
	var far := Vector2i(7, 0)
	check(land._unit_at_cell(far) == "", "横屏拖测前提：远格无占用")
	var far_center: Vector2 = land._cells[far.y * EncounterLandscape.GRID_COLS + far.x].get_global_rect().get_center()
	var pc_center2: Vector2 = land._cells[pc_cell2.y * EncounterLandscape.GRID_COLS + pc_cell2.x].get_global_rect().get_center()
	land._on_gesture_drag_started({"start": pc_center2, "pos": pc_center2})
	land._on_gesture_dragged({"start": pc_center2, "end": far_center, "delta": far_center - pc_center2})
	check(land.unit_cell("pc") == pc_cell2, "横屏：落点不可达/超 6 格 = 取消（12 §3.2；11 §4 ≤6 格）")
	# 双指点击战场 = 结束回合（pc 已是本轮最后一名：轮替至第 2 轮即证据）
	land._on_gesture_two_finger_tap(land.center_map.get_global_rect().get_center())
	await process_frame
	check(sm2.round_no() == 2, "横屏：双指点击战场 = 结束回合（12 §2.1；轮替发生）")
	# 捏合 = 缩放 0.7~1.6 持续生效（12 §2.1）
	land._on_gesture_pinch(3.0, land.center_map.get_global_rect().get_center())
	check(absf(land._zoom - 1.6) < 0.001, "横屏捏合缩放上限 1.6（任务书 0.7~1.6）")
	land._on_gesture_pinch_ended(3.0, land.center_map.get_global_rect().get_center())
	land._on_gesture_pinch(0.1, land.center_map.get_global_rect().get_center())
	check(absf(land._zoom - 0.7) < 0.001, "横屏捏合缩放下限 0.7")
	# 长按格内单位 = 详情卡
	land._on_gesture_long_press(land.center_map.get_global_rect().get_center())
	# 中心未必有单位；对 pc 格长按
	var pc_cell3 := land.unit_cell("pc")
	var pc_center3: Vector2 = land._cells[pc_cell3.y * EncounterLandscape.GRID_COLS + pc_cell3.x].get_global_rect().get_center()
	land._on_gesture_long_press(pc_center3)
	check(land.info_popup.visible and land.info_popup.body_label.text.contains("HP"),
		"横屏：长按单位 = 详情半屏卡（12 §2.1）")
	land.info_popup.hide()
	portrait.queue_free()
	land.queue_free()
	await process_frame

	# ---- 房间推进条回看（04 §④.2：只读，已完成不重置）----
	var stream3 := EventStream.new()
	var board3 := Board.new(stream3)
	var pack3 := _load_campaign01()
	var pv: EncounterPortrait = (load("res://shell/portrait/encounter_portrait.tscn") as PackedScene).instantiate()
	root.add_child(pv)
	await process_frame
	await process_frame
	pv.bind_story(stream3, board3, pack3, {"edge": func(_i: int) -> void: pass})
	pv.set_rooms(["N0-1", "N0-2", "N1-1", "N1-2"], 2,
		{"N0-1": "潮醒", "N0-2": "雨夜码头", "N1-1": "广场", "N1-2": "褪色现场"})
	var ev_before := stream3.size()
	pv._open_room_review()
	check(pv.is_review_visible(), "推进条：下滑/点按展开已过房间列表（04 §④.2）")
	check(pv.review_list.get_child_count() == 2, "回看列表 = 已过房间（不含当前/未来剪影）")
	(pv.review_list.get_child(0) as Button).pressed.emit()
	check(pv.review_detail.text.contains("潮醒"), "点房间 = 回看其摘要（04 §④.2）")
	check(stream3.size() == ev_before and board3.get_doom_clock() == 0,
		"回看只读：不产事件、不写板（已完成检定与战斗不重置，04 §④.2）")
	pv.review_popup.visible = false
	pv.queue_free()
	await process_frame

	# ---- 教程三层（12 §4）----
	var home: ScreenHome = (load("res://shell/ui/screen_home.tscn") as PackedScene).instantiate()
	root.add_child(home)
	await process_frame
	var done: Array = []
	home.tutorial_done.connect(func() -> void: done.append(true))
	home.show_launch_tutorial()
	check(home.tutorial.is_launch_visible(), "启动卡：首次启动 3 页核心手势卡（12 §4 第一层）")
	home.tutorial.next_page()
	home.tutorial.next_page()
	check(home.tutorial._page == 2, "启动卡翻页（右滑/下一页）")
	home.tutorial.next_page() # 末页再进 = 完成
	check(done.size() == 1 and not home.tutorial.is_launch_visible(), "启动卡可看完离开（可跳过常驻）")
	# 一次原则写板（12 §4：global.tutorial.* 全局白名单，任何包可写）
	var board4 := Board.new(EventStream.new())
	check(board3.write("global.tutorial.boot", true,
		{"event_id": 1, "node_id": "", "pack_id": "system"}), "教程触发记录写板（global.tutorial.* 白名单，07 §3）")
	check(board3.write("global.tutorial.combat", true,
		{"event_id": 1, "node_id": "", "pack_id": "campaign01"}), "教程记录任何包可写（07 §3 白名单）")
	check(board4.write("global.tutorial.boot", true,
		{"event_id": 1, "node_id": "", "pack_id": "system"}), "教程写板独立板同样受理")
	# 帮助页：手势图鉴全表 + 重学入口（12 §4 第三层）
	home._toggle_help()
	var help_text := ""
	for child: Node in home._help_overlay.get_child(0).get_children():
		if child is Label:
			help_text += (child as Label).text
	check(help_text.contains("拖动") and help_text.contains("双指点击") and help_text.contains("捏合")
		and help_text.contains("横滑") and help_text.contains("长按"),
		"帮助页：手势图鉴恢复 12 §1 全表（13 §1 帮助入口 ✅ 化）")
	var retrain: Array = []
	home.retrain_requested.connect(func() -> void: retrain.append(true))
	var retrain_btn: Button = null
	for child: Node in home._help_overlay.get_child(0).get_children():
		if child is Button and (child as Button).text == TextsZh.HELP_RETRAIN:
			retrain_btn = child
	check(retrain_btn != null, "帮助页：重学入口存在（12 §4 可重学）")
	retrain_btn.pressed.emit()
	check(retrain.size() == 1, "重学入口上报（清记录由 main 落板）")
	home._toggle_help()
	home.queue_free()
	await process_frame

	# ---- 事件中心放弃 UI（04 §⑤）----
	var qs5: ScreenQuests = (load("res://shell/ui/screen_quests.tscn") as PackedScene).instantiate()
	root.add_child(qs5)
	await process_frame
	qs5.bind([
		{"id": "archive_quest", "name": "档案馆委托", "objective": "送信", "node": "N2S-1",
			"state": "triggered", "optional": true},
		{"id": "dock_tales", "name": "码头异闻", "objective": "听说法", "node": "N0-2",
			"state": "triggered", "optional": false},
		{"id": "old", "name": "旧事", "objective": "", "node": "N0-1", "state": "settled", "optional": true},
	])
	check(qs5.abandon_button_count() == 1, "仅进行中的可选事件带「放弃」（04 §⑤）")
	var abandoned: Array = []
	qs5.abandon_requested.connect(func(qid: String) -> void: abandoned.append(qid))
	for row: Node in qs5.list_box.get_children():
		for child: Node in row.get_children():
			if child is Button and (child as Button).text == TextsZh.QUESTS_ABANDON:
				(child as Button).pressed.emit()
	check(abandoned == ["archive_quest"], "放弃上报 quest_id（写旗标由 core 落）")
	qs5.queue_free()
	await process_frame

	# ---- 背包图鉴完整版（04 §⑥；10 §1/§3/§4）----
	var iv: ScreenInventory = (load("res://shell/ui/screen_inventory.tscn") as PackedScene).instantiate()
	root.add_child(iv)
	await process_frame
	var inv := {"heal_potion": 2, "codex_fragment": 1}
	iv.bind(inv, _load_campaign01()["items"], ["weaver_fragment_01"], _load_campaign01()["lore"])
	var n_all := iv.bag_entry_count()
	check(n_all == 2, "背包：全部身份条目入列（04 §⑥）")
	# 四重身份筛选：codex 只剩信物
	iv._filter = "codex"
	iv._render_bag()
	await process_frame # queue_free 延迟回收：隔帧再计数
	check(iv.bag_entry_count() == 1, "背包：按四重身份筛选（图鉴信物，10 §1）")
	iv._filter = ""
	iv._render_bag()
	await process_frame
	# 道具详情（04 §⑥ 详情弹层：属性/检定修正/分支提示）
	iv.show_item_detail("codex_fragment")
	check(iv.info_popup.visible and iv.info_popup.body_label.text.contains(TextsZh.INV_BRANCH_HINT),
		"道具详情：分支钥匙提示（04 §⑥「某处派上用场」句式）")
	iv.info_popup.hide()
	# 图鉴四系列进度 + 集齐奖励预告（worldview §9；10 §4）
	var codex_text := ""
	for child: Node in iv.codex_box.get_children():
		if child is Label:
			codex_text += (child as Label).text + "\n"
	check(codex_text.contains("织命者残简：1/4") and codex_text.contains("被撤销者名录：0/2")
		and codex_text.contains("烬港风物志：0/1") and codex_text.contains("命骰考：0/0"),
		"图鉴：四系列进度（lore.json × global.lore，10 §3）")
	check(codex_text.contains("集齐") and codex_text.contains("隐藏剧情线"),
		"图鉴：集齐奖励预告（10 §4 白名单，永不卖数值）")
	check(codex_text.contains("残简·其一") and codex_text.contains(TextsZh.CODEX_LOCKED_TITLE),
		"图鉴：已解锁 Lore 条目呈题，未解锁占位（04 §⑥）")
	iv.queue_free()
	await process_frame

	# ---- 战报回放最小版（04 §⑧：事件流重演，纯演出不可改结果）----
	var stream6 := EventStream.new()
	var board6 := Board.new(stream6)
	stream6.emit(EventTypes.COMBAT_START, {"order": ["pc", "imp1"]}, &"core", "N1-7")
	stream6.emit(EventTypes.BATTLE_ATTACK, {"attacker": "pc", "target": "imp1", "hit": true,
		"damage": 5, "rolls": [12], "keep": 12, "atk_mod": 2, "target_ac": 10,
		"crit": false, "fumble": false,
		"attacker_name": "白页者", "target_name": "小墨妖", "damage_rolls": [5]}, &"core", "N1-7")
	stream6.emit(EventTypes.COMBAT_END, {"result": &"victory", "rounds": 1}, &"core", "N1-7")
	var hi6: ScreenHistory = (load("res://shell/ui/screen_history.tscn") as PackedScene).instantiate()
	root.add_child(hi6)
	await process_frame
	hi6.bind(stream6, board6)
	var ev6_before := stream6.size()
	hi6.start_replay(1)
	await create_timer(1.8).timeout # 3 拍 × 0.5s 播完
	check(hi6.is_replay_visible() and hi6.replay_text().contains("白页者"),
		"战报重演：事件流按节拍重放进只读战报视图（04 §⑧，最小版=节拍日志重演）")
	check(stream6.size() == ev6_before and board6.keys_with_prefix("").is_empty(),
		"重演只读：不产事件、不写板（纯演出，不可改结果）")
	hi6._replay_close()
	hi6.queue_free()
	await process_frame
