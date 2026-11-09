# ☰ 菜单音量三档滑条（docs/framework/14 清单 #5：Master/BGM/SFX；12 §5：UI 偏好不写状态板）。
# 双壳同一构建器（godot-dev §7：禁止复制两份逻辑）；滑条改动 = 写 user://settings.cfg +
# 组调用 AudioManager.apply_volumes 即时生效（无音频环境时组调用空转，静默跳过）。
class_name AudioSettingsUi
extends RefCounted

## 追加三档滑条到容器；返回 {音量键: HSlider} 供测试寻址。初值读设置文件（缺省满格 1.0）。
static func append_to(container: VBoxContainer, settings_path: String = UiSettings.PATH) -> Dictionary:
	var out := {}
	var defs := [
		[UiSettings.KEY_VOL_MASTER, TextsZh.MENU_VOL_MASTER],
		[UiSettings.KEY_VOL_BGM, TextsZh.MENU_VOL_BGM],
		[UiSettings.KEY_VOL_SFX, TextsZh.MENU_VOL_SFX],
	]
	for d: Array in defs:
		var key := String(d[0])
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = String(d[1])
		label.custom_minimum_size.x = 110
		row.add_child(label)
		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 100.0
		slider.step = 1.0
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value = UiSettings.load_volume(key, settings_path) * 100.0
		slider.value_changed.connect(func(v: float) -> void:
			UiSettings.save_volume(key, v / 100.0, settings_path)
			var tree := Engine.get_main_loop() as SceneTree
			if tree != null:
				tree.call_group("audio_manager", "apply_volumes"))
		row.add_child(slider)
		container.add_child(row)
		out[key] = slider
	return out
