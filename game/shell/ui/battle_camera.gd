# 战斗跟随镜头与关键推拉（docs/framework/14-表现层与平台化清单.md #8；
# 04 §④.4 智能镜头：默认跟随当前行动单位、回合焦点切换平滑推移、捏合随时拉远；
# 12 §2.1/§2.2 捏合缩放兼容：用户手动缩放时镜头让位，回合末回弹跟随）
# 纯呈现壳层组件：
# - 唯一输入 = 事件流（on_event）+ 壳收口的锚点/可视区查询；不改 core、不写 Board、不回注事件流；
# - 双壳同一组件同一参数源（godot-dev §7：禁止复制两份横屏/竖屏逻辑）；
#   布局差异由壳收口（target / view_of / anchor_of / axis_lock_x）；
# - 与 Juice 层同事件源（battle.attack crit / combat.start 携 boss）——推拉只做缩放/平移，
#   不重复震屏（震屏唯一来源仍是 JuiceLayer，14 #4）；
# - 播出时机：on_event 只登记，隔一帧锚点落定后播出（单位节点刚重建，容器排序需过帧才稳定，
#   与 JuiceLayer 同一登记-播出分离手法）。
class_name BattleCamera
extends Node

# ---- 参数唯一源（14 清单 #8 冻结）----
const FOCUS_TIME := 0.35  # 回合焦点切换平滑推移时长
const PUNCH_SCALE := 1.12 # 关键推拉推近倍率（暴击/Boss 登场）
const PUNCH_IN := 0.18    # 推近时长
const PUNCH_OUT := 0.22   # 拉回时长（推近+拉回 0.40s ≤0.5s，14 #8）
const PAN_LIMIT := 0.30   # 单轴平移上限 = 可视区对应边长比例（防拽空，竖屏 lane 防出画）
const RESUME_TIME := 0.30 # 手动缩放回合末回弹跟随时长

var target: Control = null # 镜头施加节点（竖屏 lane 内容层 / 横屏战术格）
var view_of := Callable()   # () -> Rect2 可视区全局矩形（对焦居中参照，壳收口）
var anchor_of := Callable() # (uid) -> Vector2 单位全局锚点（壳收口，JuiceLayer 同款查询）
var on_resume := Callable() # 回弹时壳同步自身缩放簿记（横屏 _zoom/_zoom0、竖屏主视野弹回）
var axis_lock_x := false    # 竖屏 lane 滚动对焦：只纵轴（04 §④.4 竖向战场）
var follow_zoom := 1.0      # 跟随档缩放（回弹归位目标）
var manual := false         # 用户手动缩放会话中 → 镜头让位（捏合优先，12 §2.1）
var focus_uid := ""         # 当前对焦单位
# 无头断言探针
var stats := {"focus": 0, "punch": 0, "yield": 0, "resume": 0}
var last_focus: Dictionary = {} # {uid, pan}
var last_punch: Dictionary = {} # {scale, in, out}

var _pending: Array[Dictionary] = []
var _base_pos := Vector2.ZERO
var _base_scale := Vector2.ONE
var _focus_tween: Tween = null # 焦点推移互斥：新焦点压掉旧推移（就近原则，不叠写位移）
var _punch_tween: Tween = null

## 壳接线：目标节点 + 可视区/锚点查询 + 是否纵轴锁定（竖屏 true / 横屏 false）。
func setup(p_target: Control, p_view: Callable, p_anchor: Callable, lock_x: bool) -> void:
	target = p_target
	view_of = p_view
	anchor_of = p_anchor
	axis_lock_x = lock_x
	if target != null:
		_base_pos = target.position
		_base_scale = target.scale

## 新遭遇归零（壳 bind 时调用）：镜头归位、会话与计数清零。
func reset() -> void:
	_pending.clear()
	focus_uid = ""
	manual = false
	last_focus = {}
	last_punch = {}
	for k: String in stats:
		stats[k] = 0
	if target != null and is_instance_valid(target):
		target.position = _base_pos
		target.scale = _base_scale

## 事件流入口（唯一输入）：turn.start.actor → 跟随对焦；battle.attack 暴击 → 推近拉回；
## combat.start 携 boss 单位 → Boss 登场对焦+推近（04 §④.7 演出分级；14 #8）。
func on_event(ev: Dictionary) -> void:
	var t := StringName(ev["type"])
	var p: Dictionary = ev.get("payload", {})
	match t:
		EventTypes.TURN_START:
			if manual:
				resume() # 回合末回弹跟随（14 #8：手动缩放让位至回合边界）
			var actor := str(p.get("actor", ""))
			if actor != "":
				_enqueue({"kind": &"focus", "uid": actor})
		EventTypes.BATTLE_ATTACK:
			if bool(p.get("hit", false)) and bool(p.get("crit", false)):
				_enqueue({"kind": &"punch", "uid": str(p.get("target", ""))})
		EventTypes.COMBAT_START:
			var units: Dictionary = p.get("units", {})
			for id: String in units:
				var u: Dictionary = units[id]
				if StringName(u.get("side", &"")) == &"enemy" and bool(u.get("boss", false)):
					_enqueue({"kind": &"focus", "uid": id})
					_enqueue({"kind": &"punch", "uid": id}) # Boss 登场推近再拉回
					break

## 手动缩放会话（壳捏合处理器调用）：进行中镜头让位——对焦/推拉登记 yield 不动镜头。
func begin_manual() -> void:
	manual = true

## 手动缩放会话结束（竖屏松手弹回即回弹，04 §④.4；横屏松手持续生效，让位至回合末，12 §2.1）。
func end_manual() -> void:
	manual = false

## 回合末回弹跟随：缩放归位 + 壳簿记同步；随后的 turn.start.actor 对焦恢复跟随。
func resume() -> void:
	if not manual:
		return
	manual = false
	stats["resume"] += 1
	if on_resume.is_valid():
		on_resume.call()
	if target != null and is_instance_valid(target) \
			and target.scale != Vector2.ONE * follow_zoom:
		var tw := target.create_tween()
		tw.tween_property(target, "scale", Vector2.ONE * follow_zoom, RESUME_TIME) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _enqueue(job: Dictionary) -> void:
	job["wait"] = 1 # 隔帧锚点（JuiceLayer 同一手法：壳事件回调里单位节点刚重建）
	_pending.append(job)

func _process(_delta: float) -> void:
	var queued := _pending.size()
	for i: int in queued: # 只处理本帧开头已在队列的 job
		var job: Dictionary = _pending.pop_front()
		if int(job.get("wait", 0)) > 0:
			job["wait"] = int(job["wait"]) - 1
			_pending.append(job)
			continue
		match StringName(job["kind"]):
			&"focus":
				_do_focus(str(job["uid"]))
			&"punch":
				_do_punch(str(job["uid"]))

## 跟随对焦：把单位锚点平滑推向可视区中心（竖屏只纵轴 lane 滚动；横屏战场平移）。
func _do_focus(uid: String) -> void:
	focus_uid = uid # 焦点簿记先行：让位期间也记住"该看谁"，回弹后据此恢复
	if manual:
		stats["yield"] += 1 # 手动缩放中：镜头让位（12 §2.1 捏合优先）
		return
	if target == null or not is_instance_valid(target):
		return
	stats["focus"] += 1
	var view := _view()
	var delta := view.get_center() - _anchor(uid)
	if axis_lock_x:
		delta.x = 0.0
	delta.x = clampf(delta.x, -view.size.x * PAN_LIMIT, view.size.x * PAN_LIMIT)
	delta.y = clampf(delta.y, -view.size.y * PAN_LIMIT, view.size.y * PAN_LIMIT)
	last_focus = {"uid": uid, "pan": delta}
	if delta.length() < 0.5:
		return
	if _focus_tween != null and _focus_tween.is_running():
		_focus_tween.kill()
	_focus_tween = target.create_tween()
	_focus_tween.tween_property(target, "position", target.position + delta, FOCUS_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

## 关键推拉：以事件单位为轴心推近再拉回（总量 ≤0.5s；只缩放，不震屏——14 #4 震屏唯一源 JuiceLayer）。
func _do_punch(uid: String) -> void:
	if manual:
		stats["yield"] += 1
		return
	if target == null or not is_instance_valid(target):
		return
	stats["punch"] += 1
	last_punch = {"scale": PUNCH_SCALE, "in": PUNCH_IN, "out": PUNCH_OUT}
	target.pivot_offset = target.get_global_transform().affine_inverse() * _anchor(uid)
	if _punch_tween != null and _punch_tween.is_running():
		_punch_tween.kill()
		target.scale = Vector2.ONE * follow_zoom # 叠推先归位再推（不残留中间倍率）
	var s0 := target.scale
	_punch_tween = target.create_tween()
	_punch_tween.tween_property(target, "scale", s0 * PUNCH_SCALE, PUNCH_IN) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_punch_tween.tween_property(target, "scale", s0, PUNCH_OUT) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)

func _anchor(uid: String) -> Vector2:
	if anchor_of.is_valid():
		return anchor_of.call(uid)
	return _view().get_center()

func _view() -> Rect2:
	if view_of.is_valid():
		return view_of.call()
	if target != null and is_instance_valid(target):
		return target.get_global_rect()
	return Rect2()
