## 提灯实体渲染器（生命周期见基类 block_entity_renderer.gd）。
## 模型优先从 Pastoral 材质包的 MC/Blockbench 模型 JSON 加载
##（mc_model_loader.gd），包缺失时回退程序化盒件提灯（体积/比例
## 对齐包模型 aabb 实测：底 5..11/16 见方、总高 13/16）。
## 发光窗格：emission 直接采样 albedo 贴图（亮暖像素自发光，
## 金属框不发光）——光源感来自贴图本身，无需逐盒手调。
## 无 class_name——main preload 接线。
extends "res://presentation/block_entity_renderer.gd"

const McModelLoader := preload("res://presentation/mc_model_loader.gd")

## Pastoral 包 assets/minecraft 目录。外部目录（包有自身许可，不入
## 库）；不存在时走程序化回退——游戏不依赖该路径可运行。
const PACK_DIR := "F:/pastoral_inspect/pack/assets/minecraft"


func _build_model() -> Mesh:
	if DirAccess.dir_exists_absolute(PACK_DIR):
		var mesh: ArrayMesh = McModelLoader.build_mesh(
				PACK_DIR, "models/block/lantern.json")
		if mesh != null and mesh.get_surface_count() > 0:
			_apply_glow(mesh)
			return mesh
	return _fallback_model()


## MC 语义 fullbright：提灯/火把在 MC 中按自身格光 15 渲染 = 全亮。
## 实体收不到体素顶点光，用 UNSHADED + 贴图压暗（×0.55）等效——
## 免疫阳光/蓝环境光冲刷（曾 emission 方案 0.6/0.25/0.08 三档 +
## albedo 压暗均被实机判"整个发白"：暗框被全局蓝环境光按比例
## 抬成灰白）。暗框 0.26×0.55≈0.14 → 深灰，窗格 0.9×0.55≈0.5 →
## 暖亮，任何光照环境观感恒定
func _apply_glow(mesh: ArrayMesh) -> void:
	for i in mesh.get_surface_count():
		var mat: StandardMaterial3D = mesh.surface_get_material(i)
		if mat == null or mat.albedo_texture == null:
			continue
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.55, 0.55, 0.55)
		mat.emission_enabled = false


## 程序化回退提灯（包缺失时）：底板/灯身（暖光 emission）/顶盖/
## 提手环，比例对齐包模型
func _fallback_model() -> ArrayMesh:
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color("3d4148")
	metal.roughness = 0.6
	metal.metallic = 0.4
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color("ffd98f")
	glass.emission_enabled = true
	glass.emission = Color(1.0, 0.85, 0.55)
	glass.emission_energy_multiplier = 0.08

	var mesh := ArrayMesh.new()
	var parts := [
		[Vector3(5.0 / 16.0, 0.0, 5.0 / 16.0),
				Vector3(11.0 / 16.0, 1.0 / 16.0, 11.0 / 16.0), metal],
		[Vector3(6.0 / 16.0, 1.0 / 16.0, 6.0 / 16.0),
				Vector3(10.0 / 16.0, 8.0 / 16.0, 10.0 / 16.0), glass],
		[Vector3(5.0 / 16.0, 8.0 / 16.0, 5.0 / 16.0),
				Vector3(11.0 / 16.0, 9.5 / 16.0, 11.0 / 16.0), metal],
		[Vector3(7.0 / 16.0, 9.5 / 16.0, 7.0 / 16.0),
				Vector3(9.0 / 16.0, 12.5 / 16.0, 9.0 / 16.0), metal],
	]
	for part in parts:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
				box_surface(part[0], part[1]))
		mesh.surface_set_material(mesh.get_surface_count() - 1, part[2])
	return mesh
