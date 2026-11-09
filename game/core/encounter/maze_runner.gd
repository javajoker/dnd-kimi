# 迷宫探索序列核（docs/tech/02-内容包格式规范.md §6 maze 块；04 文档 §④.3 房间类型的序列化呈现）
# - 以 2~3 个节拍呈现迷宫遭遇：check（检定房）/ loot（拾取房）/ ambush（伏击判定）；
#   完整格子迷宫留后续迭代（tech/02 §6 maze 注记）。
# - 渐进式执行：壳逐拍推进（peek → resolve），掷骰/写板全部在 core 完成（godot-dev §2 铁律）；
#   检定 = d20 + 玩家修正 vs DC（11 文档 §2/§3，check_mod 由引导层经 Callable 注入，与 story_graph 同源）；
#   效果走 Conditions 效果 DSL 同一通道（tech/02 §4.6：写板带溯源、进事件流，07 §6）。
# - 随机只走注入的种子化 Rng（tech/01 §5.2 确定性）。
class_name MazeRunner
extends RefCounted

## 节拍类型（tech/02 §6 maze.beats）。
const BEAT_CHECK := "check"
const BEAT_LOOT := "loot"
const BEAT_AMBUSH := "ambush"

var board: Board
var stream: EventStream
var rng: Rng
var pack_id := ""
var encounter_id := ""
var node_id := ""

var _beats: Array = []
var _idx := 0
var _mod_fn := Callable() # (skill: String) -> int；与 StoryGraph.check_mod 同一公式（11 §2）

func _init(p_board: Board, p_stream: EventStream, p_rng: Rng, p_pack_id: String) -> void:
	board = p_board
	stream = p_stream
	rng = p_rng
	pack_id = p_pack_id

## 装载探索序列。beats = encounters.json 条目 maze.beats（tech/02 §6）。
## 节拍进度随状态板持久化（簿记键 <pack>.maze.<enc>.idx，07 §2 计数型簿记）：
## 中途 ☰ 离场后继续 = 从已完成的下一拍恢复——已写板的节拍效果不重打（07 §4.2 遭遇外存档时机）。
func begin(p_encounter_id: String, beats: Array, p_mod_fn: Callable, p_node_id: String = "") -> void:
	encounter_id = p_encounter_id
	node_id = p_node_id if p_node_id != "" else p_encounter_id
	_beats = beats.duplicate(true)
	_idx = clampi(int(board.read(_progress_key(), 0)), 0, _beats.size())
	_mod_fn = p_mod_fn
	if _idx == 0:
		stream.emit(EventTypes.LOG, {"msg": "探索开始（%s，%d 拍）" % [encounter_id, _beats.size()]},
			&"core", node_id)

func _progress_key() -> String:
	return "%s.maze.%s.idx" % [pack_id, encounter_id]

func is_done() -> bool:
	return _idx >= _beats.size()

func beat_count() -> int:
	return _beats.size()

func beat_index() -> int:
	return _idx

## 当前节拍（壳呈现用，只读）；已完成返回空字典。
func peek() -> Dictionary:
	if is_done():
		return {}
	return _beats[_idx]

## 执行当前节拍：检定/伏击掷 d20+修正 vs DC 并产 check.roll（kind=maze_check/maze_ambush），
## 按成败写板节拍效果；拾取经 give_item 写板（07 §1 溯源）。返回本拍结果摘要。
## 解谜房（tech/02 §6 maze.beats retry_on_fail）：检定/伏击拍失败时若节拍声明 retry_on_fail，
## 则**不推进节拍、不结算失败效果**，返回 {retry:true, hint}——失败给提示原地重试，不进死路。
func resolve() -> Dictionary:
	if is_done():
		return {}
	var beat: Dictionary = _beats[_idx]
	var btype := str(beat.get("type", BEAT_CHECK))
	var prov := {"event_id": stream.tail(), "node_id": node_id, "pack_id": pack_id}
	var out := {"type": btype, "text": str(beat.get("text", "")), "success": true}
	if [BEAT_CHECK, BEAT_AMBUSH].has(btype):
		var skill := str(beat.get("skill", "perception"))
		var dc := LightV1.dc_for(str(beat.get("difficulty", "medium")))
		var mod := int(_mod_fn.call(skill)) if _mod_fn.is_valid() else 0
		var res := LightV1.check(rng, int(mod), dc)
		var success := bool(res["success"])
		out["success"] = success
		stream.emit(EventTypes.CHECK_ROLL, {"roller": "pc",
			"kind": "maze_ambush" if btype == BEAT_AMBUSH else "maze_check",
			"skill": skill, "rolls": res["rolls"], "keep": res["keep"], "mod": mod,
			"total": res["total"], "dc": dc, "success": success,
			"key": false, # 迷宫节拍默认普通演出（09 §6；内容包可另行标记）
			"extreme": bool(res["nat20"]) or bool(res["nat1"]),
			"source": &"core"}, &"core", node_id)
		if btype == BEAT_AMBUSH and str(beat.get("enemy", "")) != "":
			stream.emit(EventTypes.LOG, {"msg": "伏击！（%s）" % str(beat["enemy"])},
				&"core", node_id)
		if not success and bool(beat.get("retry_on_fail", false)):
			out["retry"] = true
			out["hint"] = str(beat.get("hint", "")) # 提示文案随结果回壳（tech/02 §6 hint）
			return out # 解谜房：失败不推进、不结算失败效果（进度簿记不动，重来不重复效果）
		var fx: Array = beat.get("success_effects", []) if success \
			else beat.get("failure_effects", [])
		_idx += 1
		board.write(_progress_key(), _idx, prov) # 节拍进度簿记（中途离场续打不重效果，07 §4.2）
		_apply(fx, prov)
	elif btype == BEAT_LOOT:
		var item := str(beat.get("item", ""))
		var n := int(beat.get("n", 1))
		_idx += 1
		board.write(_progress_key(), _idx, prov)
		board.give_item(item, n, prov)
		out["item"] = item
		out["n"] = n
		stream.emit(EventTypes.LOG, {"msg": "拾取：%s ×%d" % [item, n]}, &"core", node_id)
	if is_done():
		stream.emit(EventTypes.LOG, {"msg": "探索完成（%s）" % encounter_id}, &"core", node_id)
	return out

## 节拍效果 = 效果 DSL 同一通道（tech/02 §4.6；纳入 packlint V4/V5/V11/V12 闭环）。
func _apply(effects: Array, prov: Dictionary) -> void:
	if effects.is_empty():
		return
	Conditions.new(board).apply_effects(effects, {
		"pack_id": pack_id, "node_id": node_id, "event_id": prov["event_id"], "source": "core"})
