## SSPR 屏幕空间平面反射（水面）。移植自 Godot-SSPR（MIT, AQ_Echoo 2025，
## github.com/AQ-Echoo/Godot-SSPR），适配本项目：
## - 7 个 compute shader 以 GLSL 源码内嵌、运行时编译（本项目禁 --import，
##   .glsl 资源文件的 import 缓存无法生成）
## - 纹理尺寸跟随 RenderSceneBuffers 内部分辨率（支持窗口缩放/渲染缩放，
##   原版只在初始化取一次窗口大小）
## - 修复原版 bug：tex_copy_pipeline 误用 gaussian blur shader 创建
## - 管线：scatter（深度→平面镜像坐标 hash 编码）→ resolve（解码采样
##   反射色+邻域补洞）→ temporal（TAA 时域累积补洞）→ blur（Dual
##   Kawase / Gaussian）。结果经 global uniform SSPR_Reflection（RGBA8，
##   alpha=有效性）供水面 shader 采样。仅 Forward+（CompositorEffect 依赖
##   RenderingDevice compute），gl_compatibility 下由 main 检测后不挂载。
##
## 【当前未挂载】4.7 下 global uniform + Texture2DRD 无法送达材质：材质
## 绑定时经 Variant→get_rid() 取 RS wrapper，早于 wrapper 创建的绑定解析
## 成占位黑纹且不自动重解析（主线程/渲染线程 set 均试过，含每帧重 set）。
## 水面反射改用镜像投影 + 屏幕纹理采样（water_surface.gdshader 的
## sspr_mirror_vp，main._update_water_reflection 每帧下发），零 compute、
## 可反射天空、gl_compatibility 可用。本文件保留供任意平面反射/真 SSR
## 复用；本文件的逐级调试转储（debug_dump）曾用于定位 4.7 的 push
## 常量严格校验（std430 vec2+float=12 字节，多传 16 字节会静默拒发
## dispatch）与上述 wrapper 绑定问题。
extends CompositorEffect

## 反射平面高度（世界 y）。v1 用海平面主水面；高处流动水不参与（材质端
## 按高度差渐隐采样）。
@export var water_h : float = 0.0
@export_group("TAA")
@export var taa_enable : bool = true
## 越小越依赖历史帧（反射更稳），越大越依赖当前帧（拖影少）
@export var temporal_blend : float = 0.06
@export var neighbor_clamp_radius : int = 1
@export_group("Blur")
@export var blur_enable : bool = true
## 0 = Dual Kawase（大模糊快），1 = Gaussian（细模糊）
@export var blur_mode : int = 0
@export var blur_radius : float = 0.5
@export var blur_iteration : int = 2
@export var blur_downscaling : int = 2
@export var blur_strength : float = 1.0


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	# 输出纹理壳须在主线程创建：global uniform 的 set 只在主线程生效
	# （渲染线程回调里 set 会被静默丢弃），rid 由首帧回调赋值
	texture2drd = Texture2DRD.new()
	RenderingServer.call_on_render_thread(_register_compute_shaders)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if rd == null:
			return
		for rid: RID in [sspr_scatter_shader, sspr_resolve_shader,
				sspr_temporal_shader, sspr_blur_shader, sspr_blur_down_shader,
				sspr_blur_up_shader, tex_copy_shader, tex_copy_pipeline]:
			if rid.is_valid():
				rd.free_rid(rid)
		_free_texture_group()
		if view_proj_mat_buffer.is_valid():
			rd.free_rid(view_proj_mat_buffer)
		for level: Level in pyramid:
			_free_rt(level.down_rid)
			_free_rt(level.up_rid)


# ---- 渲染线程侧状态 ----
var rd: RenderingDevice

var nearest_sampler: RID
var linear_sampler: RID
var frame_index: int = 0

var sspr_scatter_shader: RID
var sspr_scatter_pipeline: RID
var sspr_resolve_shader: RID
var sspr_resolve_pipeline: RID
var sspr_temporal_shader: RID
var sspr_temporal_pipeline: RID
var sspr_blur_shader: RID
var sspr_blur_pipeline: RID
var sspr_blur_down_shader: RID
var sspr_blur_down_pipeline: RID
var sspr_blur_up_shader: RID
var sspr_blur_up_pipeline: RID
var tex_copy_shader: RID
var tex_copy_pipeline: RID

## 本帧编码 hash（r32ui：高 16bit 源 Y / 低 16bit 源 X）
var tex_current_hash: RID
## 解码后未模糊的反射色
var tex_current_resolve: RID
## 上帧历史（temporal 采样）
var tex_history: RID
var tex_temporal: RID
var tex_blurred_rt1: RID
var tex_blurred_rt2: RID
var tex_current_display: RID

var view_proj_mat_buffer: RID
var tex_size: Vector2i = Vector2i.ZERO

var texture2drd: Texture2DRD
var mat_ssbo: PackedFloat32Array = PackedFloat32Array()
var prev_view_proj: Projection
var _shaders_ready := false

# Dual Kawase 金字塔
const MAX_PYRAMID_SIZE: int = 16
var _current_iteration: int = -1
var _current_tex_size: Vector2i = Vector2i(-1, -1)
var _pyramid_inited: bool = false


class Level:
	var down_rid: RID = RID()
	var up_rid: RID = RID()
	var size: Vector2i = Vector2i(0, 0)


var pyramid: Array[Level] = []


# ---- uniform 工具 ----
func create_ssbo_uniform(buffer: RID, binding: int) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func get_image_uniform(image: RID, binding: int = 0) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(image)
	return uniform


func get_sampler_uniform(image: RID, binding: int = 0, linear: bool = true) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	if linear:
		uniform.add_id(linear_sampler)
	else:
		uniform.add_id(nearest_sampler)
	uniform.add_id(image)
	return uniform


# ---- Halton 抖动（手动 TAA 用） ----
func radical_inverse(base: int, i: int) -> float:
	var result: float = 0.0
	var f: float = 1.0 / float(base)
	while i > 0:
		result += f * float(i % base)
		f /= float(base)
		@warning_ignore("integer_division")
		i /= base
	return result


func get_halton_jitter(frame_index_in: int) -> Vector2:
	var i := frame_index_in % 8
	var x := radical_inverse(2, i) - 0.5
	var y := radical_inverse(3, i) - 0.5
	return Vector2(x, y) * 2.0 * 0.5


func apply_jitter_to_proj(original_proj: Projection, jitter_pixels: Vector2) -> Array:
	var jitter_clip := Vector2(jitter_pixels.x / tex_size.x, jitter_pixels.y / tex_size.y)
	var jittered := original_proj
	jittered[2][0] += jitter_clip.x
	jittered[2][1] += jitter_clip.y
	return [jittered, jitter_clip]


func validate_pipelines() -> bool:
	return sspr_scatter_pipeline.is_valid() \
			and sspr_resolve_pipeline.is_valid() \
			and sspr_temporal_pipeline.is_valid()


# ---- shader 编译与资源创建（渲染线程） ----
var _shader_by_source: Dictionary = {}


## 编译 GLSL 源码 → [pipeline RID, shader RID]；shader RID 供
## UniformSetCacheRD 作缓存键与手动释放
func _compile_pipeline_full(source: String) -> Array:
	var src := RDShaderSource.new()
	# #[compute] 标记仅 .glsl 资源整文件解析时合法；stage 专用源码需剥掉
	src.source_compute = source.replace("#[compute]\n", "")
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(src)
	var compile_err: String = spirv.get_stage_compile_error(
			RenderingDevice.SHADER_STAGE_COMPUTE)
	if compile_err != "":
		push_error("SSPR shader 编译失败: " + compile_err)
		return [RID(), RID()]
	var shader := rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		return [RID(), RID()]
	var pipeline := rd.compute_pipeline_create(shader)
	_shader_by_source[source] = shader
	return [pipeline, shader]


func _register_compute_shaders() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		push_warning("RenderingDevice 不可用（gl_compatibility？），SSPR 不生效")
		return

	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	nearest_sampler = rd.sampler_create(sampler_state)
	sampler_state = RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_sampler = rd.sampler_create(sampler_state)

	var compiled := _compile_pipeline_full(GLSL_SCATTER)
	sspr_scatter_pipeline = compiled[0]
	sspr_scatter_shader = compiled[1]
	compiled = _compile_pipeline_full(GLSL_RESOLVE)
	sspr_resolve_pipeline = compiled[0]
	sspr_resolve_shader = compiled[1]
	compiled = _compile_pipeline_full(GLSL_TEMPORAL)
	sspr_temporal_pipeline = compiled[0]
	sspr_temporal_shader = compiled[1]
	compiled = _compile_pipeline_full(GLSL_GAUSSIAN)
	sspr_blur_pipeline = compiled[0]
	sspr_blur_shader = compiled[1]
	compiled = _compile_pipeline_full(GLSL_DOWNSCALE)
	sspr_blur_down_pipeline = compiled[0]
	sspr_blur_down_shader = compiled[1]
	compiled = _compile_pipeline_full(GLSL_UPSCALE)
	sspr_blur_up_pipeline = compiled[0]
	sspr_blur_up_shader = compiled[1]
	compiled = _compile_pipeline_full(GLSL_COPY)
	tex_copy_pipeline = compiled[0]
	tex_copy_shader = compiled[1]

	if not validate_pipelines():
		push_warning("SSPR 管线创建失败，反射不生效")
		return

	# 金字塔层级（延迟建纹理）
	pyramid = []
	for i in MAX_PYRAMID_SIZE:
		pyramid.append(Level.new())

	# 矩阵 SSBO：3 个 mat4
	var mat_bytes := PackedByteArray()
	mat_bytes.resize(192)
	mat_bytes.fill(0)
	view_proj_mat_buffer = rd.storage_buffer_create(mat_bytes.size(), mat_bytes)
	_shaders_ready = true


# ---- 纹理组按内部尺寸（重）建 ----
func _free_texture_group() -> void:
	if rd == null:
		return
	for rid: RID in [tex_current_hash, tex_current_resolve, tex_history,
			tex_temporal, tex_blurred_rt1, tex_blurred_rt2]:
		if rid.is_valid():
			rd.free_rid(rid)
	tex_current_hash = RID()
	tex_current_resolve = RID()
	tex_history = RID()
	tex_temporal = RID()
	tex_blurred_rt1 = RID()
	tex_blurred_rt2 = RID()
	tex_current_display = RID()
	_pyramid_inited = false


func _ensure_textures(size: Vector2i) -> void:
	if size == tex_size and tex_current_resolve.is_valid():
		return
	_free_texture_group()
	tex_size = size

	# hash 图：r32ui 原子写（CPU_READ/COPY_FROM 供调试转储）
	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R32_UINT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.width = tex_size.x
	tf.height = tex_size.y
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_ATOMIC_BIT \
			| RenderingDevice.TEXTURE_USAGE_CPU_READ_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	tex_current_hash = rd.texture_create(tf, RDTextureView.new(), [])

	# 反射色/历史/temporal：rgba8
	var cf := RDTextureFormat.new()
	cf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	cf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	cf.width = tex_size.x
	cf.height = tex_size.y
	cf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CPU_READ_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	tex_current_resolve = rd.texture_create(cf, RDTextureView.new(), [])
	tex_history = rd.texture_create(cf, RDTextureView.new(), [])
	tex_temporal = rd.texture_create(cf, RDTextureView.new(), [])
	tex_blurred_rt1 = _create_rt(tex_size)
	tex_blurred_rt2 = _create_rt(tex_size)


func _create_rt(rt_size: Vector2i) -> RID:
	if rt_size.x <= 0 or rt_size.y <= 0:
		return RID()
	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.width = rt_size.x
	tf.height = rt_size.y
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CPU_READ_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return rd.texture_create(tf, RDTextureView.new(), [])


func _free_rt(rid: RID) -> void:
	if rid.is_valid():
		rd.free_rid(rid)


# ---- 每帧回调 ----
## 调试转储：主线程置 debug_dump=true，下一帧渲染回调转储 hash/resolve/
## final 三级中间纹理（user://sspr_debug）并打印统计，用于定位 alpha 断链
var debug_dump := false
const DEBUG_DUMP_DIR := "user://sspr_debug"


func _render_callback(p_effect_callback_type: int, p_render_data: RenderData) -> void:
	if rd == null or not _shaders_ready \
			or p_effect_callback_type != CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT \
			or not validate_pipelines():
		return
	var render_scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
	var render_scene_data: RenderSceneDataRD = p_render_data.get_render_scene_data()
	if render_scene_buffers == null or render_scene_data == null:
		return

	_ensure_textures(render_scene_buffers.get_internal_size())

	mat_ssbo.clear()
	rd.texture_clear(tex_current_hash, Color(0, 0, 0, 0), 0, 1, 0, 1)

	var color_image: RID = render_scene_buffers.get_texture("render_buffers", "color")
	var depth_image: RID = render_scene_buffers.get_texture("render_buffers", "depth")
	var projection: Projection = render_scene_data.get_cam_projection()

	var jitter_pixels := get_halton_jitter(frame_index)
	var jitter_array: Array = apply_jitter_to_proj(projection, jitter_pixels)
	var jittered_proj: Projection = jitter_array[0]
	var view_matrix: Transform3D = render_scene_data.get_cam_transform().inverse()
	var cam_view := Projection(Transform3D(view_matrix.basis, view_matrix.origin))
	var cur_view_proj := jittered_proj * cam_view
	if prev_view_proj == Projection():
		prev_view_proj = cur_view_proj

	# SSBO：jittered VP、其逆、上帧 VP（重投影）
	for i in 4:
		for j in 4:
			mat_ssbo.push_back(cur_view_proj[i][j])
	var inv_vp := cur_view_proj.inverse()
	for i in 4:
		for j in 4:
			mat_ssbo.push_back(inv_vp[i][j])
	for i in 4:
		for j in 4:
			mat_ssbo.push_back(prev_view_proj[i][j])
	var mat_bytes := mat_ssbo.to_byte_array()
	rd.buffer_update(view_proj_mat_buffer, 0, mat_bytes.size(), mat_bytes)

	# 1. 散射：深度 → 镜像坐标 hash
	var push := PackedFloat32Array([water_h, 0.0, 0.0, 0.0])
	var push_bytes := push.to_byte_array()
	var uniforms := [
		get_sampler_uniform(depth_image, 0, false),
		get_image_uniform(tex_current_hash, 1),
		create_ssbo_uniform(view_proj_mat_buffer, 2)]
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, sspr_scatter_pipeline)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(
			sspr_scatter_shader, 0, uniforms), 0)
	rd.compute_list_dispatch(cl, ceili(tex_size.x / 16.0), ceili(tex_size.y / 16.0), 1)
	rd.compute_list_end()

	# 2. 解码：hash → 反射色（邻域补洞 + 边缘淡出）
	uniforms = [
		get_sampler_uniform(color_image, 0, false),
		get_image_uniform(tex_current_hash, 1),
		get_image_uniform(tex_current_resolve, 2)]
	cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, sspr_resolve_pipeline)
	rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(
			sspr_resolve_shader, 0, uniforms), 0)
	rd.compute_list_dispatch(cl, ceili(tex_size.x / 16.0), ceili(tex_size.y / 16.0), 1)
	rd.compute_list_end()

	# 3. TAA 时域累积
	var taa_push := PackedFloat32Array([
		temporal_blend, float(neighbor_clamp_radius),
		jitter_array[1].x, jitter_array[1].y])
	uniforms = [
		get_sampler_uniform(tex_current_resolve, 0),
		get_sampler_uniform(tex_history, 1),
		get_sampler_uniform(depth_image, 2, false),
		create_ssbo_uniform(view_proj_mat_buffer, 3),
		get_image_uniform(tex_temporal, 4)]
	cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, sspr_temporal_pipeline)
	rd.compute_list_set_push_constant(cl, taa_push.to_byte_array(), taa_push.size() * 4)
	rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(
			sspr_temporal_shader, 0, uniforms), 0)
	rd.compute_list_dispatch(cl, ceili(tex_size.x / 16.0), ceili(tex_size.y / 16.0), 1)
	rd.compute_list_end()

	tex_current_display = tex_temporal if taa_enable else tex_current_resolve

	# 4. 模糊
	if blur_enable:
		_run_blur(tex_current_display, tex_blurred_rt2)
		tex_current_display = tex_blurred_rt2
		tex_history = tex_blurred_rt2
	else:
		tex_history = tex_temporal

	if texture2drd.texture_rd_rid != tex_current_display:
		texture2drd.texture_rd_rid = tex_current_display
	# 注意：global uniform 的绑定在 main._setup_sspr（主线程）一次性完成；
	# 渲染线程回调里 global_shader_parameter_set 不生效（会被丢弃）

	if debug_dump:
		_dump_debug()
		debug_dump = false

	prev_view_proj = cur_view_proj
	frame_index += 1


func _dump_debug() -> void:
	var dir := DirAccess.open("user://")
	if not dir.dir_exists("sspr_debug"):
		dir.make_dir("sspr_debug")
	# hash（r32ui 原始字节）：非零像素占比 = 散射命中
	var hash_bytes := rd.texture_get_data(tex_current_hash, 0)
	var nonzero := 0
	var total := 0
	var i := 0
	while i + 3 < hash_bytes.size():
		total += 1
		if hash_bytes[i] != 0 or hash_bytes[i + 1] != 0 \
				or hash_bytes[i + 2] != 0 or hash_bytes[i + 3] != 0:
			nonzero += 1
		i += 4 * 8  # 8 像素步进采样
	print("DUMP hash 非零占比≈%.1f%% (%d/%d)" % [
			100.0 * nonzero / maxi(total, 1), nonzero, total])
	var fa := FileAccess.open(DEBUG_DUMP_DIR + "/hash.raw", FileAccess.WRITE)
	if fa != null:
		fa.store_buffer(hash_bytes)
		fa.close()
	# resolve / final（RGBA8）→ PNG + alpha/RGB 统计
	for trio in [["resolve", tex_current_resolve, tex_size],
			["temporal", tex_temporal, tex_size],
			["lv0down", pyramid[0].down_rid, pyramid[0].size],
			["lv1down", pyramid[1].down_rid, pyramid[1].size],
			["lv0up", pyramid[0].up_rid, pyramid[0].size],
			["final", tex_current_display, tex_size]]:
		var name_s: String = trio[0]
		var rid: RID = trio[1]
		var tsize: Vector2i = trio[2]
		if not rid.is_valid() or tsize.x <= 0:
			continue
		var bytes := rd.texture_get_data(rid, 0)
		var img := Image.create_from_data(
				tsize.x, tsize.y, false, Image.FORMAT_RGBA8, bytes)
		var alpha_sum := 0.0
		var a_nonzero := 0
		var n := 0
		for y in range(0, tsize.y, 8):
			for x in range(0, tsize.x, 8):
				var a: float = img.get_pixel(x, y).a8 / 255.0
				alpha_sum += a
				if a > 0.05:
					a_nonzero += 1
				n += 1
		img.save_png(DEBUG_DUMP_DIR + "/%s.png" % name_s)
		print("DUMP %s alpha均值=%.3f alpha>0.05占比=%.1f%% (%d/%d)" % [
				name_s, alpha_sum / maxi(n, 1), 100.0 * a_nonzero / maxi(n, 1),
				a_nonzero, n])


# ---- 模糊（Gaussian / Dual Kawase） ----
func _run_blur(source: RID, dest: RID) -> void:
	if blur_mode == 1:
		_run_gaussian_blur(source)
		_copy_texture_via_compute(tex_blurred_rt2, dest, tex_size)
	else:
		_run_dual_kawase(source, dest)


func _copy_texture_via_compute(src_rid: RID, dst_rid: RID, dst_size: Vector2i) -> void:
	if not src_rid.is_valid() or not dst_rid.is_valid() or not tex_copy_pipeline.is_valid():
		return
	# COPY shader 无 push 常量块：多设会因尺寸不匹配被 RD 拒发（4.7 严格校验）
	var uniforms := [get_sampler_uniform(src_rid, 0), get_image_uniform(dst_rid, 1)]
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, tex_copy_pipeline)
	rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(
			tex_copy_shader, 0, uniforms), 0)
	rd.compute_list_dispatch(cl, ceili(dst_size.x / 16.0), ceili(dst_size.y / 16.0), 1)
	rd.compute_list_end()


func _run_gaussian_blur(source: RID) -> void:
	_copy_texture_via_compute(source, tex_blurred_rt1, tex_size)
	for pass_i in 2:
		var uniforms := [
			get_sampler_uniform(tex_blurred_rt1, 0),
			get_image_uniform(tex_blurred_rt2, 1)]
		# std430 int+float+float = 12 字节（勿补第 4 个 float，4.7 按块尺寸严格校验）
		var push := PackedFloat32Array([
			float(pass_i), blur_radius, blur_strength])
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, sspr_blur_pipeline)
		rd.compute_list_set_push_constant(cl, push.to_byte_array(), push.size() * 4)
		rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(
				sspr_blur_shader, 0, uniforms), 0)
		rd.compute_list_dispatch(cl, ceili(tex_size.x / 16.0), ceili(tex_size.y / 16.0), 1)
		rd.compute_list_end()
		_copy_texture_via_compute(tex_blurred_rt2, tex_blurred_rt1, tex_size)


func _lazy_init_pyramid() -> void:
	if blur_iteration == _current_iteration and tex_size == _current_tex_size \
			and _pyramid_inited:
		return
	for level in pyramid:
		_free_rt(level.down_rid)
		_free_rt(level.up_rid)
		level.down_rid = RID()
		level.up_rid = RID()
		level.size = Vector2i(0, 0)
	_current_iteration = blur_iteration
	_current_tex_size = tex_size
	_pyramid_inited = true
	var current_size := tex_size
	for i in blur_iteration:
		pyramid[i].size = current_size
		pyramid[i].down_rid = _create_rt(current_size)
		pyramid[i].up_rid = _create_rt(current_size)
		current_size = Vector2i(
				maxi(int(current_size.x / blur_downscaling), 1),
				maxi(int(current_size.y / blur_downscaling), 1))


func _run_dual_kawase(source: RID, dest: RID) -> void:
	_lazy_init_pyramid()
	# 下采样链
	var last_down: RID = source
	for i in blur_iteration:
		var level: Level = pyramid[i]
		if not level.down_rid.is_valid():
			continue
		var uniforms := [
			get_sampler_uniform(last_down, 0),
			get_image_uniform(level.down_rid, 1)]
		# std430 vec2+float = 12 字节（勿补第 4 个 float，4.7 按块尺寸严格校验）
		var push := PackedFloat32Array([
			float(level.size.x), float(level.size.y), blur_radius])
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, sspr_blur_down_pipeline)
		rd.compute_list_set_push_constant(cl, push.to_byte_array(), push.size() * 4)
		rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(
				sspr_blur_down_shader, 0, uniforms), 0)
		rd.compute_list_dispatch(cl, ceili(level.size.x / 16.0), ceili(level.size.y / 16.0), 1)
		rd.compute_list_end()
		last_down = level.down_rid
	# 上采样链
	if blur_iteration <= 1:
		_copy_texture_via_compute(last_down, dest, tex_size)
		return
	var last_up: RID = pyramid[blur_iteration - 1].down_rid
	for i in range(blur_iteration - 2, -1, -1):
		var level: Level = pyramid[i]
		if not level.up_rid.is_valid():
			continue
		var uniforms := [
			get_sampler_uniform(last_up, 0),
			get_image_uniform(level.up_rid, 1)]
		var push := PackedFloat32Array([
			float(level.size.x), float(level.size.y), blur_radius])
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, sspr_blur_up_pipeline)
		rd.compute_list_set_push_constant(cl, push.to_byte_array(), push.size() * 4)
		rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(
				sspr_blur_up_shader, 0, uniforms), 0)
		rd.compute_list_dispatch(cl, ceili(level.size.x / 16.0), ceili(level.size.y / 16.0), 1)
		rd.compute_list_end()
		last_up = level.up_rid
	_copy_texture_via_compute(last_up, dest, tex_size)


# ============================================================================
# GLSL 源码（照抄 Godot-SSPR，MIT）
# ============================================================================

const GLSL_SCATTER := """
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_tex;
layout(r32ui, set = 0, binding = 1) uniform restrict uimage2D dest_hash_map;

layout(set = 0, binding = 2, std430) readonly buffer ViewProjMatBuffer {
    mat4 view_proj_mat;
    mat4 inv_view_proj_mat;
    mat4 prev_view_proj_mat;
} mat_buffer;

layout(push_constant, std430) uniform Push {
    vec4 water_height;
} pc;

vec3 reconstruct_world_pos(vec2 uv, float depth) {
    vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 world_pos = mat_buffer.inv_view_proj_mat * clip_pos;
    return world_pos.xyz / world_pos.w;
}

void main() {
    ivec2 size = imageSize(dest_hash_map);
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    if (id.x >= size.x || id.y >= size.y) {
        return;
    }
    vec2 uv = vec2(id) / vec2(size);

    float depth = texture(depth_tex, uv).r;
    if (depth <= 0.0001 || depth >= 0.97) return;

    vec3 world_pos = reconstruct_world_pos(uv, depth);

    float water_height = pc.water_height.x;
    if (world_pos.y < water_height) {
        return;
    }
    vec3 reflected_world_pos = world_pos;
    reflected_world_pos.y = 2.0 * water_height - world_pos.y;

    vec4 reflected_clip = mat_buffer.view_proj_mat * vec4(reflected_world_pos, 1.0);
    vec3 reflected_ndc = reflected_clip.xyz / reflected_clip.w;
    vec2 reflected_uv = reflected_ndc.xy * 0.5 + 0.5;

    if (reflected_uv.x < -0.001 || reflected_uv.x > 1.001
            || reflected_uv.y < -0.001 || reflected_uv.y > 1.001) {
        return;
    }

    ivec2 target_pixel = ivec2(reflected_uv * size);
    uint packed_coord = (uint(id.y) << 16) | (uint(id.x) & 0xFFFF);
    imageAtomicMax(dest_hash_map, target_pixel, packed_coord);
}
"""

const GLSL_RESOLVE := """
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(r32ui, set = 0, binding = 1) uniform restrict readonly uimage2D source_hash_map;
layout(rgba8, set = 0, binding = 2) uniform restrict image2D dest_reflection;

void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    vec2 size = imageSize(dest_reflection);

    if (id.x >= int(size.x) || id.y >= int(size.y)) return;

    uint best_packed = 0u;
    ivec2 offsets[9] = ivec2[](ivec2(0,0), ivec2(1,0), ivec2(-1,0), ivec2(0,1),
            ivec2(0,-1), ivec2(1,1), ivec2(-1,1), ivec2(1,-1), ivec2(-1,-1));

    for(int i=0; i<9; i++) {
        ivec2 sample_pos = id + offsets[i];
        if(sample_pos.x < 0 || sample_pos.y < 0
                || sample_pos.x >= int(size.x) || sample_pos.y >= int(size.y)) continue;
        uint val = imageLoad(source_hash_map, sample_pos).r;
        if (val != 0u) {
            best_packed = val;
            break;
        }
    }

    vec4 result_color = vec4(0.0);

    if (best_packed != 0u) {
        uint src_y = best_packed >> 16;
        uint src_x = best_packed & 0xFFFF;
        vec2 src_uv = (vec2(src_x, src_y) + 0.5) / size;

        result_color = texture(source_color, src_uv);

        float fade_x = smoothstep(0.0, 0.1, src_uv.x) * (1.0 - smoothstep(0.9, 1.0, src_uv.x));
        float fade_y = smoothstep(0.0, 0.1, src_uv.y) * (1.0 - smoothstep(0.9, 1.0, src_uv.y));
        result_color.a *= fade_y * fade_x;
    }

    imageStore(dest_reflection, id, result_color);
}
"""

const GLSL_TEMPORAL := """
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D current;
layout(set = 0, binding = 1) uniform sampler2D history;
layout(set = 0, binding = 2) uniform sampler2D depth_tex;

layout(set = 0, binding = 3, std430) readonly buffer ViewProjMatBuffer {
    mat4 view_proj_mat;
    mat4 inv_view_proj_mat;
    mat4 prev_view_proj_mat;
} data_buffer;

layout(set = 0, binding = 4, rgba8) uniform image2D result;

layout(push_constant, std430) uniform Push {
    float blend;
    float neighbor_clamp_radius;
    float jitter_current_x;
    float jitter_current_y;
} pc;

#define UV_RAW ((gl_GlobalInvocationID.xy) / vec2(imageSize(result)))
#define PIXEL_SIZE (1.0 / vec2(imageSize(result)))
#define UV (UV_RAW - vec2(pc.jitter_current_x, pc.jitter_current_y))

vec3 ndc_to_world(vec2 uv, float depth) {
    vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 world = data_buffer.inv_view_proj_mat * ndc;
    return world.xyz / world.w;
}

vec2 world_to_prev_uv(vec3 world_pos) {
    vec4 prev_clip = data_buffer.prev_view_proj_mat * vec4(world_pos, 1.0);
    vec2 prev_ndc = prev_clip.xy / prev_clip.w;
    return (prev_ndc + 1.0) * 0.5;
}

vec4 neighbor_clamp(vec4 history_color, vec2 uv) {
    vec2 offsets[] = vec2[](
        vec2(0, 0),
        vec2(-pc.neighbor_clamp_radius, 0),
        vec2(pc.neighbor_clamp_radius, 0),
        vec2(0, -pc.neighbor_clamp_radius),
        vec2(0, pc.neighbor_clamp_radius)
    );

    vec4 min_color = vec4(1e3);
    vec4 max_color = vec4(-1e3);
    for (int i = 0; i < 5; i++) {
        vec2 sample_uv = uv + offsets[i] * PIXEL_SIZE;
        vec4 sample_color = texture(current, sample_uv);
        min_color = min(min_color, sample_color);
        max_color = max(max_color, sample_color);
    }
    return clamp(history_color, min_color, max_color);
}

void main() {
    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);
    if (coords.x >= imageSize(result).x || coords.y >= imageSize(result).y) {
        imageStore(result, coords, vec4(0, 0, 0, 1));
        return;
    }

    vec4 current_color = texture(current, UV);
    float depth = texture(depth_tex, UV).r;

    vec3 world_pos = ndc_to_world(UV, depth);
    vec2 prev_uv = world_to_prev_uv(world_pos);

    vec4 history_color = current_color;
    if (prev_uv.x >= 0.0 && prev_uv.x <= 1.0
            && prev_uv.y >= 0.0 && prev_uv.y <= 1.0) {
        history_color = texture(history, prev_uv);
    }

    vec4 clamped_history = neighbor_clamp(history_color, UV);
    vec4 final_color = mix(clamped_history, current_color, pc.blend);

    imageStore(result, coords, final_color);
}
"""

const GLSL_GAUSSIAN := """
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 0, binding = 1, rgba8) uniform image2D dest;

layout(push_constant, std430) uniform Push {
    int blur_pass;
    float blur_radius;
    float blur_strength;
} pc;

const float gauss_weights[5] = float[](
    0.2270270270,
    0.1945945946,
    0.1216216216,
    0.0540540541,
    0.0162162162
);

vec4 safe_sample(sampler2D tex, vec2 uv, vec2 offset) {
    vec2 tex_size = vec2(textureSize(tex, 0));
    vec2 sample_uv = uv + offset / tex_size;
    sample_uv = clamp(sample_uv, vec2(0.0), vec2(1.0));
    return texture(tex, sample_uv);
}

void main() {
    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);
    vec2 uv = vec2(coords) / vec2(imageSize(dest));

    if (coords.x >= imageSize(dest).x || coords.y >= imageSize(dest).y) {
        imageStore(dest, coords, vec4(0.0));
        return;
    }

    vec2 blur_dir = pc.blur_pass == 0 ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    float radius = pc.blur_radius * pc.blur_strength;

    vec4 color = safe_sample(src, uv, vec2(0.0)) * gauss_weights[0];
    float total_weight = gauss_weights[0];

    for (int i = 1; i < 5; i++) {
        float offset = float(i) * radius;
        color += safe_sample(src, uv, blur_dir * offset) * gauss_weights[i];
        color += safe_sample(src, uv, -blur_dir * offset) * gauss_weights[i];
        total_weight += 2.0 * gauss_weights[i];
    }

    imageStore(dest, coords, vec4(color / total_weight));
}
"""

const GLSL_COPY := """
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D src_tex;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D dst_img;

#define UV ((gl_GlobalInvocationID.xy) / vec2(imageSize(dst_img)))
#define img_size vec2(imageSize(dst_img))

void main() {
    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);
    if (coords.x >= int(img_size.x) || coords.y >= int(img_size.y)) {
        return;
    }
    vec4 color = texture(src_tex, UV);
    imageStore(dst_img, coords, color);
}
"""

const GLSL_DOWNSCALE := """
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D dst;
layout(push_constant, std430) uniform Push {
    vec2 dst_size;
    float offset;
} pc;

#define UV ((gl_GlobalInvocationID.xy + vec2(0.5)) / vec2(imageSize(dst)))
#define offset pc.offset
#define half_texel_size (0.5 / pc.dst_size)

void main() {
    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);
    if (coords.x >= pc.dst_size.x || coords.y >= pc.dst_size.y) return;

    vec4 c = texture(src, UV) * 4.0;
    c += texture(src, UV + vec2(-offset - 1.0,-offset - 1.0) * half_texel_size);
    c += texture(src, UV + vec2(-offset - 1.0,offset + 1.0) * half_texel_size);
    c += texture(src, UV + vec2(offset + 1.0,-offset - 1.0) * half_texel_size);
    c += texture(src, UV + vec2(offset + 1.0,offset + 1.0) * half_texel_size);
    imageStore(dst, coords, c * 0.125);
}
"""

const GLSL_UPSCALE := """
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D dst;
layout(push_constant, std430) uniform Push {
    vec2 dst_size;
    float offset;
} pc;

#define UV ((gl_GlobalInvocationID.xy)  / vec2(imageSize(dst)))
#define offset pc.offset
#define half_texel_size (0.5 / pc.dst_size)

void main() {
    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);
    if (coords.x >= pc.dst_size.x || coords.y >= pc.dst_size.y) return;

    vec4 sum = vec4(0.0);
    sum += texture(src, UV + vec2(half_texel_size.x,half_texel_size.y) * offset)  * 2.0;
    sum += texture(src, UV + vec2(-half_texel_size.x,half_texel_size.y) * offset)  * 2.0;
    sum += texture(src, UV + vec2(half_texel_size.x,-half_texel_size.y) * offset)  * 2.0;
    sum += texture(src, UV + vec2(-half_texel_size.x,-half_texel_size.y) * offset)  * 2.0;
    sum += texture(src, UV + vec2(half_texel_size.x * 2.0, 0.0) * offset);
    sum += texture(src, UV + vec2(-half_texel_size.x * 2.0 ,0.0) * offset);
    sum += texture(src, UV + vec2(0.0,half_texel_size.y * 2.0) * offset);
    sum += texture(src, UV + vec2(0.0,-half_texel_size.y * 2.0) * offset);

    imageStore(dst, coords, sum * .0833);
}
"""
