# 美术资产加载器（docs/tech/05-美术管线.md §1/§5/§6：双壳同一加载通道，禁止复制横屏/竖屏两份逻辑）。
# - art_ref 值格式 "<类别目录>/<id>" → res://assets/art/<目录>/<类名>_<id>_<档>.png（tech/05 §6）；
# - Image.load_from_file 直读（与 AudioStreamWAV.load_from_file 同通道：免导入管线、无头可测）；
# - 缺文件/非法键一律静默返回 null（tech/05 §5 占位兜底：壳层保持色块/文本现状，不拒绝加载）；
# - 纯壳层呈现工具：不订阅事件流、不读写状态板。
class_name ArtLoader
extends RefCounted

## 类别目录 → 文件名类名前缀（tech/05 §2 命名规范）。
const CLASS_PREFIX := {"units": "unit", "portraits": "portrait", "scenes": "scene", "icons": "icon"}
const ART_ROOT := "res://assets/art"

static var _cache: Dictionary = {} # "ref@tier" -> Texture2D（命中才缓存；miss 也缓存 null 标记防重复 IO）

## art_ref 合法性校验 + 路径拼接；非法键返回 ""。
static func path_for(art_ref: String, tier: int = 128) -> String:
	if art_ref.is_empty() or art_ref.contains("..") or art_ref.begins_with("/"):
		return ""
	var parts := art_ref.split("/")
	if parts.size() != 2 or not CLASS_PREFIX.has(parts[0]):
		return ""
	var id := parts[1]
	if id.is_empty():
		return ""
	for i: int in id.length():
		var ch := id[i]
		var ok := (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_"
		if not ok:
			return ""
	return "%s/%s/%s_%s_%d.png" % [ART_ROOT, parts[0], CLASS_PREFIX[parts[0]], id, tier]

## 引用解析 → 纹理；缺失/非法 = null（tech/05 §5 静默兜底）。
static func texture_for(art_ref: String, tier: int = 128) -> Texture2D:
	var path := path_for(art_ref, tier)
	if path.is_empty():
		return null
	var key := "%s@%d" % [art_ref, tier]
	if _cache.has(key):
		return _cache[key] # null 标记同缓存（重复 miss 不重复 IO）
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = (load(path) as Texture2D) # 已导入：标准资源通道（导出包同路径可用）
	elif FileAccess.file_exists(path):
		var img := Image.load_from_file(path) # 未导入兜底：直读 PNG（与 AudioStreamWAV.load_from_file 同通道）
		if img != null and not img.is_empty():
			tex = ImageTexture.create_from_image(img) # filter on 平滑（tech/05 §4 一期导入约定）
	_cache[key] = tex
	return tex

## 是否存在可用图（探针：无头断言用）。
static func has_art(art_ref: String, tier: int = 128) -> bool:
	return texture_for(art_ref, tier) != null

## 测试/调试用：清缓存。
static func clear_cache() -> void:
	_cache.clear()
