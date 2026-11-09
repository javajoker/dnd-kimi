# UI 主题（docs/framework/04-UI-UX设计文档.md §7 开放项「视觉风格与字体阅读层级」第一档落地）：
# - 内置 Noto Sans SC（思源黑体，OFL 许可，见 assets/fonts/OFL.txt）为默认主题字体——
#   不再依赖运行机系统中文字体，消除 CJK 豆腐块；
# - 统一字号档：正文/标题/大字三档常量，渲染层消费档位而非散落硬编码新值；
# - 渲染层对字体来源无感：只读 ThemeDB 默认主题（呈现与逻辑解耦，白皮书 §7.3）。
class_name UITheme
extends RefCounted

## 内置字体（SC 子集 OTF：Regular + Bold 两常用字重，控制包体）。
const FONT_REGULAR := "res://assets/fonts/NotoSansSC-Regular.otf"
const FONT_BOLD := "res://assets/fonts/NotoSansSC-Bold.otf"

## 字号档（04 §7：正文/标题/大字）。正文档 = Godot 默认 16，保持既有界面观感不变。
const SIZE_BODY := 16 # 正文
const SIZE_TITLE := 24 # 标题
const SIZE_BIG := 32 # 大字（掷骰结果、结算数字等强调位）

static var regular: FontFile # 正文字重（默认主题用）
static var bold: FontFile # 粗体字重（标题强调位取用）
static var theme_res: Theme # apply() 构建的主题实例（attach 挂接用）

## 主题挂接点（铁律：主题必须挂在 Control 链上）。Window.theme 不会穿过
## 普通 Node 祖先下发（main.tscn 根为 Node），故各界面/壳实例在加入树时经此挂接。
static func attach(c: Control) -> void:
	if theme_res != null:
		c.theme = theme_res

## 装载内置字体并设为默认主题（挂到根 Window.theme，树内全部 Control 继承；
## ThemeDB.fallback_font 同源兜底，避免运行机系统字体差异导致呈现不一致）。
## ThemeDB.default_theme 运行期只读，故默认主题经根窗口挂接生效。
## root 可空（纯 core 无头场景只注册兜底字体）。返回 true = 内置字体生效；
## 内置文件缺失时回退系统中文字体（仅开发机可读性兜底，不入发布形态）并返回 false。
static func apply(root: Window = null) -> bool:
	var ff := _load(FONT_REGULAR)
	if ff != null:
		regular = ff
		var bb := _load(FONT_BOLD)
		bold = bb if bb != null else ff
		var theme := Theme.new()
		theme.default_font = regular
		theme.default_font_size = SIZE_BODY
		theme_res = theme
		if root != null:
			root.theme = theme
		ThemeDB.fallback_font = regular
		ThemeDB.fallback_font_size = SIZE_BODY
		return true
	# 开发兜底：系统中文字体（macOS 优先；不打包，仅保证开发期可读）
	for path: String in ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc",
			"/System/Library/Fonts/STHeiti Light.ttc", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"]:
		var sys := _load(path)
		if sys != null:
			regular = sys
			bold = sys
			ThemeDB.fallback_font = sys
			return false
	return false

static func _load(path: String) -> FontFile:
	if not FileAccess.file_exists(path):
		return null
	var ff := FontFile.new()
	if ff.load_dynamic_font(path) != OK:
		return null
	return ff
