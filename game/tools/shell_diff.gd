# 双壳事件流比对工具（tech/01 §10 TP3；白皮书 §7.3 数据零差异）
# 同一脚本化遭遇（同种子、同指令序列）分别在竖屏壳与横屏壳实例中完整跑一遍——
# 指令一律经壳的 press_action_index / debug_step_auto 探针下发（与点按/托管同一 Command 通道），
# 导出两壳各自驱动下 core 产出的事件流（JSON 规范化序列化：sort_keys + full_precision），逐字节比对。
# 用法：/Applications/Godot.app/Contents/MacOS/Godot --headless --path game -s tools/shell_diff.gd
# 产物：/tmp/tp3_stream_portrait.json、/tmp/tp3_stream_landscape.json（不提交）。
extends SceneTree

const SHELL_SCENES := {
	&"time": "res://shell/portrait/encounter_portrait.tscn",
	&"space": "res://shell/landscape/encounter_landscape.tscn",
}
const OUT_PORTRAIT := "/tmp/tp3_stream_portrait.json"
const OUT_LANDSCAPE := "/tmp/tp3_stream_landscape.json"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	print("== 双壳事件流比对（TP3：数据零差异，白皮书 §7.3）==")
	var ok := true
	var pair := await run_pair(self, 20261108, 7, false)
	ok = report("普通局（脚本化指令）", pair) and ok
	for i: int in 3: # 乱序压力版：同种子 bot 指令序列（含托管命令）两壳各 3 局
		var p2 := await run_pair(self, 20261108 + i, 100 + i * 31, true)
		ok = report("托管乱序局 %d" % (i + 1), p2) and ok
	print("[shell_diff] 总结：", "全部逐字节一致 ✅" if ok else "存在差异 ❌")
	quit(0 if ok else 1)

static func report(tag: String, pair: Dictionary) -> bool:
	var same: bool = pair["portrait"] == pair["landscape"]
	print("[shell_diff] %s：事件 %d 条，两壳事件流逐字节%s一致" % [tag, int(pair["count"]),
		"" if same else "【不】"])
	if not same:
		push_error("[shell_diff] %s 双壳事件流不一致！产物见 %s / %s" % [tag, OUT_PORTRAIT, OUT_LANDSCAPE])
	return same

## 两壳各跑一遍同一遭遇，返回 {portrait, landscape, count}（JSON 字符串 + 事件数）。
static func run_pair(tree: SceneTree, seed: int, bot_seed: int, auto_mix: bool) -> Dictionary:
	var a := await run_battle(tree, &"time", seed, bot_seed, auto_mix)
	var b := await run_battle(tree, &"space", seed, bot_seed, auto_mix)
	_write(OUT_PORTRAIT, str(a["json"]))
	_write(OUT_LANDSCAPE, str(b["json"]))
	return {"portrait": a["json"], "landscape": b["json"], "count": a["count"],
		"result": a["result"]}

static func _write(path: String, content: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)

## 单壳整局：同种子 + 同 bot 指令序列（经壳探针下发），返回 {json, count, result}。
## board_preset：可选板预置回调（如换肤禁区断言预写外观旗标，06 §4）——在 SM 建组前调用，
## 预置只许写与战斗逻辑无关的键；断言方负责证明事件流逐字节一致。
static func run_battle(tree: SceneTree, shell_kind: StringName, seed: int, bot_seed: int,
		auto_mix: bool, board_preset: Callable = Callable()) -> Dictionary:
	var stream := EventStream.new()
	var board := Board.new(stream)
	var preset_anchor := 0
	if board_preset.is_valid():
		board_preset.call(board, stream)
		preset_anchor = stream.tail() # 预置（如换肤写板）在对局锚点之前：比对只覆盖同指令对局段
	var sm := EncounterSM.new(board, stream, Rng.new(seed), "campaign01")
	var agent := AutoAgent.new()
	# 序章带入（与 main.gd 同一脚本化遭遇）：补给药水 ×2 + 见证撤销旗标
	board.give_item("heal_potion", 2, {"event_id": 0, "node_id": "N1-1", "pack_id": "campaign01"})
	board.write("campaign01.witnessed_revocation", true,
		{"event_id": 0, "node_id": "N1-3", "pack_id": "campaign01"})
	var shell: Control = (load(SHELL_SCENES[shell_kind]) as PackedScene).instantiate()
	tree.root.add_child(shell)
	if shell is EncounterPortrait:
		(shell as EncounterPortrait).set_rooms(["N1-1", "N1-3", "N1-7", "N1-8"], 2)
	else:
		# 横屏壳按其设计屏幕尺寸实例化（09 §4 冻结指标面向横屏；项目视口为竖屏 390×760）
		shell.set_anchors_preset(Control.PRESET_TOP_LEFT)
		shell.size = Vector2(1280, 720)
	shell.bind(sm, agent)
	sm.enter("N1-7")
	sm.transition(EncounterSM.S_EXPLORE)
	stream.emit(EventTypes.LOG, {"msg": "午夜，墨色的雨。"}, &"core", "N1-7")
	sm.begin_combat(battle_def())
	await tree.process_frame
	await tree.process_frame
	var bot := Rng.new(bot_seed)
	var guard := 0
	while not sm.is_over() and guard < 300:
		guard += 1
		var actions := sm.get_available_actions()
		if actions.is_empty():
			await tree.process_frame
			continue
		if auto_mix and bot.range_int(1, 4) == 1: # 1/4 概率走托管通道（source=auto，09 §9.3）
			shell.debug_step_auto()
		else:
			var enabled: Array[int] = []
			for i: int in actions.size():
				if not bool(actions[i]["disabled"]):
					enabled.append(i)
			var pick := enabled[bot.range_int(0, enabled.size() - 1)]
			shell.press_action_index(pick)
		await tree.process_frame
	# 有预置时比对锚点后的对局段（换肤禁区断言：预置写板差异属对局外动作，06 §4 比对口径=同指令对局段）
	var events: Array = stream.since(preset_anchor) if preset_anchor > 0 else stream.all()
	var json := JSON.stringify(events, "", true, true)
	var out := {"json": json, "count": stream.size(), "result": str(sm.result())}
	shell.queue_free()
	await tree.process_frame
	return out

## N1-7 午夜墨雨战斗定义（与 main.gd 同一脚本化遭遇，战役书 §7 教学 Boss 墨魈）。
static func battle_def() -> Dictionary:
	return {
		"party": [
			{"id": "pc", "ref": "player_blank", "name": "白页者", "kind": "player", "hp": 14, "max_hp": 14, "ac": 11,
				"art_ref": "portraits/player_blank", # 纯呈现随行（tech/05 §6；双壳同一 def，事件流零差异）
				"attrs": {"might": 2, "finesse": 1, "wits": 0}, "attack_mod": 2, "damage": "1d6+2",
				"skills": [
					{"id": "inkbolt", "name": "墨术飞矢", "kind": "attack", "attr": "wits",
						"damage": "1d6", "uses": 2, "target": "enemy"},
					{"id": "inkshield", "name": "墨盾格挡", "kind": "utility", "uses": 1, "target": "self",
						"effect": {"attackers_disadvantage": true}},
				],
				"items": [{"id": "heal_potion", "name": "补给药水", "count": 2,
					"use": {"timing": "bonus_action", "heal": "1d4+2", "consume": true}}]},
			{"id": "kelan", "ref": "companion_kelan", "name": "珂兰", "kind": "companion", "hp": 10, "max_hp": 10, "ac": 11,
				"art_ref": "portraits/companion_kelan",
				"attrs": {"might": 0, "finesse": 1, "wits": 1}, "attack_mod": 1, "damage": "1d6+1",
				"skills": [{"id": "kelan_bolt", "name": "墨矢", "kind": "attack", "attr": "finesse",
					"damage": "1d6+1", "target": "enemy"}]},
			{"id": "laofei", "ref": "companion_laofei", "name": "老费", "kind": "companion", "hp": 12, "max_hp": 12, "ac": 12,
				"art_ref": "portraits/companion_laofei",
				"attrs": {"might": 1, "finesse": 0, "wits": 1}, "attack_mod": 1, "damage": "1d6+1",
				"skills": [{"id": "laofei_hook", "name": "船钩", "kind": "attack", "attr": "might",
					"damage": "1d6+1", "target": "enemy"}]},
		],
		"enemies": [
			{"id": "boss", "name": "墨魈", "hp": 16, "max_hp": 16, "ac": 11,
				"art_ref": "units/ink_fiend",
				"attrs": {"might": 1, "finesse": 1, "wits": 0}, "attack_mod": 3, "damage": "1d4+1",
				"skills": [{"id": "ink_rain", "name": "墨雨溅射", "kind": "aoe", "damage": "1d6",
					"uses": 2, "cooldown": 2,
					"save": {"attr": "finesse", "dc": 11, "on_success": "half"}}]},
			{"id": "imp1", "name": "墨魈幼体", "hp": 8, "max_hp": 8, "ac": 10,
				"art_ref": "units/ink_imp",
				"attrs": {"might": 0, "finesse": 0, "wits": 0}, "attack_mod": 2, "damage": "1d4"},
			{"id": "imp2", "name": "墨魈幼体", "hp": 8, "max_hp": 8, "ac": 10,
				"art_ref": "units/ink_imp",
				"attrs": {"might": 0, "finesse": 0, "wits": 0}, "attack_mod": 2, "damage": "1d4"},
		],
		"party_advantage_rounds": 1,
		"loot": [{"item": "ink_core", "n": 1}],
		"xp": 100,
	}
