## MC/Blockbench 模型 JSON 加载器单元测试：盒件几何、UV 映射、
## parent 合并、元素旋转（Pastoral 等写实包的方块 3D 形体来源）。
extends VoxelTestCase

const McModelLoader := preload("res://presentation/mc_model_loader.gd")

## 测试模型目录（user:// 临时目录，自建 JSON——不依赖外部材质包）
var _dir := ""


func run() -> void:
	_setup_pack()
	_test_single_box()
	_test_uv_mapping()
	_test_parent_merge()
	_test_rotation()


func _setup_pack() -> void:
	_dir = "user://mc_model_test"
	DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(_dir) + "/models/block")


func _write(rel: String, text: String) -> void:
	var path := "%s/%s" % [_dir, rel]
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


func _readback(rel: String) -> String:
	return "%s/%s" % [_dir, rel]


## 单盒 0..16 全贴图：1 元素 6 面 → 24 顶点 36 索引
func _test_single_box() -> void:
	_write("models/block/box.json", """
{"elements": [{"from": [0,0,0], "to": [16,16,16],
	"faces": {"east": {"texture": "#0"}, "west": {"texture": "#0"},
		"up": {"texture": "#0"}, "down": {"texture": "#0"},
		"south": {"texture": "#0"}, "north": {"texture": "#0"}}}],
 "textures": {"0": "block/none"}}
""")
	var mesh: ArrayMesh = McModelLoader.build_mesh(_dir,
			"models/block/box.json")
	check(mesh != null, "模型网格生成")
	if mesh == null:
		return
	check_eq(mesh.get_surface_count(), 1, "同贴图合并为 1 表面")
	var arrays: Array = mesh.surface_get_arrays(0)
	check_eq((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), 24,
			"6 面 24 顶点")
	check_eq((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size(), 36,
			"6 面 36 索引")


## UV [0,0,8,16]：侧面首角（左下）应为 (0,1)（u 半幅、v 到底）
func _test_uv_mapping() -> void:
	_write("models/block/uv.json", """
{"elements": [{"from": [0,0,0], "to": [16,16,16],
	"faces": {"east": {"texture": "#0", "uv": [0, 0, 8, 16]}}}],
 "textures": {"0": "block/none"}}
""")
	var mesh: ArrayMesh = McModelLoader.build_mesh(_dir, "models/block/uv.json")
	if mesh == null:
		check(false, "uv 模型生成失败")
		return
	var arrays: Array = mesh.surface_get_arrays(0)
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	check_eq(uv.size(), 4, "4 UV 角")
	if uv.size() == 4:
		check(absf(uv[0].x) < 0.001 and absf(uv[0].y - 1.0) < 0.001,
				"左下角 (0,1)（实际 %s）" % uv[0])
		check(absf(uv[2].x - 0.5) < 0.001 and absf(uv[2].y) < 0.001,
				"右上角 (0.5,0)（实际 %s）" % uv[2])


## parent 提供 elements，子覆盖 textures（MC 语义）
func _test_parent_merge() -> void:
	_write("models/block/parent_box.json", """
{"elements": [{"from": [0,0,0], "to": [16,16,16],
	"faces": {"east": {"texture": "#0"}}}],
 "textures": {"0": "block/parent_tex"}}
""")
	_write("models/block/child.json", """
{"parent": "block/parent_box", "textures": {"0": "block/child_tex"}}
""")
	var mesh: ArrayMesh = McModelLoader.build_mesh(_dir,
			"models/block/child.json")
	check(mesh != null and mesh.get_surface_count() == 1,
			"parent elements 继承生成网格")
	# 子贴图覆盖 → 材质查 child_tex（贴图缺失回退 MAGENTA，两种引用
	# 应产生不同表面分配——这里验证解析层：用 _resolve_texture 直测
	var model: Dictionary = McModelLoader._load_merged(_dir,
			"models/block/child.json", 4)
	check_eq(String(model["textures"]["0"]), "block/child_tex",
			"子层贴图覆盖 parent")


## 元素旋转：0..4 立方体绕 (8,8,8) y 轴 90° → east 面转到 z=12/16 朝北
func _test_rotation() -> void:
	_write("models/block/rot.json", """
{"elements": [{"from": [0,6,6], "to": [4,10,10],
	"rotation": {"origin": [8, 8, 8], "axis": "y", "angle": 90},
	"faces": {"east": {"texture": "#0"}}}],
 "textures": {"0": "block/none"}}
""")
	var mesh: ArrayMesh = McModelLoader.build_mesh(_dir, "models/block/rot.json")
	if mesh == null:
		check(false, "旋转模型生成失败")
		return
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	check_eq(verts.size(), 4, "单面 4 顶点")
	if verts.size() == 4:
		# 绕 Y+90°（右手）：x'=z, z'=-x（相对 origin）——east 面(+x)
		# 转到 -z 朝向，平面落在 z=12/16
		var all_z := true
		for v in verts:
			if absf(v.z - 0.75) > 0.001:
				all_z = false
		check(all_z, "旋转后四角 z=12/16（实际 %s）"
				% [verts[0].z, verts[3].z])
		check(absf(norms[0].z + 1.0) < 0.001, "法线转到朝北 (0,0,-1)")
