# 音频框架（docs/framework/14-表现层与平台化清单.md #5）
# 铁律落位：
# - 纯呈现消费：唯一逻辑输入是事件流事件（on_event），不改 core、不写 Board、不回注事件流
#   （godot-dev §2，与 JuiceLayer 同模式）；壳侧直调（play_sfx/play_ui/to_home）同样只播不发；
# - 总线四路：Master（引擎内置）+ BGM/SFX/Ambient（AudioServer 自定义，均挂 Master）；
# - BGM 四态状态机：营地/探索/战斗/结局，事件流驱动——node.enter(hub→营地；battle 节点不切，
#   整备期间不打断；其余→探索) / combat.start→战斗 / state.entered(settle)→探索（09 §1）/
#   story.ending→结局（tech/02 §9）；切换交叉淡入淡出 CROSSFADE_SEC 秒（A/B 双播放器）；
#   首批仅两首 BGM（14 #6），探索/结局暂共用营地垫（留白：补资产后只改 BGM_ASSETS 表）；
# - SFX 订阅映射：check.roll→dice_roll + 延迟 DICE_LAND_DELAY 秒 dice_land；
#   battle.attack hit→hit / crit→crit（不叠 hit；miss 无声——无资产留白）；
#   item.use healed>0→heal；翻页（界面切换）与 UI 点击由壳侧直调；
# - 音量：Master/BGM/SFX 三档，user://settings.cfg（12 §5：UI 偏好不写状态板），
#   ☰ 滑条经 AudioSettingsUi 写盘后组调用 apply_volumes 即时生效；
# - 无音频文件静默容错：缺文件只计数 stats["missing_files"]，不报错不崩溃（框架先行）。
class_name AudioManager
extends Node

const BUS_BGM := &"BGM"
const BUS_SFX := &"SFX"
const BUS_AMBIENT := &"Ambient"

# BGM 四态（14 清单 #5：营地/探索/战斗/结局）
const BGM_NONE := &""
const BGM_CAMP := &"camp"
const BGM_EXPLORE := &"explore"
const BGM_BATTLE := &"battle"
const BGM_ENDING := &"ending"

## 状态 → BGM 资产名（首批两首：探索/结局共用营地垫；补资产只改本表）。
const BGM_ASSETS := {
	BGM_CAMP: &"bgm_camp",
	BGM_EXPLORE: &"bgm_camp",
	BGM_BATTLE: &"bgm_battle",
	BGM_ENDING: &"bgm_camp",
}
## 循环播放的资产（BGM/环境声，LOOP_FORWARD 全曲循环）。
const LOOP_ASSETS: Array[StringName] = [&"bgm_camp", &"bgm_battle", &"tide_loop"]

const CROSSFADE_SEC := 1.0    # BGM 交叉淡入淡出时长
const DICE_LAND_DELAY := 0.45 # 骰子滚动 → 落定延迟（与快掷 ≤0.5s 落定节奏一致，09 §6）
const SFX_POOL_SIZE := 8

var asset_dir := "res://assets/audio"
var settings_path := UiSettings.PATH

var bgm_state: StringName = BGM_NONE
var current_bgm_asset: StringName = &""
var stats := {"bgm_switches": 0, "sfx_total": 0, "missing_files": 0, "ambient_on_count": 0}
var sfx_counts := {} # StringName -> int

var _bgm_front: AudioStreamPlayer
var _bgm_back: AudioStreamPlayer
var _ambient: AudioStreamPlayer
var _ambient_on := false
var _sfx_pool: Array[AudioStreamPlayer] = []
var _sfx_idx := 0
var _cache := {} # StringName -> AudioStream 或 null（null = 已确认缺失，不重复探测）

func _ready() -> void:
	add_to_group("audio_manager") # ☰ 滑条即时生效 / 壳侧点击音的组调用落点
	_ensure_buses()
	_bgm_front = _make_player(BUS_BGM)
	_bgm_back = _make_player(BUS_BGM)
	_ambient = _make_player(BUS_AMBIENT)
	for i: int in SFX_POOL_SIZE:
		_sfx_pool.append(_make_player(BUS_SFX))
	apply_volumes()

## 总线就位（幂等：多实例/重复调用不重复建）。
func _ensure_buses() -> void:
	for b: StringName in [BUS_BGM, BUS_SFX, BUS_AMBIENT]:
		if AudioServer.get_bus_index(b) == -1:
			var idx := AudioServer.bus_count
			AudioServer.add_bus(idx)
			AudioServer.set_bus_name(idx, b)
			AudioServer.set_bus_send(idx, &"Master")

func _make_player(bus: StringName) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = bus
	add_child(p)
	return p

## 音量应用（启动一次 + ☰ 滑条 value_changed 组调用）。0 = 静音（-80dB 兜底防爆音）。
func apply_volumes() -> void:
	_apply_bus(&"Master", UiSettings.load_volume(UiSettings.KEY_VOL_MASTER, settings_path))
	_apply_bus(BUS_BGM, UiSettings.load_volume(UiSettings.KEY_VOL_BGM, settings_path))
	_apply_bus(BUS_SFX, UiSettings.load_volume(UiSettings.KEY_VOL_SFX, settings_path))

func _apply_bus(bus: StringName, v: float) -> void:
	var idx := AudioServer.get_bus_index(bus)
	if idx < 0:
		return
	AudioServer.set_bus_mute(idx, v <= 0.0)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(v, 0.0001)))

# ---------------------------------------------------------------- 事件流订阅（纯呈现消费，零回注）

func on_event(ev: Dictionary) -> void:
	var p: Dictionary = ev["payload"]
	match StringName(ev["type"]):
		EventTypes.NODE_ENTER:
			var ntype := str(p.get("type", ""))
			if ntype == "hub":
				_set_bgm(BGM_CAMP)
			elif ntype != "battle": # 战斗节点 BGM 由 combat.start 驱动（整备期间不打断）
				_set_bgm(BGM_EXPLORE)
		EventTypes.COMBAT_START:
			_set_bgm(BGM_BATTLE)
		EventTypes.STATE_ENTERED:
			if str(p.get("state", "")) == "settle": # 结算（09 §1）→ 战后回探索氛围
				_set_bgm(BGM_EXPLORE)
		EventTypes.STORY_ENDING:
			_set_bgm(BGM_ENDING)
		EventTypes.CHECK_ROLL:
			play_sfx(&"dice_roll")
			# 落定声延迟一拍（快掷 ≤0.5s 落定，09 §6）；对象析构时连接自动断开，无悬挂回调
			get_tree().create_timer(DICE_LAND_DELAY).timeout.connect(
				func() -> void: play_sfx(&"dice_land"))
		EventTypes.BATTLE_ATTACK:
			if bool(p.get("crit", false)):
				play_sfx(&"crit")
			elif bool(p.get("hit", false)):
				play_sfx(&"hit")
		EventTypes.ITEM_USE:
			if int(p.get("healed", 0)) > 0:
				play_sfx(&"heal")

# ---------------------------------------------------------------- BGM 状态机

func _set_bgm(state: StringName) -> void:
	if bgm_state == state:
		return
	bgm_state = state
	stats["bgm_switches"] += 1
	_crossfade_to(StringName(BGM_ASSETS.get(state, &"")))

## 主屏（壳侧直调）：BGM 收止，潮声环境声由 set_home_ambient 接管（14 #6：主屏常播）。
func to_home() -> void:
	if bgm_state == BGM_NONE:
		return
	bgm_state = BGM_NONE
	stats["bgm_switches"] += 1
	_crossfade_to(&"")

func _crossfade_to(asset: StringName) -> void:
	var stream: AudioStream = null if asset == &"" else _stream_for(asset)
	var new_asset := asset if stream != null else &""
	if new_asset == current_bgm_asset and (new_asset == &"" or _bgm_front.playing):
		return # 同曲续播（探索↔营地共用垫时不重启不打断）
	current_bgm_asset = new_asset
	var from := _bgm_front
	var to := _bgm_back
	_bgm_front = to
	_bgm_back = from
	to.stop()
	if stream != null:
		to.stream = stream
		to.volume_db = -40.0
		to.play()
	var tw := create_tween().set_parallel(true)
	if from.playing:
		tw.tween_property(from, "volume_db", -40.0, CROSSFADE_SEC)
	if stream != null:
		tw.tween_property(to, "volume_db", 0.0, CROSSFADE_SEC)
	tw.chain().tween_callback(func() -> void:
		if from != _bgm_front:
			from.stop())

# ---------------------------------------------------------------- SFX / 环境声

func play_sfx(sfx_name: StringName) -> void:
	var stream := _stream_for(sfx_name)
	if stream == null:
		return # 静默容错
	var p := _sfx_pool[_sfx_idx]
	_sfx_idx = (_sfx_idx + 1) % _sfx_pool.size()
	p.stream = stream
	p.play()
	stats["sfx_total"] += 1
	sfx_counts[sfx_name] = int(sfx_counts.get(sfx_name, 0)) + 1

## 壳侧 UI 音入口（组调用目标；纯播放不产事件）。
func play_ui(sfx_name: StringName) -> void:
	play_sfx(sfx_name)

## 测试探针：某 SFX 已播次数。
func sfx_count(sfx_name: StringName) -> int:
	return int(sfx_counts.get(sfx_name, 0))

## 主屏潮声环境声（14 #6：主屏常播；幂等）。
func set_home_ambient(on: bool) -> void:
	if on == _ambient_on:
		return
	_ambient_on = on
	if on:
		stats["ambient_on_count"] += 1
		var stream := _stream_for(&"tide_loop")
		if stream != null:
			_ambient.stream = stream
			_ambient.play()
	else:
		_ambient.stop()

func is_ambient_on() -> bool:
	return _ambient_on

## 资产装载（含循环标记）；缺文件静默容错：计数一次并缓存 null，不重复探测。
func _stream_for(sfx_name: StringName) -> AudioStream:
	if _cache.has(sfx_name):
		return _cache[sfx_name]
	var s: AudioStream = null
	var path := "%s/%s.wav" % [asset_dir, String(sfx_name)]
	if FileAccess.file_exists(path):
		s = AudioStreamWAV.load_from_file(path)
		if s is AudioStreamWAV and LOOP_ASSETS.has(sfx_name):
			var w := s as AudioStreamWAV
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = w.get_data().size() / 2 # 16-bit 单声道：字节数/2 = 采样帧数
	else:
		stats["missing_files"] += 1 # 静默容错：只计数，不报错
	_cache[sfx_name] = s
	return s
