# packlint CLI：godot --headless --path game -s tools/packlint.gd [-- packs/campaign01]
# 校验核见 tools/packlint_core.gd（tech/02 §12 V1~V10 + tech/04 §6 V11~V13）。
# 退出码：存在 FAIL = 1；全 PASS/WARN/N-A = 0。
extends SceneTree

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var dir := "res://packs/campaign01"
	if not args.is_empty():
		dir = args[0]
	print("== packlint：%s ==" % dir)
	var res := PackLoader.load_pack(dir)
	for w: String in res["warnings"]:
		print("  [WARN] 加载：", w)
	if not res["ok"]:
		for e: String in res["errors"]:
			print("  [FAIL] 加载：", e)
		print("== packlint 加载失败 ==")
		quit(1)
		return
	var issues: Array = PacklintCore.lint(res["pack"])
	var fails := 0
	var warns := 0
	for issue: Dictionary in issues:
		print("  [%-4s] %s：%s" % [issue["level"], issue["v"], issue["msg"]])
		if issue["level"] == PacklintCore.LEVEL_FAIL:
			fails += 1
		elif issue["level"] == PacklintCore.LEVEL_WARN:
			warns += 1
	print("== packlint 完成：%d FAIL / %d WARN ==" % [fails, warns])
	quit(1 if fails > 0 else 0)
