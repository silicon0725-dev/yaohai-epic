# Chisels & Bits v26.1 源码研究报告

> 2026-10-28 整理。研究对象：Chisels-and-Bits-version-26.1.zip（源码仓库，
> MultiLoader 架构：api / core / fabric / neoforge 四模块，core 主体约 1200 个
> Java 文件）。目的：评估"方块级微雕刻"（每方块 16³ = 4096 微位 bit）对我们
> 体素引擎的参考价值，形成思想库。**本轮为纯研究，不含实现改动。**

---

## 一、这个 Mod 是什么

Chisels & Bits（C&B）是 Minecraft 方块雕刻 mod 的祖师爷：把一个普通方块
"凿开"成 16×16×16 个 1/16 尺寸的微位（bit），每个 bit 可以独立放置/移除，
并继承其来源方块的材质。玩家用它做浮雕、雕像、家具细节。核心体验 =
**体素分辨率从 1 格提升到 1/16 格**。

## 二、架构解构（按子系统，含源码定位）

### 2.1 位存储：调色板 + BitSet 打包

`api/src/main/java/mod/chiselsandbits/api/block/storage/StateEntryStorage.java`（440 行）

- 每个雕刻方块 = `StateEntryPalette`（块内出现过的材质列表）+ `BitSet data`
- 每格定长 `entryWidth = ceil(log2(palette.size()))` 位（`LongMath.log2` 向上取整）
- 4096 格全量打包；空块（全空气）palette 为空、data 为空 BitSet，零成本
- 序列化三通道并存：NBT Codec（存档）、StreamCodec（网络）、LEGACY_CODEC（旧档迁移）

**与我们引擎的关系**：与 `persistence/chunk_serializer.gd` 的调色板方案完全同构
——他们的"微方块存储"就是我们"区块存储"缩小 4096 倍的同款实现。概念零翻译成本，
我们已有的存储基建直接印证了这条路是对的。

### 2.2 增量统计表（最精妙的部分）

`core/src/main/java/mod/chiselsandbits/block/entities/ChiseledBlockEntity.java`
（1774 行，第 1075–1380 行区间是统计核心）

每次增/删一个 bit **不重扫 4096 格**，而是维护一组运行和：

| 字段 | 用途 |
|---|---|
| `countMap: Map<BlockInformation, int>` | 各材质计数 → 推导 `primaryState`（主材质，决定工具行为/掉落） |
| `totalLightLevel: int` | 发光 bit 累加（每 bit 加/减其来源方块的光照值） |
| `totalLightBlockLevel: int` | 遮光 bit 累加 |
| `collisionData: Map<CollisionType, BitSet>` | 按碰撞类型分桶的占用位图 |
| `columnStatisticsTable` | 按 xz 列的统计（天光列语义：每列最高实心 bit） |

增删路径对称（1280 行加、1334 行减），撤销/重做直接走同一条增减逻辑。

**可平移思想**：派生数据用"增量维护运行和"而非"变更后重扫"。我们的
chunk 流水线（水位表预收集、edit_serial 过期检查）同族，此模式可推广。

### 2.3 分数光照（对外表现）

同文件 1213–1218 行：

```java
public float getLightEmissionFactor() {
    // 全填充模式：按 4096 平均
    return this.totalLightLevel / (float) StateEntrySize.current().getBitsPerBlock();
    // 仅已用 bit 模式：return totalLightLevel / (float) totalUsedBlockCount;
}
```

雕刻方块对 Minecraft 逐格光照系统表现为**分数发光/遮光值**——发光强度 =
发光 bit 的占比加权，而不是整个方块突然变成光源。

**对我们光照系统的意义**：我们 BFS 光照的 `LIGHT_OPACITY` 表是逐方块常量。
若将来做部分方块（半砖/楼梯/栅栏），其 opacity 可按占据比例折算（如楼梯
0.5、栅栏 0.15）——BFS 的 `max(1, opacity)` 步进天然兼容，方块光通道的
emission 同理。**这是本报告中无需雕刻系统即可单独落地的最高价值点。**

### 2.4 网格：三轴贪心 + 带符号材质索引 mask

`core/src/main/java/mod/chiselsandbits/client/model/meshing/GreedyMeshBuilder.java`（227 行）

经典 0FPS 三轴贪心（我们 `meshing/greedy_mesher.gd` 同族），亮点在 mask 编码：

- `mask[i] = 正数` → 朝 A 侧的面，值为**材质索引**（动态构建的
  `Object2IntMap<BlockInformation>`，空气固定为 0）
- `mask[i] = 负数` → 朝 B 侧的面，值为对方材质索引取负
- `mask[i] = 0` → 两侧同实同虚（无面）

一次扫描同时完成**跨材质面剔除**与**同材质贪心合并**；合并的 width/height
扩展只在同材质同向时进行（`computeWidth/computeHeight` 逐格比对 mask 值）。

**对我们**：我们的 greedy mask 用 tile 索引合并——C&B 证明"材质索引进 mask"
在动态材质集合下同样成立。若做多分辨率网格可整套参考。

### 2.5 邻居感知：面剔除跨雕刻块

`core/src/main/java/mod/chiselsandbits/neighborhood/BlockNeighborhood*.java`

每方向（6 面）一个 `BlockNeighborhoodEntry`：普通邻居拿 BlockInformation、
雕刻邻居拿 `IAreaAccessor`（可按 bit 查询）。效果：两个相邻雕刻块的贴合面
只在"双方对应 bit 都实心"时不出面——雕刻块之间无接缝冗余面。

**对我们**：等价于我们的 `collect_neighbors` 27 邻域 + 面剔除判定的
细粒度版。思路相通，粒度问题。

### 2.6 撤销：前后快照对

`core/src/main/java/mod/chiselsandbits/change/changes/BitChange.java`：

```java
private final BlockPos blockPos;
private final IMultiStateSnapshot before;
private final IMultiStateSnapshot after;
```

一次雕刻 = 记录受影响方块的前后整块快照；`CombinedChange` 组合多块变更。
简单粗暴但绝对正确——不需要理解变更内容即可还原。

**对我们**：将来做建造模式编辑器/创造模式批量工具时的低成本撤销方案
（对齐我们已有的 sparse_block_states 快照能力）。

### 2.7 存档：专用守护线程池

`core/src/main/java/mod/chiselsandbits/storage/MultiThreadAwareStorageEngine.java`

方块实体序列化在固定大小守护线程池（配置项 `blockSaveThreadCount`）异步执行，
`CompletableFuture` 返回；线程带主类 ClassLoader（避免 mod 加载器坑）。

**对我们**：与我们"生成 worker 线程 + 主线程提交"纪律一致，得到印证。

### 2.8 雕刻模式族（UX 层）

`core/src/main/java/mod/chiselsandbits/chiseling/modes/` 七族：
`cubed`（按整 bit）、`sphere`（球形笔刷）、`plane`/`line`/`draw`（平面/线/连续
绘制）、`connected`（连通同类材质）、`replace`（替换材质）。模式决定一次点击
命中哪些 bit，与存储/网格完全解耦——纯交互层设计。

## 三、参考价值结论

### 可平移复用的思想（按价值排序）

| # | 思想 | 落地时机 | 前置条件 |
|---|---|---|---|
| 1 | **分数不透明度/发光**：LIGHT_OPACITY 按方块占据比例折算 | 做半砖/楼梯/栅栏等部分方块时 | 无，BFS 已兼容 |
| 2 | **增量统计表**：派生数据维护运行和而非重扫 | 任何高频派生数据场景 | 无 |
| 3 | **带符号材质索引 mask 贪心** | 多分辨率/动态材质网格 | 无 |
| 4 | **撤销 = 前后快照对** | 建造模式编辑器 | sparse 状态已有 |
| 5 | **调色板+位打包存储** | 已有（chunk_serializer），印证 | — |
| 6 | **异步存档线程池** | 已有同款纪律，印证 | — |

### 不建议近期做的：完整雕刻系统

4096 位雕刻是 C&B 的全部存在意义，但对体素 RPG 是重投入方向，成本集中在：

- **网格量**：一个雕刻方块最多 4096 格贪心（我们一个区块 16³ 才到这个量级
  的网格复杂度），雕刻密度高的区域网格成本 ×N
- **碰撞**：需要位级 AABB 合并（他们的 VoxelShapeUtils 做旋转/合并工具族），
  Godot 侧要自建合并策略
- **交互精度**：射线要在 1/16 格上求交，选择/预览/放置三态 UI 全套
- **存档膨胀**：每个雕刻方块一条 palette+bit 数据（调色板方案已最优，但量级
  仍是普通方块的数十倍）
- **双分辨率融合**：与我们现有区块贪心网格器、水面角点系统、体素光照 BFS
  的采样粒度全部要协调

**判断标准**：除非"雕刻玩法"进入设计蓝图（比如装饰/建造玩法成为核心循环），
这份研究的定位是思想库而非实现计划。若立项，建议从"装饰性雕刻方块"
（不可碰撞、不参与光照 BFS 的纯表现层 bit）起步降低系统耦合。

## 四、源码位置备忘

解包目录（临时）：`C:/Users/Administrator/Downloads/_cnb_tmp/Chisels-and-Bits-version-26.1/`
原始压缩包：`C:/Users/Administrator/Downloads/Chisels-and-Bits-version-26.1.zip`

```
api/src/main/java/mod/chiselsandbits/api/
  block/storage/StateEntryStorage.java      # 位存储（调色板+BitSet）
  block/storage/StateEntryPalette.java
  multistate/StateEntrySize.java            # 1/16 尺寸定义
core/src/main/java/mod/chiselsandbits/
  block/entities/ChiseledBlockEntity.java   # 统计表/分数光照/主材质
  client/model/meshing/GreedyMeshBuilder.java  # 带符号材质 mask 贪心
  neighborhood/BlockNeighborhood*.java      # 跨雕刻块面剔除
  change/changes/BitChange.java             # 快照对撤销
  storage/MultiThreadAwareStorageEngine.java # 异步存档线程池
  chiseling/modes/                          # 七族雕刻模式
  utils/VoxelShapeUtils.java                # 碰撞形状工具
```
