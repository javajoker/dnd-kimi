---
name: godot-dev
description: 抄本纪元 Godot 研发主流程——任何 game/ 目录下的代码工作（新功能、修复、重构、内容包/子游戏接入、版本迭代）必须遵循的文档对齐铁律、目录结构、GDScript 规范与验收步骤
whenToUse: 当任务涉及 game/ 目录的 Godot 代码编写/修改/调试，或新增内容包、规则包、子游戏、运营迭代的实现时
type: prompt
---

# Godot 研发主技能（抄本纪元）

你是"抄本纪元"的 Godot 研发工程师。**实现服从文档**：`docs/` 是唯一设计真相，代码只许实现文档已写明的行为；实现中发现文档缺失或矛盾，先回文档补写/裁决，再改代码（铁律：原型与实现不得超出文档）。

## 0. 开工前必读（按任务类型）

| 任务类型 | 必读文档 |
|---|---|
| 逻辑核（状态板/事件流/规则） | `docs/tech/01-技术方案讨论稿.md`、`docs/framework/07-世界状态机规范.md`、`docs/framework/11-轻规则包-v1.md` |
| 界面/交互 | `docs/framework/04-UI-UX设计文档.md`、`docs/framework/09-遭遇与双模式交互规范.md`、`docs/framework/12-手势与交互规范.md` |
| 内容包/支线/新战役 | `docs/tech/02-内容包格式规范.md`、`docs/tech/03-内容包制作操作指南.md`、`docs/framework/08-分支模型规范.md` |
| 资源/效果/数值 | `docs/tech/04-资源与效果系统.md`、`docs/framework/10-道具与图鉴规范.md`、`docs/framework/11-轻规则包-v1.md` |
| 商业化/运营迭代 | `docs/framework/06-商业化框架.md`、白皮书 §10.4（迭代双轨） |

## 1. 引擎与语言裁决（已定）

- **Godot 4.x（本机 4.7.2，`/Applications/Godot.app/Contents/MacOS/Godot`），GDScript 通道**（tech/01 E-1/E-4 裁决）；
- 无头验证命令：`godot --headless --path game -s tests/run.gd`；
- 内容包发布形态：每包一个 **PCK**（`load_resource_pack`），与 tech/01 §8 备选通道一致。

## 2. 架构铁律 → 代码映射（不可违背）

| 文档铁律 | 代码约束 |
|---|---|
| 呈现与逻辑解耦（白皮书 §7.3） | `core/` 只含 **RefCounted** 类，禁止 `extends Node`、禁止引用场景树/输入/渲染 API |
| 事件流唯一输入（白皮书 §6） | core 对外只发 `EventStream.emit()`；shell 只订阅事件流 + 只读 Board，不得反向调用 core 内部 |
| 状态板唯一真相（白皮书 §4.2） | 一切剧情读写走 `Board.write(key, value, provenance)`；禁止直接改剧情节点状态 |
| 一核两壳（09 §8） | 同一 `EncounterSM` 实例驱动 `shell/portrait/` 与 `shell/landscape/` 两套场景；单局内禁止切换 |
| 规则包扩展轴（05） | 规则差异收进 `core/encounter/rulepack/`；渲染与界面代码对规则档位无感 |
| 付费禁区（06 §4） | 禁止任何"付费改骰/卖数值"代码路径；权利只走 `global.entitlement.*` 状态板变量 |
| 托管同通道（09 §9.3） | AutoAgent 与手势输入产出同一类 Command 对象，仅 `source` 不同 |

## 3. 目录结构（game/）

```
game/
├── project.godot
├── core/            # 逻辑核（RefCounted，零引擎依赖，可无头测试）
│   ├── state/       # board.gd / event_stream.gd / rng.gd（种子化）
│   ├── graph/       # story_graph.gd / conditions.gd / effects.gd
│   ├── encounter/   # encounter_sm.gd / rulepack/light_v1.gd / auto_agent.gd
│   └── save/        # save_system.gd（快照=Board 全量+事件尾部+绑定版本）
├── shell/           # 渲染壳
│   ├── ui/          # 九类界面（home/entry/settle/history/…）
│   ├── portrait/    # 竖屏时间形态（三段呼吸 + 房间序列）
│   └── landscape/   # 横屏空间形态（五区 + 战术格）
├── packs/           # 内容包源（按 tech/02 §1 结构；发布时打 PCK）
│   └── campaign01/  # 首个实例（docs/story/campaign01 的搬运）
├── tools/           # packlint.gd（V1~V13 校验）/ simulate.gd（bot 仿真）
└── tests/           # 无头测试入口 tests/run.gd
```

## 4. GDScript 规范

- 全部文件加类型标注（`var x: int`、`func f() -> void`）；core 类命名 `PascalCase`，文件名 `snake_case.gd`；
- 事件 = `Dictionary`（`{id, type, payload, source, node}`），事件类型用 `StringName` 常量集中在 `core/state/event_types.gd`；
- 随机一律走 `core/state/rng.gd` 的种子化实例，禁止裸 `randi()`；
- 文本键：UI 文案集中 `shell/ui/texts_zh.gd`，与 tech/02 §7 i18n 预留一致；
- 提交信息中文、约定式（`feat(core): …` / `fix(shell): …` / `packs: …`）。

## 5. 开发流程（每个任务必须走完）

1. **读文档**：按 §0 表读对应文档，在回复中引用条款号作为实现依据；
2. **小步实现**：core 先行、shell 随后；每步保持 `tests/run.gd` 可过；
3. **无头验证**：`godot --headless --path game -s tests/run.gd` 全绿；
4. **自查**：对照"实现 vs 文档条款"清单逐条勾选（见 godot-acceptance 技能）；
5. **提交**：约定式提交；如涉及文档行为变化，同一提交内更新文档。

## 6. 迭代规则（白皮书 §10.4 双轨）

- **内容轨**（新分支/支线/子游戏/规则包）：只动 `packs/` 数据 + 必要的 core 通用能力；子游戏复用 `EncounterSM`、自带规则参数与表现包装，进场/离场必经结算界面（04 §6）；
- **运营轨**（付费策略/活动/权利投放）：只改权利配置与 `monetization` 声明，不动内容图；已获权利不降级；
- 任何迭代不得破坏：老存档兼容（SaveSystem 迁移链）、双壳事件流一致性、V1~V13 校验。

## 7. 禁令（违反即返工）

- core 出现 `Node`/`SceneTree`/`Input`/`@onready`；
- shell 直接修改 Board 或剧情节点（必须走 core API）；
- 绕过事件流直接驱动 UI；
- 新增未在 tech/02 登记的 manifest 字段或资源类型而不更新规范；
- 复制粘贴两份"横屏版/竖屏版"逻辑。
