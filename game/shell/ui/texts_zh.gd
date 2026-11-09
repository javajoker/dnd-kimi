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
const CHIP_MOVE := "移动" # 移动段（11 §4；12 §2.1 拖动移动的按钮等价路径）

## 指令集条目 → 芯片/轮盘按钮文案（两壳同源排版；次数余量实时呈现，09 §9.2）。
static func action_label(a: Dictionary) -> String:
	match StringName(str(a.get("type", ""))):
		EncounterSM.CMD_ATTACK:
			return CHIP_ATTACK
		EncounterSM.CMD_MOVE:
			return CHIP_MOVE
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

# 掷骰演出（09 §6；04 §④.7：一切演出可跳过，统一长按 ≥400ms 防误触）
const KEY_ROLL_HINT := "长按任意处跳过演出"
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
const SETTLE_SAVED := "抄本已记录。" # 07 §4.2 结算快照（溯源在代码注释，条款号不上屏，M2 审计 G7）
const SETTLE_ATTR_TITLE := "成长加点（属性点可留到下次整备）"
const SETTLE_ATTR_KEEP := "留到下次整备"

# 通用
const COMMON_BACK := "返回"
const COMMON_WIP := "（最小版：要素随内容接入补全）"

# 节点流程（04 §3.1/§④.2/§④.3、09 §6、tech/02 §3/§5、战役书 §4 N1-1）
const STORY_CONTINUE := "继续"
const STORY_CHECK := "检定"
const MAZE_TITLE := "%s · 探索 %d/%d"          # 迷宫探索序列标题（tech/02 §6 maze；04 §④.3 房间序列）
const MAZE_AMBUSH_PREFIX := "伏击判定｜"        # 伏击拍按钮前缀（tech/02 §6 maze.beats）
const MAZE_LOOT := "拾取：%s ×%d"              # 拾取拍按钮（04 §④.3 拾取房）
const MAZE_BEAT_OK := "检定成功。"
const MAZE_BEAT_FAIL := "检定失败……"
const SKILL_NAMES := {
	"athletics": "运动", "intimidate": "威吓", "stealth": "潜行", "thievery": "巧手",
	"perception": "感知", "investigation": "调查", "history": "历史",
	"persuasion": "交涉", "soothe": "安抚",
	# a_or_b 复合键（11 §2 取高）：显示层映射（M2 审计 G6：复合键不得原样上屏）
	"history_or_perception": "历史/感知",
}
const DIFF_NAMES := {"easy": "易", "medium": "中", "hard": "难"}
const FACTION_NAMES := {"scriptorium": "誊写庭", "uninked": "断墨会", "salvage": "拾遗行会"}
const STORY_CLOCK := "时钟 %d 格"
const STORY_CLOCK_NEXT := "▸ %s %d格"
const STORY_FORECAST_TITLE := "时间边预告" # 04 §3.1（条款号不上屏，M2 审计 G7）
const STORY_FORECAST_EMPTY := "暂无逼近的时间边。"
const STORY_QUEST_BADGE := "事件 %d"
const STORY_SLICE_END := "幕一 · 切片终点"
const SETTLE_SLICE := "切片完成"
# 模式锁定（09 §3：强制是叙事手段；tech/02 §2.1 forced / forced_except）
const STORY_MODE_UNLOCK := "回放到此为止——往后的路，可以用全局的视野走了。"
# 结局屏（tech/02 §9；战役书 §9：结局演出 + 尾声结算合并于 ending 节点）
const ENDING_TITLE := "【结局】%s"
const ENDING_HOOK := "多周目钩子：%s"
const ENDING_NGPLUS := "开始二周目"
const ENDING_HOME := "回主屏"
const ENDING_SAVED := "抄本已记录。" # 07 §4.2 结局快照（同上）
const ENDING_PLAYTHROUGH := "—— 第 %d 周目 完 ——"
const NGPLUS_TOAST := "你带着抄本残页回到潮醒之前。织命者残简 ×1 随行，图鉴与权利如故。"
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
# 兜底条 toggle（12 §5：可收起/展开，默认展开，偏好持久化到本地设置；把手始终可触达）
const HOME_BAR_HINT := "文字入口条"
const HOME_BAR_COLLAPSE := "▾ 收起入口条"
const HOME_BAR_EXPAND := "▴ 展开入口条"
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
const ENTRY_MODE_PICK := "选择这一程的讲述方式（整场战役锁定）" # 09 §3（同上）
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
const QUESTS_ABANDONED := "已放弃（归档历史卷轴）"
const QUESTS_ABANDON := "放弃"
const QUESTS_EMPTY := "（暂无进行中的事件）"

# ⑥ 背包与图鉴（04 §⑥：四重身份筛选 / 图鉴系列进度与集齐奖励预告）
const INV_TITLE := "背包与图鉴"
const INV_BAG := "背包"
const INV_CODEX := "图鉴"
const INV_FILTER_ALL := "全部"
const INV_ROLE_NAMES := { # 四重身份（tech/02 §7 roles；10 §1 标签体系）
	"stat": "数值装备", "check_mod": "检定工具", "branch_key": "分支钥匙", "codex": "图鉴信物",
}
const INV_BRANCH_HINT := "它似乎能在某处派上用场……" # 分支钥匙提示（04 §⑥ 示例句式）
const CODEX_SERIES := { # 系列归世界观层定义（story/01 §9 四大系列；10 §3）
	"weaver_fragments": "织命者残简", "revoked_registry": "被撤销者名录",
	"fate_dice": "命骰考", "ashenport_local": "烬港风物志",
}
const CODEX_REWARDS := { # 集齐奖励预告（世界观 §9 方向；10 §4 白名单，永不卖数值）
	"weaver_fragments": "集齐 → 揭示褪墨真相的隐藏剧情线",
	"revoked_registry": "集齐 → 解锁「追忆」战役（强制竖屏形态）",
	"fate_dice": "集齐 → 骰子外观（纯演出）",
	"ashenport_local": "集齐 → 烬港声望与商店折扣",
}
const CODEX_PROGRESS := "%s：%d/%d"
const CODEX_REWARD_LINE := "　预告：%s"
const CODEX_LOCKED_TITLE := "？？？"

# ⑧ 战报回放（04 §⑧：事件流重演，纯演出不可改结果；最小版 = 节拍日志重演）
const HISTORY_REPLAY := "重演"
const REPLAY_TITLE := "战报重演（纯演出 · 不可改结果）"
const REPLAY_SKIP := "跳过"
const REPLAY_DONE := "—— 重演终 ——"

# 房间回看（04 §④.2：下滑/点按推进条展开已过房间；只读，已完成检定与战斗不重置）
const ROOM_REVIEW_TITLE := "已过房间"
const ROOM_REVIEW_HINT := "（只读回看：已完成的检定与战斗不会重置）"

# 手势反馈（12 §3：抬手落空 = 取消，不产生半状态指令）
const GESTURE_CANCEL := "落空，已取消"
const GESTURE_PATH_AIM := "轨迹：%s → %s"

# ⑦ 角色（04 §⑦）
const CHAR_TITLE := "角色"
const CHAR_BOND := "羁绊"
# 成长区（tech/04 §8）：等级 / XP 进度 / 已分配属性 / 未分配点数
const CHAR_GROWTH := "成长：Lv.%d　经验 %d/%s"
const CHAR_GROWTH_MAX := "成长：Lv.%d　经验 %d（已满级）"
const CHAR_GROWTH_ATTRS := "已分配：力 %+d 敏 %+d 智 %+d　未分配点数：%d"

# 帮助页 · 手势图鉴（12 §4：常驻，主动进入；12 §1/§2 全表）
# 手势层已落地（gesture_recognizer.gd / gesture_layer.gd）：按 12 §1 判定参数全量上屏；
# 铁律同步上屏：一切手势均有按钮等价路径（12 §1）。
const HELP_TITLE := "手势图鉴"
const HELP_RETRAIN := "重学教程"
const HELP_LINES: Array[String] = [
	"点按 = 选择 / 确认（选项、按钮、目标格、目标单位）",
	"点按芯片 / 轮盘 = 对默认目标使用",
	"长按（≥0.4 秒）= 单位 / 道具详情卡；关键判定演出长按跳过",
	"拖动己方单位 = 移动（消耗移动段，拖动中显示落点预览）",
	"拖动轨迹（己方 → 敌方）= 指向性技能：轨迹即弹道预览，松手确认，落空取消",
	"双指点击（战场 / 主视野）= 结束回合 / 普通检定一键快掷",
	"横滑（操作台）= 四 Tab 切换（行动 / 骰子 / 日志 / 角色）",
	"双指捏合 = 战场缩放（全局俯瞰 ↔ 跟随镜头；竖屏松手弹回）",
	"下滑 / 点按（推进条）= 已过房间回看（只读，已完成检定与战斗不重置）",
	"（一切手势均有按钮等价路径——手势是效率层，不是唯一通道）",
]

# 教程三层（12 §4：可跳过、可重学、跳过不丢信息；触发记录写 global.tutorial.*）
const TUT_NEXT := "下一页"
const TUT_SKIP := "跳过"
const TUT_DISMISS := "点任意处继续"
const TUT_CARDS: Array[String] = [
	"【点按】= 选择\n选项、按钮、目标——轻点即定。",
	"【长按】= 详情\n按住单位或道具片刻，展开它的信息卡。",
	"【横滑】= 切换\n在底部操作台左右滑动，切换行动 / 骰子 / 日志 / 角色。",
]
const TUT_HINT_COMBAT := "拖动己方单位 = 移动；拖到敌方 = 轨迹施法；双指点击 = 结束回合；双指捏合 = 缩放战场。"
const TUT_HINT_CHECK := "双指点击 = 一键快掷；点按检定按钮亦可。关键判定演出可长按跳过。"
const TUT_HINT_KEY := "关键判定演出：长按 ≥0.4 秒跳过，跳过不丢信息（内容同步写入日志与卷轴）。"
