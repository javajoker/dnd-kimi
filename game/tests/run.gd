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
