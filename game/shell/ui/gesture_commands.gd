# 手势 → 同构 Command 映射（12 §2 场景映射；09 §9.3 托管同通道；godot-dev §7 禁止双壳各写一份）
# 双壳手势处理器唯一出口：一切手势指令经这里产出与芯片/轮盘完全同构的 Command 对象
# （{type, actor, target, skill, item, source}），再由壳走 _manual → EncounterSM.submit_command。
# 纯映射、零状态：不读板、不写板、不产事件（合法性与效果判定全部在 core）。
class_name GestureCommands
extends RefCounted

## 双指点击战场 = 结束回合（12 §2.1/§2.2）。非友方阶段返回空命令（提交即被拒，不产生半状态）。
static func end_turn(sm: EncounterSM) -> Dictionary:
	var uid := sm.current_actor_id()
	if uid == "":
		return {}
	return {"type": EncounterSM.CMD_END_TURN, "actor": uid, "target": "",
		"skill": "", "item": "", "source": &"player"}

## 拖动轨迹（己方 → 敌方）= 指向性技能（12 §2.1：起点=施法者，终点=目标）：
## 取当前行动单位首个可用的敌指向攻击技能，无则退普攻（与托管策略链同一优先级，09 §9.3）。
static func cast_at(sm: EncounterSM, target_id: String) -> Dictionary:
	var uid := sm.current_actor_id()
	if uid == "" or target_id == "":
		return {}
	for a: Dictionary in sm.get_available_actions():
		if a["type"] == EncounterSM.CMD_SKILL and str(a["target_kind"]) == "enemy" \
				and not bool(a["disabled"]):
			return sm.command_from_action(a, target_id)
	for a: Dictionary in sm.get_available_actions():
		if a["type"] == EncounterSM.CMD_ATTACK and not bool(a["disabled"]):
			return sm.command_from_action(a, target_id)
	return {}

## 拖动己方单位 = 移动（12 §2.1/§2.2：消耗移动段）。dest = 呈现层落点描述（"x,y" 格位或站位词），
## 仅随事件溯源（core 不校验距离，≤6 格与可达性由壳在拖动预览层约束，11 §4）。
static func move_to(sm: EncounterSM, dest: String) -> Dictionary:
	var uid := sm.current_actor_id()
	if uid == "":
		return {}
	return {"type": EncounterSM.CMD_MOVE, "actor": uid, "target": dest,
		"skill": "", "item": "", "source": &"player"}
