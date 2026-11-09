# 首批美术资产 + 升级绘卷截图工具（14 清单 #7 交付产物；不提交截图，输出 /tmp/art_*.png）
# 用法（需显示服务，非 headless）：
#   /Applications/Godot.app/Contents/MacOS/Godot --path game -s tools/shoot_art.gd
extends SceneTree

func _snap(path: String) -> void:
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	img.save_png(path)
	print("[shoot] saved ", path)

func _run() -> void:
	var sd: GDScript = load("res://tools/shell_diff.gd")
	# ① 竖屏战斗：单位卡 icon（墨魈/幼体单位图）+ 队伍芯片头像
	var pstream := EventStream.new()
	var psm := EncounterSM.new(Board.new(pstream), pstream, Rng.new(11), "campaign01")
	var portrait: EncounterPortrait = \
		(load("res://shell/portrait/encounter_portrait.tscn") as PackedScene).instantiate()
	root.add_child(portrait)
	await process_frame
	portrait.bind(psm, AutoAgent.new())
	psm.enter("N1-7")
	psm.transition(EncounterSM.S_EXPLORE)
	psm.begin_combat(sd.battle_def())
	await create_timer(0.3).timeout
	await _snap("/tmp/art_units_portrait.png")
	portrait.queue_free()
	await process_frame
	# ② 横屏战斗：格内 token 铺单位图（窗口扩到横屏尺寸取景）
	root.size = Vector2i(1280, 720)
	var lstream := EventStream.new()
	var lsm := EncounterSM.new(Board.new(lstream), lstream, Rng.new(11), "campaign01")
	var land: EncounterLandscape = \
		(load("res://shell/landscape/encounter_landscape.tscn") as PackedScene).instantiate()
	root.add_child(land)
	land.set_anchors_preset(Control.PRESET_TOP_LEFT)
	land.position = Vector2.ZERO
	land.size = Vector2(1280, 720)
	await process_frame
	await process_frame
	land.bind(lsm, AutoAgent.new())
	lsm.enter("N1-7")
	lsm.transition(EncounterSM.S_EXPLORE)
	lsm.begin_combat(sd.battle_def())
	await create_timer(0.3).timeout
	await _snap("/tmp/art_units_landscape.png")
	land.queue_free()
	await process_frame
	# ③ 主屏绘卷：分层细节（棚顶灯光点 / 塔顶灯窗与光束 / 水面波光点）
	root.size = Vector2i(390, 760)
	var hs := HomeScroll.new()
	hs.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(hs)
	hs.set_state(2, 3) # 低褪墨 + 告示板角标，灯光/波光可见
	await create_timer(0.6).timeout # 呼吸微光走一段
	await _snap("/tmp/art_home_scroll.png")
	hs.queue_free()
	await process_frame
	print("[shoot] done: units_portrait / units_landscape / home_scroll")
	quit()

func _init() -> void:
	call_deferred("_run")
