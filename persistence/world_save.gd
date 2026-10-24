## 世界存档（开发文档 §9.1、§9.2）：
##   <root>/world.json          元数据（格式版本/种子/生成版本/配置/玩家状态）
##   <root>/chunks/c_x_y_z.bin  被修改区块的完整压缩数据（增量落盘）
##
## 原子写入（§9.2）：所有文件先写 <path>.tmp，校验后 rename 替换，
## 进程中断不会留下半截文件；写入失败保留旧文件并报错。
## 区块文件容器：u32 magic "VCSF" + u16 容器版本 + u32 原始长度
## + zstd 压缩的 ChunkSerializer 载荷。
class_name WorldSave
extends RefCounted

const FORMAT_VERSION := 1
const FILE_MAGIC := 0x56435346  # "VCSF"
const META_FILE := "world.json"
const CHUNKS_DIR := "chunks"

var root: String
var registry: VoxelRegistry


func _init(p_root: String, p_registry: VoxelRegistry) -> void:
	root = p_root
	registry = p_registry


# ---- 路径 ----

func meta_path() -> String:
	return root + "/" + META_FILE


func chunks_dir() -> String:
	return root + "/" + CHUNKS_DIR


func chunk_path(coord: Vector3i) -> String:
	return "%s/c_%d_%d_%d.bin" % [chunks_dir(), coord.x, coord.y, coord.z]


func has_save() -> bool:
	return FileAccess.file_exists(meta_path())


func has_chunk(coord: Vector3i) -> bool:
	return FileAccess.file_exists(chunk_path(coord))


## 已落盘区块数（HUD/诊断用；目录扫描，低频调用）。
func saved_chunk_count() -> int:
	var dir := DirAccess.open(chunks_dir())
	if dir == null:
		return 0
	var count := 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.ends_with(".bin"):
			count += 1
		entry = dir.get_next()
	dir.list_dir_end()
	return count


func ensure_dirs() -> bool:
	var base := DirAccess.open("user://")
	if base == null:
		push_error("无法打开 user:// 目录")
		return false
	var relative := root.trim_prefix("user://")
	var err := base.make_dir_recursive(relative + "/" + CHUNKS_DIR)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("创建存档目录失败: %s (%s)" % [root, error_string(err)])
		return false
	return true


## 删除整个存档目录（开新世界 / 测试隔离用）。仅允许 user:// 路径。
func erase_all() -> void:
	_remove_tree(root)


static func _remove_tree(path: String) -> void:
	if not path.begins_with("user://"):
		push_error("拒绝删除 user:// 之外的路径: %s" % path)
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	var entries: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			entries.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	for name in entries:
		var child := path + "/" + name
		if DirAccess.dir_exists_absolute(child):
			_remove_tree(child)
		else:
			DirAccess.remove_absolute(child)
	DirAccess.remove_absolute(path)


# ---- 元数据 ----

## extra 为附加世界状态（如掉落实体 {"drops": [...]}），键不得与
## 保留键（format_version/world_seed/...）冲突，冲突键忽略并告警。
func save_meta(
		world: VoxelWorld, player_state: Dictionary, extra := {}
) -> bool:
	if not ensure_dirs():
		return false
	var meta := {
		"format_version": FORMAT_VERSION,
		"world_seed": world.config.world_seed,
		"generator_version": TerrainGenerator.GENERATOR_VERSION,
		"world_config": {
			"chunk_size": world.config.chunk_size,
			"chunks_y": world.config.chunks_y,
		},
		"player_state": player_state,
		"saved_at": Time.get_datetime_string_from_system(),
	}
	for key in extra:
		if meta.has(key):
			push_warning("元数据扩展键 %s 与保留键冲突，已忽略" % key)
		else:
			meta[key] = extra[key]
	var text := JSON.stringify(meta, "\t")
	var verify := func(path: String) -> bool: return _verify_meta_file(path)
	var ok := _atomic_write(meta_path(), text.to_utf8_buffer(), verify)
	if not ok:
		push_error("保存世界元数据失败: %s" % meta_path())
	return ok


## 返回 {} 表示无存档或不可读（已记录原因），调用方按新世界处理。
func load_meta() -> Dictionary:
	if not has_save():
		return {}
	var file := FileAccess.open(meta_path(), FileAccess.READ)
	if file == null:
		push_warning("存档元数据无法打开，按新世界处理")
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("存档元数据损坏（非法 JSON），按新世界处理")
		return {}
	var meta: Dictionary = parsed
	if not SaveMigrations.is_format_compatible(
			int(meta.get("format_version", -1))):
		push_warning("存档格式版本 %d 不受支持，按新世界处理" % [
			int(meta.get("format_version", -1))])
		return {}
	return meta


# ---- 区块 ----

## 保存被修改的区块（增量存盘）。成功后清除 save_needed。
## 未修改区块为无操作（返回 true）。
func save_chunk(chunk: ChunkData) -> bool:
	if not chunk.data_modified:
		return true
	if not ensure_dirs():
		return false
	var payload := ChunkSerializer.serialize(registry, chunk)
	var compressed := payload.compress(FileAccess.COMPRESSION_ZSTD)
	var container := StreamPeerBuffer.new()
	container.big_endian = false
	container.put_u32(FILE_MAGIC)
	container.put_u16(FORMAT_VERSION)
	container.put_u32(payload.size())
	container.put_data(compressed)
	var path := chunk_path(chunk.chunk_coord)
	var raw_length := payload.size()
	var verify := func(check_path: String) -> bool: return _verify_chunk_file(check_path, raw_length)
	var ok := _atomic_write(path, container.data_array, verify)
	if ok:
		chunk.save_needed = false
	else:
		push_error("保存区块失败: %s" % path)
	return ok


## 读取区块；无文件或损坏返回 null（已记录原因），调用方回退生成。
## 读出的区块视为"已持久化"：data_modified=true（与重新生成结果不同）
## 但 save_needed=false（磁盘上已是最新），直到再次被修改。
func load_chunk(coord: Vector3i) -> ChunkData:
	var path := chunk_path(coord)
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("区块存档无法打开: %s" % path)
		return null
	var raw: PackedByteArray = file.get_buffer(file.get_length())
	file.close()
	if raw.size() < 10:
		push_warning("区块存档过短: %s" % path)
		return null
	var peer := StreamPeerBuffer.new()
	peer.big_endian = false
	peer.data_array = raw
	if peer.get_u32() != FILE_MAGIC:
		push_warning("区块存档容器损坏: %s" % path)
		return null
	var container_version := peer.get_u16()
	if container_version > FORMAT_VERSION:
		push_warning("区块存档容器版本 %d 不受支持: %s" % [container_version, path])
		return null
	var raw_length := peer.get_u32()
	# 此时光标恰在读完 10 字节容器头之后（magic 4 + 版本 2 + 长度 4）
	var compressed_result: Array = peer.get_data(raw.size() - 10)
	if compressed_result[0] != OK:
		push_warning("区块存档读取压缩体失败: %s" % path)
		return null
	if compressed_result[1] == null or (compressed_result[1] as PackedByteArray).size() <= 0:
		push_warning("区块存档压缩体为空: %s" % path)
		return null
	var payload := (compressed_result[1] as PackedByteArray).decompress(
			raw_length, FileAccess.COMPRESSION_ZSTD)
	return _finish_load(payload, coord, path)


func _finish_load(
		payload: PackedByteArray, coord: Vector3i, path: String
) -> ChunkData:
	var chunk := ChunkSerializer.deserialize(registry, payload, coord)
	if chunk == null:
		push_warning("区块存档内容无效: %s" % path)
		return null
	chunk.data_modified = true
	chunk.save_needed = false
	return chunk


# ---- 原子写入（§9.2）----

## 写入 path.tmp -> 关闭 -> 校验回读 -> rename 原子替换。
## 任一步失败：返回 false、保留旧文件并清理 tmp。
static func _atomic_write(
		path: String,
		payload: PackedByteArray,
		verify: Callable
) -> bool:
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		push_error("无法写入临时文件: %s" % tmp)
		return false
	file.store_buffer(payload)
	file.close()
	var verified := false
	var check := FileAccess.open(tmp, FileAccess.READ)
	if check != null:
		var size_ok := check.get_length() == payload.size()
		check.close()
		verified = size_ok and bool(verify.call(tmp))
	if not verified:
		push_error("临时文件校验失败，保留旧文件: %s" % path)
		_remove_quietly(tmp)
		return false
	var rename_error := DirAccess.rename_absolute(
			ProjectSettings.globalize_path(tmp),
			ProjectSettings.globalize_path(path))
	if rename_error != OK:
		push_error("原子替换失败: %s -> %s (%s)" % [
			tmp, path, error_string(rename_error)])
		_remove_quietly(tmp)
		return false
	return true


static func _remove_quietly(path: String) -> void:
	if path.begins_with("user://"):
		var dir := DirAccess.open("user://")
		if dir != null:
			dir.remove_absolute(ProjectSettings.globalize_path(path))


## 元数据校验：能重新解析为带正确格式版本的 JSON。
static func _verify_meta_file(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed is Dictionary \
			and int(parsed.get("format_version", -1)) == FORMAT_VERSION


## 区块容器校验：magic / 容器版本 / 原始长度 / 最小体积。
static func _verify_chunk_file(path: String, expected_raw_length: int) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var ok := file.get_32() == FILE_MAGIC
	ok = ok and file.get_16() == FORMAT_VERSION
	ok = ok and file.get_32() == expected_raw_length
	ok = ok and file.get_length() >= 10
	file.close()
	return ok
