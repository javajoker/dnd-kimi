# 事件类型常量集（godot-dev §4：事件类型用 StringName 常量集中于此）
# 语义依据：docs/framework/07-世界状态机规范.md §6（状态板变化对应事件）、
# docs/tech/01-技术方案讨论稿.md §5.1（type 示例）。
class_name EventTypes
extends RefCounted

# 检定 / 战斗
const CHECK_ROLL := &"check.roll"
const BATTLE_ATTACK := &"battle.attack"
const BATTLE_DOWN := &"battle.down"      # 单位倒地（11 §5.2/§7）
const BATTLE_DEAD := &"battle.dead"      # 单位死亡（11 §7 三负）
const BATTLE_REVIVE := &"battle.revive"  # 扶起/稳住/战后起身（11 §5.2/§7）
const SKILL_USE := &"skill.use"          # 次数制技能扣次（11 §8）

# 遭遇状态机（09 §1 约定：状态切换以 state.entered 事件外发，渲染壳只订阅、不被指挥）
const STATE_ENTERED := &"state.entered"
const COMBAT_START := &"combat.start"    # 先攻序列落定（11 §5）
const COMBAT_END := &"combat.end"        # 一方全灭/撤退边/目标达成（09 §1）
const TURN_START := &"turn.start"        # 回合/阶段轮转
const COMMAND_REJECTED := &"command.rejected"  # 非法意图拒绝（tech/01 §6.2：不污染逻辑状态）

# 状态板写入（07 §6：flag.written / clock.tick / rep.changed ……）
const FLAG_WRITE := &"flag.write"
const CLOCK_TICK := &"clock.tick"
const REP_CHANGE := &"rep.change"
const BOND_CHANGE := &"bond.change"
const ALIGNMENT_SHIFT := &"alignment.shift"
const ENTITLEMENT_CHANGE := &"entitlement.change"

# 物品
const ITEM_GAIN := &"item.gain"
const ITEM_REMOVE := &"item.remove"
const ITEM_USE := &"item.use"

# 故事图
const NODE_ENTER := &"node.enter"
const STORY_TRIGGER := &"story.trigger"  # doom_clock 时间边触发（tech/02 §4.4）
const STORY_ENDING := &"story.ending"    # 结局选定（tech/02 §9）

# 成长 / 图鉴（tech/02 §4.6 效果词汇）
const XP_GAIN := &"xp.gain"        # xp 在 07 无落板键，只进事件流（待裁决，属 tech/04 成长系统）
const LORE_UNLOCK := &"lore.unlock"  # lore 落板 global.lore（07 §2 约束）时由 Board 产出

# 框架告警（不静默原则，07 §2 约束）
const CLAMPED := &"clamped"        # 写入越界被钳位
const BOARD_DENIED := &"board.denied"  # 命名空间越权写入被拒绝

# 通用日志
const LOG := &"log"
