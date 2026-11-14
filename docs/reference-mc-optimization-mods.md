# Minecraft Java 优化生态调研（2026-11-14）

调研背景：Minecraft 十多年体素工程经验浓缩在优化 mod 生态里。本报告调研 6 个指定项目（Sodium/Starlight/Lithium/FerriteCore/ImmediatelyFast/Fabulously-Optimized）+ 追加侦察 12 个，为瑶海 EPIC 提炼可落地技术。全部结论来自 gh api + tarball 源码精读，来源标注在文中。

自家对照基线：Godot 4.7.2 mono；16³ chunk、512 高垂直流式、视距 16 + 三级远景壳 4096；光照阶段 2 已做 BFS 天光/方块光 + 块级脏集合局部失效（待办：跨块减光兜底、火把光源方块、加载 7.4s）；水 CA 0.25s tick / 512 格上限（欠采样）；掉落实体上限 128；无生物；单机。

## 一、项目速览表

| 项目 | Stars | 状态 | License | 一句话 |
|---|---|---|---|---|
| CaffeineMC/sodium | 5853 | 极活跃 | **PolyForm Shield（禁竞争性使用，非 OSI）**；0.5.x 老版 LGPL-3 | 整套地形渲染管线重写 |
| PaperMC/Starlight | 1252 | **已归档 2024-03**（活在 Paper/Moonrise 里） | LGPL-3.0 | 光照引擎重写，减光最高 44× |
| CaffeineMC/lithium | 2194 | 活跃 | LGPL-3.0 | 游戏逻辑零行为变化优化 |
| malte0811/FerriteCore | 416 | 活跃 | **MIT** | 内存去重（无 NBT 压缩——纠正传言） |
| RaphiMC/ImmediatelyFast | 351 | 活跃 | LGPL-3.0 | immediate mode 渲染批处理 |
| Fabulously-Optimized | 1189 | 活跃 | BSD-3 | 整合包=社区公认优化目录 |
| RelativityMC/ScalableLux | 97 | 活跃 | LGPL-3.0 | Starlight 维护 fork，无状态光照可并行 |
| RelativityMC/C2ME | 825 | 活跃 | LGPL-3.0(部分ARR) | 并行区块生成，线程数=min(核,内存GB×3) |
| Steveplays28/noisium | 145 | 已归档 | LGPL-3.0 | 生成期绕过抽象直写 palette |
| pop4959/Chunky | 763 | 活跃 | GPL-3.0 | 预生成 + 在途配额反压 |
| Tuinity/Moonrise | 310 | 活跃 | GPL-3.0 | Starlight 后继 + chunk/实体系统整体重写 |
| PaperMC/Folia | 4738 | 活跃 | GPL-3.0 | region 化多线程，无主线程 |
| MCRcortex/nvidium | 1039 | 活跃 | LGPL-3.0 | mesh shader GPU 驱动剔除（NVIDIA 专属） |
| tr7zw/EntityCulling | 341 | 活跃 | **自定义禁商用** | 异步射线剔除实体 |
| juliand665/Dynamic-FPS | 306 | 迁 Codeberg（活跃） | **MIT** | 后台窗口降帧（15cycle/s 底循环丢帧） |
| astei/krypton | 402 | 活跃 | LGPL-3.0 | 网络 flush 合并/libdeflate/螺旋发送 |
| embeddedt/ModernFix | 257 | 活跃 | LGPL-3.0 | 启动 2×/动态模型按需加载 |
| SpaceWalkerRS/alternate-current | 262 | 活跃 | **MIT** | 红石建网求解，MSPT 降 20× |

## 二、分主题技术精华

### A. 光照（Starlight → ScalableLux/Moonrise）——正中我们光照阶段 2 待办

原版光照的病根：拉式重算（队列存"待重算位置"，出队读 6 邻居）+ 哈希队列 + 光照数据与 chunk 生命周期分离。

Starlight 核心做法（`common/light/StarLightEngine.java` 等）：
1. **推式 BFS**：队列元素=(位置, 传播光级, 允许方向 bitset)，向邻居推已算好的目标值；**读方块前先比光级**（`current >= level-1` 直接跳过，方块读少 6×）；排除来向永不回查；level≤1 不入队。
2. **减光三规则**（我们的"跨块减光兜底"待办的标准解法）：邻居比目标亮→转增队列带 RECHECK 校验；邻居是发光块→转增队列带 WRITE_LEVEL 写回源值；函数末尾统一跑一遍增光——保证不残留也不误删。
3. **int64 队列打包**：坐标｜光级｜方向 bitset｜3 个标志位，`long[]` 数组 FIFO，翻倍扩容。
4. **SWMRNibbleArray 四态**：每 16³ section 一块 2048B（4096 格 ×4bit）；NULL（不存在读 0）/UNINIT（全 0 不分配）/INIT/HIDDEN；单写多读双缓冲（updating 写 COW、volatile visible 读，任务末 updateVisible 提交）。
5. **空 section extrude 语义**：天光 NULL section ≡ 上方最近非 NULL nibble 的 y=0 行；照明时整段跳过空 section。
6. **天光列式增量**：每列记最高变化 Y，重新下探 + 旧源整列批量入减队列；**值设置延迟到源收集完**（防半更新状态被读到）。
7. **边界面一致性校验 checkChunkEdge**："何时触发邻块重算"的答案——邻块就绪时对 16×16 接触面**逐格拉算期望值 vs 存储值**，不等则当方块变化入队；先收集后提交。
8. **3×3 扁平工作缓存**：邻 chunk section/nibble 指针装平数组（5×5×H），热路径零哈希。
9. 量化：移除光源 block gets 44×、纯传播 ~28×；1.20 起原版吸收了推式双队列与天光专用路径两大思想。

ScalableLux 论点：**光照的无状态性（数据挂 chunk 生命周期）决定区块流水线并行上限**——光照是并行 worldgen 的瓶颈。引擎对象池化复用。
火把待办直接参考：`BlockStarLightEngine.checkBlock`（约 30 行，发光方块读 emission 入增队列）。

### B. 渲染（Sodium 为核心）

Sodium 架构：RenderSection(16³) → **RenderRegion(8×4×8 sections)** 为 buffer/draw 分组单位 → 三 pass（SOLID/CUTOUT/TRANSLUCENT）；OpenGL multidraw / Vulkan indirect。

1. **section 连通性 64-bit 位编码 + BFS 图剔除**：构建时 flood-fill 算 6面→6面空气连通性编码进一个 long；实心方块 <256（数学上不可能隔断）直接全可见跳过 flood-fill。查询纯位运算把入方向集折叠成出方向集。
2. **三级精度剔除树**：WIDE（相机在相邻 chunk 内有效）/REGULAR/LOCAL；相机没跨 chunk 时复用上一轮结果——"相机不动就零剔除开销"。
3. **异步剔除**：专用单线程 + CancellationToken；结果莫顿码 bitset 树；新 section mesh 完成立即 patch 进当前剔除树（不闪空洞）。
4. **射线遮挡**：>48 格的候选沿视线步进 portal 树验证，带 8 角容差。
5. **透明排序分级**（对体素水/玻璃性价比最高的算法思想）：所有面同法线→按 dot(normal,pos) 一次 radix 排序**永不重排**；quad 间拓扑无环→一次拓扑排序永不重排；否则构建期 BSP 树，运行期跨面时（区间树检测相机越过哪些面平面）只**遍历树写索引 buffer，不动顶点、无比较排序**。
6. **region×pass 一条 multidraw**；命令跨帧缓存（相机与列表没变就整帧零命令构建）；**全局共享 quad 索引 + baseVertex**；facing 7 组几何布局 + 背向组整组位掩码剔除。
7. **20 字节量化顶点**：位置 20bit section 相对 + UV RG16（半 texel 收缩只存符号位，渗色 epsilon 挪进 shader）+ light/material/section 打包 RGBA8_UINT。
8. **显存 arena 子分配**：free-list best-fit + 渐进碎片整理（每帧预算搬移）+ 持久映射 staging 环形 buffer（连续上传合并成单条 copy，fence 分代回收）。
9. **构建预算**（micro-stutter 消除的来源）：时长估算器（指数衰减线性回归）按 section 内容估 mesh 耗时；每帧只提交预计总时长 ≤ 线程数×帧时长的任务；上传侧第二预算 max(30% 帧时长, 2ms)；三级推迟（重要/半重要/延后）+ 渲染线程可偷任务。

EntityCulling（⚠ license 禁商用，只学思想）：异步线程对实体做视线可见性，**主线程每几 tick 采样一次**，渲染帧只消费上一轮结果；体素世界里用 DDA 网格射线几乎免费；可见性结果同时削减客户端 tick。
Nvidium：mesh shader 全 GPU 驱动剔除（远期路线参考，NVIDIA 专属）。

### C. 逻辑与调度（Lithium + Alternate Current）

Lithium 通用思想（ mixin 全部标注"不改变玩法"）：
1. **不可变方块类型上预计算派生属性**：BlockState 单例上挂 pathNodeType 缓存/位标志——一切"这格子什么性质"的查询注册期算好 O(1) 读。
2. **section 级计数器基础设施**（block_tracking）：每 16³ 分区维护"是否含某类方块"计数（RANDOM_TICKING / PATH_NOT_OPEN / OVERSIZED_SHAPE），放块/破坏 ±1 增量维护；一处数据喂碰撞扫描（跳空区+免外扩）、寻路邻居检查（整段跳过）、随机刻三个系统。
3. **随机刻重构**：section 精确维护可随机刻方块数 N；N≤384 时先按 N/4096 概率命中再**直接均匀抽第 n 个**（分布逐位等价）；定位用 17 个迷你区两级计数（248 格/区 + 11 字节计数字节组）；N>384 回退原版——按密度切换算法 + 实测阈值。
4. **BlockEntity 睡眠系统**：熔炉/漏斗/潜影盒等平时挂空 ticker，**被事件唤醒**（setChanged、邻库存变化、实体进入范围、到时）；漏斗三套订阅（实体 AABB 进入/库存变化/组件计数）。
5. **碰撞四技巧**：实体碰撞推迟（方块已挡住就不查实体箱）；下落先只查脚下支撑块；单轴移动包围盒收缩成薄片；惰性方块碰撞列表。整方块碰撞=6 个 double 比较，绕过 VoxelShape；section 无 OVERSIZED 形状时搜索不外扩 1 格。
6. **掉落物合并分桶**：按 ItemStack 分桶 O(n²)→桶内；半满/全满细分；**数量 <10 不启用分桶**（小列表直接遍历更快）。
7. **计划刻队列**：tick 打包 int，按到期时间分桶 + 桶内数组队列**惰性排序**（offer O(1)，几乎总按序加入所以几乎不排）。
8. **反面教材**：原版温度缓存"比直接算还慢且命中率低"，直接删掉——**缓存要有证据，否则删**。
9. **重要否定结论：Lithium 没动 A\* 本体**（堆/启发式/去重都没改）——寻路热点全在节点求值与方块读取。未来我们做生物 AI 的设计教训：先缓存节点类型、先做 section 计数跳过、寻路区块数据拷扁平局部数组，别先优化堆。

Alternate Current（红石，MIT）：**网格传播系统的正确抽象=建网络→找源→从源头求稳定值→只在终值时一次性提交**；原版每根线变功率发 42 次方块更新（18 次冗余）削到 24+6。可推广到一切体素网格上的状态传播（信号/流体/光照）。

### D. 内存（FerriteCore，MIT）

- 我们方块存 int id 已经是 FerriteCore 优化的终点形态（int 即压缩索引），BlockState 组合爆炸不存在。
- 仍适用的思想：空容器共享只读单例（空 patch map）；**规范实例去重**（内容相同的 shape/模型共享实例——Godot 里对应共享 Shape/ArrayMesh 引用）；警惕"安全冗余"对象随区块数线性放大（每 chunk 挂调试对象→全局单例+每 chunk 一个 byte）；lambda/Callable 捕获对象在热路径上的寿命延长。
- 纠正传言：当前 HEAD 无 NBT 压缩优化（旧版部分思想已被 Mojang 吸收）。

### E. 区块系统与并行（C2ME / Noisium / Chunky / Moonrise / Folia / Krypton）

- **C2ME 线程数公式**：`min(物理核数约束, (内存GB-0.5~1.0)×3)`——内存是隐藏上限；并行 worldgen 配"未定义行为消毒"检测器。
- **Noisium**：生成期绕过方块抽象层**直写 palette 存储**——批量生成写与玩家交互写分成两条路径（后者才有事件/光照钩子）。
- **Chunky**：预生成用"在途区块配额"（默认 50）而非裸线程数做反压；生成后 `tickingLoadDuration` 稳定期让流体沉降再卸载。
- **Moonrise**：区块系统当独立子系统整体设计；低核自动降并行度；**禁止 tick 补偿追帧**（卡顿后不狂追）。
- **Folia**：region 独立 tick loop 无主线程；**数据所有权 + 跨区访问当场断言**（血泪工程结论）；线程按子系统预算切分留 20% 余量。
- **Krypton**：flush 合并发包；压缩选型 libdeflate；**区块按螺旋顺序优先发送**。

### F. 体验类（Dynamic FPS + FO 目录反推）

- Dynamic FPS（MIT）：后台/失焦/遮挡降帧；实现讲究——**底循环率 15 cycle/s + 丢帧**（1FPS=15 帧丢 14 帧），比长 sleep 恢复延迟低一个量级；加载遮罩盖画面时干脆停渲染世界。
- FO 目录反推社区共识优先级：①渲染管线重写 ②逻辑+内存 ③剔除不可见物 ④immediate mode 小物件 ⑤空闲降载 ⑥光照（1.20 起被原版吸收，社区不再需要）⑦启动时间（一次性）。**"曾经独立成 mod 的光照优化最终进了原版"——印证光照值得做到极致。**

## 三、对我们的落地清单（对接现有系统与待办）

### P0 —— 正中当前待办

1. **光照推式 BFS + 减光三规则**（Starlight §A1-A2）：对接"跨块减光兜底"待办与"火把光源方块"待办（checkBlock≈30 行参考）。GDScript 64 位 int 可直接照抄位布局，`PackedInt64Array` 做队列。
2. **光照 nibble 四态 + 空 section extrude**（§A4-A5）：512 高=32 section/列，空 section 不分配内存（UNINIT），天光空段语义化——内存与传播双收益。
3. **方块 id 位标志 + section 计数器**（Lithium §C1-C2）：IS_SOLID/IS_LIQUID/RANDOM_TICKABLE/OVERSIZED/TREE_PART 一个 int 按 id 索引；section 级含水量/活跃水位格计数增量维护——一次性地基投资，喂水 CA/未来寻路/未来生物。

### P1 —— 性能主战场

4. **水 CA 事件驱动化**（Lithium 睡眠系统 + Alternate Current 范式）：静止格出队、邻域变化才入队，替代 512 格/tick 欠采样；"网络级求解+终值单次提交"对照我们"供给只降不升"语义。
5. **section 连通性位编码 + BFS 异步剔除**（Sodium §B1-B3）：对高视距 16+远景壳是最大单项；三级精度树"相机不动零开销"；与三级远景壳天然契合（每级壳一棵粗粒度树）。
6. **构建预算估算器 + 上传预算**（Sodium §B9）：对接"抖动立项卡"——时长估算（指数衰减回归）+ 提交预算（线程×帧时长）+ 上传预算（30% 帧时长）。
7. **透明排序分级**（Sodium §B5）：水面同法线面一次排序永久有效——可能是性价比最高的一条；BSP 遍历只写索引不动顶点。
8. **边界面校验触发邻块重算**（§A7）：替代"猜测影响范围"，邻块就绪时逐格验证接触面。

### P2 —— 玩法扩展与远期

9. **未来生物 AI**：节点类型缓存（位标志）+ section 计数跳过 + 寻路数据拷扁平数组；**不要先优化 A\* 堆**；感知降频+记忆变更计数；EntityCulling 思想的异步 DDA 可见性（未来实体多时）。
10. **掉落物分桶合并**（<10 不启用）+ **计划刻分桶惰性排序**（水位 tick 队列结构）。
11. **后台窗口降帧**（Dynamic FPS 思想）：Godot 检测窗口失焦/最小化降帧 + 底循环丢帧——低成本体感优化。
12. **加载 7.4s 优化**对接 ModernFix 思想：资源惰性按需加载 + 去重，审视启动期全量预加载。
13. **新世界预生成**（Chunky 思想）：开图前离线预生成 + 在途配额 + 流体沉降稳定期。
14. **顶点 20B 量化 + 共享 quad 索引**（Sodium §B6-B7）：Godot CUSTOM0 通道可行，网格桥 7KB 之后的下一档。
15. 远期评估：碰撞单 cuboid 数值扫掠（我们已有碰撞分级，需先 bench 对比再动）；mesh shader 剔除（Nvidium）；Folia 式分区 tick + 所有权断言（若做多人）。

## 四、许可证红线

- **只学思想（算法/数据布局/伪代码自行实现）无义务**——这是默认路径，本报告全部内容按此使用。
- **Sodium 现行 PolyForm Shield**：非 OSI，禁竞争性使用；0.5.x 老版 LGPL 但架构已大变——一律不搬代码。
- **逐行翻译即衍生**：LGPL-3.0（Starlight/Lithium/ScalableLux/ImmediatelyFast/Krypton/ModernFix/C2ME）与 GPL-3.0（Moonrise/Folia/Chunky）逐行移植需开源该部分——闭源项目禁止直译，尤其注意 Lithium 随机刻等价性论证、Starlight 减光三规则这类"看似简单实则调过参"的代码最易诱发抄写。
- **MIT 干净**：FerriteCore、Alternate Current、Dynamic FPS。
- **自定义禁商用**：EntityCulling（tr7zw Protective License）。
