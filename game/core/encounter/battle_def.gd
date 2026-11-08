# 战斗定义组装器（docs/tech/04-资源与效果系统.md §2/§3/§4；docs/tech/02-内容包格式规范.md §6）
# 由内容包资源表组装 EncounterSM.begin_combat 的战斗定义：
#   遭遇 party/enemies 实例（tech/02 §6）→ characters.json / enemies.json 条目（tech/04 §1/§2）；
#   hp/ac 由规则包求值字符串公式（tech/04 §2：规则包求值，改规则包不改角色表）；
#   普攻修正/伤害骰 = 角色 basic_attack 技能的 attr 属性值与 damage（tech/04 §2 basic_attack）；
#   出战技能 = 整备选择 ∩（角色已习得 ∩ skills.json）（tech/04 §7）；
#   道具 = 整备选择 ∩ 背包持有 ∩ items.json 含 use 块（tech/04 §4）；
#   玩家模板叠加成长：属性点分配（11 §6，board <pack>.attrs）与每级 HP+2（LightV1.hp_bonus_for_xp）；
#   首回合优势 = 遭遇 party_advantage 旗标声明（11 §3.1：来源由内容包声明）。
# 纯数据组装，零引擎依赖；任何引用缺失/公式求值失败 → ok=false 并逐条报错（引导层 fail-fast）。
class_name BattleDef
extends RefCounted

## tech/04 §3 target（数据层）→ EncounterSM target（运行时）映射。
const TARGET_MAP := {"enemy_single": "enemy", "ally_single": "ally", "self": "self"}
## 玩家模板缺省出战技能数（整备未启用时的兜底：已习得列表前 2 个，对齐 TP2 引导脚本）。
const DEFAULT_SKILL_COUNT := 2

## 组装战斗定义。返回 { ok, errors[], def }；def 仅在 ok 时可用。
## selection = 整备选择 {skills[], items[]}（可空 = 缺省）；board 供成长/背包/优势旗标读取（只读）。
static func assemble(pack: Dictionary, encounter_id: String, selection: Dictionary, board: Board) -> Dictionary:
	var errors: Array[String] = []
	var pack_id := str(pack.get("pack_id", ""))
	var encounters: Dictionary = pack.get("encounters", {})
	if not encounters.has(encounter_id):
		return {"ok": false, "errors": ["遭遇 '%s' 未在 encounters.json 登记（tech/02 §6）" % encounter_id], "def": {}}
	var enc: Dictionary = encounters[encounter_id]
	var characters: Dictionary = pack.get("characters", {})
	var skills: Dictionary = pack.get("skills", {})
	var enemies: Dictionary = pack.get("enemies", {})
	var items: Dictionary = pack.get("items", {})

	# ---- 队伍（tech/02 §6 party 实例 → tech/04 §2 角色条目）----
	var party: Array = []
	var party_entries: Array = enc.get("party", [])
	if party_entries.is_empty():
		errors.append("遭遇 %s 未声明 party（tech/02 §6：引导层不自动组队）" % encounter_id)
	for entry: Variant in party_entries:
		var e: Dictionary = entry
		var ref := str(e.get("ref", ""))
		if not characters.has(ref):
			errors.append("遭遇 %s party 引用未登记角色 '%s'（characters.json）" % [encounter_id, ref])
			continue
		party.append(_build_character_unit(str(e.get("id", ref)), characters[ref],
			pack_id, selection, board, skills, items, encounter_id, errors))

	# ---- 敌方（tech/02 §6 enemies 实例 → tech/04 §1 敌人条目）----
	var foes: Array = []
	var enemy_entries: Array = enc.get("enemies", [])
	if str(enc.get("type", "")) == "battle" and enemy_entries.is_empty():
		errors.append("战斗遭遇 %s 未声明 enemies（tech/02 §6）" % encounter_id)
	for entry: Variant in enemy_entries:
		var e: Dictionary = entry
		var ref := str(e.get("ref", ""))
		if not enemies.has(ref):
			errors.append("遭遇 %s enemies 引用未登记敌人 '%s'（enemies.json）" % [encounter_id, ref])
			continue
		foes.append(_build_enemy_unit(str(e.get("id", ref)), enemies[ref], encounter_id, errors))

	# ---- 首回合优势（11 §3.1 内容包声明来源）----
	var adv_rounds := 0
	var adv: Dictionary = enc.get("party_advantage", {})
	if adv.has("flag"):
		var fkey := str(adv["flag"])
		if not fkey.contains("."):
			fkey = "%s.%s" % [pack_id, fkey]
		if bool(board.read(fkey)):
			adv_rounds = int(adv.get("rounds", 1))

	var loot: Array = []
	for l: Variant in enc.get("loot", []):
		loot.append({"item": str((l as Dictionary).get("item", "")), "n": int((l as Dictionary).get("n", 1))})
	var def := {"party": party, "enemies": foes, "party_advantage_rounds": adv_rounds,
		"loot": loot, "xp": int(enc.get("xp", 0))}
	return {"ok": errors.is_empty(), "errors": errors, "def": def}

# ---------------------------------------------------------------- 单位组装

static func _build_character_unit(inst_id: String, c: Dictionary, pack_id: String,
		selection: Dictionary, board: Board, skills: Dictionary, items: Dictionary,
		encounter_id: String, errors: Array[String]) -> Dictionary:
	var kind := str(c.get("kind", ""))
	var base_attrs: Dictionary = c.get("attrs", {})
	var alloc: Dictionary = {}
	var hp_bonus := 0
	var level := 1
	if kind == "player_template":
		# 成长叠加（11 §6）：属性点分配进最终属性；HP 加值只加 HP（11 §6 与属性点解耦）
		alloc = board.read("%s.attrs" % pack_id, {})
		var xp_total := int(board.read("%s.xp_total" % pack_id, 0))
		level = LightV1.level_for_xp(xp_total)
		hp_bonus = LightV1.hp_bonus_for_xp(xp_total)
	# hp/ac：公式以模板基础属性求值（属性点分配不影响 hp/ac 基值，11 §6 成长只走 hp_bonus）
	var fvars := {"might": int(base_attrs.get("might", 0)), "finesse": int(base_attrs.get("finesse", 0)),
		"wits": int(base_attrs.get("wits", 0)), "level": level}
	var hp: Variant = LightV1.eval_formula(str(c.get("hp_formula", "")), fvars)
	if hp == null:
		errors.append("角色 %s hp_formula 求值失败：'%s'（tech/04 §2 白名单 might/finesse/wits/level）"
			% [inst_id, str(c.get("hp_formula", ""))])
		hp = 1
	var ac: Variant = LightV1.eval_formula(str(c.get("ac_formula", "")), fvars)
	if ac == null:
		errors.append("角色 %s ac_formula 求值失败：'%s'（tech/04 §2）" % [inst_id, str(c.get("ac_formula", ""))])
		ac = 10
	var final_attrs := {}
	for a: String in ["might", "finesse", "wits"]:
		final_attrs[a] = int(base_attrs.get(a, 0)) + int(alloc.get(a, 0))
	# 普攻修正/伤害骰 = basic_attack 技能（tech/04 §2）
	var atk_mod := 0
	var dmg := "1d4"
	var ba_id := str(c.get("basic_attack", ""))
	if ba_id.is_empty():
		errors.append("角色 %s 缺 basic_attack（tech/04 §2）" % inst_id)
	elif not skills.has(ba_id):
		errors.append("角色 %s basic_attack 引用未登记技能 '%s'（skills.json）" % [inst_id, ba_id])
	else:
		var ba: Dictionary = skills[ba_id]
		atk_mod = int(final_attrs.get(str(ba.get("attr", "might")), 0))
		dmg = str(ba.get("damage", dmg))
	var unit := {
		"id": inst_id,
		"name": str(c.get("name", inst_id)),
		"kind": "player" if kind == "player_template" else kind, # 运行时 kind：player/companion（11 §5.2）
		"hp": int(hp) + hp_bonus, "max_hp": int(hp) + hp_bonus, "ac": int(ac),
		"attrs": final_attrs, "attack_mod": atk_mod, "damage": dmg,
	}
	# 出战技能：整备选择 ∩ 已习得（tech/04 §7）；同伴恒带招牌技能（11 §5.2）
	var learned: Array = c.get("skills", [])
	var picked: Array = []
	if kind == "player_template":
		picked = selection.get("skills", [])
		if picked.is_empty():
			picked = learned.slice(0, DEFAULT_SKILL_COUNT) # 整备未启用兜底（TP2 引导脚本对齐）
	else:
		picked = learned
	var unit_skills: Array = []
	for sid: Variant in picked:
		var skill_id := str(sid)
		if not learned.has(skill_id):
			continue # 未习得不进战斗 def（整备层已校验槽位，防御式跳过）
		if not skills.has(skill_id):
			errors.append("角色 %s 出战技能 '%s' 未在 skills.json 登记" % [inst_id, skill_id])
			continue
		unit_skills.append(runtime_skill(skills[skill_id]))
	unit["skills"] = unit_skills
	# 出战道具：整备选择 ∩ 背包持有 ∩ items.json 含 use 块（tech/04 §4；仅玩家模板携带，
	# 键存在性与 TP2 引导脚本结构对齐：玩家单位恒有 items 键，同伴无）
	if kind == "player_template":
		var unit_items: Array = []
		for iid: Variant in selection.get("items", []):
			var item_id := str(iid)
			if not items.has(item_id) or not (items[item_id] as Dictionary).has("use"):
				continue
			if not board.has_item(item_id):
				continue
			unit_items.append({"id": item_id, "name": str((items[item_id] as Dictionary).get("name", item_id)),
				"count": board.item_count(item_id),
				"use": ((items[item_id] as Dictionary)["use"] as Dictionary).duplicate(true)})
		unit["items"] = unit_items
	return unit

static func _build_enemy_unit(inst_id: String, def: Dictionary, encounter_id: String,
		errors: Array[String]) -> Dictionary:
	var attrs := {"might": 0, "finesse": 0, "wits": 0}
	for a: String in (def.get("attrs", {}) as Dictionary).keys():
		attrs[a] = int((def["attrs"] as Dictionary)[a])
	var unit := {
		"id": inst_id,
		"name": str(def.get("name", inst_id)),
		"hp": int(def.get("hp", 1)), "max_hp": int(def.get("hp", 1)),
		"ac": int(def.get("ac", 10)),
		"attrs": attrs,
		"attack_mod": int(def.get("attack_mod", 0)),
		"damage": str(def.get("damage", "1d4")),
	}
	var unit_skills: Array = []
	for sk: Variant in def.get("skills", []):
		var s: Dictionary = sk
		var out := {"id": str(s.get("id", "")), "name": str(s.get("name", s.get("id", ""))),
			"kind": str(s.get("kind", "attack"))}
		if s.has("attr"):
			out["attr"] = str(s["attr"])
		if s.has("damage"):
			out["damage"] = str(s["damage"])
		if s.has("uses"):
			out["uses"] = int(s["uses"])
		if s.has("cooldown"):
			out["cooldown"] = int(s["cooldown"])
		if s.has("save"):
			var sv: Dictionary = s["save"]
			out["save"] = {"attr": str(sv.get("attr", "finesse")), "dc": int(sv.get("dc", 12)),
				"on_success": str(sv.get("on_success", "half"))}
		if str(s.get("kind", "")) == "aoe" and not (s.get("save", {}) as Dictionary).has("dc"):
			errors.append("遭遇 %s 敌人 %s 范围技能 '%s' 缺 save.dc（11 §5.1）"
				% [encounter_id, inst_id, str(s.get("id", ""))])
		unit_skills.append(out)
	if not unit_skills.is_empty():
		unit["skills"] = unit_skills
	return unit

## tech/04 §3 技能条目 → 运行时技能结构（uses_per_encounter→uses；target 枚举映射；
## gesture 为呈现层提示不进战斗 def）。
static func runtime_skill(s: Dictionary) -> Dictionary:
	var out := {"id": str(s.get("id", "")), "name": str(s.get("name", s.get("id", ""))),
		"kind": str(s.get("kind", "attack"))}
	if s.has("attr"):
		out["attr"] = str(s["attr"])
	if s.has("damage"):
		out["damage"] = str(s["damage"])
	if s.get("uses_per_encounter") != null:
		out["uses"] = int(s["uses_per_encounter"])
	out["target"] = str(TARGET_MAP.get(str(s.get("target", "enemy_single")), "enemy"))
	if s.has("effect"):
		out["effect"] = (s["effect"] as Dictionary).duplicate(true)
	if s.has("save"):
		out["save"] = (s["save"] as Dictionary).duplicate(true)
	return out
