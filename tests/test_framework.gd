## 轻量测试基类（开发文档 §11.1）。
## 不依赖 GUT 等第三方框架；headless 运行方式见 tests/run_all_tests.gd。
class_name VoxelTestCase
extends RefCounted

var check_count := 0
var failures: Array[String] = []
## runner 注入的 SceneTree.root（headless 下 Engine.get_main_loop()
## 在 _init 阶段为 null，节点入树测试经此通道；未注入时为 null）
var tree_root: Node = null


## 子类覆盖此方法执行测试。
func run() -> void:
	push_error("VoxelTestCase.run() 未被子类覆盖")
	failures.append("run() 未实现")


func check(condition: bool, label: String) -> void:
	check_count += 1
	if not condition:
		failures.append(label)


func check_eq(actual: Variant, expected: Variant, label: String) -> void:
	check_count += 1
	if actual != expected:
		failures.append("%s — 期望 %s，实际 %s" % [label, str(expected), str(actual)])


## 世界夹具工厂（各套件的 _make_world 三件套合一）。
## coords 内每块全 AIR；filler(chunk) 填方块。seed 固定可复现。
func make_world(
		size: int, coords: Array, seed_value: int = 7,
		filler: Callable = Callable()
) -> VoxelWorld:
	var blocks := VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.world_seed = seed_value
	config.chunk_size = size
	var world := VoxelWorld.new(config, blocks)
	for coord in coords:
		var chunk := ChunkData.new(coord, Vector3i(size, size, size), 1)
		if filler.is_valid():
			filler.call(chunk)
		world.add_chunk(chunk)
	return world


## 光照管线激活（体素光照类套件共用：init + 邻块快照 + 播出）。
func activate_light(world: VoxelWorld, coord: Vector3i) -> void:
	const VoxelLightScript := preload("res://systems/lighting/voxel_light.gd")
	var light: Node = VoxelLightScript.new()
	light.setup(world)
	var nbs := []
	for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
			Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		nbs.append(world.get_chunk(coord + d))
	light.init_chunk_light(world.get_chunk(coord), nbs)
	light.on_chunk_ready(world.get_chunk(coord))


func summary() -> String:
	if failures.is_empty():
		return "PASS（%d 项检查）" % check_count
	return "FAIL（%d/%d 项失败）:\n  - %s" % [
		failures.size(), check_count, "\n  - ".join(PackedStringArray(failures))]
