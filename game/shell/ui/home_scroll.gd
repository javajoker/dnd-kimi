# 主屏可交互绘卷 · 烬港夜景（12 §5 落位状态：一期程序化占位图，分层色块+剪影，ink/金墨配色）。
# - 热点坐标表数据化（HOTSPOTS：归一化 rect + 入口映射）：美术稿替换时热点坐标表与逻辑不动（12 §5 落位状态）；
# - 微光呼吸提示：BREATH_PERIOD ≤3s 正弦缓动，光强有下限不归零 = 不闪烁（12 §5）；
# - 未读角标：告示板（事件中心）热点叠加 ◆N（复用主屏角标语义，04 §①）；
# - 绘卷随状态板变化：褪墨度（global.doom_clock）驱动天色变暗/海面褪色（12 §5；04 §4 ① 状态板的可视化）；
# - 壳铁律：只发 hotspot_pressed 信号；写板与导航由 main 流程控制器执行。
class_name HomeScroll
extends Control

signal hotspot_pressed(screen_id: StringName)

const BREATH_PERIOD := 2.4 # 微光呼吸周期（12 §5：≤3 秒）
const GLOW_MIN := 0.22 # 微光下限：不归零 = 不闪烁（12 §5）
const GLOW_MAX := 0.70

# ink 深蓝黑 + 金墨点缀（与现有主题一致，04 §4）
const SKY_BASE := Color(0.045, 0.06, 0.13)
const SKY_DARK := Color(0.012, 0.014, 0.045) # 时钟高格：天色更暗
const SEA_BASE := Color(0.07, 0.11, 0.17)
const SEA_FADED := Color(0.045, 0.05, 0.07) # 时钟高格：海面褪色加剧
const INK := Color(0.02, 0.02, 0.05)
const GOLD := Color(0.88, 0.72, 0.32)
const EMBER := Color(0.95, 0.55, 0.20)

const HORIZON := 0.55 # 海天分界（归一化）
## 热点坐标表（数据化：rect = 绘卷归一化区域；screen_id = 入口映射，12 §5 ① 表）。
const HOTSPOTS: Array[Dictionary] = [
	{"id": "tide_tower", "screen_id": &"entry", "rect": Rect2(0.06, 0.10, 0.15, 0.42)},     # 潮汐塔（远景微光）→ ② 战役入口
	{"id": "market", "screen_id": &"inventory", "rect": Rect2(0.50, 0.48, 0.26, 0.18)},     # 集市棚区 → ⑥ 背包图鉴
	{"id": "campfire", "screen_id": &"character", "rect": Rect2(0.28, 0.62, 0.18, 0.24)},   # 营火与同伴 → ⑦ 角色
	{"id": "board", "screen_id": &"quests", "rect": Rect2(0.78, 0.64, 0.18, 0.26)},         # 告示板 → ⑤ 事件中心
	{"id": "scraps", "screen_id": &"history", "rect": Rect2(0.04, 0.72, 0.20, 0.24)},       # 残页堆/私藏抄本 → ⑧ 历史卷轴
]
## 星位（归一化坐标，数据；随褪墨度淡出）。
const STARS: Array[Vector2] = [Vector2(0.30, 0.10), Vector2(0.44, 0.06), Vector2(0.60, 0.16),
	Vector2(0.80, 0.08), Vector2(0.92, 0.20), Vector2(0.24, 0.24), Vector2(0.70, 0.28)]
## 水面波光点（归一化坐标，全部在海平线 HORIZON 之下；14 #7 绘卷分层细节：
## 呼吸微光驱动闪烁，随褪墨度衰减——与天色/海面同一 doom 口径，12 §5）。
const SPARKLES: Array[Vector2] = [Vector2(0.10, 0.63), Vector2(0.22, 0.70), Vector2(0.35, 0.66),
	Vector2(0.47, 0.74), Vector2(0.58, 0.62), Vector2(0.66, 0.78), Vector2(0.76, 0.68),
	Vector2(0.88, 0.73), Vector2(0.16, 0.82), Vector2(0.30, 0.88), Vector2(0.44, 0.84),
	Vector2(0.55, 0.92), Vector2(0.70, 0.87), Vector2(0.84, 0.90)]
## 塔顶灯窗（沿塔身纵向的归一化分数位，相对 tide_tower 热点 rect；14 #7）。
const TOWER_WINDOWS: Array[float] = [0.30, 0.52, 0.74]
## 集市棚顶灯光点（每棚沿檐口的横向分数位，相对单棚宽；14 #7）。
const SHED_ROOF_LIGHTS: Array[float] = [0.25, 0.55, 0.85]

var _doom_clock := 0
var _quest_badge := 0
var _breath_time := 0.0

func _process(delta: float) -> void:
	_breath_time += delta
	queue_redraw() # 呼吸微光逐帧重绘（纯呈现，不产事件不写板）

## 状态板可视化刷新（只读入参；由 ScreenHome.bind 转发，12 §5 / 04 §4 ①）。
func set_state(doom_clock: int, quest_badge: int) -> void:
	_doom_clock = doom_clock
	_quest_badge = quest_badge
	queue_redraw()

# ---------------------------------------------------------------- 呈现探针（无头断言用）

## 呼吸相位 0~1（缓动周期内位置）。
func breath_phase() -> float:
	return fmod(_breath_time, BREATH_PERIOD) / BREATH_PERIOD

## 呼吸光强：正弦缓动，区间 [GLOW_MIN, GLOW_MAX]，永不归零（不闪烁，12 §5）。
func breath_glow() -> float:
	var t := breath_phase()
	return GLOW_MIN + (GLOW_MAX - GLOW_MIN) * (0.5 - 0.5 * cos(t * TAU))

func doom_clock() -> int:
	return _doom_clock

func doom_factor() -> float:
	return clampf(float(_doom_clock) / 10.0, 0.0, 1.0)

func sky_color() -> Color:
	return SKY_BASE.lerp(SKY_DARK, doom_factor())

func sea_color() -> Color:
	return SEA_BASE.lerp(SEA_FADED, doom_factor())

func badge_count() -> int:
	return _quest_badge

func badge_visible() -> bool:
	return _quest_badge > 0

## 分层细节探针（14 #7 无头断言用：数据表驱动，改动即断）。
func sparkle_count() -> int:
	return SPARKLES.size()

func sparkle_point(i: int) -> Vector2:
	return SPARKLES[i]

func tower_window_count() -> int:
	return TOWER_WINDOWS.size()

func shed_roof_lights_per_shed() -> int:
	return SHED_ROOF_LIGHTS.size()

## 归一化热点区域 → 控件内绝对 rect。
func hotspot_rect(h: Dictionary) -> Rect2:
	var r: Rect2 = h["rect"]
	return Rect2(r.position * size, r.size * size)

## 命中测试（数据驱动：遍历 HOTSPOTS 表，不写死顺序语义）。
func hotspot_at(pos: Vector2) -> Dictionary:
	for h: Dictionary in HOTSPOTS:
		if hotspot_rect(h).has_point(pos):
			return h
	return {}

# ---------------------------------------------------------------- 交互（12 §5 ①：点按热点 = 导航；兜底条为等价路径）

func _gui_input(event: InputEvent) -> void:
	var pos := Vector2.ZERO
	var tapped := false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		pos = event.position
		tapped = true
	elif event is InputEventScreenTouch and not event.pressed:
		pos = event.position
		tapped = true
	if not tapped:
		return
	var h := hotspot_at(pos)
	if not h.is_empty():
		hotspot_pressed.emit(h["screen_id"])
		accept_event()

# ---------------------------------------------------------------- 程序化绘卷（一期占位：分层色块+剪影，无外部美术资源）

func _draw() -> void:
	var w := size.x
	var h := size.y
	var horizon_y := HORIZON * size.y
	var glow := breath_glow()
	# 天空（随褪墨度变暗）+ 星（褪色淡出）
	draw_rect(Rect2(0, 0, w, horizon_y), sky_color())
	var star_alpha := (1.0 - doom_factor()) * 0.8
	for s: Vector2 in STARS:
		draw_circle(s * size, 1.3, Color(GOLD, star_alpha))
	# 海面（随褪墨度褪色）+ 波线
	draw_rect(Rect2(0, horizon_y, w, size.y - horizon_y), sea_color())
	var wave_col := sea_color().lightened(0.35)
	for i: int in 4:
		var y := horizon_y + (float(i) + 0.6) * (size.y - horizon_y) / 5.0
		draw_line(Vector2(0, y), Vector2(w, y), Color(wave_col, 0.35), 1.0)
	# 水面波光点（14 #7 分层细节：呼吸闪烁 + 逐点错相，随褪墨度衰减）
	var sparkle_fade := (1.0 - doom_factor() * 0.6)
	for i: int in SPARKLES.size():
		var phase := fmod(breath_phase() + float(i) * 0.37, 1.0) # 逐点错相，不整齐划一
		var tw := 0.3 + 0.7 * (0.5 - 0.5 * cos(phase * TAU))
		var a := sparkle_fade * tw * (0.20 + glow * 0.55)
		draw_circle(SPARKLES[i] * size, 1.1 + glow * 0.7, Color(0.92, 0.86, 0.58, a))
	for hs: Dictionary in HOTSPOTS:
		_draw_layer(hs, glow)

func _draw_layer(hs: Dictionary, glow: float) -> void:
	var r := hotspot_rect(hs)
	match String(hs["id"]):
		"tide_tower": # 潮汐塔剪影：梯形塔身 + 塔顶金墨微光（远景微光，呼吸）
			var bx := r.position.x
			var bw := r.size.x
			var by := r.position.y
			var bh := r.size.y
			draw_colored_polygon(PackedVector2Array([
				Vector2(bx + bw * 0.15, by + bh), Vector2(bx + bw * 0.35, by),
				Vector2(bx + bw * 0.65, by), Vector2(bx + bw * 0.85, by + bh)]), INK)
			var tip := Vector2(bx + bw * 0.5, by + bh * 0.08)
			draw_circle(tip, 3.0 + glow * 2.0, Color(GOLD, 0.35 + glow * 0.6))
			draw_circle(tip, 9.0 + glow * 6.0, Color(GOLD, glow * 0.25))
			# 塔顶光束（14 #7：三段渐隐竖线，呼吸同相）
			for i: int in 3:
				var beam_a := glow * (0.22 - 0.06 * i)
				draw_line(tip + Vector2(0, -bh * (0.05 + 0.09 * i)),
					tip + Vector2(0, -bh * (0.14 + 0.09 * i)), Color(GOLD, beam_a), 1.6 - 0.4 * i)
			# 塔身灯窗（14 #7：沿塔纵向的金墨小窗，随呼吸微亮）
			for f: float in TOWER_WINDOWS:
				var wy := by + bh * f
				var half_w := bw * (0.35 - 0.20 * f) * 0.5 # 梯形内缩：窗不越出塔身
				draw_circle(Vector2(bx + bw * 0.5, wy), 1.5,
					Color(GOLD, (0.25 + glow * 0.45) * (1.0 - doom_factor() * 0.5)))
				draw_circle(Vector2(bx + bw * 0.5 - half_w, wy + bh * 0.02), 1.1,
					Color(GOLD, (0.18 + glow * 0.32) * (1.0 - doom_factor() * 0.5)))
		"market": # 集市棚区：三联棚剪影 + 金墨灯笼 + 棚顶檐口灯光点（14 #7 分层细节）
			for i: int in 3:
				var sx := r.position.x + r.size.x * (0.05 + 0.32 * i)
				var sw := r.size.x * 0.28
				var sy := r.position.y + r.size.y * 0.18
				draw_colored_polygon(PackedVector2Array([ # 棚顶三角
					Vector2(sx, sy + r.size.y * 0.35), Vector2(sx + sw * 0.5, sy),
					Vector2(sx + sw, sy + r.size.y * 0.35)]), INK)
				draw_rect(Rect2(sx + sw * 0.1, sy + r.size.y * 0.35, sw * 0.8, r.size.y * 0.45), INK)
				draw_circle(Vector2(sx + sw * 0.5, sy + r.size.y * 0.45), 1.8,
					Color(GOLD, 0.3 + glow * 0.4))
				for f: float in SHED_ROOF_LIGHTS: # 檐口灯串：逐棚三灯，呼吸微亮
					draw_circle(Vector2(sx + sw * f, sy + r.size.y * 0.33), 1.1,
						Color(GOLD, (0.22 + glow * 0.5) * (1.0 - doom_factor() * 0.4)))
		"campfire": # 营火与同伴：火堆金橙呼吸 + 两个围坐剪影
			var fx := r.position.x + r.size.x * 0.5
			var fy := r.position.y + r.size.y * 0.75
			var flame := r.size.y * (0.30 + glow * 0.12)
			draw_colored_polygon(PackedVector2Array([
				Vector2(fx - r.size.x * 0.12, fy), Vector2(fx, fy - flame),
				Vector2(fx + r.size.x * 0.12, fy)]), Color(EMBER, 0.55 + glow * 0.4))
			draw_circle(Vector2(fx, fy - flame * 0.4), 10.0 + glow * 8.0, Color(EMBER, glow * 0.2))
			for side: float in [-1.0, 1.0]: # 同伴剪影
				var px := fx + side * r.size.x * 0.32
				draw_circle(Vector2(px, fy - r.size.y * 0.22), r.size.y * 0.09, INK)
				draw_rect(Rect2(px - r.size.y * 0.08, fy - r.size.y * 0.14,
					r.size.y * 0.16, r.size.y * 0.16), INK)
		"board": # 告示板：双柱 + 板面 + 残纸贴片；未读角标 ◆N（金墨）
			var bw2 := r.size.x * 0.7
			var bx2 := r.position.x + r.size.x * 0.15
			var by2 := r.position.y + r.size.y * 0.12
			draw_rect(Rect2(bx2 + bw2 * 0.08, by2, r.size.x * 0.05, r.size.y * 0.88), INK)
			draw_rect(Rect2(bx2 + bw2 * 0.87, by2, r.size.x * 0.05, r.size.y * 0.88), INK)
			draw_rect(Rect2(bx2, by2 + r.size.y * 0.08, bw2, r.size.y * 0.5), INK)
			for i: int in 3: # 板上残纸（淡墨贴片）
				draw_rect(Rect2(bx2 + bw2 * (0.12 + 0.3 * i), by2 + r.size.y * 0.18,
					bw2 * 0.2, r.size.y * 0.26), Color(0.5, 0.48, 0.42, 0.8))
			if badge_visible(): # 未读角标叠加（12 §5；复用主屏 ◆N 语义，04 §①）
				var bp := Vector2(bx2 + bw2, by2 + r.size.y * 0.02)
				draw_circle(bp, 8.0, Color(GOLD, 0.5 + glow * 0.5))
				draw_string(get_theme_default_font(), bp + Vector2(-5.0, 4.0),
					"%d" % _quest_badge, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(INK))
		"scraps": # 残页堆/私藏抄本：叠落的淡墨纸片 + 金墨残光
			var base_y := r.position.y + r.size.y * 0.8
			for i: int in 4:
				var pw := r.size.x * (0.42 - 0.06 * i)
				var px2 := r.position.x + r.size.x * 0.25 + sin(float(i) * 1.7) * r.size.x * 0.1
				var py2 := base_y - r.size.y * 0.14 * i
				draw_rect(Rect2(px2, py2, pw, r.size.y * 0.1),
					Color(0.5, 0.48, 0.42, 0.55 + glow * 0.25))
			draw_circle(Vector2(r.position.x + r.size.x * 0.45, base_y - r.size.y * 0.55),
				2.0 + glow * 1.5, Color(GOLD, glow * 0.5))
