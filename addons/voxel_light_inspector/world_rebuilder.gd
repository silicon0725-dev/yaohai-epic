## 编辑器侧世界重建器（光照探查插件内核）。
## 与游戏同一套代码在编辑器上下文拼出可查询的 VoxelWorld：
## 存档 meta 恢复种子/配置 → TerrainGenerator 确定性生成 /
## WorldSave 叠加玩家改动 → VoxelLight.init_chunk_light 迭代到不动点。
## 光照 BFS 单调收敛唯一（与游戏加载顺序无关）——内部区块光值与
## 游戏内一致；边缘区块对未加载侧的行为也与游戏相同（按 null 邻居）。
## 纯同步实现供 headless 测试直调；Dock 侧自行分帧调度。
## 生成/存档/光照类已在对应文件加 @tool（编辑器上下文实例化要求）。
extends RefCounted

const VoxelTypesScript := preload("res://core/voxel_types.gd")
const WorldConfigScript := preload("res://core/world_config.gd")
const VoxelWorldScript := preload("res://world/voxel_world.gd")
const VoxelCoordsScript := preload("res://core/voxel_coords.gd")
const ChunkStateScript := preload("res://world/chunk_state.gd")
const TerrainGeneratorScript := preload("res://generation/terrain_generator.gd")
const VoxelLightScript := preload("res://systems/lighting/voxel_light.gd")
const WorldSaveScript := preload("res://persistence/world_save.gd")
const VoxelRaycastScript := preload("res://physics/voxel_raycast.gd")
const NativeTerrainBridge := preload("res://meshing/native_terrain_bridge.gd")
const NativeMeshBridge := preload("res://meshing/native_mesh_bridge.gd")

## 与 main.gd 同源的游戏默认值（无存档时用）
const DEFAULT_SAVE_ROOT := "user://saves/world1"
const GAME_DEFAULT_SEED := 1337
## 光照不动点最大迭代轮数（光最远传播 15 格 < 16 格区块宽，
## 3 轮内必收敛；4 轮兜底）
const MAX_LIGHT_PASSES := 4


## 读存档 meta 恢复世界配置；无存档时用游戏默认种子。
## 返回 { registry, config, save, has_meta, saved_chunks }。
static func load_world_context(save_root: String) -> Dictionary:
	var registry = VoxelTypesScript.build_default_registry()
	var save = WorldSaveScript.new(save_root, registry)
	var config = WorldConfigScript.new()
	var meta: Dictionary = save.load_meta()
	var has_meta := not meta.is_empty()
	if has_meta:
		config.world_seed = int(meta.get("world_seed", GAME_DEFAULT_SEED))
		var saved_config: Dictionary = meta.get("world_config", {})
		config.chunk_size = int(saved_config.get("chunk_size", config.chunk_size))
		config.chunks_y = int(saved_config.get("chunks_y", config.chunks_y))
	else:
		config.world_seed = GAME_DEFAULT_SEED
	return {
		"registry": registry,
		"config": config,
		"save": save,
		"has_meta": has_meta,
		"saved_chunks": save.saved_chunk_count(),
	}


## 构建空世界 + 生成器 + 光照系统（原生桥预热与 main.gd 同序）。
## 返回 { world, generator, light }。
static func build_world(ctx: Dictionary) -> Dictionary:
	var config = ctx["config"]
	var registry = ctx["registry"]
	var world = VoxelWorldScript.new(config, registry)
	var generator = TerrainGeneratorScript.new(config)
	NativeTerrainBridge.prewarm(config.world_seed, config.world_height_blocks())
	NativeMeshBridge.prewarm(registry)
	var light = VoxelLightScript.new()
	light.setup(world)
	return {"world": world, "generator": generator, "light": light}


## 重建范围内的区块坐标清单（方形区域 × 全部垂直层）。
static func range_coords(radius: int, center_xz: Vector2i, chunks_y: int) -> Array:
	var coords: Array = []
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			for cy in chunks_y:
				coords.append(Vector3i(center_xz.x + dx, cy, center_xz.y + dz))
	return coords


## 单区块落位：存档优先（玩家改动），否则确定性生成。
## 返回 { chunk, source }（source = "save" / "generate"）。
static func fill_chunk(world, generator, save, coord: Vector3i, use_save: bool) -> Dictionary:
	var chunk = null
	var source := "generate"
	if use_save and save.has_chunk(coord):
		chunk = save.load_chunk(coord)
		if chunk != null:
			source = "save"
	if chunk == null:
		chunk = generator.generate_chunk(coord)
	# 编辑器重建态：数据已就绪（无网格管线，状态枚举取最接近语义）
	chunk.state = ChunkStateScript.State.DATA_READY
	world.add_chunk(chunk)
	return {"chunk": chunk, "source": source}


## 光照收敛：init_chunk_light（含邻块边界播入）整域迭代到不动点。
## 返回实际迭代轮数（收敛后重复调用返回 1）。
static func converge_light(world, light) -> int:
	var passes := 0
	for pass_i in MAX_LIGHT_PASSES:
		passes = pass_i + 1
		var changed := false
		for coord in world.chunks:
			var chunk = world.chunks[coord]
			var before: PackedByteArray = chunk.light.duplicate()
			var neighbors: Array = [null, null, null, null, null, null]
			var dirs: Array = VoxelLightScript.DIRS
			for k in dirs.size():
				neighbors[k] = world.chunks.get(coord + dirs[k])
			light.init_chunk_light(chunk, neighbors)
			if chunk.light != before:
				changed = true
		if not changed:
			break
	return passes


## 体素探针：复用游戏 DDA（挖掘/放置同款命中语义，射线穿水）。
## 命中返回 { hit, block_pos, face_pos, block_id, distance,
##            cell_sky, cell_block, face_sky, face_block, chunk }；
## 未命中返回 {}。face_pos = 命中前面一格（命中面外侧，常为空气/水）。
static func probe(world, from: Vector3, dir: Vector3, max_distance: float = 96.0) -> Dictionary:
	var raw: Dictionary = VoxelRaycastScript.raycast(world, from, dir, max_distance)
	if not bool(raw.get("hit", false)):
		return {}
	var block_pos: Vector3i = raw["block_pos"]
	var normal: Vector3i = raw["normal"]
	var face_pos := block_pos + normal
	var cell_lv := light_at(world, block_pos)
	var face_lv := light_at(world, face_pos)
	return {
		"hit": true,
		"block_pos": block_pos,
		"face_pos": face_pos,
		"block_id": world.get_block(block_pos),
		"distance": float(raw.get("distance", 0.0)),
		"cell_sky": int(cell_lv.get("sky", -1)),
		"cell_block": int(cell_lv.get("block", -1)),
		"face_sky": int(face_lv.get("sky", -1)),
		"face_block": int(face_lv.get("block", -1)),
		"chunk": cell_lv.get("chunk"),
	}


## 查任意格光照与所属区块（未加载返回 {}）。
static func light_at(world, pos: Vector3i) -> Dictionary:
	var chunk = world.chunks.get(
			VoxelCoordsScript.world_to_chunk(pos, world.config.chunk_size))
	if chunk == null:
		return {}
	var local := VoxelCoordsScript.world_to_local(pos, world.config.chunk_size)
	return {
		"sky": chunk.get_sky_light(local),
		"block": chunk.get_block_light(local),
		"chunk": chunk,
	}


static func native_available() -> bool:
	return NativeMeshBridge.available()
