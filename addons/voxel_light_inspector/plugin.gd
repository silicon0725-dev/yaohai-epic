@tool
## 光照探查插件：编辑器视口叠加体素天光/方块光热力图 + 悬停/点击探针。
## 世界数据在编辑器内 1:1 重建（world_rebuilder.gd）——与游戏同一套
## 生成/存档/光照代码；玩家挖掘后的最新状态以最近一次存档为准
##（游戏退出/自动保存/卸载落盘）。
## 热力图/边框挂在编辑场景根下但 owner 为空——不会写进场景文件。
extends EditorPlugin

const DockScript := preload("res://addons/voxel_light_inspector/light_probe_dock.gd")
const Rebuilder := preload("res://addons/voxel_light_inspector/world_rebuilder.gd")
const HeatBuilder := preload("res://addons/voxel_light_inspector/heat_mesh_builder.gd")

var _dock: Control
var _overlay: Node3D
var _heat_instance: MeshInstance3D
var _border_instance: MeshInstance3D
var _heat_material: StandardMaterial3D
var _border_material: StandardMaterial3D
var _ctx: Dictionary = {}
var _world = null
var _light = null  # VoxelLight（Node，不入树；free 于重建/退出时）
var _chunk_source: Dictionary = {}  # coord -> "save"/"generate"
var _probe_mode := true
var _probe_result: Dictionary = {}
var _probe_camera: Camera3D = null
var _rebuilding := false


func _enter_tree() -> void:
	_dock = DockScript.new()
	_dock.name = "光照探查"
	_dock.plugin = self
	add_control_to_dock(DOCK_SLOT_LEFT_UR, _dock)
	get_tree().node_removed.connect(_on_node_removed)


func _exit_tree() -> void:
	if get_tree() != null:
		get_tree().node_removed.disconnect(_on_node_removed)
	_detach_overlay()
	if _light != null:
		_light.free()
		_light = null
	_world = null
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null


func _on_node_removed(node: Node) -> void:
	# 用户关闭/切换场景时叠加节点随场景销毁——清引用防悬空
	if node == _overlay:
		_overlay = null
		_heat_instance = null
		_border_instance = null


# ---- 3D 视口输入（探针） ----

func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if not _probe_mode or _world == null or _rebuilding:
		return AFTER_GUI_INPUT_PASS
	if event is InputEventMouseMotion:
		_probe_camera = viewport_camera
		_run_probe(viewport_camera, (event as InputEventMouseMotion).position)
		return AFTER_GUI_INPUT_PASS
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_probe_camera = viewport_camera
			_run_probe(viewport_camera, mb.position)
			return AFTER_GUI_INPUT_STOP  # 探针模式下吃掉左键，防误选场景节点
	return AFTER_GUI_INPUT_PASS


func _run_probe(camera: Camera3D, mouse_pos: Vector2) -> void:
	var from := camera.project_ray_origin(mouse_pos)
	var dir := camera.project_ray_normal(mouse_pos)
	_probe_result = Rebuilder.probe(_world, from, dir)
	_dock.show_probe(_probe_result, _world, _chunk_source)
	update_overlays()


func _forward_3d_draw_over_viewport(viewport_control: Control) -> void:
	if _probe_result.is_empty() or _probe_camera == null:
		return
	var hit_pos: Vector3i = _probe_result.get("block_pos", Vector3i.ZERO)
	_draw_cell_box(viewport_control, _probe_camera, hit_pos, Color(1, 1, 1, 0.95))
	_draw_cell_box(viewport_control, _probe_camera,
			_probe_result.get("face_pos", Vector3i.ZERO), Color(0.5, 0.9, 1.0, 0.55))
	_draw_probe_text(viewport_control, _probe_camera, hit_pos)


func _draw_cell_box(control: Control, cam: Camera3D, cell: Vector3i, color: Color) -> void:
	var a := Vector3(cell)
	var corner_defs := [
		a, a + Vector3(1, 0, 0), a + Vector3(1, 0, 1), a + Vector3(0, 0, 1),
		a + Vector3(0, 1, 0), a + Vector3(1, 1, 0), a + Vector3(1, 1, 1), a + Vector3(0, 1, 1),
	]
	var pts: Array[Vector2] = []
	for c in corner_defs:
		if cam.is_position_behind(c):
			return
		pts.append(cam.unproject_position(c))
	for e in HeatBuilder._BOX_EDGES:
		control.draw_line(pts[e[0]], pts[e[1]], color, 1.5)


func _draw_probe_text(control: Control, cam: Camera3D, cell: Vector3i) -> void:
	var anchor := Vector3(cell) + Vector3(0.5, 1.05, 0.5)
	if cam.is_position_behind(anchor):
		return
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var lines: Array[String] = [
		"sky %d / blk %d" % [int(_probe_result.get("cell_sky", -1)),
				int(_probe_result.get("cell_block", -1))],
		String(_world.registry.name_for_id(int(_probe_result.get("block_id", 0)))),
	]
	var chunk = _probe_result.get("chunk")
	if chunk != null:
		lines.append("chunk %s" % chunk.chunk_coord)
	var p := cam.unproject_position(anchor) + Vector2(10, -6)
	var y := p.y
	for line in lines:
		control.draw_string(font, Vector2(p.x, y), line,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.95))
		y += 15.0


# ---- 重建与显示（Dock 调用） ----

func request_rebuild() -> void:
	if not _rebuilding:
		_rebuild()


func _rebuild() -> void:
	_rebuilding = true
	_dock.set_rebuilding(true)
	_dock.clear_status()
	_detach_overlay()
	_probe_result = {}
	update_overlays()
	var tree := _dock.get_tree()

	_ctx = Rebuilder.load_world_context(_dock.save_root_text())
	var config = _ctx.get("config")
	_dock.set_busy("读档 meta（seed=%d，存档区块 %d）…" % [
		config.world_seed, int(_ctx.get("saved_chunks", 0))])
	await tree.process_frame

	var bw: Dictionary = Rebuilder.build_world(_ctx)
	_world = bw["world"]
	_light = bw["light"]
	_chunk_source = {}
	var coords: Array = Rebuilder.range_coords(
			_dock.radius(), _dock.center_xz(), int(config.chunks_y))
	var save = _ctx.get("save")
	var generator = bw["generator"]
	var done := 0
	for coord in coords:
		var fr: Dictionary = Rebuilder.fill_chunk(
				_world, generator, save, coord, _dock.use_save())
		_chunk_source[coord] = fr["source"]
		done += 1
		if done % 12 == 0:
			_dock.set_busy("生成区块 %d/%d…" % [done, coords.size()])
			await tree.process_frame

	_dock.set_busy("光照传播收敛…")
	await tree.process_frame
	var passes: int = Rebuilder.converge_light(_world, _light)

	refresh_display()
	_rebuilding = false
	_dock.set_rebuilding(false)
	_dock.set_busy("")
	var native_text := "原生C#" if Rebuilder.native_available() else "GDScript回退"
	_dock.set_stats("区块 %d · 光照 %d 轮收敛 · %s · 来源：存档 %d / 生成 %d" % [
		_world.chunk_count(), passes, native_text,
		_count_source("save"), _count_source("generate")])
	if not bool(_ctx.get("has_meta", false)):
		_dock.set_status("无存档（纯生成世界，种子 %d）" % int(config.world_seed))


## 显示参数变化：从缓存世界重建网格（不重新生成数据）。
func refresh_display() -> void:
	if _world == null:
		return
	var built: Dictionary = HeatBuilder.build(_world, {
		"sky": _dock.sky_on(),
		"block": _dock.block_on(),
		"min_level": _dock.min_level(),
		"max_level": _dock.max_level(),
		"borders": _dock.borders_on(),
	})
	if not _attach_overlay():
		return
	_heat_instance.mesh = built.get("heat")
	_heat_instance.visible = built.get("heat") != null
	_border_instance.mesh = built.get("border")
	_border_instance.visible = _dock.borders_on() and built.get("border") != null


func set_probe_mode(on: bool) -> void:
	_probe_mode = on
	if not on:
		_probe_result = {}
		update_overlays()


func _attach_overlay() -> bool:
	if _overlay != null and is_instance_valid(_overlay):
		return true
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null or not (scene_root is Node3D):
		_dock.set_status("先打开 3D 场景（main.tscn）再显示叠加")
		return false
	_overlay = Node3D.new()
	_overlay.name = "VoxelLightInspectorOverlay"
	scene_root.add_child(_overlay)  # owner 缺省 null——不写进场景文件
	if _heat_material == null:
		_heat_material = StandardMaterial3D.new()
		_heat_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_heat_material.vertex_color_use_as_albedo = true
		_heat_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_heat_material.disable_receive_shadows = true
	if _border_material == null:
		_border_material = StandardMaterial3D.new()
		_border_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_border_material.albedo_color = Color(1, 1, 1, 0.4)
		_border_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_heat_instance = MeshInstance3D.new()
	_heat_instance.material_override = _heat_material
	_heat_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_overlay.add_child(_heat_instance)
	_border_instance = MeshInstance3D.new()
	_border_instance.material_override = _border_material
	_border_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_overlay.add_child(_border_instance)
	return true


func _detach_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		if _overlay.get_parent() != null:
			_overlay.get_parent().remove_child(_overlay)
		_overlay.free()
	_overlay = null
	_heat_instance = null
	_border_instance = null


func _count_source(source: String) -> int:
	var n := 0
	for key in _chunk_source:
		if _chunk_source[key] == source:
			n += 1
	return n
