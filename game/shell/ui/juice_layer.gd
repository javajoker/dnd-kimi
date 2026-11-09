# 打击感三件套 + 屏幕震动分级呈现层（docs/framework/14-表现层与平台化清单.md #3/#4）
# 铁律落位：
# - 纯呈现消费：唯一输入是事件流事件（on_event），不改 core、不写 Board、不回注事件流（godot-dev §2）；
# - 双壳同一组件同一配置源：参数全部取自 JuiceConfig（godot-dev §7：禁止复制两份逻辑）；
#   壳只提供单位锚点/节点查询（anchor_of / unit_node_of），布局差异由壳收口；
# - 演出层视觉随机走种子化 Rng 实例（与逻辑骰无关，同 _tray_roll 风格）；
# - 震动可关：读 user://settings.cfg 的 ui.screen_shake（12 §5：UI 偏好不写状态板，与兜底条同机制）。
# 播出时机：on_event 只登记，隔一帧 _process 落定锚点后播出——壳的事件回调里单位节点刚重建，
# 容器排序需过帧才稳定；登记-播出分离 + 隔帧锚点求值保证飘字永远锚到单位实际落位。
class_name JuiceLayer
extends Control

## 单位 id → 全局坐标锚点（单位视觉中心；壳实现）。
var anchor_of: Callable = Callable()
## 单位 id → 当前视觉节点（Control；壳实现；找不到返回 null）。
var unit_node_of: Callable = Callable()
## 屏幕震动施加节点（壳根；为 null 时震动不播但计数照常，便于无头断言）。
var shake_target: Control = null
## 震动开关设置路径（测试可注入隔离文件）。
var settings_path := UiSettings.PATH
## 震动开关强制覆盖：-1=读设置；0=强制关；1=强制开（测试用）。
var shake_override := -1

# 计数器（无头断言探针；只增不减，reset 清零）
var stats := {"numbers": 0, "crits": 0, "misses": 0, "heals": 0, "flashes": 0,
	"knockbacks": 0, "dissolves": 0, "shake_small": 0, "shake_big": 0, "shake_blocked": 0}
var last_numbers: Array[Dictionary] = [] # 最近飘字规格（封顶 16 条）
var last_shake: Dictionary = {}          # 最近一次震动 {level, amp, dur}
var shake_max_dev := 0.0                 # 最近一次震动的最大偏移（px）
var last_dissolve_fragments := 0

var _pending: Array[Dictionary] = []     # 待播规格（下一帧锚点落定后播出）
var _rng := Rng.new(20261109)            # 演出层视觉随机（与逻辑骰无关）
var _dissolved: Dictionary = {}          # unit_id -> true（消散完成，壳重建时保持隐去）
var _numbers: Array[Label] = []
var _fragments: Array[ColorRect] = []
var _shake_left := 0.0
var _shake_amp := 0.0
var _shake_base := Vector2.ZERO
var _dissolve_marks: Dictionary = {} # unit_id -> 剩余秒（消散完成倒计时，节点无关）

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE # 呈现覆盖层不吞输入（12 §1 按钮等价路径不受影响）

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

## 新遭遇/换局清零（消散名单与计数随旧单位一并作废）。
func reset() -> void:
	_pending.clear()
	_dissolved.clear()
	_dissolve_marks.clear()
	last_numbers.clear()
	last_shake = {}
	shake_max_dev = 0.0
	last_dissolve_fragments = 0
	for k: String in stats:
		stats[k] = 0
	_shake_left = 0.0
	if shake_target != null and is_instance_valid(shake_target):
		shake_target.position = _shake_base

## 壳事件回调入口（唯一输入：事件流）。只登记规格，不立即播出。
func on_event(ev: Dictionary) -> void:
	var spec := JuiceConfig.number_spec(ev)
	if not spec.is_empty():
		_pending.append({"kind": &"number", "spec": spec, "wait": 1})
		if StringName(ev["type"]) == EventTypes.BATTLE_ATTACK:
			# 命中反馈只随"命中"发生（闪白+击退；miss 不碰目标）
			_pending.append({"kind": &"hit", "spec": spec, "wait": 1})
	var level := JuiceConfig.shake_level(ev)
	if level != JuiceConfig.SHAKE_NONE:
		_pending.append({"kind": &"shake", "level": level, "wait": 1})
	if StringName(ev["type"]) == EventTypes.BATTLE_DEAD:
		_pending.append({"kind": &"dissolve", "unit": str(ev["payload"].get("unit", "")), "wait": 1})

func _process(delta: float) -> void:
	var queued := _pending.size()
	for i: int in queued: # 只处理本帧开头已在队列的 job；wait>0 的隔帧再播（锚点等容器排序落定）
		var job: Dictionary = _pending.pop_front()
		if int(job.get("wait", 0)) > 0:
			job["wait"] = int(job["wait"]) - 1
			_pending.append(job)
			continue
		match StringName(job["kind"]):
			&"number":
				_spawn_number(job["spec"])
			&"hit":
				_hit_feedback(job["spec"])
			&"shake":
				_shake_start(int(job["level"]))
			&"dissolve":
				_dissolve(str(job["unit"]))
	_tick_shake(delta)
	for unit: String in _dissolve_marks.keys(): # 消散完成倒计时（节点无关，重建安全）
		_dissolve_marks[unit] = float(_dissolve_marks[unit]) - delta
		if float(_dissolve_marks[unit]) <= 0.0:
			_dissolve_marks.erase(unit)
			_dissolved[unit] = true # 淡出完成后壳重建保持隐去（is_dissolved）
			var n: Control = _unit_node(unit)
			if n != null:
				n.visible = false

# ---------------------------------------------------------------- #3-1 伤害数字飘字

func _spawn_number(spec: Dictionary) -> void:
	stats["numbers"] += 1
	match str(spec["kind"]):
		"crit": stats["crits"] += 1
		"miss": stats["misses"] += 1
		"heal": stats["heals"] += 1
	var pos := _anchor(str(spec["unit"]))
	var rec: Dictionary = spec.duplicate()
	rec["pos"] = pos
	last_numbers.append(rec)
	if last_numbers.size() > 16:
		last_numbers.pop_front()
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = ("%s %s" % [str(spec["tag"]), str(spec["text"])]).strip_edges()
	label.add_theme_color_override("font_color", spec["color"])
	label.add_theme_font_size_override("font_size",
		int(round(JuiceConfig.FONT_BASE * float(spec["scale"]))))
	add_child(label)
	label.reset_size()
	label.position = pos - label.size * 0.5
	_numbers.append(label)
	var tw := label.create_tween().set_parallel(true)
	tw.tween_property(label, "position:y", label.position.y - JuiceConfig.FLOAT_DISTANCE,
		JuiceConfig.FLOAT_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, "modulate:a", 0.0, JuiceConfig.FLOAT_DURATION)
	tw.chain().tween_callback(func() -> void:
		_numbers.erase(label)
		label.queue_free())

## 测试探针：场上存活飘字数。
func active_number_count() -> int:
	return _numbers.size()

# ---------------------------------------------------------------- #3-2 命中反馈（闪白一帧 + 击退弹回）

func _hit_feedback(spec: Dictionary) -> void:
	if str(spec["kind"]) == "miss" or str(spec["kind"]) == "heal":
		return
	var node: Control = _unit_node(str(spec["unit"]))
	if node == null:
		return
	stats["flashes"] += 1
	var orig := node.modulate
	node.modulate = JuiceConfig.FLASH_COLOR # 闪白一帧（过曝白）
	var ftw := node.create_tween() # 绑定节点：单位重建时 tween 随之销毁，不残留
	ftw.tween_property(node, "modulate", orig, JuiceConfig.FLASH_TIME)
	# 击退：沿 攻击者→目标 方向几像素弹回；方向不可知时视觉随机给一个
	var dir := Vector2.ZERO
	var from := str(spec.get("attacker", ""))
	if from != "" and from != str(spec["unit"]):
		dir = (_anchor(str(spec["unit"])) - _anchor(from)).normalized()
	if dir == Vector2.ZERO:
		var ang := deg_to_rad(float(_rng.range_int(0, 359)))
		dir = Vector2(cos(ang), sin(ang))
	var home := node.position
	stats["knockbacks"] += 1
	var ktw := node.create_tween()
	ktw.tween_property(node, "position", home + dir * JuiceConfig.KNOCKBACK_PX,
		JuiceConfig.KNOCKBACK_TIME * 0.5)
	ktw.tween_property(node, "position", home, JuiceConfig.KNOCKBACK_TIME * 0.5)

# ---------------------------------------------------------------- #3-3 击杀消散（墨色碎片 + 淡出 0.5s）

func _dissolve(unit: String) -> void:
	if unit == "" or _dissolved.has(unit):
		return
	stats["dissolves"] += 1
	var pos := _anchor(unit)
	last_dissolve_fragments = JuiceConfig.DISSOLVE_FRAGMENTS
	for i: int in JuiceConfig.DISSOLVE_FRAGMENTS:
		var frag := ColorRect.new()
		frag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 墨色碎片提亮 0.35~0.65：纯墨色在深色单位卡底上不可见（留白记录），提亮保色相保可读
		frag.color = JuiceConfig.COLOR_INK.lightened(0.35 + float(_rng.range_int(0, 30)) / 100.0)
		frag.size = Vector2.ONE * JuiceConfig.FRAGMENT_PX
		frag.position = pos
		add_child(frag)
		_fragments.append(frag)
		var ang := deg_to_rad(float(_rng.range_int(0, 359)))
		var dist := float(_rng.range_int(24, 52))
		var tw := frag.create_tween().set_parallel(true)
		tw.tween_property(frag, "position", pos + Vector2(cos(ang), sin(ang)) * dist,
			JuiceConfig.DISSOLVE_DURATION)
		tw.tween_property(frag, "modulate:a", 0.0, JuiceConfig.DISSOLVE_DURATION)
		tw.chain().tween_callback(func() -> void:
			_fragments.erase(frag)
			frag.queue_free())
	var node: Control = _unit_node(unit)
	if node != null:
		var ftw := node.create_tween()
		ftw.tween_property(node, "modulate:a", 0.0, JuiceConfig.DISSOLVE_DURATION)
	# 消散完成标记走 _process 倒计时，不绑节点 tween：淡出期间单位节点被事件刷新重建
	# 会杀掉绑定 tween，若标记绑在 tween 回调上将永远不落（重建的死单位"复活"在原地）
	_dissolve_marks[unit] = JuiceConfig.DISSOLVE_DURATION

## 测试探针：场上存活碎片数。
func active_fragment_count() -> int:
	return _fragments.size()

## 壳重建单位视觉时查询：已消散单位保持隐去（击杀 = 消散，而非瞬间消失）。
func is_dissolved(unit: String) -> bool:
	return _dissolved.has(unit)

# ---------------------------------------------------------------- #4 屏幕震动分级

func _shake_start(level: int) -> void:
	var params := JuiceConfig.shake_params(level)
	if params.is_empty():
		return
	if not _shake_enabled():
		stats["shake_blocked"] += 1
		return
	if level == JuiceConfig.SHAKE_BIG:
		stats["shake_big"] += 1
	else:
		stats["shake_small"] += 1
	last_shake = {"level": level, "amp": float(params["amp"]), "dur": float(params["dur"])}
	shake_max_dev = 0.0
	if shake_target == null or not is_instance_valid(shake_target):
		return
	_shake_base = shake_target.position
	_shake_amp = float(params["amp"])
	_shake_left = float(params["dur"]) # 新震覆盖旧震（就近原则：最近一次事件说了算）

func _tick_shake(delta: float) -> void:
	if _shake_left <= 0.0:
		return
	_shake_left -= delta
	if shake_target == null or not is_instance_valid(shake_target):
		_shake_left = 0.0
		return
	if _shake_left <= 0.0:
		shake_target.position = _shake_base # 震完归位
		_shake_left = 0.0
		return
	var off := Vector2(float(_rng.range_int(-10, 10)), float(_rng.range_int(-10, 10))) \
		* (_shake_amp / 10.0)
	shake_target.position = _shake_base + off
	shake_max_dev = maxf(shake_max_dev, off.length())

func _shake_enabled() -> bool:
	if shake_override >= 0:
		return shake_override == 1
	return UiSettings.load_screen_shake(settings_path)

## 测试探针：震动是否进行中。
func is_shaking() -> bool:
	return _shake_left > 0.0

# ---------------------------------------------------------------- 锚点解析

func _anchor(unit: String) -> Vector2:
	if anchor_of.is_valid():
		var g: Vector2 = anchor_of.call(unit)
		return get_global_transform().affine_inverse() * g
	return size * 0.5

func _unit_node(unit: String) -> Control:
	if unit_node_of.is_valid():
		var n: Variant = unit_node_of.call(unit)
		if n is Control and is_instance_valid(n):
			return n as Control
	return null
