# 打击感三件套 + 屏幕震动分级：参数与判定唯一配置源（docs/framework/14-表现层与平台化清单.md #3/#4）
# 双壳各自接线 JuiceLayer，参数一律取自此文件（godot-dev §7：禁止复制两份横屏/竖屏逻辑）。
# 纯呈现层：输入只有事件流 Dictionary，输出是呈现规格；不改 core、不写板、不回注事件流。
class_name JuiceConfig
extends RefCounted

# ---- #3 伤害数字飘字（上飘 + 淡出 0.8s）----
const FLOAT_DURATION := 0.8
const FLOAT_DISTANCE := 36.0
const FONT_BASE := 22
const CRIT_SCALE := 1.6                   # 暴击加大
const COLOR_DAMAGE := Color(1.0, 1.0, 1.0)
const COLOR_CRIT := Color(1.0, 0.82, 0.25) # 暴击金色
const COLOR_HEAL := Color(0.45, 0.92, 0.55)  # 治疗绿色
const COLOR_MISS := Color(0.62, 0.62, 0.68)  # 未命中"闪过"灰色

# ---- #3 命中反馈（闪白一帧 + 几像素弹回）----
const FLASH_COLOR := Color(4.0, 4.0, 4.0) # 过曝白一帧
const FLASH_TIME := 0.12
const KNOCKBACK_PX := 6.0
const KNOCKBACK_TIME := 0.12

# ---- #3 击杀消散（墨色碎片粒子 + 单位淡出 0.5s）----
const DISSOLVE_DURATION := 0.5
const DISSOLVE_FRAGMENTS := 12
const FRAGMENT_PX := 6.0
const COLOR_INK := Color(0.16, 0.14, 0.22)

# ---- #4 屏幕震动分级 ----
const SHAKE_NONE := 0
const SHAKE_SMALL := 1 # 受击小震
const SHAKE_BIG := 2   # 暴击/死亡豁免大震
const SHAKE_SMALL_AMP := 2.0
const SHAKE_SMALL_DUR := 0.15
const SHAKE_BIG_AMP := 5.0
const SHAKE_BIG_DUR := 0.3
const SHAKE_STEP := 0.03 # 每步 30ms 换向

## 事件 → 飘字规格；不该出字的事件返回 {}。
## 规格：{unit, attacker, text, tag, color, scale, kind}（kind ∈ damage/crit/miss/heal）。
static func number_spec(ev: Dictionary) -> Dictionary:
	var p: Dictionary = ev.get("payload", {})
	match StringName(ev["type"]):
		EventTypes.BATTLE_ATTACK:
			if bool(p.get("hit", false)):
				var crit := bool(p.get("crit", false))
				return {"unit": str(p["target"]), "attacker": str(p["attacker"]),
					"text": str(int(p["damage"])),
					"tag": TextsZh.JUICE_CRIT if crit else "",
					"color": COLOR_CRIT if crit else COLOR_DAMAGE,
					"scale": CRIT_SCALE if crit else 1.0,
					"kind": "crit" if crit else "damage"}
			return {"unit": str(p["target"]), "attacker": str(p.get("attacker", "")),
				"text": TextsZh.JUICE_MISS, "tag": "", "color": COLOR_MISS,
				"scale": 1.0, "kind": "miss"}
		EventTypes.ITEM_USE:
			if int(p.get("healed", 0)) > 0:
				return {"unit": str(p["target"]), "attacker": "",
					"text": "+%d" % int(p["healed"]), "tag": "", "color": COLOR_HEAL,
					"scale": 1.0, "kind": "heal"}
	return {}

## 事件 → 震动档（SHAKE_NONE/SMALL/BIG）：受击小震；暴击或死亡豁免大震（14 #4）。
static func shake_level(ev: Dictionary) -> int:
	var p: Dictionary = ev.get("payload", {})
	var t := StringName(ev["type"])
	if t == EventTypes.BATTLE_ATTACK and bool(p.get("hit", false)):
		return SHAKE_BIG if bool(p.get("crit", false)) else SHAKE_SMALL
	if t == EventTypes.CHECK_ROLL and str(p.get("kind", "")) == "death_save":
		return SHAKE_BIG # 死亡豁免恒定关键判定（11 §7），震动随大档
	return SHAKE_NONE

## 档位 → {amp, dur}；SHAKE_NONE 返回 {}。
static func shake_params(level: int) -> Dictionary:
	match level:
		SHAKE_SMALL:
			return {"amp": SHAKE_SMALL_AMP, "dur": SHAKE_SMALL_DUR}
		SHAKE_BIG:
			return {"amp": SHAKE_BIG_AMP, "dur": SHAKE_BIG_DUR}
	return {}
