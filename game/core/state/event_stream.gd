# 事件流（docs/tech/01-技术方案讨论稿.md §5；docs/framework/07-世界状态机规范.md §6）
# 追加式、不可变：事件一旦写入不得修改；渲染、历史卷轴、回放消费同一条流。
# 事件结构（tech/01 §5.1 + godot-dev §4）：{id, session, type, payload, source, node}
class_name EventStream
extends RefCounted

var _events: Array[Dictionary] = []
var _subscribers: Array[Callable] = []
var _next_id: int = 1

## 追加一条事件并同步通知订阅者。返回写入的事件（含递增 id）。
func emit(type: StringName, payload: Dictionary = {}, source: StringName = &"core", node: String = "", session: String = "") -> Dictionary:
	var ev := {
		"id": _next_id,
		"session": session,
		"type": type,
		"payload": payload.duplicate(true),
		"source": source,
		"node": node,
	}
	_next_id += 1
	_events.append(ev)
	for fn: Callable in _subscribers:
		fn.call(ev)
	return ev

## 订阅事件流（渲染壳唯一消费通道，tech/01 §5.2 进程内发布订阅）。
func subscribe(fn: Callable) -> void:
	if not _subscribers.has(fn):
		_subscribers.append(fn)

func unsubscribe(fn: Callable) -> void:
	_subscribers.erase(fn)

## 按类型查询（历史卷轴 / 调试视图）。
func query_by_type(type: StringName) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for ev: Dictionary in _events:
		if ev["type"] == type:
			out.append(ev)
	return out

## 事件流尾部序号：存档锚点（07 §4.1 event_tail）。
func tail() -> int:
	return _next_id - 1

func size() -> int:
	return _events.size()

## 取 id 大于 event_id 的事件段（自存档锚点回放/追溯用）。
func since(event_id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for ev: Dictionary in _events:
		if int(ev["id"]) > event_id:
			out.append(ev)
	return out

func all() -> Array[Dictionary]:
	return _events.duplicate()
