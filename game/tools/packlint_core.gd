# packlint 校验核（docs/tech/02-内容包格式规范.md §12 V1~V10 + docs/tech/04-资源与效果系统.md §6 V11~V13）
# 纯数据校验，零引擎依赖（RefCounted），供 tools/packlint.gd（CLI）与 tests/run.gd 复用。
# 每条结论：{v, level, msg}；level ∈ PASS / WARN / FAIL / NA。
# V11~V13 自 M2 起实检资源四表（tech/04 §6）；仅 V10 界面闭环保留 N/A 及原因。
class_name PacklintCore
extends RefCounted

const LEVEL_PASS := "PASS"
const LEVEL_WARN := "WARN"
const LEVEL_FAIL := "FAIL"
const LEVEL_NA := "N/A"

## 轻规则包 v1 §2 技能表（V12 检定技能合法值；_or_ 双技能取两者较高，11 文档 §2）。
const LIGHT_SKILLS := ["athletics", "intimidate", "stealth", "thievery",
	"perception", "investigation", "history", "persuasion", "soothe"]
const DIFFICULTIES := ["easy", "medium", "hard"]
const ITEM_ROLES := ["stat", "check_mod", "branch_key", "codex"] # tech/02 §7 四重身份
const STRATEGIES := ["buyout_component", "dlc", "subscription", "cosmetic", "free"] # tech/02 §2.3
## 框架层权利变量注册表路径（06 文档 §2.3：全部合法权利变量登记在运营侧注册表
## packs/_ops/entitlements.json——数据文件，非代码常量；新增权利 = 运营侧登记一行）。
const ENTITLEMENT_REGISTRY_PATH := "res://packs/_ops/entitlements.json"

## 加载权利注册表。返回 {ok, error, entitlements: Array[id]}；文件缺失 / JSON 损坏 /
## 结构非法均给明确错误——V9 据此前置 FAIL，不静默按空表放行（06 §2.3）。
static func load_entitlement_registry(path: String = ENTITLEMENT_REGISTRY_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "entitlements": [],
			"error": "权利注册表缺失：%s（06 §2.3：注册表落 packs/_ops/entitlements.json）" % path}
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if raw == null or not raw is Dictionary or not (raw as Dictionary).get("entitlements") is Array:
		return {"ok": false, "entitlements": [],
			"error": "权利注册表 JSON 解析失败或缺 entitlements 数组：%s（06 §2.3）" % path}
	var out: Array = []
	for e: Variant in (raw as Dictionary)["entitlements"]:
		if e is Dictionary and not str((e as Dictionary).get("id", "")).is_empty():
			out.append(str((e as Dictionary)["id"]))
	return {"ok": true, "error": "", "entitlements": out}
const EFFECT_KEYS := ["write", "value", "clock", "alignment", "give_item", "remove_item", "xp", "lore"]
const COND_KEYS := ["clock", "alignment", "bond_max", "all", "any"]
const EFFECT_PREFIXES := ["rep.", "bond.", "clock."]
const COND_PREFIXES := ["flag.", "rep.", "item.", "bond.", "clock."]
# ---- tech/04 合法值集合（V11~V13；规则包 light v1 注册的属性/枚举）----
const ATTRS := ["might", "finesse", "wits"]                       # 11 文档 §1 三属性
const MODIFIABLE_ATTRS := ["attack_damage", "ac", "hp_max"]       # tech/04 §5.1 规则包注册可修饰属性
const EFFECT_OPS := ["add", "mul", "override", "clamp_max", "clamp_min"] # tech/04 §5.1
const EFFECT_DURATIONS := ["encounter", "rest", "campaign", "permanent"] # tech/04 §5.1
const EFFECT_STACKS := ["refresh", "stack", "unique"]             # tech/04 §5.1
const SKILL_KINDS := ["attack", "check", "heal", "utility"]       # tech/04 §3
const SKILL_TARGETS := ["enemy_single", "ally_single", "self"]    # tech/04 §3
const GESTURES := ["tap", "path"]                                 # tech/04 §3（12 文档手势）
const STATUS_KEYS := ["attackers_disadvantage", "ac_bonus", "duration_rounds"] # EncounterSM statuses 键
const SAVE_KEYS := ["attr", "dc", "on_success"]                   # 11 文档 §5.1
const SAVE_ON_SUCCESS := ["half", "none"]                         # 11 文档 §5.1
const ITEM_USE_TIMINGS := ["action", "bonus_action", "out_of_combat"] # tech/04 §4
const ITEM_USE_EFFECT_KEYS := ["heal"]                            # tech/04 §4 v1 落位（扁平键）

## registry = load_entitlement_registry() 的返回形态；缺省空字典 = 从默认路径现读
## （06 §2.3：注册表是运营侧数据文件）。测试可注入损坏/缺失形态做 V9 负例。
static func lint(pack: Dictionary, registry: Dictionary = {}) -> Array:
	if registry.is_empty():
		registry = load_entitlement_registry()
	var issues: Array = []
	issues.append_array(_v1_no_dead_end(pack))
	issues.append_array(_v2_no_unreachable(pack))
	issues.append_array(_v3_failure_path(pack))
	issues.append_array(_v4_flag_closure(pack))
	issues.append_array(_v5_clock_bounded(pack))
	issues.append_array(_v6_node_budget(pack))
	issues.append_array(_v7_namespace(pack))
	issues.append_array(_v8_portrait_constraint(pack))
	issues.append_array(_v9_entitlement(pack, registry))
	issues.append({"v": "V10", "level": LEVEL_NA,
		"msg": "界面闭环：九类界面入口/出口检查依赖 shell 界面实现（04 文档 §5），TP2/TP4 落地后方可数据化"})
	issues.append_array(_v11_resource_refs(pack))
	issues.append_array(_v12_legal_keys(pack))
	issues.append_array(_v13_uses_consume(pack))
	return issues

static func has_failures(issues: Array) -> bool:
	for issue: Dictionary in issues:
		if issue["level"] == LEVEL_FAIL:
			return true
	return false

# ---------------------------------------------------------------- 图遍历工具

## 全图邻接（V1/V2 共用）：边条件按"可满足即通"处理（任务裁决）——choice/reputation/check/item/
## doom_clock 五类边一律计为可通，check 取 success+failure 双路，item 取主路+fallback。
static func _adjacency(pack: Dictionary) -> Dictionary:
	var adj := {}
	var nodes: Dictionary = pack["nodes"]
	for nid: String in nodes.keys():
		var outs: Array = []
		for edge: Variant in (nodes[nid] as Dictionary).get("edges", []):
			var e: Dictionary = edge
			for key: String in ["to", "success", "failure", "fallback"]:
				if e.has(key) and not str(e[key]).is_empty():
					outs.append(str(e[key]))
		adj[nid] = outs
	return adj

static func _bfs(adj: Dictionary, start_ids: Array, reverse: bool) -> Dictionary:
	var graph := adj
	if reverse:
		graph = {}
		for nid: String in adj.keys():
			graph[nid] = []
		for nid: String in adj.keys():
			for to: Variant in adj[nid]:
				if graph.has(to):
					graph[to].append(nid)
	var seen := {}
	var queue: Array = start_ids.duplicate()
	for s: Variant in start_ids:
		seen[s] = true
	while not queue.is_empty():
		var nid: String = queue.pop_front()
		for to: Variant in graph.get(nid, []):
			if not seen.has(to):
				seen[to] = true
				queue.append(to)
	return seen

# ---------------------------------------------------------------- 效果/条件收集

## 全包效果出处：[{effect, where}]（节点 on_enter/on_complete/边效果/成败效果 + events.json settle）。
static func _collect_effects(pack: Dictionary) -> Array:
	var out: Array = []
	for nid: String in pack.get("node_order", []):
		var node: Dictionary = pack["nodes"][nid]
		for effect: Variant in node.get("on_enter", []):
			out.append({"effect": effect, "where": "%s.on_enter" % nid})
		for effect: Variant in node.get("on_complete", []):
			out.append({"effect": effect, "where": "%s.on_complete" % nid})
		var edges: Array = node.get("edges", [])
		for i: int in edges.size():
			var e: Dictionary = edges[i]
			for field: String in ["effects", "success_effects", "failure_effects"]:
				for effect: Variant in e.get(field, []):
					out.append({"effect": effect, "where": "%s.edge[%d].%s" % [nid, i, field]})
	for ev: Variant in pack.get("events", []):
		var evd: Dictionary = ev
		for effect: Variant in evd.get("settle", []):
			out.append({"effect": effect, "where": "events.%s.settle" % str(evd.get("id", "?"))})
	return out

## 全包条件出处：[{cond, where}]（边 requires + endings.conditions + events trigger.requires）。
static func _collect_conditions(pack: Dictionary) -> Array:
	var out: Array = []
	for nid: String in pack.get("node_order", []):
		var edges: Array = (pack["nodes"][nid] as Dictionary).get("edges", [])
		for i: int in edges.size():
			var e: Dictionary = edges[i]
			if e.has("requires"):
				out.append({"cond": e["requires"], "where": "%s.edge[%d].requires" % [nid, i]})
	for ending: Variant in pack.get("endings", []):
		var ed: Dictionary = ending
		if not (ed.get("conditions", {}) as Dictionary).is_empty():
			out.append({"cond": ed["conditions"], "where": "endings.%s" % str(ed.get("id", "?"))})
	for ev: Variant in pack.get("events", []):
		var evd: Dictionary = ev
		var trig: Dictionary = evd.get("trigger", {})
		if trig.has("requires"):
			out.append({"cond": trig["requires"], "where": "events.%s.trigger" % str(evd.get("id", "?"))})
	return out

# ---------------------------------------------------------------- V1 无死路（tech/02 §12）

static func _v1_no_dead_end(pack: Dictionary) -> Array:
	var issues: Array = []
	var nodes: Dictionary = pack["nodes"]
	var bad_target := false
	for nid: String in pack.get("node_order", []):
		var node: Dictionary = nodes[nid]
		if str(node.get("type", "")) == "ending":
			continue
		if (node.get("edges", []) as Array).is_empty():
			issues.append({"v": "V1", "level": LEVEL_FAIL, "msg": "非结局节点 %s 无出边（死路）" % nid})
		for edge: Variant in node.get("edges", []):
			for key: String in ["to", "success", "failure", "fallback"]:
				if edge.has(key):
					var to := str(edge[key])
					if not to.is_empty() and not nodes.has(to):
						issues.append({"v": "V1", "level": LEVEL_FAIL,
							"msg": "节点 %s 的边指向不存在的节点 '%s'" % [nid, to]})
						bad_target = true
	if bad_target:
		return issues
	# 每条路径可达某结局：自结局反向遍历全覆盖
	var endings: Array = []
	for nid: String in pack.get("node_order", []):
		if str((nodes[nid] as Dictionary).get("type", "")) == "ending":
			endings.append(nid)
	if endings.is_empty():
		issues.append({"v": "V1", "level": LEVEL_FAIL, "msg": "包内无结局节点"})
		return issues
	var can_reach := _bfs(_adjacency(pack), endings, true)
	for nid: String in pack.get("node_order", []):
		if not can_reach.has(nid):
			issues.append({"v": "V1", "level": LEVEL_FAIL, "msg": "节点 %s 无法到达任何结局" % nid})
	if issues.is_empty():
		issues.append({"v": "V1", "level": LEVEL_PASS, "msg": "无死路；全部节点可达某结局"})
	return issues

# ---------------------------------------------------------------- V2 无不可达节点

static func _v2_no_unreachable(pack: Dictionary) -> Array:
	var issues: Array = []
	var order: Array = pack.get("node_order", [])
	if order.is_empty():
		return [{"v": "V2", "level": LEVEL_FAIL, "msg": "包内无节点"}]
	var entry := str(order[0])
	var seen := _bfs(_adjacency(pack), [entry], false)
	for nid: String in order:
		if not seen.has(nid):
			issues.append({"v": "V2", "level": LEVEL_FAIL, "msg": "节点 %s 自入口 %s 不可达" % [nid, entry]})
	if issues.is_empty():
		issues.append({"v": "V2", "level": LEVEL_PASS,
			"msg": "自入口 %s 全图遍历覆盖 %d 节点（边条件按可满足即通）" % [entry, order.size()]})
	return issues

# ---------------------------------------------------------------- V3 失败路完备（tech/02 §4.2 硬规则、08 文档 §2）

static func _v3_failure_path(pack: Dictionary) -> Array:
	var issues: Array = []
	var nodes: Dictionary = pack["nodes"]
	var checks := 0
	for nid: String in pack.get("node_order", []):
		var edges: Array = (nodes[nid] as Dictionary).get("edges", [])
		for i: int in edges.size():
			var e: Dictionary = edges[i]
			if str(e.get("type", "")) != "check":
				continue
			checks += 1
			var where := "%s.edge[%d]" % [nid, i]
			if not e.has("failure") or str(e.get("failure", "")).is_empty():
				issues.append({"v": "V3", "level": LEVEL_FAIL,
					"msg": "%s 检定边缺 failure（tech/02 §4.2：校验器拒绝无失败路的检定边）" % where})
				continue
			var failure := str(e["failure"])
			if failure == str(e.get("success", "")):
				# 型式 B 代价汇合：差异必须体现在成败效果（tech/02 §4.2）；
				# alt_pass 是规范声明的替代通过方式（资源代价落位，如 N2G-1 支付金币），视同差异化代价。
				if (e.get("failure_effects", []) as Array).is_empty()  and (e.get("success_effects", []) as Array).is_empty() and not e.has("alt_pass"):
					issues.append({"v": "V3", "level": LEVEL_FAIL,
						"msg": "%s 成败同点汇合但无差异化效果（空转汇合，08 文档 §2 禁止）" % where})
			elif nodes.has(failure) and str((nodes[failure] as Dictionary).get("type", "")) != "ending"  and ((nodes[failure] as Dictionary).get("edges", []) as Array).is_empty():
				issues.append({"v": "V3", "level": LEVEL_FAIL,
					"msg": "%s 失败路 %s 无出边（失败锁死，08 文档 §2 禁止）" % [where, failure]})
	if issues.is_empty():
		issues.append({"v": "V3", "level": LEVEL_PASS, "msg": "%d 条检定边失败路完备" % checks})
	return issues

# ---------------------------------------------------------------- V4 旗标闭环（tech/02 §8、§12）

static func _v4_flag_closure(pack: Dictionary) -> Array:
	var issues: Array = []
	var pack_id := str(pack.get("pack_id", ""))
	# 图内实际写入（nodes + events settle；write 键省略前缀自动解析为本包命名空间，tech/02 §4.6）
	var written := {} # flag_id -> [where]
	for rec: Dictionary in _collect_effects(pack):
		var effect: Dictionary = rec["effect"]
		if effect.has("write"):
			var fid := str(effect["write"])
			if "." in fid:
				continue # 全键（跨包/global）不计包内台账
			if not written.has(fid):
				written[fid] = []
			written[fid].append(str(rec["where"]))
	# 图内实际读取（条件 flag.<id>）
	var read := {}
	for rec: Dictionary in _collect_conditions(pack):
		_collect_flag_reads(rec["cond"], str(rec["where"]), read)
	# 台账比对
	var declared := {}
	for f: Variant in pack.get("flags", []):
		declared[str((f as Dictionary).get("id", ""))] = f
	for fid: String in written.keys():
		if not declared.has(fid):
			issues.append({"v": "V4", "level": LEVEL_FAIL,
				"msg": "旗标 %s.%s 图内写入但未在 flags.json 登记（写入处：%s）" % [pack_id, fid, ",".join(written[fid])]})
	for fid: String in declared.keys():
		if fid.is_empty():
			issues.append({"v": "V4", "level": LEVEL_FAIL, "msg": "flags.json 存在缺 id 条目"})
			continue
		if not written.has(fid):
			issues.append({"v": "V4", "level": LEVEL_FAIL,
				"msg": "旗标 %s 已登记但图内无写入点（孤立旗标）" % fid})
			continue
		if not read.has(fid):
			issues.append({"v": "V4", "level": LEVEL_WARN,
				"msg": "旗标 %s 无图层条件读取；声明读取点为 UI/演出面（%s），需人工核对"  % [fid, ";".join(_reader_strings(declared[fid]))]})
		# 声明写入点的节点号须存在（容忍"N4-4 尾声结算"式描述，取首 token）
		for w: Variant in (declared[fid] as Dictionary).get("writers", []):
			var token := str(w).get_slice(" ", 0).get_slice("（", 0)
			if _looks_like_node_id(token) and not (pack["nodes"] as Dictionary).has(token):
				issues.append({"v": "V4", "level": LEVEL_WARN,
					"msg": "旗标 %s 声明写入点 '%s' 非图节点（按转写决策并入结局/L3 事件结算），实际写入存在：%s"  % [fid, token, ",".join(written[fid])]})
	if not issues.any(func(i: Dictionary) -> bool: return i["level"] == LEVEL_FAIL):
		issues.append({"v": "V4", "level": LEVEL_PASS,
			"msg": "旗标台账闭环：%d 登记 / %d 图内写入" % [declared.size(), written.size()]})
	return issues

static func _collect_flag_reads(cond: Dictionary, where: String, read: Dictionary) -> void:
	for key: Variant in cond.keys():
		var k := str(key)
		if k == "all" or k == "any":
			for sub: Variant in cond[key]:
				_collect_flag_reads(sub, where, read)
		elif k.begins_with("flag."):
			var fid := k.substr(5)
			if "." in fid:
				continue
			if not read.has(fid):
				read[fid] = []
			read[fid].append(where)

static func _reader_strings(flag_decl: Dictionary) -> Array:
	var out: Array = []
	for r: Variant in flag_decl.get("readers", []):
		out.append(str(r))
	return out

static func _looks_like_node_id(s: String) -> bool:
	if s.is_empty() or s.length() > 8:
		return false
	var c := s.substr(0, 1)
	return c == "N" or c == "R" or c == "E"

# ---------------------------------------------------------------- V5 时间钟有界 + E4 兜底

static func _v5_clock_bounded(pack: Dictionary) -> Array:
	var issues: Array = []
	var pos := 0
	var neg := 0
	for rec: Dictionary in _collect_effects(pack):
		var effect: Dictionary = rec["effect"]
		if effect.has("clock"):
			var d := int(effect["clock"])
			if d > 0:
				pos += d
			else:
				neg += d
	var default_ending := ""
	for ending: Variant in pack.get("endings", []):
		if bool((ending as Dictionary).get("default", false)):
			default_ending = str((ending as Dictionary).get("id", ""))
	if default_ending.is_empty():
		issues.append({"v": "V5", "level": LEVEL_FAIL,
			"msg": "endings.json 缺 default: true 兜底结局（tech/02 §9，战役书 §9 E4 失败非终局）"})
	if pos > Board.CLOCK_MAX:
		issues.append({"v": "V5", "level": LEVEL_FAIL,
			"msg": "全包正向时钟效果代数和 +%d 超过上限 %d（单周目可证越界）" % [pos, Board.CLOCK_MAX]})
	if issues.is_empty():
		issues.append({"v": "V5", "level": LEVEL_PASS,
			"msg": "时钟效果代数和 +%d/%d（界 0~%d，写入钳位兜底）；E4 兜底 = %s"  % [pos, neg, Board.CLOCK_MAX, default_ending]})
	return issues

# ---------------------------------------------------------------- V6 节点预算（tech/02 §12：派生后缀与结局节点不计）

static func _v6_node_budget(pack: Dictionary) -> Array:
	var issues: Array = []
	var mains := {}
	for nid: String in pack.get("node_order", []):
		var node: Dictionary = pack["nodes"][nid]
		if str(node.get("type", "")) == "ending":
			continue
		mains[_main_node_id(nid)] = true
	var budget := int((pack["manifest"] as Dictionary).get("node_budget", 0))
	if mains.size() > budget:
		issues.append({"v": "V6", "level": LEVEL_FAIL,
			"msg": "逻辑节点 %d 超预算 %d（08 文档 §4：超预算须拆包，不允许例外放行）" % [mains.size(), budget]})
	else:
		issues.append({"v": "V6", "level": LEVEL_PASS,
			"msg": "逻辑节点 %d/%d（实际节点 %d，派生与结局不计）"  % [mains.size(), budget, (pack["nodes"] as Dictionary).size()]})
	return issues

## 派生后缀剥离（campaign01 README 转写决策：主编号 + 小写后缀）：N1-2b→N1-2、N2G-2c→N2G-2、R4-r→R4。
static func _main_node_id(nid: String) -> String:
	var re := RegEx.new()
	re.compile("^(.*?\\d+)[a-z]+$|^(.*\\D)-[a-z]+$")
	var m := re.search(nid)
	if m == null:
		return nid
	return m.get_string(1) if not m.get_string(1).is_empty() else m.get_string(2)

# ---------------------------------------------------------------- V7 命名空间（tech/02 §12、07 文档 §3）

static func _v7_namespace(pack: Dictionary) -> Array:
	var issues: Array = []
	var pack_id := str(pack.get("pack_id", ""))
	# 写旗标：带前缀的全键不得越出本包命名空间（global 变量走效果键，不经 write）
	for rec: Dictionary in _collect_effects(pack):
		var effect: Dictionary = rec["effect"]
		if effect.has("write"):
			var fid := str(effect["write"])
			if "." in fid and not fid.begins_with(pack_id + "."):
				issues.append({"v": "V7", "level": LEVEL_FAIL,
					"msg": "%s 写旗标 '%s' 越出本包命名空间 %s（07 §3：跨包写禁止）" % [str(rec["where"]), fid, pack_id]})
	# 条件旗标：保守约束包外引用（跨包读虽运行时可行，上线包不允许隐式耦合）
	for rec: Dictionary in _collect_conditions(pack):
		_v7_check_cond(rec["cond"], str(rec["where"]), pack_id, issues)
	if issues.is_empty():
		issues.append({"v": "V7", "level": LEVEL_PASS,
			"msg": "包内旗标引用均落在 %s.* 或省略前缀自动解析" % pack_id})
	return issues

static func _v7_check_cond(cond: Dictionary, where: String, pack_id: String, issues: Array) -> void:
	for key: Variant in cond.keys():
		var k := str(key)
		if k == "all" or k == "any":
			for sub: Variant in cond[key]:
				_v7_check_cond(sub, where, pack_id, issues)
		elif k.begins_with("flag."):
			var fid := k.substr(5)
			if "." in fid and not fid.begins_with(pack_id + "."):
				issues.append({"v": "V7", "level": LEVEL_FAIL,
					"msg": "%s 读旗标 '%s' 越出本包命名空间 %s" % [where, fid, pack_id]})

# ---------------------------------------------------------------- V8 竖屏约束（tech/02 §6、04 文档 §④.4）

static func _v8_portrait_constraint(pack: Dictionary) -> Array:
	var issues: Array = []
	var n := 0
	for eid: String in (pack["encounters"] as Dictionary).keys():
		var enc: Dictionary = pack["encounters"][eid]
		if str(enc.get("mode", "")) == "forced_time":
			n += 1
			if int(enc.get("max_units", 0)) > 8:
				issues.append({"v": "V8", "level": LEVEL_FAIL,
					"msg": "遭遇 %s forced_time 但 max_units=%d > 8（tech/02 §6 校验器强制）"  % [eid, int(enc.get("max_units", 0))]})
	if issues.is_empty():
		issues.append({"v": "V8", "level": LEVEL_PASS, "msg": "%d 场 forced_time 遭遇 max_units 均 ≤8" % n})
	return issues

# ---------------------------------------------------------------- V9 权利与策略一致（tech/02 §2.2/§2.3、06 文档 §3.2）

static func _v9_entitlement(pack: Dictionary, registry: Dictionary) -> Array:
	var issues: Array = []
	# 注册表本身不可读 = 前置 FAIL 并给出明确错误（06 §2.3：文件缺失/损坏不静默放行）
	if not bool(registry.get("ok", false)):
		issues.append({"v": "V9", "level": LEVEL_FAIL, "msg": str(registry.get("error", "权利注册表不可用"))})
		return issues
	var registered: Array = registry["entitlements"]
	var manifest: Dictionary = pack["manifest"]
	var entitlement: Dictionary = manifest.get("entitlement", {})
	var monetization: Dictionary = manifest.get("monetization", {})
	var requires: Array = entitlement.get("requires", [])
	var strategies: Array = monetization.get("strategies", [])
	for s: Variant in strategies:
		if not STRATEGIES.has(str(s)):
			issues.append({"v": "V9", "level": LEVEL_FAIL,
				"msg": "monetization.strategies 含非法值 '%s'（tech/02 §2.3 合法值集合）" % str(s)})
	for r: Variant in requires:
		var rv := str(r)
		if not rv.begins_with("entitlement.") or rv.length() <= "entitlement.".length():
			issues.append({"v": "V9", "level": LEVEL_FAIL,
				"msg": "entitlement.requires 条目 '%s' 非 global.entitlement.* 权利变量形态（06 文档 §2.3）" % rv})
		elif not registered.has(rv):
			issues.append({"v": "V9", "level": LEVEL_FAIL,
				"msg": "entitlement.requires 条目 '%s' 未在权利注册表登记（%s，06 文档 §2.3）" % [rv, ENTITLEMENT_REGISTRY_PATH]})
	if strategies.has("dlc") and requires.is_empty():
		issues.append({"v": "V9", "level": LEVEL_FAIL,
			"msg": "strategies 含 dlc 但 entitlement.requires 缺省（tech/02 §2.3 一致性硬规则）"})
	if strategies == ["free"] and not requires.is_empty():
		issues.append({"v": "V9", "level": LEVEL_FAIL,
			"msg": "strategies 为 [free] 不得声明 requires（tech/02 §2.3）"})
	if issues.is_empty():
		if requires.is_empty() and strategies.is_empty():
			issues.append({"v": "V9", "level": LEVEL_PASS,
				"msg": "entitlement/monetization 双缺省 = 随本体权利与策略（tech/02 §2.2/§2.3）"})
		else:
			issues.append({"v": "V9", "level": LEVEL_PASS, "msg": "权利与策略声明一致"})
	return issues

# ---------------------------------------------------------------- V11 资源引用闭环（tech/04 §6）

static func _v11_resource_refs(pack: Dictionary) -> Array:
	var issues: Array = []
	var items: Dictionary = pack["items"]
	var lore_ids := {}
	for l: Variant in pack.get("lore", []):
		lore_ids[str((l as Dictionary).get("id", ""))] = true
	var encounters: Dictionary = pack["encounters"]
	var nodes: Dictionary = pack["nodes"]

	# item 边 / 效果 / 条件引用的道具存在
	for nid: String in pack.get("node_order", []):
		var edges: Array = (nodes[nid] as Dictionary).get("edges", [])
		for i: int in edges.size():
			var e: Dictionary = edges[i]
			if str(e.get("type", "")) == "item" and not items.has(str(e.get("item", ""))):
				issues.append({"v": "V11", "level": LEVEL_FAIL,
					"msg": "%s.edge[%d] 引用未登记道具 '%s'（items.json）" % [nid, i, str(e.get("item", ""))]})
	for rec: Dictionary in _collect_effects(pack):
		var effect: Dictionary = rec["effect"]
		for key: String in ["give_item", "remove_item"]:
			if effect.has(key) and not items.has(str(effect[key])):
				issues.append({"v": "V11", "level": LEVEL_FAIL,
					"msg": "%s 效果 %s 引用未登记道具 '%s'" % [str(rec["where"]), key, str(effect[key])]})
		if effect.has("lore") and not lore_ids.has(str(effect["lore"])):
			issues.append({"v": "V11", "level": LEVEL_FAIL,
				"msg": "%s 效果 lore 引用未登记图鉴条目 '%s'（lore.json）" % [str(rec["where"]), str(effect["lore"])]})
	for rec: Dictionary in _collect_conditions(pack):
		_v11_check_cond(rec["cond"], str(rec["where"]), items, issues)

	# 节点 encounter 引用存在；遭遇回指节点存在
	for nid: String in pack.get("node_order", []):
		var node: Dictionary = nodes[nid]
		if node.has("encounter"):
			var enc_id := str(node["encounter"])
			if not encounters.has(enc_id):
				issues.append({"v": "V11", "level": LEVEL_FAIL,
					"msg": "节点 %s 引用未登记遭遇 '%s'（encounters.json）" % [nid, enc_id]})
		else:
			var t := str(node.get("type", ""))
			if ["battle", "explore", "rest", "hub"].has(t):
				issues.append({"v": "V11", "level": LEVEL_WARN,
					"msg": "节点 %s 类型 %s 缺 encounter 关联（tech/02 §3：战斗/迷宫/休整节点必填）" % [nid, t]})
	for eid: String in encounters.keys():
		var ref := str((encounters[eid] as Dictionary).get("node", ""))
		if not ref.is_empty() and not nodes.has(ref):
			issues.append({"v": "V11", "level": LEVEL_FAIL,
				"msg": "遭遇 %s 回指不存在的节点 '%s'" % [eid, ref]})
	# 事件触发/落点节点存在
	for ev: Variant in pack.get("events", []):
		var evd: Dictionary = ev
		var trig: Dictionary = evd.get("trigger", {})
		for key: String in ["node"]:
			if trig.has(key) and not nodes.has(str(trig[key])):
				issues.append({"v": "V11", "level": LEVEL_FAIL,
					"msg": "事件 %s 触发引用不存在的节点 '%s'" % [str(evd.get("id", "?")), str(trig[key])]})
		if evd.has("node") and not nodes.has(str(evd["node"])):
			issues.append({"v": "V11", "level": LEVEL_FAIL,
				"msg": "事件 %s 落点引用不存在的节点 '%s'" % [str(evd.get("id", "?")), str(evd["node"])]})
	# 道具身份合法值（tech/02 §7）
	for iid: String in items.keys():
		for role: Variant in (items[iid] as Dictionary).get("roles", []):
			if not ITEM_ROLES.has(str(role)):
				issues.append({"v": "V11", "level": LEVEL_FAIL,
					"msg": "道具 %s 身份 '%s' 非法（tech/02 §7 四重身份）" % [iid, str(role)]})

	# ---- tech/04 §6 资源引用闭环（M2 实检）----
	var characters: Dictionary = pack.get("characters", {})
	var skills: Dictionary = pack.get("skills", {})
	var enemies: Dictionary = pack.get("enemies", {})
	var effects: Dictionary = pack.get("effects", {})
	# 角色 → 技能（skills[] 与 basic_attack 均须登记）；熟练 ∈ 规则包技能表（11 §2）
	for cid: String in characters.keys():
		var c: Dictionary = characters[cid]
		for sid: Variant in c.get("skills", []):
			if not skills.has(str(sid)):
				issues.append({"v": "V11", "level": LEVEL_FAIL,
					"msg": "角色 %s 引用未登记技能 '%s'（skills.json）" % [cid, str(sid)]})
		var ba := str(c.get("basic_attack", ""))
		if not ba.is_empty() and not skills.has(ba):
			issues.append({"v": "V11", "level": LEVEL_FAIL,
				"msg": "角色 %s basic_attack 引用未登记技能 '%s'（skills.json）" % [cid, ba]})
		for prof: Variant in c.get("proficiencies", []):
			if not LIGHT_SKILLS.has(str(prof)):
				issues.append({"v": "V11", "level": LEVEL_FAIL,
					"msg": "角色 %s 熟练 '%s' 未在绑定规则包 light v1 注册（11 §2）" % [cid, str(prof)]})
	# 遭遇 → 敌人/角色/战利品道具（tech/02 §6）
	for eid: String in encounters.keys():
		var enc: Dictionary = encounters[eid]
		for entry: Variant in enc.get("enemies", []):
			if not enemies.has(str((entry as Dictionary).get("ref", ""))):
				issues.append({"v": "V11", "level": LEVEL_FAIL,
					"msg": "遭遇 %s enemies 引用未登记敌人 '%s'（enemies.json）"
						% [eid, str((entry as Dictionary).get("ref", ""))]})
		for entry: Variant in enc.get("party", []):
			if not characters.has(str((entry as Dictionary).get("ref", ""))):
				issues.append({"v": "V11", "level": LEVEL_FAIL,
					"msg": "遭遇 %s party 引用未登记角色 '%s'（characters.json）"
						% [eid, str((entry as Dictionary).get("ref", ""))]})
		for l: Variant in enc.get("loot", []):
			if not items.has(str((l as Dictionary).get("item", ""))):
				issues.append({"v": "V11", "level": LEVEL_FAIL,
					"msg": "遭遇 %s 战利品引用未登记道具 '%s'（items.json）"
						% [eid, str((l as Dictionary).get("item", ""))]})
		if str(enc.get("type", "")) == "battle" and (enc.get("enemies", []) as Array).is_empty():
			issues.append({"v": "V11", "level": LEVEL_WARN,
				"msg": "战斗遭遇 %s 未声明 enemies（tech/02 §6）：敌人阵容待内容定稿" % eid})
	# 效果 → 规则包注册属性（tech/04 §5.1：target_attr 须在绑定规则包注册）
	for eid: String in effects.keys():
		var ta := str((effects[eid] as Dictionary).get("target_attr", ""))
		if not _registered_attr(ta):
			issues.append({"v": "V11", "level": LEVEL_FAIL,
				"msg": "效果 %s target_attr '%s' 未在绑定规则包注册（tech/04 §5.1）" % [eid, ta]})
	if not issues.any(func(i: Dictionary) -> bool: return i["level"] == LEVEL_FAIL):
		issues.append({"v": "V11", "level": LEVEL_PASS,
			"msg": "资源引用闭环：%d 道具 / %d 图鉴 / %d 遭遇 / %d 事件 / %d 角色 / %d 技能 / %d 敌人引用均可解析"
				% [items.size(), lore_ids.size(), encounters.size(), (pack.get("events", []) as Array).size(),
					characters.size(), skills.size(), enemies.size()]})
	return issues

## target_attr 注册判定：基础可修饰属性（tech/04 §5.1）∪ check_mod.<规则包技能>。
static func _registered_attr(ta: String) -> bool:
	if MODIFIABLE_ATTRS.has(ta):
		return true
	if ta.begins_with("check_mod."):
		return LIGHT_SKILLS.has(ta.trim_prefix("check_mod."))
	return false

static func _v11_check_cond(cond: Dictionary, where: String, items: Dictionary, issues: Array) -> void:
	for key: Variant in cond.keys():
		var k := str(key)
		if k == "all" or k == "any":
			for sub: Variant in cond[key]:
				_v11_check_cond(sub, where, items, issues)
		elif k.begins_with("item.") and not items.has(k.substr(5)):
			issues.append({"v": "V11", "level": LEVEL_FAIL,
				"msg": "%s 条件引用未登记道具 '%s'" % [where, k.substr(5)]})

# ---------------------------------------------------------------- V12 效果与条件键合法值（tech/04 §6、tech/02 §4.6）

static func _v12_legal_keys(pack: Dictionary) -> Array:
	var issues: Array = []
	for rec: Dictionary in _collect_effects(pack):
		for key: Variant in (rec["effect"] as Dictionary).keys():
			if not _effect_key_legal(str(key)):
				issues.append({"v": "V12", "level": LEVEL_FAIL,
					"msg": "%s 含未登记效果键 '%s'（tech/02 §4.6 词汇表）" % [str(rec["where"]), str(key)]})
	for rec: Dictionary in _collect_conditions(pack):
		_v12_check_cond(rec["cond"], str(rec["where"]), issues)
	# 检定边：技能名在绑定规则包注册 + 难度三档（08 文档 §1 校验硬规则）
	for nid: String in pack.get("node_order", []):
		var edges: Array = (pack["nodes"][nid] as Dictionary).get("edges", [])
		for i: int in edges.size():
			var e: Dictionary = edges[i]
			if str(e.get("type", "")) != "check":
				continue
			var where := "%s.edge[%d]" % [nid, i]
			if not DIFFICULTIES.has(str(e.get("difficulty", ""))):
				issues.append({"v": "V12", "level": LEVEL_FAIL,
					"msg": "%s 难度 '%s' 非法（轻规则三档 easy/medium/hard，11 文档 §3）" % [where, str(e.get("difficulty", ""))]})
			for skill: String in str(e.get("skill", "")).split("_or_", false):
				if not LIGHT_SKILLS.has(skill):
					issues.append({"v": "V12", "level": LEVEL_FAIL,
						"msg": "%s 技能 '%s' 未在绑定规则包 light v1 注册（11 文档 §2）" % [where, skill]})
	# ---- tech/04 §6 资源合法值（M2 实检）----
	# 效果修饰器：op / duration / stack 合法值；stack=stack 需 max_stack（tech/04 §5.1）
	for eid: String in (pack.get("effects", {}) as Dictionary).keys():
		var fx: Dictionary = pack["effects"][eid]
		if not EFFECT_OPS.has(str(fx.get("op", ""))):
			issues.append({"v": "V12", "level": LEVEL_FAIL,
				"msg": "效果 %s op '%s' 非法（tech/04 §5.1：add/mul/override/clamp_max/clamp_min）"
					% [eid, str(fx.get("op", ""))]})
		if not EFFECT_DURATIONS.has(str(fx.get("duration", ""))):
			issues.append({"v": "V12", "level": LEVEL_FAIL,
				"msg": "效果 %s duration '%s' 非法（tech/04 §5.1）" % [eid, str(fx.get("duration", ""))]})
		if not EFFECT_STACKS.has(str(fx.get("stack", ""))):
			issues.append({"v": "V12", "level": LEVEL_FAIL,
				"msg": "效果 %s stack '%s' 非法（tech/04 §5.1）" % [eid, str(fx.get("stack", ""))]})
		elif str(fx.get("stack", "")) == "stack" and not fx.has("max_stack"):
			issues.append({"v": "V12", "level": LEVEL_FAIL,
				"msg": "效果 %s stack=stack 缺 max_stack（tech/04 §5.1 叠层需上限）" % eid})
	# 技能：kind/target/attr/gesture 合法值；effect 键与 save 块合法（tech/04 §3、11 §5.1）
	for sid: String in (pack.get("skills", {}) as Dictionary).keys():
		var sk: Dictionary = pack["skills"][sid]
		var where := "skills.%s" % sid
		if not SKILL_KINDS.has(str(sk.get("kind", ""))):
			issues.append({"v": "V12", "level": LEVEL_FAIL,
				"msg": "%s kind '%s' 非法（tech/04 §3：attack/check/heal/utility）" % [where, str(sk.get("kind", ""))]})
		if not SKILL_TARGETS.has(str(sk.get("target", ""))):
			issues.append({"v": "V12", "level": LEVEL_FAIL,
				"msg": "%s target '%s' 非法（tech/04 §3）" % [where, str(sk.get("target", ""))]})
		if sk.has("attr") and not ATTRS.has(str(sk["attr"])):
			issues.append({"v": "V12", "level": LEVEL_FAIL,
				"msg": "%s attr '%s' 非法（11 §1 三属性）" % [where, str(sk["attr"])]})
		if sk.has("gesture") and not GESTURES.has(str(sk["gesture"])):
			issues.append({"v": "V12", "level": LEVEL_FAIL,
				"msg": "%s gesture '%s' 非法（tech/04 §3：tap/path）" % [where, str(sk["gesture"])]})
		if str(sk.get("kind", "")) == "attack" and (not sk.has("attr") or not sk.has("damage")):
			issues.append({"v": "V12", "level": LEVEL_FAIL,
				"msg": "%s attack 技能缺 attr/damage（tech/04 §3：走检定公式必填）" % where})
		for key: Variant in (sk.get("effect", {}) as Dictionary).keys():
			if not STATUS_KEYS.has(str(key)):
				issues.append({"v": "V12", "level": LEVEL_FAIL,
					"msg": "%s effect 含未登记状态键 '%s'（EncounterSM statuses）" % [where, str(key)]})
		if sk.has("save"):
			_check_save(sk["save"], where, issues)
	# 敌人内联技能：save 块合法（11 §5.1）；uses/cooldown 为非负整数
	for eid: String in (pack.get("enemies", {}) as Dictionary).keys():
		for sk: Variant in (pack["enemies"][eid] as Dictionary).get("skills", []):
			var s: Dictionary = sk
			var where := "enemies.%s.%s" % [eid, str(s.get("id", "?"))]
			if s.has("attr") and not ATTRS.has(str(s["attr"])):
				issues.append({"v": "V12", "level": LEVEL_FAIL,
					"msg": "%s attr '%s' 非法（11 §1 三属性）" % [where, str(s["attr"])]})
			if s.has("save"):
				_check_save(s["save"], where, issues)
	# 道具 use 块：timing 合法值（tech/04 §4）
	for iid: String in (pack.get("items", {}) as Dictionary).keys():
		var it: Dictionary = pack["items"][iid]
		if it.has("use") and not ITEM_USE_TIMINGS.has(str((it["use"] as Dictionary).get("timing", ""))):
			issues.append({"v": "V12", "level": LEVEL_FAIL,
				"msg": "items.%s use.timing '%s' 非法（tech/04 §4：action/bonus_action/out_of_combat）"
					% [iid, str((it["use"] as Dictionary).get("timing", ""))]})
	if issues.is_empty():
		issues.append({"v": "V12", "level": LEVEL_PASS,
			"msg": "效果键 / 条件键 / 检定技能与难度 / 资源枚举（op·duration·stack·save·timing）均为合法值"})
	return issues

## save 块校验（11 §5.1）：键集 ⊆ {attr,dc,on_success}，attr ∈ 三属性，on_success ∈ {half,none}，dc 为数值。
static func _check_save(save: Variant, where: String, issues: Array) -> void:
	if not save is Dictionary:
		issues.append({"v": "V12", "level": LEVEL_FAIL, "msg": "%s save 块非对象（11 §5.1）" % where})
		return
	var sv: Dictionary = save
	for key: Variant in sv.keys():
		if not SAVE_KEYS.has(str(key)):
			issues.append({"v": "V12", "level": LEVEL_FAIL,
				"msg": "%s save 含未登记键 '%s'（11 §5.1：attr/dc/on_success）" % [where, str(key)]})
	if sv.has("attr") and not ATTRS.has(str(sv["attr"])):
		issues.append({"v": "V12", "level": LEVEL_FAIL,
			"msg": "%s save.attr '%s' 非法（11 §1 三属性）" % [where, str(sv["attr"])]})
	if sv.has("on_success") and not SAVE_ON_SUCCESS.has(str(sv["on_success"])):
		issues.append({"v": "V12", "level": LEVEL_FAIL,
			"msg": "%s save.on_success '%s' 非法（11 §5.1：half/none）" % [where, str(sv["on_success"])]})
	if sv.has("dc") and not (sv["dc"] is float or sv["dc"] is int):
		issues.append({"v": "V12", "level": LEVEL_FAIL,
			"msg": "%s save.dc 非数值（11 §5.1）" % where})

# ---------------------------------------------------------------- V13 次数制与 consume 语义（tech/04 §6，M2 实检）

static func _v13_uses_consume(pack: Dictionary) -> Array:
	var issues: Array = []
	var checked := 0
	# 次数制技能 uses ≥ 1（tech/04 §3 uses_per_encounter；null = 不限次不检）
	for sid: String in (pack.get("skills", {}) as Dictionary).keys():
		var sk: Dictionary = pack["skills"][sid]
		if sk.get("uses_per_encounter") != null:
			checked += 1
			if int(sk["uses_per_encounter"]) < 1:
				issues.append({"v": "V13", "level": LEVEL_FAIL,
					"msg": "技能 %s uses_per_encounter=%d < 1（tech/04 §6 V13：次数制技能 uses≥1）"
						% [sid, int(sk["uses_per_encounter"])]})
	# 敌人内联次数制技能 uses ≥ 1
	for eid: String in (pack.get("enemies", {}) as Dictionary).keys():
		for sk: Variant in (pack["enemies"][eid] as Dictionary).get("skills", []):
			var s: Dictionary = sk
			if s.has("uses"):
				checked += 1
				if int(s["uses"]) < 1:
					issues.append({"v": "V13", "level": LEVEL_FAIL,
						"msg": "敌人 %s 技能 %s uses=%d < 1（tech/04 §6 V13）"
							% [eid, str(s.get("id", "?")), int(s["uses"])]})
	# consume 道具语义（tech/04 §4/§6：不得在遭遇外静默消失——数据侧可证部分）
	for iid: String in (pack.get("items", {}) as Dictionary).keys():
		var it: Dictionary = pack["items"][iid]
		var use: Dictionary = it.get("use", {})
		var declared_consume := bool(use.get("consume", false)) or bool(it.get("consume", false))
		if declared_consume:
			checked += 1
			if use.is_empty():
				issues.append({"v": "V13", "level": LEVEL_FAIL,
					"msg": "道具 %s consume:true 但无 use 块（tech/04 §4：无使用效果即静默消失）" % iid})
			elif use.get("timing") == null:
				issues.append({"v": "V13", "level": LEVEL_FAIL,
					"msg": "道具 %s consume:true 但 use 缺 timing（tech/04 §4：无行动经济落点）" % iid})
			elif not ITEM_USE_EFFECT_KEYS.any(func(k: String) -> bool: return use.has(k)):
				issues.append({"v": "V13", "level": LEVEL_FAIL,
					"msg": "道具 %s consume:true 但 use 无效果键（%s，tech/04 §4 v1 扁平键）"
						% [iid, "/".join(ITEM_USE_EFFECT_KEYS)]})
		elif not use.is_empty():
			checked += 1
	if issues.is_empty():
		issues.append({"v": "V13", "level": LEVEL_PASS,
			"msg": "次数制技能 uses≥1、consume 道具均有 use 效果落点（%d 项实检）" % checked})
	return issues

static func _effect_key_legal(k: String) -> bool:
	if EFFECT_KEYS.has(k):
		return true
	for p: String in EFFECT_PREFIXES:
		if k.begins_with(p) and k.length() > p.length():
			return true
	return false

static func _cond_key_legal(k: String) -> bool:
	if COND_KEYS.has(k):
		return true
	for p: String in COND_PREFIXES:
		if k.begins_with(p) and k.length() > p.length():
			return true
	return false

static func _v12_check_cond(cond: Dictionary, where: String, issues: Array) -> void:
	for key: Variant in cond.keys():
		var k := str(key)
		if not _cond_key_legal(k):
			issues.append({"v": "V12", "level": LEVEL_FAIL,
				"msg": "%s 含未登记条件键 '%s'（tech/02 §4.6 词汇表）" % [where, k]})
		elif k == "all" or k == "any":
			for sub: Variant in cond[key]:
				_v12_check_cond(sub, where, issues)
