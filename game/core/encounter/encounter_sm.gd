# 遭遇状态机（docs/framework/09-遭遇与双模式交互规范.md §1；docs/tech/01-技术方案讨论稿.md §6.1/§6.2）
# - 六态：进场→探索⇄发现→战斗→结算→休整→出场（对话并入探索分支，tech/01 §6.1 转换图）；
#   状态切换外发 state.entered 事件（09 §1：渲染壳只订阅、不被指挥）；非法转换拒绝（不换态、不产事件）。
# - 统一 Command 通道（tech/01 §6.2）：玩家/托管/敌方意图均为同构命令对象
#   {type, actor, target, skill, item, source}，submit_command 校验合法性后执行并产出事件；
#   非法意图拒绝并发 command.rejected——渲染层 Bug 不污染逻辑状态。
# - 战斗数值结算全部委托规则包 LightV1（05 §3 规则包扩展轴：状态机本体无规则公式）。
# - 行动经济（11 §4/§5.2）：PC 1 动作 + 每存活同伴 1 动作 + 附赠 ×1；全员行动完进敌方回合。
class_name EncounterSM
extends RefCounted

# ---- 六态（09 §1）----
const S_ENTER := &"enter"
const S_EXPLORE := &"explore"
const S_DISCOVER := &"discover"
const S_COMBAT := &"combat"
const S_SETTLE := &"settle"
const S_REST := &"rest"
const S_EXIT := &"exit"

## 合法转换表（09 §1 进入/退出条件 + tech/01 §6.1 转换图）。
const TRANSITIONS := {
	S_ENTER: [S_EXPLORE],
	S_EXPLORE: [S_DISCOVER, S_COMBAT, S_SETTLE],
	S_DISCOVER: [S_EXPLORE, S_COMBAT],
	S_COMBAT: [S_SETTLE, S_EXIT],   # →exit 仅限内容包声明撤退边（09 §7）
	S_SETTLE: [S_REST, S_EXIT],
	S_REST: [S_EXIT],
	S_EXIT: [],
}

# ---- Command 类型（tech/01 §6.2）----
const CMD_ATTACK := &"attack"
const CMD_SKILL := &"skill"
const CMD_ITEM := &"item"
const CMD_FIRST_AID := &"first_aid"
const CMD_MOVE := &"move"          # 移动段（11 §4：每回合 移动≤6格 与动作/附赠并行；12 §2.1 拖动移动）
const CMD_END_TURN := &"end_turn"
const CMD_RETREAT := &"retreat"
const COMMAND_TYPES: Array[StringName] = [CMD_ATTACK, CMD_SKILL, CMD_ITEM, CMD_FIRST_AID, CMD_MOVE, CMD_END_TURN, CMD_RETREAT]
const COMMAND_KEYS: Array[String] = ["type", "actor", "target", "skill", "item", "source"]

var board: Board
var stream: EventStream
var rng: Rng
var pack_id := ""
var node_id := ""
var state: StringName = &""

# ---- 战斗态数据（壳只读，经 get_* 访问）----
var _units: Dictionary = {}       # id -> unit
var _order: Array[String] = []    # 先攻降序（11 §5：d20+敏，平局玩家优先）
var _round := 0
var _phase: StringName = &"party"
var _party_pending: Array[String] = []
var _retreat_allowed := false
var _party_adv_rounds := 0        # 优势来源由内容包声明（11 §3.1 示例：见证撤销 → 首回合全队优势）
var _loot: Array = []
var _xp := 0
var _over := false
var _result: StringName = &""
var _last_actor: String = ""
# ---- 护送目标（11 §5「遭遇定义的目标达成」；tech/02 §6 escort 块）----
var _escort_unit_id := ""          # 护送对象实例 id（kind=escort_npc：不占行动轮、不可指令、HP 不持久化）
var _escort_survive_rounds := 0    # 存活满 N 个完整回合即胜；0 = 非护送遭遇
var _escort_failure_effects: Array = [] # 目标失败写板（罚时替代全灭，08 §2 失败即分支）

func _init(p_board: Board, p_stream: EventStream, p_rng: Rng, p_pack_id: String = "system") -> void:
	board = p_board
	stream = p_stream
	rng = p_rng
	pack_id = p_pack_id

# ---------------------------------------------------------------- 状态机（09 §1）

## 进入遭遇（加载完成 → 进场态），外发 state.entered。
func enter(p_node_id: String) -> void:
	node_id = p_node_id
	_set_state(S_ENTER)

## 状态转换；非法转换拒绝（返回 false，不换态、不产事件）。
func transition(to: StringName) -> bool:
	if state == S_EXIT or not TRANSITIONS.has(state):
		return false
	if to == state or not (TRANSITIONS[state] as Array).has(to):
		return false
	if state == S_COMBAT and to == S_EXIT and not _retreat_allowed:
		return false # 撤退边须内容包声明（09 §7）
	_set_state(to)
	return true

func _set_state(to: StringName) -> void:
	var prev := state
	state = to
	stream.emit(EventTypes.STATE_ENTERED, {"state": to, "prev": prev}, &"core", node_id)

# ---------------------------------------------------------------- 战斗开始（11 §5 先攻）

## 由探索/发现态进入战斗。def = {party[], enemies[], retreat_allowed, party_advantage_rounds, loot[], xp}。
func begin_combat(def: Dictionary) -> bool:
	if state != S_EXPLORE and state != S_DISCOVER:
		push_error("EncounterSM.begin_combat：仅探索/发现态可进战斗（09 §1）")
		return false
	_units.clear()
	for u: Variant in def.get("party", []):
		_add_unit(u as Dictionary, &"party")
	for u: Variant in def.get("enemies", []):
		_add_unit(u as Dictionary, &"enemy")
	_retreat_allowed = bool(def.get("retreat_allowed", false))
	_party_adv_rounds = int(def.get("party_advantage_rounds", 0))
	_loot = (def.get("loot", []) as Array).duplicate(true)
	_xp = int(def.get("xp", 0))
	# 护送目标声明（tech/02 §6 escort 块；胜负条件 = 11 §5 目标达成）
	var esc: Dictionary = def.get("escort", {})
	_escort_unit_id = str(esc.get("unit_id", ""))
	_escort_survive_rounds = int(esc.get("survive_rounds", 0))
	_escort_failure_effects = (esc.get("failure_effects", []) as Array).duplicate(true)
	_over = false
	_result = &""
	# 先攻 = d20 + 敏修正，降序，平局玩家优先（11 §5）
	var rolls: Array = []
	for id: String in _units:
		var u: Dictionary = _units[id]
		rolls.append({"id": id, "init": rng.d20() + _attr(u, "finesse"),
			"seq": rolls.size(), "side": u["side"]})
	rolls.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["init"]) != int(b["init"]):
			return int(a["init"]) > int(b["init"])
		if a["side"] != b["side"]:
			return a["side"] == &"party"
		return int(a["seq"]) < int(b["seq"]))
	_order.clear()
	for r: Dictionary in rolls:
		_order.append(str(r["id"]))
	_set_state(S_COMBAT)
	stream.emit(EventTypes.COMBAT_START, {"order": _order.duplicate(), "units": get_units(),
		"party_advantage_rounds": _party_adv_rounds}, &"core", node_id)
	_round = 1
	_begin_party_phase()
	return true

func _add_unit(def: Dictionary, side: StringName) -> void:
	var u := def.duplicate(true)
	u["side"] = side
	u["kind"] = StringName(str(u.get("kind", "enemy" if side == &"enemy" else "player")))
	u["name"] = str(u.get("name", u.get("id", "?")))
	u["max_hp"] = int(u.get("max_hp", u.get("hp", 1)))
	u["hp"] = mini(int(u.get("hp", u["max_hp"])), int(u["max_hp"]))
	u["ac"] = int(u.get("ac", 10))
	u["attrs"] = (u.get("attrs", {"might": 0, "finesse": 0, "wits": 0}) as Dictionary).duplicate()
	u["attack_mod"] = int(u.get("attack_mod", 0))
	u["damage"] = str(u.get("damage", "1d4"))
	var skills: Array = (u.get("skills", []) as Array).duplicate(true)
	u["skills"] = skills
	u["skill_uses"] = {}
	for sk: Variant in skills:
		var uses := int((sk as Dictionary).get("uses", -1))
		if uses > 0:
			(u["skill_uses"] as Dictionary)[str((sk as Dictionary)["id"])] = uses
	u["cooldowns"] = {}
	u["items"] = (u.get("items", []) as Array).duplicate(true)
	u["statuses"] = []
	u["downed"] = false
	u["dead"] = false
	u["death_saves"] = {"s": 0, "f": 0}
	u["action_used"] = false
	u["bonus_used"] = false
	u["move_used"] = false # 移动段（11 §4：每回合一段，与动作/附赠并行）
	_units[str(u["id"])] = u

# ---------------------------------------------------------------- 回合循环（11 §4/§5/§5.2）

func _begin_party_phase() -> void:
	if _over:
		return
	_phase = &"party"
	_party_pending.clear()
	for id: String in _order:
		var u: Dictionary = _units[id]
		if u["side"] == &"party" and not bool(u["dead"]) and u["kind"] != &"escort_npc":
			# 护送对象不占行动轮、不可被指令（tech/02 §6 escort 块）
			u["action_used"] = false
			u["bonus_used"] = false
			u["move_used"] = false # 移动段随回合重置（11 §4）
			_party_pending.append(id)
	stream.emit(EventTypes.TURN_START, {"round": _round, "side": "party",
		"actor": current_actor_id()}, &"core", node_id)
	_last_actor = current_actor_id()
	_process_downed_front()

## 行动单位变更时外发 turn.start（事件流驱动渲染：壳据此刷新快捷栏/当前单位高亮）。
func _emit_actor_turn() -> void:
	var cur := current_actor_id()
	if cur != "" and cur != _last_actor:
		_last_actor = cur
		stream.emit(EventTypes.TURN_START, {"round": _round, "side": "party", "actor": cur},
			&"core", node_id)

## 队首倒地单位自动进行死亡豁免（11 §7），直至轮到可行动单位或进入敌方回合。
func _process_downed_front() -> void:
	while not _party_pending.is_empty():
		var u: Dictionary = _units[_party_pending[0]]
		if bool(u["dead"]):
			_party_pending.pop_front()
			continue
		if not bool(u["downed"]):
			break
		_party_pending.pop_front()
		_roll_death_save(u)
		if _over:
			return
	if _party_pending.is_empty() and not _over:
		_run_enemy_phase()
	else:
		_emit_actor_turn()

func _roll_death_save(u: Dictionary) -> void:
	var res := LightV1.death_save(rng)
	if bool(res["success"]):
		(u["death_saves"] as Dictionary)["s"] = int((u["death_saves"] as Dictionary)["s"]) + 1
	else:
		(u["death_saves"] as Dictionary)["f"] = int((u["death_saves"] as Dictionary)["f"]) + 1
	var ds: Dictionary = u["death_saves"]
	stream.emit(EventTypes.CHECK_ROLL, {"roller": u["id"], "kind": "death_save",
		"rolls": [res["roll"]], "keep": res["roll"], "dc": LightV1.DEATH_SAVE_DC,
		"success": res["success"], "s": ds["s"], "f": ds["f"],
		"key": true, # 11 §7：死亡豁免是框架恒定关键判定（全屏演出，09 §6）
		"extreme": bool(res["nat20"]) or bool(res["nat1"]),
		"source": &"core"}, &"core", node_id)
	if int(ds["s"]) >= 3:
		_revive(u, "stabilized") # 三胜稳住（1 HP，11 §7）
	elif int(ds["f"]) >= 3:
		u["dead"] = true
		stream.emit(EventTypes.BATTLE_DEAD, {"unit": u["id"], "name": u["name"]}, &"core", node_id)
		_check_battle_end()

func _run_enemy_phase() -> void:
	if _over:
		return
	_phase = &"enemy"
	_last_actor = ""
	stream.emit(EventTypes.TURN_START, {"round": _round, "side": "enemy"}, &"core", node_id)
	for id: String in _order:
		var u: Dictionary = _units[id]
		if u["side"] != &"enemy" or bool(u["dead"]):
			continue
		_enemy_act(u)
		if _over:
			return
	_round += 1
	_party_adv_rounds = maxi(0, _party_adv_rounds - 1)
	# 护送目标：存活满 survive_rounds 个完整回合即胜（11 §5 目标达成，tech/02 §6 escort 块）
	if _escort_survive_rounds > 0 and _round > _escort_survive_rounds and _escort_alive():
		_finish(&"victory")
		return
	_begin_party_phase()

## 敌方行动：与玩家走同一结算路径（同一事件流，tech/01 §6.2），source=&"enemy"。
func _enemy_act(u: Dictionary) -> void:
	for k: String in (u["cooldowns"] as Dictionary).keys():
		(u["cooldowns"] as Dictionary)[k] = maxi(0, int((u["cooldowns"] as Dictionary)[k]) - 1)
	var aoe := _pick_aoe(u)
	if not aoe.is_empty():
		if (u["skill_uses"] as Dictionary).has(str(aoe["id"])):
			(u["skill_uses"] as Dictionary)[str(aoe["id"])] = int((u["skill_uses"] as Dictionary)[str(aoe["id"])]) - 1
		(u["cooldowns"] as Dictionary)[str(aoe["id"])] = int(aoe.get("cooldown", 0))
		stream.emit(EventTypes.SKILL_USE, {"unit": u["id"], "skill": aoe["id"],
			"name": str(aoe.get("name", aoe["id"])), "source": &"enemy"}, &"core", node_id)
		var save_def: Dictionary = aoe.get("save", {})
		for tid: String in _order:
			var t: Dictionary = _units[tid]
			if t["side"] != &"party" or bool(t["dead"]) or bool(t["downed"]):
				continue
			var res := LightV1.save_throw(rng, _attr(t, str(save_def.get("attr", "finesse"))),
				save_def, str(aoe.get("damage", "1d4")))
			_apply_damage(t, int(res["damage_taken"]), true) # 先落数值再发事件
			stream.emit(EventTypes.CHECK_ROLL, {"roller": tid, "kind": "save",
				"skill": aoe["id"], "rolls": res["rolls"], "keep": res["keep"], "mod": res["mod"],
				"total": res["total"], "dc": res["dc"], "success": res["success"],
				"damage": res["damage_taken"], "on_success": res["on_success"],
				"target_hp_after": int(t["hp"]),
				"key": bool(aoe.get("key", false)), # 豁免默认普通演出，内容包可标记关键（11 §5.1）
				"extreme": bool(res["nat20"]) or bool(res["nat1"]),
				"source": &"enemy"}, &"core", node_id)
			_emit_damage_outcome(t)
			if _over:
				return
		return
	# 近战意图优先指向护送对象（打断仪式，tech/02 §6 escort 块）；范围效果照常覆盖全队
	var target_id := first_alive_party()
	if _escort_alive():
		target_id = _escort_unit_id
	if target_id == "":
		_check_battle_end()
		return
	_resolve_attack(u, target_id, {}, &"enemy")

## 挑可用的范围技能（11 §5.1：声明 save 块的范围效果）。
func _pick_aoe(u: Dictionary) -> Dictionary:
	for sk: Variant in (u["skills"] as Array):
		var s: Dictionary = sk
		if not (s.get("save", {}) as Dictionary).has("dc"):
			continue
		if (u["skill_uses"] as Dictionary).has(str(s["id"])) and int((u["skill_uses"] as Dictionary)[str(s["id"])]) <= 0:
			continue
		if int((u["cooldowns"] as Dictionary).get(str(s["id"]), 0)) > 0:
			continue
		return s
	return {}

# ---------------------------------------------------------------- Command 通道（tech/01 §6.2）

## 唯一指令入口。返回是否受理；拒绝时发 command.rejected 事件。
func submit_command(cmd: Dictionary) -> bool:
	var reason := _validate(cmd)
	if reason != "":
		stream.emit(EventTypes.COMMAND_REJECTED, {"cmd": cmd.duplicate(true), "reason": reason},
			&"core", node_id)
		return false
	_resolve(cmd)
	return true

func _validate(cmd: Dictionary) -> String:
	if state != S_COMBAT or _over:
		return "not_in_combat"
	var ctype := StringName(str(cmd.get("type", "")))
	if not COMMAND_TYPES.has(ctype):
		return "bad_type"
	var src := StringName(str(cmd.get("source", "")))
	if src != &"player" and src != &"auto":
		return "bad_source" # 玩家/托管同通道（09 §9.3）；敌方由 core 内部驱动
	if _phase != &"party":
		return "not_party_phase"
	var actor_id := str(cmd.get("actor", ""))
	if actor_id != current_actor_id():
		return "not_your_turn"
	var u: Dictionary = _units.get(actor_id, {})
	if u.is_empty() or bool(u["downed"]) or bool(u["dead"]):
		return "bad_actor"
	match ctype:
		CMD_END_TURN:
			return ""
		CMD_RETREAT:
			return "" if _retreat_allowed else "no_retreat_edge"
		CMD_MOVE:
			if bool(u["move_used"]):
				return "move_used" # 移动段每回合一段（11 §4）
			return ""
		CMD_ATTACK:
			if bool(u["action_used"]):
				return "action_used"
			if not _is_enemy_target(u, str(cmd.get("target", ""))):
				return "bad_target"
		CMD_SKILL:
			if bool(u["action_used"]):
				return "action_used"
			var sk := _find_skill(u, str(cmd.get("skill", "")))
			if sk.is_empty():
				return "no_skill"
			if (u["skill_uses"] as Dictionary).has(str(sk["id"])) \
					and int((u["skill_uses"] as Dictionary)[str(sk["id"])]) <= 0:
				return "skill_depleted" # 次数制（11 §8）
			match str(sk.get("target", "enemy")):
				"enemy":
					if not _is_enemy_target(u, str(cmd.get("target", ""))):
						return "bad_target"
				"self":
					if str(cmd.get("target", "")) != actor_id:
						return "bad_target"
				"ally":
					if not _is_ally_target(u, str(cmd.get("target", "")), false):
						return "bad_target"
		CMD_ITEM:
			if bool(u["bonus_used"]):
				return "bonus_used"
			var it := _find_item(u, str(cmd.get("item", "")))
			if it.is_empty():
				return "no_item"
			if str((it.get("use", {}) as Dictionary).get("timing", "")) != "bonus_action":
				return "bad_timing" # TP2 道具 use 块：附赠（tech/04 §4）
			if not _is_ally_target(u, str(cmd.get("target", "")), false):
				return "bad_target"
		CMD_FIRST_AID:
			if bool(u["action_used"]):
				return "action_used"
			if not _is_ally_target(u, str(cmd.get("target", "")), true):
				return "bad_target" # 目标须为倒地队友（11 §5.2）
	return ""

func _resolve(cmd: Dictionary) -> void:
	var ctype := StringName(str(cmd["type"]))
	var src := StringName(str(cmd.get("source", &"player")))
	var u: Dictionary = _units[str(cmd["actor"])]
	match ctype:
		CMD_ATTACK:
			_resolve_attack(u, str(cmd["target"]), {}, src)
		CMD_SKILL:
			_resolve_skill(u, cmd, src)
		CMD_ITEM:
			_resolve_item(u, cmd, src)
		CMD_FIRST_AID:
			_resolve_first_aid(u, str(cmd["target"]), src)
		CMD_MOVE:
			# 移动段消耗（11 §4）；落点是呈现层布局（壳维护格位，不进事件流），
			# dest 仅作溯源记录（"x,y" 格位或 stance 描述），core 不校验距离（≤6 格由壳在拖动预览层约束）
			u["move_used"] = true
			stream.emit(EventTypes.BATTLE_MOVE, {"unit": u["id"], "name": u["name"],
				"dest": str(cmd.get("target", "")), "source": src}, &"core", node_id)
		CMD_END_TURN:
			u["action_used"] = true
			u["bonus_used"] = true
		CMD_RETREAT:
			_finish(&"retreat") # 撤退边走"失败即分支"（09 §7）
			return
	if _over:
		return
	_check_battle_end()
	if not _over and _phase == &"party":
		_maybe_advance()

## 当前单位动作+附赠均耗尽（或结束回合）→ 轮到下一单位；全员行动完进敌方回合（11 §5.2）。
func _maybe_advance() -> void:
	if _party_pending.is_empty():
		return
	var u: Dictionary = _units[_party_pending[0]]
	if bool(u["action_used"]) and bool(u["bonus_used"]):
		_party_pending.pop_front()
		_process_downed_front()

# ---------------------------------------------------------------- 结算动作

func _resolve_attack(u: Dictionary, target_id: String, skill: Dictionary, src: StringName) -> void:
	var t: Dictionary = _units[target_id]
	# 优势来源收集（11 §3.1：来源由内容包声明——首回合优势 / 墨盾格挡 / 技能自带）
	var sources: Array = []
	if u["side"] == &"party" and _party_adv_rounds > 0:
		sources.append(LightV1.ADV_ADVANTAGE)
	for st: Variant in (t["statuses"] as Array):
		if bool((st as Dictionary).get("attackers_disadvantage", false)):
			sources.append(LightV1.ADV_DISADVANTAGE)
	if bool(skill.get("adv", false)):
		sources.append(LightV1.ADV_ADVANTAGE)
	if bool(skill.get("dis", false)):
		sources.append(LightV1.ADV_DISADVANTAGE)
	var mode := LightV1.combine_advantage(sources)
	var atk_mod := int(u["attack_mod"])
	var dmg_expr := str(u["damage"])
	if not skill.is_empty():
		atk_mod = _attr(u, str(skill.get("attr", "might")))
		dmg_expr = str(skill.get("damage", dmg_expr))
	var res := LightV1.attack(rng, atk_mod, _effective_ac(t), dmg_expr, mode)
	if u["side"] == &"party":
		u["action_used"] = true
	var hp_before := int(t["hp"])
	if bool(res["hit"]):
		_apply_damage(t, int(res["damage"]), true) # 先落数值再发事件：订阅者刷新即见最新 HP
	stream.emit(EventTypes.BATTLE_ATTACK, {"attacker": u["id"], "attacker_name": u["name"],
		"target": target_id, "target_name": t["name"], "skill": str(skill.get("id", "")),
		"rolls": res["rolls"], "keep": res["keep"], "mode": res["mode"],
		"atk_mod": res["atk_mod"], "target_ac": res["target_ac"],
		"hit": res["hit"], "crit": res["crit"], "fumble": res["fumble"],
		"damage_rolls": res["damage_rolls"], "damage": res["damage"],
		"target_hp_before": hp_before, "target_hp_after": int(t["hp"]),
		"key": false, # 普通攻击=普通演出（09 §6）
		"extreme": bool(res["crit"]) or bool(res["fumble"]), # nat20/nat1 追加一档反馈
		"source": src}, &"core", node_id)
	_emit_damage_outcome(t)

func _resolve_skill(u: Dictionary, cmd: Dictionary, src: StringName) -> void:
	var sk := _find_skill(u, str(cmd["skill"]))
	if (u["skill_uses"] as Dictionary).has(str(sk["id"])):
		(u["skill_uses"] as Dictionary)[str(sk["id"])] = int((u["skill_uses"] as Dictionary)[str(sk["id"])]) - 1
	stream.emit(EventTypes.SKILL_USE, {"unit": u["id"], "skill": sk["id"],
		"name": str(sk.get("name", sk["id"])),
		"uses_left": int((u["skill_uses"] as Dictionary).get(str(sk["id"]), -1)),
		"source": src}, &"core", node_id)
	match str(sk.get("kind", "attack")):
		"attack":
			_resolve_attack(u, str(cmd["target"]), sk, src)
		"utility":
			u["action_used"] = true
			var st: Dictionary = (sk.get("effect", {}) as Dictionary).duplicate(true)
			st["id"] = str(sk["id"])
			st["until_round"] = _round + int(st.get("duration_rounds", 0))
			(u["statuses"] as Array).append(st)
			stream.emit(EventTypes.LOG, {"msg": "%s 发动了「%s」" % [u["name"], str(sk.get("name", sk["id"]))],
				"unit": u["id"], "skill": sk["id"], "source": src}, &"core", node_id)

func _resolve_item(u: Dictionary, cmd: Dictionary, src: StringName) -> void:
	var it := _find_item(u, str(cmd["item"]))
	u["bonus_used"] = true
	it["count"] = int(it["count"]) - 1
	if int(it["count"]) <= 0:
		(u["items"] as Array).erase(it)
	var t: Dictionary = _units[str(cmd["target"])]
	var healed := 0
	var use: Dictionary = it.get("use", {})
	if use.has("heal"):
		var hr := LightV1.roll_damage(rng, str(use["heal"]))
		healed = mini(int(hr["total"]), int(t["max_hp"]) - int(t["hp"]))
		t["hp"] = int(t["hp"]) + healed
	var ev := stream.emit(EventTypes.ITEM_USE, {"unit": u["id"], "item": it["id"],
		"target": t["id"], "healed": healed, "left": int(it.get("count", 0)),
		"source": src}, &"core", node_id)
	if bool(use.get("consume", false)) and board.has_item(str(it["id"])):
		# consume 道具从 global.inv 移除（写板+事件流，tech/04 §4）
		board.remove_item(str(it["id"]), 1,
			{"event_id": ev["id"], "node_id": node_id, "pack_id": pack_id})

## 急救：动作，d20+智 vs DC 8，成功即以 1 HP 扶起（11 §5.2/§7）。
func _resolve_first_aid(u: Dictionary, target_id: String, src: StringName) -> void:
	u["action_used"] = true
	var t: Dictionary = _units[target_id]
	var res := LightV1.check(rng, _attr(u, "wits"), LightV1.FIRST_AID_DC)
	stream.emit(EventTypes.CHECK_ROLL, {"roller": u["id"], "kind": "first_aid",
		"target": target_id, "rolls": res["rolls"], "keep": res["keep"], "mod": res["mod"],
		"total": res["total"], "dc": res["dc"], "success": res["success"],
		"key": false, "extreme": bool(res["nat20"]) or bool(res["nat1"]),
		"source": src}, &"core", node_id)
	if bool(res["success"]):
		_revive(t, "first_aid")

## 数值落板（silent=true 时只改数值，倒地/死亡事件由 _emit_damage_outcome 在结算事件之后补发）。
func _apply_damage(t: Dictionary, dmg: int, silent: bool = false) -> void:
	if dmg <= 0 or bool(t["dead"]):
		return
	t["hp"] = maxi(0, int(t["hp"]) - dmg)
	if int(t["hp"]) > 0:
		return
	if t["side"] == &"enemy":
		t["dead"] = true
	else:
		t["downed"] = true
		t["death_saves"] = {"s": 0, "f": 0}
	if silent:
		return
	_emit_damage_outcome(t)

func _emit_damage_outcome(t: Dictionary) -> void:
	if int(t["hp"]) > 0:
		return
	if t["side"] == &"enemy" and bool(t["dead"]):
		stream.emit(EventTypes.BATTLE_DEAD, {"unit": t["id"], "name": t["name"]}, &"core", node_id)
	elif t["side"] == &"party" and bool(t["downed"]):
		stream.emit(EventTypes.BATTLE_DOWN, {"unit": t["id"], "name": t["name"]}, &"core", node_id)
		# 护送对象 HP 归 0 = 目标失败（objective_failed，罚时替代全灭，tech/02 §6 escort 块）
		if str(t["id"]) == _escort_unit_id:
			_finish(&"objective_failed")
			return
	_check_battle_end()

func _revive(u: Dictionary, reason: StringName) -> void:
	u["downed"] = false
	u["hp"] = 1
	u["death_saves"] = {"s": 0, "f": 0}
	stream.emit(EventTypes.BATTLE_REVIVE, {"unit": u["id"], "name": u["name"], "reason": reason},
		&"core", node_id)

# ---------------------------------------------------------------- 战斗结束与结算（09 §1：写状态板是硬要求）

func _check_battle_end() -> void:
	if _over:
		return
	if first_alive_enemy() == "":
		_finish(&"victory")
	elif _first_alive_fighter() == "":
		# 全员（玩家+同伴）倒地 = 团灭（11 §5.2）→ 失败路；护送对象不计入战斗员
		_finish(&"defeat")

## 护送对象存活（未倒未死）；无护送声明恒 false。
func _escort_alive() -> bool:
	if _escort_unit_id.is_empty() or not _units.has(_escort_unit_id):
		return false
	var u: Dictionary = _units[_escort_unit_id]
	return not bool(u["dead"]) and not bool(u["downed"])

## 首个可行动的存活战斗员（玩家/同伴；护送 NPC 不算战斗员，tech/02 §6）。
func _first_alive_fighter() -> String:
	for id: String in _order:
		var u: Dictionary = _units[id]
		if u["side"] == &"party" and u["kind"] != &"escort_npc" \
				and not bool(u["dead"]) and not bool(u["downed"]):
			return id
	return ""

func _finish(result: StringName) -> void:
	_over = true
	_result = result
	var ev := stream.emit(EventTypes.COMBAT_END, {"result": result, "rounds": _round}, &"core", node_id)
	var prov := {"event_id": ev["id"], "node_id": node_id, "pack_id": pack_id}
	if result == &"victory":
		# 11 §5.2：战斗结束时倒地同伴自动以 1 HP 起身
		for id: String in _order:
			var u: Dictionary = _units[id]
			if u["side"] == &"party" and u["kind"] == &"companion" \
					and bool(u["downed"]) and not bool(u["dead"]):
				_revive(u, "post_battle")
		for l: Variant in _loot:
			board.give_item(str((l as Dictionary).get("item", "")), int((l as Dictionary).get("n", 1)), prov)
		if _xp > 0:
			# 遭遇经验 = xp 效果同一通道：写 global.growth.xp 并自动结算升级（tech/04 §8 规则1/2）
			Growth.new(board).grant_xp(_xp, prov)
	elif result == &"objective_failed":
		# 护送目标失败：无战利品/经验，按声明写板罚时等代价（08 §2 失败即分支；
		# 效果 DSL 同一通道，tech/02 §4.6）——之后仍走节点唯一出边（由引导层推进）
		if not _escort_failure_effects.is_empty():
			Conditions.new(board).apply_effects(_escort_failure_effects, {
				"pack_id": pack_id, "node_id": node_id, "event_id": ev["id"], "source": "core"})
	# 11 §7.1：遭遇结束时 HP 写状态板（<ns>.hp.<char_id>），下次遭遇以此开局；
	# 倒地同伴战后 1 HP 起身（上方 _revive 已落 hp=1）；非死亡单位至少 1 HP 落板（团灭=失败路分支，
	# 不做永久团灭锁死），死亡单位写 0（组装层按 1 HP 抬升，11 §7.1 落地裁决见交付说明）。
	for id: String in _order:
		var u: Dictionary = _units[id]
		if u["side"] == &"party" and u["kind"] != &"escort_npc":
			# 护送 NPC 非 characters.json 条目：HP 不跨遭遇持久化（tech/02 §6 escort 块）
			var char_id := str(u.get("ref", u["id"]))
			var hp_write := 0 if bool(u["dead"]) else maxi(int(u["hp"]), 1)
			board.write("%s.hp.%s" % [pack_id, char_id], hp_write, prov)
	_set_state(S_SETTLE)
	stream.emit(EventTypes.LOG, {"msg": "遭遇结束：%s（%d 回合）" % [result, _round],
		"result": result, "xp": _xp, "loot": _loot.duplicate(true)}, &"core", node_id)

# ---------------------------------------------------------------- 只读访问（壳唯一数据通道：事件流 + 这些 getter）

func get_unit(id: String) -> Dictionary:
	return (_units.get(id, {}) as Dictionary).duplicate(true)

func get_units() -> Dictionary:
	return _units.duplicate(true)

func get_order() -> Array[String]:
	return _order.duplicate()

func round_no() -> int:
	return _round

func phase() -> StringName:
	return _phase

func is_over() -> bool:
	return _over

func result() -> StringName:
	return _result

func party_advantage_rounds() -> int:
	return _party_adv_rounds

func current_actor_id() -> String:
	if _phase != &"party" or _party_pending.is_empty() or _over:
		return ""
	return _party_pending[0]

func first_alive_enemy() -> String:
	for id: String in _order:
		var u: Dictionary = _units[id]
		if u["side"] == &"enemy" and not bool(u["dead"]):
			return id
	return ""

## 首个可行动的存活友方（未倒地）。
func first_alive_party() -> String:
	for id: String in _order:
		var u: Dictionary = _units[id]
		if u["side"] == &"party" and not bool(u["dead"]) and not bool(u["downed"]):
			return id
	return ""

## 有队友倒地（急救芯片可用条件，11 §5.2）。
func any_party_downed() -> bool:
	return _first_downed_ally_id() != ""

func _first_downed_ally_id() -> String:
	for id: String in _order:
		var u: Dictionary = _units[id]
		if u["side"] == &"party" and bool(u["downed"]) and not bool(u["dead"]):
			return id
	return ""

# ---------------------------------------------------------------- 可用指令集（09 §9.2：快捷栏/行动轮盘内容 = 当前整备选择 + 情境实时过滤）
# 两壳同源铁律：横屏行动轮盘与竖屏快捷栏都从本 getter 生成，壳内禁止复制过滤逻辑（godot-dev §7）。
# 每项：{type, skill, item, name, uses, count, disabled, reason, target_kind, default_target}
# —— 只读视图，不产出事件、不改状态；文案名取自内容数据，壳只负责排版。

## 当前友方行动单位的可用指令集；非友方阶段/非战斗态返回空数组。
func get_available_actions() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if state != S_COMBAT or _over or _phase != &"party":
		return out
	var uid := current_actor_id()
	if uid == "":
		return out
	var u: Dictionary = _units[uid]
	var enemy := first_alive_enemy()
	var acted := bool(u["action_used"])
	# 普攻（11 §4：1 动作）
	out.append({"type": CMD_ATTACK, "skill": "", "item": "", "name": "", "uses": -1, "count": -1,
		"disabled": acted or enemy == "",
		"reason": "action_used" if acted else ("no_target" if enemy == "" else ""),
		"target_kind": "enemy", "default_target": enemy})
	# 技能（次数制，11 §8；target: enemy/self/ally）
	for sk: Variant in (u["skills"] as Array):
		var s: Dictionary = sk
		var sk_id := str(s["id"])
		var uses := int((u["skill_uses"] as Dictionary).get(sk_id, -1))
		var tkind := str(s.get("target", "enemy"))
		var dt := ""
		match tkind:
			"enemy":
				dt = enemy
			"self":
				dt = uid
			"ally":
				dt = first_alive_party()
		var reason := ""
		if acted:
			reason = "action_used"
		elif uses == 0:
			reason = "skill_depleted"
		elif dt == "":
			reason = "no_target"
		out.append({"type": CMD_SKILL, "skill": sk_id, "item": "",
			"name": str(s.get("name", sk_id)), "uses": uses, "count": -1,
			"disabled": reason != "", "reason": reason,
			"target_kind": tkind, "default_target": dt})
	# 道具（附赠动作，tech/04 §4）
	for it: Variant in (u["items"] as Array):
		var d: Dictionary = it
		out.append({"type": CMD_ITEM, "skill": "", "item": str(d["id"]),
			"name": str(d.get("name", d["id"])), "uses": -1, "count": int(d.get("count", 0)),
			"disabled": bool(u["bonus_used"]),
			"reason": "bonus_used" if bool(u["bonus_used"]) else "",
			"target_kind": "ally", "default_target": uid})
	# 急救（11 §5.2：目标须倒地队友）
	var downed := _first_downed_ally_id()
	var fa_reason := ""
	if acted:
		fa_reason = "action_used"
	elif downed == "":
		fa_reason = "no_target"
	out.append({"type": CMD_FIRST_AID, "skill": "", "item": "", "name": "", "uses": -1, "count": -1,
		"disabled": fa_reason != "", "reason": fa_reason,
		"target_kind": "downed_ally", "default_target": downed})
	# 移动（11 §4：每回合一段移动段；按钮等价路径=消耗移动段调整站位，12 §1 铁律）
	out.append({"type": CMD_MOVE, "skill": "", "item": "", "name": "", "uses": -1, "count": -1,
		"disabled": bool(u["move_used"]), "reason": "move_used" if bool(u["move_used"]) else "",
		"target_kind": "cell", "default_target": ""})
	# 结束回合
	out.append({"type": CMD_END_TURN, "skill": "", "item": "", "name": "", "uses": -1, "count": -1,
		"disabled": false, "reason": "", "target_kind": "none", "default_target": ""})
	return out

## 由指令集条目构建同构 Command（tech/01 §6.2 键集恒定）；target 缺省 = default_target（09 §9.2 点按=默认目标）。
func command_from_action(action: Dictionary, target: String = "") -> Dictionary:
	var uid := current_actor_id()
	if uid == "":
		return {}
	return {"type": action["type"], "actor": uid,
		"target": target if target != "" else str(action.get("default_target", "")),
		"skill": str(action.get("skill", "")), "item": str(action.get("item", "")),
		"source": &"player"}

# ---------------------------------------------------------------- 内部工具

func _attr(u: Dictionary, attr: String) -> int:
	return int((u["attrs"] as Dictionary).get(attr, 0))

func _effective_ac(u: Dictionary) -> int:
	var ac := int(u["ac"])
	for st: Variant in (u["statuses"] as Array):
		ac += int((st as Dictionary).get("ac_bonus", 0))
	return ac

func _is_enemy_target(u: Dictionary, target_id: String) -> bool:
	var t: Dictionary = _units.get(target_id, {})
	return not t.is_empty() and t["side"] != u["side"] and not bool(t["dead"])

## 友方目标；need_downed=true 时须为倒地未死（急救），false 时须可行动（道具）。
func _is_ally_target(u: Dictionary, target_id: String, need_downed: bool) -> bool:
	var t: Dictionary = _units.get(target_id, {})
	if t.is_empty() or t["side"] != u["side"] or bool(t["dead"]):
		return false
	return bool(t["downed"]) if need_downed else not bool(t["downed"])

func _find_skill(u: Dictionary, skill_id: String) -> Dictionary:
	for sk: Variant in (u["skills"] as Array):
		if str((sk as Dictionary).get("id", "")) == skill_id:
			return sk
	return {}

func _find_item(u: Dictionary, item_id: String) -> Dictionary:
	for it: Variant in (u["items"] as Array):
		if str((it as Dictionary).get("id", "")) == item_id and int((it as Dictionary).get("count", 0)) > 0:
			return it
	return {}
