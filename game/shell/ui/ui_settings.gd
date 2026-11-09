# UI 偏好本地持久化（12 §5：玩家偏好持久化——UI 偏好不是世界状态，不写状态板，存本地设置 user://settings.cfg）
# - shell 侧工具（引擎依赖允许）：ConfigFile 存取；core 零感知；
# - 读失败/键缺失一律回落文档默认值；写盘合并既有键，不覆盖其它设置。
class_name UiSettings
extends RefCounted

const PATH := "user://settings.cfg"
const SECTION := "ui"
const KEY_HOME_BAR_COLLAPSED := "home_bar_collapsed"
const KEY_SCREEN_SHAKE := "screen_shake"

## 主屏兜底条是否收起；默认展开（12 §5：默认展开）。
static func load_home_bar_collapsed(path: String = PATH) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return false
	return bool(cfg.get_value(SECTION, KEY_HOME_BAR_COLLAPSED, false))

static func save_home_bar_collapsed(collapsed: bool, path: String = PATH) -> void:
	_save_key(KEY_HOME_BAR_COLLAPSED, collapsed, path)

## 屏幕震动是否开启（14 清单 #4：可关的设置项）；默认开启。
static func load_screen_shake(path: String = PATH) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return true
	return bool(cfg.get_value(SECTION, KEY_SCREEN_SHAKE, true))

static func save_screen_shake(enabled: bool, path: String = PATH) -> void:
	_save_key(KEY_SCREEN_SHAKE, enabled, path)

## 写盘合并既有键，不覆盖其它设置。
static func _save_key(key: String, value: Variant, path: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(path)
	cfg.set_value(SECTION, key, value)
	var err := cfg.save(path)
	if err != OK:
		push_warning("[ui_settings] 偏好写盘失败 %s err=%d" % [path, err])
