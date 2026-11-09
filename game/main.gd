# 节点流程版流程控制器（tech/01 §10；04 §2 导航闭环 + §3.1/§④.2/§④.3；07 §4 存档；09 §3/§6/§7/§9.1；tech/02 §3/§4/§5）
# 串流：①主屏 → ②战役入口（模式分支，09 §3）→ **故事图驱动节点流程**（序章 N0-1 → … → 终章 E1~E4）：
#   scene/check/dialog/hub 节点由双壳故事态呈现（StoryVM 单源）；battle 节点进整备→遭遇→战后边回图；
#   强制幕（SL-0/SL-3）按 presentation.forced 换壳并以叙事化提示呈现（09 §3；N3-7 起 forced_except 解锁）；
#   结局节点 → 结局屏（tech/02 §9：四分型文案 + 多周目钩子 + 开始二周目）→ NG+ / 回主屏 / ⑧历史卷轴。
# 存档时机（07 §4.2）：切片/遭遇结算完成（主快照）+ 主屏闲置（兜底）+ 主屏手动"记录抄本"；
# 遭遇进行中不存档——☰「保存并回主屏」= 恢复遭遇进入前快照（09 §7，战斗重打）；
# 故事态（遭遇外）☰ = 存档后回主屏（节点进度在图快照 meta.graph 内）。
# 战斗数值由 packs 资源表驱动（tech/04 §1~§4 / tech/02 §6）：BattleDef.assemble 组装，引用缺失 fail-fast。
# 调试：`-- --m2n-shots` 走图截图 /tmp/m2n_*.png（不提交）；`-- --m3-shots` 子游戏截图；
# `-- --m4-shots` 锁定态/购买弹层截图；`-- --mode=space|time` 预选形态。
extends Node

const BATTLE_SEED := 20260009 # 固定种子（tech/01 §5.2 确定性）：本切片主线两次检定均为成功路
# 本切片范围：完整战役 M1（序章 → 幕一 → 幕二四链 → 幕三撤销区房间序列 → 终章 Boss/抉择/结局）；
# 结局节点（E1~E4）进结局屏（tech/02 §9），战斗失败仍走 ⑨ 结算（失败即分支，09 §7）。
const SLICE_ACTS: Array[String] = ["SL-0", "SL-1", "SL-2", "SL-3", "SL-4"]
const LANDSCAPE_SIZE := Vector2i(1280, 720)
const PACK_DIR := "res://packs/campaign01"
const SHELL_SCENES := {
	&"time": "res://shell/portrait/encounter_portrait.tscn",
	&"space": "res://shell/landscape/encounter_landscape.tscn",
}
const SCREEN_SCENES := {
	&"home": "res://shell/ui/screen_home.tscn",
	&"entry": "res://shell/ui/screen_entry.tscn",
	&"loadout": "res://shell/ui/screen_loadout.tscn",
	&"settle": "res://shell/ui/screen_settle.tscn",
	&"history": "res://shell/ui/screen_history.tscn",
	&"quests": "res://shell/ui/screen_quests.tscn",
	&"inventory": "res://shell/ui/screen_inventory.tscn",
	&"character": "res://shell/ui/screen_character.tscn",
	&"ending": "res://shell/ui/screen_ending.tscn",
}
var stream: EventStream
var board: Board
var rng: Rng
var entitlements: Entitlements      # 权利模型运行时（06 §2：商店/活动/成就三类点亮方）
var ops_config: Dictionary = {}     # 运营侧配置（06 §3.2：点亮在运营，不进内容包管线）
var graph: StoryGraph
var pack: Dictionary = {}
var router := ShellRouter.new()
var current_screen: Control = null
var shell: Control = null

# ---- 子游戏（白皮书 §10.2；04 §6：入口挂 ② 战役入口区，进出场必经 ⑨ 结算）----
var _subgames: Dictionary = {}        # pack_id -> pack（pack_type=subgame 数据驱动入列，不写死 arena）
var _sub: SubgameRunner = null        # 进行中的子游戏流程核
var _sub_active := false
var _sub_battling := false
var _sub_mode: StringName = &""
var _sub_tail := 0                    # 子游戏开始锚点（结算汇总区间，04 §⑨）
var _sub_snapshot: Dictionary = {}    # 子游戏遭遇进入前快照（09 §7 ☰ 恢复点）

var _cli_mode: StringName = &""
var _in_encounter := false
var _encounter_snapshot: Dictionary = {} # 遭遇进入前快照（09 §7 ☰ 回主屏恢复点）
var _encounter_tail := 0                 # 遭遇开始时的事件锚点（结算汇总区间）
var _campaign_tail := 0                  # 战役开始锚点（切片结算汇总区间）
var _encounter_result: StringName = &""
var _encounter_id := ""                  # 当前战斗节点的遭遇 id（tech/02 §6）
var _battle_title := ""
var _battles_won := 0
var _mode: StringName = &""
# ---- 迷宫探索序列（tech/02 §6 maze；04 §④.3 房间类型序列化）----
var _maze: MazeRunner = null      # 进行中的探索序列核（core 渐进执行，壳只呈现）
var _maze_outcome := ""           # 上一拍结果摘要（拼进下一拍文本）
var _history_origin: StringName = &"home"
var _settle_lines: Array[String] = [] # 结算汇总缓存（卷轴往返 / 加点刷新复用）
var _shots := false

func _ready() -> void:
	_setup_cjk_font()
	var args := OS.get_cmdline_user_args()
	_shots = args.has("--m2n-shots")
	_cli_mode = ShellRouter.cli_mode(args) if args.has("--mode=space") or args.has("--mode=time") else &""
	var res := PackLoader.load_pack(PACK_DIR)
	if not res["ok"]:
		push_error("campaign01 加载失败：%s" % ";".join(res["errors"]))
		return
	pack = res["pack"]
	_discover_subgames()
	stream = EventStream.new()
	board = Board.new(stream)
	rng = Rng.new(BATTLE_SEED)
	# 权利运行时 + 运营配置（06 §3.2：活动开关开 → 入口自动解锁，内容包零改动）
	entitlements = Entitlements.new(board, stream)
	ops_config = Entitlements.load_ops_config()
	entitlements.apply_activities(ops_config)
	graph = StoryGraph.new(board, rng, pack)
	stream.subscribe(_on_event)
	_show_home()
	if _shots:
		_run_shots_m2n()
	if args.has("--m3-shots"):
		_run_shots_m3()
	if args.has("--m4-shots"):
		_run_shots_m4()
	if args.has("--growth-shots"):
		_run_shots_growth()
	if args.has("--act2-shots"):
		_run_shots_act2()
	if args.has("--act3-shots"):
		_run_shots_act3()
	if args.has("--gap-shots"):
		_run_shots_gap()
	if args.has("--home-shot"):
		_run_shot_home()
	if args.has("--home-bar-shot"):
		_run_shot_home_bar()

## 子游戏包发现（白皮书 §10.2/§10.3）：扫描 packs/ 全部包目录，pack_type=subgame 即入列——
## 数据驱动，不写死 arena；加载失败只告警不阻断（单包缺陷不拖垮框架，tech/02 §1 向前兼容）。
func _discover_subgames() -> void:
	var dir := DirAccess.open("res://packs")
	if dir == null:
		return
	for sub: String in dir.get_directories():
		if sub.begins_with("_"):
			continue # _ops 等运营目录非内容包（06 §3.2：运营配置不进内容包管线）
		if sub == str(pack.get("pack_id", "")):
			continue
		var res := PackLoader.load_pack("res://packs/%s" % sub)
		if not res["ok"]:
			push_warning("[main] 包 %s 加载失败（跳过）：%s" % [sub, ";".join(res["errors"])])
			continue
		var p: Dictionary = res["pack"]
		if str((p["manifest"] as Dictionary).get("pack_type", "")) == "subgame":
			_subgames[str(p["pack_id"])] = p

# ---------------------------------------------------------------- 导航（04 §2/§5：任何界面有明确来路退路）

func _swap(screen: Control) -> void:
	if current_screen != null and current_screen != shell:
		current_screen.queue_free()
	elif shell != null:
		shell.visible = false
	current_screen = screen
	add_child(screen)

func _show_home() -> void:
	_in_encounter = false
	_sub_active = false # 回主屏即子游戏离场（04 §6：离场必经结算，未到结算即放弃本次连战）
	_sub_battling = false
	_sub = null
	if shell != null: # 壳随离场回收（09 §7 结算态之后为正常离场）
		shell.queue_free()
		shell = null
	var home: ScreenHome = (load(SCREEN_SCENES[&"home"]) as PackedScene).instantiate()
	_swap(home)
	home.bind(board, graph.quest_badge_count(), _has_continuable())
	home.navigate.connect(_on_home_navigate)
	home.save_requested.connect(_save_home)
	home.idle_timeout.connect(_save_idle)
	home.tutorial_done.connect(func() -> void: _tutorial_mark("boot")) # 启动卡一次性（12 §4）
	home.retrain_requested.connect(_on_retrain) # 重学入口（12 §4：可重学）
	if not bool(board.read("global.tutorial.boot", false)):
		home.show_launch_tutorial() # 首次启动 3 页核心手势卡（12 §4 第一层）
	router = ShellRouter.new() # 回主屏即离场：壳锁定随单局结束（09 §8）

## 教程触发记录（12 §4：写 global.tutorial.<id>，一次原则，不因重开重复打扰）。
func _tutorial_mark(id: String) -> void:
	board.write("global.tutorial.%s" % id, true,
		{"event_id": stream.tail(), "node_id": graph.current_id, "pack_id": "system"})

func _tutorial_seen(id: String) -> bool:
	return bool(board.read("global.tutorial.%s" % id, false))

## 重学：清全部教程触发记录（重放启动卡 + 情境提示恢复一次），再重放启动卡（12 §4）。
func _on_retrain() -> void:
	for key: String in board.keys_with_prefix("global.tutorial."):
		board.write(key, false, {"event_id": stream.tail(), "node_id": graph.current_id,
			"pack_id": "system"})
	_show_home()
	if current_screen is ScreenHome:
		(current_screen as ScreenHome).show_launch_tutorial()

## 情境教程（12 §4 第二层：首次进入某情境，每类一次；半透明遮罩+高亮，非模态）。
func _context_hint(id: String, text: String) -> void:
	if _tutorial_seen(id):
		return
	if shell != null and shell.has_method("show_tutorial_hint"):
		shell.call("show_tutorial_hint", id, text)
	_tutorial_mark(id)

func _on_home_navigate(screen_id: StringName) -> void:
	match screen_id:
		&"entry":
			_show_entry()
		&"quests":
			_show_quests()
		&"inventory":
			_show_inventory()
		&"character":
			_show_character()
		&"history":
			_history_origin = &"home"
			_show_history()

func _show_entry() -> void:
	var entry: ScreenEntry = (load(SCREEN_SCENES[&"entry"]) as PackedScene).instantiate()
	_swap(entry)
	var played: Array = []
	var played_raw: Variant = board.read("global.mode_choice.campaign01")
	if played_raw is String and str(played_raw) != "":
		played.append(str(played_raw))
	entry.bind(pack, played, _collect_pct())
	entry.mode_chosen.connect(_on_mode_chosen)
	entry.start_requested.connect(_on_campaign_start.bind(entry))
	entry.back_requested.connect(_show_home)
	# 子游戏卡（04 §6 特殊战役书卡）：manifest 数据驱动（名称/建议等级/模式/战绩键）；
	# 权利门槛未点亮 → 锁定态卡（06 §3.1：可见但锁定 + 叙事化文案 +「获取」）
	var cards: Array = []
	for pid: String in _subgames:
		var p: Dictionary = _subgames[pid]
		var manifest: Dictionary = p["manifest"]
		var runner := SubgameRunner.new(p, board, stream, rng)
		cards.append({"pack_id": pid, "name": str(manifest.get("name", pid)),
			"level_min": int((manifest.get("recommended_level", [1]) as Array)[0]),
			"mode": str((manifest.get("presentation", {}) as Dictionary).get("mode", "choice")),
			"stats": runner.stats(),
			"locked": not entitlements.can_access(manifest),
			"lock_text": TextsZh.LOCK_ARENA})
	entry.bind_subgames(cards)
	entry.subgame_start.connect(_on_subgame_start)
	entry.acquire_requested.connect(_on_acquire_requested)
	entry.shop_popup.purchase_confirmed.connect(_on_purchase_confirmed)
	if _cli_mode != &"":
		entry.pick_mode(_cli_mode)
	elif not played.is_empty():
		entry.pick_mode(StringName(str(played[0]))) # 已选模式预选（09 §3 整场锁定；04 §② 已玩标记）

func _on_mode_chosen(mode: StringName) -> void:
	# 模式选择 = 一次分支，写入状态板（09 §3）；全局白名单键（07 §3 v1.1）
	board.write("global.mode_choice.campaign01", String(mode),
		{"event_id": stream.tail(), "node_id": graph.current_id, "pack_id": "campaign01"})

func _on_campaign_start(entry: ScreenEntry) -> void:
	_mode = entry.selected_mode
	if _mode == &"":
		return
	if graph.is_at_ending():
		_on_ngplus_start() # 已通关战役再开 = 多周目（战役书 §9：结局屏外同一继承语义）
		return
	if not graph.visit_log.is_empty():
		_present_node() # 战役进行中：继续当前节点（主屏"继续"语义，04 §①）
		return
	_start_campaign()

## 战役开局：播种金币（hub 商店）→ 序章带入补给 → 从入口节点真实走图（tech/02 §3）。
func _start_campaign() -> void:
	_campaign_tail = stream.tail()
	graph.seed_gold()
	graph.start()
	# 序章带入（叙事既定）：补给药水 ×2（战役书 §4 SL-1；items.json source 登记）
	board.give_item("heal_potion", 2,
		{"event_id": stream.tail(), "node_id": "N1-1", "pack_id": "campaign01"})
	_present_node()

# ---------------------------------------------------------------- 节点流程（故事图驱动；UI 只消费 StoryVM + 事件流）

## 呈现当前节点：ending → 结局屏（tech/02 §9）；battle → 整备/遭遇；
## explore（迷宫探索序列，tech/02 §6 maze）→ 逐拍呈现；出切片范围 → 切片结算；其余 → 双壳故事态。
func _present_node() -> void:
	if graph.is_at_ending():
		_present_ending()
		return
	if not SLICE_ACTS.has(str(graph.current().get("act", ""))):
		_end_slice()
		return
	var ntype := str(graph.current().get("type", ""))
	if ntype == "battle":
		_enter_encounter()
		return
	if ntype == "explore" and _maze_pending():
		_enter_maze()
		return
	_present_story_node()

func _present_story_node() -> void:
	var vm := StoryVM.build(graph, board, pack)
	_ensure_story_shell()
	_story_show(vm)
	# 情境教程：首次检定（12 §4：双指点击快掷；可跳过不丢信息）
	for e: Variant in vm["edges"]:
		if bool((e as Dictionary).get("check", false)):
			_context_hint("first_check", TextsZh.TUT_HINT_CHECK)
			break

func _story_show(vm: Dictionary) -> void:
	if shell is EncounterPortrait:
		(shell as EncounterPortrait).show_story(vm)
	elif shell is EncounterLandscape:
		(shell as EncounterLandscape).show_story(vm)

## 当前节点要求的壳形态（tech/02 §2.1：forced 按幕强制、forced_except 幕内节点级例外——
## 战役书幕三：SL-3 强制竖屏，N3-7 空白广场起恢复玩家所选形态"此处起解锁横屏"；09 §3 强制是叙事手段）。
func _story_mode() -> StringName:
	var pres: Dictionary = (pack.get("manifest", {}) as Dictionary).get("presentation", {})
	var act := str(graph.current().get("act", ""))
	var forced: Dictionary = pres.get("forced", {})
	if forced.has(act):
		var exempt: Array = (pres.get("forced_except", {}) as Dictionary).get(act, [])
		if not exempt.has(graph.current_id):
			return StringName(str(forced[act]))
	return _mode

func _shell_mode() -> StringName:
	if shell is EncounterPortrait:
		return ShellRouter.MODE_TIME
	if shell is EncounterLandscape:
		return ShellRouter.MODE_SPACE
	return &""

## 故事壳就位：实例化/复用同一壳（09 §8 一局一壳），绑定故事回调（唯一指令通道）。
## 强制幕换壳（09 §3 内容驱动，非玩家切换——router 的玩家切换锁不变）：形态不一致即重建壳，
## 并以叙事化提示呈现（09 §3：禁止系统腔；锁定用 NOTICE_FORCED，解锁用 TextsZh.STORY_MODE_UNLOCK）。
func _ensure_story_shell() -> void:
	var want := _story_mode()
	var notice := ""
	if shell != null and _shell_mode() != want:
		shell.queue_free()
		shell = null
		router = ShellRouter.new() # 换壳重开一局壳锁定（09 §8：锁管玩家切换，不管内容驱动换壳）
		notice = str(ShellRouter.NOTICE_FORCED.get(want, "")) if want != _mode \
			else TextsZh.STORY_MODE_UNLOCK
	if shell == null:
		shell = (load(SHELL_SCENES[want]) as PackedScene).instantiate()
		add_child(shell)
		shell.set("on_save_quit", Callable(self, "_on_save_quit"))
		if want == ShellRouter.MODE_SPACE and DisplayServer.get_name() != "headless":
			get_window().size = LANDSCAPE_SIZE
			get_window().move_to_center()
		router.lock_encounter(want) # 形态整场锁定（09 §3/§8：战役开始即定壳）
	if current_screen != null and current_screen != shell:
		current_screen.queue_free()
	current_screen = shell
	shell.visible = true
	shell.bind_story(stream, board, pack, {"edge": _on_story_edge, "hub": _on_hub_action})
	if notice != "": # 换壳提示在新壳订阅事件流之后发出（事件流驱动 toast，壳只订阅）
		stream.emit(EventTypes.LOG, {"msg": notice, "toast": true}, &"core", graph.current_id)

## 玩家执行节点选项：check 边真实掷骰（11 §3，check.roll 事件驱动两级演出 09 §6）；
## dialog 选项回复进日志；边效果/on_enter 写板由 StoryGraph 落（07 §1 溯源）。
## 探索序列进行中时，选项按钮 = 推进当前节拍（MazeRunner，tech/02 §6 maze）。
func _on_story_edge(idx: int) -> void:
	if _maze != null:
		_on_maze_advance()
		return
	var edges := graph.available_edges()
	if idx < 0 or idx >= edges.size():
		return
	var edge: Dictionary = edges[idx]
	if str(graph.current().get("type", "")) == "dialog":
		stream.emit(EventTypes.LOG, {"msg": "【%s】%s" % [str(graph.current().get("title", "")),
			str(edge.get("label", TextsZh.STORY_CONTINUE))]}, &"core", graph.current_id)
	if str(edge.get("type", "")) == "check":
		var res := graph.roll_check(edge)
		await get_tree().create_timer(2.3 if bool(res.get("key", false)) else 0.8).timeout # 等演出落定
	else:
		graph.take_edge(edge)
	_present_node()

## Hub 动作（战役书 §4 N1-1）：商店购买 / 休整 / 传闻；写板全部在 core，本层只转发与刷新。
func _on_hub_action(action: String, arg: String) -> void:
	match action:
		"buy":
			if not graph.hub_buy(arg):
				stream.emit(EventTypes.LOG, {"msg": TextsZh.HUB_NO_GOLD, "toast": true}, &"core", graph.current_id)
			var vm := StoryVM.build(graph, board, pack)
			_story_show(vm)
			shell.sync_hub_popup(vm)
		"rest":
			graph.hub_rest()
			var vm2 := StoryVM.build(graph, board, pack)
			_story_show(vm2)
			shell.sync_hub_popup(vm2)
		"rumor":
			var rumors: Array = graph.hub_rumors()
			var msg := StoryVM.rumor_text(rumors[0]) if not rumors.is_empty() else TextsZh.HUB_RUMOR_NONE
			stream.emit(EventTypes.LOG, {"msg": msg, "toast": true}, &"core", graph.current_id)

## 切片终点（出 SL-0/SL-1 范围或结局节点）：结算快照落盘（07 §4.2 主快照点）+ ⑨结算屏。
func _end_slice() -> void:
	_in_encounter = false
	# 通关旗标 → 成就点亮路径（06 §2.1：点亮手段多样；规则表在运营配置，06 §3.2）
	if not bool(board.read("campaign01.cleared")):
		board.write("campaign01.cleared", true,
			{"event_id": stream.tail(), "node_id": graph.current_id, "pack_id": "campaign01"})
	entitlements.check_achievements(ops_config)
	# 成长在 xp 效果产出时已即时汇入 global.growth.*（tech/04 §8 规则1/2）；
	# 结算界面 = 成长加点时机（11 §6；04 §⑨），此处只呈现与分配。
	_save("settle")
	_encounter_tail = _campaign_tail # 汇总区间 = 整个切片（逐项念给玩家听，04 §⑨）
	_encounter_result = &"slice"
	_show_settle()

# ---------------------------------------------------------------- 结局与多周目（tech/02 §9；战役书 §9/§8）

## 结局节点：写通关旗标（成就点亮路径 06 §2.1）→ story.ending 事件（tech/02 §9）→ 结局快照
## （07 §4.2 主快照点）→ 结局屏（四分型文案 + 多周目钩子均取 endings.json，壳不再创作）。
## 结局分型旗标（ending_e1~e4 / 解锁占位）由 ending 节点 on_enter 写板（nodes.json，V4 台账闭环）。
func _present_ending() -> void:
	_in_encounter = false
	var eid := graph.current_id
	if not bool(board.read("campaign01.cleared")):
		board.write("campaign01.cleared", true,
			{"event_id": stream.tail(), "node_id": eid, "pack_id": "campaign01"})
	entitlements.check_achievements(ops_config)
	var edef := {}
	for e: Variant in pack.get("endings", []):
		if str((e as Dictionary).get("id", "")) == eid:
			edef = e
	stream.emit(EventTypes.STORY_ENDING, {"ending": eid,
		"title": str(edef.get("title", graph.current().get("title", eid)))}, &"graph", eid)
	_save("ending")
	var screen: ScreenEnding = (load(SCREEN_SCENES[&"ending"]) as PackedScene).instantiate()
	_swap(screen)
	screen.bind({"ending_id": eid, "title": str(edef.get("title", eid)),
		"content": str(edef.get("content", "")), "hook": str(edef.get("ngplus_hook", "")),
		"playthrough": int(board.read("campaign01.ngplus", 0)) + 1, "saved": true})
	screen.ngplus_requested.connect(_on_ngplus_start)
	screen.go_home.connect(_show_home)

## 开始二周目（战役书 §8 投放第 4 枚残简 = 多周目继承 ×1；§9 E4：失败非终局、收集与图鉴进度保留）：
## 保留 global.lore（图鉴）与 global.entitlement.*（权利），周目数 +1（campaign01.ngplus 簿记，
## meta.ngplus/playthrough 数据源），其余状态重置后从入口节点重新开图（bot NG+ 语义同口径）。
func _on_ngplus_start() -> void:
	var lore: Array = board.get_lore()
	var ents := {}
	for key: String in board.keys_with_prefix("global.entitlement."):
		ents[key] = board.read(key)
	var ng := int(board.read("campaign01.ngplus", 0)) + 1
	board = Board.new(stream)
	entitlements = Entitlements.new(board, stream)
	entitlements.apply_activities(ops_config)
	var sys_prov := {"event_id": stream.tail(), "node_id": "ngplus_boot", "pack_id": "system"}
	for key: String in ents.keys():
		board.write(key, ents[key], sys_prov) # 权利保留（global.entitlement.* 仅 system 可写，07 §3）
	var pack_prov := {"event_id": stream.tail(), "node_id": "ngplus_boot", "pack_id": "campaign01"}
	board.write("global.lore", lore, pack_prov) # 图鉴保留（07 §2 全局白名单，任何包可写）
	board.write("campaign01.ngplus", ng, pack_prov) # 周目数簿记（包命名空间）
	board.give_item("codex_fragment", 1, pack_prov) # 多周目继承 ×1（战役书 §8 投放第 4 枚）
	graph = StoryGraph.new(board, rng, pack)
	if shell != null:
		shell.queue_free()
		shell = null
	router = ShellRouter.new()
	_battles_won = 0
	stream.emit(EventTypes.LOG, {"msg": TextsZh.NGPLUS_TOAST, "toast": true}, &"core")
	_start_campaign()

# ---------------------------------------------------------------- 迷宫探索序列（tech/02 §6 maze 块；04 §④.3）
# 逐拍呈现：check/ambush 拍掷 d20+修正（与检定边同一公式，11 §2/§3），loot 拍写板拾取；
# 节拍效果/进度全部由 MazeRunner 落 core（写板带溯源、进事件流），本层只转发与刷新。

## 当前 explore 节点有待完成的探索序列（节拍进度簿记在状态板，中途离场续打不重效果）。
func _maze_pending() -> bool:
	var enc: Dictionary = (pack.get("encounters", {}) as Dictionary).get(
		str(graph.current().get("encounter", graph.current_id)), {})
	var beats: Array = (enc.get("maze", {}) as Dictionary).get("beats", [])
	if beats.is_empty():
		return false
	var enc_id := str(enc.get("id", graph.current_id))
	return int(board.read("%s.maze.%s.idx" % [pack["pack_id"], enc_id], 0)) < beats.size()

func _enter_maze() -> void:
	var enc_id := str(graph.current().get("encounter", graph.current_id))
	var enc: Dictionary = (pack.get("encounters", {}) as Dictionary).get(enc_id, {})
	_maze = MazeRunner.new(board, stream, rng, str(pack["pack_id"]))
	_maze.begin(enc_id, (enc.get("maze", {}) as Dictionary).get("beats", []),
		Callable(graph, "check_mod"), graph.current_id)
	_maze_outcome = ""
	_show_maze_beat()

## 呈现当前节拍：复用双壳故事态（StoryVM 单源），选项按钮 = 推进本拍。
func _show_maze_beat() -> void:
	if _maze == null:
		_present_node()
		return
	var beat := _maze.peek()
	if beat.is_empty(): # 序列完成 → 回节点呈现出边（密道道具边按条件显形，tech/02 §4.3）
		_maze = null
		_maze_outcome = ""
		_present_node()
		return
	var vm := StoryVM.build(graph, board, pack)
	vm["type"] = "explore"
	vm["title"] = TextsZh.MAZE_TITLE % [str(graph.current().get("title", graph.current_id)),
		_maze.beat_index() + 1, _maze.beat_count()]
	vm["text"] = _maze_outcome + str(beat.get("text", ""))
	var label := TextsZh.STORY_CONTINUE
	var btype := str(beat.get("type", ""))
	if btype == "check" or btype == "ambush":
		var skill := str(beat.get("skill", "perception"))
		var diff := str(beat.get("difficulty", "medium"))
		label = "%s：%s（%s DC %d · 修正 %+d）" % [TextsZh.STORY_CHECK,
			str(TextsZh.SKILL_NAMES.get(skill, skill)), str(TextsZh.DIFF_NAMES.get(diff, diff)),
			LightV1.dc_for(diff), graph.check_mod(skill)]
		if btype == "ambush":
			label = TextsZh.MAZE_AMBUSH_PREFIX + label
	elif btype == "loot":
		label = TextsZh.MAZE_LOOT % [_item_name(str(beat.get("item", ""))), int(beat.get("n", 1))]
	vm["edges"] = [{"type": "choice", "label": label}]
	_ensure_story_shell()
	_story_show(vm)

## 推进当前节拍：掷骰/写板在 core（check.roll、item.gain、效果 DSL 事件进事件流）；
## 结果摘要拼入下一拍文本；等快掷落定再刷新（09 §6 普通检定 ≤0.5s 出结果）。
func _on_maze_advance() -> void:
	var res := _maze.resolve()
	if str(res.get("type", "")) == "loot":
		_maze_outcome = "%s\n\n" % TextsZh.MAZE_LOOT % [_item_name(str(res.get("item", ""))),
			int(res.get("n", 1))]
	else:
		_maze_outcome = (TextsZh.MAZE_BEAT_OK if bool(res.get("success", false)) \
			else TextsZh.MAZE_BEAT_FAIL) + "\n\n"
	await get_tree().create_timer(0.8).timeout
	_show_maze_beat()

# ---------------------------------------------------------------- 整备（09 §9.1；tech/02 §2.4）

func _enter_encounter() -> void:
	var node := graph.current()
	_encounter_id = str(node.get("encounter", graph.current_id))
	_battle_title = str(node.get("title", _encounter_id))
	var cfg := Loadout.resolve_config(pack, _encounter_id)
	if not cfg.is_empty():
		cfg = cfg.duplicate() # 2→3 级技能槽 +1（11 §6；槽位基值仍读配置，tech/02 §2.4）
		cfg["skill_slots"] = int(cfg["skill_slots"]) \
			+ LightV1.skill_slot_bonus(Growth.level(board))
	if cfg.is_empty():
		_begin_encounter({"skills": [], "items": ["heal_potion"], "attr_alloc": {}}) # 空选择 = BattleDef 缺省
		return
	var screen: ScreenLoadout = (load(SCREEN_SCENES[&"loadout"]) as PackedScene).instantiate()
	_swap(screen)
	screen.bind(cfg, _loadout_candidates())
	screen.confirmed.connect(_on_loadout_confirmed.bind(cfg))
	screen.back_requested.connect(_present_node) # 整备可退回节点（04 §5 有退路）

## 整备备选 = 玩家模板已习得技能 ∩ skills.json（tech/04 §7）；道具 = 背包含 use 块条目（tech/04 §4）。
func _loadout_candidates() -> Dictionary:
	var skill_pool: Array = []
	var skills: Dictionary = pack.get("skills", {})
	for sid: Variant in _player_template().get("skills", []):
		if skills.has(str(sid)):
			skill_pool.append(BattleDef.runtime_skill(skills[str(sid)]))
	var items: Array = []
	for iid: String in (pack.get("items", {}) as Dictionary).keys():
		var it: Dictionary = pack["items"][iid]
		if it.has("use") and board.has_item(iid):
			items.append({"id": iid, "name": str(it.get("name", iid)), "count": board.item_count(iid)})
	return {"skills": skill_pool, "items": items,
		"attr_points": Growth.attr_points(board), # 成长簿记归全局键（tech/04 §8）
		"attrs": Growth.attrs_map(board), # 已分配值（单项 +3 封顶判定用，11 §6）
		"attr_alloc": {"might": 0, "finesse": 0, "wits": 0}}

## 玩家模板条目（tech/04 §2 kind=player_template；找不到 = 包数据缺陷，返回空字典由组装层报错）。
func _player_template() -> Dictionary:
	for cid: String in (pack.get("characters", {}) as Dictionary).keys():
		var c: Dictionary = pack["characters"][cid]
		if str(c.get("kind", "")) == "player_template":
			return c
	return {}

func _on_loadout_confirmed(selection: Dictionary, cfg: Dictionary) -> void:
	Loadout.confirm(stream, cfg, selection["skills"], selection["items"],
		selection["attr_alloc"], graph.current_id, pack["pack_id"]) # loadout.confirm 事件（09 §9.1）
	_apply_attr_alloc(selection.get("attr_alloc", {}), int(selection.get("attr_points_left", 0)))
	_begin_encounter(selection)

## 属性点分配经成长系统写板 global.growth.*（07 §1 溯源；tech/04 §8 规则3）；
## 单项 ≤+3 封顶（11 §6）或点数不足 → 拒绝整体分配并返回 false。
func _apply_attr_alloc(alloc: Dictionary, _points_left: int = 0) -> bool:
	var growth := Growth.new(board)
	for attr: String in alloc.keys():
		var n := int(alloc[attr])
		if n <= 0:
			continue
		if Growth.attrs_total(board, attr) + n > LightV1.ATTR_POINT_CAP:
			return false # 单项 ≤+3 封顶（11 §6）
		if n > Growth.attr_points(board):
			return false # 未分配点数不足
	var prov := {"event_id": stream.tail(), "node_id": graph.current_id, "pack_id": "campaign01"}
	for attr: String in alloc.keys():
		for i: int in int(alloc[attr]):
			if not growth.alloc(attr, prov):
				return false
	return true

# ---------------------------------------------------------------- 遭遇（09 §2/§7/§8；tech/02 §2.1）

func _begin_encounter(selection: Dictionary) -> void:
	_in_encounter = true
	_encounter_snapshot = SaveSystem.make_snapshot(board, stream, rng, _bindings(), _meta()) # ☰ 恢复点
	_encounter_tail = stream.tail()
	_encounter_result = &""
	var sm := EncounterSM.new(board, stream, rng, pack["pack_id"])
	var agent := AutoAgent.new()
	_ensure_story_shell() # 复用故事壳（09 §8：一局一壳；bind 内切战斗布局）
	if current_screen != null and current_screen != shell:
		current_screen.queue_free()
	current_screen = shell
	shell.visible = true
	if shell is EncounterPortrait:
		(shell as EncounterPortrait).bind(sm, agent)
	else:
		(shell as EncounterLandscape).bind(sm, agent)
	shell.set("on_save_quit", Callable(self, "_on_save_quit"))
	router.lock_encounter(_mode) # 遭遇开始即壳锁定（09 §8）
	var nid := graph.current_id
	sm.enter(nid)
	sm.transition(EncounterSM.S_EXPLORE)
	stream.emit(EventTypes.LOG, {"msg": str(graph.current().get("summary", ""))}, &"core", nid)
	await get_tree().create_timer(1.0).timeout
	if sm.state == EncounterSM.S_EXPLORE:
		var def := _battle_def(selection)
		if def.is_empty():
			return # fail-fast：包数据缺陷不进战斗（报错已由 _battle_def 输出）
		sm.begin_combat(def)

## 战斗定义 = pack 资源表组装（tech/04 §1~§4 / tech/02 §6；M2：TP2 硬编码留白落位）。
## 引用缺失/公式失败 = 包数据缺陷：fail-fast 报错并返回空字典（不静默降级、不进战斗）。
func _battle_def(selection: Dictionary) -> Dictionary:
	var enc := _encounter_id if not _encounter_id.is_empty() else graph.current_id
	var res := BattleDef.assemble(pack, enc, selection, board)
	if not bool(res["ok"]):
		push_error("[main] 战斗定义组装失败（campaign01/%s）：%s"
			% [enc, ";".join(res["errors"] as Array)])
		return {}
	return res["def"]

## ☰「保存并回主屏」（09 §7）：遭遇进行中 = 恢复遭遇进入前快照（本局重打，不存档）；
## 故事态（遭遇外）= 进度随图快照落档后回主屏（07 §4.2 遭遇外时机）。
func _on_save_quit() -> void:
	if _in_encounter:
		if shell != null:
			shell.queue_free()
			shell = null
		SaveSystem.apply(_encounter_snapshot, board, rng) # 恢复遭遇进入前的世界状态（战斗不写板，RNG 归位）
		graph.deserialize(_encounter_snapshot["meta"].get("graph", {}))
		stream.emit(EventTypes.LOG, {"msg": "你合上抄本。这一页的雨，被轻轻翻回了开头。"}, &"core")
		_in_encounter = false
		_save("quit_home") # 恢复后的世界状态落档（遭遇外时机，07 §4.2）
		_show_home()
		return
	_save("quit_home") # 故事态：节点进度在 meta.graph 内随快照落档
	stream.emit(EventTypes.LOG, {"msg": "你合上抄本。这一程就讲到这里。"}, &"core")
	_show_home()

# ---------------------------------------------------------------- 结算（04 §⑨；07 §4.2 主快照点）

func _on_event(ev: Dictionary) -> void:
	if ev["type"] == EventTypes.COMBAT_END and _sub_active and _sub_battling:
		_sub_on_combat_end(ev["payload"]["result"]) # 子游戏连战路由（04 §6）
		return
	if ev["type"] == EventTypes.COMBAT_START:
		# 情境教程：首次战斗（12 §4：拖动移动 + 轨迹施法 + 双指点击结束回合 + 捏合缩放）
		_context_hint("combat", TextsZh.TUT_HINT_COMBAT)
	if ev["type"] == EventTypes.CHECK_ROLL and bool(ev["payload"].get("key", false)):
		# 情境教程：首次关键判定（可跳过演出，04 §④.7 长按跳过）
		_context_hint("key_roll", TextsZh.TUT_HINT_KEY)
	if ev["type"] == EventTypes.COMBAT_END and _in_encounter:
		_encounter_result = ev["payload"]["result"]
		_show_settle_deferred()

func _show_settle_deferred() -> void:
	await get_tree().create_timer(1.2).timeout
	_in_encounter = false
	if _encounter_result == &"victory":
		_battles_won += 1
		# 战斗是图内节点：胜利后走战后边回图（tech/02 §3 节点边结算）；
		# 多条出边（hybrid 战后抉择 N2U-2 撕/不撕、通缉战 N2L-1b 强制择链）
		# → 呈现节点选项由玩家抉择（tech/02 §6 hybrid），单出边自动推进
		var edges := graph.available_edges()
		if edges.is_empty():
			_end_slice()
			return
		if edges.size() == 1:
			graph.take_edge(edges[0])
			_present_node()
		else:
			# 多条出边（hybrid 战后抉择 N2U-2 撕/不撕、通缉战 N2L-1b 强制择链）：
			# 呈现战斗节点的故事态选项由玩家抉择——不得再进 _present_node（type=battle 会重进遭遇）
			_present_story_node()
	elif _encounter_result == &"objective_failed":
		# 护送目标失败：罚时等代价已按 escort.failure_effects 写板（core，tech/02 §6），
		# 仍走节点唯一出边——罚时替代全灭（N2S-1 注记就近处理，08 §2 失败即分支）
		var edges := graph.available_edges()
		if edges.is_empty():
			_end_slice()
			return
		graph.take_edge(edges[0])
		_present_node()
	else:
		_save("settle") # 失败即分支：结算仍是元循环落笔（09 §7 失败不读档）
		_show_settle()

## 汇总区间 = 锚点之后的事件（04 §⑨：逐项念给玩家听）。
func _show_settle() -> void:
	var lines: Array[String] = []
	var xp := 0
	var attr_gained := 0
	for ev: Dictionary in stream.since(_encounter_tail):
		var p: Dictionary = ev["payload"]
		match StringName(ev["type"]):
			EventTypes.XP_GAIN:
				xp += int(p.get("amount", 0))
			EventTypes.LEVEL_UP:
				attr_gained += int(p.get("attr_points", 0)) # 升级即发放（tech/04 §8 规则2）
			EventTypes.ITEM_GAIN:
				lines.append("获得：%s ×%d（已入背包）" % [_item_name(str(p.get("item_id", ""))),
					int(p.get("count", 1))])
			EventTypes.FLAG_WRITE:
				var fkey := str(p.get("key", ""))
				# 内部簿记键（成长/模式选择/金币/HP）不念给玩家（04 §⑨ 呈现语义：旗标变化摘要）
				if fkey.begins_with("global.growth.") or fkey.begins_with("campaign01.attr") \
						or fkey == "campaign01.xp_total" \
						or fkey == "campaign01.gold" or fkey.begins_with("campaign01.hp.") \
						or fkey.begins_with("campaign01.maze.") \
						or fkey.begins_with("global.tutorial.") \
						or fkey.begins_with("global.mode_choice."):
					continue
				lines.append("旗标：%s" % fkey)
			EventTypes.REP_CHANGE:
				lines.append("声望：%s %+d" % [str(p.get("key", "")).trim_prefix("global.rep."),
					int(p.get("delta", 0))])
			EventTypes.LOADOUT_CONFIRM:
				lines.append("整备：技能 %s / 道具 %s" % [str(p.get("skills", [])), str(p.get("items", []))])
	if xp > 0:
		lines.insert(0, "经验 +%d" % xp)
	var level := Growth.level(board)
	if level > 1:
		lines.append("等级：Lv.%d（11 §6 成长表）" % level)
	if attr_gained > 0:
		lines.append("成长：属性点 +%d" % attr_gained)
	lines.append("时间钟：%d 格" % board.get_doom_clock())
	_settle_lines = lines
	_bind_settle()

func _bind_settle() -> void:
	var screen: ScreenSettle = (load(SCREEN_SCENES[&"settle"]) as PackedScene).instantiate()
	_swap(screen)
	screen.bind({"title": TextsZh.STORY_SLICE_END if _encounter_result == &"slice" else _battle_title,
		"result": String(_encounter_result), "lines": _settle_lines,
		"saved": true, "attr_points": Growth.attr_points(board),
		"attrs": Growth.attrs_map(board)})
	screen.allocate.connect(_on_settle_allocate)
	screen.go_home.connect(_show_home)
	screen.go_history.connect(func() -> void:
		_history_origin = &"settle"
		_show_history())

func _on_settle_allocate(attr: String) -> void:
	var prov := {"event_id": stream.tail(), "node_id": graph.current_id, "pack_id": "campaign01"}
	if not Growth.new(board).alloc(attr, prov):
		return # 点数不足或单项 +3 封顶（11 §6）：拒绝并保持界面
	_bind_settle() # 刷新可用点数与已分配值

# ---------------------------------------------------------------- ⑤⑥⑦⑧ 功能界面（04 §⑤⑥⑦⑧ 最小版）

func _show_quests() -> void:
	var screen: ScreenQuests = (load(SCREEN_SCENES[&"quests"]) as PackedScene).instantiate()
	_swap(screen)
	screen.bind(graph.quests())
	screen.abandon_requested.connect(func(qid: String) -> void:
		graph.abandon_quest(qid) # 放弃写旗标 + 事件在 core（04 §⑤）；放弃后归档历史卷轴
		_show_quests())
	screen.back_requested.connect(_show_home)

func _show_inventory() -> void:
	var screen: ScreenInventory = (load(SCREEN_SCENES[&"inventory"]) as PackedScene).instantiate()
	_swap(screen)
	screen.bind(board.get_inv(), pack.get("items", {}), board.get_lore(), pack.get("lore", []))
	screen.back_requested.connect(_show_home)

func _show_character() -> void:
	var screen: ScreenCharacter = (load(SCREEN_SCENES[&"character"]) as PackedScene).instantiate()
	_swap(screen)
	# 返回连接先于数据绑定（M2 审计 G1：绑定路径任何早期返回都不得带走出口）
	screen.back_requested.connect(_show_home)
	var bonds := {}
	for key: String in board.keys_with_prefix("global.bond."):
		bonds[key.trim_prefix("global.bond.")] = board.read(key)
	# 队伍卡 = 名册直组（StoryGraph.party_roster，04 §⑦），与战斗定义解耦——
	# 主屏/非战斗上下文无当前遭遇，不得走 _battle_def（M2 审计 G1：组装失败曾致脚本错误+软锁）。
	# 成长区（tech/04 §8）：等级 / XP 进度 / 已分配属性 / 未分配点数
	screen.bind(graph.party_roster(), bonds, Growth.xp_progress(board))

## ⑧ 历史卷轴：从主屏 / 结算进入，返回来源界面（04 §5 出口列）。
func _show_history() -> void:
	var screen: ScreenHistory = (load(SCREEN_SCENES[&"history"]) as PackedScene).instantiate()
	_swap(screen)
	screen.bind(stream, board)
	screen.back_requested.connect(func() -> void:
		if _history_origin == &"settle":
			_bind_settle() # 返回来源界面（04 §5 出口列：结算→卷轴→结算）
		elif _history_origin == &"sub_settle":
			_sub_bind_settle() # 子游戏结算同理（04 §6：子游戏复用框架界面）
		else:
			_show_home())

# ---------------------------------------------------------------- 子游戏连战（白皮书 §10.2；04 §6；docs/subgames/arena/01-概念设计.md）
# 流程：② 入口卡 → A-0 演出 → 整备（仅进场一次）→ EncounterSM ×N（场间无休整，HP 持久 11 §7.1）
#   → 每场胜利写金币/胜场（SubgameRunner）→ 战后边（追击/收兵）→ ⑨ 结算（写板硬要求）→ 回主屏。
# 全部数据驱动自子游戏包（节点图/遭遇/奖励声明），core 零改动；本块是 §10.2"子游戏不动框架"的运行时落点。

# ---------------------------------------------------------------- 权利与商店（06 §2/§3/§6）

## 锁定卡「获取」→ 购买半屏弹层（06 §6：不离开当前界面情境；04 §3.3）。
func _on_acquire_requested(pack_id: String) -> void:
	if not _subgames.has(pack_id):
		return
	var entry := current_screen as ScreenEntry
	if entry == null:
		return
	var manifest: Dictionary = _subgames[pack_id]["manifest"]
	var price := Entitlements.price_of(ops_config, pack_id)
	entry.shop_popup.open(pack_id, str(manifest.get("name", pack_id)),
		str(price.get("price_text", "")))

## 购买确认 → 商店点亮方写板（单号溯源，06 §2.3）→ 入口当场刷新解锁（06 §3.1：购买即解锁无需重启）。
func _on_purchase_confirmed(pack_id: String) -> void:
	var receipt_id := "rcpt_%d" % stream.tail() # mock 单号（真实支付接入是运营立项留白，06 §7）
	if not entitlements.shop_purchase(pack_id, receipt_id):
		return
	var pack_name := str((_subgames.get(pack_id, {}) as Dictionary).get("manifest", {}).get("name", pack_id))
	stream.emit(EventTypes.LOG,
		{"msg": "守门人收下印记——《%s》的门开了。（购买即解锁，无需重启）" % pack_name, "toast": true}, &"core")
	_show_entry()

func _on_subgame_start(pack_id: String, mode: StringName) -> void:
	if not _subgames.has(pack_id) or _sub_active:
		return
	if not entitlements.can_access((_subgames[pack_id] as Dictionary)["manifest"]):
		# 硬门槛（tech/02 §2.2）：叙事化提示，无"未购买"生硬弹窗（06 §3.1）
		stream.emit(EventTypes.LOG, {"msg": TextsZh.LOCK_ARENA, "toast": true}, &"core")
		return
	_sub = SubgameRunner.new(_subgames[pack_id], board, stream, rng)
	_sub_mode = mode
	_sub_active = true
	_sub_battling = false
	_sub_tail = stream.tail()
	# 模式选择 = 一次分支，写入状态板（09 §3；global.mode_choice.* 白名单，07 §3 v1.1）
	board.write("global.mode_choice.%s" % pack_id, String(mode),
		{"event_id": stream.tail(), "node_id": graph.current_id, "pack_id": pack_id})
	_sub.start()
	_sub_present()

## 子游戏节点呈现：ending → ⑨ 结算；battle → 整备/遭遇；其余 → 双壳故事态（StoryVM 单源）。
func _sub_present() -> void:
	var node := _sub.current()
	var t := str(node.get("type", ""))
	if t == "ending":
		_sub_finish(&"victory")
		return
	if t == "battle":
		_sub_enter_battle()
		return
	_ensure_sub_shell()
	_story_show(StoryVM.build(_sub.graph, board, _sub.pack))

## 子游戏故事壳：复用双壳场景（09 §8 一局一壳），绑定子游戏包与子游戏回调（与战役通道隔离）。
func _ensure_sub_shell() -> void:
	if shell == null:
		shell = (load(SHELL_SCENES[_sub_mode]) as PackedScene).instantiate()
		add_child(shell)
		if _sub_mode == ShellRouter.MODE_SPACE and DisplayServer.get_name() != "headless":
			get_window().size = LANDSCAPE_SIZE
			get_window().move_to_center()
		router.lock_encounter(_sub_mode) # 形态整场锁定（09 §3/§8）
	if current_screen != null and current_screen != shell:
		current_screen.queue_free()
	current_screen = shell
	shell.visible = true
	shell.set("on_save_quit", Callable(self, "_on_sub_save_quit"))
	shell.bind_story(stream, board, _sub.pack,
		{"edge": _on_sub_story_edge, "hub": func(_a: String, _b: String) -> void: pass})

func _on_sub_story_edge(idx: int) -> void:
	_sub.take_edge(idx)
	_sub_present()

## 战斗节点：进场一次整备（09 §9.1；连战中途不再整备、HP 不恢复——概念设计 §2 无休整）。
func _sub_enter_battle() -> void:
	var cfg := _sub.loadout_config()
	if not cfg.is_empty() and _sub.run_wins == 0:
		var screen: ScreenLoadout = (load(SCREEN_SCENES[&"loadout"]) as PackedScene).instantiate()
		_swap(screen)
		screen.bind(cfg, _sub.loadout_candidates())
		screen.confirmed.connect(_on_sub_loadout_confirmed.bind(cfg))
		screen.back_requested.connect(_sub_leave_home) # 整备可退（04 §5 有退路）
		return
	_sub_begin_combat({"skills": [], "items": [], "attr_alloc": {}})

func _on_sub_loadout_confirmed(selection: Dictionary, cfg: Dictionary) -> void:
	Loadout.confirm(stream, cfg, selection["skills"], selection["items"],
		selection.get("attr_alloc", {}), _sub.graph.current_id, _sub.pack_id) # loadout.confirm（09 §9.1）
	# 整备分配写板 global.growth.*（tech/04 §8 规则3；与战役整备同一通道）
	var growth := Growth.new(board)
	var prov := {"event_id": stream.tail(), "node_id": _sub.graph.current_id, "pack_id": _sub.pack_id}
	for attr: String in (selection.get("attr_alloc", {}) as Dictionary).keys():
		for i: int in int((selection["attr_alloc"] as Dictionary)[attr]):
			if not growth.alloc(attr, prov):
				push_warning("[main] 子游戏整备加点被拒（%s，封顶或点数不足，11 §6）" % attr)
	_sub_begin_combat(selection)

func _sub_begin_combat(selection: Dictionary) -> void:
	_sub_battling = true
	_sub_snapshot = SaveSystem.make_snapshot(board, stream, rng, _bindings(), _meta()) # ☰ 恢复点（09 §7）
	var sm := EncounterSM.new(board, stream, rng, _sub.pack_id)
	var agent := AutoAgent.new()
	_ensure_sub_shell()
	if current_screen != null and current_screen != shell:
		current_screen.queue_free()
	current_screen = shell
	shell.visible = true
	if shell is EncounterPortrait:
		(shell as EncounterPortrait).bind(sm, agent)
	else:
		(shell as EncounterLandscape).bind(sm, agent)
	var nid := _sub.graph.current_id
	sm.enter(nid)
	sm.transition(EncounterSM.S_EXPLORE)
	stream.emit(EventTypes.LOG, {"msg": str(_sub.current().get("summary", ""))}, &"core", nid)
	await get_tree().create_timer(1.0).timeout
	if sm.state == EncounterSM.S_EXPLORE:
		var def := _sub.battle_def(selection)
		if def.is_empty():
			return # fail-fast：包数据缺陷不进战斗（报错已由 battle_def 输出）
		sm.begin_combat(def)

## 连战收场路由（COMBAT_END 由 _on_event 分发）：胜利 → 写奖励 + 战后边回图（追击/收兵）；
## 败北 → 按已完成场次直接进 ⑨ 结算（失败即分支，概念设计 §2）。
func _sub_on_combat_end(result: StringName) -> void:
	await get_tree().create_timer(1.2).timeout
	_sub_battling = false
	if result == &"victory":
		_sub.on_victory() # 每场胜利：金币 + 累计胜场写板（04 §6 写状态板硬要求）
		_ensure_sub_shell()
		_story_show(StoryVM.build(_sub.graph, board, _sub.pack)) # 战后边：追击（无休整）/ 收兵
	else:
		_sub_finish(result)

## ⑨ 结算（04 §6/§9：进出场必经；逐项念给玩家听）→ 结算快照（07 §4.2）→ 回主屏 / ⑧ 卷轴。
func _sub_finish(result: StringName) -> void:
	_sub_battling = false
	var summary := _sub.finish_run(result) # 最佳连战纪录取大写板
	_save("settle")
	_sub_settle_cache = _sub_settle_lines(summary, result)
	_sub_bind_settle()

var _sub_settle_cache: Dictionary = {}

func _sub_settle_lines(summary: Dictionary, result: StringName) -> Dictionary:
	var lines: Array[String] = []
	var xp := 0
	for ev: Dictionary in stream.since(_sub_tail):
		var p: Dictionary = ev["payload"]
		match StringName(ev["type"]):
			EventTypes.XP_GAIN:
				xp += int(p.get("amount", 0))
			EventTypes.ITEM_GAIN:
				var iid := str(p.get("item_id", ""))
				lines.append("获得：%s ×%d（已入背包，global.inv 互通）" % [
					str((_sub.pack.get("items", {}) as Dictionary).get(iid, {}).get("name", iid)),
					int(p.get("count", 1))])
	if xp > 0:
		lines.append("经验 +%d" % xp)
	if int(summary["gold"]) > 0:
		lines.append("金币 +%d（%s.gold 累计 %d）" % [int(summary["gold"]), _sub.pack_id,
			int(board.read("%s.gold" % _sub.pack_id, 0))])
	lines.append("战绩：本次 %d 胜 · 累计 %d 胜 · 最佳连战 %d" % [int(summary["wins"]),
		int((_sub.stats() as Dictionary)["wins"]), int(summary["best"])])
	if bool(summary["flawless"]):
		lines.append("全胜谢幕：擂台为你留名（arena.flawless 已落板）")
	return {"title": "%s · %s" % [str((_sub.pack["manifest"] as Dictionary).get("name", _sub.pack_id)),
			str(_sub.current().get("title", "连战结算"))],
		"result": String(result), "lines": lines, "saved": true,
		# 成长簿记归框架全局键（tech/04 §8）：子游戏结算屏同口径呈现与分配
		"attr_points": Growth.attr_points(board), "attrs": Growth.attrs_map(board)}

func _sub_bind_settle() -> void:
	var screen: ScreenSettle = (load(SCREEN_SCENES[&"settle"]) as PackedScene).instantiate()
	_swap(screen)
	screen.bind(_sub_settle_cache)
	# 子游戏结算屏同接成长分配（tech/04 §8 规则3：结算屏分配；概念设计 §8 待裁决 3 随全局簿记结构消解）
	screen.allocate.connect(func(attr: String) -> void:
		if Growth.new(board).alloc(attr, {"event_id": stream.tail(),
				"node_id": _sub.graph.current_id, "pack_id": _sub.pack_id}):
			_sub_settle_cache["attr_points"] = Growth.attr_points(board)
			_sub_settle_cache["attrs"] = Growth.attrs_map(board)
			_sub_bind_settle()) # 刷新可用点数与已分配值
	screen.go_home.connect(_sub_leave_home)
	screen.go_history.connect(func() -> void:
		_history_origin = &"sub_settle"
		_show_history())

## ☰「保存并回主屏」（09 §7）：战斗中 = 恢复本场进入前快照（本场重打，不存档）；故事态 = 落档回主屏。
func _on_sub_save_quit() -> void:
	if _sub_battling:
		SaveSystem.apply(_sub_snapshot, board, rng)
		stream.emit(EventTypes.LOG, {"msg": "你合上抄本。擂台的墨锣声远去了。"}, &"core")
	_save("quit_home")
	_sub_leave_home()

func _sub_leave_home() -> void:
	_sub_active = false
	_sub_battling = false
	_sub = null
	_show_home()

# ---------------------------------------------------------------- 存档（07 §4）

func _bindings() -> Dictionary:
	var packs := {str(pack.get("pack_id", "campaign01")):
		int((pack.get("manifest", {}) as Dictionary).get("pack_version", 1))}
	for pid: String in _subgames: # 子游戏包版本随快照绑定（07 §4.1 三方版本解耦，tech/02 §11）
		packs[pid] = int(((_subgames[pid] as Dictionary).get("manifest", {}) as Dictionary).get("pack_version", 1))
	return {"packs": packs,
		"rule_pack": (pack.get("manifest", {}) as Dictionary).get("rule_pack", {}),
		"framework": "1.0.0"}

func _meta() -> Dictionary:
	return {"playthrough": int(board.read("campaign01.ngplus", 0)) + 1,
		"ngplus": int(board.read("campaign01.ngplus", 0)), # 周目数随快照落档（07 §4.1 meta）
		"created_at": Time.get_datetime_string_from_system(false, true),
		"progress": "当前节点 %s · 已访 %d 节点 · 胜场 %d" % [graph.current_id,
			graph.visit_log.size(), _battles_won],
		"graph": graph.serialize(),
		"node_id": graph.current_id}

## 写档（遭遇外时机专用：结算完成 / 主屏手动 / 主屏闲置 / ☰ 回主屏恢复后）。
func _save(reason: String) -> void:
	if _in_encounter:
		push_error("[main] 遭遇进行中不存档（07 §4.2）——调用方时机错误")
		return
	var snap := SaveSystem.make_snapshot(board, stream, rng, _bindings(), _meta())
	if SaveSystem.write(snap):
		stream.emit(EventTypes.LOG, {"msg": "抄本已记录（%s）。" % reason}, &"core")

func _save_home() -> void:
	_save("home_manual")

func _save_idle() -> void:
	_save("home_idle")

func _has_continuable() -> bool:
	return SaveSystem.has_save() or (not graph.visit_log.is_empty() and not graph.is_at_ending())

func _collect_pct() -> float:
	var total := maxi((pack.get("nodes", {}) as Dictionary).size(), 1)
	return float(graph.visit_log.size()) / float(total) * 100.0

func _item_name(item_id: String) -> String:
	return str((pack.get("items", {}) as Dictionary).get(item_id, {}).get("name", item_id))

# ---------------------------------------------------------------- 中文字体（macOS 系统字体回退，仅为可读性）

func _setup_cjk_font() -> void:
	for path: String in ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc",
			"/System/Library/Fonts/STHeiti Light.ttc", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"]:
		if FileAccess.file_exists(path):
			var ff := FontFile.new()
			if ff.load_dynamic_font(path) == OK:
				ThemeDB.fallback_font = ff
				print("[main] CJK 字体：", path)
				return
	push_warning("[main] 未找到系统中文字体，界面文字可能无法渲染")

# ---------------------------------------------------------------- 截图模式（节点流程证据 /tmp，不提交）

## 竖屏：scene/check/hub/dialog 四张；横屏（--mode=space）：叙事态一张。
func _run_shots_m2n() -> void:
	await get_tree().create_timer(0.8).timeout
	_on_home_navigate(&"entry")
	await get_tree().create_timer(0.3).timeout
	var entry := current_screen as ScreenEntry
	entry.pick_mode(ShellRouter.MODE_SPACE if _cli_mode == ShellRouter.MODE_SPACE else ShellRouter.MODE_TIME)
	entry.start_requested.emit()
	await get_tree().create_timer(0.5).timeout
	if _mode == ShellRouter.MODE_SPACE:
		await _shot("/tmp/m2n_landscape_story.png") # 横屏叙事态（N0-1，04 §③ 中央主视野）
		print("[shots] 横屏叙事态完成")
		get_tree().quit()
		return
	await _shot("/tmp/m2n_scene.png") # N0-1 scene
	_on_story_edge(0) # → N0-2 检定房
	await get_tree().create_timer(0.3).timeout
	await _shot("/tmp/m2n_check.png")
	_on_story_edge(0) # 掷检定（截图种子成功路）
	await get_tree().create_timer(1.2).timeout # 快掷落定 + 节点呈现
	_on_story_edge(0) # N0-3a → N0-4
	await get_tree().create_timer(0.3).timeout
	_on_story_edge(0) # N0-4 → N1-1 hub
	await get_tree().create_timer(0.3).timeout
	(shell as EncounterPortrait).hub_popup.open(graph.get_gold(), graph.hub_stock()) # 商店半屏弹层（04 §3.3）
	await get_tree().create_timer(0.3).timeout
	await _shot("/tmp/m2n_hub.png")
	(shell as EncounterPortrait).hub_popup.hide()
	# N1-1 → 前往褪色现场 N1-2（按文案找边：购买边数量随货单变化）
	var edges := graph.available_edges()
	for i: int in edges.size():
		if str((edges[i] as Dictionary).get("label", "")).contains("褪色现场"):
			_on_story_edge(i)
			break
	await get_tree().create_timer(0.3).timeout
	_on_story_edge(0) # N1-2 掷检定（成功 → N1-3）
	await get_tree().create_timer(1.2).timeout
	_on_story_edge(0) # N1-3 → 接触誊写庭 N1-4
	await get_tree().create_timer(0.3).timeout
	await _shot("/tmp/m2n_dialog.png")
	print("[shots] 竖屏四张完成：scene/check/hub/dialog")
	get_tree().quit()

func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("[shots] ", path, " err=", err)

# ---------------------------------------------------------------- 成长截图（角色界面⑦成长区证据 /tmp，不提交）

## ⑦ 角色：汇入 350 XP（跨 300 档升 Lv.2）+ 力 +1 后的成长区呈现：`-- --growth-shots`。
func _run_shots_growth() -> void:
	await get_tree().create_timer(0.8).timeout
	var prov := {"event_id": stream.tail(), "node_id": "", "pack_id": "campaign01"}
	var growth := Growth.new(board)
	growth.grant_xp(350, prov) # tech/04 §8 规则1/2：汇入即写 global.growth.xp，跨档自动升级
	growth.alloc("might", prov) # 规则3：属性点分配
	_encounter_id = "N1-7" # ⑦ 队伍卡数据源需要一场已登记遭遇（tech/02 §6）
	_show_character()
	await get_tree().create_timer(0.4).timeout
	await _shot("/tmp/growth_char.png")
	print("[shots] 角色界面成长区完成：/tmp/growth_char.png")
	get_tree().quit()

# ---------------------------------------------------------------- M3 截图（子游戏证据 /tmp，不提交）

## ② 入口卡 + 连战第一场（竖屏）：`-- --m3-shots`。
func _run_shots_m3() -> void:
	await get_tree().create_timer(1.2).timeout
	_on_home_navigate(&"entry")
	await get_tree().create_timer(0.3).timeout
	await _shot("/tmp/m3_entry.png") # ② 战役入口：子游戏特殊战役书卡（04 §6）
	if _subgames.is_empty():
		print("[shots] 无子游戏包，跳过连战截图")
		get_tree().quit()
		return
	var pid := str((_subgames.keys() as Array)[0])
	entitlements.shop_purchase(pid, "rcpt_m3_shots") # M3 截图前提：权利已点亮（M4 起 arena 有门槛）
	_on_subgame_start(pid, ShellRouter.MODE_TIME)
	await get_tree().create_timer(0.4).timeout
	_on_sub_story_edge(0) # A-0 → 踏入擂台
	await get_tree().create_timer(0.4).timeout
	var lo := current_screen as ScreenLoadout
	if lo != null:
		lo._on_confirm() # 空选择 = BattleDef 缺省出战（与战役引导同一兜底）
		await get_tree().create_timer(2.0).timeout # 探索演出 1s + 战斗铺开
	await _shot("/tmp/m3_battle.png") # 连战第一场（无休整，HP 持久 11 §7.1）
	print("[shots] M3 两张完成：/tmp/m3_entry.png /tmp/m3_battle.png")
	get_tree().quit()

# ---------------------------------------------------------------- 幕二截图（护送战/迷宫序列/撕页抉择证据 /tmp，不提交）

## `-- --act2-shots`：传送至幕二节点（仅截图证据，不走完整流程）——
## 护送战 N2S-2（缮写士入队）、雾码头探索序列 N2G-2（伏击拍）、撕页行动战后抉择 N2U-2。
func _run_shots_act2() -> void:
	await get_tree().create_timer(0.8).timeout
	_on_home_navigate(&"entry")
	await get_tree().create_timer(0.3).timeout
	var entry := current_screen as ScreenEntry
	entry.pick_mode(ShellRouter.MODE_TIME)
	entry.start_requested.emit()
	await get_tree().create_timer(0.5).timeout
	# 1) 护送战：整备 → 遭遇（缮写士以 escort_npc 入队，tech/02 §6 escort 块）
	graph._enter("N2S-2")
	_present_node()
	await get_tree().create_timer(0.3).timeout
	(current_screen as ScreenLoadout)._on_confirm()
	await get_tree().create_timer(1.8).timeout
	await _shot("/tmp/act2_escort.png")
	stream.emit(EventTypes.COMBAT_END, {"result": &"victory", "rounds": 3}, &"core", "N2S-2")
	await get_tree().create_timer(1.6).timeout
	# 2) 迷宫探索序列：N2G-2 第 1 拍检定 → 推进 → 第 2 拍伏击判定
	graph._enter("N2G-2")
	_maze = null
	_present_node()
	await get_tree().create_timer(0.4).timeout
	_on_story_edge(0) # 第 1 拍（检定）
	await get_tree().create_timer(1.2).timeout
	await _shot("/tmp/act2_maze.png") # 第 2 拍：伏击判定呈现
	# 3) 撕页行动：战斗 → 模拟胜利 → 战后抉择（撕/不撕双出边，tech/02 §6 hybrid）
	graph._enter("N2U-2")
	_maze = null
	_present_node()
	await get_tree().create_timer(0.3).timeout
	(current_screen as ScreenLoadout)._on_confirm()
	await get_tree().create_timer(1.8).timeout
	stream.emit(EventTypes.COMBAT_END, {"result": &"victory", "rounds": 2}, &"core", "N2U-2")
	await get_tree().create_timer(1.8).timeout
	await _shot("/tmp/act2_hybrid.png")
	print("[shots] 幕二三张完成：/tmp/act2_escort.png /tmp/act2_maze.png /tmp/act2_hybrid.png")
	get_tree().quit()

# ---------------------------------------------------------------- 幕三/终章截图（模式锁定演出 / 分支门 / 结局屏证据 /tmp，不提交）

## `-- --act3-shots`：横屏玩家路径——N2-C → N3-1 强制切竖屏壳（叙事化提示 toast，09 §3）→
## R4 分支门（[物·黑羽令] 左路捷径 / fallback 右路，tech/02 §4.3）→ E3 结局屏（tech/02 §9）。
func _run_shots_act3() -> void:
	await get_tree().create_timer(0.8).timeout
	_on_home_navigate(&"entry")
	await get_tree().create_timer(0.3).timeout
	var entry := current_screen as ScreenEntry
	entry.pick_mode(ShellRouter.MODE_SPACE) # 横屏玩家路径（强制幕换壳证据）
	entry.start_requested.emit()
	await get_tree().create_timer(0.5).timeout
	graph._enter("N2-C") # 横屏故事态就位（SL-2 随玩家所选形态）
	_present_node()
	await get_tree().create_timer(0.4).timeout
	_on_story_edge(0) # N2-C → N3-1：强制切竖屏 + 模式锁定叙事化提示
	await get_tree().create_timer(0.5).timeout
	await _shot("/tmp/act3_mode_lock.png")
	graph._enter("R4") # 分叉回廊分支门
	_present_node()
	await get_tree().create_timer(0.4).timeout
	await _shot("/tmp/act3_branch_gate.png")
	graph._enter("E3") # 结局屏：四分型文案 + 多周目钩子（endings.json）
	_present_node()
	await get_tree().create_timer(0.5).timeout
	await _shot("/tmp/act3_ending.png")
	print("[shots] 幕三/终章三张完成：/tmp/act3_mode_lock.png /tmp/act3_branch_gate.png /tmp/act3_ending.png")
	get_tree().quit()

# ---------------------------------------------------------------- 缺口批截图（手势/教程/图鉴证据 /tmp/gap_*.png，不提交）

## `-- --gap-shots`：启动卡（12 §4 第一层）→ 帮助页手势图鉴全表（12 §4 第三层）→ ⑥ 图鉴页（四系列进度）。
func _run_shots_gap() -> void:
	await get_tree().create_timer(1.0).timeout
	await _shot("/tmp/gap_tutorial.png") # 首次启动：3 页核心手势卡（可跳过）
	if current_screen is ScreenHome:
		var home := current_screen as ScreenHome
		home.tutorial.finish_launch()
		await get_tree().create_timer(0.2).timeout
		home._toggle_help()
		await get_tree().create_timer(0.3).timeout
		await _shot("/tmp/gap_help.png") # 帮助页：手势图鉴全表 + 重学入口
		home._toggle_help()
	# 图鉴页：注入两枚残简演示系列进度（仅截图证据，不写板正规流程——截图后即退出进程）
	board.unlock_lore("weaver_fragment_01",
		{"event_id": stream.tail(), "node_id": "", "pack_id": "campaign01"})
	board.give_item("codex_fragment", 1,
		{"event_id": stream.tail(), "node_id": "", "pack_id": "campaign01"})
	_on_home_navigate(&"inventory")
	await get_tree().create_timer(0.4).timeout
	await _shot("/tmp/gap_codex.png") # ⑥ 图鉴页：四系列进度 + 集齐奖励预告
	print("[shots] 缺口批三张完成：/tmp/gap_tutorial.png /tmp/gap_help.png /tmp/gap_codex.png")
	get_tree().quit()

# ---------------------------------------------------------------- 主屏热点图截图（12 §5 证据 /tmp，不提交）

## `-- --home-shot`：主屏可交互绘卷（烬港夜景程序化占位 + 五热点微光 + 底部兜底条）。
func _run_shot_home() -> void:
	await get_tree().create_timer(1.0).timeout
	if current_screen is ScreenHome:
		var home := current_screen as ScreenHome
		if home.tutorial != null:
			home.tutorial.finish_launch() # 跳过启动卡，取干净绘卷
		await get_tree().create_timer(0.6).timeout # 呼吸微光推进到非零相位
	await _shot("/tmp/home_hotspot.png")
	print("[shots] 主屏热点图完成：/tmp/home_hotspot.png")
	get_tree().quit()

## 主屏兜底条收起态（12 §5：toggle 可收起，收起为细条把手，绘卷占满）：`-- --home-bar-shot`（/tmp 不提交）。
func _run_shot_home_bar() -> void:
	await get_tree().create_timer(1.0).timeout
	if current_screen is ScreenHome:
		var home := current_screen as ScreenHome
		if home.tutorial != null:
			home.tutorial.finish_launch() # 跳过启动卡，取干净绘卷
		home.set_bar_collapsed(true, false) # 截图态不落盘（不写 user://settings.cfg）
		await get_tree().create_timer(0.6).timeout # 呼吸微光推进到非零相位
	await _shot("/tmp/home_bar_collapsed.png")
	print("[shots] 主屏兜底条收起态完成：/tmp/home_bar_collapsed.png")
	get_tree().quit()

# ---------------------------------------------------------------- M4 截图（锁定态 + 购买弹层证据 /tmp，不提交）

## ② 入口锁定态卡（06 §3.1：可见但锁定 + 叙事化包装）+ 购买半屏弹层（04 §3.3）：`-- --m4-shots`。
func _run_shots_m4() -> void:
	await get_tree().create_timer(1.2).timeout
	_on_home_navigate(&"entry")
	await get_tree().create_timer(0.4).timeout
	await _shot("/tmp/m4_lock.png") # 锁定态战役书卡（战绩照常呈现 + 守门人文案 +「获取」）
	_on_acquire_requested("arena")
	await get_tree().create_timer(0.4).timeout
	await _shot("/tmp/m4_shop.png") # 购买半屏弹层（06 §6：不离开当前界面情境）
	print("[shots] M4 两张完成：/tmp/m4_lock.png /tmp/m4_shop.png")
	get_tree().quit()
