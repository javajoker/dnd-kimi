# 轻规则包 v1（docs/framework/11-轻规则包-v1.md 全文，v1.1）
# 纯函数规则核：不持有战斗状态，一切随机走传入的种子化 Rng（godot-dev §2：渲染与界面对规则档位无感）。
# - §3 检定公式：d20 + 修正 (+ 熟练 +2) vs DC 8/12/16；nat20 大成功、nat1 大失败；
#   攻击暴击：nat20 必中且伤害骰翻倍（修正不加倍），nat1 必失；
# - §3.1 优势/劣势：2d20 取高/取低；多来源不叠加，优劣互抵 → 普通掷；
# - §5.1 豁免：save={attr,dc,on_success: half|none}，成功半伤（向下取整）或免伤；
# - §7 死亡豁免：d20 ≥ 10 记一胜，<10 记一负（三局两胜的计数由 EncounterSM 持有）。
class_name LightV1
extends RefCounted

const DC_EASY := 8
const DC_MEDIUM := 12
const DC_HARD := 16
const DEATH_SAVE_DC := 10  # §7：d20 ≥ 10 记一胜
const FIRST_AID_DC := 8    # §5.2/§7：急救 d20+智 vs DC 8

const ADV_NORMAL := &"normal"
const ADV_ADVANTAGE := &"advantage"
const ADV_DISADVANTAGE := &"disadvantage"

# ---- §6 成长曲线（1~4 级，对齐 campaign01）----
const LEVEL_XP: Array[int] = [300, 700, 1200] # 1→2 / 2→3 / 3→4 升级所需累计经验
const LEVEL_HP_BONUS := 2    # 每升一级 HP+2
const LEVEL_ATTR_POINTS := 1 # 每升一级属性点 +1
const ATTR_POINT_CAP := 3    # 单项属性加点 ≤+3 封顶

## 累计经验 → 等级（1~4）。
static func level_for_xp(xp_total: int) -> int:
	var lv := 1
	for threshold: int in LEVEL_XP:
		if xp_total >= threshold:
			lv += 1
	return lv

## 累计经验 → HP 加值（每级 +2，§6）。
static func hp_bonus_for_xp(xp_total: int) -> int:
	return (level_for_xp(xp_total) - 1) * LEVEL_HP_BONUS

## 累计经验 → 应得属性点（每级 +1，§6；分配时机：结算或整备，09 §9.1）。
static func attr_points_for_xp(xp_total: int) -> int:
	return (level_for_xp(xp_total) - 1) * LEVEL_ATTR_POINTS

## §6：2→3 级技能槽 +1（3 级及以上生效）。
static func skill_slot_bonus(level: int) -> int:
	return 1 if level >= 3 else 0

# ---------------------------------------------------------------- §3.1 优势/劣势

## 合并优势来源：任意优势+任意劣势互抵 → 普通；仅一侧 → 该侧；多个同侧不叠加。
static func combine_advantage(sources: Array) -> StringName:
	var has_adv := false
	var has_dis := false
	for s: Variant in sources:
		var m := StringName(str(s))
		if m == ADV_ADVANTAGE:
			has_adv = true
		elif m == ADV_DISADVANTAGE:
			has_dis = true
	if has_adv == has_dis:
		return ADV_NORMAL
	return ADV_ADVANTAGE if has_adv else ADV_DISADVANTAGE

## 掷 d20（优势/劣势时 2d20 取高/低）。返回 {rolls, keep, mode}。
static func roll_d20(rng: Rng, mode: StringName = ADV_NORMAL) -> Dictionary:
	var a := rng.d20()
	if mode == ADV_NORMAL:
		return {"rolls": [a], "keep": a, "mode": mode}
	var b := rng.d20()
	var keep := maxi(a, b) if mode == ADV_ADVANTAGE else mini(a, b)
	return {"rolls": [a, b], "keep": keep, "mode": mode}

# ---------------------------------------------------------------- §3 检定

## 通用检定：d20+mod vs dc；nat20 大成功（必成）、nat1 大失败（必败）。
static func check(rng: Rng, mod: int, dc: int, mode: StringName = ADV_NORMAL) -> Dictionary:
	var r := roll_d20(rng, mode)
	var keep: int = r["keep"]
	var nat20 := keep == 20
	var nat1 := keep == 1
	var success := nat20 or (not nat1 and keep + mod >= dc)
	return {"rolls": r["rolls"], "keep": keep, "mode": mode, "mod": mod,
		"total": keep + mod, "dc": dc, "success": success, "nat20": nat20, "nat1": nat1}

# ---------------------------------------------------------------- 伤害骰

## 解析 "XdY+Z" / "XdY-Z" / "dY" 伤害骰表达式为 {count, sides, mod}。
static func parse_dice(expr: String) -> Dictionary:
	var e := expr.strip_edges().to_lower()
	var d_pos := e.find("d")
	if d_pos < 0:
		return {"count": 0, "sides": 0, "mod": int(e) if e.is_valid_int() else 0}
	var count_s := e.substr(0, d_pos)
	var rest := e.substr(d_pos + 1)
	var mod := 0
	var sides_s := rest
	var cut := -1
	var plus := rest.find("+")
	var minus := rest.find("-")
	if plus >= 0:
		cut = plus
	if minus >= 0 and (cut < 0 or minus < cut):
		cut = minus
	if cut >= 0:
		sides_s = rest.substr(0, cut)
		mod = int(rest.substr(cut))
	return {"count": (int(count_s) if count_s != "" else 1), "sides": int(sides_s), "mod": mod}

## 掷伤害骰；crit 时伤害骰翻倍（骰数 ×2，修正不加倍，§3）。
static func roll_damage(rng: Rng, expr: String, crit: bool = false) -> Dictionary:
	var d := parse_dice(expr)
	var times: int = int(d["count"]) * (2 if crit else 1)
	var rolls: Array[int] = []
	var total := 0
	for i: int in times:
		var r := rng.d_n(int(d["sides"]))
		rolls.append(r)
		total += r
	total += int(d["mod"])
	return {"rolls": rolls, "mod": int(d["mod"]), "total": maxi(total, 0)}

# ---------------------------------------------------------------- §5 攻击

## 攻击检定：d20+atk_mod vs target_ac；nat20 必中+暴击伤害骰翻倍，nat1 必失。
static func attack(rng: Rng, atk_mod: int, target_ac: int, damage_expr: String,
		mode: StringName = ADV_NORMAL) -> Dictionary:
	var r := roll_d20(rng, mode)
	var keep: int = r["keep"]
	var crit := keep == 20
	var fumble := keep == 1
	var hit := crit or (not fumble and keep + atk_mod >= target_ac)
	var dmg := {"rolls": [], "mod": 0, "total": 0}
	if hit:
		dmg = roll_damage(rng, damage_expr, crit)
	return {"rolls": r["rolls"], "keep": keep, "mode": mode, "atk_mod": atk_mod,
		"target_ac": target_ac, "hit": hit, "crit": crit, "fumble": fumble,
		"damage_rolls": dmg["rolls"], "damage_mod": dmg["mod"], "damage": dmg["total"]}

# ---------------------------------------------------------------- §5.1 豁免

## 豁免检定：save_def = {attr(已换算为 mod 传入), dc, on_success: "half"|"none"}。
## 成功：half → 半伤（向下取整），none → 免伤；失败全伤。伤害骰按目标各掷一次。
static func save_throw(rng: Rng, attr_mod: int, save_def: Dictionary, damage_expr: String,
		mode: StringName = ADV_NORMAL) -> Dictionary:
	var dc := int(save_def.get("dc", DC_MEDIUM))
	var on_success := str(save_def.get("on_success", "half"))
	var r := check(rng, attr_mod, dc, mode)
	var full := roll_damage(rng, damage_expr)
	var taken: int = full["total"]
	if r["success"]:
		taken = 0 if on_success == "none" else int(floori(float(full["total"]) / 2.0))
	return {"rolls": r["rolls"], "keep": r["keep"], "mode": mode, "mod": attr_mod,
		"total": r["total"], "dc": dc, "success": r["success"], "nat20": r["nat20"], "nat1": r["nat1"],
		"on_success": on_success, "damage_full": full["total"], "damage_taken": taken}

# ---------------------------------------------------------------- §7 死亡豁免

## 死亡豁免：d20 ≥ 10 记一胜，<10 记一负（三局两胜计数在 EncounterSM）。
static func death_save(rng: Rng) -> Dictionary:
	var roll := rng.d20()
	return {"roll": roll, "success": roll >= DEATH_SAVE_DC,
		"nat20": roll == 20, "nat1": roll == 1}
