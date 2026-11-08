# TP4 界面闭环流程控制器（tech/01 §10 TP4；04 §2 导航闭环 + §5 检查表；07 §4 存档；09 §3/§7/§9.1）
# 串流：①主屏 → ②战役入口（模式分支，09 §3）→ 整备（09 §9.1）→ ③/④遭遇（壳路由 09 §2）→
#      ⑨结算（加点 + 结算快照 07 §4.2）→ 回主屏 / ⑧历史卷轴；⑤⑥⑦⑧ 由主屏进入、返回主屏。
# 存档时机（07 §4.2）：遭遇结算完成（主快照）+ 主屏闲置（兜底）+ 主屏手动"记录抄本"；
# 遭遇进行中不存档——☰「保存并回主屏」= 恢复遭遇进入前快照（09 §7，战斗重打）。
# 战役进度引导：序章 → N1-7 沿脚本化路径真实走 StoryGraph（L3 事件随节点触发/结算）；
# 遭遇战斗数值与队伍名单仍以引导脚本承载（TP2 留白：正式落位 packs 的 characters/enemies.json）。
# 调试：`-- --tp4-shots` 自动推进并截图 /tmp/tp4_*.png（不提交）；`-- --mode=space|time` 预选形态。
extends Node

const BATTLE_SEED := 20261108
const BATTLE_NODE := "N1-7"
const BATTLE_LINE := "SL-1"
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
## 整备备选技能池（TP2 留白承接：技能表正式落位 tech/04 skills.json 后由包数据供给）。
const SKILL_POOL := [
	{"id": "inkbolt", "name": "墨术飞矢", "kind": "attack", "attr": "wits",
		"damage": "1d6", "uses": 2, "target": "enemy"},
	{"id": "inkshield", "name": "墨盾格挡", "kind": "utility", "uses": 1, "target": "self",
		"effect": {"attackers_disadvantage": true}},
	{"id": "inklance", "name": "墨枪突刺", "kind": "attack", "attr": "might",
		"damage": "1d8", "uses": 1, "target": "enemy"},
]
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
var _encounter_result: StringName = &""
var _battles_won := 0
var _mode: StringName = &""
var _history_origin: StringName = &"home"
var _settle_lines: Array[String] = [] # 结算汇总缓存（卷轴往返 / 加点刷新复用）
var _shots := false

func _ready() -> void:
	_setup_cjk_font()
	var args := OS.get_cmdline_user_args()
	_shots = args.has("--tp4-shots")
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
		_run_shots_tp4()

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
	if shell != null: # 遭遇壳随离场回收（09 §7 结算态之后为正常离场）
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
		_enter_encounter() # 战役进行中：继续当前节点（主屏"继续"语义，04 §①）
		return
	_start_campaign()

## 序章 → N1-7 脚本化路径（TP4 引导：真实走 StoryGraph，L3 事件随节点触发/结算）。
func _start_campaign() -> void:
	graph.start()
	_walk_to_battle_node()
	# 序章带入（叙事既定）：N1-1 商店补给药水 ×2（战役书 §4 SL-1；TP2 引导脚本承接）
	board.give_item("heal_potion", 2,
		{"event_id": stream.tail(), "node_id": "N1-1", "pack_id": "campaign01"})
	_enter_encounter()

func _walk_to_battle_node() -> void:
	var guard := 0
	while graph.current_id != BATTLE_NODE and not graph.is_at_ending() and guard < 30:
		guard += 1
		var edge := _pick_scripted_edge()
		if edge.is_empty():
			push_warning("[main] 脚本路径在 %s 中断" % graph.current_id)
			break
		if str(edge.get("type", "")) == "check":
			graph.resolve_check(edge, true)
		else:
			graph.take_edge(edge)

## 沿测试同款主线择优（检定恒成功；hub 先买潮汐表；邀约选誊写庭）。
func _pick_scripted_edge() -> Dictionary:
	var edges: Array = graph.available_edges()
	var e := _edge_to(edges, BATTLE_NODE)
	if not e.is_empty():
		return e
	for target: String in ["N0-2", "N0-4", "N1-1", "N1-3", "N1-4", "N1-8", "N2S-1"]:
		e = _edge_to(edges, target)
		if not e.is_empty():
			return e
	for ev: Variant in edges: # hub：优先给物边（N1-1 买半页潮汐表，战役书 §8）
		for fx: Variant in (ev as Dictionary).get("effects", []):
			if (fx as Dictionary).has("give_item"):
				return ev
	return edges[0] if not edges.is_empty() else {}

func _edge_to(edges: Array, to: String) -> Dictionary:
	for ev: Variant in edges:
		if str((ev as Dictionary).get("to", "")) == to:
			return ev
	return {}

# ---------------------------------------------------------------- 整备（09 §9.1；tech/02 §2.4）

func _enter_encounter() -> void:
	var cfg := Loadout.resolve_config(pack, BATTLE_NODE)
	if not cfg.is_empty():
		cfg = cfg.duplicate() # 2→3 级技能槽 +1（11 §6；槽位基值仍读配置，tech/02 §2.4）
		cfg["skill_slots"] = int(cfg["skill_slots"]) \
			+ LightV1.skill_slot_bonus(LightV1.level_for_xp(int(board.read("campaign01.xp_total", 0))))
	if cfg.is_empty():
		_begin_encounter({"skills": _default_skill_ids(), "items": ["heal_potion"], "attr_alloc": {}})
		return
	var screen: ScreenLoadout = (load(SCREEN_SCENES[&"loadout"]) as PackedScene).instantiate()
	_swap(screen)
	screen.bind(cfg, _loadout_candidates())
	screen.confirmed.connect(_on_loadout_confirmed.bind(cfg))
	screen.back_requested.connect(_show_entry)

func _default_skill_ids() -> Array:
	return ["inkbolt", "inkshield"]

func _loadout_candidates() -> Dictionary:
	var items: Array = []
	if board.has_item("heal_potion"):
		items.append({"id": "heal_potion", "name": "补给药水",
			"count": board.item_count("heal_potion")})
	return {"skills": SKILL_POOL, "items": items,
		"attr_points": int(board.read("campaign01.attr_points", 0)),
		"attrs": board.read("campaign01.attrs", {}), # 已分配值（单项 +3 封顶判定用，11 §6）
		"attr_alloc": {"might": 0, "finesse": 0, "wits": 0}}

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
	shell = (load(SHELL_SCENES[_mode]) as PackedScene).instantiate()
	add_child(shell)
	if current_screen != null:
		current_screen.queue_free()
	current_screen = shell
	if _mode == ShellRouter.MODE_SPACE and DisplayServer.get_name() != "headless":
		get_window().size = LANDSCAPE_SIZE
		get_window().move_to_center()
	if shell is EncounterPortrait:
		(shell as EncounterPortrait).bind(sm, agent)
		(shell as EncounterPortrait).set_rooms(["N1-1", "N1-3", "N1-7", "N1-8"], 2,
			{"N1-1": "自由市广场", "N1-3": "见证撤销", "N1-7": "午夜墨雨", "N1-8": "三份邀约"})
	else:
		(shell as EncounterLandscape).bind(sm, agent)
	shell.set("on_save_quit", Callable(self, "_on_save_quit"))
	sm.enter(BATTLE_NODE)
	router.lock_encounter(_mode) # 遭遇开始即壳锁定（09 §8）
	sm.transition(EncounterSM.S_EXPLORE)
	stream.emit(EventTypes.LOG, {"msg": "午夜，墨色的雨。雨点落地成字，字扭曲着立起——墨魈朝着广场上唯一的「空白」涌来。"},
		&"core", BATTLE_NODE)
	await get_tree().create_timer(1.0).timeout
	if sm.state == EncounterSM.S_EXPLORE:
		sm.begin_combat(_battle_def(selection))

func _battle_def(selection: Dictionary) -> Dictionary:
	var picked: Array = selection.get("skills", _default_skill_ids())
	var skills: Array = []
	for sk: Variant in SKILL_POOL:
		if picked.has(str((sk as Dictionary)["id"])):
			skills.append((sk as Dictionary).duplicate(true))
	var attrs: Dictionary = board.read("campaign01.attrs", {})
	var hp_bonus := LightV1.hp_bonus_for_xp(int(board.read("campaign01.xp_total", 0))) # 每级 HP+2（11 §6）
	var pc_attrs := {"might": 2 + int(attrs.get("might", 0)),
		"finesse": 1 + int(attrs.get("finesse", 0)), "wits": 0 + int(attrs.get("wits", 0))}
	var items: Array = []
	if (selection.get("items", []) as Array).has("heal_potion") and board.has_item("heal_potion"):
		items.append({"id": "heal_potion", "name": "补给药水",
			"count": board.item_count("heal_potion"),
			"use": {"timing": "bonus_action", "heal": "1d4+2", "consume": true}})
	return {
		"party": [
			{"id": "pc", "name": "白页者", "kind": "player", "hp": 14 + hp_bonus, "max_hp": 14 + hp_bonus,
				"ac": 11,
				"attrs": pc_attrs, "attack_mod": 2 + int(attrs.get("might", 0)), "damage": "1d6+2",
				"skills": skills, "items": items},
			{"id": "kelan", "name": "珂兰", "kind": "companion", "hp": 10, "max_hp": 10, "ac": 11,
				"attrs": {"might": 0, "finesse": 1, "wits": 1}, "attack_mod": 1, "damage": "1d6+1",
				"skills": [{"id": "kelan_bolt", "name": "墨矢", "kind": "attack", "attr": "finesse",
					"damage": "1d6+1", "target": "enemy"}]},
			{"id": "laofei", "name": "老费", "kind": "companion", "hp": 12, "max_hp": 12, "ac": 12,
				"attrs": {"might": 1, "finesse": 0, "wits": 1}, "attack_mod": 1, "damage": "1d6+1",
				"skills": [{"id": "laofei_hook", "name": "船钩", "kind": "attack", "attr": "might",
					"damage": "1d6+1", "target": "enemy"}]},
		],
		"enemies": [
			{"id": "boss", "name": "墨魈", "hp": 16, "max_hp": 16, "ac": 11,
				"attrs": {"might": 1, "finesse": 1, "wits": 0}, "attack_mod": 3, "damage": "1d4+1",
				"skills": [{"id": "ink_rain", "name": "墨雨溅射", "kind": "aoe", "damage": "1d6",
					"uses": 2, "cooldown": 2,
					"save": {"attr": "finesse", "dc": 11, "on_success": "half"}}]},
			{"id": "imp1", "name": "墨魈幼体", "hp": 8, "max_hp": 8, "ac": 10,
				"attrs": {"might": 0, "finesse": 0, "wits": 0}, "attack_mod": 2, "damage": "1d4"},
			{"id": "imp2", "name": "墨魈幼体", "hp": 8, "max_hp": 8, "ac": 10,
				"attrs": {"might": 0, "finesse": 0, "wits": 0}, "attack_mod": 2, "damage": "1d4"},
		],
		"party_advantage_rounds": 1 if bool(board.read("campaign01.witnessed_revocation")) else 0,
		"loot": [{"item": "ink_core", "n": 1}],
		"xp": 100,
	}

## ☰「保存并回主屏」（09 §7）：遭遇进行中不存档，回到遭遇进入前快照（本局重打）。
func _on_save_quit() -> void:
	if shell != null:
		shell.queue_free()
		shell = null
	SaveSystem.apply(_encounter_snapshot, board, rng) # 恢复遭遇进入前的世界状态（战斗不写板，RNG 归位）
	graph.deserialize(_encounter_snapshot["meta"].get("graph", {}))
	stream.emit(EventTypes.LOG, {"msg": "你合上抄本。这一页的雨，被轻轻翻回了开头。"}, &"core")
	_in_encounter = false
	_save("quit_home") # 恢复后的世界状态落档（遭遇外时机，07 §4.2）
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
		var gained := _grant_growth() # 成长：XP 换算属性点（原型规则）
		_save("settle") # 遭遇结算完成 = 主快照点（07 §4.2）
		_show_settle(gained)
	else:
		_save("settle") # 失败即分支：结算仍是元循环落笔（09 §7 失败不读档）
		_show_settle(0)

## 汇总区间 = 遭遇开始锚点之后的事件（04 §⑨：逐项念给玩家听）。
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
				# 内部簿记键（成长/模式选择）不念给玩家（04 §⑨ 呈现语义：旗标变化摘要）
				if fkey.begins_with("campaign01.attr") or fkey == "campaign01.xp_total" \
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
	screen.bind({"title": "午夜墨雨", "result": String(_encounter_result), "lines": _settle_lines,
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
	var prov := {"event_id": stream.tail(), "node_id": BATTLE_NODE, "pack_id": "campaign01"}
	board.write("campaign01.xp_total", xp_total, prov)
	var level := LightV1.level_for_xp(xp_total)
	if level > int(board.read("campaign01.level", 1)):
		board.write("campaign01.level", level, prov)
		stream.emit(EventTypes.LOG, {"msg": "等级提升至 Lv.%d：HP+%d，属性点+%d（11 §6）" % [level,
			LightV1.hp_bonus_for_xp(xp_total), LightV1.attr_points_for_xp(xp_total)]}, &"core", BATTLE_NODE)
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

# ---------------------------------------------------------------- 截图模式（TP4 证据 /tmp，不提交）

func _run_shots_tp4() -> void:
	await get_tree().create_timer(0.8).timeout
	await _shot("/tmp/tp4_home.png")
	_on_home_navigate(&"entry")
	await get_tree().create_timer(0.4).timeout
	await _shot("/tmp/tp4_entry.png")
	var entry := current_screen as ScreenEntry
	entry.pick_mode(ShellRouter.MODE_TIME)
	entry.start_requested.emit()
	await get_tree().create_timer(0.4).timeout
	var lo := current_screen as ScreenLoadout
	lo._toggle_skill("inkbolt")
	lo._toggle_skill("inkshield")
	lo._toggle_item("heal_potion")
	await get_tree().create_timer(0.2).timeout
	await _shot("/tmp/tp4_loadout.png")
	lo._on_confirm()
	await get_tree().create_timer(2.0).timeout # 进场延时 + 战斗开始
	# 托管打完（2× 节拍，09 §9.3）
	(shell as EncounterPortrait).set_speed(2)
	(shell as EncounterPortrait).set_auto(true)
	var guard := 0
	while _in_encounter and guard < 300:
		guard += 1
		await get_tree().create_timer(0.2).timeout
	await get_tree().create_timer(0.5).timeout
	await _shot("/tmp/tp4_settle.png")
	var st := current_screen as ScreenSettle
	st.go_history.emit()
	await get_tree().create_timer(0.4).timeout
	await _shot("/tmp/tp4_history.png")
	print("[shots] 战斗结果：", _encounter_result, " 胜场：", _battles_won)
	get_tree().quit()

func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("[shots] ", path, " err=", err)
