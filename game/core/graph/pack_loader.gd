# 内容包加载器（docs/tech/02-内容包格式规范.md §1 目录结构、§2 manifest）
# - 加载 manifest + 各表（nodes/events/encounters/items/flags/endings/lore，及 §1 预留的可选表）；
# - 结构校验：manifest 必填字段、namespace == pack_id（§2 防呆冗余）、节点 act 须在 acts 登记、
#   节点 id 包内唯一（§3）；可选字段缺省容错（§11 Schema 演进：新增字段一律可选）；
# - 资源四表（tech/04 §1~§5）：characters/skills/effects/enemies 按 §Schema 做必填字段结构校验，
#   合法值集合（kind/op/duration/stack 等）由 packlint V11~V13 按绑定规则包校验；
# - 未知文件警告但不拒绝（§1 向前兼容预留）；缺必填文件 = 加载失败；
# - 命名空间注册：加载成功后包内旗标解析到 manifest.namespace（Board 写权限由 07 §3 执行）。
class_name PackLoader
extends RefCounted

## §1 文件名固定、大小写敏感；value = 是否必填（campaign 包必填 endings，§9 注明"仅战役包"）。
const KNOWN_FILES := {
	"manifest.json": true,
	"nodes.json": true,
	"events.json": false,
	"encounters.json": false,
	"items.json": false,
	"flags.json": false,
	"characters.json": false,
	"skills.json": false,
	"effects.json": false,
	"enemies.json": false,
	"endings.json": false,
	"lore.json": false,
}
const NODE_TYPES := ["scene", "hub", "check", "battle", "dialog", "explore", "rest", "branch", "ending"]
const EDGE_TYPES := ["choice", "check", "item", "doom_clock", "reputation"]
## tech/04 Schema 必填字段（结构校验：存在性；合法值归 packlint V11~V13）。
const REQUIRED_FIELDS := {
	"characters.json": ["id", "name", "kind", "attrs", "hp_formula", "ac_formula"], # §2
	"skills.json": ["id", "name", "kind", "target"],                                # §3
	"effects.json": ["id", "name", "target_attr", "op", "value", "duration", "stack"], # §5.1
	"enemies.json": ["id", "name", "hp", "ac", "attack_mod", "damage"],             # §1
}

## 加载一个包目录。返回 { ok, errors[], warnings[], pack }；
## pack = { pack_id, manifest, acts, nodes{id:node}, node_order[], events[], encounters{id}, items{id},
## flags[], endings[], lore[], characters{id}, skills{id}, effects{id}, enemies{id} }（tech/04 §1）。
static func load_pack(dir_path: String) -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var pack := {"pack_id": "", "manifest": {}, "acts": [], "nodes": {}, "node_order": [],
		"events": [], "encounters": {}, "items": {}, "flags": [], "endings": [], "lore": [],
		"characters": {}, "skills": {}, "effects": {}, "enemies": {}}

	# 未知文件警告（§1：报警但不拒绝）
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return {"ok": false, "errors": ["包目录不存在：%s" % dir_path], "warnings": [], "pack": {}}
	for f: String in dir.get_files():
		if f.ends_with(".json") and not KNOWN_FILES.has(f):
			warnings.append("未知文件 %s（tech/02 §1：报警不拒绝，向前兼容预留）" % f)

	# 逐表加载
	var tables := {}
	for fname: String in KNOWN_FILES.keys():
		var path := dir_path.path_join(fname)
		if not FileAccess.file_exists(path):
			if KNOWN_FILES[fname]:
				errors.append("缺必填文件 %s（tech/02 §1）" % fname)
			continue
		var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if raw == null:
			errors.append("%s JSON 解析失败" % fname)
			continue
		tables[fname] = raw
	if not errors.is_empty():
		return {"ok": false, "errors": errors, "warnings": warnings, "pack": {}}

	# manifest（§2）
	var manifest: Dictionary = tables["manifest.json"]
	for field: String in ["pack_id", "name", "pack_type", "pack_version", "min_framework_version",
			"rule_pack", "presentation", "namespace"]:
		if not manifest.has(field):
			errors.append("manifest 缺必填字段 %s（tech/02 §2）" % field)
	if str(manifest.get("pack_id", "")) != str(manifest.get("namespace", "")):
		errors.append("manifest.namespace 必须等于 pack_id（tech/02 §2 防呆冗余）")
	if manifest.get("pack_type") == "campaign":
		for field: String in ["recommended_level", "node_budget"]:
			if not manifest.has(field):
				errors.append("战役包 manifest 缺必填字段 %s（tech/02 §2）" % field)
		if not tables.has("endings.json"):
			errors.append("战役包缺 endings.json（tech/02 §9）")
	pack["pack_id"] = str(manifest.get("pack_id", ""))
	pack["manifest"] = manifest

	# nodes（§3）
	var nodes_doc: Dictionary = tables.get("nodes.json", {})
	pack["acts"] = nodes_doc.get("acts", [])
	var act_ids: Array = []
	for act: Variant in pack["acts"]:
		act_ids.append(str((act as Dictionary).get("id", "")))
	var nodes := {}
	var order: Array[String] = []
	for node: Variant in nodes_doc.get("nodes", []):
		var n: Dictionary = node
		var nid := str(n.get("id", ""))
		if nid.is_empty():
			errors.append("存在缺 id 的节点（tech/02 §3）")
			continue
		if nodes.has(nid):
			errors.append("节点 id 重复：%s（tech/02 §3 包内唯一）" % nid)
			continue
		if not act_ids.has(str(n.get("act", ""))):
			errors.append("节点 %s 的 act '%s' 未在 acts 登记（tech/02 §3）" % [nid, str(n.get("act", ""))])
		if not NODE_TYPES.has(str(n.get("type", ""))):
			errors.append("节点 %s 的 type '%s' 非法（tech/02 §3 枚举）" % [nid, str(n.get("type", ""))])
		# 字段缺省容错（§11）：可选字段给默认值
		n["title"] = str(n.get("title", nid))
		n["summary"] = str(n.get("summary", ""))
		n["on_enter"] = n.get("on_enter", [])
		n["on_complete"] = n.get("on_complete", [])
		n["edges"] = n.get("edges", [])
		for edge: Variant in n["edges"]:
			var etype := str((edge as Dictionary).get("type", ""))
			if not EDGE_TYPES.has(etype):
				errors.append("节点 %s 存在非法边类型 '%s'（tech/02 §4 五类边）" % [nid, etype])
		nodes[nid] = n
		order.append(nid)
	pack["nodes"] = nodes
	pack["node_order"] = order

	# 其余表（缺省容错：不存在即为空）
	pack["events"] = tables.get("events.json", [])
	var encounters := {}
	for e: Variant in tables.get("encounters.json", []):
		var eid := str((e as Dictionary).get("id", ""))
		if eid.is_empty():
			errors.append("encounters.json 存在缺 id 条目（tech/02 §6）")
			continue
		encounters[eid] = e
	pack["encounters"] = encounters
	var items := {}
	for it: Variant in tables.get("items.json", []):
		var iid := str((it as Dictionary).get("id", ""))
		if iid.is_empty():
			errors.append("items.json 存在缺 id 条目（tech/02 §7）")
			continue
		items[iid] = it
	pack["items"] = items
	pack["flags"] = tables.get("flags.json", [])
	pack["endings"] = tables.get("endings.json", [])
	pack["lore"] = tables.get("lore.json", [])

	# 资源四表（tech/04 §1~§5：id 索引 + 必填字段结构校验）
	for fname: String in REQUIRED_FIELDS.keys():
		var table := {}
		for entry: Variant in tables.get(fname, []):
			var d: Dictionary = entry
			var eid := str(d.get("id", ""))
			if eid.is_empty():
				errors.append("%s 存在缺 id 条目（tech/04）" % fname)
				continue
			if table.has(eid):
				errors.append("%s 条目 id 重复：%s" % [fname, eid])
				continue
			for field: String in REQUIRED_FIELDS[fname]:
				if not d.has(field):
					errors.append("%s 条目 %s 缺必填字段 %s（tech/04 Schema）" % [fname, eid, field])
			table[eid] = d
		pack[fname.trim_suffix(".json")] = table

	return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings, "pack": pack}

# ---------------------------------------------------------------- graft 支线挂接（tech/02 §2.6，M4）

## 资源表合并：arc 自有条目并入合并视图；与宿主/已注入包 id 冲突 = 挂接错误（V14 命名空间独立）。
static func _merge_table(view: Dictionary, arc_pack: Dictionary, table: String, errors: Array) -> void:
	var arc_id := str(arc_pack.get("pack_id", ""))
	for eid: String in (arc_pack.get(table, {}) as Dictionary).keys():
		if (view[table] as Dictionary).has(eid):
			errors.append("graft：%s 条目 '%s' 与宿主/已注入包 id 冲突（tech/02 §2.6 命名空间独立）"
				% [table, eid])
			continue
		var entry: Dictionary = (arc_pack[table] as Dictionary)[eid]
		entry["_ns"] = arc_id # 来源命名空间元数据（合并视图内部键，内容侧不书写，§2.6）
		(view[table] as Dictionary)[eid] = entry

## 把支线包按 manifest.graft 注入宿主包视图。返回 { ok, errors[], view }：
## view = 宿主深拷贝 + 支线节点/事件/遭遇/资源表并入（节点/事件/注入边携带 _ns 来源键）
## + graft.edge 追加到宿主目标节点出边表。**宿主包数据不被改动**（深拷贝合并，§2.6）。
## endings 不并入（§9：结局仅战役包——支线收束回主线，不影响宿主结局条件）。
static func merge_graft(host_pack: Dictionary, arc_pack: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var host_id := str(host_pack.get("pack_id", ""))
	var arc_id := str(arc_pack.get("pack_id", ""))
	var graft: Dictionary = (arc_pack.get("manifest", {}) as Dictionary).get("graft", {})
	var into := str(graft.get("into", ""))
	var gnode := str(graft.get("node", ""))
	var gedge: Dictionary = graft.get("edge", {})
	if into.is_empty() or gnode.is_empty() or gedge.is_empty():
		errors.append("graft 缺 into/node/edge 必填字段（tech/02 §2.6）")
	if arc_id == into:
		errors.append("graft.into 不可等于本包 id（%s）" % arc_id)
	elif into != host_id:
		errors.append("graft.into '%s' 与宿主包 '%s' 不符（tech/02 §2.6）" % [into, host_id])
	var host_nodes: Dictionary = host_pack.get("nodes", {})
	if not gnode.is_empty() and not host_pack.is_empty() and not host_nodes.has(gnode):
		errors.append("graft.node '%s' 在宿主包 %s 不存在（V14）" % [gnode, host_id])
	if not gedge.is_empty():
		if not EDGE_TYPES.has(str(gedge.get("type", ""))):
			errors.append("graft.edge.type '%s' 非法（tech/02 §4 五类边）" % str(gedge.get("type", "")))
		var to := str(gedge.get("to", ""))
		if to.is_empty() or not (arc_pack.get("nodes", {}) as Dictionary).has(to):
			errors.append("graft.edge.to '%s' 须指向本包节点（tech/02 §2.6）" % to)
		if str(gedge.get("type", "")) == "item":
			var item := str(gedge.get("item", ""))
			if not (host_pack.get("items", {}) as Dictionary).has(item) \
					and not (arc_pack.get("items", {}) as Dictionary).has(item):
				errors.append("graft.edge 道具 '%s' 未在合并视图登记（V14/V11）" % item)
	if not errors.is_empty():
		return {"ok": false, "errors": errors, "view": {}}

	var view: Dictionary = host_pack.duplicate(true)
	# 节点并入（id 冲突 = 命名空间不独立，拒绝）
	var arc_nodes: Dictionary = arc_pack.get("nodes", {})
	for nid: String in arc_pack.get("node_order", []):
		if (view["nodes"] as Dictionary).has(nid):
			errors.append("graft：节点 '%s' 与宿主/已注入包 id 冲突（tech/02 §2.6 命名空间独立）" % nid)
			continue
		var n: Dictionary = (arc_nodes[nid] as Dictionary).duplicate(true)
		n["_ns"] = arc_id
		(view["nodes"] as Dictionary)[nid] = n
		(view["node_order"] as Array).append(nid)
	for table: String in ["encounters", "items", "characters", "skills", "effects", "enemies"]:
		_merge_table(view, arc_pack, table, errors)
	# 事件/旗标/图鉴并入（事件带 _ns 来源键）
	for ev: Variant in arc_pack.get("events", []):
		var evd: Dictionary = (ev as Dictionary).duplicate(true)
		evd["_ns"] = arc_id
		(view["events"] as Array).append(evd)
	for f: Variant in arc_pack.get("flags", []):
		(view["flags"] as Array).append(f)
	for l: Variant in arc_pack.get("lore", []):
		(view["lore"] as Array).append(l)
	# 注入边追加到宿主目标节点出边表（_ns/_graft 标记来源；卸载即随视图重建消失）
	var edge: Dictionary = gedge.duplicate(true)
	edge["_ns"] = arc_id
	edge["_graft"] = arc_id
	(((view["nodes"] as Dictionary)[gnode] as Dictionary)["edges"] as Array).append(edge)
	return {"ok": errors.is_empty(), "errors": errors, "view": view}
