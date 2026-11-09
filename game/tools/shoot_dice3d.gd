# 骰子 3D 演出截图工具（14 清单 #2 交付产物；不提交截图，输出 /tmp/dice3d_*.png）
# 用法（需显示服务，非 headless）：
#   /Applications/Godot.app/Contents/MacOS/Godot --path game -s tools/shoot_dice3d.gd
extends SceneTree

var _d: Dice3D

func _init() -> void:
	call_deferred("_run")

func _snap(path: String) -> void:
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	img.save_png(path)
	print("[shoot] saved ", path)

func _run() -> void:
	_d = (load("res://shell/ui/dice_3d.tscn") as PackedScene).instantiate() as Dice3D
	root.add_child(_d)
	await process_frame
	_d.play(20, 20261109) # nat20 仪式感定格
	await create_timer(0.5).timeout
	await _snap("/tmp/dice3d_bounce.png")   # ① 物理弹跳段
	await create_timer(1.9).timeout
	await _snap("/tmp/dice3d_slowmo.png")   # ② 慢镜头定格对齐段
	await _d.finished
	await _snap("/tmp/dice3d_settle.png")   # ③ 定格顶面 20 + 时间恢复
	print("[shoot] top_face=", _d.top_face(), " time_scale=", Engine.time_scale)
	quit()
