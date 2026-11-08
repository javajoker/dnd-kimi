# 故事图运行时（docs/tech/02-内容包格式规范.md §3 节点、§4 五类边 DSL、§9 结局分型）
# - 五类边统一按"条件 + 目标 + 效果"求值（§4 导言：运行时只有条件求值），条件/效果复用 Conditions；
#   choice 显式可选 / check 成功失败双路（§4.2）/ item 持有显形否则 fallback（§4.3）/
#   doom_clock 到格自动触发 + once（§4.4）/ reputation requires 隐形门槛（§4.5）；
# - 触发器扫描：任何写板（节点 on_enter/on_complete、边效果）后全量复查 doom_clock 边（35 节点量级）；
# - 结局选择：按 endings.json 顺序求值条件，首个命中者胜，default: true 兜底（§9、战役书 §9 E4）；
# - 一切写板经 Board（07 §1 溯源），节点进入/触发/结局产事件进事件流（07 §6）。
class_name StoryGraph
extends RefCounted

var board: Board
var rng: Rng
var pack: Dictionary
var pack_id: String
var cond: Conditions

var current_id: String = ""
var visit_log: Array[String] = []
var _completed: Dictionary = {} # node_id -> true（on_complete 只结算一次，§3 "离开前结算"）
var _fired_triggers: Dictionary = {} # "node_id/edge_idx" -> true（doom_clock once，§4.4）
var _clock_edges: Array = [] # 预索引全图 doom_clock 边：{node_id, idx, edge}

func _init(p_board: Board, p_rng: Rng, p_pack: Dictionary) -> void:
	board = p_board
	rng = p_rng
	pack = p_pack
	pack_id = str(pack.get("pack_id", ""))
	cond = Conditions.new(board)
	_index_clock_edges()

# ---------------------------------------------------------------- 进入与遍历

## 从入口节点开图（缺省取节点表首个节点，campaign01 = N0-1）。
func start(entry_id: String = "") -> void:
	var eid := entry_id
	if eid.is_empty():
		eid = (pack["node_order"] as Array)[0]
	_enter(eid)

func current() -> Dictionary:
	return (pack["nodes"] as Dictionary).get(current_id, {})

func is_at_ending() -> bool:
	return str(current().get("type", "")) == "ending"

## 当前节点玩家可走的边（check 边整体返回，成败由 resolve_check 结算）。
## item 边：持有 → 主路；未持有且有 fallback → 以 {to: fallback} 变体出现；无 fallback 则不显形（§4.3）。
func available_edges() -> Array:
	var out: Array = []
	var ctx := {"pack_id": pack_id}
	for edge: Variant in current().get("edges", []):
		var e: Dictionary = edge
		match str(e.get("type", "")):
			"choice", "reputation":
				if _requires_ok(e, ctx):
					out.append(e)
			"item":
				if board.has_item(str(e.get("item", ""))) and _requires_ok(e, ctx):
					out.append(e)
				elif e.has("fallback"):
					var fb := e.duplicate(true)
					fb["to"] = e["fallback"]
					fb["via_fallback"] = true
					out.append(fb)
			"check":
				out.append(e)
			"doom_clock":
				pass # 自动触发，非玩家选项（§4.4）
	return out

## 走一条非检定边：先结算离开节点的 on_complete，再边效果，再触发器扫描，最后进入目标。
func take_edge(edge: Dictionary) -> void:
	_leave_current()
	_apply(edge.get("effects", []), current_id)
	_scan_triggers()
	_enter(str(edge.get("to", "")))

## 检定边成败双路结算（§4.2：差异体现在 success/failure 目标与效果）。
func resolve_check(edge: Dictionary, success: bool) -> void:
	_leave_current()
	if success:
		_apply(edge.get("success_effects", []), current_id)
		_scan_triggers()
		_enter(str(edge.get("success", "")))
	else:
		_apply(edge.get("failure_effects", []), current_id)
		_scan_triggers()
		_enter(str(edge.get("failure", "")))

# ---------------------------------------------------------------- 结局（§9）

## 按 endings.json 顺序求值，首个条件命中者胜；无命中取 default: true 兜底（E4，战役书 §9）。
func pick_ending() -> String:
	var ctx := {"pack_id": pack_id}
	var fallback := ""
	for ending: Variant in pack.get("endings", []):
		var e: Dictionary = ending
		if bool(e.get("default", false)):
			fallback = str(e.get("id", ""))
			continue
		if cond.evaluate(e.get("conditions", {}), ctx):
			return str(e.get("id", ""))
	return fallback

# ---------------------------------------------------------------- 内部

func _enter(node_id: String) -> void:
	if not (pack["nodes"] as Dictionary).has(node_id):
		push_error("StoryGraph: 进入不存在的节点 '%s'" % node_id)
		return
	current_id = node_id
	visit_log.append(node_id)
	board.stream.emit(EventTypes.NODE_ENTER,
		{"node_id": node_id, "type": str(current().get("type", ""))}, &"graph", node_id)
	_apply(current().get("on_enter", []), node_id)
	_scan_triggers()

## §3：on_complete 在"节点全部边结算完成、离开前"结算，每节点只一次。
func _leave_current() -> void:
	if current_id.is_empty() or _completed.has(current_id):
		return
	_completed[current_id] = true
	_apply(current().get("on_complete", []), current_id)

func _apply(effects: Array, node_id: String) -> void:
	if effects.is_empty():
		return
	cond.apply_effects(effects, {
		"pack_id": pack_id,
		"node_id": node_id,
		"event_id": board.stream.tail(),
		"source": "graph",
	})

func _requires_ok(edge: Dictionary, ctx: Dictionary) -> bool:
	if not edge.has("requires"):
		return true
	return cond.evaluate(edge["requires"], ctx)

func _index_clock_edges() -> void:
	_clock_edges.clear()
	for nid: String in pack.get("node_order", []):
		var edges: Array = (pack["nodes"][nid] as Dictionary).get("edges", [])
		for i: int in edges.size():
			if str((edges[i] as Dictionary).get("type", "")) == "doom_clock":
				_clock_edges.append({"node_id": nid, "idx": i, "edge": edges[i]})

## §4.4：写板后全量复查 doom_clock 边；once 防重复触发（35 节点量级，全量扫描即可）。
func _scan_triggers() -> void:
	for rec: Dictionary in _clock_edges:
		var key := "%s/%d" % [str(rec["node_id"]), int(rec["idx"])]
		var edge: Dictionary = rec["edge"]
		if bool(edge.get("once", true)) and _fired_triggers.has(key):
			continue
		if board.get_doom_clock() < int(edge.get("at", 0)):
			continue
		_fired_triggers[key] = true
		board.stream.emit(EventTypes.STORY_TRIGGER,
			{"edge": edge.duplicate(true), "at": int(edge.get("at", 0))}, &"graph", str(rec["node_id"]))
		_apply(edge.get("effects", []), str(rec["node_id"]))
		var to := str(edge.get("to", ""))
		if not to.is_empty() and to != current_id:
			_enter(to)
