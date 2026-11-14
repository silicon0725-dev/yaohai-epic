## 单套件测试入口（调试迭代用）：
##   <exe> --headless --path . -s tests/run_one.gd -- res://tests/test_xxx.gd
## 路径经 -- 传用户参数（与 --greedy 同机制），缺省打印用法并退出 1。
extends SceneTree


func _initialize() -> void:
	# 与 run_all_tests 同模式：跑一帧后再执行（_init 期 root 未就绪），
	# await 兼容异步套件（同步 run() 返回立即值，await 直接继续）
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("用法: -s tests/run_one.gd -- res://tests/test_xxx.gd")
		quit(1)
		return
	var suite: VoxelTestCase = load(args[0]).new()
	if suite == null:
		push_error("套件加载失败（路径不存在或 parse error）: %s" % args[0])
		quit(3)
		return
	suite.tree_root = root
	await suite.run()
	var status := "FAIL" if not suite.failures.is_empty() \
			else ("SKIP" if suite.skipped else "PASS")
	print("[%s] %s — %s" % [status, args[0], suite.summary()])
	quit(1 if not suite.failures.is_empty()
			else (2 if suite.skipped else 0))
