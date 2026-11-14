## headless 单元测试入口（开发文档 §11.1）：
##   godot-4 --headless --path <项目目录> -s tests/run_all_tests.gd
## 首次运行前先执行一次 --import 生成 .godot 全局类缓存。
## 退出码：0 全部通过，1 存在失败套件（可接入 CI）。
extends SceneTree

const TEST_CASES := [
	"res://tests/test_coordinates.gd",
	"res://tests/test_chunk_data.gd",
	"res://tests/test_registry.gd",
	"res://tests/test_registry_dock.gd",
	"res://tests/test_atlas_preview.gd",
	"res://tests/test_generation.gd",
	"res://tests/test_meshing.gd",
	"res://tests/test_raycast.gd",
	"res://tests/test_chunk_manager.gd",
	"res://tests/test_save_load.gd",
	"res://tests/test_greedy_meshing.gd",
	"res://tests/test_block_state.gd",
	"res://tests/test_items.gd",
	"res://tests/test_crafting.gd",
	"res://tests/test_drops.gd",
	"res://tests/test_trees.gd",
	"res://tests/test_tree_mesh.gd",
	"res://tests/test_water_flow.gd",
	"res://tests/test_weather.gd",
	"res://tests/test_light_manager.gd",
	"res://tests/test_voxel_light.gd",
	"res://tests/test_light_inspector.gd",
	"res://tests/test_cave_fog.gd",
	"res://tests/test_stress_edits.gd",
	"res://tests/test_torch_entities.gd",
	"res://tests/test_mc_model.gd",
	"res://tests/test_lantern_entities.gd",
	"res://tests/test_lantern_light_probe.gd",
	"res://tests/test_leaf_probe.gd",
	"res://tests/test_distant_shell.gd",
	"res://tests/test_sound.gd",
	"res://tests/test_native_equivalence.gd",
	"res://tests/test_native_terrain.gd",
	"res://tests/test_character.gd",
	"res://tests/test_anim_editor.gd",
]


func _initialize() -> void:
	# 跑一帧后再执行：_init/_initialize 期 root 未完全就绪，注入的
	# tree_root 挂不进树（global_position 软报错吞检查——已踩坑）
	await process_frame
	# 单套件挂死保护由外层 timeout 命令承担（审查 7-F8）；曾尝试
	# runner 内协程看门狗——lambda 挂起状态在引擎退出清理期 UAF
	var failed_suites := 0
	var skipped_suites := 0
	var total_checks := 0
	var total_failures := 0
	print("=== 体素内核 Stage A 单元测试 ===")
	for path in TEST_CASES:
		var suite: VoxelTestCase = load(path).new()
		suite.tree_root = root
		# await 兼容异步套件（test_distant_shell 等 worker 流程）；
		# 同步 run() 返回立即值，await 直接继续。
		# 看门狗曾用协程 lambda + done 标志实现——lambda 捕获的挂起
		# 状态在引擎退出清理期 UAF 段错误（exit 139，稳定复现），弃用；
		# 挂死保护由外层 timeout 命令承担（CI 包装层）
		var t0 := Time.get_ticks_msec()
		await suite.run()
		var elapsed := Time.get_ticks_msec() - t0
		total_checks += suite.check_count
		total_failures += suite.failures.size()
		var status := "FAIL" if not suite.failures.is_empty() \
				else ("SKIP" if suite.skipped else "PASS")
		print("[%s] %s (%.1fs) — %s" % [status, path,
				elapsed / 1000.0, suite.summary()])
		if not suite.failures.is_empty():
			failed_suites += 1
		elif suite.skipped:
			skipped_suites += 1
	print("=== 总计：%d 套件，%d 项检查，%d 项失败，%d 套件跳过 ===" % [
		TEST_CASES.size(), total_checks, total_failures, skipped_suites])
	# 退出码：0 全过；1 有失败；2 仅跳过（对拍覆盖缺失必须显式上报，
	# 静默全绿曾让 C# 生产路径不可用 34 套件照常全绿退出——审查 7-F2）
	quit(1 if failed_suites > 0 else (2 if skipped_suites > 0 else 0))
