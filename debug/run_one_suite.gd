extends SceneTree
## 跑一帧后再执行（root 与整树完全就绪；_init/_initialize 期 add_child
## 的节点不在树内——global_position 软报错吞检查，两坑都踩过）
func _initialize():
	await process_frame
	var suite = load(OS.get_cmdline_user_args()[0]).new()
	suite.tree_root = root
	suite.run()
	if suite.failures.size() > 0:
		print("DETAIL:
", suite.summary())
	print("one-suite:", "FAIL" if suite.failures.size() > 0 else "PASS",
			" checks=", suite.check_count)
	quit(0 if suite.failures.is_empty() else 1)
