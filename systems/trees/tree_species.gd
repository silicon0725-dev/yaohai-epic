## 树种配置（结构化树系统 v2：GrowSignal 生长模拟参数包）。
## 只读数据 Resource：生长几何规则与方块绑定。Inspector 可调。
## 参数语义源自 DynamicTrees 研究（docs/reference-dynamic-trees.md）：
## 概率地图选向 + 能量预算 + 面积守恒加粗。
@tool
class_name TreeSpecies
extends Resource

@export var species_id: StringName = &"oak"
## 树干/树叶方块名（占位方块与掉落结算用）
@export var wood_block_name: StringName = &"core:branch"
@export var leaf_block_name: StringName = &"core:leaves"
## 掉落物品名（砍伐结算）
@export var log_item_name: StringName = &"core:log"
@export var stick_item_name: StringName = &"core:stick"

## 主干目标高度（格，±height_variation 抖动；生长能量由此推导）
@export var trunk_height: int = 10
## 高度抖动幅度（格，同种子同树保持确定性）
@export var height_variation: int = 2
## 主干半径上限（面积守恒结果的 clamp 顶；底粗顶细由子枝面积导出，
## 不再手工指定——trunk_top_radius 字段废弃保留兼容）
@export var trunk_base_radius: int = 4
@export var trunk_top_radius: int = 1
## 最低枝高度（格，之下主干强制垂直向上——无低处枝）
@export var lowest_branch_height: int = 6
## 分叉概率（主干/一级枝每步；二级枝为末梢不再分叉）
@export var fork_probability: float = 0.32
## 每树分叉预算上限（防极端树冠爆炸）
@export var max_forks: int = 9
## 分叉时子信号能量除数（越大侧枝越短——云杉类用 3+ 造锥形）
@export var energy_divisor: float = 1.8
## 信号能量=主干高度+该冗余（侧枝预算）
@export var energy_padding: int = 3
## 惯性权重（沿当前方向继续的加成——枝条走直线的倾向；低值
## 产生单格转向楼梯段，网格碎、二级挂点拥挤）
@export var current_dir_probability: int = 5
## 主干向上权重（越低树冠越开张/越高越尖塔）
@export var up_probability: int = 8
## 一级枝向上权重系数（0-1：侧枝信号把 up_probability 乘该系数。
## oak 形态语言=中段纯水平+末梢向光上翘（0）；垂枝类物种可调高）
@export var branch_up_factor: float = 0.0
## 面积守恒锥度（每格加粗量；DT oak=0.3，世界生成 ×1.5）
@export var tapering: float = 0.3
## 树冠水平影响半径（生命周期引用计数用，生成器常量 TREE_REACH 同源）
@export var reach: int = 4
## 叶冠：末梢叶球半径 / 主干顶叶球半径
@export var leaf_ball_radius: int = 2
@export var crown_radius: int = 2
