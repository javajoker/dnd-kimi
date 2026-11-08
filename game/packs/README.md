# game/packs —— 运行时内容包副本

> 格式契约：`docs/tech/02-内容包格式规范.md` §1（包目录结构）。

## 同步关系

- **编写源**：`docs/story/<pack_id>/`（战役）；子游戏编写源为 `docs/subgames/<子游戏名>/pack/`（README 目录约定）；
- **运行时副本**：`game/packs/<pack_id>/`（加载器与仿真只读本目录）；
- 两者必须逐字节一致：改内容先改 docs 源，再 `cp <源>/*.json game/packs/<pack_id>/` 同步；
- 一致性由 CI / packlint 前置步骤保证（TP1 阶段人工执行）；发布时按 tech/01 §8 将本目录打包为 PCK。

## 当前包

| 包 | 源 | 说明 |
|---|---|---|
| campaign01 | `docs/story/campaign01/` | 《烬港残页》首个战役实例 |
| arena | `docs/subgames/arena/pack/` | 子游戏「竞技场连战」（pack_type=subgame，M3 验证白皮书 §10.2） |
