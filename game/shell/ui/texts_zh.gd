# UI 文案集中（godot-dev §4；tech/02 §7 i18n 预留：首版内嵌中文，键名即文本 ID）
class_name TextsZh
extends RefCounted

# 操作台四 Tab（04 §④.5）
const TAB_ACTION := "行动"
const TAB_DICE := "骰子"
const TAB_LOG := "日志"
const TAB_CHAR := "角色"

# 快捷栏芯片（09 §9.2）
const CHIP_ATTACK := "攻击"
const CHIP_FIRST_AID := "急救"
const CHIP_END_TURN := "结束回合"

## 指令集条目 → 芯片/轮盘按钮文案（两壳同源排版；次数余量实时呈现，09 §9.2）。
static func action_label(a: Dictionary) -> String:
	match StringName(str(a.get("type", ""))):
		EncounterSM.CMD_ATTACK:
			return CHIP_ATTACK
		EncounterSM.CMD_SKILL:
			var label := str(a.get("name", a.get("skill", "")))
			if int(a.get("uses", -1)) >= 0:
				label += " ×%d" % int(a["uses"])
			return label
		EncounterSM.CMD_ITEM:
			return "%s ×%d" % [str(a.get("name", a.get("item", ""))), int(a.get("count", 0))]
		EncounterSM.CMD_FIRST_AID:
			return CHIP_FIRST_AID
		EncounterSM.CMD_END_TURN:
			return CHIP_END_TURN
	return str(a.get("name", "?"))

# 托管（09 §9.3）
const AUTO_ON := "托管"
const AUTO_OFF := "接管"

# ☰ 单局菜单（09 §7）
const MENU := "☰"
const MENU_CONTINUE := "继续"
const MENU_SAVE_QUIT := "保存并回主屏"
const MENU_HELP := "手势帮助"
const MENU_CONFIRM_QUIT := "确认退出？本局进度将丢失（遭遇进行中不存档）"

# 掷骰演出（09 §6）
const KEY_ROLL_HINT := "点击任意处跳过"
const RESULT_SUCCESS := "成功"
const RESULT_FAIL := "失败"
const RESULT_CRIT := "大成功！"
const RESULT_FUMBLE := "大失败…"

# 横屏五区（04 §③、09 §4）
const ZONE_WHEEL := "行动轮盘"
const ZONE_DICE := "骰子盘"
const LOG_EXPAND := "日志 ▴"
const LOG_COLLAPSE := "收起 ▾"

# 结算（04 §⑨）
const SETTLE_TITLE := "遭遇结算"
const SETTLE_VICTORY := "胜利"
const SETTLE_DEFEAT := "失败"
const SETTLE_RETREAT := "撤退"
const SETTLE_QUIT := "退出"
