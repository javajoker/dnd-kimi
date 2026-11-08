# bot 仿真 CLI：godot --headless --path game -s tools/simulate.gd [-- 种子数]
# TASKS P1.5 TP1：多 seed（默认 24，半数二周目配置）断言——
#   1) 每局必达结局；2) 全部路径 clock ∈ 0~10；3) 四结局全集可达（含二周目）；4) 节点覆盖率报告。
extends SceneTree

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var seed_count := 24
	if not args.is_empty():
		seed_count = int(args[0])
	var res := PackLoader.load_pack("res://packs/campaign01")
	if not res["ok"]:
		for e: String in res["errors"]:
			push_error(e)
		quit(1)
		return
	var pack: Dictionary = res["pack"]

	print("== campaign01 bot 仿真：%d 局（半数二周目） ==" % seed_count)
	var failures := 0
	var endings := {} # ending_id -> count
	var coverage := {} # node_id -> 到达局数
	var lone_wolf_hits := 0
	var total_checks := 0
	var total_check_success := 0
	for i: int in seed_count:
		# 种子大步长混合：RandomNumberGenerator（PCG32）相邻种子早期输出相关，
		# 连续整数种子会让各局的同序位抽骰系统性趋同（仿真实测接触选择分布 [3,15,6]→[10,6,8]）。
		var seed := 1000 + i * 7919
		var ngplus := i % 2 == 1 # 半数二周目（多周目继承配置）
		var lone_wolf := i % 4 == 2 # 1/4 一周目局为独狼探针（TP1 验收裁决 1 可达性验证）
		var r := StoryBot.run(pack, seed, ngplus, lone_wolf)
		if not r["ok"]:
			failures += 1
			push_error("  FAIL seed=%d ngplus=%s：%s" % [seed, ngplus, r["reason"]])
			continue
		if (r["visited"] as Dictionary).has("N2L-1") or (r["visited"] as Dictionary).has("N2L-1b"):
			lone_wolf_hits += 1
		var ending := str(r["ending"])
		# 图边结局与结局表求值互证（tech/02 §9）
		if str(r["ending_by_table"]) != "" and str(r["ending_by_table"]) != ending:
			failures += 1
			push_error("  FAIL seed=%d：图边结局 %s 与 endings.json 求值 %s 不一致" % [seed, ending, str(r["ending_by_table"])])
		if int(r["clock_min"]) < Board.CLOCK_MIN or int(r["clock_max"]) > Board.CLOCK_MAX:
			failures += 1
			push_error("  FAIL seed=%d：clock 越界 [%d, %d]" % [seed, int(r["clock_min"]), int(r["clock_max"])])
		endings[ending] = int(endings.get(ending, 0)) + 1
		for nid: String in (r["visited"] as Dictionary).keys():
			coverage[nid] = int(coverage.get(nid, 0)) + 1
		total_checks += int((r["checks"] as Dictionary)["total"])
		total_check_success += int((r["checks"] as Dictionary)["success"])
		print("  seed=%-5d %s 结局=%s 步数=%-3d clock峰值=%d 检定=%d/%d" % [
			seed, "二周目" if ngplus else "一周目", ending, int(r["steps"]),
			int(r["clock_max"]), int((r["checks"] as Dictionary)["success"]), int((r["checks"] as Dictionary)["total"])])

	# 结局分布
	print("-- 结局分布 --")
	for eid: String in ["E1", "E2", "E3", "E4"]:
		var c := int(endings.get(eid, 0))
		print("  %s：%d 局" % [eid, c])
		if c == 0:
			failures += 1
			push_error("  FAIL 结局 %s 在 %d 局中零达成" % [eid, seed_count])

	# 独狼路径可达（TP1 验收裁决 1）
	if lone_wolf_hits == 0:
		failures += 1
		push_error("  FAIL 独狼路径（N2L-1/N2L-1b）在 %d 局中零命中" % seed_count)
	else:
		print("  独狼路径命中：%d 局（TP1 验收裁决 1 ✓）" % lone_wolf_hits)

	# 覆盖率报告（目标 ≥95%）
	var order: Array = pack["node_order"]
	var covered := 0
	print("-- 节点覆盖率（到达局数/%d） --" % seed_count)
	for nid: String in order:
		var c := int(coverage.get(nid, 0))
		if c > 0:
			covered += 1
		else:
			print("  未覆盖：%s（%s）" % [nid, str((pack["nodes"][nid] as Dictionary).get("title", ""))])
	var ratio := 100.0 * covered / order.size()
	print("  覆盖 %d/%d 节点（%.1f%%）" % [covered, order.size(), ratio])
	if ratio < 95.0:
		failures += 1
		push_error("  FAIL 节点覆盖率 %.1f%% < 95%%" % ratio)
	if total_checks > 0:
		print("  检定通过率：%d/%d（%.0f%%）" % [total_check_success, total_checks,
			100.0 * total_check_success / total_checks])

	if failures == 0:
		print("== 仿真断言全绿 ==")
	else:
		print("== 仿真失败：%d ==" % failures)
	quit(1 if failures > 0 else 0)
