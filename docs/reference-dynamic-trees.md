# DynamicTrees（1.21.1）源码研究与落地映射

> 源码包：`DynamicTrees-release-1.21.1`（GitHub release zip，466 个 Java 文件，
> common/fabric/neoforge 三模块）。本机解压于 `F:\dt_ref\`（仓库外，不入库）。
> 研究目的：优化本项目树系统 + 为多生物群系铺路。
> 行号均相对 `common/src/main/java/com/dtteam/dynamictrees/`。

## 0. 一句话总结

DynamicTrees = **生长模拟器（GrowSignal）+ 世界生成快照（JoCode）+ 生态适配层
（BiomeDatabase/泊松盘）**。运行时树会真的长（根土 randomTick 发信号），世界生成
**不跑模拟**而是从 JoCode 库按树冠档位盖章。对我们最有价值的三块：生长信号
算法（树形质量）、密度→泊松盘半径→树形档位的**三合一生成链**（生物群系骨架）、
气候适应度表（多群系树种分布）。

## 1. 运行时生长：GrowSignal（systems/GrowSignal.java + BasicBranchBlock）

### 1.1 信号（GrowSignal.java:8-81）

前向数据：`energy`（默认 16，Species.java:236；每步 -1，耗尽=失败）、`dir`、
`numTurns`（转向次数，0=主干）、`numSteps`。回传数据：`radius`（枝端回传的
半径，供父枝加粗）、`tapering`（锥度，默认 0.3）、`success`、`choked`
（空间不足憋死——setRadius 被邻居挡住时置位，停止一切加粗）。

### 1.2 方向选择：概率地图（GrowthLogicKit.java:70-134）

每步构造 6 向概率地图后加权抽取：
- `defaultDir(UP) += species.upProbability`（不是从下方来时）；
- `当前方向 += probabilityForCurrentDir`（惯性——枝条走直线）；
- 其余方向 += **目标格内容物的吸引值**（`probabilityForBlock`）：
  空气 1、叶子 2、**同树枝干 radius+2**（粗枝吸引融合生长，树冠自聚拢）；
- `lowestBranchHeight` 以下强制 UP（防枝条接地）。

树种特异性=GrowthLogicKit 子类改概率地图。例 ConiferLogic.java:57-77：
禁 DOWN；主干只允许 UP；水平 2 概率仅当"非主干 或 奇数步且半径>1"
（云杉的轮生枝节奏）；**出主干瞬间 `energy /= 3`、水平余能钳 16**
（能量=剩余生长预算，除法器直接造出锥形——侧枝越低越长）；
高度按坐标 hash 抖动（HEIGHT_VARIATION=5，同地不同月不同高）。

### 1.3 半径：面积守恒（BasicBranchBlock.java:326-352）

信号回程（DFS 回溯）逐节点执行：

```
areaAccum = Σ(子枝半径²)            # 来自刚返回的信号 + 扫描其余 5 向同树枝干
radius = clamp(sqrt(areaAccum) + tapering, 当前半径, max)
```

**只粗不细**（下限=当前半径）——砍枝不会瞬间瘦身。这是"枝干粗细有分支
语义"的根源：主干粗=它要供养的子枝总面积大。世界生成版 InflatorNode 同
公式但 tapering×1.5（Species.java:2286-2288，一次性生成更粗壮），且侧枝
上限 8、主干柱内才允许到 species max。

### 1.4 长枝/长叶（BasicBranchBlock.java:266-288）

信号进空气格 `growIntoAir`：来自细枝（r=primaryThickness）→只放一片叶子；
来自粗枝→`branchOut`：先验证可长叶+跑一次叶子 BFS，再把叶位替换为新枝
起点（r=secondaryThickness=2）。

## 2. 世界生成：JoCode 快照（worldgen/）

**生成期完全不跑生长模拟**。链路（Explore 报告 §0）：

```
biome 装饰 → 每 chunk 恰一次 dynamic_tree feature
  → 泊松盘（密度→半径 r∈[2,8]）→ 找地面 → speciesSelector 选种 → chance
  → JoCodeRegistry 按半径桶随机挑一棵 → JoCode.generate 盖章
```

### 2.1 JoCode 编码（JoCode.java）

- 指令 3 bit：0-5=六方向步进、6=FORK（开分支）、7=RETURN（回溯）。
  DFS 遍历枝干网络编码；两指令打包 1 个 base64 字符。
- **密度→树形档位三合一**：泊松盘半径（树冠占位）就是 JoCode 库的分桶键
  （每物种 r2..r8 共 7 桶 × 各 16 棵，oak.txt 实测）。地盘大→挑大树代码。
- generate 流程（JoCode.java:155-224）：递归放枝（r=primaryThickness 细枝）
  → analyse 一遍：InflatorNode 加粗 + 把 LeafClusters 模板叶图 blitMax 进
  体素图 → smother 预计算（每列自上而下数叶子，>4 层的抹掉=自然内层
  空洞）→ 放叶（flag 16 防观察者级联）→ ageVolume 迭代（体素图 CA 收敛，
  一般 3 轮）→ handleRot（无支撑端点烂掉）→ postGeneration（GenFeature
  装饰：果实/蜂巢/藤蔓/底部喇叭根…22 种）→ 寒带 biome 加雪。
- 失败兜底：frankentree（两树融合成环）→ 清除双方 + secondChance 重试一次。

### 2.2 泊松盘（systems/poissondisc/）——树距控制

- 盘半径 2..8 格（=树冠半径）。`density→radius`：`size=(1-density)*9`，
  坐标 hash 抖动 ±2，clamp [2,8]（BiomeRadiusCoordinator.java:49-59）。
- 圆碰撞用**预生成位图**：r2..r8 七档 `(2r+1)²` 位圆打包成 int 行，
  逐行 AND 判交（SimpleBitmap）；允许边缘像素接触（内圈位图判深穿）。
- 算法（LevelPoissonDiscProvider.java:72-246）：取 3×3 chunk 已存盘为种子
  → edgeMask 掩掉朝外弧（32 角度槽/圆）→ 三角化（两圆相切坐标表
  PoissonDiscPairData 预计算 28 种组合的环形槽位）迭代填补 → 圆心落本
  chunk 的盘写入 **16 字节/chunk**（4×4 tile×1B：`E|(r-1)<<4|x<<2|z`）。
- 确定性：`RandomXOR.setXOR((x*674365771)^(z*254326997)>>4)` 同 seed 同
  chunk 必同结果——盘不存档也能重算（NBT 存的只是缓存）。
- chance "standard"：`radius>3 ? 2.0/radius : 1.0`（大树天然更稀疏）。

### 2.3 原版树取消（featurecancellation/）

按 biome 从生成步骤 REMOVE 命中 canceller 的 feature（判 config 类型
TreeConfiguration + feature 命名空间）→ 原版树绝不在 DT 世界出现。
（本项目自研生成器无此问题，仅记录。）

## 3. 多生物群系骨架（用户核心诉求）

### 3.1 BiomeDatabase（worldgen/BiomeDatabase.java）

每 biome 一条 Entry，全部可由 treepack JSON 声明（支持 REPLACE/
SPLICE_BEFORE/SPLICE_AFTER 链式合并）：

| 字段 | 语义 | 默认 |
|---|---|---|
| speciesSelector | 树种权重表（森林 `oak:4 birch:1`、丛林 `jungle:15 mega_jungle:3`） | 未处理 |
| densitySelector | 密度 0-1，**可写表达式** `noise()*0.2`（PerlinSimplex 1 octave seed=96 scale=1/128 归一化） | -1 |
| chanceSelector | 该盘最终成树概率（`standard`=2.0/radius） | UNHANDLED |
| forestness | 森林度（种子散布用） | 0 |
| multipass | 多轮再生成（pass1 补 r5、pass2 补 r3——密林两轮加密） | 单 pass |
| CaveRootedData | 洞穴生根树独立选择器（藤蔓倒挂/溶洞树） | 关 |

维度隔离：DIMENSIONAL_DATABASES（下界有独立 fungus 树系）。

### 3.2 气候带与适应度（season/ClimateHelper + Species.biomeSuitability）

温度→气候带（NormalSeasonManager.java:54-94）：<0.2 COLD；≥1.0 ARID；
>0.8 TROPICAL；其余 TEMPERATE。每物种 `preferredClimate`+`climateTolerance`
(0.2)，查 5×5 适应度表（ClimateHelper.java:10-18，如 TEMPERATE 物种在
TROPICAL 0.6、COLD 0.4）得 **biomeSuitability 0-1** → 缩放：soilLongevity
（=suitability×8，长势）、growthRate、种子/果实掉率。热带物种种寒带直接
0.1 倍——**分布约束不靠黑名单，靠生长惩罚**（自然但硬）。

季节（Serene Seasons 联动）：`sin(季节×π/2 + 相位)·幅值+偏置` 各气候带
不同的三因子（生长/落种/结果），无季节 mod 时恒 1。

### 3.3 叶子：水力细胞（block/leaves + systems/cell）

- hydro 0-7 直接存原版 `DISTANCE` blockstate（0=死）。求解是**单次查表**
  不是迭代 CA：BasicSolver 收集 6 邻居输出值直方图，按规则表
  （`0xXHCR`：值 H ≥C 个邻居 → 得 R）**首条命中**（CellKits.java:412-438）。
- 关键设计：**只有 r=1 细枝供水**（DECIDUOUS kit：细枝 NormalCell(5)，
  粗枝给 0）——叶子只长枝梢，树冠自然外密内空。
- 各向异性细胞=查表（MatrixCell：6 面×8 值的 byte 表）：ConiferLeafCell
  向下给 0（针叶不垂供）、PalmFrondCell 只向上传 4（棕榈平展）。
- 光照约束：见天直通；否则需天光≥13（已有叶放宽 2 级=滞回防闪烁）；
  smother：正上方 4 格内树部件超限不长（JoCode.java:398-440 生成期同款）。
- 运行时收敛靠邻居变化调度 tick + BFS（上限 256 格）+ ageVolume 多轮；
  **没有全局 tick 预算**，防雪崩全靠局部门（周围 chunk 加载完才 update、
  低 hydro 降频 1/4、值不变不 setBlock、hydro 变化 flag 4 不通知邻居）。

### 3.4 运行时调度（防性能雪崩的现实答案）

根土 randomTick（原版随机 tick，平均 ~68s/块）→ 50% 被
treeGrowthMultiplier 丢弃 → `Species.update`：一次 FindEndsNode 全树
遍历（DFS 深度上限 32，超限破坏节点=防环）→ rot 检查
（rotChance=0.3+1/r，粗枝抗烂）→ 按 growthRate×季节 概率发 1 个
GrowSignal → 肥力 0-15 随成功递减（1/soilLongevity 概率）。
**一棵树平均 ~4.5 分钟才发一次生长信号**——"动态生长"的真实成本被
随机 tick 天然摊薄。SpeciesBlockEntity 不驱动任何东西（只存物种名）。

## 4. 对照本项目（systems/trees/）的差距与已有优势

### 4.1 本项目已强于 DT 的部分（不动）

| 能力 | 本项目 | DT |
|---|---|---|
| 倒伏 | RigidBody3D 真物理受控倒伏+落地结算 | 假动画（FallingTreeEntity 网格动画） |
| 砍伐 | split+BFS 连通性+失支撑分量即时分离 | 破坏传导+腐烂（慢速） |
| 生命周期 | chunk 列引用计数+确定性重放 | 方块即数据（天然） |
| 光照联动 | 树网格顶点色重烘（光源/遮挡脏标记） | 原版光照直用 |
| mesh | 分叉桥/锥台阴影代理/年轮端面 | SmartModel 连接形状缓存 |

### 4.2 差距（=用户"问题还挺多"的技术面）

1. **树形同族死板**：固定模板（层数×每层根数×水平伸出+上翘），全部树
   一个轮廓。DT 是概率地图+能量+面积守恒——每棵树都不同但都"像那棵树"。
2. **半径无分支语义**：主干线性插值 base→top；侧枝固定 r。DT 的
   sqrt(Σr²) 让粗细=供养面积，视觉上"懂树"。
3. **撒点无最小间距**：hash 密度 0.003 均匀伯努利——会贴脸/重叠/
   稀疏带（泊松盘的存在意义）；密度是常数，与地形/群系无关。
4. **单物种**：TreeSpecies 只有一份 oak 参数，无物种框架、无 per-biome
   选择。DT 的 Family(方块绑定)/Species(生态+生长) 双层可借鉴。
5. **叶子不贴枝**：末梢叶球+随机镂空；内层不掏空（无 smother），叶与
   枝的空间关系是"球贴在端点"而非"枝梢供水的冠"。

### 4.3 落地映射（建议采纳）

| DT 机制 | 落地方式 | 成本 |
|---|---|---|
| GrowSignal 概率地图+能量 | **生成期跑一次确定性模拟**（同 seed 同树），替代固定模板。不需要运行时 tick——我们的树是一次性生成的静态结构+砍伐管线 | 中：TreeGenerator 重写核心 ~200 行 |
| 面积守恒加粗 | 同上，回程一遍 DFS。现有 BranchNode 半径字段直接受益（mesh_builder 无需改） | 低 |
| 泊松盘 | 简化版：盘半径=物种树冠半径+hash 抖动，3×3 chunk 种子迭代；可先做"最小间距网格 jitter"（一档），完整弧掩码三角化后置 | 低→中 |
| density/speciesSelector | per-biome 密度函数 + 权重表（接地形噪声栈 terrain v8 群系判定） | 中（依赖群系先落地） |
| 气候适应度表 | 5×5 表直接搬；等群系温度/湿度维度有了再接 | 低（查表） |
| 叶子贴枝+内层掏空 | 生成期"距最近枝梢的距离场"（≤hydro 阈值留叶）+每列 smother 掏空；完整水力 CA 后置 | 中 |
| Conifer 式 kit 参数 | 物种参数包：up_prob/tapering/energy_divisor/lowest_branch_height/水平限幅——多物种=多参数包+可选概率地图改写 | 低（数据驱动） |

### 4.4 不搬清单（及理由）

- **JoCode 库/编码**：我们已有更富的枝干图结构（直线段+半径+父子），
  存档走 cut 事件流；快照库是为 MC 方块树+网络同步设计的。
- **运行时生长 tick/肥力/腐烂/疾病**：玩法层（种树/施肥/等待），等
  战斗与生存循环成型后再立项；生成期模拟已拿到 90% 的树形收益。
- **blockstate 编码枝干/形状缓存**：方块级树是 MC 限制，我们是实体
  mesh（已有分叉桥/锥台代理）。
- **FeatureCancellation**：自研生成器无原版树可取消。
- **季节联动**：无季节系统，且与树优化正交。
- **泊松盘的位图圆/三角化坐标表全套**：过度工程（DT 为 MC 跨 chunk
  确定性+存档 16B 设计）；我们 chunk 内生成期一次算完，简化版够用。

## 5. 量化参数速查（搬参数用）

| 参数 | 值 | 出处 |
|---|---|---|
| signalEnergy | 16.0 | Species.java:236 |
| tapering | 0.3（世界生成 ×1.5） | Species.java:222 / :2286 |
| primaryThickness(细枝) | 1 | Family.java:599 |
| secondaryThickness(新枝) | 2 | Family.java:600 |
| maxBranchRadius | 8（=整格；thick 树 24 配 TrunkShell） | Species.java:260 |
| 盘半径范围 | 2..8；density→(1-d)×9 clamp | BiomeRadiusCoordinator.java |
| 大树 chance | radius>3 ? 2.0/radius : 1.0 | ChanceSelectorDeserializer:78 |
| smother 层数 | 4 | LeavesProperties 默认 |
| 叶天光需求 | 13（已有叶 +2 滞回） | DynamicLeavesBlock.java:331 |
| 水力值域 | 0-7；DECIDUOUS 细枝供水值 5 | CellKits.java:14-57 |
| 适应度表 | TEMPERATE 行：TROPICAL 0.6 / COLD 0.4；TROPICAL 行：COLD 0.1 | ClimateHelper.java:10 |
| rotChance | 0.3 + 1/radius | Species.java:1516 |
| signal 深度上限 | 32 | Family.java:692 |
| Conifer 出干能量 | energy/=3，水平钳 16 | ConiferLogic.java:60-70 |
| 叶 BFS 上限 | 256 格 | LeavesProperties.java:639 |
