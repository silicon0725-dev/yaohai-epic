## 确定性树生成器（结构化树系统 v1）——纯数据，无场景依赖。
## 生成期（terrain_generator 占位重放）与运行期（tree_manager 实体
## 重建）共用本模块，保证两边结构一致（禁止各维护模板）。
##
## 形态模板（确定性，无随机游走）：
## - 主干垂直（高度按种子 ±20% 抖动），底部粗顶部细（逐格线性半径）；
## - 侧枝从主干上部 40% 起分 2-3 层，每层 2-3 根：水平方向伸出
##   2-4 格再上翘 1-2 格（方向由种子定）；
## - 叶冠：每根末梢枝端叶球 + 主干顶大叶球（叶格列表返回，
##   由调用方决定入区块还是收集）。
class_name TreeGenerator
extends RefCounted

const UP := Vector3i(0, 1, 0)
const HORIZONTALS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
## 树冠水平影响半径（生命周期引用计数用）
const TREE_REACH := 4


## 撒种判定纯函数：该水平列是否长树（确定性 hash）。
static func has_tree_at(world_seed: int, col: Vector2i) -> bool:
	# 轻量确定性判定（无 RNG 分配）：hash 位取 [0,1) 与密度比较。
	# 与 terrain_generator 的撒种判定必须一致——生成端用同一公式。
	var h := hash([world_seed, col.x, col.y])
	return float(h & 0xFFFF) / 65536.0 < 0.003


## 生成一棵树的完整结构数据（确定性：同 seed 同 origin 同结构）。
## 返回 TreeInstance（枝干图 + 体素索引 + 叶格列表在 leaf_cells）。
static func generate(species: TreeSpecies, world_seed: int,
		origin: Vector3i) -> TreeInstance:
	var tree := TreeInstance.new()
	tree.species = species
	tree.origin = origin
	tree.random_seed = hash([world_seed, origin.x, origin.z])
	tree.tree_id = tree.random_seed

	var rng := RandomNumberGenerator.new()
	rng.seed = tree.random_seed

	# 主干：垂直，高度抖动 ±20%，半径底粗顶细逐格
	var h := maxi(5, int(round(float(species.trunk_height)
			* (0.8 + rng.randf() * 0.4))))
	var trunk := TreeInstance.BranchNode.new()
	trunk.id = tree.next_branch_id
	tree.next_branch_id += 1
	trunk.start_cell = origin
	trunk.end_cell = origin + UP * (h - 1)
	trunk.radius_start = species.trunk_base_radius
	trunk.radius_end = species.trunk_top_radius
	tree.root_branch_id = trunk.id
	tree.register_branch(trunk)

	# 主干逐格半径表（供占位写入与网格共用）
	# —— 半径线性插值：r(i) = round(base + (top-base) * i/(h-1))
	# 存进临时（mesh_builder 按 start/end 重算同样公式，无需存）

	# 侧枝：主干上部 40% 起，分 layers 层
	var layers := maxi(1, species.branch_layers)
	var first_layer_y := origin.y + int(float(h) * 0.6)
	for layer in layers:
		var ly := first_layer_y + layer * 2
		if ly >= origin.y + h - 1:
			break
		var count := maxi(1, species.branches_per_layer
				+ (1 if rng.randf() < 0.4 else 0))
		# 每层均分水平方向 + 种子偏移
		var dir_offset := rng.randi() % 4
		for k in count:
			var dir := HORIZONTALS[(dir_offset + k) % 4]
			var blen := maxi(2, species.branch_length
					+ (1 if rng.randf() < 0.35 else 0))
			var attach := Vector3i(
					origin.x + (trunk.end_cell.x - origin.x),
					ly, origin.z + (trunk.end_cell.z - origin.z))
			# 侧枝：水平伸出 blen 格再上翘 upturn 格
			var b := TreeInstance.BranchNode.new()
			b.id = tree.next_branch_id
			tree.next_branch_id += 1
			b.parent_id = trunk.id
			b.start_cell = attach + dir
			var mid := attach + dir * blen
			var tip := mid + UP * maxi(0, species.branch_upturn
					+ (1 if rng.randf() < 0.3 else 0))
			b.end_cell = tip
			b.radius_start = maxi(1, species.branch_radius + 1)
			b.radius_end = 1
			# 折线段拆两段：水平段 + 上翘段（BranchNode 是直线段）
			var horiz := TreeInstance.BranchNode.new()
			horiz.id = b.id
			horiz.parent_id = trunk.id
			horiz.start_cell = attach + dir
			horiz.end_cell = mid
			horiz.radius_start = maxi(2, species.branch_radius + 1)
			horiz.radius_end = maxi(1, species.branch_radius)
			tree.register_branch(horiz)
			if tip != mid:
				var upseg := TreeInstance.BranchNode.new()
				upseg.id = tree.next_branch_id
				tree.next_branch_id += 1
				upseg.parent_id = horiz.id
				upseg.start_cell = mid + UP
				upseg.end_cell = tip
				upseg.radius_start = 1
				upseg.radius_end = 1
				tree.register_branch(upseg)

	# 主干顶部上翘收尾（冠心）
	var crown := TreeInstance.BranchNode.new()
	crown.id = tree.next_branch_id
	tree.next_branch_id += 1
	crown.parent_id = trunk.id
	crown.start_cell = trunk.end_cell + UP
	crown.end_cell = crown.start_cell + UP * 2
	crown.radius_start = 1
	crown.radius_end = 1
	tree.register_branch(crown)

	return tree


## 叶冠格列表（世界坐标）：每根末梢枝（无子）末端叶球 + 冠心大球。
## 不覆盖非空气判断由调用方负责（这里只算格）。
static func leaf_cells(tree: TreeInstance) -> Array[Vector3i]:
	var rng := RandomNumberGenerator.new()
	rng.seed = tree.random_seed + 777
	var out: Array[Vector3i] = []
	var r_ball: int = tree.species.leaf_ball_radius
	for bid in tree.branches:
		var node: TreeInstance.BranchNode = tree.branches[bid]
		if not node.child_ids.is_empty():
			continue
		_ball_cells(out, node.end_cell, r_ball, rng, 0.85)
		# 沿末梢段每格补一个小球（沿途叶簇，树冠有体积）
		for c in node.cells():
			if c != node.end_cell:
				_ball_cells(out, c, maxi(1, r_ball - 1), rng, 0.5)
	# 冠心（主干顶收尾段末端）
	if tree.branches.has(tree.root_branch_id):
		var trunk: TreeInstance.BranchNode = tree.branches[tree.root_branch_id]
		var top := trunk.end_cell
		# 冠心球更大（crown_radius）
		for dy in range(2):
			for dx in range(-tree.species.crown_radius, tree.species.crown_radius + 1):
				for dz in range(-tree.species.crown_radius, tree.species.crown_radius + 1):
					var d := Vector3(dx, dy, dz).length()
					if d > float(tree.species.crown_radius) + 0.5:
						continue
					var p := top + Vector3i(dx, dy + 1, dz)
					if not out.has(p):
						out.append(p)
	return out


static func _ball_cells(out: Array[Vector3i], center: Vector3i,
		radius: int, rng: RandomNumberGenerator, density: float) -> void:
	for dy in range(-1, 2):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				var d := Vector3(dx, dy, dz).length()
				if d > float(radius) + 0.3:
					continue
				if d > 0.5 and rng.randf() > density:
					continue
				var p := center + Vector3i(dx, dy, dz)
				if not out.has(p):
					out.append(p)


## 主干某格的插值半径（占位写入用；mesh_builder 同公式）。
static func trunk_radius_at(tree: TreeInstance, cell: Vector3i) -> int:
	var trunk: TreeInstance.BranchNode = tree.branches.get(tree.root_branch_id)
	if trunk == null:
		return 1
	var h: int = (trunk.end_cell.y - trunk.start_cell.y)
	if h <= 0:
		return trunk.radius_start
	var t := clampf(float(cell.y - trunk.start_cell.y) / float(h),
			0.0, 1.0)
	return int(round(lerpf(float(trunk.radius_start),
			float(trunk.radius_end), t)))
