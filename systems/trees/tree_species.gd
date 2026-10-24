## 树种配置（结构化树系统 v1）。
## 只读数据 Resource：生长几何规则与方块绑定。Inspector 可调。
class_name TreeSpecies
extends Resource

@export var species_id: StringName = &"oak"
## 树干/树叶方块名（占位方块与掉落结算用）
@export var wood_block_name: StringName = &"core:branch"
@export var leaf_block_name: StringName = &"core:leaves"
## 掉落物品名（砍伐结算）
@export var log_item_name: StringName = &"core:log"
@export var stick_item_name: StringName = &"core:stick"

## 主干高度（格，种子在 ±20% 内抖动）
@export var trunk_height: int = 10
## 主干底部/顶部半径（1-8；管道逐格线性过渡）
@export var trunk_base_radius: int = 4
@export var trunk_top_radius: int = 1
## 侧枝：层数、每层根数、伸出长度（水平格）、末端上翘格数
@export var branch_layers: int = 3
@export var branches_per_layer: int = 2
@export var branch_length: int = 3
@export var branch_upturn: int = 1
## 侧枝半径（固定 1-2）
@export var branch_radius: int = 1
## 叶冠：末梢叶球半径 / 主干顶叶球半径
@export var leaf_ball_radius: int = 2
@export var crown_radius: int = 2
