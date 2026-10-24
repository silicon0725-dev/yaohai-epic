## 影子漏光 v11：把镜头怼到 t3 视图漏光斑 (1097,484) 对应的地面点
## 7 格处拍近景——分辨"真树影内亮洞"还是"多棵树影之间的阳光走廊"。
extends Node

const SRC := "user://saves/world1"
const ROOT := "user://tmp_userworld"
const CAM_TREE := Vector3(-132, 10, -18)
const BLOB_PX := Vector2(1097.0, 484.0)


func _ready() -> void:
	if not DirAccess.dir_exists_absolute(ROOT):
		var d := DirAccess.open("user://saves")
		d.make_dir_recursive_absolute(ROOT)
		d.copy_absolute(SRC + "/world.json", ROOT + "/world.json")
		d.make_dir_recursive_absolute(ROOT + "/chunks")
		var sc := DirAccess.open(SRC + "/chunks")
		var tc := DirAccess.open(ROOT + "/chunks")
		for f in sc.get_files():
			tc.copy_absolute(sc.get_current_dir() + "/" + f, tc.get_current_dir() + "/" + f)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ROOT
	add_child(main)
	var waited := 0
	while waited < 2400:
		await get_tree().process_frame
		waited += 1
		if waited >= 120 and main.chunk_manager.is_idle():
			break
	print("world ready")

	var sun: DirectionalLight3D = _find_sun(main)
	var ld := -sun.global_transform.basis.z.normalized()
	var flat := Vector3(ld.x, 0.0, ld.z).normalized()
	var player: PlayerController = main.player
	main.chunk_manager.focus = player

	# 复现 v7 机位
	player.global_position = Vector3(CAM_TREE) + flat * 10.0 + Vector3(0, 2.5, 0)
	player.velocity = Vector3.ZERO
	player.rotation.y = atan2(flat.x, flat.z)
	player.camera.rotation.x = -0.25
	await _settle_long()

	# 像素 → 世界射线 → 步进找地面
	var cam: Camera3D = player.camera
	var origin: Vector3 = cam.project_ray_origin(BLOB_PX)
	var dir: Vector3 = cam.project_ray_normal(BLOB_PX)
	print("ray o=", origin, " d=", dir)
	var world: VoxelWorld = main.world
	var hit := Vector3(origin)
	var found := false
	for i in 400:
		hit += dir * 0.25
		var bid: int = world.get_block(Vector3i(floor(hit.x), floor(hit.y), floor(hit.z)))
		if bid != VoxelTypes.AIR_ID and bid != VoxelTypes.WATER_ID:
			found = true
			break
	print("ground hit=", hit, " found=", found)
	if not found:
		hit = origin + dir * 20.0

	# 近景机位：地面点向原相机方向退 7 格、抬高 2.5，俯视地面点
	var to_cam := (origin - hit).normalized()
	player.global_position = hit + to_cam * 7.0 + Vector3(0, 2.5, 0)
	player.velocity = Vector3.ZERO
	var look := (hit + Vector3(0, 0.5, 0) - player.global_position).normalized()
	player.rotation.y = atan2(-look.x, -look.z) + PI
	player.camera.rotation.x = asin(clamp(look.y, -1.0, 1.0))
	print("close cam at ", player.global_position, " look ", look)
	await _settle_long()
	await _settle()
	_shot("res://debug/u11_closeup.png")
	sun.shadow_enabled = false
	await _settle()
	_shot("res://debug/u11_closeup_ref.png")
	print("done")
	get_tree().quit(0)


func _settle_long() -> void:
	for i in 150:
		await get_tree().process_frame


func _settle() -> void:
	for i in 40:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _shot(path: String) -> void:
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _find_sun(node: Node) -> DirectionalLight3D:
	for c in node.get_children():
		if c is DirectionalLight3D:
			return c
		var r = _find_sun(c)
		if r != null:
			return r
	return null
