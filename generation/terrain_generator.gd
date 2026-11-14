## 固定种子的确定性地形生成器（开发文档 §5）。
## v3（参考 Terrain Diffusion 的合成地形配方移植）：
##   1. 分位匹配——把单纯形 fBm 的输出分布重映射到贴近真实地貌的
##      高程分布（大面积平原、长尾山地），源分位节点在初始化时对
##      本种子噪声采样校准（对应 transform_perlin + build_quantiles）；
##   2. 粗图布局——低频"山脉掩码"决定山在哪里，掩码内叠加脊状
##      噪声（RIDGED）生成山脊线，等价于其 coarse map 条件生成；
##   3. 气候场——低频温度/降水两张粗图 + 温度随海拔的递减率
##      （lapse），据此选生物群系：荒漠（热且干）/ 草原 /
##      裸岩山地 / 滩涂沙地。
## v8（Epic-Terrain 数据包尺度配比移植，"巨型档"整体缩 2 倍）：
##   地表按"显示比例"分层重构——大陆板块 fbm 4096 格 / 山系掩码
##   2048 + 脊状山形 1024 / Epic 式 5 级侵蚀链（1024→64，嵌套系数
##   0.5/0.3/0.17/0.08，海岸带加权出峡湾与离岸岛屿）+ ridged 零点
##   窄带河流（走向 2048 格，窄带 0.03 下切到海平面下，静态水填充
##   自动成河）。分位匹配表保留（高程多样性资产），仅换形状来源。
## 调整任何参数都必须递增版本——未修改区域会用新算法重建，已保存
## 的完整区块数据不受影响（§5.1、§9）。
@tool
class_name TerrainGenerator
extends RefCounted

## C# 原生地形桥（preload 避开新 class_name 的全局类缓存坑）
const NativeTerrainBridge := preload("res://meshing/native_terrain_bridge.gd")

## 生成算法版本。
const GENERATOR_VERSION := 8

# ---- 地层参数（v2 语义保留）----
## 表层以下 3 格为泥土（草区）或砂岩（沙区）。
const DIRT_LAYER_DEPTH := 3
const SANDSTONE_LAYER_DEPTH := 3
## 地表高度不超过此值时为滩涂/干涸湖床沙地。
## 遗留常量（48 高世界的值）；运行时一律用实例 sand_max_height
##（= sea_level + 1，随世界高度联动）。
const SAND_MAX_HEIGHT := 8
## 矿石不生成的地表保护层厚度。
const ORE_SURFACE_MARGIN := 4
## 海平面（v4）：低于它的空气列填水。取 7 与滩涂沙线上限（8）衔接
##——海岸一圈自然成沙滩；水下地表本就 ≤8 全为沙（浅海沙底）。
## 遗留常量（48 高世界的值）；运行时一律用实例 sea_level（v9 起
## 随世界高度联动：48 高=7 保持老存档逐格一致，新世界 H/8——512
## 高=64，MC 同款）。仅测试（显式 chunks_y=3）与 debug 脚本引用。
const SEA_LEVEL := 7

# ---- v7 洞穴与矿脉（Minetest cavegen/mg_ore 算法移植）----
## 隧道判定：两条 3D 噪声等值线交叉——d1=1-|n1|、d2=1-|n2|，
## d1*d2 > width 即在双等值线交叉的管状隧道内（天然互通网络，
## 贴地表处自然开口）。width 越大隧道越宽。
## 注意：Minetest 原参数靠噪声 scale=3（值域超 ±1）把隧道压稀，
## FastNoiseLite FBM 输出归一 ±1，必须按实测分位重标——width=0.88
## 在真实地下带给出 ~3.5% 隧道体积、垂直剖面中位 3 格（可通行；
## 游程探针标定，勿改回小值，0.09 会把 99.96% 地下挖空；
## 0.90 以上管径坍缩到 1 格高钻不进）。
const CAVE_WIDTH := 0.88
## 隧道噪声频率（1/48 格 = 隧道走向的弯曲尺度）与倍频。
const CAVE_FREQ := 1.0 / 48.0
const CAVE_OCTAVES := 2
## 大洞厅（cheese cavern）：低频 3D 噪声超阈值即整片挖空。
const CHEESE_FREQ := 1.0 / 64.0
const CHEESE_OCTAVES := 2
const CHEESE_THRESHOLD := 0.58
## 大洞厅最小埋深（距地表）——浅层只允许细隧道（防满天窗）。
const CHEESE_MIN_DEPTH := 8
## 矿脉细脉判定：vein 双噪声等值线交叉 + hash 抖动。
## value = d1*d2 + (hash*2-1)*0.04；煤 value > COAL_VEIN_VALUE、
## 铁 value > IRON_VEIN_VALUE（更稀）且深度更带状。
## 阈值同为归一化噪声分位标定（煤 ~2.1%、铁 ~0.74% 地下带占比，
## 探针 p97≈0.892 / p99≈0.965——0.16/0.30 是 Minetest scale 语义
## 的残留，在归一化输出下会产生海量矿）。
const VEIN_FREQ := 1.0 / 16.0
const VEIN_OCTAVES := 1
const VEIN_JITTER := 0.04
const COAL_VEIN_VALUE := 0.92
const IRON_VEIN_VALUE := 0.965
## 铁矿深度带上限（比煤更深）。遗留常量（48 高世界）；运行时用
## 实例 iron_ore_max_y（= sea_level + 13，随世界高度联动）。
const IRON_ORE_MAX_Y := 20

# ---- v8 地形塑形参数（Epic-Terrain 配比，巨型档=其尺度 ÷2）----
## 高程分布重映射的目标分位表（移植其分位匹配）：输入为噪声的
## 累积分位，输出为高度占比 0..1。质量集中在中低（平原为主），
## 高端长尾（山地稀少而陡峭）——即真实地貌的测高曲线形状。
const KNOT_COUNT := 17
const TARGET_HEIGHT_FRAC := [
	0.030, 0.055, 0.075, 0.095, 0.115, 0.135, 0.155, 0.180,
	0.205, 0.235, 0.270, 0.315, 0.370, 0.445, 0.540, 0.680, 0.900,
]
## 大陆板块 fbm 波长（Epic continentalness 8192 格 ÷2）与倍频。
const CONTINENT_FREQ := 1.0 / 4096.0
const CONTINENT_OCTAVES := 6
## 山系分布掩码波长与门控（smoothstep 区间）：掩码高于上界全幅出山，
## 低于下界完全无山——山只出现在掩码划定的山系区域。
const MOUNTAIN_MASK_FREQ := 1.0 / 2048.0
const MOUNTAIN_GATE_LO := 0.30
const MOUNTAIN_GATE_HI := 0.60
## 脊状山形波长/倍频与幅度。FNL Ridged 实测输出 [-0.62, 1.0]
## （1-|n| 加权语义，脊线=max）；clamp 截到 [0,1] 后负值区=谷底
## 平地，正好像山间谷地（v3 的 (n+1)/2 映射会把输出压在 [0.2,1]
## 使山形变馒头——v8 改直接取值）。
const RIDGE_FREQ := 1.0 / 1024.0
const RIDGE_OCTAVES := 5
const MOUNTAIN_GAIN := 0.46
## Epic 式侵蚀链：4 级嵌套扰动（波长 512/256/128/64，系数递减
## 0.5/0.3/0.17/0.08）叠加在 1024 格主体上——大波长管趋势、逐级
## 加细节，中观地貌过渡带的来源。
const ERODE_FREQ := 1.0 / 1024.0
const ERODE_GAIN_1 := 0.5
const ERODE_GAIN_2 := 0.3
const ERODE_GAIN_3 := 0.17
const ERODE_GAIN_4 := 0.08
## 海岸带权重（smoothstep 升/降端点，frac 空间；海平面 frac≈0.14）：
## 侵蚀只在海岸带全幅作用（峡湾/海峡/离岸岛屿），内陆轻调制。
const COAST_RISE_LO := 0.06
const COAST_RISE_HI := 0.11
const COAST_FALL_LO := 0.24
const COAST_FALL_HI := 0.34
const COAST_ERODE_GAIN := 0.07
const INLAND_ERODE_GAIN := 0.03
## 河流（Epic r/1 配方移植）：普通 fbm 噪声取绝对值后的过零窄带
## = 河道（走向波长 2048 格；|n|<BAND 的带状区即河，宽度由带宽
## 与噪声梯度决定）。窄带内按带宽向下切到 RIVER_FRAC（河床 h≈5，
## 海平面下 2 格 → 静态水填充自动成河），强度调制噪声（1024 格）
## 让河段有深浅/源头变化。只在陆上（frac > RIVER_FRAC）下切，
## 河到海边自然衔接。注意不能用 Ridged 分形取低值端——多倍频
## 和的分布挤在中段，>0.97 端趋零；必须对原始 fbm 取 abs。
const RIVER_FREQ := 1.0 / 2048.0
const RIVER_OCTAVES := 4
const RIVER_MOD_FREQ := 1.0 / 1024.0
const RIVER_BAND := 0.001
const RIVER_FRAC := 0.085
const RIVER_BASE := 0.4
## 裸岩山地的高度占比阈值（高于此值表层为石头，无泥土）。
const ROCK_SURFACE_FRAC := 0.62
## 气候：温度随高度占比的递减率（高地更冷）。
const TEMP_LAPSE := 0.9
## 荒漠判定：温度与干燥度阈值（低地才算，山地按裸岩处理）。
const DESERT_TEMP := 0.30
const DESERT_DRYNESS := -0.10
const DESERT_MAX_FRAC := 0.45

var config: WorldConfig
var _continental_noise: FastNoiseLite
var _mountain_mask_noise: FastNoiseLite
var _ridge_noise: FastNoiseLite
var _e0_noise: FastNoiseLite
var _e1_noise: FastNoiseLite
var _e2_noise: FastNoiseLite
var _e3_noise: FastNoiseLite
var _e4_noise: FastNoiseLite
var _river1_noise: FastNoiseLite
var _river2_noise: FastNoiseLite
var _temp_noise: FastNoiseLite
var _precip_noise: FastNoiseLite
var _coal_noise: FastNoiseLite
var _iron_noise: FastNoiseLite
## v7 洞穴与矿脉噪声（隧道双等值线 / 大洞厅 / 细脉双等值线）
var _cave1_noise: FastNoiseLite
var _cave2_noise: FastNoiseLite
var _cheese_noise: FastNoiseLite
var _vein1_noise: FastNoiseLite
var _vein2_noise: FastNoiseLite
## 本种子噪声的源分位节点（初始化时校准，确定性）。
var _source_knots := PackedFloat32Array()

# ---- v9 高度联动（世界高度可变：老存档 48 逐格一致，新世界 512）----
## 海平面：48 高世界=7（原值逐格一致）；其余 H/8（512→64，MC 同款）。
## 所有海/滩涂/铁矿带判定必须走实例字段，勿用遗留 const（两套值）。
var sea_level: int
## 滩涂/浅海沙线（= sea_level + 1，保持与 48 高世界的衔接关系）。
var sand_max_height: int
## 铁矿深度带上限（= sea_level + 13，原 7+13=20 逐格一致）。
var iron_ore_max_y: int


## 海平面随世界高度联动（静态，主场景读配置期就能算）：48 高
## （chunks_y=3 老存档/旧测试）=7 逐格一致；其余 H/8（512→64）。
static func sea_level_for(world_height_blocks: int) -> int:
	if world_height_blocks <= 48:
		return 7
	return world_height_blocks / 8


func _init(world_config: WorldConfig) -> void:
	config = world_config
	sea_level = sea_level_for(world_config.world_height_blocks())
	sand_max_height = sea_level + 1
	iron_ore_max_y = sea_level + 13
	# 粗图（v8 尺度配比）：大陆板块 4096 / 山系掩码 2048 / 气候 2048
	_continental_noise = _make_fbm(world_config.world_seed,
			CONTINENT_FREQ, CONTINENT_OCTAVES)
	_mountain_mask_noise = _make_fbm(world_config.world_seed + 101,
			MOUNTAIN_MASK_FREQ, 3)
	_temp_noise = _make_fbm(world_config.world_seed + 202,
			MOUNTAIN_MASK_FREQ, 3)
	_precip_noise = _make_fbm(world_config.world_seed + 303,
			MOUNTAIN_MASK_FREQ, 3)
	# 山形：脊状分形（FNL Ridged 输出 [0,1]，1-|n| 语义脊线=max）
	_ridge_noise = FastNoiseLite.new()
	_ridge_noise.seed = world_config.world_seed + 404
	_ridge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_ridge_noise.frequency = RIDGE_FREQ
	_ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_ridge_noise.fractal_octaves = RIDGE_OCTAVES
	# Epic 式侵蚀链：1024 主体 + 4 级扰动（512/256/128/64）
	_e0_noise = _make_fbm(world_config.world_seed + 505, ERODE_FREQ, 1)
	_e1_noise = _make_fbm(world_config.world_seed + 515,
			ERODE_FREQ * 2.0, 1)
	_e2_noise = _make_fbm(world_config.world_seed + 525,
			ERODE_FREQ * 4.0, 1)
	_e3_noise = _make_fbm(world_config.world_seed + 535,
			ERODE_FREQ * 8.0, 1)
	_e4_noise = _make_fbm(world_config.world_seed + 545,
			ERODE_FREQ * 16.0, 1)
	# 河流：fbm 走向（取 abs 过零窄带）+ 强度调制
	_river1_noise = _make_fbm(world_config.world_seed + 624,
			RIVER_FREQ, RIVER_OCTAVES)
	_river2_noise = _make_fbm(world_config.world_seed + 634,
			RIVER_MOD_FREQ, 3)
	# 矿物（v7 细脉网络替代 v2 单噪声阈值）
	_coal_noise = _make_fbm(world_config.world_seed + 606, 0.08, 1)
	_iron_noise = _make_fbm(world_config.world_seed + 707, 0.09, 1)
	# v7 洞穴与矿脉噪声（seed 段 808+，与粗图/细节段隔离）
	_cave1_noise = _make_fbm(world_config.world_seed + 808,
			CAVE_FREQ, CAVE_OCTAVES)
	_cave2_noise = _make_fbm(world_config.world_seed + 909,
			CAVE_FREQ, CAVE_OCTAVES)
	_cheese_noise = _make_fbm(world_config.world_seed + 1010,
			CHEESE_FREQ, CHEESE_OCTAVES)
	_vein1_noise = _make_fbm(world_config.world_seed + 1111,
			VEIN_FREQ, VEIN_OCTAVES)
	_vein2_noise = _make_fbm(world_config.world_seed + 1212,
			VEIN_FREQ, VEIN_OCTAVES)
	_source_knots = _build_source_quantiles()


static func _make_fbm(seed_value: int, frequency: float, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = frequency
	noise.fractal_octaves = octaves
	return noise


## 对本种子的大陆噪声固定采样，构建源分布分位节点（对应
## build_quantiles：分布与种子无关，仅频率/倍频参数决定形状；
## 固定采样坐标保证确定性）。
## 采样窗必须远大于噪声波长（v8 大陆 4096 格 → 窗 ~20000 格，
## 约 5 个波长；v3 旧步长 37/41 的 900 格窗会让 576 个样本全落在
## 单一坡面上，分位节点挤成一点，全图高度塌到低端）。
func _build_source_quantiles() -> PackedFloat32Array:
	var samples: Array[float] = []
	for i in 24:
		for j in 24:
			samples.append(_continental_noise.get_noise_2d(
					float(i * 911 + 3), float(j * 929 + 13)))
	samples.sort()
	var knots := PackedFloat32Array()
	for k in KNOT_COUNT:
		var idx := int(round(float(k) / float(KNOT_COUNT - 1)
				* float(samples.size() - 1)))
		knots.append(samples[idx])
	for k in range(1, knots.size()):
		if knots[k] <= knots[k - 1]:
			knots[k] = knots[k - 1] + 0.0001
	return knots


## 分位匹配（对应 transform_perlin）：把噪声值线性映射到目标
## 高程分布的对应分位高度占比。
func _shape_height(noise_value: float) -> float:
	if noise_value <= _source_knots[0]:
		return float(TARGET_HEIGHT_FRAC[0])
	for k in range(1, _source_knots.size()):
		if noise_value <= _source_knots[k]:
			var t := (noise_value - _source_knots[k - 1]) \
					/ maxf(_source_knots[k] - _source_knots[k - 1], 0.0001)
			return lerpf(float(TARGET_HEIGHT_FRAC[k - 1]), float(TARGET_HEIGHT_FRAC[k]), t)
	return float(TARGET_HEIGHT_FRAC[TARGET_HEIGHT_FRAC.size() - 1])


## 列剖面：高度占比 + 高度 + 生物群系（每列一次，供地层填充）。
## v8 层序：分位匹配大陆 → 山系掩码×脊状山形 → Epic 侵蚀链
## （海岸带全幅/内陆轻调制）→ 河流窄带下切 → 气候群系。
func column_profile(world_x: int, world_z: int) -> Dictionary:
	var frac := _shape_height(
			_continental_noise.get_noise_2d(world_x, world_z))
	var mask_raw := _mountain_mask_noise.get_noise_2d(world_x, world_z)
	var gate := smoothstep(MOUNTAIN_GATE_LO, MOUNTAIN_GATE_HI, mask_raw)
	if gate > 0.0:
		# FNL Ridged 实测 [-0.62,1]，截 [0,1] 后平方——压谷抬峰：
		# 不平方时输出均值 ~0.4，山系内部整体抬升成裸岩高原；
		# 平方后只有脊线附近满幅，山系=线状峰峦+谷地
		var ridge01 := clampf(_ridge_noise.get_noise_2d(world_x, world_z),
				0.0, 1.0)
		ridge01 *= ridge01
		frac += gate * ridge01 * MOUNTAIN_GAIN
	# Epic 式侵蚀链：大波长主体 + 逐级小系数扰动
	var e := _e0_noise.get_noise_2d(world_x, world_z) \
			+ absf(_e1_noise.get_noise_2d(world_x, world_z)) * ERODE_GAIN_1 \
			+ absf(_e2_noise.get_noise_2d(world_x, world_z)) * ERODE_GAIN_2 \
			+ absf(_e3_noise.get_noise_2d(world_x, world_z)) * ERODE_GAIN_3 \
			+ absf(_e4_noise.get_noise_2d(world_x, world_z)) * ERODE_GAIN_4
	var coast := smoothstep(COAST_RISE_LO, COAST_RISE_HI, frac) \
			* (1.0 - smoothstep(COAST_FALL_LO, COAST_FALL_HI, frac))
	frac += e * (coast * COAST_ERODE_GAIN + INLAND_ERODE_GAIN)
	# 河流：原始 fbm 取 abs 的过零窄带（|n|<BAND 的线状带区），
	# 只在陆上下切（河海自然衔接）
	var rn := absf(_river1_noise.get_noise_2d(world_x, world_z))
	if rn < RIVER_BAND and frac > RIVER_FRAC:
		var rw := clampf(_river2_noise.get_noise_2d(world_x, world_z),
				0.0, 1.0)
		var band := 1.0 - rn / RIVER_BAND
		var depth := band * (RIVER_BASE + (1.0 - RIVER_BASE) * rw)
		frac = lerpf(frac, RIVER_FRAC, minf(depth, 1.0))
	frac = clampf(frac, 0.0, 1.0)
	var max_surface := config.world_height_blocks() - 3
	var height := clampi(
			1 + int(round(frac * float(max_surface - 1))), 1, max_surface)
	# v5：压掉"齐平沙洲"（height == sea_level，顶面恰在海平面上
	# 0.125 格）——贴水视角是大片无水干沙色平台带 + 同高露头横线，
	# 被视为"水面缺口"。降 1 格沉为 1 格水深浅滩，海滩线从 +1 开始
	if height == sea_level:
		height = sea_level - 1

	var rocky := frac >= ROCK_SURFACE_FRAC
	var temp := _temp_noise.get_noise_2d(world_x, world_z) \
			- TEMP_LAPSE * maxf(0.0, frac - 0.30)
	var desert := not rocky and height > sand_max_height \
			and temp > DESERT_TEMP and frac < DESERT_MAX_FRAC \
			and _precip_noise.get_noise_2d(world_x, world_z) < DESERT_DRYNESS
	var sandy := desert or height <= sand_max_height
	return { "height": height, "frac": frac, "rocky": rocky, "sandy": sandy }


## 列表面方块（§5.1 气候群系 + 矿脉层）：按高度占比与气候选块。
func block_for_column(
		profile: Dictionary, world_x: int, world_y: int,
		world_z: int, height: int
) -> int:
	return _block_for_column(profile, profile["rocky"], profile["sandy"],
			world_x, world_y, world_z, height)


## 内联版：rocky/sandy 由调用方解包（生成热循环免每格字符串键取值）。
func _block_for_column(
		profile: Dictionary, rocky: bool, sandy: bool,
		world_x: int, world_y: int, world_z: int, height: int
) -> int:
	if world_y > height:
		return VoxelTypes.AIR_ID
	if world_y == 0:
		return VoxelTypes.BEDROCK_ID
	if world_y == height:
		if rocky:
			return VoxelTypes.STONE_ID
		if sandy or height <= sand_max_height:
			return VoxelTypes.SAND_ID
		return VoxelTypes.GRASS_ID
	if world_y >= height - DIRT_LAYER_DEPTH:
		if rocky:
			return VoxelTypes.STONE_ID
		if sandy or height <= sand_max_height:
			# 滩涂/荒漠沙地层：紧贴表层的次层是砂岩（测试期望
			# sandy 列 depth 1..3 全为砂岩）
			return VoxelTypes.SANDSTONE_ID
		return VoxelTypes.DIRT_ID
	# v7 洞穴与矿脉（地表保护层内不挖——防满地天窗；基岩上留层）
	if world_y <= height - ORE_SURFACE_MARGIN and world_y >= 1:
		if _is_cave(world_x, world_y, world_z, height):
			return VoxelTypes.AIR_ID
		var ore := _ore_vein(world_x, world_y, world_z)
		if ore != VoxelTypes.AIR_ID:
			return ore
	return VoxelTypes.STONE_ID


## 隧道：双 3D 噪声等值线交叉（Minetest cavegen）；大洞厅：低频
## 3D 噪声超阈值（更深处）。地下格才判定（调用方保证）。
func _is_cave(world_x: int, world_y: int, world_z: int,
		height: int) -> bool:
	var d1 := 1.0 - absf(_cave1_noise.get_noise_3d(
			world_x, world_y, world_z))
	var d2 := 1.0 - absf(_cave2_noise.get_noise_3d(
			world_x, world_y, world_z))
	if d1 * d2 > CAVE_WIDTH:
		return true
	if world_y <= height - CHEESE_MIN_DEPTH \
			and _cheese_noise.get_noise_3d(
			world_x, world_y, world_z) > CHEESE_THRESHOLD:
		return true
	return false


## 矿脉细脉（Minetest mg_ore OreVein）：vein 双噪声等值线交叉
## + hash 抖动控制厚度；煤浅带、铁更深（IRON_ORE_MAX_Y）。
## hash 为整型算术（GD/C# 位同步——RandomNumberGenerator 序列
## 不可跨语言复现）。
static func _hash_unit(x: int, y: int, z: int) -> float:
	var h := (x * 73856093) ^ (y * 19349663) ^ (z * 83492791)
	h = absi(h) % 65536
	return float(h) / 65536.0


func _ore_vein(world_x: int, world_y: int, world_z: int) -> int:
	var d1 := 1.0 - absf(_vein1_noise.get_noise_3d(
			world_x, world_y, world_z))
	var d2 := 1.0 - absf(_vein2_noise.get_noise_3d(
			world_x, world_y, world_z))
	var jitter: float = _hash_unit(world_x, world_y, world_z) \
			* 2.0 - 1.0
	var value: float = d1 * d2 + jitter * VEIN_JITTER
	if value > IRON_VEIN_VALUE and world_y <= iron_ore_max_y:
		return VoxelTypes.IRON_ORE_ID
	if value > COAL_VEIN_VALUE:
		return VoxelTypes.COAL_ORE_ID
	return VoxelTypes.AIR_ID



## 某一世界列（x, z）的地表高度。独立暴露便于测试与未来生物群系接入。
func column_height(world_x: int, world_z: int) -> int:
	return column_profile(world_x, world_z)["height"]


## 树影响半径（树冠 + 主干倾斜余量，格）
const TREE_REACH := 4


func generate_chunk(chunk_coord: Vector3i) -> ChunkData:
	assert(config.in_chunk_bounds(chunk_coord),
			"生成垂直越界区块: %s" % chunk_coord)
	var size := config.chunk_size
	var chunk := ChunkData.new(
			chunk_coord,
			Vector3i(size, size, size),
			GENERATOR_VERSION
	)
	chunk.state = ChunkState.State.GENERATING
	var origin := VoxelCoords.chunk_origin(chunk_coord, size)
	# C# 优先（等价测试 native_terrain 多种子逐字节保证）：列剖面+方块
	# 填充主体走原生；树重放留 GDScript（hash/RNG 等价风险长尾），
	# 复用 C# 输出的列剖面数组免重复噪声采样。不可用回退 GD 全程
	var native := NativeTerrainBridge.generate_chunk(
			config.world_seed, config.world_height_blocks(),
			chunk_coord, size)
	if not native.is_empty():
		chunk.block_ids = native["ids"]
		_scatter_trees(chunk, native)
		_scatter_plants(chunk, native)
	else:
		_fill_columns_gd(chunk, origin, size)
		_scatter_trees(chunk, {})
		_scatter_plants(chunk, {})
	chunk.state = ChunkState.State.DATA_READY
	return chunk


## GDScript 列填充回退路径（与 C# NativeTerrain.GenerateChunk 等价，
## 等价测试保证；直写 block_ids 布局 x + y*s + z*s²）。
func _fill_columns_gd(chunk: ChunkData, origin: Vector3i, size: int) -> void:
	var ids := chunk.block_ids
	for lz in size:
		var z_off := lz * size * size
		for lx in size:
			var world_x := origin.x + lx
			var world_z := origin.z + lz
			var profile := column_profile(world_x, world_z)
			var height: int = profile["height"]
			var rocky: bool = profile["rocky"]
			var sandy: bool = profile["sandy"]
			var col := z_off + lx
			for ly in size:
				var world_y := origin.y + ly
				var block_id: int
				# 海平面填充：地表之上的空气低于海平面即为水（v1 静态水）
				if world_y > height and world_y <= sea_level:
					block_id = VoxelTypes.WATER_ID
				else:
					block_id = _block_for_column(profile, rocky, sandy,
							world_x, world_y, world_z, height)
				ids[col + ly * size] = block_id


## v6 动态树撒种（确定性哈希）：草地且上方空气、距 chunk 边 >=3 格
##（树冠半径 2 + 主干倾斜余量，避免跨 chunk 截断），草地密度约 5%。
## v6.1 影响范围重放（修"树顶被生成层顶切断"）：每层 chunk 对
## 水平范围内可能影响本层的所有树（根在 ±TREE_REACH 列内、
## 树根的地表任意层）确定性重放生长（同 rng 同树形），只写入
## 落在本层的格——跨层树在每层各写各的部分，完整无截断。
## profiles 非空时（C# 路径）界内列直接查 height/sandy/rocky 数组，
## 界外列（±TREE_REACH 圈）回退 column_profile——每树 1-2 次，量小。
## 植被撒布（草/花，生成期确定性 hash——同树重放先例留 GD 侧，
## C# 生成路径不碰）：草地表面、上方空气且非水下。密度 v1 定值：
## 高草 10%、两种花各 1%（与高草互斥）。树占位优先（树在植物前
## 撒布，_ref 占位非空气自然跳过）。
const TreeScatterScript := preload("res://systems/trees/tree_scatter.gd")
const PLANT_SALT := 777
const TALL_GRASS_DENSITY := 0.22
const FLOWER_DENSITY := 0.01


func _scatter_plants(chunk: ChunkData, profiles: Dictionary) -> void:
	var size := chunk.dimensions.x
	var origin := chunk.chunk_coord * size
	var heights: PackedInt32Array = profiles.get("heights",
			PackedInt32Array())
	var sandy_arr: PackedByteArray = profiles.get("sandy",
			PackedByteArray())
	var rocky_arr: PackedByteArray = profiles.get("rocky",
			PackedByteArray())
	for lz in size:
		for lx in size:
			var col := lz * size + lx
			var height: int
			var sandy: bool
			var rocky: bool
			if not heights.is_empty():
				height = heights[col]
				sandy = sandy_arr[col] == 1
				rocky = rocky_arr[col] == 1
			else:
				var prof := column_profile(origin.x + lx, origin.z + lz)
				height = int(prof["height"])
				sandy = bool(prof["sandy"])
				rocky = bool(prof["rocky"])
			if sandy or rocky or height <= sea_level:
				continue
			# 地表格必须在本区块内且其上格也在（跨顶界跳过——上层
			# 区块生成时该列地表不在其内，天然不重复）
			var surf_y := height - origin.y
			if surf_y < 0 or surf_y >= size or surf_y + 1 >= size:
				continue
			var base := col + surf_y * size
			if chunk.block_ids[base] != VoxelTypes.GRASS_ID:
				continue
			if chunk.block_ids[base + size] != VoxelTypes.AIR_ID:
				continue
			var wx := origin.x + lx
			var wz := origin.z + lz
			var r := TreeScatterScript.hash01(wx, wz, PLANT_SALT)
			var plant: int = VoxelTypes.AIR_ID
			if r < FLOWER_DENSITY:
				plant = VoxelTypes.FLOWER_POPPY_ID
			elif r < FLOWER_DENSITY * 2.0:
				plant = VoxelTypes.FLOWER_DANDELION_ID
			elif r < FLOWER_DENSITY * 2.0 + TALL_GRASS_DENSITY:
				plant = VoxelTypes.TALL_GRASS_ID
			if plant != VoxelTypes.AIR_ID:
				chunk.block_ids[base + size] = plant


func _scatter_trees(chunk: ChunkData, profiles: Dictionary) -> void:
	var origin := Vector3i(chunk.chunk_coord.x * chunk.dimensions.x,
			chunk.chunk_coord.y * chunk.dimensions.y,
			chunk.chunk_coord.z * chunk.dimensions.z)
	var size: int = chunk.dimensions.x
	var has_profiles := not profiles.is_empty()
	var heights: PackedInt32Array = profiles.get("heights", PackedInt32Array())
	var sandy_arr: PackedByteArray = profiles.get("sandy", PackedByteArray())
	var rocky_arr: PackedByteArray = profiles.get("rocky", PackedByteArray())
	for wx in range(origin.x - TREE_REACH, origin.x + size + TREE_REACH):
		for wz in range(origin.z - TREE_REACH, origin.z + size + TREE_REACH):
			if not TreeGenerator.has_tree_at(config.world_seed,
					Vector2i(wx, wz)):
				continue
			var surf := 0
			var is_sandy := false
			var is_rocky := false
			var lx := wx - origin.x
			var lz := wz - origin.z
			if has_profiles and lx >= 0 and lx < size and lz >= 0 and lz < size:
				var pidx := lz * size + lx
				surf = heights[pidx]
				is_sandy = sandy_arr[pidx] == 1
				is_rocky = rocky_arr[pidx] == 1
			else:
				var profile := column_profile(wx, wz)
				surf = profile["height"]
				is_sandy = profile.get("sandy", false)
				is_rocky = profile.get("rocky", false)
			if surf <= sea_level:
				continue  # 水域/滩涂不种树
			# 草地判定（荒漠/裸岩不种）
			if is_sandy or is_rocky:
				continue
			_grow_tree_into_chunk(chunk, Vector3i(wx, surf + 1, wz))

## 确定性重放一棵树并只把落在本 chunk 的枝干/树叶格写入占位
##（跨层/跨区块树由各层重放补齐，树系统 v2 接口）。
func _grow_tree_into_chunk(chunk: ChunkData, root: Vector3i) -> void:
	var sp := TreeSpecies.new()
	var tree := TreeGenerator.generate(sp, config.world_seed, root)
	var origin := Vector3i(chunk.chunk_coord.x * chunk.dimensions.x,
			chunk.chunk_coord.y * chunk.dimensions.y,
			chunk.chunk_coord.z * chunk.dimensions.z)
	# 枝干占位（radius 逐格插值，仅主干）
	for cell in tree.cell_to_branch:
		var local: Vector3i = cell - origin
		if local.x < 0 or local.y < 0 or local.z < 0 				or local.x >= chunk.dimensions.x 				or local.y >= chunk.dimensions.y 				or local.z >= chunk.dimensions.z:
			continue
		if chunk.get_block(local) != VoxelTypes.AIR_ID:
			continue
		chunk.set_block_raw(local, VoxelTypes.BRANCH_ID)
		if tree.cell_to_branch[cell] == tree.root_branch_id:
			var r: int = TreeGenerator.trunk_radius_at(tree, cell)
			if r > 1:
				# 生成期写入：不标记玩家修改（审查修复 P1-4——
				# 曾把纯生成区块持久化+阻碍生成器升级重建）
				chunk.set_state(local, "radius", r, true)
	# 树叶占位
	for leaf in TreeGenerator.leaf_cells(tree):
		var local: Vector3i = leaf - origin
		if local.x < 0 or local.y < 0 or local.z < 0 				or local.x >= chunk.dimensions.x 				or local.y >= chunk.dimensions.y 				or local.z >= chunk.dimensions.z:
			continue
		if chunk.get_block(local) == VoxelTypes.AIR_ID:
			chunk.set_block_raw(local, VoxelTypes.LEAVES_ID)


## 确定性重放一棵树并只把落在本 chunk 的格写入（跨层/跨区块树
