# 体素地形内核 — Stage E（性能与资源体系）

Godot 4 体素沙盒游戏的技术原型，开发文档（`docs/DEVELOPMENT_PLAN.md`）
的 **阶段 A-E 全部完成**：静态地形 -> 交互 -> 流式加载 -> 增量存档 ->
基准测试与真实材质包。水平无限世界，14 种方块，Conquest 写实材质包，
Greedy Meshing 可切换。

## 引擎版本锁定

- **Godot 4.7.2.stable.mono.official**（官网构建，安装于 `~/godot/godot`；
  早期使用的 snap 包 `godot-4` 缺少 .NET 数据通道，已弃用）
- 脚本语言：GDScript + C#（Greedy 网格器走 C# 原生路径，见"网格管线 C# 迁移"一节）
- **C# 运行前提**：系统 .NET SDK（本项目面向 net8.0，`voxel-terrain.csproj`
  设置了 `RollForward=LatestMajor`，仅有 .NET 9/10 运行时的机器也能跑）。
  修改 `native/NativeMesher.cs` 后需 `dotnet build voxel-terrain.csproj`
- **渲染器**：项目锁定 `gl_compatibility`。本机 GT 610（Fermi）无 Vulkan
  支持，llvmpipe 软渲染的 Vulkan JIT 会生成 BMI2 指令（本机 2014 年
  赛扬不支持），导致 SIGILL 崩溃；OpenGL 4.3 走这块卡硬件加速，稳定。

## 运行

```bash
cd "<本项目目录>"

# 1. 首次运行前导入（生成 .godot 全局类缓存，git 忽略该目录）
~/godot/godot --headless --path . --import

# 2. 单元测试（headless，无需显示环境；退出码 0 = 全部通过）
~/godot/godot --headless --path . -s tests/run_all_tests.gd

# 3. 运行原型（需要显示环境）
~/godot/godot --path .

# 4. 打开编辑器
~/godot/godot --editor --path .

# 5. 世界统计（headless 冒烟检查：区块数 / 可见面 / 耗时）
~/godot/godot --headless --path . -s debug/world_stats.gd

# 6. 渲染回归检查（需要显示环境；等待流式安定后校验绕序/剔除）
~/godot/godot --path . res://debug/render_check.tscn

# 7. 流式加载集成检查（headless 可跑：加载/卸载/休眠恢复/修改存活）
~/godot/godot --headless --path . res://debug/streaming_check.tscn

# 8. 任意角度截图（等待流式安定，保存到 debug/last_capture.png）
~/godot/godot --path . res://debug/capture.tscn

# 9. 基准套件（headless，§10.3：生成/网格/重网格/存档/区块尺寸）
~/godot/godot --headless --path . -s debug/benchmark.gd

# 10. Greedy Meshing 模式（任意调试场景追加 -- --greedy）
~/godot/godot --path . -- --greedy

# 11. C# 可用性探针（headless 实例化 NativeMesher，验证 .NET 运行时）
~/godot/godot --headless --path . -s debug/probe_csharp.gd

# 12. 强制禁用 C# 原生路径（A/B 基准 / 问题隔离）
VOXEL_NO_NATIVE=1 ~/godot/godot --headless --path . -s debug/benchmark.gd

# 13. 物品层 HUD 布局检查（headless：快捷栏几何/起始装备/背包开关）
~/godot/godot --headless --path . res://debug/items_ui_check.tscn

# 14. 物品层视觉截图（需要显示环境；输出 debug/capture_hud.png 与
#     capture_inventory.png，隔离存档）
~/godot/godot --path . res://debug/capture_items.tscn
```

### 操作（第一人称玩家）

- `WASD` 移动，`Space` 跳跃，`Shift` 疾跑
- 鼠标左键点击窗口锁定视角，`Esc` 释放
- `按住左键` 挖掘（时长由方块硬度与手持工具决定，准星下有进度条；
  基岩不可破坏），`右键` 放置（消耗手持方块物品）
- `1-9, 0` 数字键或 `滚轮` 切换热栏（背包前 12 格），`E` 开关背包界面
  （点击拿起/放下/交换/合并堆；左侧合成面板点击配方行合成，材料
  不足整行置灰）
- 升级闭环：砍原木→合成木板/木棍→木镐→挖石得圆石→石镐
- 新世界起始装备：木镐 + 泥土×16 + 木板×16；石头系需要镐才掉落物品
- 挖穿悬空岛边缘掉落后自动回到出生点
- 修改每 10 秒自动保存，退出时全量保存（含背包）；重启游戏世界原样恢复

## 物品与合成层 v1（玩法扩展第一、二步）

体素内核（阶段 A-E）完成后按开发文档 §1.2 接入物品系统，延续
数据/规则/表现分离：

- **数据层**：`items/item_registry.gd`（与 VoxelRegistry 同构：稳定名称
  `core:stone`/`core:wooden_pickaxe` <-> 数值 ID，存档用稳定名称）；
  `core/item_types.gd` 定义 14 种物品 = 11 方块物品（id 与方块同名，
  放置时消耗 1 个）+ 煤（材料）+ 木镐/石镐（工具，堆叠 1）
- **背包**：`items/inventory.gd`，24 格（前 12 格即快捷栏），堆叠并入/
  开新堆/溢出返回剩余；移动/交换/合并；`changed` 信号驱动 UI
- **挖掘规则**：方块定义新增 `hardness`（徒手秒数，基岩 -1）与
  `requires_tool`（class + min_tier）。`BlockMining.break_info` 综合
  手持工具给出时长与掉落资格：镐挖石头 5.5s→1.375s；徒手/等级不足
  4 倍减速且**不掉落**。玩家控制器按住左键累积进度（换目标即重置），
  准星下进度条可视化
- **掉落表**：`items/drop_table.gd`，草→泥土、石头→圆石、煤矿→煤、
  其余掉自身；掉落直接入包（背包满则告警丢弃，v1 无地面实体）
- **表现层**：`presentation/item_icons.gd`——方块物品从图集裁剪 side
  贴图（材质包替换自动跟随），材料/工具程序化像素画；HUD 快捷栏
  （图标+数量+选中框）、E 键背包界面（点击拿起/放下/交换）
- **存档**：背包随 player_state 序列化（稳定名称，未知名称跳过、
  超上限截断）；旧档无 inventory 键自动补发起始装备（木镐+泥土×16+
  木板×16）——已在真实旧档上验证
- **合成系统**（`items/crafting_recipes.gd`）：v1 无序配方（材料计数
  匹配即合成，无网格摆放），原子性由 craft() 保证（先校验后消耗再
  产出，失败零副作用）。配方链 4 条构成工具升级闭环：
  原木→4 木板；2 木板→4 木棍；3 木板+2 木棍→木镐；
  3 圆石+2 木棍→石镐（挖石得圆石闭环，与 MC 一致需 2 根原木起步）。
  背包界面左侧合成面板：材料不足整行置灰，点击合成一次，
  `inventory.changed` 驱动实时刷新。`Inventory.remove_item` 支持跨堆
  消耗（从末尾堆向前扣）
- **检查**：`tests/test_items.gd` 73 项 + `tests/test_crafting.gd` 63 项
  （配方定义/原子合成/跨堆消耗/升级闭环/背包满丢弃语义）；
  `debug/items_ui_check.tscn` headless 断言 HUD 几何与接线（快捷栏
  580×52 非 0 尺寸、图标内缩、合成面板行数与点击合成等 17 项）；
  `debug/capture_items.tscn` 出游戏 HUD 与背包+合成界面两张截图

## 方块状态持久化（内核扩展，§4.3）

- **状态 API**：`VoxelWorld.get_block_state / set_block_state`（统一入口，
  §8.2）；状态写入推进 edit_serial 并标记待存档；`set_block` 替换方块时
  自动清空旧状态；`affects_mesh` 参数区分"朝向影响贴图"与"纯数据状态"
- **存档格式 v2**：区块文件追加稀疏状态段（局部坐标 + JSON 状态字典，
  值须可 JSON 化）；v1 旧档按版本条件读取，完全兼容
- **首个使用者——原木朝向**：贴顶/底面放置竖放（年轮朝上），贴侧面
  放置横放（端面朝向放置面）；面剔除与贪心两种网格器都按状态选贴图
- 单测覆盖：状态读写/越界/清空、轴向推导、两种网格器的朝向贴图断言、
  序列化往返、v1 旧档兼容、文件级往返

## 方块清单（生成算法 v2）

| 来源 | 方块 |
| --- | --- |
| 地形生成 | 草、泥土、石头、基岩；低地（高度≤8）为沙 + 砂岩地层；石层含煤/铁矿脉（确定性噪声，铁矿更深更稀有） |
| 仅可放置 | 圆石、木板、原木（顶/底年轮、侧面树皮）、砖块、沙砾 |

共 14 种（含空气）。旧存档兼容：调色板按稳定名称存储，新方块不破档；
生成版本 v1 -> v2 后，未修改区域用新算法重建（高度不变，仅材质/矿物差异），
已保存的完整区块数据不受影响。

## Stage A 已实现（对照文档 §12 阶段 A）

| 任务 | 实现 |
| --- | --- |
| 建立项目与版本锁定 | 本文件 + `project.godot` |
| 坐标、方块 ID、区块数据 | `core/`、`world/` |
| 固定大小测试地形 | `generation/terrain_generator.gd`（种子 1337，确定性） |
| `ArrayMesh` 可见面网格 | `meshing/`（面剔除，单区块单网格，非逐方块节点） |
| 简单材质图集 | `presentation/`（程序化占位图集，无第三方授权负担） |

另含：统一世界修改 API（`get_block` / `set_block` / `replace_block`）、
区块边界修改的网格失效传播、区块生命周期状态枚举、dirty 标记——
这些是文档 §8.2、§6.4、§4.3 的要求，虽属阶段 B/C 的运行路径，
但数据接口在 Stage A 即建立并被测试覆盖。

## Stage A 实测数据（headless 调试构建，仅作参考；正式基准在阶段 E）

- 世界：6x3x6 区块（16³），种子 1337，生成版本 1
- 区块 108 个（含可见几何 56 个），可见面 19,994（三角形 39,988）
- 生成 ~0.5 s，网格构建 ~1 s（同步，主线程，GDScript 调试构建）
- 网格构建初版 60 s：逐面世界坐标查询开销过高，改为填充缓存 +
  注册表属性预查后降为 ~1 s，面数不变（测试断言保证语义一致）。
  这属于"先测量、再优化"的一次实践记录，见 `meshing/chunk_mesher.gd` 注释。

## Stage B 已实现（对照文档 §12 阶段 B）

| 任务 | 实现 |
| --- | --- |
| 第一人称测试控制器 | `player/`：两格高一格宽胶囊碰撞体（无模型），重力/跳跃/疾跑 |
| 体素 DDA 射线检测 | `physics/voxel_raycast.gd`：Amanatides & Woo 网格遍历，返回命中方块/法线/距离 |
| 挖掘与放置 | `interaction/`：即时挖掘（基岩不可破）；放置需空气格且不与玩家碰撞体重叠 |
| 受影响网格与碰撞更新 | `presentation/chunk_renderer.gd`：轮询 dirty 标记，只重建被修改区块（网格与碰撞分开标记） |
| 区块碰撞 | `physics/chunk_collision_builder.gd`：可见面 → 单区块 ConcavePolygonShape3D |
| 准星与方块选择 | 纯绘制十字准星；1-4/滚轮切换，HUD 显示当前方块 |

掉落保护：玩家低于基岩层（穿模或掉出已加载边缘）自动回出生点。

## Stage C 已实现（对照文档 §12 阶段 C）

| 任务 | 实现 |
| --- | --- |
| 区块管理器 | `world/chunk_manager.gd`：按玩家位置流式加载/卸载（视距 5 区块半径 + 卸载缓冲 2） |
| 后台生成/网格构建（§10.1） | WorkerThreadPool 工作线程只做纯计算（生成区块数据、网格数组）；主线程验证后创建 ArrayMesh/碰撞形状 |
| 任务队列与过期检查（§4.4） | 入队时快照区块与面邻居的 edit_serial；提交时比对，不匹配即丢弃重排；区块卸载后任务结果作废 |
| 加载优先级与预算（§10.2） | 玩家列 > 视线前方（相机朝向加成）> 近距离；每帧限提交生成 8 / 网格 3，在途上限 32 |
| 区块边界（§6.4） | 邻区块未加载按空气临时处理；数据到达时把已存在邻居标脏重建，网格用真实边界数据 |
| 卸载数据保全（§4.4） | 被玩家修改过的区块卸载时进入休眠缓存，重回视距原样恢复（阶段 D 存档落地前的保底） |
| 世界无限化 | 水平方向无限流式，垂直高度固定（3 区块）；玩家脚下区块未就绪时冻结物理 |

阶段 C 调试过程中修掉的三个代表性缺陷（均有检查兜底）：
网格任务活锁（入队清脏 + 序列号判过期，防止无限重排）、对角邻居序列号
误判（遮挡只读面邻居，比对范围与标脏范围对齐）、出生点区块/方块坐标
混用（统一经 VoxelCoords 换算）。

## Stage D 已实现（对照文档 §12 阶段 D / §9）

| 任务 | 实现 |
| --- | --- |
| 保存种子与生成版本 | `world.json`：格式版本 / 种子 / 生成版本 / 世界配置 / 玩家状态 |
| 保存修改区块 | `persistence/chunk_serializer.gd`：完整数据 + 调色板稳定名称 + zstd 压缩（§2.2 注册表重排不破档） |
| 安全写入与读取（§9.2） | 原子写：`*.tmp` -> 回读校验 -> rename 替换；失败保留旧文件并报错 |
| 存档格式版本 | `persistence/save_migrations.gd`：格式兼容判定 + 生成版本策略（完整区块数据不受生成算法升级影响） |
| 增量存盘时机 | 卸载修改区块即落盘（工作线程加载时优先读盘）+ 10 秒自动保存 + 退出保存 |
| 写盘失败兜底 | 保留内存缓存绝不丢玩家修改（§4.4），下次卸载/自动保存重试写盘 |
| 损坏/不兼容处理（§9.3） | 损坏元数据按新世界处理；损坏区块回退重新生成；未知方块名替换为石头并告警 |

存档位置：`user://saves/world1/`（snap 版即 `~/snap/godot-4/common/...`）。
删除存档 = 删除该目录（或 `WorldSave.erase_all()`）。

## Stage E 已实现（对照文档 §12 阶段 E / §6.3 / §10.3 / §7）

| 任务 | 实现 |
| --- | --- |
| 真实材质包（§7.3 许可证核验） | `assets/textures/`：15 tile 全覆盖，当前为 **Conquest 1.21.11**（32px 写实风，用户提供的本地包，**不可再分发**——发布前按 CREDITS.md 换回 `open_cc0_backup/` 的 CC0/CC BY 组）；TILE_SIZE 随包调整为 32，图集/图标几何全部由常量推导；加载器优先真实贴图、缺失回退程序化占位图 |
| Greedy Meshing（§6.3） | `meshing/greedy_mesher.gd`（与面剔除共用填充缓存/剔除语义）+ 图集平铺着色器（UV2 携带 tile 原点、fract 平铺）；启动加 `-- --greedy` 或设 `ChunkManager.use_greedy_meshing` 切换 |
| 基准测试（§10.3） | `debug/benchmark.gd`：生成吞吐、面剔除 vs 贪心、编辑重网格延迟、存档读写、区块尺寸对比 |
| 区块尺寸对比（§4.1） | 16^3 vs 32^3 同体积实测，维持 16^3（见下表） |

## 阶段 E 实测数据（官方构建 / 2 核 / 调试构建，3 次取中位）

| 指标 | 实测 | 结论 |
| --- | --- | --- |
| 生成 | 13.8 ms/区块（16^3，v2 地形） | 后台线程可接受 |
| 面剔除网格（GDScript） | 9.1 ms/区块（192 区块 31,654 面） | 默认实现 |
| Greedy 网格（C#） | 28.7 ms/区块；面数与顶点均降至 **22.8%** | 较 GDScript 版快 2.4×（62→26 ms）；仍比面剔除慢，保留为开关 |
| 编辑重网格延迟 | 9.0 ms/区块（工作线程，面剔除路径） | 挖掘/放置手感即时 |
| 存档写/读 | 3.7 / 2.5 ms/区块（zstd + 原子写） | 卸载即存盘无压力 |
| 16^3 vs 32^3 | 同体积：生成 1411 vs 1819 ms，网格 1721 vs 1289 ms（面数相同） | 16^3 更优，维持候选值 |

贪心正确性由"四边形总面积 == 面剔除面数"不变量（单测，含真实地形）与
渲染回归检查共同保证；其 T 型交界在双面渲染下有个位像素级 z-fighting
（已计入检查容差并注明）。

## 目录结构（与文档 §3 对应，仅引入当前阶段需要的模块）

```
core/           坐标换算、方块类型/注册表、世界配置
world/          ChunkData、ChunkState、VoxelWorld（统一修改 API）、ChunkManager（流式+存盘）
generation/     固定种子确定性地形生成器
meshing/        可见面剔除（线程安全签名）、贪心网格、C# 桥接、图集 UV、ArrayMesh 构建
physics/        体素 DDA 射线、区块碰撞构建
interaction/    方块挖掘（硬度/工具/掉落规则）、方块放置
items/          物品注册表、槽位背包、掉落表、合成配方
persistence/    ChunkSerializer、WorldSave（原子写）、SaveMigrations
presentation/   程序化占位图集、材质注册表、区块渲染器（被动应用）
player/         第一人称玩家控制器、准星
native/         C# NativeMesher（贪心网格原生路径，Variant 批量互转）
debug/          截图/渲染回归/流式+存档集成检查、世界统计
scenes/         主场景
tests/          轻量单元测试 + headless 运行器
docs/           开发文档
```

## 决策记录

- **脚本语言 GDScript + C#**：逻辑层 GDScript；性能重灾区（Greedy 网格器）
  经阶段 E 基准验证后迁移 C#，按"算法重量"选择调度（§14，见下方决策）。
- **区块尺寸 16³**：候选值之一，写入 `WorldConfig`，非永久约束（§4.1）。
- **图集为程序化占位贴图**：逐 tile 固定种子生成，规避第三方许可证核验（§7.3）；
  真实材质包在阶段 E 通过同名 tile 体系接入。Nearest 过滤 + 关闭 mipmap 避免渗色（§7.1）。
- **网格边界策略**：y<0 视为实心（不渲染世界底面），其余越界视为空气（§6.4）。
- **同步生成**：Stage A 一次性构建固定 6x3x6 区块；后台线程与任务版本在阶段 C 引入（§10.1）。
- **三角形绕序**：Godot 光栅化的正面是"从面外侧看顺时针"（与 OpenGL 式逆时针假设相反）。
  曾因绕序相反导致所有面被背面剔除、可透视地形内部；`debug/render_check.tscn`
  以无光照白材质的像素统计客观回归此问题。
- **区块碰撞**：可见面剔除后的三角形直接转 ConcavePolygonShape3D（表面即碰撞面）；
  mesh_dirty 与 collision_dirty 分开标记、分开重建（§8.3）。Stage B 为同步整区块重建，
  局部更新/延迟合并按文档要求待测量后再做。
- **挖掘为计时生效**（物品层升级）：时长 = hardness / 工具速度；
  徒手/等级不足 4 倍减速且不掉落。挖掘进度条与掉落直接入包属 v1
  语义；地面掉落实体、工具耐久属后续玩法层。
- **物品身份与方块同名**（`core:stone` 既指方块也指其物品）：挖什么
  得什么、放什么消耗什么，映射零特判；纯物品（煤/镐）独立命名。
- **背包序列化用稳定名称**：与方块存档同一原则（§2.2），注册顺序
  变化不破档；未知名称跳过、超上限截断，旧档缺键补起始装备。
- **流式线程模型（§10.1）**：工作线程纯计算 + 主线程提交；过期任务用
  edit_serial 快照判定。网格与碰撞仍整区块重建（16^3 重建成本低），
  局部更新留待基准数据支持后再引入。
- **区块存档为完整数据而非生成增量（§9.1）**：体积略大但生成算法升级后
  旧存档仍精确还原（配合生成版本记录，§5.1）；调色板 + 稳定名称保证
  注册表重排安全（§2.2）。
- **玩家状态在 world.json**：位置/朝向/手持/出生点，自动与退出时保存。
- **生成算法 v2（阶段 E 扩充）**：沙地/砂岩地层 + 煤/铁矿脉。v1 存档
  读取时会告警"未修改区域将用新算法重建"，完整区块数据不受影响。
- **默认网格算法为面剔除**：贪心虽把顶点压到 22.8%，但即便 C# 加速后
  构建仍慢 3 倍（9.1 vs 28.7 ms/区块，§6.3 实测），收益不足以切换默认；
  两者共享正确性语义与测试。
- **材质包许可证（§7.3）**：当前 Conquest 为用户提供的本地包，仅限
  个人使用、不可再分发；可商用的 CC0 / CC BY 4.0 备份组保留在
  `assets/textures/open_cc0_backup/`，发布前整体换回即可。
  来源、许可与下载日期记录于 assets/textures/CREDITS.md。
- **原生迁移（§14 决策记录，最终状态：C# 已落地，选择调度）**：
  snap 版 godot-4 曾阻断全部原生路径（C# 缺 Packed*Array 类型、godot-cpp
  镜像缺失、裸 GDExtension 接口全 void 返回）。改用官网 mono 构建后 C# 打通，
  遗留两个环境坑与解法：
  1) **.NET 运行时版本**：程序集面向 net8.0 而系统仅有 .NET 10，默认
     `LatestMinor` 不跨主版本导致运行时静默解析失败——csproj 设
     `RollForward=LatestMajor` 解决；
  2) **渲染器**：llvmpipe 的 Vulkan JIT 会生成 BMI2 指令，本机 2014 年
     赛扬不支持 → 编辑器 SIGILL 崩溃；项目锁 `gl_compatibility` 走
     GT 610 的 OpenGL 4.3 硬件加速。
  C# 侧用 Variant 批量互转（`AsInt32Array` 一次转整段，绕开缺失的
  Packed*Array 类型）。A/B 基准（192 区块）：**贪心 62.2→25.9 ms/区块
  （C# 胜 2.4×）；面剔除 12.9→29.3 ms（GDScript 胜 2.3×）**——算法重的
  路径 C# 收益盖过跨语言装箱开销，算法轻的反而吃亏。落地为**选择调度**：
  `GreedyMesher` 走 C#，`ChunkMesher`（默认路径）走 GDScript；
  `NativeMeshBridge` 保持中立供等价测试直调（5 世界 × 2 网格器 × 60 检查）。
  `VOXEL_NO_NATIVE=1` 可强制全 GDScript（A/B 与隔离用）。

## 下一步（物品层完成，继续玩法扩展）

阶段 A-E 体素内核 + 物品/合成层 v1 完成。后续迭代方向：地面掉落
实体、工具耐久与数值、有形配方（工作台方块 + 网格摆放）。再往后
按文档 §1.2 逐步接入：生存数值、机械与自动化、NPC 与 Boss、
维度与远征——性能敏感路径按既有基准方法评估是否继续下沉 C#。
