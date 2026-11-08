# 子游戏连战流程核（docs/subgames/arena/01-概念设计.md；白皮书 §10.2；04 §6 进出场必经结算）
# 引导层（与 main.gd 同层，非 core/shell）：复用 StoryGraph 走子游戏节点图 + EncounterSM 打每场战斗，
# 全部行为数据驱动自内容包——节点/边/遭遇/敌人读 pack 各表；奖励与战绩键读 manifest.subgame 声明
# （gold_reward 每场金币、stat_keys 战绩簿记键；tech/02 §2 subgame 变体块，待裁决登记见概念设计 §8）。
# 写板一律经 Board 公共 API 带溯源（07 §1）；经验随 EncounterSM 胜利结算经 Growth 汇入
# global.growth.*（tech/04 §8 规则1：子游戏经验喂养角色成长，概念设计 §8 待裁决 3 随定稿消解）；
# core/ 零改动——本类的存在本身即 §10.2"子游戏不动框架"的验证证据。
class_name SubgameRunner
extends RefCounted

var pack: Dictionary
var board: Board
var stream: EventStream
var rng: Rng
var graph: StoryGraph
var pack_id: String

var run_wins := 0        # 本次连战已胜场数（中途退出/败北按此结算）
var run_gold := 0        # 本次连战已得金币（汇总呈现用）
var run_over := false    # 本次连战已收场（全胜/退出/败北）
var last_result: StringName = &""

func _init(p_pack: Dictionary, p_board: Board, p_stream: EventStream, p_rng: Rng) -> void:
	pack = p_pack
	board = p_board
	stream = p_stream
	rng = p_rng
	pack_id = str(pack.get("pack_id", ""))
	graph = StoryGraph.new(board, rng, pack)

# ---------------------------------------------------------------- 图推进（tech/02 §3/§4）

func start() -> void:
	graph.start()

func current() -> Dictionary:
	return graph.current()

## 当前战斗节点的遭遇 id（tech/02 §6：节点 encounter 关联，缺省同节点号）。
func encounter_id() -> String:
	return str(current().get("encounter", graph.current_id))

## 战斗定义 = 子游戏包资源表组装（tech/04 §1~§4；HP 跨场持久由 <ns>.hp.* 簿记承载，11 §7.1）。
func battle_def(selection: Dictionary) -> Dictionary:
	var res := BattleDef.assemble(pack, encounter_id(), selection, board)
	if not bool(res["ok"]):
		push_error("[subgame] 战斗定义组装失败（%s/%s）：%s"
			% [pack_id, encounter_id(), ";".join(res["errors"] as Array)])
		return {}
	return res["def"]

## 玩家执行节点选项（scene 继续 / 战后 追击·收兵 选择边）。
func take_edge(idx: int) -> void:
	var edges := graph.available_edges()
	if idx < 0 or idx >= edges.size():
		return
	graph.take_edge(edges[idx])

# ---------------------------------------------------------------- 奖励与战绩（04 §6 写状态板是硬要求；概念设计 §3）

func _prov() -> Dictionary:
	return {"event_id": stream.tail(), "node_id": graph.current_id, "pack_id": pack_id}

func _sub_cfg() -> Dictionary:
	return (pack.get("manifest", {}) as Dictionary).get("subgame", {})

func _stat_key(name: String) -> String:
	return str((_sub_cfg().get("stat_keys", {}) as Dictionary).get(name, "%s.%s" % [pack_id, name]))

## 每场胜利结算（概念设计 §3）：金币 = manifest.subgame.gold_reward[本场序号] 增量写 <ns>.gold；
## 累计胜场 +1 写 stat_keys.wins。经验与战利品由 EncounterSM 结算落板（xp/loot 数据在 encounters.json）。
func on_victory() -> void:
	var rewards: Array = _sub_cfg().get("gold_reward", [])
	var gold := int(rewards[mini(run_wins, rewards.size() - 1)]) if not rewards.is_empty() else 0
	if gold > 0:
		run_gold += gold
		board.write("%s.gold" % pack_id, int(board.read("%s.gold" % pack_id, 0)) + gold, _prov())
	run_wins += 1
	board.write(_stat_key("wins"), int(board.read(_stat_key("wins"), 0)) + 1, _prov())
	stream.emit(EventTypes.LOG, {"msg": "第 %d 场告捷：金币 +%d（连胜无休整，下一场带伤上阵）" % [run_wins, gold],
		"toast": true}, &"core", graph.current_id)

## 连战收场（全胜/见好就收/败北）：最佳连战纪录取大写 stat_keys.best（战绩簿记，04 §6）。
func finish_run(result: StringName) -> Dictionary:
	run_over = true
	last_result = result
	var best := int(board.read(_stat_key("best"), 0))
	if run_wins > best:
		board.write(_stat_key("best"), run_wins, _prov())
		best = run_wins
	return {"result": result, "wins": run_wins, "gold": run_gold, "best": best,
		"flawless": bool(board.read("%s.flawless" % pack_id))}

## 战绩卡数据源（入口卡呈现，概念设计 §3）：累计胜场 / 最佳连战。
func stats() -> Dictionary:
	return {"wins": int(board.read(_stat_key("wins"), 0)),
		"best": int(board.read(_stat_key("best"), 0)),
		"gold": int(board.read("%s.gold" % pack_id, 0))}

# ---------------------------------------------------------------- 整备候选（09 §9.1；tech/02 §2.4；候选口径同 main._loadout_candidates）

func loadout_config() -> Dictionary:
	return Loadout.resolve_config(pack, encounter_id())

func loadout_candidates() -> Dictionary:
	var skill_pool: Array = []
	var skills: Dictionary = pack.get("skills", {})
	for cid: String in (pack.get("characters", {}) as Dictionary).keys():
		var c: Dictionary = pack["characters"][cid]
		if str(c.get("kind", "")) != "player_template":
			continue
		for sid: Variant in c.get("skills", []):
			if skills.has(str(sid)):
				skill_pool.append(BattleDef.runtime_skill(skills[str(sid)]))
	var items: Array = []
	for iid: String in (pack.get("items", {}) as Dictionary).keys():
		var it: Dictionary = pack["items"][iid]
		if it.has("use") and board.has_item(iid):
			items.append({"id": iid, "name": str(it.get("name", iid)), "count": board.item_count(iid)})
	return {"skills": skill_pool, "items": items,
		# 成长簿记归框架全局键（tech/04 §8）：子游戏整备同口径分配（概念设计 §8 待裁决 3 结构消解）
		"attr_points": Growth.attr_points(board), "attrs": Growth.attrs_map(board),
		"attr_alloc": {"might": 0, "finesse": 0, "wits": 0}}
