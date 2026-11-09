# 外观系统运行时（docs/framework/06-商业化框架.md §3 外观只写外观旗标 / §7 外观商品位落地；
# docs/framework/07-世界状态机规范.md §2/§3 v1.2 global.cosmetic.* 白名单；
# docs/framework/10-道具与图鉴规范.md §4 v1.1 集齐奖励到账细化）
# - 注册表 = 运营侧数据文件 packs/_ops/cosmetics.json（与 entitlements.json 同构，06 §7：
#   点亮在运营，内容包管线零改动）；本类只读注册表，不持有定价决策。
# - 写板键：global.cosmetic.dice_skin（当前装备）+ global.cosmetic.owned.<skin_id>（持有集合）；
#   写权限仅 system（07 §3 v1.2）——商店购买 / 图鉴集齐奖励 / 外观页装备操作统一经本类落板，
#   每次写入携带溯源（购买单号 / 集齐系列），变更经 flag.write 进事件流（07 §6）。
# - 付费禁区（06 §4）：本类只回答"皮肤是什么"，绝不进入骰子/数值/事件流判定路径
#   （core/encounter、rulepack、rng 零引用）；渲染壳经 palette_of 只读取色，渲染层对规则无感。
class_name Cosmetics
extends RefCounted

## 注册表路径（06 §7：运营侧数据文件，非内容包）。
const REGISTRY_PATH := "res://packs/_ops/cosmetics.json"
## 兜底调色板（注册表缺失时仍渲染默认金墨，容错不阻断）。
const FALLBACK_PALETTE := {"face": "#e8c76a", "edge": "#6b4f16", "pip": "#2b2114"}

var board: Board
var stream: EventStream
var registry: Array = [] # 皮肤定义（注册表 dice_skins 原序）

func _init(p_board: Board, p_stream: EventStream, p_registry: Array = []) -> void:
	board = p_board
	stream = p_stream
	registry = p_registry if not p_registry.is_empty() else load_registry(REGISTRY_PATH)

# ---------------------------------------------------------------- 注册表（数据驱动，06 §7）

## 加载皮肤注册表；缺失或解析失败 = 空注册表（容错不阻断，与 ops_config 同一哲学）。
static func load_registry(path: String = REGISTRY_PATH) -> Array:
	if not FileAccess.file_exists(path):
		push_warning("[cosmetics] 皮肤注册表缺失：%s（按空注册表容错）" % path)
		return []
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if raw == null or not raw is Dictionary or not (raw as Dictionary).get("dice_skins") is Array:
		push_error("[cosmetics] 皮肤注册表 JSON 解析失败或缺 dice_skins 数组：%s" % path)
		return []
	var out: Array = []
	for e: Variant in (raw as Dictionary)["dice_skins"]:
		if e is Dictionary and not str((e as Dictionary).get("id", "")).is_empty():
			out.append(e)
	return out

func skins() -> Array:
	return registry

func has_skin(skin_id: String) -> bool:
	return _def_of(skin_id) != null

## 默认皮肤（注册表 default=true；缺省取首项；空注册表 = ""）。
func default_skin_id() -> String:
	for e: Variant in registry:
		if bool((e as Dictionary).get("default", false)):
			return str((e as Dictionary)["id"])
	return str((registry[0] as Dictionary)["id"]) if not registry.is_empty() else ""

# ---------------------------------------------------------------- 持有与装备（只读查询）

## 持有判定：默认皮肤恒持有；其余读 global.cosmetic.owned.<skin_id>（07 §2 外观旗标）。
func is_owned(skin_id: String) -> bool:
	if skin_id == default_skin_id():
		return true
	return bool(board.read("global.cosmetic.owned." + skin_id, false))

## 当前装备皮肤 id（未设置或指向未持有皮肤时回落默认皮）。
func equipped_id() -> String:
	var cur := str(board.read("global.cosmetic.dice_skin", ""))
	if cur != "" and has_skin(cur) and is_owned(cur):
		return cur
	return default_skin_id()

func skin_name(skin_id: String) -> String:
	var def: Variant = _def_of(skin_id)
	return str((def as Dictionary).get("name", skin_id)) if def != null else skin_id

# ---------------------------------------------------------------- 写入方（system 写权限，07 §3 v1.2）

## 点亮持有（幂等：已持有不重复写）。extra_prov = 溯源补充（granted_by / receipt_id / series）。
func grant(skin_id: String, extra_prov: Dictionary) -> bool:
	if not has_skin(skin_id):
		push_error("[cosmetics] 未登记皮肤：%s（注册表数据驱动，06 §7）" % skin_id)
		return false
	if is_owned(skin_id):
		return false # 幂等（默认皮肤恒持有，亦不再落板）
	var prov := {"event_id": stream.tail(), "node_id": "", "pack_id": "system"}
	prov.merge(extra_prov)
	return board.write("global.cosmetic.owned." + skin_id, true, prov)

## 商店购买点亮：receipt_id = 购买单号（mock；真实支付接入是运营立项留白，06 §7）。
func shop_purchase(skin_id: String, receipt_id: String) -> bool:
	return grant(skin_id, {"granted_by": "shop", "receipt_id": receipt_id})

## 装备：仅已持有皮肤可装备（写 global.cosmetic.dice_skin，07 §2）。
func equip(skin_id: String) -> bool:
	if not has_skin(skin_id) or not is_owned(skin_id):
		return false
	var prov := {"event_id": stream.tail(), "node_id": "", "pack_id": "system", "granted_by": "equip"}
	return board.write("global.cosmetic.dice_skin", skin_id, prov)

## 卸下：回落默认皮肤（置空字符串，equipped_id 兜底）。
func unequip() -> bool:
	var prov := {"event_id": stream.tail(), "node_id": "", "pack_id": "system", "granted_by": "equip"}
	return board.write("global.cosmetic.dice_skin", "", prov)

# ---------------------------------------------------------------- 集齐奖励（10 §4 v1.1：聚合全包 lore 判定）

## 评估注册表中 grant.kind=codex_series 的皮肤：该系列全部条目已解锁 → 点亮持有。
## lore_defs = 全部已加载内容包的 lore 条目聚合（条目可跨包贡献，10 §4 v1.1）。
## 返回本次新点亮 skin_id 列表（幂等：已点亮不重复发）；点亮即 toast（与成就点亮同一呈现手法）。
func check_codex_rewards(lore_defs: Array) -> Array:
	var granted: Array = []
	for e: Variant in registry:
		var def: Dictionary = e
		var g: Dictionary = def.get("grant", {})
		if str(g.get("kind", "")) != "codex_series":
			continue
		var series := str(g.get("series", ""))
		if series.is_empty():
			continue
		var total := 0
		var got := 0
		for le: Variant in lore_defs:
			var ld: Dictionary = le
			if str(ld.get("series", "")) != series:
				continue
			total += 1
			if board.has_lore(str(ld.get("id", ""))):
				got += 1
		if total > 0 and got == total:
			var skin_id := str(def["id"])
			if grant(skin_id, {"granted_by": "codex", "series": series}):
				granted.append(skin_id)
				stream.emit(EventTypes.LOG,
					{"msg": "图鉴集齐——骰子皮肤「%s」已到账。（纯演出，不动骰运）" % skin_name(skin_id),
						"toast": true}, &"core")
	return granted

# ---------------------------------------------------------------- 调色板（渲染壳唯一读取口，纯呈现）

## 当前装备皮肤的调色板 {face, edge, pip}（Color）。board 为 null 或皮肤缺失时回落默认金墨。
## 渲染层只读此方法：换肤 = 换色板，不进任何逻辑判定（06 §3/§4；godot-dev §2 渲染对规则无感）。
static var _palette_cache: Array = [] # 注册表静态缓存（渲染热路径不重复读盘）

static func palette_of(p_board: Board) -> Dictionary:
	if _palette_cache.is_empty():
		_palette_cache = load_registry()
	var skins := _palette_cache
	var skin_id := ""
	if p_board != null:
		skin_id = str(p_board.read("global.cosmetic.dice_skin", ""))
	var def: Dictionary = {}
	for e: Variant in skins:
		if str((e as Dictionary).get("id", "")) == skin_id:
			def = e
			break
	if def.is_empty(): # 未设置/未登记 → 默认皮
		for e: Variant in skins:
			if bool((e as Dictionary).get("default", false)):
				def = e
				break
		if def.is_empty() and not skins.is_empty():
			def = skins[0]
	var pal: Dictionary = def.get("palette", {})
	return {
		"face": Color(str(pal.get("face", FALLBACK_PALETTE["face"]))),
		"edge": Color(str(pal.get("edge", FALLBACK_PALETTE["edge"]))),
		"pip": Color(str(pal.get("pip", FALLBACK_PALETTE["pip"]))),
	}

# ---------------------------------------------------------------- 内部

func _def_of(skin_id: String) -> Variant:
	for e: Variant in registry:
		if str((e as Dictionary).get("id", "")) == skin_id:
			return e
	return null
