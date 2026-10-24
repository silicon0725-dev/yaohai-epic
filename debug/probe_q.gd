extends SceneTree

func _init() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = "user://tmp_probe_q"
	WorldSave.new("user://tmp_probe_q", VoxelTypes.build_default_registry()).erase_all()
	root.add_child(main)
	for i in 10:
		await process_frame
	var player: PlayerController = main.player
	var dm: DropManager = main.drop_manager
	var items: ItemRegistry = player.item_registry
	# 模拟 Q：选中槽 0（木镐太特殊，先放泥土）——直接调玩家丢弃入口
	player.inventory.add(items.id_for_name("core:dirt"), 4)
	player.call("_select", 0)
	player.call("_drop_held", false)
	var traced := dm.drop_at(dm.drop_count() - 1) if dm.drop_count() > 0 else null
	for frame in 240:
		await physics_frame
		if traced == null or not traced.is_inside_tree() if false else false:
			continue
		if traced == null:
			break
		var idx := -1
		for k in dm.drop_count():
			if dm.drop_at(k) == traced:
				idx = k
		if idx < 0:
			print("f%03d PICKED" % frame)
			break
		var d := traced
		var root_node: Node3D = dm._visuals[idx]
		# 嵌地度量：显示底面 vs 足迹内最高地面
		var support := root_node.position.y - (d.position.y - ItemDrop.HALF_HEIGHT)
		var bottom := root_node.position.y - support
		var ground := bottom
		for sx in [-d.footprint_radius, d.footprint_radius]:
			for sz in [-d.footprint_radius, d.footprint_radius]:
				for cy in range(floori(bottom) + 2, floori(bottom) - 2, -1):
					if ItemDrop._solid_at(main.world, Vector3i(
							floori(d.position.x + sx), cy, floori(d.position.z + sz))):
						ground = maxf(ground, float(cy + 1))
						break
		if frame % 4 == 0 or ground > bottom + 0.02:
			var spin_now := d.spin_angle + d.spin_phase
			var target_now := dm._target_pose(d, dm.cube_item(d.item_id), spin_now)
			print("f%03d g=%s t=%.4f embed=%.3f q=(%.2f,%.2f,%.2f,%.2f) target=(%.2f,%.2f,%.2f,%.2f)" % [
				frame, d.grounded, dm._landing_t[idx], ground - bottom,
				root_node.quaternion.x, root_node.quaternion.y,
				root_node.quaternion.z, root_node.quaternion.w,
				target_now.x, target_now.y, target_now.z, target_now.w])
	main.chunk_manager.save_system = null
	main.queue_free()
	await process_frame
	WorldSave.new("user://tmp_probe_q", VoxelTypes.build_default_registry()).erase_all()
	quit(0)
