# 统一界面转场器（docs/framework/14-表现层与平台化清单.md #8；04 §2 导航闭环、§④.7 转场不打断节奏、
# §10「各界面转场动画时长规范见 14 清单 #8」——参数冻结在本文件，唯一源）
# 纯呈现壳层组件：
# - 主屏⇄入口⇄功能界面⇄遭遇 切换淡入淡出（0.2~0.3s 档）+ 遭遇进场轻微上移滑入；
# - 不打断交互：幕布 mouse_filter=IGNORE（淡出段旧屏照常可点），连续切换前场即时结算（快速完成，
#   不叠加黑场）；逻辑换屏不受转场门控（current_screen 即时就位，视觉在淡出中场切换）；
# - 不进事件流、不写板、不读规则档位——只是壳层视觉（godot-dev §2）。
class_name UiTransition
extends CanvasLayer

const FADE_OUT := 0.25 # 淡出时长（0.2~0.3s 档，14 #8 冻结）
const FADE_IN := 0.25  # 淡入时长（0.2~0.3s 档）
const SLIDE_PX := 36.0 # 遭遇进场上移滑入幅度（轻微）
const INK := Color(0.05, 0.04, 0.08, 1.0) # 墨色幕布（与关键判定演出层同色系）

var veil: ColorRect
# 无头断言探针：fades=淡入淡出场次，slides=进场滑入场次，fast_forward=连续切换快速完成次数
var stats := {"fades": 0, "slides": 0, "fast_forward": 0}
var last_out := 0.0 # 最近一次淡出实际时长（快速完成后续播会按剩余比例缩短）
var last_in := 0.0  # 最近一次淡入实际时长
var transitioning := false

var _tween: Tween = null
var _pending := Callable()   # 淡出中场回调（真实换屏点）
var _slide_target: Control = null
var _slide_base := 0.0

func _init() -> void:
	layer = 100 # 压一切界面层（关键判定演出层在壳内，壳外层级低于本幕布无碍——演出期不切屏）
	veil = ColorRect.new()
	veil.name = "Veil"
	veil.color = INK
	veil.modulate.a = 0.0
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE # 转场期间可点（14 #8 不打断交互）
	add_child(veil)

## 淡入淡出切换：淡出 → 中场回调（旧屏回收/新屏现身）→ 淡入；
## slide 非空时淡入段同步自 +SLIDE_PX 上移滑入归位（遭遇进场，14 #8）。
func fade_through(on_mid := Callable(), slide: Control = null) -> void:
	if _tween != null and _tween.is_running():
		_tween.kill()
		_flush_mid() # 快速完成前场（连续切换不叠加黑场，交互不被转场队列阻塞）
		_restore_slide()
		stats["fast_forward"] += 1
	stats["fades"] += 1
	transitioning = true
	_pending = on_mid
	_slide_target = slide
	if slide != null:
		stats["slides"] += 1
		_slide_base = slide.position.y
	var a0 := veil.modulate.a
	last_out = FADE_OUT * (1.0 - a0) # 幕布未归零下续播：只补剩余淡出
	last_in = FADE_IN
	_tween = create_tween()
	if last_out > 0.001:
		_tween.tween_property(veil, "modulate:a", 1.0, last_out)
	_tween.tween_callback(_flush_mid)
	if slide != null:
		_tween.tween_callback(_begin_slide)
	_tween.tween_property(veil, "modulate:a", 0.0, FADE_IN)
	if slide != null:
		_tween.parallel().tween_property(slide, "position:y", _slide_base, FADE_IN) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(func() -> void: transitioning = false)

## 遭遇进场：淡入淡出 + 目标上移滑入（14 #8：主屏⇄入口⇄功能界面⇄遭遇 的「进遭遇」一场）。
func encounter_enter(target: Control) -> void:
	fade_through(Callable(), target)

## 截图/证据通道：立即完成一切进行中转场（幕布归零、滑入归位、中场结算），取干净帧。
func skip_all() -> void:
	if _tween != null and _tween.is_running():
		_tween.kill()
	_flush_mid()
	_restore_slide()
	veil.modulate.a = 0.0
	transitioning = false

func _flush_mid() -> void:
	var cb := _pending
	_pending = Callable()
	if cb.is_valid():
		cb.call()

func _begin_slide() -> void:
	if _slide_target != null and is_instance_valid(_slide_target):
		_slide_target.position.y = _slide_base + SLIDE_PX

func _restore_slide() -> void:
	if _slide_target != null and is_instance_valid(_slide_target):
		_slide_target.position.y = _slide_base
	_slide_target = null
