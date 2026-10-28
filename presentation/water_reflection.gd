## 水面平面反射（真镜像相机）——从 main.gd 拆出的表现层节点
##（无 class_name，调用方 preload 绕全局类缓存，cave_fog 同款惯例）。
##
## 职责（单一）：镜像 SubViewport 的搭建与每帧同步——
## - 相机每帧同步到主相机关于海平面的镜像（数学镜像基，任意俯角
##   良定义；构造推导与踩坑史见 git 历史与 water_surface.gdshader 注释）；
## - 环境副本：关体积雾（倒影省一次雾积分）、天空 ground 色并到
##   horizon（镜像相机朝下视线直视天空下半球会污染远区倒影）；
## - RT 注入水材质、地形 RT 裁剪 uniform（镜像相机渲染时丢弃水下
##   片元，倒影只来自水面上方的世界）。
## 水面 shader 侧的采样补偿（1-uv.x 水平翻）与本节点共同构成完整
## 反射链路；两处必须同步改。
extends Node

## 反射平面世界高度 = 顶层水格 index + water_surface_height(0)。
## 由 setup 注入（调用方从公式单一来源计算，勿在此重复字面量）
var water_h := 0.0
var viewport: SubViewport
var mirror_cam: Camera3D

var _water_materials: Array = []
var _clip_materials: Array = []
var _last_clip_pos := Vector3(1.0e9, 1.0e9, 1.0e9)


## water_materials：接收 RT 的水材质（表面+侧壁）；clip_materials：
## 参与镜像渲染、需水下裁剪的地形材质（opaque+cutout）。
func setup(
		p_water_materials: Array,
		p_clip_materials: Array,
		environment: Environment,
		p_water_h: float
) -> void:
	water_h = p_water_h
	_water_materials = p_water_materials
	_clip_materials = p_clip_materials
	viewport = SubViewport.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# 排除 layer 2（水面 instance）；分辨率 0.6x 降载（倒影经波纹扰动
	# +低 fresnel，半分辨率感不明显）
	viewport.size = Vector2i(768, 432)
	add_child(viewport)
	# SubViewport 需自己的环境（环境光/天空背景）——环境 per-viewport。
	# 用副本并把天空 ground 色并到 horizon 色：镜像相机有朝下的视线
	#（对应远区水面的近水平反射），水下几何被 RT 裁剪后会直视天空
	# 下半球——物理上那里该是地平线色，原 ground 棕色会污染远区倒影
	if environment != null:
		var env := environment.duplicate() as Environment
		# 镜像 RT 不做体积雾：倒影省一次雾积分开销，且洞口光束
		# 在倒影里重复会显脏
		env.volumetric_fog_enabled = false
		if env.sky != null and env.sky.sky_material is ProceduralSkyMaterial:
			var sky := (env.sky.sky_material as ProceduralSkyMaterial).duplicate()
			sky.ground_bottom_color = sky.ground_horizon_color
			env.sky.sky_material = sky
		var we := WorldEnvironment.new()
		we.environment = env
		viewport.add_child(we)
	mirror_cam = Camera3D.new()
	mirror_cam.near = 0.2
	mirror_cam.far = 160.0
	# 水面 instance 挂 visibility layer 2（1<<1）：镜像相机排除之，
	# 双面水材质才不会铺满镜像画面挡住倒影
	mirror_cam.cull_mask = 0xFFFFF & ~(1 << 1)
	viewport.add_child(mirror_cam)
	var rt := viewport.get_texture()
	for mat in _water_materials:
		if mat == null:
			continue
		mat.set_shader_parameter("sspr_water_h", water_h)
		mat.set_shader_parameter("sspr_rt", rt)


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or mirror_cam == null:
		return
	var t := cam.global_transform
	var o := t.origin
	# 逐列 y 翻转的数学镜像基（=关于海平面的反射矩阵作用于相机），
	# x 列再取反补右手性（det -1→+1）——对任意俯角良定义。look_at 式
	# "up 正交化"构造在低头接近垂直时 up 与视线共线退化（NaN→渲染
	# 翻转），且一般俯角下点对应失准（已踩坑）。补偿：采样 1-uv.x
	var mx := Vector3(t.basis.x.x, -t.basis.x.y, t.basis.x.z)
	var my := Vector3(t.basis.y.x, -t.basis.y.y, t.basis.y.z)
	var mz := Vector3(t.basis.z.x, -t.basis.z.y, t.basis.z.z)
	mirror_cam.global_transform = Transform3D(
			Basis(-mx, my, mz), Vector3(o.x, 2.0 * water_h - o.y, o.z))
	mirror_cam.fov = cam.fov
	# 裁剪 uniform 脏检查（相机静止时值不变，每帧 4 次 uniform 重发
	# + SubViewport.size 重设是无谓开销）
	var mpos: Vector3 = mirror_cam.global_position
	if not mpos.is_equal_approx(_last_clip_pos):
		_last_clip_pos = mpos
		for mat in _clip_materials:
			if mat is ShaderMaterial:
				mat.set_shader_parameter("sspr_mirror_cam_pos", mpos)
				mat.set_shader_parameter("sspr_clip_y", water_h)
	# 视口尺寸跟随主视口（0.6x）
	var vs := get_viewport().get_visible_rect().size
	var target_size := Vector2i(
			maxi(int(vs.x * 0.6), 2), maxi(int(vs.y * 0.6), 2))
	if viewport.size != target_size:
		viewport.size = target_size
