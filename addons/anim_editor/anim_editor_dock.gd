## 动作编辑器 dock：左资源（模型/动作/武器）+ 右 SubViewport 预览
##（复用 PlayerAvatar 全套蒙皮/动画/重定向）+ 时间轴播放队列。
## 播放真值源=时间轴 playhead：每帧 seek 定位段与段内时间直写
## animator._base_time → update(0) 采样（seek/播放/倒拖全同步）。
@tool
extends Control

const TimelineScript := preload("res://addons/anim_editor/anim_timeline.gd")
const ModelScript := preload("res://addons/anim_editor/anim_editor_model.gd")
const PlayerAvatar := preload("res://characters/player_avatar.gd")

const WEAPONS := ["无", "太刀（收刀）", "太刀（拔刀）"]

var model
var timeline: Control
var avatar = null              # PlayerAvatar 实例（弱类型）
var playing := false
var _switched_to := -1         # 当前 base 段（避免每帧 set_base）

var _vp_container: SubViewportContainer
var _viewport: SubViewport
var _cam_rig: Node3D
var _cam: Camera3D
var _model_list: ItemList
var _anim_list: ItemList
var _weapon_opt: OptionButton
var _play_btn: Button
var _info: Label
# 段属性区（选中队列块时显示：修剪/倍速/事件区间）
var _prop_row: HBoxContainer
var _trim_in: SpinBox
var _trim_out: SpinBox
var _seg_speed: SpinBox
var _ev_t0: SpinBox
var _ev_t1: SpinBox
var _ev_name: LineEdit
var _ev_del: Button
var _prop_idx := -1
# 播放事件扫掠状态（上一帧段内表观时间/段号）
var _sweep_idx := -1
var _sweep_local := 0.0

var _dragging_cam := false
var _cam_yaw := deg_to_rad(155.0)   # 3/4 正面（角色面向 -Z；曾 35° 背面
                                    # 俯视+远距，面板窄时角色过小难辨认）
var _cam_pitch := deg_to_rad(-8.0)
var _cam_dist := 2.5


class DragList extends ItemList:
	## 支持拖出的列表：meta[选中项] = 拖负载
	var drag_meta := {}

	func _get_drag_data(_pos: Vector2) -> Variant:
		var sel := get_selected_items()
		if sel.is_empty():
			return null
		var data: Dictionary = drag_meta.get(sel[0], {})
		if data.is_empty():
			return null
		var prev := Label.new()
		prev.text = String(data.get("label", "?"))
		set_drag_preview(prev)
		return data


func _init() -> void:
	custom_minimum_size = Vector2(640, 420)
	_build_ui()


func _exit_tree() -> void:
	# 不在此清 avatar——编辑器布局恢复会 reparent dock 触发本回调
	# （曾 queue_free 误杀 avatar，re-enter 后 _ready 不再执行 → 预览
	# 永久空白，dock 诊断"avatar valid=false"实锤）；dock 真正销毁时
	# 子节点随树自动释放
	pass


func _build_ui() -> void:
	var root := VBoxContainer.new()
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	# ---- 左：资源面板 ----
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(230, 0)
	split.add_child(panel)
	_model_list = _add_list_section(panel, "模型（拖到预览 / 双击切换）")
	_model_list.item_activated.connect(_on_model_activated)
	_anim_list = _add_list_section(panel, "动作（拖到时间轴 / 双击加入）",
			true)
	_anim_list.item_activated.connect(_on_anim_activated)
	var wrow := HBoxContainer.new()
	panel.add_child(wrow)
	var wlabel := Label.new()
	wlabel.text = "武器："
	wrow.add_child(wlabel)
	_weapon_opt = OptionButton.new()
	# 战斗系统下线时下拉禁用（avatar.COMBAT_ENABLED）
	if PlayerAvatar.COMBAT_ENABLED:
		for w in WEAPONS:
			_weapon_opt.add_item(w)
	else:
		_weapon_opt.disabled = true
	wrow.add_child(_weapon_opt)
	_weapon_opt.item_selected.connect(_on_weapon_selected)

	# ---- 右：预览 ----
	_vp_container = SubViewportContainer.new()
	_vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_container.stretch = true
	_vp_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_vp_container.gui_input.connect(_on_viewport_input)
	split.add_child(_vp_container)
	_viewport = SubViewport.new()
	_vp_container.add_child(_viewport)
	_viewport.handle_input_locally = false
	# 独立 3D 世界——SubViewport 默认继承父视口 World3D；挂在编辑器
	# dock 下=共享"正在编辑的场景"世界（预览拍的是编辑场景而非角色，
	# 实机"预览空白"根因；运行时窗口冒烟因父视口恰为空世界而侥幸通过）
	_viewport.own_world_3d = true

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50), deg_to_rad(30), 0)
	_viewport.add_child(sun)
	var fill := OmniLight3D.new()
	fill.position = Vector3(2, 3, 2)
	fill.omni_range = 8.0
	_viewport.add_child(fill)
	var floor := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(8, 0.2, 8)
	floor.mesh = box
	floor.position = Vector3(0, -0.1, 0)
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.32, 0.34, 0.3)
	floor.material_override = fmat
	_viewport.add_child(floor)

	_cam_rig = Node3D.new()
	_cam_rig.position = Vector3(0, 1.0, 0)
	_viewport.add_child(_cam_rig)
	_cam = Camera3D.new()
	_cam.position = Vector3(0, 0, _cam_dist)
	_cam_rig.add_child(_cam)

	# ---- 底：时间轴 + 控制 ----
	model = ModelScript.new()
	timeline = TimelineScript.new()
	timeline.set_model(model)
	root.add_child(timeline)
	timeline.seek_requested.connect(_on_seek)
	timeline.clip_appended.connect(_on_clip_drop)
	timeline.clip_selected.connect(_on_clip_selected)

	var bar := HBoxContainer.new()
	root.add_child(bar)
	_play_btn = Button.new()
	_play_btn.text = "▶ 播放"
	_play_btn.pressed.connect(_toggle_play)
	bar.add_child(_play_btn)
	var stop := Button.new()
	stop.text = "⏹ 停止"
	stop.pressed.connect(_stop)
	bar.add_child(stop)
	var clear := Button.new()
	clear.text = "清空队列"
	clear.pressed.connect(func(): model.clear(); _switched_to = -1)
	bar.add_child(clear)
	var loop := CheckButton.new()
	loop.text = "循环"
	loop.toggled.connect(func(v: bool): model.looping = v)
	bar.add_child(loop)
	var slabel := Label.new()
	slabel.text = "  速度："
	bar.add_child(slabel)
	var speed := OptionButton.new()
	for s in ["0.25×", "0.5×", "1×", "1.5×", "2×"]:
		speed.add_item(s)
	speed.select(2)
	speed.item_selected.connect(func(idx: int):
		model.speed = [0.25, 0.5, 1.0, 1.5, 2.0][idx])
	bar.add_child(speed)
	_info = Label.new()
	_info.text = "预览启动中…"
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(_info)
	var pop := Button.new()
	pop.text = "⤢ 大窗口"
	pop.tooltip_text = "弹出独立预览窗口（dock 面板窄时）"
	pop.pressed.connect(_toggle_popup)
	bar.add_child(pop)
	var save := Button.new()
	save.text = "保存"
	save.tooltip_text = "导出蒙太奇到 res://assets/anims/montages/"
	save.pressed.connect(_on_save_montage)
	bar.add_child(save)
	var load := Button.new()
	load.text = "载入"
	load.tooltip_text = "导入已保存的蒙太奇"
	load.pressed.connect(_on_load_montage)
	bar.add_child(load)
	# 段属性区（选中块显示）
	_prop_row = HBoxContainer.new()
	_prop_row.visible = false
	root.add_child(_prop_row)
	_trim_in = _add_spin(_prop_row, "入点", 0.0, 30.0, 0.01)
	_trim_out = _add_spin(_prop_row, "出点", 0.05, 60.0, 0.01)
	_seg_speed = _add_spin(_prop_row, "倍速", 0.05, 5.0, 0.05)
	_seg_speed.value = 1.0
	_trim_in.value_changed.connect(_on_trim_changed)
	_trim_out.value_changed.connect(_on_trim_changed)
	_seg_speed.value_changed.connect(_on_seg_speed_changed)
	_prop_row.add_child(_sep_label("  事件"))
	_ev_t0 = _add_spin(_prop_row, "起", 0.0, 60.0, 0.01)
	_ev_t1 = _add_spin(_prop_row, "止", 0.01, 60.0, 0.01)
	_ev_name = LineEdit.new()
	_ev_name.text = "hit"
	_ev_name.custom_minimum_size = Vector2(70, 0)
	_prop_row.add_child(_ev_name)
	var ev_add := Button.new()
	ev_add.text = "+"
	ev_add.tooltip_text = "添加事件区间（时间轴粉带）"
	ev_add.pressed.connect(_on_event_add)
	_prop_row.add_child(ev_add)
	_ev_del = Button.new()
	_ev_del.text = "删事件"
	_ev_del.pressed.connect(_on_event_del)
	_prop_row.add_child(_ev_del)


func _add_list_section(parent: Control, title: String,
		dragable := false) -> ItemList:
	var label := Label.new()
	label.text = title
	parent.add_child(label)
	var list: ItemList
	if dragable:
		list = DragList.new()
	else:
		list = ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.custom_minimum_size = Vector2(0, 90)
	parent.add_child(list)
	return list


func _add_spin(parent: Control, label: String, from: float, to: float,
		step: float) -> SpinBox:
	var l := _sep_label(label)
	parent.add_child(l)
	var sb := SpinBox.new()
	sb.min_value = from
	sb.max_value = to
	sb.step = step
	sb.custom_minimum_size = Vector2(74, 0)
	parent.add_child(sb)
	return sb


func _sep_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _ready() -> void:
	# avatar 需在树内创建（_ready 装骨骼/材质）
	avatar = PlayerAvatar.new()
	avatar.name = "PreviewAvatar"
	_viewport.add_child(avatar)
	# stub 挂 viewport 而非 avatar（build_model 会清 avatar 全部子节点）
	var stub_player := Node3D.new()
	stub_player.name = "StubPlayer"
	_viewport.add_child(stub_player)
	avatar.setup(stub_player, null)
	_apply_preview_light()
	_refresh_model_list()
	_refresh_anim_list()
	avatar.clips_ready.connect(_refresh_anim_list)  # 异步重定向就位后补清单
	avatar.set_weapon_mode(0)  # 预览默认无武器（曾默认收刀=场景见刀）
	_apply_camera()


func _refresh_model_list() -> void:
	_model_list.clear()
	if avatar == null:
		return
	for i in avatar.pack_dirs.size():
		# 包目录名=路径末段（曾 get_base_dir() 多一层：全显示 "characters"）
		var dir_name: String = String(avatar.pack_dirs[i]).get_file()
		_model_list.add_item(dir_name)
		if i == avatar.pack_index:
			_model_list.select(i)


func _refresh_anim_list() -> void:
	_anim_list.clear()
	if avatar == null:
		return
	_anim_list.drag_meta = {}
	var names: Array = avatar.clips.keys()
	names.sort_custom(func(a, b):
		return String(a) < String(b))
	for name in names:
		var clip: Dictionary = avatar.clips[name]
		var idx: int = _anim_list.add_item("%s  (%.1fs)" % [
				String(name).get_file(), float(clip["length"])])
		_anim_list.drag_meta[idx] = {
			"clip": name, "length": float(clip["length"]),
			"label": String(name).get_file(),
		}


func _on_weapon_selected(idx: int) -> void:
	if avatar != null:
		# 0 无（全隐）/ 1 收刀（鞘挂躯干）/ 2 拔刀（在手）——曾二态：
		# "无"=收刀，DMC 插鞘模型仍显示（用户"场景里也有刀"）
		avatar.set_weapon_mode(idx)
		_weapon_opt.select(idx)      # 程序触发时同步下拉显示（select 不重入信号）


# ---- 段属性区（选中队列块：修剪/倍速/事件区间） ----

func _on_clip_selected(idx: int) -> void:
	_prop_idx = idx
	if idx < 0 or idx >= model.queue.size():
		_prop_row.visible = false
		return
	var item: Dictionary = model.queue[idx]
	_prop_row.visible = true
	# 填值（set_value_no_signal 防回调环）
	_trim_in.set_value_no_signal(float(item["t0"]))
	_trim_out.set_value_no_signal(float(item["t1"]))
	_seg_speed.set_value_no_signal(float(item["speed"]))
	_ev_t0.set_value_no_signal(float(item["t0"]))
	_ev_t1.set_value_no_signal(minf(float(item["t0"]) + 0.3,
			float(item["t1"])))


func _on_trim_changed(_v: float) -> void:
	if _prop_idx < 0:
		return
	var item: Dictionary = model.queue[_prop_idx]
	var src: float = float(item["src_length"])
	item["t0"] = clampf(_trim_in.value, 0.0, float(item["t1"]) - 0.05)
	item["t1"] = clampf(_trim_out.value, float(item["t0"]) + 0.05, src)
	model.queue_changed.emit()   # 总长变化→时间轴重绘


func _on_seg_speed_changed(v: float) -> void:
	if _prop_idx < 0:
		return
	model.queue[_prop_idx]["speed"] = clampf(v, 0.05, 5.0)
	model.queue_changed.emit()


func _on_event_add() -> void:
	if _prop_idx < 0:
		return
	var item: Dictionary = model.queue[_prop_idx]
	item["events"].append({
		"t0": clampf(_ev_t0.value, float(item["t0"]), float(item["t1"])),
		"t1": clampf(maxf(_ev_t1.value, _ev_t0.value + 0.01),
				float(item["t0"]), float(item["t1"])),
		"name": _ev_name.text if _ev_name.text != "" else "evt",
	})
	model.queue_changed.emit()


func _on_event_del() -> void:
	if _prop_idx < 0:
		return
	var events: Array = model.queue[_prop_idx]["events"]
	if not events.is_empty():
		events.pop_back()
		model.queue_changed.emit()


# ---- 蒙太奇导出/导入（MVP 固定档案位） ----

const MONTAGE_PATH := "res://assets/anims/montages/montage_1.txt"


func _on_save_montage() -> void:
	if model.queue.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(
			"res://assets/anims/montages"))
	var f := FileAccess.open(MONTAGE_PATH, FileAccess.WRITE)
	f.store_string(var_to_str(model.export_montage("montage_1")))
	f.close()
	print("[anim_editor] 蒙太奇已保存 %s（%d 段）" % [MONTAGE_PATH,
			model.queue.size()])


func _on_load_montage() -> void:
	if not FileAccess.file_exists(MONTAGE_PATH):
		print("[anim_editor] 无已保存蒙太奇")
		return
	var data = str_to_var(FileAccess.get_file_as_string(MONTAGE_PATH))
	if model.import_montage(data):
		_switched_to = -1
		_on_seek(0.0)
		print("[anim_editor] 蒙太奇已载入（%d 段）" % model.queue.size())


func _on_model_activated(idx: int) -> void:
	if avatar == null or idx >= avatar.pack_dirs.size():
		return
	avatar.pack_index = idx
	avatar.build_model(avatar.pack_dirs[idx])
	avatar.set_armed(_weapon_opt.selected == 1)
	_apply_preview_light()  # build_model 重建材质，uniform 复位须重设
	_refresh_anim_list()   # 重定向按新 rig 重算，动作清单可能变化


## 蒙皮 shader 光照 uniform——游戏里由 main 下发；dock 不设=天光 0，
## 角色渲染成黑影（曾致"预览看不到角色"，用户实机主诉）。
func _apply_preview_light() -> void:
	if avatar != null and avatar.material != null:
		avatar.material.set_shader_parameter("u_day", 1.0)
		avatar.material.set_shader_parameter("u_sky", 1.0)
		avatar.material.set_shader_parameter("u_blk", 0.0)


func _on_anim_activated(idx: int) -> void:
	var data: Dictionary = _anim_list.drag_meta.get(idx, {})
	if data.is_empty():
		return
	model.append(String(data["clip"]), float(data["length"]))


func _on_clip_drop(clip_name: String) -> void:
	if avatar != null and avatar.clips.has(clip_name):
		model.append(clip_name, float(avatar.clips[clip_name]["length"]))


func _on_seek(t: float) -> void:
	var idx: int = model.seek(t)
	if idx >= 0:
		_apply_segment(idx, true)


func _apply_segment(idx: int, force := false) -> void:
	if avatar == null or idx < 0 or idx >= model.queue.size():
		return
	if idx != _switched_to or force:
		avatar.animator.set_base(String(model.queue[idx]["clip"]), 1.0,
				false, 0.15)
		_switched_to = idx


func _toggle_play() -> void:
	playing = not playing
	_play_btn.text = "⏸ 暂停" if playing else "▶ 播放"
	if playing and model.current_index() < 0:
		_on_seek(0.0)


func _stop() -> void:
	playing = false
	_play_btn.text = "▶ 播放"
	_on_seek(0.0)


func _process(delta: float) -> void:
	if avatar == null or avatar.animator == null:
		return
	if playing and not model.queue.is_empty():
		var sw: Dictionary = model.advance(delta)
		if sw.has("switch_to") and int(sw["switch_to"]) >= 0:
			_apply_segment(int(sw["switch_to"]))
		if model.playhead >= model.total_length() - 1e-4 and not model.looping:
			playing = false
			_play_btn.text = "▶ 播放"
	# 时间轴真值采样：段内表观时间 → 源时间（入点+表观×段速）直写
	# _base_time 后带 delta 推进（delta 供快照过渡；曾 update(0) 零推进
	# 致过渡冻结）；_base_time 每帧重写，update 内 +delta 漂移即时纠正
	var loc: Dictionary = model.locate(model.playhead)
	if not loc.is_empty():
		var idx := int(loc["index"])
		var item: Dictionary = model.queue[idx]
		var local_t := float(loc["local_t"])
		_apply_segment(idx)
		avatar.animator._base_time = model.source_time(item, local_t)
		var pose: Dictionary = avatar.animator.update(delta)
		avatar._apply_pose(pose)
		# 区间事件扫掠（仅正向播放；换段/seek 重置基准防误触发）
		if playing:
			if idx != _sweep_idx:
				_sweep_idx = idx
				_sweep_local = local_t
			else:
				for hit in model.sweep_events(item, _sweep_local, local_t):
					var ev: Dictionary = hit["event"]
					print("[anim_editor] 事件 %s %s（%.2f-%.2fs）" % [
							ev["name"], hit["phase"], ev["t0"], ev["t1"]])
				_sweep_local = local_t
	elif avatar.animator.base_name() != "":
		# 队列空：维持当前 base（默认 idle）呼吸——曾空队列不采样
		# （叠加骨骼纹理初始全零 → 预览空白）
		var pose2: Dictionary = avatar.animator.update(delta)
		avatar._apply_pose(pose2)
	_info.text = "%.2fs  段 %d/%d  [%s]" % [model.playhead,
			model.current_index() + 1, model.queue.size(),
			"播放中" if playing else "暂停"]
	timeline.queue_redraw()


# ---- 预览相机轨道（拖转 + 滚轮） ----

func _on_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging_cam = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_cam_dist = maxf(_cam_dist - 0.3, 1.2)
			_apply_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_cam_dist = minf(_cam_dist + 0.3, 8.0)
			_apply_camera()
	elif event is InputEventMouseMotion and _dragging_cam:
		_cam_yaw -= event.relative.x * 0.008
		_cam_pitch = clampf(_cam_pitch - event.relative.y * 0.006,
				-1.2, 0.6)
		_apply_camera()


func _apply_camera() -> void:
	if _cam_rig == null:
		return
	_cam_rig.rotation = Vector3(_cam_pitch, _cam_yaw, 0)
	_cam.position = Vector3(0, 0, _cam_dist)


# ---- 独立预览窗口（dock 面板窄时） ----

var _pop_window: Window = null
var _pop_split: HSplitContainer = null


func _toggle_popup() -> void:
	if _pop_window == null:
		_pop_split = _vp_container.get_parent() as HSplitContainer
		_pop_window = Window.new()
		_pop_window.title = "动作预览"
		_pop_window.size = Vector2i(900, 700)
		_pop_window.close_requested.connect(_toggle_popup)
		add_child(_pop_window)
		_pop_window.add_child(_vp_container)
	else:
		_pop_window.remove_child(_vp_container)
		_pop_split.add_child(_vp_container)
		_pop_window.queue_free()
		_pop_window = null
