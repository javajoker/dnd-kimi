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
const SETTLE_HOME := "回主屏"
const SETTLE_HISTORY := "查看卷轴"
const SETTLE_SAVED := "抄本已记录（结算快照，07 §4.2）"
const SETTLE_ATTR_TITLE := "成长加点（属性点可留到下次整备）"
const SETTLE_ATTR_KEEP := "留到下次整备"

# 通用
const COMMON_BACK := "返回"
const COMMON_WIP := "（最小版：要素随内容接入补全）"

# 节点流程（04 §3.1/§④.2/§④.3、09 §6、tech/02 §3/§5、战役书 §4 N1-1）
const STORY_CONTINUE := "继续"
const STORY_CHECK := "检定"
const SKILL_NAMES := {
	"athletics": "运动", "intimidate": "威吓", "stealth": "潜行", "thievery": "巧手",
	"perception": "感知", "investigation": "调查", "history": "历史",
	"persuasion": "交涉", "soothe": "安抚",
}
const DIFF_NAMES := {"easy": "易", "medium": "中", "hard": "难"}
const FACTION_NAMES := {"scriptorium": "誊写庭", "uninked": "断墨会", "salvage": "拾遗行会"}
const STORY_CLOCK := "时钟 %d 格"
const STORY_CLOCK_NEXT := "▸ %s %d格"
const STORY_FORECAST_TITLE := "时间边预告（04 §3.1）"
const STORY_FORECAST_EMPTY := "暂无逼近的时间边。"
const STORY_QUEST_BADGE := "事件 %d"
const STORY_SLICE_END := "幕一 · 切片终点"
const SETTLE_SLICE := "切片完成"
# Hub（战役书 §4 N1-1：休整 / 商店 / 传闻；04 §3.3 半屏弹层）
const HUB_SHOP := "商店"
const HUB_REST := "休整"
const HUB_RUMOR := "听传闻"
const HUB_GOLD := "金币：%d"
const HUB_CLOSE := "离开"
const HUB_NO_GOLD := "金币不足。"
const HUB_REST_HINT := "休整：恢复全部 HP 与技能次数"
const HUB_RUMOR_NONE := "码头寂静，暂无新传闻。"

# ① 主屏（04 §①）
const HOME_TITLE := "烬港 · 营地"
const HOME_ENTRY_CAMPAIGN := "战役入口"
const HOME_CONTINUE := "继续"
const HOME_ENTRY_QUESTS := "事件中心"
const HOME_ENTRY_INVENTORY := "背包图鉴"
const HOME_ENTRY_CHARACTER := "角色"
const HOME_ENTRY_HISTORY := "历史卷轴"
const HOME_OP_SLOT := "〔运营位〕新内容包筹备中——《烬港残页》后续章节将由投放决定"
const HOME_HELP := "帮助"
const HOME_SAVE := "记录抄本"
const HOME_SAVED := "抄本已记录"
## 营地图景随褪墨度（global.doom_clock 0~10）变化（04 §①：状态板的可视化）。
static func home_doom_text(clock: int) -> String:
	if clock <= 3:
		return "营火尚旺。墨迹在天边，像一场还没下定的雨。"
	if clock <= 6:
		return "街名又淡了一分。营地的人开始把重要的事写在手上。"
	return "褪墨逼近。抄本的纸页发凉——能留下的，只有你写下的部分。"

# ② 战役入口（04 §②、09 §3）
const ENTRY_TITLE := "战役入口"
const ENTRY_START := "开始战役"
const ENTRY_MODE_SPACE := "横屏空间战役"
const ENTRY_MODE_SPACE_DESC := "战术格 · 站位 · 大战场——以全局视野摊开每一幕"
const ENTRY_MODE_TIME := "竖屏时间战役"
const ENTRY_MODE_TIME_DESC := "多房间 · 叙事流 · 单手节奏——一段记忆按自己的节奏展开"
const ENTRY_MODE_PICK := "选择这一程的讲述方式（整场战役锁定，09 §3）"
const ENTRY_MODE_CHOSEN := "已选："
const ENTRY_COLLECT := "分支收集度"
const ENTRY_PLAYED := "已玩模式："
# ② 子游戏卡（04 §6：入口挂战役入口区作特殊战役书卡；pack_type=subgame 数据驱动入列）
const ENTRY_SUBGAME_SECTION := "—— 特殊战役书卡 · 子游戏 ——"
const ENTRY_SUBGAME_TAG := "〔子游戏 · 连战〕"
const SUBGAME_ENTER_TIME := "竖屏参战"
const SUBGAME_ENTER_SPACE := "横屏参战"
const SUBGAME_STATS := "累计胜场 %d · 最佳连战 %d"
const SUBGAME_LEVEL := "建议等级 Lv.%d+"

# ② 锁定态与购买（06 §3.1：可见但锁定、叙事化包装、无"未购买"生硬弹窗；06 §6 + 04 §3.3：半屏弹层购买）
const LOCK_ARENA := "竞技场的守门人只认印记——你的抄本里还没有这一页。"
const LOCK_ACQUIRE := "获取"
const SHOP_TITLE := "守门人的印龛"
const SHOP_CONFIRM := "确认获取"
const SHOP_CANCEL := "再想想"
## 购买弹层文案（叙事化包装：商品名 + 价格 + 一句叙事；购买即解锁无需重启，06 §3.1）。
static func shop_line(pack_name: String, price_text: String) -> String:
	return "《%s》——%s。守门人收下印记，擂台的门就会为你翻开。" % [pack_name, price_text]

# 整备（09 §9.1）
const LOADOUT_TITLE := "整备"
const LOADOUT_SKILLS := "技能备选（%d 选 %d）"
const LOADOUT_ITEMS := "道具携带（槽位 %d）"
const LOADOUT_ATTRS := "未分配属性点：%d"
const LOADOUT_CONFIRM := "确认出发"
const LOADOUT_FULL := "（槽位已满）"

# ⑧ 历史卷轴（04 §⑧）
const HISTORY_TITLE := "历史卷轴"
const HISTORY_KEY_MARK := "★ 关键判定"
const HISTORY_EMPTY := "（尚无条目）"
const HISTORY_PROV := "来源：%s · %s"

# ⑤ 事件中心（04 §⑤）
const QUESTS_TITLE := "事件中心"
const QUESTS_ACTIVE := "进行中"
const QUESTS_DONE := "已完结（归档历史卷轴）"
const QUESTS_EMPTY := "（暂无进行中的事件）"

# ⑥ 背包与图鉴（04 §⑥）
const INV_TITLE := "背包与图鉴"
const INV_BAG := "背包"
const INV_CODEX := "图鉴"

# ⑦ 角色（04 §⑦）
const CHAR_TITLE := "角色"
const CHAR_BOND := "羁绊"

# 帮助页 · 手势图鉴（12 §4：常驻，主动进入；§1~§2 全表摘要）
const HELP_TITLE := "手势图鉴"
const HELP_LINES: Array[String] = [
	"点按 = 选择 / 默认目标使用（芯片、轮盘、单位）",
	"长按 = 查看详情（单位信息、道具详情）",
	"横滑 = 切换页签（操作台四 Tab）",
	"双指点击 = 快掷 / 结束回合",
	"双指捏合 = 缩放战场（横屏）",
	"拖动芯片到目标 = 指定目标使用",
	"（教程可跳过、可重学、跳过不丢信息，12 §4）",
]
