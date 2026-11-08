# 无头测试入口：/Applications/Godot.app/Contents/MacOS/Godot --headless --path game -s tests/run.gd
# 约定：每个 core 模块一个 test_xxx()，失败 push_error 并以非零码退出（godot-acceptance §1.2）
extends SceneTree

var failures := 0

func check(cond: bool, name: String) -> void:
	if cond:
		print("  PASS ", name)
	else:
		failures += 1
		push_error("  FAIL " + name)

func _init() -> void:
	print("== 抄本纪元 core 无头测试 ==")
	# 冒烟：脚本环境可用即通过（模块测试随 TP0 逐步加入）
	check(true, "headless runner alive")
	if failures == 0:
		print("== 全部通过 ==")
	else:
		print("== 失败：", failures, " ==")
	quit(1 if failures > 0 else 0)
