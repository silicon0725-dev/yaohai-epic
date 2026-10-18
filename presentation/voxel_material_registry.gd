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


## Greedy Meshing 专用：平铺着色器材质（fract(uv) 采样图集）。
func create_greedy_material(atlas: Texture2D) -> ShaderMaterial:
	var shader := load("res://presentation/atlas_tiling.gdshader")
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("atlas", atlas)
	material.set_shader_parameter("tile_fraction",
			Vector2(1.0 / TextureAtlasLoader.COLS, 1.0 / TextureAtlasLoader.ROWS))
	return material
