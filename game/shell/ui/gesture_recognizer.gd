# 统一手势识别器（docs/framework/12-手势与交互规范.md §1 判定参数为框架恒定值；§3 冲突消解）
# - 纯逻辑（RefCounted）：输入为 (触点 index, 位置, 时间 ms)，输出为信号——无引擎/场景树依赖，
#   可无头单测；GestureLayer 负责把 InputEvent 翻译成这里的三元组；
# - 判定参数恒定（12 §1）：tap <300ms 且位移 <10pt；长按 ≥400ms 且位移 <10pt；
#   拖动位移 >10pt；横滑 水平 >60pt 且垂直 <30pt（下滑同阈值，04 §④.6）；
#   双指点击 持续 <300ms 且各点位移 <10pt 且间距变化 <15pt；捏合 间距变化 >20%；
# - 冲突消解（12 §3）：起点定语义由壳层命中测试负责；本器保证 ③ 双指点击 vs 捏合
#   以间距变化与时长区分、先后落点间隔 >1 帧（容差 TWO_FINGER_WINDOW_MS）不判双指；
#   ⑤ 打断（cancel_all）按抬手于空位处理 = 取消，不产生半状态指令。
class_name GestureRecognizer
extends RefCounted

signal tapped(pos: Vector2)
signal long_pressed(pos: Vector2)
signal drag_started(info: Dictionary)          # 越过拖动阈值：{index, start, pos}
signal drag_updated(info: Dictionary)          # 拖动中每帧：{index, start, pos, points, targets}
signal dragged(info: Dictionary)               # 抬手：{index, start, end, delta, points, targets}
signal path_cast(info: Dictionary)             # 拖动经过 ≥2 个语义目标（12 §1 path；targets=途经目标 id）
signal two_finger_tapped(pos: Vector2)         # 中点
signal pinched(ratio: float, center: Vector2)  # 越过阈值后持续播报（ratio = 当前间距 / 起始间距）
signal pinch_ended(ratio: float, center: Vector2)
signal h_swiped(dir: int, pos: Vector2)        # dir: +1 右 / -1 左
signal v_swiped(dir: int, pos: Vector2)        # dir: +1 下 / -1 上（04 §④.6 下滑回看 / 上滑展开）

# ---- 判定参数（12 §1 框架恒定值，禁止逐场景覆盖）----
const TAP_MAX_MS := 300
const TAP_MOVE_PT := 10.0
const LONG_PRESS_MS := 400
const DRAG_MIN_PT := 10.0
const SWIPE_H_PT := 60.0
const SWIPE_V_PT := 30.0
const PINCH_RATIO := 0.2
const PINCH_DRIFT_PT := 15.0
const TWO_FINGER_WINDOW_MS := 50 # 12 §3.3「同帧按下」容差（>1 帧不判双指）
const PATH_MIN_TARGETS := 2

## 语义目标探针（12 §1 path 判定 + §6 最近目标吸附）：func(pos: Vector2) -> String（""=空位）。
var target_probe: Callable = Callable()

var _touches: Dictionary = {} # index -> {start, pos, t0, dragging, long_fired, drag_announced, targets, points, paired}
var _tf := {}                 # 双指会话：{t0, d0, pinching, indices}

func _now_state(index: int) -> Dictionary:
	return _touches.get(index, {})

# ---------------------------------------------------------------- 输入（时间由调用方注入，测试可确定性驱动）

func press(index: int, pos: Vector2, now_ms: int) -> void:
	_touches[index] = {"start": pos, "pos": pos, "t0": now_ms, "dragging": false,
		"long_fired": false, "drag_announced": false, "targets": [], "points": [pos]}
	var active := _touches.keys()
	if active.size() == 2:
		var a: int = active[0]
		var b: int = active[1]
		var ta: Dictionary = _touches[a]
		var tb: Dictionary = _touches[b]
		# 12 §3.3：两根手指先后落点间隔 >1 帧（容差 50ms）即不判双指，先落指的单指流程照常
		if absi(int(ta["t0"]) - int(tb["t0"])) <= TWO_FINGER_WINDOW_MS:
			ta["paired"] = true
			tb["paired"] = true
			_tf = {"t0": maxi(int(ta["t0"]), int(tb["t0"])),
				"d0": (ta["pos"] as Vector2).distance_to(tb["pos"]),
				"pinching": false, "indices": [a, b]}

func move(index: int, pos: Vector2, now_ms: int) -> void:
	if not _touches.has(index):
		return
	var t: Dictionary = _touches[index]
	t["pos"] = pos
	if not bool(t["dragging"]) and (pos - (t["start"] as Vector2)).length() > DRAG_MIN_PT:
		t["dragging"] = true # 位移 >10pt 进入拖动（12 §1）
	if bool(t["dragging"]):
		(t["points"] as Array).append(pos)
		if target_probe.is_valid():
			var hit := str(target_probe.call(pos))
			if hit != "" and not (t["targets"] as Array).has(hit):
				(t["targets"] as Array).append(hit)
		if not bool(t["drag_announced"]):
			t["drag_announced"] = true
			drag_started.emit({"index": index, "start": t["start"], "pos": pos})
		drag_updated.emit({"index": index, "start": t["start"], "pos": pos,
			"points": (t["points"] as Array).duplicate(), "targets": (t["targets"] as Array).duplicate()})
	_update_pinch(now_ms)

func release(index: int, pos: Vector2, now_ms: int) -> void:
	if not _touches.has(index):
		return
	var t: Dictionary = _touches[index]
	_touches.erase(index)
	var held := now_ms - int(t["t0"])
	var dist := (pos - (t["start"] as Vector2)).length()
	if _tf.has("indices") and (_tf["indices"] as Array).has(index):
		_release_paired(index, t, pos, held, dist)
		if _touches.is_empty():
			_tf = {}
		return
	if bool(t["long_fired"]):
		return # 长按已触发，抬手不再产 tap/drag（查看语义已消费）
	if not bool(t["dragging"]):
		if held < TAP_MAX_MS and dist < TAP_MOVE_PT:
			tapped.emit(pos)
		return
	# 拖动抬手分流（12 §1/§3）：横/竖滑 > 轨迹 > 平拖
	var d: Vector2 = pos - (t["start"] as Vector2)
	var info := {"index": index, "start": t["start"], "end": pos, "delta": d,
		"points": (t["points"] as Array).duplicate(), "targets": (t["targets"] as Array).duplicate()}
	if absf(d.x) > SWIPE_H_PT and absf(d.y) < SWIPE_V_PT:
		h_swiped.emit(1 if d.x > 0.0 else -1, pos)
	elif absf(d.y) > SWIPE_H_PT and absf(d.x) < SWIPE_V_PT:
		v_swiped.emit(1 if d.y > 0.0 else -1, pos)
	elif (t["targets"] as Array).size() >= PATH_MIN_TARGETS:
		path_cast.emit(info) # 经过 ≥2 个语义目标点 = 施法/瞄准（12 §1 path）
	else:
		dragged.emit(info)

## 长按轮询（按住 ≥400ms 且位移 <10pt 即触发，不等抬手；12 §1）。
func poll(now_ms: int) -> void:
	for index: Variant in _touches.keys():
		var t: Dictionary = _touches[index]
		if bool(t["long_fired"]) or bool(t["dragging"]):
			continue
		if now_ms - int(t["t0"]) >= LONG_PRESS_MS \
				and ((t["pos"] as Vector2) - (t["start"] as Vector2)).length() < TAP_MOVE_PT:
			t["long_fired"] = true
			long_pressed.emit(t["pos"])

## 打断（来电/切后台，12 §3.5）：按抬手于空位处理 = 取消，不产生半状态指令。
func cancel_all() -> void:
	_touches.clear()
	if not _tf.is_empty() and bool(_tf.get("pinching", false)):
		pinch_ended.emit(1.0, Vector2.ZERO)
	_tf = {}

func is_idle() -> bool:
	return _touches.is_empty()

# ---------------------------------------------------------------- 双指（12 §3.3：间距变化与时长区分 双指点击 vs 捏合）

func _update_pinch(_now_ms: int) -> void:
	if _tf.is_empty() or not _tf.has("indices"):
		return
	var idx: Array = _tf["indices"]
	if idx.size() != 2 or not _touches.has(idx[0]) or not _touches.has(idx[1]):
		return
	var pa: Vector2 = _touches[idx[0]]["pos"]
	var pb: Vector2 = _touches[idx[1]]["pos"]
	var d0 := maxf(float(_tf["d0"]), 1.0)
	var ratio := pa.distance_to(pb) / d0
	if not bool(_tf["pinching"]) and absf(ratio - 1.0) > PINCH_RATIO:
		_tf["pinching"] = true # 间距变化 >20% 进入缩放判定（12 §1）
	if bool(_tf["pinching"]):
		pinched.emit(ratio, (pa + pb) * 0.5)

func _release_paired(index: int, t: Dictionary, pos: Vector2, held: int, dist: float) -> void:
	var idx: Array = _tf.get("indices", [])
	var other_id := -1
	if idx.size() == 2:
		other_id = int(idx[1]) if int(idx[0]) == index else int(idx[0]) # 另一指
	# 另一指信息（若仍在触）用于时长/位移判定
	var other: Dictionary = _touches.get(other_id, {})
	if bool(_tf.get("pinching", false)):
		var d0 := maxf(float(_tf["d0"]), 1.0)
		var ratio := 1.0
		var center := pos
		if not other.is_empty():
			ratio = (other["pos"] as Vector2).distance_to(pos) / d0
			center = ((other["pos"] as Vector2) + pos) * 0.5
		pinch_ended.emit(ratio, center)
		_tf = {}
		return
	# 双指点击：持续 <300ms 且各点位移 <10pt 且间距变化 <15pt（12 §1/§3.3）
	if other.is_empty():
		return
	var other_dist: float = ((other["pos"] as Vector2) - (other["start"] as Vector2)).length()
	var drift: float = absf((other["pos"] as Vector2).distance_to(pos) - float(_tf["d0"]))
	if held < TAP_MAX_MS and dist < TAP_MOVE_PT and other_dist < TAP_MOVE_PT \
			and drift < PINCH_DRIFT_PT:
		two_finger_tapped.emit(((other["pos"] as Vector2) + pos) * 0.5)
	# 双指语义已消费：另一指抬手不再产单指 tap（防重复触发）
	other["long_fired"] = true
	_tf = {}
