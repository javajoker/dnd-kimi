# 胜率标定工具（docs/story/03-数值定稿与Boss设计.md §1 标定方法、§5 成长校核）
# CLI：godot --headless --path game -s tools/winrate.gd [-- 局数 基种子]
# - 对每场战斗型遭遇（battle/escort/hybrid）以默认队伍跑 N 局 bot（默认 200），输出胜率表；
#   默认队伍 = 按战役进度的预期等级（序章 Lv1 / 幕二 Lv2 / 幕三 Lv3 / 终章 Lv3~4 取下限 Lv3），
#   默认整备（空 selection：兜底技能、无道具），AutoAgent 策略链驱动（09 §9.3 同一指令通道）；
# - §5 校核：主线三链经验总量 vs 300/700/1200 门槛表（通关应落在 Lv3 区间 [700,1200)）；
# - 确定性：每局种子 = 基种子 + 局号 × 7919（与 tools/simulate.gd 同一大步长混合）；
#   同基种子重跑结果逐局一致（tests/run.gd 有断言）。
extends SceneTree

## §1 难度目标胜率区间（%）。
const TARGETS := {"easy": [85, 95], "medium": [70, 80], "hard": [50, 65]}
## 战役进度 → 预期等级（任务裁决：序章 Lv1 / 幕二 Lv2 / 幕三 Lv3 / 终章 Lv3~4 取下限 Lv3，标定从严）。
const ACT_LEVEL := {"SL-0": 1, "SL-1": 1, "SL-2": 2, "SL-3": 3, "SL-4": 3}
## 等级 → 入场累计经验（11 §6 门槛 300/700/1200 的下档值）。
const LEVEL_XP_FLOOR := {1: 0, 2: 300, 3: 700, 4: 1200}
const SEED_STRIDE := 7919
const MAX_TURNS_GUARD := 500

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var games := 200
	var base_seed := 20261109
	if args.size() >= 1:
		games = int(args[0])
	if args.size() >= 2:
		base_seed = int(args[1])
	var res := PackLoader.load_pack("res://packs/campaign01")
	if not res["ok"]:
		for e: String in res["errors"]:
			push_error(e)
		quit(1)
		return
	var pack: Dictionary = res["pack"]
	print("== 胜率标定（story/03 §1）：每场 %d 局 bot，基种子 %d ==" % [games, base_seed])
	print("默认队伍 = 预期等级（序章 Lv1/幕二 Lv2/幕三 Lv3/终章 Lv3）+ 默认整备（无道具）+ AutoAgent")
	print("%-8s %-6s %-4s %-9s %-8s %s" % ["遭遇", "难度", "等级", "目标胜率", "实测", "判定"])
	var all_in := true
	for eid: String in battle_encounters(pack):
		var enc: Dictionary = pack["encounters"][eid]
		var diff := str(enc.get("difficulty", "medium"))
		var r: Dictionary = run_encounter(pack, eid, games, base_seed)
		var rate := 100.0 * int(r["wins"]) / maxi(1, int(r["games"]))
		var tgt: Array = TARGETS.get(diff, TARGETS["medium"])
		var in_range := rate >= float(tgt[0]) and rate <= float(tgt[1])
		if not in_range:
			all_in = false
		print("%-8s %-6s Lv%-3d %3d~%-5d %5.1f%% (%d/%d) %s" % [eid, diff, int(r["level"]),
			int(tgt[0]), int(tgt[1]), rate, int(r["wins"]), int(r["games"]),
			"✓" if in_range else "✗ 超区间"])
	print("== 胜率表%s全部落入 §1 目标区间 ==" % ("" if all_in else "未"))
	# ---- §5 成长校核 ----
	print("-- §5 主线经验校核（门槛 300/700/1200，通关应达 Lv3 区间 [700,1200)） --")
	var xp_report: Dictionary = main_path_xp(pack)
	for chain: String in xp_report.keys():
		var total: int = xp_report[chain]
		print("  %s：%d xp → Lv%d %s" % [chain, total, LightV1.level_for_xp(total),
			"✓" if total >= 700 and total < 1200 else "✗ 越出 Lv3 区间"])
	quit(0)

# ---------------------------------------------------------------- 静态核（tests/run.gd 复用）

## 战斗型遭遇 id 列表（声明序；battle/escort/hybrid 且 enemies 非空）。
static func battle_encounters(pack: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for eid: String in (pack.get("encounters", {}) as Dictionary).keys():
		var enc: Dictionary = pack["encounters"][eid]
		if ["battle", "escort", "hybrid"].has(str(enc.get("type", ""))) \
				and not (enc.get("enemies", []) as Array).is_empty():
			out.append(eid)
	return out

## 遭遇 → 预期队伍等级：按挂载节点的幕次映射（ACT_LEVEL）。
static func encounter_level(pack: Dictionary, encounter_id: String) -> int:
	for nid: String in (pack.get("nodes", {}) as Dictionary).keys():
		var n: Dictionary = pack["nodes"][nid]
		if str(n.get("encounter", "")) == encounter_id:
			return int(ACT_LEVEL.get(str(n.get("act", "")), 1))
	return 1

## 单场遭遇跑 games 局 bot。返回 {wins, games, level, results[]}（results[i]=该局 result，供确定性断言）。
static func run_encounter(pack: Dictionary, encounter_id: String, games: int, base_seed: int) -> Dictionary:
	var level := encounter_level(pack, encounter_id)
	var xp_floor := int(LEVEL_XP_FLOOR.get(level, 0))
	var results: Array = []
	var wins := 0
	for i: int in games:
		var seed := base_seed + i * SEED_STRIDE
		var stream := EventStream.new()
		var board := Board.new(stream)
		var prov := {"event_id": 0, "node_id": encounter_id, "pack_id": str(pack.get("pack_id", ""))}
		if xp_floor > 0:
			Growth.new(board).grant_xp(xp_floor, prov) # 预期等级基线（属性点不分配 = 默认整备）
		var asm := BattleDef.assemble(pack, encounter_id, {}, board)
		if not bool(asm["ok"]):
			push_error("winrate：遭遇 %s 组装失败：%s" % [encounter_id, ";".join(asm["errors"] as Array)])
			results.append("assemble_error")
			continue
		var sm := EncounterSM.new(board, stream, Rng.new(seed), str(pack.get("pack_id", "")))
		var agent := AutoAgent.new()
		sm.enter(encounter_id)
		sm.transition(EncounterSM.S_EXPLORE)
		sm.begin_combat(asm["def"])
		var guard := 0
		while not sm.is_over() and guard < MAX_TURNS_GUARD:
			guard += 1
			var cmd := agent.next_command(sm)
			if cmd.is_empty():
				break
			sm.submit_command(cmd)
		results.append(str(sm.result()))
		if sm.result() == &"victory":
			wins += 1
	return {"wins": wins, "games": games, "level": level, "results": results}

## §5 主线经验总量校核：三条幕二委托链各自的"通关经验"（主线必经历程，不含失败路/绕行/可选节拍）。
## 口径：SL-0 自动事件 xp（dock_tales）+ N1-7 教学 Boss + 幕二本链主线 + 幕三房间链（R3→R4-r→R4-r2→R5）
## + 终章强攻 Boss（N4-1，誊写庭链持印戒免战不计）。返回 {chain_id: xp_total}。
static func main_path_xp(pack: Dictionary) -> Dictionary:
	var encounters: Dictionary = pack.get("encounters", {})
	var base := 0
	# SL-0/SL-1 自动触发事件的 settle xp（trigger.type=auto；doom_clock/choice 触发为分支相关，不计主线保底）
	for ev: Variant in pack.get("events", []):
		var trig: Dictionary = (ev as Dictionary).get("trigger", {})
		if str(trig.get("type", "")) == "auto":
			for eff: Variant in (ev as Dictionary).get("settle", []):
				base += int((eff as Dictionary).get("xp", 0))
	base += _enc_xp(encounters, "N1-7") # 幕一教学 Boss（三方接触后必经）
	var act3 := _enc_xp(encounters, "R3") + _enc_xp(encounters, "R4-r") \
		+ _enc_xp(encounters, "R4-r2") + _enc_xp(encounters, "R5")
	var finale := _enc_xp(encounters, "N4-1") # 强攻路（无印戒）；持印戒免战 = 减此项
	# 幕二主线（三链各自必经历程的战斗/探索节拍 xp）：
	# S 链：护送战 N2S-2；U 链：撕页行动 N2U-2；G 链：打捞 maze 检定拍成功 xp（名义值）
	var maze_xp := 0
	var maze: Dictionary = (encounters.get("N2G-2", {}) as Dictionary).get("maze", {})
	for beat: Variant in maze.get("beats", []):
		for eff: Variant in ((beat as Dictionary).get("success_effects", []) as Array):
			maze_xp += int((eff as Dictionary).get("xp", 0))
	return {
		"誊写庭链(印戒免战)": base + _enc_xp(encounters, "N2S-2") + act3,
		"断墨会链(强攻)": base + _enc_xp(encounters, "N2U-2") + act3 + finale,
		"拾遗行会链(强攻)": base + maze_xp + act3 + finale,
	}

static func _enc_xp(encounters: Dictionary, eid: String) -> int:
	return int((encounters.get(eid, {}) as Dictionary).get("xp", 0))
