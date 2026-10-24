## 光照桌面图形集成测试（第二测试组，headless 单元组之外）：
## 验证真实渲染行为——灯节点创建/释放、visible 与 shadow_enabled
## 切换确实改变画面（配对帧像素对比）、渲染器断言。
## 运行：godot --path . res://debug/light_integration.tscn （必须窗口化）
## 退出码 0=全部通过，1=有失败。
extends Node

const LightManagerScript := preload("res://systems/lighting/light_manager.gd")
const SRC := "user://saves/world1"
const ROOT := "user://tmp_userworld2"

var _failures: Array[String] = []


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		_failures.append(label)
		print("FAIL: ", label)


func _ready() -> void:
	var method := RenderingServer.get_current_rendering_method()
	print("renderer_method=", method)
	_check(method == "forward_plus", "实际渲染器为 forward_plus")
	if not DirAccess.dir_exists_absolute(ROOT):
		var d := DirAccess.open("user://saves")
		d.make_dir_recursive_absolute(ROOT)
		d.copy_absolute(SRC + "/world.json", ROOT + "/world.json")
		d.make_dir_recursive_absolute(ROOT + "/chunks")
		var sc := DirAccess.open(SRC + "/chunks")
		var tc := DirAccess.open(ROOT + "/chunks")
		for f in sc.get_files():
			tc.copy_absolute(sc.get_current_dir() + "/" + f,
					tc.get_current_dir() + "/" + f)
	get_window().size = Vector2i(1280, 720)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ROOT
	add_child(main)
	var waited := 0
	while waited < 2400:
		await get_tree().process_frame
		waited += 1
		if waited >= 120 and main.chunk_manager.is_idle():
			break
	var lm = LightManagerScript.new()
	add_child(lm)
	var player: PlayerController = main.player
	lm.camera = player.camera  # 调度器跟相机距离判定；不接则用原点 probe
	main.chunk_manager.focus = player
	# 站到树影带附近（用户位姿区域），灯放眼前地面
	player.global_position = Vector3(51.11, 15.0, -96.06)
	player.velocity = Vector3.ZERO
	player.rotation.y = -0.160614654421806
	player.camera.rotation.x = -0.67059999704361
	for i in 200:
		await get_tree().process_frame
		if i > 80 and main.chunk_manager.is_idle():
			break
	await _settle()

	# --- omni：可见性切换改变画面 ---
	var light_pos: Vector3 = player.global_position \
			+ player.global_transform.basis.z.normalized() * -4.0
	light_pos.y = float(_ground_y(main, light_pos)) + 1.2
	var id: int = lm.add_light({
		"type": "omni",
		"position": light_pos,
		"color": Color(1.0, 0.75, 0.45),
		"energy": 3.0,
		"range": 10.0,
		"shadow_requested": true,
	})
	var rec: Dictionary = lm._records[id]
	_check(rec.node is OmniLight3D, "omni 灯节点真实创建")
	_check(rec.node.is_inside_tree(), "灯节点已进场景树")
	_check(rec.node.visible, "范围内灯可见")
	_check(rec.shadow_granted, "唯一请求者获得阴影资格")
	await _settle()
	var img_on: Image = get_viewport().get_texture().get_image()
	lm.set_light_enabled(id, false)  # 走 API：手动 visible 会被调度器改回
	var img_off: Image = await _settle_shot(img_on)
	lm.set_light_enabled(id, true)
	await _settle()
	var diff := _diff_px(img_on, img_off)
	_check(diff > 2000, "omni 启停改变画面（差异像素 %d）" % diff)

	# --- shadow_enabled 切换改变画面（灯下放个遮挡物看影）---
	# 简化：直接对比 shadow on/off 两帧（灯照亮区域内部自遮挡变化
	# 在树影带内足够明显）
	var img_sh_on: Image = get_viewport().get_texture().get_image()
	rec.node.shadow_enabled = false
	await _settle()
	var img_sh_off: Image = get_viewport().get_texture().get_image()
	var diff_sh := _diff_px(img_sh_on, img_sh_off)
	rec.node.shadow_enabled = true
	_check(diff_sh > 100, "shadow_enabled 切换改变画面（差异像素 %d）" % diff_sh)

	# --- spot：创建 + 朝向 ---
	var sid: int = lm.add_light({
		"type": "spot",
		"position": light_pos + Vector3(0, 1.5, 0),
		"direction": Vector3.DOWN,
		"angle": 0.7,
		"energy": 3.0,
		"range": 9.0,
		"color": Color(0.6, 0.8, 1.0),
	})
	var srec: Dictionary = lm._records[sid]
	_check(srec.node is SpotLight3D, "spot 灯节点真实创建")
	var fwd: Vector3 = -srec.node.basis.z
	_check(fwd.dot(Vector3.DOWN) > 0.99, "spot 竖直朝下（上向轴退化路径）")
	# 关 omni + 压暗太阳再拍 spot 对：日光（sun 1.2 + 环境天空 1.0）
	# 下叠加中等强度 spot 经 FILMIC 色调映射后不足一个灰阶
	#（曾误报 0 差异——spot 池落在阳光直射地面）
	lm.set_light_enabled(id, false)
	var sun: DirectionalLight3D = _find_sun(main)
	var sun_energy: float = sun.light_energy
	sun.light_energy = 0.0
	# A/B 对照：手工同参数 spot（略偏移 XZ），与管理器 spot 同场对比
	var manual := SpotLight3D.new()
	add_child(manual)
	manual.global_position = light_pos + Vector3(2.0, 1.5, 0)
	manual.rotation_degrees.x = -90.0
	manual.light_color = Color(0, 1, 0)
	manual.light_energy = 3.0
	manual.spot_range = 9.0
	manual.spot_angle = 40.0  # 度（SpotLight3D 属性单位）
	await _settle()
	var snode: SpotLight3D = srec.node
	print("SPOT pos=", snode.global_position, " cam=",
			player.camera.global_position, " fwd=", -snode.basis.z,
			" visible=", snode.visible, " energy=", snode.light_energy,
			" range=", snode.spot_range, " angle=", snode.spot_angle,
			" dist=", snode.global_position.distance_to(
					player.camera.global_position))
	var img_spot: Image = get_viewport().get_texture().get_image()
	lm.set_light_enabled(sid, false)
	var img_spot_off: Image = await _settle_shot(img_spot)
	sun.light_energy = sun_energy
	manual.queue_free()
	lm.set_light_enabled(id, true)
	await _settle()
	img_spot.save_png("res://debug/li_spot_on.png")
	img_spot_off.save_png("res://debug/li_spot_off.png")
	_check(_diff_px(img_spot, img_spot_off) > 1000, "spot 启停改变画面")

	# --- remove_light：节点真实释放 ---
	var node: OmniLight3D = rec.node
	lm.remove_light(id)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(not is_instance_valid(node), "remove_light 后节点真实释放")
	_check(lm.get_stats().registered == 1, "注销后 registered 计数正确")
	if _failures.is_empty():
		print("INTEGRATION ALL PASS")
		get_tree().quit(0)
	else:
		print("INTEGRATION FAILED: ", _failures)
		get_tree().quit(1)


func _diff_px(a: Image, b: Image) -> int:
	var n := 0
	var aw: int = a.get_width()
	var ah: int = a.get_height()
	for y in range(0, ah, 4):
		for x in range(0, aw, 4):
			if a.get_pixel(x, y).to_argb32() != b.get_pixel(x, y).to_argb32():
				n += 1
	return n


func _ground_y(main: Node, at: Vector3) -> int:
	var world: VoxelWorld = main.world
	for y in range(40, 4, -1):
		if world.get_block(Vector3i(int(floor(at.x)), y,
				int(floor(at.z)))) != 0:
			return y
	return 12


func _find_sun(node: Node) -> DirectionalLight3D:
	for c in node.get_children():
		if c is DirectionalLight3D:
			return c
		var r = _find_sun(c)
		if r != null:
			return r
	return null


func _settle() -> void:
	for i in 30:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


## 采样截图 + 帧冻结防御：与参照帧逐像素相同则再 settle 重拍
##（本机偶发连续帧字节相同——既知怪癖，重跑即好）
func _settle_shot(reference: Image) -> Image:
	for attempt in 3:
		await _settle()
		var img: Image = get_viewport().get_texture().get_image()
		if _diff_px(img, reference) > 0:
			return img
		print("frame-freeze retry ", attempt + 1)
	return get_viewport().get_texture().get_image()
