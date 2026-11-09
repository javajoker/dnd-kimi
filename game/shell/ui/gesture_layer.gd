# 手势层（docs/framework/12-手势与交互规范.md §1~§3；13 §5 手势词表落地）
# - 透明覆盖层：mouse_filter=IGNORE + _input 观察全部输入，永不吞事件——
#   按钮等价路径（12 §1 铁律）因此不受影响，手势是纯效率层；
# - 输入翻译：鼠标 = 触点 0（桌面/无头测试同源），触屏按 index 直传；
#   时间取 Time.get_ticks_msec() 注入 GestureRecognizer（判定参数恒定，12 §1）；
# - 语义分流（12 §3 起点定语义）由宿主壳在信号回调里做命中测试，本层不含任何游戏语义。
class_name GestureLayer
extends Control

signal tapped(pos: Vector2)
signal long_pressed(pos: Vector2)
signal drag_started(info: Dictionary)
signal drag_updated(info: Dictionary)
signal dragged(info: Dictionary)
signal path_cast(info: Dictionary)
signal two_finger_tapped(pos: Vector2)
signal pinched(ratio: float, center: Vector2)
signal pinch_ended(ratio: float, center: Vector2)
signal h_swiped(dir: int, pos: Vector2)
signal v_swiped(dir: int, pos: Vector2)

var rec := GestureRecognizer.new()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE # 不挡任何控件（12 §1 按钮等价铁律）
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rec.tapped.connect(func(p: Vector2) -> void: tapped.emit(p))
	rec.long_pressed.connect(func(p: Vector2) -> void: long_pressed.emit(p))
	rec.drag_started.connect(func(i: Dictionary) -> void: drag_started.emit(i))
	rec.drag_updated.connect(func(i: Dictionary) -> void: drag_updated.emit(i))
	rec.dragged.connect(func(i: Dictionary) -> void: dragged.emit(i))
	rec.path_cast.connect(func(i: Dictionary) -> void: path_cast.emit(i))
	rec.two_finger_tapped.connect(func(p: Vector2) -> void: two_finger_tapped.emit(p))
	rec.pinched.connect(func(r: float, c: Vector2) -> void: pinched.emit(r, c))
	rec.pinch_ended.connect(func(r: float, c: Vector2) -> void: pinch_ended.emit(r, c))
	rec.h_swiped.connect(func(d: int, p: Vector2) -> void: h_swiped.emit(d, p))
	rec.v_swiped.connect(func(d: int, p: Vector2) -> void: v_swiped.emit(d, p))

func _input(event: InputEvent) -> void:
	var now := Time.get_ticks_msec()
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			rec.press(0, mb.position, now)
		else:
			rec.release(0, mb.position, now)
	elif event is InputEventMouseMotion:
		rec.move(0, (event as InputEventMouseMotion).position, now)
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			rec.press(st.index, st.position, now)
		else:
			rec.release(st.index, st.position, now)
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		rec.move(sd.index, sd.position, now)

func _process(_delta: float) -> void:
	rec.poll(Time.get_ticks_msec()) # 长按计时（12 §1：≥400ms）

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		rec.cancel_all() # 12 §3.5：打断 = 抬手于空位 = 取消
