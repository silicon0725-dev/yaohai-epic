## 单套件测试入口（调试迭代用）：
##   <exe> --headless --path . -s tests/run_one.gd -- res://tests/test_xxx.gd
## 路径经 -- 传用户参数（与 --greedy 同机制），缺省打印用法并退出 1。
extends SceneTree


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("用法: -s tests/run_one.gd -- res://tests/test_xxx.gd")
		quit(1)
		return
	var suite: VoxelTestCase = load(args[0]).new()
	suite.run()
	var status := "PASS" if suite.failures.is_empty() else "FAIL"
	print("[%s] %s — %s" % [status, args[0], suite.summary()])
	quit(0 if suite.failures.is_empty() else 1)
