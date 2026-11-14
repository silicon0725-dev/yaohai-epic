## 火把实体渲染器（生命周期见基类 block_entity_renderer.gd）。
## 模型为多部件"真实模型"：木棍（木色受场景光）+ 暗红炭头（微光
## 自发光——亮度交给火焰）+ 体积火焰面（盒网格 + torch_flame.gdshader
## 光线步进 3D 密度场，真视差）。炭头与火焰能量同步多频伪随机闪烁，
## 并随眼适应曝光反除（洞内曝光抬升时色相稳定不削顶）。
## 完整雕刻系统另有研究结论（docs/reference-chisels-and-bits.md：暂缓）。
## 无 class_name（全局类缓存坑）——main preload 接线。
extends "res://presentation/block_entity_renderer.gd"

const FlameShader := preload("res://presentation/torch_flame.gdshader")

var _stick_material: StandardMaterial3D
var _head_material: StandardMaterial3D
var _flame_material: Material
var _flicker_t := 0.0
var _exposure := 1.0  # main 眼适应注入；自发光随曝光反除保色相


## main 眼适应回调：洞内曝光抬升时自发光按同比例反除，
## 火焰/炭头过 tonemap 后色相稳定（不因黑暗中曝光 ×2.2 削顶成黄白）
func set_exposure(ex: float) -> void:
	_exposure = maxf(1.0, ex)


## 炭头 emission 与火焰 energy 同步多频伪随机闪烁（材质全场共享 =
## 全部火把同步；逐支相位偏移需逐实例 uniform，暂略）
func _process(delta: float) -> void:
	if _by_cell.is_empty() or _head_material == null:
		return
	_flicker_t += delta
	var e := (1.0 + 0.10 * sin(_flicker_t * 11.0) * sin(_flicker_t * 5.3 + 1.7) \
			+ 0.05 * sin(_flicker_t * 23.0 + 0.6)) / _exposure
	_head_material.emission_energy_multiplier = 0.3 * e
	if _flame_material != null:
		_flame_material.set_shader_parameter("energy", 1.0 * e)


## 贴墙偏移（attach 语义与放置端一致：向墙偏 6/16）
func _cell_offset(attach: Vector3i) -> Vector3:
	return Vector3(-float(attach.x) * (6.0 / 16.0), 0.0,
			-float(attach.z) * (6.0 / 16.0))


## 木棍：2/16 方柱高 9/16（木色受场景光，洞穴中被环境光照暗）；
## 炭头：2/16 方块与柄同粗（微光暗红炭块——亮度交给火焰）；
## 火焰体：盒网格（7/16 见方 × 高 9/16→16/16）——着色器内体积
## 光线步进（真 3D 视差，非面向玩家的面片贴图）
func _build_model() -> Mesh:
	if _stick_material == null:
		_stick_material = StandardMaterial3D.new()
		_stick_material.albedo_color = Color("6e5433")
		_stick_material.roughness = 1.0
	if _head_material == null:
		_head_material = StandardMaterial3D.new()
		# MC 语义：炭头是"暗红炭块"（微微透红），亮度全部交给火焰
		_head_material.albedo_color = Color("2b1a0e")
		_head_material.emission_enabled = true
		_head_material.emission = Color(1.0, 0.42, 0.08)
		_head_material.emission_energy_multiplier = 0.3
	if _flame_material == null:
		_flame_material = ShaderMaterial.new()
		_flame_material.shader = FlameShader
		# 能量档位说明：眼适应在暗处把 tonemap 曝光抬到 ~2.2，
		# albedo>1 的色带会整体削顶成同一片黄白（色相塌缩）——
		# 火焰/炭头都压在 LDR 档（×2.2 后仍各读各的橙/黄/白）
		_flame_material.set_shader_parameter("energy", 1.0)

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box_surface(
			Vector3(7.0 / 16.0, 0.0, 7.0 / 16.0),
			Vector3(9.0 / 16.0, 9.0 / 16.0, 9.0 / 16.0)))
	mesh.surface_set_material(0, _stick_material)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box_surface(
			Vector3(7.0 / 16.0, 9.0 / 16.0, 7.0 / 16.0),
			Vector3(9.0 / 16.0, 12.0 / 16.0, 9.0 / 16.0)))
	mesh.surface_set_material(1, _head_material)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box_surface(
			Vector3(0.28125, 9.0 / 16.0, 0.28125),
			Vector3(0.71875, 1.0, 0.71875)))
	mesh.surface_set_material(2, _flame_material)
	return mesh


func _spawn(cell: Vector3i, attach: Vector3i) -> void:
	super._spawn(cell, attach)
	# MultiMesh 路径（审查二轮 C8）：cast_shadow 在 MultiMeshInstance3D
	# 上整体关闭（基类 setup）；逐实例路径才需要逐实例设置
	if not _use_multimesh:
		var mi: MeshInstance3D = _by_cell.get(cell)
		if mi != null:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
