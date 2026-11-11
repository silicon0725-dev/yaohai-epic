## 只跑指定套件并打印失败条目（调试用）：
##   godot --headless --path . -s debug/run_subset.gd
extends SceneTree

const SUITES := [
	"res://tests/test_meshing.gd",
	"res://tests/test_water_flow.gd",
]


func _initialize() -> void:
	await process_frame
	for path in SUITES:
		var suite: VoxelTestCase = load(path).new()
		suite.tree_root = root
		await suite.run()
		print("[", "PASS" if suite.failures.is_empty() else "FAIL", "] ",
				path, " — ", suite.summary())
		for f in suite.failures:
			print("    * ", f)
	quit(0)
