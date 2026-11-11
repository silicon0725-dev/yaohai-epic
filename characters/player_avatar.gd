## 玩家角色化身（YSM 模型 + 规范骨架 + 分层动画）。
##
## 职责：模型包发现/装载（F6 切换）、骨架+蒙皮网格组装、动画集装载
## （内置程序化 + user://anim_ef 的 EF 风格动画重定向）、运动状态机
## （走/跑/跳/落/泳/待机 + 挖/拳动作层）、头部注视、体素光照采样下发。
## 纯代码组装（项目惯例：无 .tscn 依赖，新类 preload 引用）。
@tool
extends Node3D

const YsmModel := preload("res://characters/ysm_model.gd")
const CharacterRig := preload("res://characters/character_rig.gd")
const ClipLib := preload("res://characters/clip_lib.gd")
const Animator := preload("res://characters/character_animator.gd")
const EfRef := preload("res://characters/ef_reference_rig.gd")
const EfMesh := preload("res://characters/ef_mesh_loader.gd")
const BvhLoader := preload("res://characters/bvh_loader.gd")

const PACK_ROOT := "res://assets/characters"
const EF_CLIP_DIR := "user://anim_ef"
## ⚠ 战斗系统总开关（2026-11-11 用户"先把动作系统藏起来，之后再搞"）：
## false=拔刀战斗整体下线——刀/鞘模型不构建（局内不可见）、F7/闪避/
## 连击入口全 guard。全部代码与测试保留，翻回 true 即整体恢复。
const COMBAT_ENABLED := false
## CMU mocap 精选动作（res 内置，var_to_str 序列化的 Clip；许可见
## assets/anims/cmu/README.md——CMU "free for all uses"+署名）。
const CMU_DIR_RES := "res://assets/anims/cmu"
## 用户自放 *.bvh（CMU Daz-friendly BVH；运行时重定向，同 EF 自放模式）。
const BVH_DIR_USER := "user://anim_bvh"
## 动作层优先级覆盖：程序化动作名 → 高优 mocap 版 + 遮罩。
## mocap 战斗动作为全身驱动（"all"）——拳击幅度 96% 在 Root 转体轨
##（实测局部 95.9° vs 手臂 9°），上身遮罩下只剩微动"看不出出拳"。
const ACTION_OVERRIDES := {
	"punch": {"clip": "cmu/box_combo", "mask": "all"},
}

## ---- 拔刀模式（EF yamato 动作集；资产=用户自放 user://anim_ef 的
## DevilMineCraft 包，All-Rights-Reserved 不入库，缺件自动回退徒手） ----
## 基础层映射：状态 → yamato 持刀姿态/移动（walk 借 run 慢放）。
const EF_YAMATO_LIVING := {
	# idle 用 idle_2（持刀战斗待机：腕居胸前、刀水平指前、刀⊥前臂正握）
	# ——yamato_idle 是空手收刀待机（右手搭腰间），配出鞘刀=姿势与刀
	# 不匹配（用户实机"位置还是不对"；数值探针按腕位/刀尖向筛选）。
	"idle": "ef/biped/yamato/living/yamato_idle_2",
	"walk": "ef/biped/yamato/living/yamato_run",
	"run": "ef/biped/yamato/living/yamato_run",
	"jump": "ef/biped/yamato/living/yamato_jump",
	"fall": "ef/biped/yamato/living/yamato_jump",
}
## 三段连击链（左键连按；段间取消窗口 COMBO_CANCEL_AT）。
const ATTACK_CHAIN := [
	"ef/biped/yamato/attack/yamato_combo_a_1",
	"ef/biped/yamato/attack/yamato_combo_a_2",
	"ef/biped/yamato/attack/yamato_combo_a_3",
]
const COMBO_CANCEL_AT := 0.45  # 动作进度 45% 后可接下一段（提前按=缓冲）
## 闪避（双击方向键）：动作名 → 冲量方向（模型局部 -Z 前）。
const DODGE_CLIPS := {
	"forward": ["ef/biped/yamato/dodge/yamato_dodge_forward", Vector3(0, 0, -1)],
	"back": ["ef/biped/yamato/dodge/yamato_dodge_backward", Vector3(0, 0, 1)],
	"left": ["ef/biped/yamato/dodge/yamato_dodge_left", Vector3(-1, 0, 0)],
	"right": ["ef/biped/yamato/dodge/yamato_dodge_right", Vector3(1, 0, 0)],
}
const DODGE_SPEED := 7.0     # 闪避冲刺初速（m/s）
const DODGE_LOCK := 0.55     # 闪避硬直（锁新闪避/攻击）
const LIGHT_SAMPLE_INTERVAL := 0.15
const BODY_YAW_RATE := 14.0   # 身体朝向跟随视线速率（滞后产生自然感）
const HEAD_YAW_LIMIT := deg_to_rad(75.0)

var player   # PlayerController（不标窄类型：preload 类注解 headless 下不稳）
var world    # VoxelWorld

var pack_dirs: Array = []
var pack_index := 0

var rig := {}
var skeleton: Skeleton3D
var mesh_instance: MeshInstance3D
var material: ShaderMaterial

var animator
var clips := {}
var _ef_raw := {}          # EF 原始动画缓存（跨模型复用，重定向按 rig）
var _ef_loaded := false

var _body_yaw := 0.0
var _light_accum := 0.0
var _day_factor := 1.0
var _mining := false
var _was_swim := false
## 拔刀战斗状态（EF yamato）
var _armed := false
var _chain_idx := -1
var _buffered := false
var _dodge_lock := 0.0
var _dodge_impulse := Vector3.ZERO
var _weapon: Node3D      # 太刀（拔刀挂 Tool_R 腕关节；收刀插鞘）
var _sheath: Node3D     # 刀鞘（挂 Torso 左腰，鞘口=原点 +Y 口外）
var _weapon_dmc := false  # DMC 官方阎魔刀模型（user://anim_ef/weapon 自放）
var _grip_off := Vector3(0, -0.10, 0)  # 拳心相对 Tool_R pivot 的 bind 偏移
## DMC 官方武器缩放（RenderYamato.weaponScale 反编译=0.5：建模刀长
## 2.32m×0.5=1.16m，与自建刀 1.15 一致——DMC 建模比例放大一倍）
const DMC_WEAPON_SCALE := 0.5
## 骨骼矩阵数据纹理（20×3 RGBA32F；见 character_surface.gdshader）
var _bone_img: Image
var _bone_tex: ImageTexture
var _build_gen := 0      # build_model 代数（异步重定向防赛跑）

## EF/CMU 重定向全部就位（分帧装载完成；dock/测试等待用）。
signal clips_ready


func setup(player_node, world_node) -> void:
	player = player_node
	world = world_node
	_discover_packs()
	if pack_dirs.is_empty():
		push_warning("avatar: assets/characters 下无模型包")
		return
	_load_ef_raw()
	build_model(pack_dirs[pack_index])


## 扫描模型包目录（含 ysm.json 的子目录）。
func _discover_packs() -> void:
	pack_dirs = []
	var dir := DirAccess.open(PACK_ROOT)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and not name.begins_with("."):
			if FileAccess.file_exists("%s/%s/ysm.json" % [PACK_ROOT, name]):
				pack_dirs.append("%s/%s" % [PACK_ROOT, name])
		name = dir.get_next()
	pack_dirs.sort()


func _load_ef_raw() -> void:
	if _ef_loaded:
		return
	_ef_loaded = true
	var abs_path := ProjectSettings.globalize_path(EF_CLIP_DIR)
	_ef_raw = EfRef.load_dir(abs_path)
	if not _ef_raw.is_empty():
		print("avatar: EF 动画 %d 个（%s）" % [_ef_raw.size(), EF_CLIP_DIR])


## 装载/重建模型（rig + 蒙皮 + 动画重定向）。
func build_model(pack_dir: String) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	rig = {}
	skeleton = null
	mesh_instance = null
	var pack := YsmModel.load_pack(pack_dir)
	if pack.is_empty():
		push_error("avatar: 模型包解析失败 %s" % pack_dir)
		return
	rig = CharacterRig.build(pack)
	if rig.is_empty():
		push_error("avatar: rig 构建失败 %s" % pack_dir)
		return
	skeleton = CharacterRig.make_skeleton(rig)
	add_child(skeleton)
	mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = rig["mesh"]
	material = _make_material(String(rig["texture_path"]))
	mesh_instance.mesh.surface_set_material(0, material)
	# 蒙皮走自研 GPU 路径（着色器 u_bones 矩阵，见 character_surface）：
	# 引擎对运行时 ArrayMesh 的蒙皮（自动/显式 Skin）探针实测不生效
	skeleton.add_child(mesh_instance)
	# 动画集：内置程序化（同步，立即可用）+ EF/CMU 重定向（分帧异步，
	# 97 个 EF 曾同步卡主线程十几秒——游戏启动与编辑器 dock 同受其害；
	# 就位前状态机 has 检查自然回退程序化）
	clips = {}
	for key in ClipLib.builtin_clips():
		clips[key] = ClipLib.builtin_clips()[key]
	animator = Animator.new()
	animator.setup(rig, clips)
	animator.set_base("idle")
	_build_gen += 1
	_retarget_async(_build_gen)
	_build_weapon()
	_body_yaw = player.rotation.y if player != null else 0.0


## EF/CMU 重定向分帧（每 8 个让一帧）；gen 防连续重建赛跑。
func _retarget_async(gen: int) -> void:
	var n := 0
	for key in _ef_raw:
		if gen != _build_gen:
			return  # 已被新一次 build_model 取代
		clips["ef/" + key] = EfRef.retarget(_ef_raw[key], rig)
		n += 1
		if n % 8 == 0:
			await get_tree().process_frame
	_load_cmu_clips()
	clips_ready.emit()


func _make_material(tex_path: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	var shader := load("res://characters/character_surface.gdshader")
	mat.shader = shader
	if tex_path != "" and FileAccess.file_exists(tex_path):
		var img := Image.load_from_file(tex_path)
		if img != null:
			mat.set_shader_parameter("albedo_tex",
					ImageTexture.create_from_image(img))
	# 骨骼纹理（初始=绑定姿态矩阵链；每帧 _apply_pose 更新）
	# 曾初始全零：顶点塌原点——游戏首帧被 _apply_pose 即时覆盖未暴露，
	# 动作编辑器空队列时不采样即露馅（预览空白，用户实机"没法正常用"）
	var joints_n: int = EfRef.JOINTS.size()
	_bone_img = Image.create(joints_n, 3, false, Image.FORMAT_RGBAF)
	if not rig.is_empty():
		_seed_bind_pose()
	_bone_tex = ImageTexture.create_from_image(_bone_img)
	mat.set_shader_parameter("u_bone_tex", _bone_tex)
	mat.set_shader_parameter("u_day", _day_factor)
	return mat


## 骨骼纹理写入绑定姿态（pivot 链全局 × T(-pivot)），首帧前可见。
func _seed_bind_pose() -> void:
	var joints: Array = EfRef.JOINTS
	var parents: Array = EfRef.PARENTS
	var pivots: Array = rig["pivots"]
	var globals := []
	globals.resize(joints.size())
	for i in joints.size():
		var p: int = parents[i]
		if p < 0:
			globals[i] = Transform3D(Basis(), pivots[i])
		else:
			globals[i] = (globals[p] as Transform3D) \
					* Transform3D(Basis(), pivots[i] - pivots[p])
	for i in joints.size():
		var s: Transform3D = (globals[i] as Transform3D) \
				* Transform3D(Basis(), -pivots[i])
		_bone_img.set_pixel(i, 0, Color(s.basis.x.x, s.basis.x.y,
				s.basis.x.z, s.origin.x))
		_bone_img.set_pixel(i, 1, Color(s.basis.y.x, s.basis.y.y,
				s.basis.y.z, s.origin.y))
		_bone_img.set_pixel(i, 2, Color(s.basis.z.x, s.basis.z.y,
				s.basis.z.z, s.origin.z))


## F6：切换下一个模型包。
func cycle_model() -> void:
	if pack_dirs.size() < 2:
		return
	pack_index = (pack_index + 1) % pack_dirs.size()
	var keep_yaw := _body_yaw
	build_model(pack_dirs[pack_index])
	_body_yaw = keep_yaw


## 日夜系数（main 每帧下发，同树/地形通道）。
func set_day_factor(day: float) -> void:
	_day_factor = day
	if material != null:
		material.set_shader_parameter("u_day", day)


## 挖掘动作开关（挖掘进行中持续播放 dig）。
func set_mining(active: bool) -> void:
	if _mining == active:
		return
	_mining = active
	if not _mining:
		if animator != null and animator.action_active() \
				and animator.action_name() == "dig":
			animator.stop_action()


## CMU mocap 装载：res 内置精选（.txt=var_to_str Clip）+ 用户自放 BVH
##（运行时重定向，同 EF 自放模式；同名覆盖内置）。
func _load_cmu_clips() -> void:
	var loaded := 0
	var dir := DirAccess.open(CMU_DIR_RES)
	if dir != null:
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			if not dir.current_is_dir() and name.get_extension() == "txt":
				var parsed = str_to_var(FileAccess.get_file_as_string(
						"%s/%s" % [CMU_DIR_RES, name]))
				if parsed is Dictionary and parsed.has("tracks"):
					clips["cmu/" + name.get_basename()] = parsed
					loaded += 1
			name = dir.get_next()
	var user_dir := DirAccess.open(BVH_DIR_USER)
	if user_dir != null:
		var bvh := BvhLoader.load_dir(BVH_DIR_USER, rig)
		for key in bvh:
			clips["cmu/" + key] = bvh[key]
			loaded += 1
	if loaded > 0:
		print("avatar: CMU mocap 动作 %d 个" % loaded)


## 空手拳击连击（无目标可挖时的左键反馈；战斗阶段接命中判定）。
## 有 CMU mocap 版（box_combo）优先于程序化三连拳。
func play_punch() -> void:
	if animator != null:
		for builtin_name in ACTION_OVERRIDES:
			var ov: Dictionary = ACTION_OVERRIDES[builtin_name]
			if clips.has(ov["clip"]):
				animator.play_action(ov["clip"], 1.0, ov["mask"])
				return
		animator.play_action("punch", 1.0, "upper")


## ---- 拔刀战斗（EF yamato）----

## 武器三态：无（全隐，编辑器预览用）/ 收刀（鞘挂躯干）/ 拔刀（在手）。
enum WeaponMode { NONE, HOLSTERED, ARMED }
var _weapon_mode: int = WeaponMode.HOLSTERED  # 游戏默认腰挂鞘


## 拔刀/收刀（F7，armed↔holstered）。armed=持刀动作集（yamato 移动+
## 连击+闪避）。战斗系统下线时恒 unarmed（攻击回退徒手拳）。
func set_armed(value: bool) -> void:
	if not COMBAT_ENABLED:
		_armed = false
		_weapon_mode = WeaponMode.NONE
		return
	_weapon_mode = WeaponMode.ARMED if value else WeaponMode.HOLSTERED
	if _armed == value:
		return
	_armed = value
	_chain_reset()
	if not _armed and animator != null:
		animator.stop_action()  # 收刀中断挥砍


## 完整三态切换（dock 武器下拉：0 无 / 1 收刀 / 2 拔刀）。
func set_weapon_mode(m: int) -> void:
	if not COMBAT_ENABLED:
		return
	_weapon_mode = m
	set_armed(m == WeaponMode.ARMED)


func is_armed() -> bool:
	return _armed


## 攻击输入（左键）：拔刀=三段连击（提前按缓冲、45% 后可接段）；
## 徒手回退 play_punch。
func attack() -> void:
	if animator == null:
		return
	if not _armed or not clips.has(ATTACK_CHAIN[0]):
		play_punch()
		return
	if _dodge_lock > 0.0:
		return
	if not animator.action_active():
		_play_chain(0)
	else:
		_buffered = true  # 动作中：缓冲到取消点（update 轮询接段）


func _play_chain(idx: int) -> void:
	if idx >= ATTACK_CHAIN.size() or not clips.has(ATTACK_CHAIN[idx]):
		_buffered = false
		return
	# hard=权重直起 1：连击接段曾从 0 重新淡入——中段姿态 45% 弹回
	# idle（实机判读"接段跳变"），取消窗口的意义就是无缝续招
	animator.play_action(ATTACK_CHAIN[idx], 1.0, "all", Callable(), true)
	_chain_idx = idx
	_buffered = false


func _chain_reset() -> void:
	_chain_idx = -1
	_buffered = false


## 连击缓冲轮询（update_locomotion 每帧）：
## 攻击动作尾段（≥45%）缓冲命中 → 接下一段；动作结束后的缓冲 → 起手。
func _update_combo() -> void:
	if not _buffered or animator == null:
		return
	if not animator.action_active():
		_play_chain(0)
		return
	var act: String = animator.action_name()
	var idx := ATTACK_CHAIN.find(act)
	if idx >= 0 and idx < ATTACK_CHAIN.size() - 1 \
			and animator.action_progress() >= COMBO_CANCEL_AT:
		_play_chain(idx + 1)
	# 非 chain 动作（闪避中）缓冲保持到动作结束


## 闪避（双击方向键）：全身 dodge 动作 + 冲量脉冲（controller 取走）。
## 返回 true=触发成功。
func dodge(dir_name: String) -> bool:
	if animator == null or _dodge_lock > 0.0 or not _armed:
		return false
	var entry: Array = DODGE_CLIPS.get(dir_name, [])
	if entry.is_empty() or not clips.has(entry[0]):
		return false
	animator.play_action(entry[0], 1.0, "all")
	_dodge_lock = DODGE_LOCK
	_chain_reset()
	_dodge_impulse = entry[1] * DODGE_SPEED
	return true


## controller 每物理帧取走闪避冲量（局部→世界由调用方旋转）。
func take_dodge_impulse() -> Vector3:
	var v := _dodge_impulse
	_dodge_impulse = Vector3.ZERO
	return v


## ---- 太刀（自建 CC0 盒件组合；拔刀挂腕 / 收刀插鞘） ----

func _build_weapon() -> void:
	if not COMBAT_ENABLED:
		return  # 战斗下线：刀模型不构建（局内不可见；_weapon=null）
	_weapon = Node3D.new()
	_weapon.name = "Katana"
	add_child(_weapon)
	_weapon_dmc = false
	_compute_grip_offset()
	# DMC 官方阎魔刀优先（用户自放 user://anim_ef/weapon——EF 资产
	# All-Rights-Reserved 不入库，与动画同红线）；无则回退自建 CC0 盒件。
	var wdir := _dmc_weapon_dir()
	if wdir != "":
		var dmc: Dictionary = EfMesh.load_mesh(
				"%s/devil_sword_vergil_blade.json" % wdir, "Tool_R", true)
		if not dmc.is_empty():
			var mi := MeshInstance3D.new()
			mi.mesh = dmc["mesh"]
			mi.material_override = EfMesh.make_material(
					wdir, "devil_sword_vergil.png")
			mi.scale = Vector3.ONE * DMC_WEAPON_SCALE
			_weapon.add_child(mi)
			_weapon_dmc = true
	if not _weapon_dmc:
		# 局部：原点=握点，+Y 沿刀身向刀尖；全长 ~1.15m（yamato 长刀）
		_add_blade_box(Vector3(0.03, 0.28, 0.03), Vector3(0, -0.04, 0),
				Color(0.35, 0.08, 0.08))          # 柄 深红
		_add_blade_box(Vector3(0.10, 0.015, 0.05), Vector3(0, 0.245, 0),
				Color(0.75, 0.6, 0.2))            # 格挡 金
		_add_blade_box(Vector3(0.016, 0.86, 0.048), Vector3(0, 0.685, 0),
				Color(0.82, 0.85, 0.9))           # 刀身 银白
	_weapon.visible = true   # 恒可见：拔刀在手 / 收刀在鞘（DMC 模式收刀隐藏）
	_build_sheath()


## 拳心=rig 网格中 Tool_R 权重顶点均值（bind 系，相对 Tool_R pivot）。
## DMC 刀握点校准用（刀原点=EF Tool_R 腕点，实测拳心差 8px≈半拳高）。
func _compute_grip_offset() -> void:
	if not rig.has("mesh") or not rig.has("pivots"):
		return
	var joints: Array = rig["joints"]
	var jid: int = joints.find("Tool_R")
	if jid < 0:
		return
	var arrays: Array = (rig["mesh"] as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var acc := Vector3.ZERO
	var n := 0
	for v in verts.size():
		# COLOR 通道自研蒙皮：r=骨索引/255、g=权重
		if int(round(colors[v].r * 255.0)) == jid and colors[v].g > 0.5:
			acc += verts[v]
			n += 1
	if n > 0:
		_grip_off = (acc / float(n)) - (rig["pivots"] as Array)[jid]


## DMC 武器资产目录（user://anim_ef/weapon 存在 blade 模型才算就位）。
func _dmc_weapon_dir() -> String:
	var wdir := ProjectSettings.globalize_path("user://anim_ef/weapon")
	if FileAccess.file_exists("%s/devil_sword_vergil_blade.json" % wdir):
		return wdir
	return ""


## 刀鞘：自建 CC0 盒件（原点=鞘口、+Y 口外、-Y 向鞘底 0.9m）。
## ⚠ DMC on_torso（插鞘刀挂躯干）试挂已撤：其建模挂姿按 DMC 大比例
## 躯干参考（bind 局部偏移大），挂我们 0.7 缩放小躯干=肩背高度水平
## 悬空（实机截图判读）。拔刀后空鞘恒挂腰=真实佩戴观感。
func _build_sheath() -> void:
	if not COMBAT_ENABLED:
		return  # 战斗下线：鞘不构建（_sheath=null）
	_sheath = Node3D.new()
	_sheath.name = "Sheath"
	add_child(_sheath)
	var add := func(size: Vector3, pos: Vector3, albedo: Color,
			metallic: float) -> void:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = size
		mi.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = albedo
		mat.metallic = metallic
		mat.roughness = 0.55
		mat.emission_enabled = true
		mat.emission = albedo * Color(0.4, 0.4, 0.4)
		mat.emission_energy_multiplier = 0.25
		mi.material_override = mat
		mi.position = pos
		_sheath.add_child(mi)
	add.call(Vector3(0.055, 1.02, 0.055), Vector3(0, -0.51, 0),
			Color(0.08, 0.07, 0.09), 0.2)      # 鞘体 黑漆
	add.call(Vector3(0.075, 0.05, 0.075), Vector3(0, -0.02, 0),
			Color(0.72, 0.58, 0.2), 0.7)       # 鞘口 金环
	add.call(Vector3(0.062, 0.06, 0.062), Vector3(0, -1.02, 0),
			Color(0.72, 0.58, 0.2), 0.7)       # 鞘尾 金头


func _add_blade_box(size: Vector3, pos: Vector3, albedo: Color) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	mat.metallic = 0.6
	mat.roughness = 0.35
	mat.emission_enabled = true
	mat.emission = albedo * Color(0.5, 0.5, 0.5)  # 暗部微光防死黑
	mat.emission_energy_multiplier = 0.35
	mi.material_override = mat
	mi.position = pos
	_weapon.add_child(mi)


func is_dodging() -> bool:
	return _dodge_lock > DODGE_LOCK - 0.35  # 位移有效窗口（动作前段）


## 每物理帧：运动状态机 + 动画推进 + 姿态写骨架 + 光照采样。
func update_locomotion(velocity: Vector3, on_floor: bool,
		deep_water: bool, delta: float) -> void:
	if skeleton == null or animator == null or player == null:
		return
	var hspeed := Vector2(velocity.x, velocity.z).length()
	var moving_forward := true
	if hspeed > 0.5:
		var fwd: Vector3 = -player.global_transform.basis.z
		moving_forward = Vector2(velocity.x, velocity.z).dot(
				Vector2(fwd.x, fwd.z)) > -0.1
	# 状态选择（挖掘动作层独立于基础层）
	var state := "idle"
	var speed_scale := 1.0
	if deep_water:
		state = "swim"
		speed_scale = clampf(hspeed / 3.0, 0.6, 1.6)
	elif not on_floor:
		state = "fall"
	elif hspeed > 5.2:
		state = "run"
		speed_scale = clampf(hspeed / 8.0, 0.7, 1.4)
	elif hspeed > 0.4:
		state = "walk"
		speed_scale = clampf(hspeed / 4.5, 0.5, 1.5)
	if state != "swim" and _was_swim:
		pass  # 出水过渡由快照过渡自然衔接
	_was_swim = state == "swim"
	var use_ef := clips.has("ef/biped/living/" + state)
	var base_name: String = ("ef/biped/living/" + state) if use_ef else state
	# 拔刀：yamato 持刀姿态优先于程序化/EF 原版 living
	if _armed and not use_ef and EF_YAMATO_LIVING.has(state) \
			and clips.has(EF_YAMATO_LIVING[state]):
		base_name = EF_YAMATO_LIVING[state]
		if state == "walk":
			speed_scale = clampf(speed_scale * 0.75, 0.5, 1.0)  # 碎步慢放
	if animator.base_name() != base_name or absf(
			animator.base_speed() - speed_scale) > 0.05:
		animator.set_base(base_name, speed_scale, not moving_forward)
	# 连击缓冲轮询 + 闪避锁衰减
	_update_combo()
	if _dodge_lock > 0.0:
		_dodge_lock = maxf(_dodge_lock - delta, 0.0)
	# 挖掘动作层
	if _mining and not animator.action_active():
		animator.play_action("dig", 1.0, "upper")
	# 身体朝向滞后 + 头部注视
	if player != null:
		var target_yaw: float = player.rotation.y
		var dy := wrapf(target_yaw - _body_yaw, -PI, PI)
		_body_yaw += dy * minf(1.0, BODY_YAW_RATE * delta)
		rotation.y = wrapf(_body_yaw - player.rotation.y, -PI, PI)
		var head_yaw := clampf(wrapf(target_yaw - _body_yaw, -PI, PI),
				-HEAD_YAW_LIMIT, HEAD_YAW_LIMIT)
		# 头部俯仰=玩家俯仰角（四模式统一：低头→低头）。
		# 曾读 cam.rotation.x：模式 0/1/3 相机旋转恰为 (_pitch,0,0) 而正确，
		# 第二人称相机是 look_at 派生（自身俯仰）——低头时相机低位仰拍
		# rotation.x 为正 → 头反向抬起；俯仰过 ~7°（sinθ·3.6>0.45 胸口
		# 偏移过零）后越低越抬（用户实机 P1/P2 抓到）。
		var pitch_in = player.get("_pitch")
		var head_pitch: float = 0.0 if pitch_in == null else float(pitch_in)
		animator.set_head_look(-head_yaw, head_pitch)
	var pose: Dictionary = animator.update(delta)
	_apply_pose(pose)
	_light_accum += delta
	if _light_accum >= LIGHT_SAMPLE_INTERVAL:
		_light_accum = 0.0
		_sample_light()


## 姿态落地：写 Skeleton3D（调试可视）+ 计算全局皮肤矩阵下发着色器
## （u_bones[i] = 全局姿态 × T(-pivot_i)，网格顶点即绑定世界空间）。
func _apply_pose(pose: Dictionary) -> void:
	var joints: Array = rig["joints"]
	var parents: Array = rig["parents"]
	var pivots: Array = rig["pivots"]
	var globals := []
	globals.resize(joints.size())
	var skins := []
	skins.resize(joints.size())
	for i in joints.size():
		var entry: Dictionary = pose.get(joints[i], {})
		var local := Transform3D(
				Basis(entry.get("q", Quaternion())),
				entry.get("p", (rig["pivot_diffs"] as Array)[i]))
		var parent: int = parents[i]
		var g: Transform3D
		if parent >= 0:
			g = (globals[parent] as Transform3D) * local
		else:
			g = local
		globals[i] = g
		skins[i] = g * Transform3D(Basis(), -pivots[i])
		skeleton.set_bone_pose(i, local)
	# 骨骼矩阵 → 数据纹理（mat4[] 数组 uniform 多通道下被写坏，弃用）
	for i in skins.size():
		var s: Transform3D = skins[i]
		_bone_img.set_pixel(i, 0, Color(s.basis.x.x, s.basis.x.y,
				s.basis.x.z, s.origin.x))
		_bone_img.set_pixel(i, 1, Color(s.basis.y.x, s.basis.y.y,
				s.basis.y.z, s.origin.y))
		_bone_img.set_pixel(i, 2, Color(s.basis.z.x, s.basis.z.y,
				s.basis.z.z, s.origin.z))
	_bone_tex.update(_bone_img)
	# 太刀跟随右腕。DMC 官方模式：刀=Tool_R 局部原样（模型自带持刀
	# 几何，与 EF 渲染 M_ToolR·B⁻¹·v 同构——不加姿态补偿），收刀隐藏
	# （on_torso 鞘模型含刀）。回退自建模式：拳心握点+刀身垂直前臂
	# （Rx(-90°)，用户实机"武器应该垂直于手臂"），收刀插鞘。
	var tool_idx: int = (joints as Array).find("Tool_R")
	var torso_idx: int = (joints as Array).find("Torso")
	if _weapon != null:
		if _weapon_dmc:
			_weapon.visible = _weapon_mode == WeaponMode.ARMED
			if _armed:
				# 握点=实测拳心（rig 网格中 Tool_R 权重顶点均值，bind 时
				# 算一次缓存），每帧随腕骨基变换——纯沿前臂平移曾差 8px
				#（≈半拳高，前臂与刀身近同向、平移多沿刀身白费）。
				var g_tool: Transform3D = globals[tool_idx] as Transform3D
				_weapon.transform = Transform3D(g_tool.basis,
						g_tool.origin + g_tool.basis * _grip_off)
		else:
			_weapon.visible = _weapon_mode != WeaponMode.NONE
			if _armed:
				_weapon.transform = (globals[tool_idx] as Transform3D) * Transform3D(
						Basis(Vector3(1, 0, 0), deg_to_rad(-90.0)),
						Vector3(0, -0.10, 0))
			else:
				_weapon.transform = _sheath_in_hand_transform()
	# 刀鞘：自建=日式佩刀。鞘口挂左髋前侧（本引擎 -Z=角色前方——曾
	# z=+0.02 落在体侧轮廓）、鞘尾斜向左后下（tail_dir z 取正=朝后；
	# 曾 -0.85=朝前，正面机位误判后被 3/4 推理抓出）。from-to 四元数
	# 控制鞘轴（局部 -Y=鞘尾）。
	if _sheath != null:
		_sheath.visible = _weapon_mode != WeaponMode.NONE
		var tail_dir := Vector3(-0.12, -0.50, 0.90).normalized()
		_sheath.transform = (globals[torso_idx] as Transform3D) * Transform3D(
				Basis(Quaternion(Vector3(0, -1, 0), tail_dir)),
				Vector3(-0.22, 0.02, -0.10))


## 收刀态：刀插鞘（刀 +Y 刀尖翻转朝鞘底；握点悬鞘口上 ~0.25 露柄）。
func _sheath_in_hand_transform() -> Transform3D:
	return _sheath.transform * Transform3D(
			Basis(Vector3(1, 0, 0), PI), Vector3(0, 0.25, 0))


## 体素光照采样（玩家头顶格，语义对齐 main._update_exposure）。
func _sample_light() -> void:
	if world == null or player == null or material == null:
		return
	var cell := Vector3i(
			floori(player.global_position.x),
			floori(player.global_position.y + 0.5),
			floori(player.global_position.z))
	var chunk = world.get_chunk(VoxelCoords.world_to_chunk(
			cell, world.config.chunk_size))
	if chunk == null:
		return
	var local := VoxelCoords.world_to_local(cell, world.config.chunk_size)
	var s := float(chunk.get_sky_light(local)) / 15.0
	var b := float(chunk.get_block_light(local)) / 15.0
	material.set_shader_parameter("u_sky", s * s * s)
	material.set_shader_parameter("u_blk", b * b * b)
