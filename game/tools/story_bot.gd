# bot 仿真核（TASKS P1.5 TP1；检定公式依据 framework/11-轻规则包-v1.md §3）
# - 从入口节点随机走图：choice 随机（含策略优先项）/ check 用种子化 RNG 掷 d20 判成败 /
#   item·reputation 边由 StoryGraph 条件求值显隐 / 战斗节点按难度直接判胜（不跑战斗数值，TP1 范围）；
# - hub（N1-1）执行"购买半页潮汐表"策略（战役书 §8 投放点）；
# - 二周目配置（ngplus=true）：初始 inv 含 codex_fragment×1（战役书 §8 多周目继承 ×1）；
#   羁绊不再注入——按 TP1 验收裁决 2 改为图内投放，二周目以"上一周目（同包异种子）图内所得
#   bond.kelan 继承"作为初始状态（战役书 §9 E4 钩子：收集与进度保留），不含任何非图内数值；
# - 独狼探针（lone_wolf=true）：N1-3 优先"婉拒所有邀约"、N1-8 优先独狼边（TP1 验收裁决 1 可达性验证）；
# - 纯逻辑零引擎依赖，供 tools/simulate.gd（CLI）与 tests/run.gd 复用。
class_name StoryBot
extends RefCounted

## 轻规则包三档 DC（11 文档 §3：易 8 / 中 12 / 难 16）。
const DIFF_DC := {"easy": 8, "medium": 12, "hard": 16}
## bot 角色修正占位（+2 属性档，11 文档 §1；熟练另计，仿真取中位 +2）。
const BOT_CHECK_MOD := 2
const MAX_STEPS := 200

## 跑一局。返回 {ok, reason, ending, ending_by_table, steps, visited{node_id:count},
## clock_min, clock_max, bond_max, checks{total,success}, ngplus, lone_wolf}。
## detour_probe=true（幕二绕行探针）：N1-1 不买半页潮汐表且 N1-8 优先拾遗行会链——
## 确定性覆盖 N2G-2c 无道具绕行路（tech/02 §4.3 item 边 fallback，幕二接入验收）。
static func run(pack: Dictionary, seed: int, ngplus: bool = false, lone_wolf: bool = false,
		detour_probe: bool = false) -> Dictionary:
	var stream := EventStream.new()
	var board := Board.new(stream)
	var rng := Rng.new(seed)
	var graph := StoryGraph.new(board, rng, pack)
	if ngplus:
		var prov := {"event_id": 0, "node_id": "ngplus_boot", "pack_id": "system"}
		board.give_item("codex_fragment", 1, prov) # 战役书 §8：多周目继承 ×1
		# 多周目羁绊继承：上一周目图内投放所得（TP1 验收裁决 2；不含注入数值）
		var prev := run(pack, seed + 1, false, false)
		var prev_bond := int(prev.get("bond_max", 0))
		if prev_bond > 0:
			board.write("global.bond.kelan", prev_bond, prov)
	graph.start()

	var visited := {}
	var clock_min := 0
	var clock_max := 0
	var checks := {"total": 0, "success": 0}
	var ending_by_table := ""
	var steps := 0
	while steps < MAX_STEPS:
		steps += 1
		var node := graph.current()
		var nid := str(node.get("id", ""))
		visited[nid] = int(visited.get(nid, 0)) + 1
		var clock := board.get_doom_clock()
		clock_min = mini(clock_min, clock)
		clock_max = maxi(clock_max, clock)
		if graph.is_at_ending():
			return _result(true, "", nid, ending_by_table, steps, visited,
				clock_min, clock_max, board, checks, ngplus, lone_wolf)
		var edges := graph.available_edges()
		if edges.is_empty():
			return _result(false, "卡在节点 %s（无可走边）" % nid, "", "", steps, visited,
				clock_min, clock_max, board, checks, ngplus, lone_wolf)
		if nid == "N4-2":
			ending_by_table = graph.pick_ending() # 结局表求值与图边选择互证（tech/02 §9）
		var edge: Dictionary = _choose(node, edges, board, rng, ngplus, lone_wolf, detour_probe)
		if str(edge.get("type", "")) == "check":
			checks["total"] = int(checks["total"]) + 1
			var roll := rng.d20()
			# 11 文档 §3：自然 20 大成功 / 自然 1 大失败
			var success := roll == 20 or (roll != 1 and roll + BOT_CHECK_MOD >= int(DIFF_DC[str(edge.get("difficulty", "medium"))]))
			if success:
				checks["success"] = int(checks["success"]) + 1
			graph.resolve_check(edge, success)
		else:
			graph.take_edge(edge)
	return _result(false, "超步数上限 %d（疑似环）" % MAX_STEPS, "", "", steps, visited,
		clock_min, clock_max, board, checks, ngplus, lone_wolf)

static func _result(ok: bool, reason: String, ending: String, ending_by_table: String,
		steps: int, visited: Dictionary, clock_min: int, clock_max: int,
		board: Board, checks: Dictionary, ngplus: bool, lone_wolf: bool) -> Dictionary:
	var bond_max := 0
	for key: String in board.keys_with_prefix("global.bond."):
		bond_max = maxi(bond_max, int(board.read(key)))
	return {"ok": ok, "reason": reason, "ending": ending, "ending_by_table": ending_by_table,
		"steps": steps, "visited": visited, "clock_min": clock_min, "clock_max": clock_max,
		"bond_max": bond_max, "checks": checks, "ngplus": ngplus, "lone_wolf": lone_wolf}

## 选边策略：hub 优先购买潮汐表（绕行探针除外）；二周目优先拾遗行会链（密道残简，战役书 §8）；
## 独狼探针优先"婉拒所有邀约"与独狼边（TP1 验收裁决 1）；绕行探针优先拾遗行会链（N2G-2c 覆盖）；
## 终章按结局边列出顺序取首个显形边（E1→E2→E3 优先、E4 兜底，nodes.json N4-2 边序即优先级）；其余随机。
static func _choose(node: Dictionary, edges: Array, board: Board, rng: Rng,
		ngplus: bool, lone_wolf: bool, detour_probe: bool = false) -> Dictionary:
	var nid := str(node.get("id", ""))
	if nid == "N1-1" and detour_probe:
		for edge: Variant in edges: # 绕行探针：不买任何东西（无效果的「前往褪色现场」边）
			if ((edge as Dictionary).get("effects", []) as Array).is_empty():
				return edge
	if nid == "N1-1" and not board.has_item("half_tide_table") and not detour_probe:
		for edge: Variant in edges:
			for effect: Variant in (edge as Dictionary).get("effects", []):
				if (effect as Dictionary).get("give_item", "") == "half_tide_table":
					return edge
	if lone_wolf:
		if nid == "N1-3":
			for edge: Variant in edges:
				if str((edge as Dictionary).get("to", "")) == "N1-8":
					return edge # 婉拒所有邀约（TP1 验收裁决 1）
		if nid == "N1-8":
			for edge: Variant in edges:
				if str((edge as Dictionary).get("to", "")) == "N2L-1":
					return edge
	elif nid == "N1-8" and (ngplus or detour_probe):
		for edge: Variant in edges:
			if str((edge as Dictionary).get("to", "")) == "N2G-1":
				return edge
	if str(node.get("type", "")) == "branch" and nid == "N4-2":
		return edges[0]
	return edges[rng.range_int(0, edges.size() - 1)]
