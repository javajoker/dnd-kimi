# 成长系统（docs/tech/04-资源与效果系统.md §8 定稿；docs/framework/11-轻规则包-v1.md §6）
# 成长是框架层能力（角色跨战役携带，05 §5），簿记落全局白名单键（07 §2/§3）：
#   global.growth.xp          累计经验 —— 任何包（战役/支线/子游戏）的 xp 效果即写入（§8 规则1）
#   global.growth.level       等级     —— 按绑定规则包门槛表自动结算（§8 规则2，轻规则 300/700/1200）
#   global.growth.attr_points 未分配属性点 —— 升级自动 +N（轻规则每级 +1）；分配时 -1
#   global.growth.attrs.<attr> 已分配属性 —— 分配 API（结算屏/整备界面，09 §9.1），单项 ≤+3 封顶（§8 规则3）
# 旧包内簿记键（campaign01.xp_total 等）由 SaveSystem v1→v2 迁移器并入（§8 规则4，07 §4.3）。
class_name Growth
extends RefCounted

const XP_KEY := "global.growth.xp"
const LEVEL_KEY := "global.growth.level"
const ATTR_POINTS_KEY := "global.growth.attr_points"
const ATTRS_PREFIX := "global.growth.attrs."

var _board: Board

func _init(board: Board) -> void:
	_board = board

# ---------------------------------------------------------------- 只读查询（static：BattleDef 等静态上下文同源）

static func xp(board: Board) -> int:
	return int(board.read(XP_KEY, 0))

static func level(board: Board) -> int:
	return int(board.read(LEVEL_KEY, 1))

static func attr_points(board: Board) -> int:
	return int(board.read(ATTR_POINTS_KEY, 0))

## 已分配属性映射 {attr: n}（战斗修正叠加用，11 §6）。
static func attrs_map(board: Board) -> Dictionary:
	var out := {}
	for key: String in board.keys_with_prefix(ATTRS_PREFIX):
		out[key.trim_prefix(ATTRS_PREFIX)] = int(board.read(key, 0))
	return out

## 单项已分配值（供战斗修正）。
static func attrs_total(board: Board, attr: String) -> int:
	return int(board.read(ATTRS_PREFIX + attr, 0))

## 升级进度（结算/整备/角色界面⑦数据源）：xp 相对当前档位的进度与下一档门槛（满级 next=0）。
static func xp_progress(board: Board) -> Dictionary:
	var lv := level(board)
	var floor_xp := int(LightV1.LEVEL_XP[lv - 2]) if lv >= 2 else 0 # 当前等级起始累计经验
	var next_xp := int(LightV1.LEVEL_XP[lv - 1]) if lv - 1 < LightV1.LEVEL_XP.size() else 0
	return {"xp": xp(board), "level": lv, "floor": floor_xp, "next": next_xp,
		"attr_points": attr_points(board), "attrs": attrs_map(board)}

# ---------------------------------------------------------------- 经验汇入（§8 规则1/2）

## 任何包的 xp 效果即写 global.growth.xp + xp.gain 事件；跨档即升级：
## 写 level / attr_points（每级 +LEVEL_ATTR_POINTS），每升一级产一条 level.up 事件。
## 返回 {xp, level, leveled}（leveled = 本次升级数）。
func grant_xp(n: int, provenance: Dictionary, source: StringName = &"core") -> Dictionary:
	var lv := level(_board)
	if n <= 0:
		return {"xp": xp(_board), "level": lv, "leveled": 0}
	var new_xp := xp(_board) + n
	_board.write(XP_KEY, new_xp, provenance)
	_board.stream.emit(EventTypes.XP_GAIN,
		{"amount": n, "xp_total": new_xp, "provenance": provenance.duplicate(true)},
		source, str(provenance.get("node_id", "")))
	var new_lv := LightV1.level_for_xp(new_xp)
	if new_lv > lv:
		_board.write(LEVEL_KEY, new_lv, provenance)
		_board.write(ATTR_POINTS_KEY,
			attr_points(_board) + (new_lv - lv) * LightV1.LEVEL_ATTR_POINTS, provenance)
		for l: int in range(lv + 1, new_lv + 1):
			_board.stream.emit(EventTypes.LEVEL_UP,
				{"level": l, "hp_bonus": LightV1.LEVEL_HP_BONUS,
					"attr_points": LightV1.LEVEL_ATTR_POINTS,
					"provenance": provenance.duplicate(true)},
				source, str(provenance.get("node_id", "")))
	return {"xp": new_xp, "level": new_lv, "leveled": maxi(0, new_lv - lv)}

# ---------------------------------------------------------------- 属性点分配（§8 规则3；09 §9.1）

## 可分配：有未分配点数且单项未达 +3 封顶（11 §6）。
func can_alloc(attr: String) -> bool:
	return attr_points(_board) > 0 and attrs_total(_board, attr) < LightV1.ATTR_POINT_CAP

## 分配 1 点：attrs.<attr> +1、attr_points -1，产 attr.alloc 事件；不可分配拒绝并返回 false。
func alloc(attr: String, provenance: Dictionary, source: StringName = &"core") -> bool:
	if not can_alloc(attr):
		return false
	var value := attrs_total(_board, attr) + 1
	_board.write(ATTRS_PREFIX + attr, value, provenance)
	var left := attr_points(_board) - 1
	_board.write(ATTR_POINTS_KEY, left, provenance)
	_board.stream.emit(EventTypes.ATTR_ALLOC,
		{"attr": attr, "value": value, "points_left": left,
			"provenance": provenance.duplicate(true)},
		source, str(provenance.get("node_id", "")))
	return true
