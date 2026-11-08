# 节点流程版流程控制器（tech/01 §10；04 §2 导航闭环 + §3.1/§④.2/§④.3；07 §4 存档；09 §3/§6/§7/§9.1；tech/02 §3/§4/§5）
# 串流：①主屏 → ②战役入口（模式分支，09 §3）→ **故事图驱动节点流程**（序章 N0-1 → … → 幕一 N1-8）：
#   scene/check/dialog/hub 节点由双壳故事态呈现（StoryVM 单源）；battle 节点进整备→遭遇→战后边回图；
#   branch（N1-8）选择后出切片范围 → ⑨结算（成长加点 + 结算快照 07 §4.2）→ 回主屏 / ⑧历史卷轴。
# 存档时机（07 §4.2）：切片/遭遇结算完成（主快照）+ 主屏闲置（兜底）+ 主屏手动"记录抄本"；
# 遭遇进行中不存档——☰「保存并回主屏」= 恢复遭遇进入前快照（09 §7，战斗重打）；
# 故事态（遭遇外）☰ = 存档后回主屏（节点进度在图快照 meta.graph 内）。
# 战斗数值由 packs 资源表驱动（tech/04 §1~§4 / tech/02 §6）：BattleDef.assemble 组装，引用缺失 fail-fast。
# 调试：`-- --m2n-shots` 走图截图 /tmp/m2n_*.png（不提交）；`-- --mode=space|time` 预选形态。
extends Node

const BATTLE_SEED := 20260009 # 固定种子（tech/01 §5.2 确定性）：本切片主线两次检定均为成功路
const SLICE_ACTS: Array[String] = ["SL-0", "SL-1"] # 本切片范围：序章 + 幕一（出范围即切片终点）
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
}
var stream: EventStream
var board: Board
var rng: Rng
var graph: StoryGraph
var pack: Dictionary = {}
var router := ShellRouter.new()
var current_screen: Control = null
var shell: Control = null

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
	stream = EventStream.new()
	board = Board.new(stream)
	rng = Rng.new(BATTLE_SEED)
	graph = StoryGraph.new(board, rng, pack)
	stream.subscribe(_on_event)
	_show_home()
	if _shots:
		_run_shots_m2n()

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
	if shell != null: # 壳随离场回收（09 §7 结算态之后为正常离场）
		shell.queue_free()
		shell = null
	var home: ScreenHome = (load(SCREEN_SCENES[&"home"]) as PackedScene).instantiate()
	_swap(home)
	home.bind(board, graph.quest_badge_count(), _has_continuable())
	home.navigate.connect(_on_home_navigate)
	home.save_requested.connect(_save_home)
	home.idle_timeout.connect(_save_idle)
	router = ShellRouter.new() # 回主屏即离场：壳锁定随单局结束（09 §8）

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
	if not graph.visit_log.is_empty() and not graph.is_at_ending():
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

## 呈现当前节点：battle → 整备/遭遇；出切片范围/结局 → 切片结算；其余 → 双壳故事态。
func _present_node() -> void:
	if graph.is_at_ending() or not SLICE_ACTS.has(str(graph.current().get("act", ""))):
		_end_slice()
		return
	if str(graph.current().get("type", "")) == "battle":
		_enter_encounter()
		return
	var vm := StoryVM.build(graph, board, pack)
	_ensure_story_shell()
	_story_show(vm)

func _story_show(vm: Dictionary) -> void:
	if shell is EncounterPortrait:
		(shell as EncounterPortrait).show_story(vm)
	elif shell is EncounterLandscape:
		(shell as EncounterLandscape).show_story(vm)

## 故事壳就位：实例化/复用同一壳（09 §8 一局一壳），绑定故事回调（唯一指令通道）。
func _ensure_story_shell() -> void:
	if shell == null:
		shell = (load(SHELL_SCENES[_mode]) as PackedScene).instantiate()
		add_child(shell)
		shell.set("on_save_quit", Callable(self, "_on_save_quit"))
		if _mode == ShellRouter.MODE_SPACE and DisplayServer.get_name() != "headless":
			get_window().size = LANDSCAPE_SIZE
			get_window().move_to_center()
		router.lock_encounter(_mode) # 形态整场锁定（09 §3/§8：战役开始即定壳）
	if current_screen != null and current_screen != shell:
		current_screen.queue_free()
	current_screen = shell
	shell.visible = true
	shell.bind_story(stream, board, pack, {"edge": _on_story_edge, "hub": _on_hub_action})

## 玩家执行节点选项：check 边真实掷骰（11 §3，check.roll 事件驱动两级演出 09 §6）；
## dialog 选项回复进日志；边效果/on_enter 写板由 StoryGraph 落（07 §1 溯源）。
func _on_story_edge(idx: int) -> void:
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
	var gained := _grant_growth() # 11 §6：结算界面 = 成长加点时机（04 §⑨）
	_save("settle")
	_encounter_tail = _campaign_tail # 汇总区间 = 整个切片（逐项念给玩家听，04 §⑨）
	_encounter_result = &"slice"
	_show_settle(gained)

# ---------------------------------------------------------------- 整备（09 §9.1；tech/02 §2.4）

func _enter_encounter() -> void:
	var node := graph.current()
	_encounter_id = str(node.get("encounter", graph.current_id))
	_battle_title = str(node.get("title", _encounter_id))
	var cfg := Loadout.resolve_config(pack, _encounter_id)
	if not cfg.is_empty():
		cfg = cfg.duplicate() # 2→3 级技能槽 +1（11 §6；槽位基值仍读配置，tech/02 §2.4）
		cfg["skill_slots"] = int(cfg["skill_slots"]) \
			+ LightV1.skill_slot_bonus(LightV1.level_for_xp(int(board.read("campaign01.xp_total", 0))))
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
		"attr_points": int(board.read("campaign01.attr_points", 0)),
		"attrs": board.read("campaign01.attrs", {}), # 已分配值（单项 +3 封顶判定用，11 §6）
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

## 属性点分配写板（07 §1 溯源）；单项 ≤+3 封顶（11 §6），越顶拒绝整体分配并返回 false。
func _apply_attr_alloc(alloc: Dictionary, points_left: int) -> bool:
	var attrs: Dictionary = board.read("campaign01.attrs", {}).duplicate(true)
	for attr: String in alloc.keys():
		if int(attrs.get(attr, 0)) + int(alloc[attr]) > LightV1.ATTR_POINT_CAP:
			return false # 单项 ≤+3 封顶（11 §6）
	if alloc.is_empty() and points_left == int(board.read("campaign01.attr_points", 0)):
		return true
	var prov := {"event_id": stream.tail(), "node_id": graph.current_id, "pack_id": "campaign01"}
	for attr: String in alloc.keys():
		attrs[attr] = int(attrs.get(attr, 0)) + int(alloc[attr])
	board.write("campaign01.attrs", attrs, prov)
	board.write("campaign01.attr_points", points_left, prov)
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
	if ev["type"] == EventTypes.COMBAT_END and _in_encounter:
		_encounter_result = ev["payload"]["result"]
		_show_settle_deferred()

func _show_settle_deferred() -> void:
	await get_tree().create_timer(1.2).timeout
	_in_encounter = false
	if _encounter_result == &"victory":
		_battles_won += 1
		# 战斗是图内节点：胜利后走战后边回图（tech/02 §3 节点边结算）
		var edges := graph.available_edges()
		if edges.is_empty():
			_end_slice()
			return
		graph.take_edge(edges[0])
		_present_node()
	else:
		_save("settle") # 失败即分支：结算仍是元循环落笔（09 §7 失败不读档）
		_show_settle(0)

## 汇总区间 = 锚点之后的事件（04 §⑨：逐项念给玩家听）。
func _show_settle(attr_gained: int) -> void:
	var lines: Array[String] = []
	var xp := 0
	for ev: Dictionary in stream.since(_encounter_tail):
		var p: Dictionary = ev["payload"]
		match StringName(ev["type"]):
			EventTypes.XP_GAIN:
				xp += int(p.get("amount", 0))
			EventTypes.ITEM_GAIN:
				lines.append("获得：%s ×%d（已入背包）" % [_item_name(str(p.get("item_id", ""))),
					int(p.get("count", 1))])
			EventTypes.FLAG_WRITE:
				var fkey := str(p.get("key", ""))
				# 内部簿记键（成长/模式选择/金币/HP）不念给玩家（04 §⑨ 呈现语义：旗标变化摘要）
				if fkey.begins_with("campaign01.attr") or fkey == "campaign01.xp_total" \
						or fkey == "campaign01.gold" or fkey.begins_with("campaign01.hp.") \
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
	var level := int(board.read("campaign01.level", 1))
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
		"saved": true, "attr_points": int(board.read("campaign01.attr_points", 0)),
		"attrs": board.read("campaign01.attrs", {})})
	screen.allocate.connect(_on_settle_allocate)
	screen.go_home.connect(_show_home)
	screen.go_history.connect(func() -> void:
		_history_origin = &"settle"
		_show_history())

func _on_settle_allocate(attr: String) -> void:
	var points := int(board.read("campaign01.attr_points", 0))
	if points <= 0:
		return
	if not _apply_attr_alloc({attr: 1}, points - 1):
		return # 单项 +3 封顶（11 §6）：拒绝并保持界面
	_bind_settle() # 刷新可用点数与已分配值

## 成长（11 §6 成长表）：累计 XP 跨档即升级（300/700/1200），每级 HP+2、属性点 +1。
## 簿记：xp_total / level / attr_points / attrs / attr_granted 全在包命名空间（可存档、带溯源）。
## 返回本次新增属性点数。
func _grant_growth() -> int:
	var xp_total := 0
	for ev: Dictionary in stream.query_by_type(EventTypes.XP_GAIN):
		xp_total += int(ev["payload"].get("amount", 0))
	var prov := {"event_id": stream.tail(), "node_id": graph.current_id, "pack_id": "campaign01"}
	board.write("campaign01.xp_total", xp_total, prov)
	var level := LightV1.level_for_xp(xp_total)
	if level > int(board.read("campaign01.level", 1)):
		board.write("campaign01.level", level, prov)
		stream.emit(EventTypes.LOG, {"msg": "等级提升至 Lv.%d：HP+%d，属性点+%d（11 §6）" % [level,
			LightV1.hp_bonus_for_xp(xp_total), LightV1.attr_points_for_xp(xp_total)]}, &"core", graph.current_id)
	var earned := LightV1.attr_points_for_xp(xp_total)
	var granted := int(board.read("campaign01.attr_granted", 0))
	var gained := maxi(0, earned - granted)
	if gained > 0:
		board.write("campaign01.attr_points",
			int(board.read("campaign01.attr_points", 0)) + gained, prov)
		board.write("campaign01.attr_granted", earned, prov)
	return gained

# ---------------------------------------------------------------- ⑤⑥⑦⑧ 功能界面（04 §⑤⑥⑦⑧ 最小版）

func _show_quests() -> void:
	var screen: ScreenQuests = (load(SCREEN_SCENES[&"quests"]) as PackedScene).instantiate()
	_swap(screen)
	screen.bind(graph.quests())
	screen.back_requested.connect(_show_home)

func _show_inventory() -> void:
	var screen: ScreenInventory = (load(SCREEN_SCENES[&"inventory"]) as PackedScene).instantiate()
	_swap(screen)
	screen.bind(board.get_inv(), pack.get("items", {}), board.get_lore())
	screen.back_requested.connect(_show_home)

func _show_character() -> void:
	var screen: ScreenCharacter = (load(SCREEN_SCENES[&"character"]) as PackedScene).instantiate()
	_swap(screen)
	var bonds := {}
	for key: String in board.keys_with_prefix("global.bond."):
		bonds[key.trim_prefix("global.bond.")] = board.read(key)
	screen.bind(_battle_def({})["party"], bonds)
	screen.back_requested.connect(_show_home)

## ⑧ 历史卷轴：从主屏 / 结算进入，返回来源界面（04 §5 出口列）。
func _show_history() -> void:
	var screen: ScreenHistory = (load(SCREEN_SCENES[&"history"]) as PackedScene).instantiate()
	_swap(screen)
	screen.bind(stream, board)
	screen.back_requested.connect(func() -> void:
		if _history_origin == &"settle":
			_bind_settle() # 返回来源界面（04 §5 出口列：结算→卷轴→结算）
		else:
			_show_home())

# ---------------------------------------------------------------- 存档（07 §4）

func _bindings() -> Dictionary:
	return {"packs": {str(pack.get("pack_id", "campaign01")): int((pack.get("manifest", {}) as Dictionary).get("pack_version", 1))},
		"rule_pack": (pack.get("manifest", {}) as Dictionary).get("rule_pack", {}),
		"framework": "1.0.0"}

func _meta() -> Dictionary:
	return {"playthrough": 1, "created_at": Time.get_datetime_string_from_system(false, true),
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
