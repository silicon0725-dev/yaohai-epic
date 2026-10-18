## headless 单元测试入口（开发文档 §11.1）：
##   godot-4 --headless --path <项目目录> -s tests/run_all_tests.gd
## 首次运行前先执行一次 --import 生成 .godot 全局类缓存。
## 退出码：0 全部通过，1 存在失败套件（可接入 CI）。
extends SceneTree

const TEST_CASES := [
	"res://tests/test_coordinates.gd",
	"res://tests/test_chunk_data.gd",
	"res://tests/test_registry.gd",
	"res://tests/test_generation.gd",
	"res://tests/test_meshing.gd",
	"res://tests/test_raycast.gd",
	"res://tests/test_chunk_manager.gd",
	"res://tests/test_save_load.gd",
	"res://tests/test_greedy_meshing.gd",
	"res://tests/test_block_state.gd",
	"res://tests/test_items.gd",
	"res://tests/test_crafting.gd",
	"res://tests/test_native_equivalence.gd",
]


func _init() -> void:
	var failed_suites := 0
	var total_checks := 0
	var total_failures := 0
	print("=== 体素内核 Stage A 单元测试 ===")
	for path in TEST_CASES:
		var suite: VoxelTestCase = load(path).new()
		suite.run()
		total_checks += suite.check_count
		total_failures += suite.failures.size()
		var status := "PASS" if suite.failures.is_empty() else "FAIL"
		print("[%s] %s — %s" % [status, path, suite.summary()])
		if not suite.failures.is_empty():
			failed_suites += 1
	print("=== 总计：%d 套件，%d 项检查，%d 项失败 ===" % [
		TEST_CASES.size(), total_checks, total_failures])
	quit(1 if failed_suites > 0 else 0)
