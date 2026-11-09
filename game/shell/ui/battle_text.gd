# 战斗日志文案共享格式化（godot-dev §7：禁止复制两份"横屏版/竖屏版"逻辑）
# 两壳的日志带/日志 Tab 消费同一事件流，条目文案只此一处；name_of = 单位 id → 显示名查询。
class_name BattleText
extends RefCounted

static func state_name(st: StringName) -> String:
	return {"enter": "进场", "explore": "探索", "discover": "发现", "combat": "战斗",
		"settle": "结算", "rest": "休整", "exit": "出场"}.get(st, str(st))

## 托管来源标注（09 §9.3：事件流标注来源 auto，可追溯）。
static func src_tag(p: Dictionary) -> String:
	return "（托管）" if str(p.get("source", "")) == "auto" else ""

static func check_text(p: Dictionary, name_of: Callable) -> String:
	match str(p.get("kind", "")):
		"death_save":
			return "%s 死亡豁免：%d → %s（%d胜%d负）" % [name_of.call(str(p["roller"])),
				int(p["keep"]), TextsZh.RESULT_SUCCESS if bool(p["success"]) else TextsZh.RESULT_FAIL,
				int(p.get("s", 0)), int(p.get("f", 0))]
		"save":
			return "%s 豁免：%d%+d=%d vs %d → %s（伤 %d）" % [name_of.call(str(p["roller"])),
				int(p["keep"]), int(p["mod"]), int(p["total"]), int(p["dc"]),
				TextsZh.RESULT_SUCCESS if bool(p["success"]) else TextsZh.RESULT_FAIL,
				int(p.get("damage", 0))]
		"first_aid":
			return "%s 急救 %s：%d → %s" % [name_of.call(str(p["roller"])),
				name_of.call(str(p["target"])), int(p["total"]),
				TextsZh.RESULT_SUCCESS if bool(p["success"]) else TextsZh.RESULT_FAIL]
		"story_check":
			var skill := str(p.get("skill", ""))
			return "检定·%s：%d%+d=%d vs %d → %s" % [str(TextsZh.SKILL_NAMES.get(skill, skill)),
				int(p["keep"]), int(p["mod"]), int(p["total"]), int(p["dc"]),
				TextsZh.RESULT_SUCCESS if bool(p["success"]) else TextsZh.RESULT_FAIL]
	return "检定：%d" % int(p.get("total", 0))

static func attack_text(p: Dictionary) -> String:
	var txt := "%s 攻击 %s：%s" % [p["attacker_name"], p["target_name"],
		"命中 %d 点" % int(p["damage"]) if bool(p["hit"]) else "失手"]
	if bool(p["crit"]):
		txt += "（暴击！）"
	elif bool(p["fumble"]):
		txt += "（大失败）"
	return txt

## 事件 → 日志条目文案；不该入日志的事件类型返回 ""。
static func event_log_text(ev: Dictionary, name_of: Callable) -> String:
	var p: Dictionary = ev.get("payload", {})
	match StringName(ev["type"]):
		EventTypes.STATE_ENTERED:
			return "—— 进入「%s」——" % state_name(StringName(p["state"]))
		EventTypes.COMBAT_START:
			return "战斗开始，先攻序：%s" % " → ".join(p["order"])
		EventTypes.BATTLE_ATTACK:
			return attack_text(p) + src_tag(p)
		EventTypes.CHECK_ROLL:
			return check_text(p, name_of) + src_tag(p)
		EventTypes.SKILL_USE:
			return "%s 发动「%s」%s" % [name_of.call(str(p["unit"])), p["name"], src_tag(p)]
		EventTypes.BATTLE_SKILL:
			# Boss 行为脚本技能（story/03 §2）：召唤/转阶段附明细，AoE 明细由随后 check.roll 豁免条目承载
			var extra := ""
			if p.has("summoned"):
				extra = "：召唤 ×%d" % (p["summoned"] as Array).size()
			elif p.has("attack_mod_after"):
				extra = "（攻击修正 → %+d）" % int(p["attack_mod_after"])
			return "%s 发动「%s」%s%s" % [name_of.call(str(p["unit"])), p["name"], extra, src_tag(p)]
		EventTypes.ITEM_USE:
			return "%s 使用「%s」→ %s（回复 %d）%s" % [name_of.call(str(p["unit"])), p["item"],
				name_of.call(str(p["target"])), int(p["healed"]), src_tag(p)]
		EventTypes.BATTLE_DOWN:
			return "⚠ %s 倒地！" % str(p["name"])
		EventTypes.BATTLE_DEAD:
			return "✝ %s 消散。" % str(p["name"])
		EventTypes.BATTLE_REVIVE:
			return "%s 重新站起（1 HP，%s）。" % [p["name"], p["reason"]]
		EventTypes.COMMAND_REJECTED:
			return "（命令被拒：%s）" % str(p["reason"])
		EventTypes.COMBAT_END:
			return "—— 战斗结束：%s ——" % str(p["result"])
		EventTypes.LOG:
			return str(p.get("msg", ""))
		EventTypes.ITEM_GAIN:
			return "获得物品：%s ×%d" % [p["item_id"], int(p["count"])]
		EventTypes.XP_GAIN:
			return "经验 +%d" % int(p["amount"])
	return ""
