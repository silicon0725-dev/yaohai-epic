## 渲染类别 -> 材质的注册表（开发文档 §6.2 第 4 步、§6.5）。
## Stage A 只有单一不透明图集材质；玻璃与水等透明/半透明类别
## 在不透明路径稳定后单独引入，不与第一版网格混在一起。
## 未知类别回退到不透明材质并报错（资源缺失回退策略 §11.2）。
class_name VoxelMaterialRegistry
extends RefCounted

var _materials := {}


func _init(atlas_texture: Texture2D) -> void:
	_materials["opaque"] = _create_atlas_material(atlas_texture)


func material_for(render_type: String) -> Material:
	if _materials.has(render_type):
		return _materials[render_type]
	push_error("未注册的渲染类别: %s，回退使用 opaque" % render_type)
	return _materials["opaque"]


func _create_atlas_material(atlas: Texture2D) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = atlas
	# Nearest 过滤 + 无 mipmap：像素风外观，同时避免图集渗色（§7.1）。
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.roughness = 1.0
	material.metallic = 0.0
	return material


## 水面波纹材质（§6.5：透明类别独立材质；参考 RealisticEnvironments
## 的分层思想——水是独立渲染通道，波纹取其"程序化水波"思路）。
## 双面（水下/水面内侧可见）。波纹全程序化（世界坐标驱动，无需 UV）：
## - 顶点起伏：双正弦波让水线轻微涌动（位移是位置的纯函数，
##   顶面/侧面共享角点得到同一位移，接缝不裂）；
## - 像素波纹：量化世界坐标的移动亮度色块（体素风）。
## UNSHADED：光照会把纯色水面推到近白（FILMIC 再去饱和），关掉后
## 深浅由透出的海底决定。纯视觉，水位/浮力物理不受影响。
func create_water_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://presentation/water_surface.gdshader")
	var tex_image := Image.load_from_file(
			"res://assets/textures/water_still.png")
	tex_image.generate_mipmaps()  # 远处贴图颗粒 <1px，无 mipmap 会混叠闪烁
	material.set_shader_parameter("water_tex",
			ImageTexture.create_from_image(tex_image))
	return material


## 水侧面材质：同波纹但背面剔除（water_side.gdshader）——下落水柱
## 四个侧面都朝空气，双面会从一侧看到远侧背面（半透明叠层成
## "浮空背面"），侧面只出正面。
func create_water_side_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://presentation/water_side.gdshader")
	return material


## Greedy Meshing 专用：平铺着色器材质（fract(uv) 采样图集）。
func create_greedy_material(atlas: Texture2D) -> ShaderMaterial:
	var shader := load("res://presentation/atlas_tiling.gdshader")
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("atlas", atlas)
	material.set_shader_parameter("tile_fraction",
			Vector2(1.0 / TextureAtlasLoader.COLS, 1.0 / TextureAtlasLoader.ROWS))
	return material
