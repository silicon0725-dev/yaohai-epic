# 瑶海 EPIC 第二轮审查报告 —— 修复复核 + 性能专项

| 项 | 内容 |
|---|---|
| 审查对象 | 工作树 HEAD `4d671b2`（含修复提交 `d22d604` 批次0+1、`1356eff` 批次2、`49d01e8` --give、`4d671b2` README） |
| 对照基线 | 首轮报告 [docs/CODE_AUDIT.md](CODE_AUDIT.md)（基线 `fb01aea`，100 条：P0 0 / P1 16 / P2 48 / P3 36） |
| 本轮目标 | ① 复核用户修复是否真正闭环；② 重点找性能问题（每帧扫描/分配、信号风暴、同步 IO、重复计算、无预算循环、缓存无界、GPU 过渲染、GC/LOH、热路径字典/字符串） |
| 方法 | 4 路并行静态审查（全量读修复 diff + 逐文件）＋ lead 在 headless Godot 4.7.2 内动态探针实测 |
| 产出 | 本文件；4 份模块原始报告已合并删除（结论全部收录于此） |
| 发现统计 | **48 条新发现：P0 × 1 / P1 × 10 / P2 × 23 / P3 × 14**（全部不在首轮 100 条内，已跨模块去重） |

---

## 一、总体结论

### 1.1 一句话结论

三个修复提交**方向正确、关键项确已闭环**（视距活锁、测试可信度、图集导出、按键 echo、花掉落、砍树清理路径都已修好），但**批次 2 的光照队列化引入 1 个 P0 级性能回归**：水流仍逐格写方块，而新的 C# 封盖路径把「每格 1 块重算」放大成「每格 7 块全量重算」，实测**一次溃坝第 12 个 tick 累计 2.6 秒、单 tick 最大 950ms，其中 96% 是光照**——这是当前最影响手感的问题，且用户主观感受会是「修完更卡了」。另有 **2 处新引入的正确性风险**（batch 光照单遍顺序相关 → 跨块永久光照缝；`set_blocks_batch` 只发 batch 事件导致 4 个旧消费者静默失联）。

性能问题共 48 条，按数量看 90% 可归到四类结构性根因（见第五章）：**块级全量重算 × 逐格写入的乘数放大**、**队列/预算形同虚设**、**每帧全量扫描无脏索引**、**热路径无谓分配与无脏检查重发**。

### 1.2 修复复核统计（抽查首轮 48 条可验证项）

| 状态 | 数量 | 说明 |
|---|---|---|
| 已修好 | 13 | 见 3.1，含首轮全部「数据安全 / 测试可信度」目标项 |
| 部分修好 | 8 | 见 3.2，多为「修了主路径、漏了另一条路径」或「语义修了但预算/边界没修」 |
| 未修 | 27 | 见 3.3，多为 P2/P3 技术债（批次 2 只覆盖 12 个文件） |
| 新引入问题 | 3 | P0 水流光照放大（B1）、P2 跨块光照缝（B7）、P2 batch 信号契约（L1）——见 3.4 |

> 注：首轮 100 条中余下约 52 条属 P3 风格/技术债，本轮未逐条重核；未复核项按「未动文件=未修」推断，已在附录 B 的覆盖缺口里列明。

### 1.3 本轮最该先修的 7 件事（按收益/风险排序）

| # | 事项 | 位置 | 实测/预估收益 |
|---|---|---|---|
| 1 | **水流写盘改为 tick 末聚合批次 + 光照改脏块集合**（B1） | `world/water_flow.gd:178-185`、`systems/lighting/voxel_light.gd:350-371` | 溃坝单 tick 137→预计 <25ms；极端 950ms→<60ms；消除当前最大卡顿 |
| 2 | **光照编辑队列真正分帧 + 块级合并 + 头指针**（B2） | `systems/lighting/voxel_light.gd:311-342` | 连续编辑摊到 2ms/帧以内；队列不再无界；视觉滞后可控 |
| 3 | **水面 shader 去掉 fragment 里的三重波场重算**（C1） | `presentation/water_surface.gdshader:127-145`（`water_side.gdshader:121-139` 同款） | 1080p 水面 3-8ms/帧 → 预计 1-3ms [待真机验证] |
| 4 | **WaterRipples 改 R8 + 持久缓冲 + 抬高休眠阈值**（C2） | `world/water_ripples.gd:56-122` | 实测 3.72ms/帧 → 预计 <1ms；24s 不休眠 → <2s |
| 5 | **砍树 batch 光照改有预算 + 树重建走异步**（B5/B6） | `systems/trees/tree_manager.gd:631-646`、`systems/lighting/voxel_light.gd:46-73` | 单斧 20-45ms → <8ms；溃坝期 20-40 帧连续卡顿 → 摊平 |
| 6 | **流式主循环去掉每帧/每次跨列的 O(N) 全扫**（A1/A3/A4） | `world/chunk_manager.gd:551-560`、`:339-418`、`:387-405` | 常驻 0.6-1.5ms/帧 → ~0；视线偏转 9-16ms 尖刺 → ~1ms |
| 7 | **网格桥只传外壳 1736 格**（A2） | `meshing/native_mesh_bridge.gd:81-98` | LOH 130-190MB/s → 约 1/63；GC 停顿消失 |

### 1.4 关键实测数字（headless Godot 4.7.2，本机探针脚本，临时目录已删除）

| 指标 | 实测 | 说明 |
|---|---|---|
| 单格编辑（挖/放，含光照） | p50 0.90ms / max 3.81ms | `fixcost`：25 块场景、C# 光照路径，标脏 6 块 |
| 单次 batch 200 格（砍树清叶路径） | 0.47-1.50ms | 批量通道本身很快，问题在其后的同步重算与重建 |
| 单块光照初始化 | p50 0.13ms / max 4.49ms（n=27） | `probe_light_cost`：所以「每次编辑 7 块」理论 ~0.9ms，实测水流每格 ~4.6ms（差额在信号消费者） |
| **水流 tick（开光照）** | **p50 137.8ms / p90 493.9 / max 950.4 / 12 tick 合计 2613.6ms**（545 格变更） | `water3`：3×3 水源、25×3 块、C# 光照 |
| 水流 tick（**关**光照） | p50 10.2ms / p90 22.7 / max 26.3 / 合计 113.7ms | 同一场景 → **光照占 95.6%** |
| WaterRipples.step() | **p50 3.716ms / max 4.713ms**，1449 步才休眠 | `probe_ripple2`；60fps 预算 22%，游泳时每帧唤醒 |
| 512 格连锁放置 | 1787.5ms（avg 3.49ms/格） | `fc2`：逐格 set_block 的极端场景 |
| 网格构建（worker） | p50 10.2ms / max 23.6ms | `fixcost`；主线程无感但影响流式吞吐 |
| 存档目录扫描 2000 文件 | 0.88 / 0.97 / 1.28ms（3 次） | `probe_perfD`：HUD 每秒 4 次 ≈4ms/s（据此把 D1 从 P1 降为 P2） |
| 测试基线 | **34 套件 / 12971 项 / 0 失败 / 0 跳过**，无 `Invalid Task ID` | 当前 HEAD 全绿，L2 修复确认有效 |

---

## 二、验证方法与本轮实测

### 2.1 静态审查

- 逐文件读 `git diff fb01aea..HEAD`（27 文件 +3602/−143，含 2974 行新增文档），核对每处改动是否闭环、是否引入新问题；三份模块报告分别覆盖 world/meshing、lighting/water/sound/trees、presentation/UI，第 4 份覆盖 player/characters/items/main。
- 与 [docs/CODE_AUDIT.md](CODE_AUDIT.md) 100 条逐条对号，跨模块去重（涟漪 CPU、天空每帧写、main 字面量数组三处重复已合并）。

### 2.2 动态探针（lead 亲自执行）

| 探针 | 覆盖 | 关键输出 |
|---|---|---|
| `.audit2/fc2` | 单格编辑、7 块封盖重算、512 连锁、batch200 | `cover_recalc_7blocks_ms=0.94`、`burst512_place=1787.51`、`batch200=1.50` |
| `.audit2/water2`、`water3` | 真实 water_flow tick（开/关光照对比） | 见 1.4；`water_dirty_chunks p50=4 max=6` |
| `.audit2/probe_light_cost` | C# 光照初始化/增量 | `init_chunk_light p50=0.13ms` |
| `.audit2/probe_ripple2` | WaterRipples 步进/休眠/唤醒 | `p50=3.716`、`sleep_after_steps=1449`、`wake_by_zero_impulse_steps=100`、`fresh_40steps_ms=109.8` |
| `.audit2/probe_perfD` | 存档扫描、涟漪 | `ripple_step p50=3.702`、2000 文件扫描 ~1ms |
| `.audit2/tests.out` | 全量测试 | 34 套件 12971 项 0 失败；stderr 无 `Invalid Task ID`；退出期仍有 226 RID / 842 ObjectDB 泄漏（headless 既有噪声，非新问题） |

测量局限（必须知道）：全部为 **headless + dummy 渲染器**，GPU 类数字（C1/C4/C5/C6/F8 火把 draw call）只能给静态推导并标 [待验证]；桌面 `forward_plus` 与 project.godot 声明的 mobile `gl_compatibility` 路径表现会不同（后者无体积雾、无 SSAO/SSR 差异）。

---

## 三、修复复核明细

### 3.1 已修好（13 项）

| 首轮编号 | 位置 | 复核结论 |
|---|---|---|
| 1-F1 视距 padding 环网格活锁 | `world/chunk_manager.gd:713-723`、`:401-405` | 已修：拒收分支清 `mesh_dirty/collision_dirty`+DATA_READY，补网格循环加 `_is_wanted`；活锁消失 |
| 1-F3 存档同步写盘尖刺 | `chunk_manager.gd:166-200` | 已修：autosave 改 `_save_queue` + 每帧 4ms 预算 + 队列清空写 meta（残留见 3.2） |
| 1-F10 入队期 27 邻×4096 水位扫描 | `world/chunk_data.gd:16、:91`、`meshing/chunk_mesher.gd:899-920` | 已修：`has_water` 字段 + 首行早退，写入点全查过 |
| 3-F3 砍树逐格 `set_block` 清叶 | `systems/trees/tree_manager.gd:631-639` | 已修：改一次 `world.set_blocks_batch(clear_cells, AIR_ID)`，省掉每格 529 次列索引 + 7 块光照；代价见 B5/B7/L1 |
| 4-F1 按键 echo 未过滤 | `player/player_controller.gd:201` | 已修：4 个分支统一 `event.pressed and not event.echo` |
| 4-F2 挖掘 0.5s 后冻结 | `characters/character_animator.gd:217-225` | 已修（采样层 fmod 回绕）；副作用见 3.4（4-F5 升级） |
| 4-F3 第三人称相机贴墙黑屏 | `player_controller.gd:69-72`、`:1161-1167` | 已修主体：`CAM_MIN_DIST 0.05` + `clampf(hit-PAD, MIN, want_len)`；残留 `hit<0.05` 时仍可能贴脸 |
| 5-F1 挖草丢花 | `interaction/block_mining.gd:76-91` | 已修：`above_drops` 并入返回数组 |
| 5-F4 砍树掉落无背包兜底 | `scenes/main.gd:150-160` | 已修：`_spawn_drop` 失败回包 |
| 6-F9 图集 `Image.load_from_file` 导出失效 | `presentation/texture_atlas_loader.gd:110-123` | 已修主目标：导出包走 `.ctex`，不再整包退化色块；3 项残留（见 3.2） |
| L2 测试误用 `wait_for_task_completion` | `tests/test_stress_edits.gd` | 已修：改帧驱动 + 600 帧超时；实测无 `Invalid Task ID` |
| L3 单格编辑 70ms 光照尖刺 | `systems/lighting/voxel_light.gd:374-391` | 已修「单次尖刺」：无界 BFS → 7 块封盖 ~0.9ms；但队列未分帧 + 水流放大（B1/B2） |
| 7-F11 main 每帧字面量 Array（部分） | `scenes/main.gd:429-446` | 已修 2/5 处（`_u_day_mats`/`_wind_mats` 惰性收集）；其余见 D11 |

### 3.2 部分修好（8 项，残留要补）

| 首轮编号 | 已修部分 | 残留（本轮编号） |
|---|---|---|
| 1-F2 dormant 写盘永不重试 | `save_all` 与队列清空时都会 `_flush_dormant()` | `chunk_manager.gd:162` 只有 `_save_queue` 非空才 pump → 无脏块的长时间会话中 dormant 不重试；且 `_flush_dormant` 在预算检查之后（:194 先 return） |
| 2-F1 每区块重复打包 27 邻 | C# 侧 `RentPadded/BuildPaddedCache` 已正确无残留 | 桥侧仍 442KB 打包 + `AsInt32Array` 442KB LOH（A2） |
| 2-F2 草叶 detail 无块级预算 | naive 路径有 `GRASS_CELL_BUDGET=160` | greedy 两路径与 `plant_cells` 高草不计入（A6） |
| 3-F2 cut 事件 256 上限/重放不清体素 | 新增 `cut_events_by_root()` 供生成链剪枝，生成时能重放已砍枝 | `:583-589` 仍整表 slice 拷贝；重放仍只剪结构不做体素清理（历史幽灵树干风险仍在旧档） |
| 5-F2 `_drop_held` 先扣包后 spawn | 失败会 `add()` 回滚 | 回滚非原子（可能移格/与自动拾取竞争），`spawn` 返回 null 仍不检查 |
| 6-F1 方块音 O(包围盒体积) | 新增「走廊粗判」 | 判据半径 `0.5d+3` 恒大于盒半径 → **保留率 97.5-100%**，8-30ms/事件仍在（B4） |
| 6-F4 cave_fog 脏标不过滤 | 补了 batch 订阅 | 任意编辑仍 `_dirty=true`（B8） |
| 7-F11 main 字面量数组 | 2/5 处修复 | `:341`、`:461`、`:562` 仍每帧新建（D11），`:570-572` 仍无脏检查重发（D11/D16） |

### 3.3 未修（27 条已核实 + 未逐个重核清单）

下列前五组为**已核实未修**的 27 条；最后一组是首轮 P3 提示（未改文件默认视为未修，未逐条重核，见附录 B）。

- **光照/渲染正确性**：6-F2（已有回归，见 B1）、6-F3 水面反射 SubViewport `UPDATE_ALWAYS` 每帧再渲染一遍世界、6-F5 封盖兜底 GD 回退静默失效、6-F6 幽灵火把、6-F7 死代码 RID 泄漏、6-F8 distant_shell worker UAF、6-F10/6-F11/6-F13/6-F14/6-F15/6-F16。
- **世界/流式**：1-F4（6 面 vs 26 邻过期比对）、1-F5（碰撞圈补建整块重网格）、1-F9（water 追帧无上限）、1-F12（注释与实现不符，误导后续维护）。
- **树龄链路**：3-F5（单树同步重建 24.5ms，且被水流放大成 B6）、3-F7（重建失败先 queue_free 不置 null）、3-F8（异步 job 光照快照陈旧）。
- **玩家/动画**：4-F5（`characters/ef_reference_rig.gd:177、:339` 所有 EF 片段 `loop=true` → 开战斗即连击无限循环；当前被 `player_avatar.gd:23 COMBAT_ENABLED := false` 掩盖，**开战斗前必须修**）、4-F10（不可破坏目标进度条常亮）、4-F11/4-F16（背包打开时左键仍挥拳）。
- **物品**：5-F3（拖拽期掉落自动入包 + `_bounce_back` 忽略 leftover）、5-F5/F6/F7。
- **未逐条重核（默认视为未修）**：2-F4、2-F8、7-F1…7-F10 多数、7-F12。

### 3.4 新引入的问题（3 条，详见第四章编号）

| 编号 | 严重度 | 一句话 |
|---|---|---|
| **B1** | **P0** | 水流逐格写 → 每格触发 7 块全量光照重算：机制上 ×7 放大，实测 tick p50 137ms / max 950ms、96% 在光照 |
| **B7** | P2（正确性） | batch 光照单遍顺序相关：先算的块用邻块重算前光照，且 C# 只播种不迭代 → 跨块 1-2 格永久错光带（Δ 可达 15 级） |
| **L1** | P2（正确性） | `set_blocks_batch` 只发 `blocks_changed_batch`，而 tree_manager / block_entity_renderer / sound_manager / water_flow 只订阅 `block_changed` → 砍树清叶后邻树烘焙光照不刷新；将来批量删火把会留幽灵实体 |

## 四、新发现总览与 P0/P1 详情

### 4.1 统计

| 级别 | 数量 | 编号 |
|---|---|---|
| **P0** 崩溃/存档损坏/单帧 >100ms 且高频 | 1 | B1 |
| **P1** 真 bug 或 >100ms 卡顿 / 稳态 >1ms 每帧 | 10 | A1 A2 A3 B2 B3 B4 B5 B6 C1 C2 |
| **P2** 边缘 case / 明确技术债 / 局部尖刺 | 23 | A4-A8 B7-B10 C3-C7 D1 D4-D10 L1 |
| **P3** 风格 / 微优化 | 14 | A9-A11 B11-B13 C8 C9 D11-D16 |
| 合计 | 48 | 去重后（A12 并入 A4/A5、C10 并入 B10、C2≡D2、C5≡D3） |

编号前缀：**A** = 世界/流式/网格（world、meshing、native）；**B** = 光照/水流/音效/树；**C** = 渲染/GPU/UI 资源；**D** = 玩法/物品/帧驱动；**L** = lead 独立发现。

---

### B1 [P0] 水流逐格写方块 → 每格 7 块全量光照重算（帧尖刺 0.14-0.95s）

**位置**
- [world/water_flow.gd](world/water_flow.gd):91-93、:128（每次 `_set_water`）、:178-185（写方块 + 写 level）
- [systems/lighting/voxel_light.gd](systems/lighting/voxel_light.gd):314-321（信号内同步 drain）、:350-371（7 块封盖重算）、:386-390（注释自述 7 块 ~3.5ms）
- [world/water_flow.gd](world/water_flow.gd):19、:65-77（单 tick 最多 512 格）、:51-56（每次方块变更再入队 6 邻）

**证据**
```gdscript
# world/water_flow.gd:178-185
func _set_water(pos: Vector3i, lvl: int) -> bool:
	if not world.set_block(pos, VoxelTypes.WATER_ID, false):
		return false
	if lvl > 0:
		world.set_block_state(pos, "level", lvl, true)
	return true

# systems/lighting/voxel_light.gd:350-371
func _recalc_cover_native(chunk: ChunkData) -> bool:
	var coords: Array[Vector3i] = [chunk.chunk_coord]
	for d in DIRS:
		coords.append(chunk.chunk_coord + d)   # 本块 + 6 面邻 = 7 块
	for coord in coords:
		...
		var before := c.light.duplicate()
		if not _init_chunk_light_native(c, six, six[2] == null):
			return false
```

**根因**：写水的事务单位是「单格」，而光照封盖重算的单位是「块 × 7」。`set_block` 会发 `block_changed`，`_on_block_changed` **在发信号者的帧内同步** `_drain_edits()`，于是同一 tick 内 512 格水 = 最多 512 次 7 块重算，且大量落在同一块上重复计算；每次重算还要 `light.duplicate()` 7 份并于 C# 侧整块初始化。批次 2 把「单格无界 BFS」换成「固定 7 块」，单次编辑是净改善（70ms→0.9ms），但**把逐格写入路径放大了 7 倍**。

**影响（实测）**

| 场景 | 观测 |
|---|---|
| 3×3 水源、25×3 块 | 单 tick p50 **137.8ms** / p90 493.9 / max **950.4ms**，12 tick 累计 2613.6ms（545 格变更） |
| 同场景关闭光照 | p50 10.2ms / max 26.3ms，合计 113.7ms → **光照占 95.6%** |
| 玩家主观 | 溃坝/放水时 0.5-1.5 秒级别的完全卡死，比修复前更疼 |

**修复方案**
- **A（推荐，治本）**：tick 末聚合。
  1. `WaterFlow.tick()` 内不再逐格 `set_block`，改为收集 `cells: Array[Vector3i]` + `levels: Dictionary`；
  2. 新增 `VoxelWorld.apply_water_batch(cells, levels)`：一次批量写方块（复用现有 `set_blocks_batch` 的写路径）+ 批量写 state，末尾只发一次 `blocks_changed_batch`；
  3. `VoxelLight` 新增 `_on_blocks_batch_cover(cells)`：把 cells 映射成**块集合**去重，每块只做一次封盖重算（实测溃坝最大只脏 6 块，见 water2 `water_dirty_chunks p50=4 max=6`）→ 6×0.9ms ≈ 5ms。
- **B（快修，1 小时内可上）**：给 `WaterFlow` 一个 `_light_dirty_chunks: Dictionary`，`_set_water` 期间把 `world.set_block(..., false)` 换成「静默写」新增 API（不发 `block_changed`），tick 结束后统一 `light.mark_chunks_dirty(set)` 一次重算。代价：写水期间其它信号消费者（音效/水流自身/掉落物）收不到逐格事件——水流自身靠 `tick()` 主动评估不受影响，音效本就不该为每格水响一次。

**验证**
- 重跑 `.audit2/probe_water3.gd`：目标 p50 < 25ms、max < 60ms（当前 137.8/950.4）。
- 单格挖/放回归：`probe_light_cost` 与 `fixcost`（p50 0.90ms）不得劣化；34 套件全绿（尤其 `test_water_flow`/`test_light_manager`）。
- 新增用例：溃坝 1 tick 后逐格比对「光照 == 重算后的期望值」，防批量去重漏块。

---

### A1 [P1] `_poll_jobs` 每帧全量扫描所有区块（0.6-1.5ms/帧常驻）

**位置**：[world/chunk_manager.gd](world/chunk_manager.gd):551-560（脏块扫描）、:147-163（每帧调用）

**证据**
```gdscript
# chunk_manager.gd:551-560
for coord in world.chunks:
	if in_flight_count() >= max_in_flight:
		break
	var chunk: ChunkData = world.chunks[coord]
	if (chunk.mesh_dirty or chunk.collision_dirty) \
			and not _mesh_by_coord.has(coord):
		_enqueue_mesh(coord)
```

**根因**：没有「脏块集合」索引，靠每帧遍历 `world.chunks`（视距 16 时圆内 ~800 列 × 活跃带 3-5 层 ≈ 2400-4000 块）找出 1-5 个脏块。全量扫 + 每块 2 次属性读 + 1 次字典查，实测 0.6-1.5ms/帧（800 块最坏），闲置时也照付。编辑插队循环（:540-550）已用稀疏集合 `_edit_dirty`，说明同一文件内两种风格并存。

**影响**：常驻 3.6-9% 的 16.6ms 帧预算被空转消耗；低端机与 800 块视距下更明显。

**修复方案**
- **A（推荐）**：维护 `_mesh_dirty_set: Dictionary`，在 4 个置 `mesh_dirty=true` 的地方同步插入（`_invalidate_affected_meshes`、光照 diff、草叶降档、数据就绪），`_enqueue_mesh` 成功 / `_commit_mesh` 完成时移除；`_poll_jobs` 只遍历该集合。
- **B（最小改动）**：每 4 帧扫一次（`_poll_tick % 4 == 0`），编辑插队保持不变；代价是流式首次网格化延迟 +3 帧。

**验证**：800 块场景打印 `_poll_jobs` 耗时（目标 <50µs）；`test_streaming`/`test_stress_edits` 全绿；统计一次会话内 total scanned 次数为 O(dirty)。

---

### A2 [P1] 网格桥每任务打包 27 邻域 442KB + C# `AsInt32Array` 再拷 442KB（LOH 130-190MB/s）

**位置**：[meshing/native_mesh_bridge.gd](meshing/native_mesh_bridge.gd):81-98、:120-131；[native/NativeMesher.cs](native/NativeMesher.cs):99-101、:504-520

**证据**
```gdscript
# native_mesh_bridge.gd:81-98
static func _pack_neighbors(chunk: ChunkData, neighbors: Array) -> Dictionary:
	var volume := s * s * s                    # 16³ = 4096
	var neighbor_ids := PackedInt32Array()
	for i in 27:
		var nb: ChunkData = neighbors[i]
		if nb != null:
			neighbor_ids.append_array(nb.block_ids)   # 27 × 4096 × 4B = 442KB
```

**根因**：C# 网格器需要 27 邻域判断面剔除，但真正被读到的只有「6 个面 + 12 个棱 + 8 个角」的外壳格（`16³ - 14³ = 1352` 格，约 1/63）——现有实现把 27 个整块全量复制一遍（干块 ~0.89MB、水块 ~1.8MB 托管分配/任务），`AsInt32Array` 再拷一份到 C# 堆，>85KB 直接进 LOH。

**影响**：网格化 10-20 块/s 时 **20-90MB/s** 托管分配、LOH 130-190MB/s；GC 停顿与内存峰值随视距线性放大；A/B 里 C# 4-4.5× 的收益被桥接成本吃掉一部分。

**修复方案**
- **A（推荐）**：只传外壳 1352 格（或 1736 格含面）——新增 `_pack_shell(chunk, neighbors)` 按「面优先」顺序填 6 个 16×16 面 + 12 棱 + 8 角，C# 侧 `NeighborView` 提供与现有 `Get(x,y,z)` 相同的访问语义。
- **B（不改协议）**：每 worker 持有一个可复用 `PackedInt32Array`（容量 27×4096，`resize` 复用内部缓冲），C# 侧改 `Span<int>`/`ReadOnlySpan` 直接读，避免 `AsInt32Array` 二次拷贝；LOH 从「每任务」降到「每 worker 一次」。

**验证**：`test_native_equivalence` 226 项必须全绿（两条 C# 路径）；在 200 块批量网格化下用 `GC` 统计（或 `Performance.get_monitor(MEMORY_STATIC)`）对比峰值；mesh build p50 不劣化（当前 10.2ms）。

---

### A3 [P1] 视线偏转时重建列排序（1089 列 × 两次 `sort_custom`，9-16ms 尖刺）

**位置**：[world/chunk_manager.gd](world/chunk_manager.gd):339-348（`desired_columns` 建 1089 列+按距离排序）、:406-418（每帧判偏转，>~30° 重建）、:411-416（按优先级再排一次）

**证据**
```gdscript
# chunk_manager.gd:406-418
if center_moved or _sorted_columns.is_empty() \
		or view_dir == Vector2.ZERO \
		or _stream_dir.dot(view_dir) < 0.866:      # 30° → 正常转头每帧命中
	var columns := desired_columns(center, view_distance)   # 1089 列 + 第 1 次排序
	var compare := func(a: Vector2i, b: Vector2i) -> bool:
		return priority_score(a, center, view_dir, view_bias) \
				< priority_score(b, center, view_dir, view_bias)   # 第 2 次排序
	columns.sort_custom(compare)
```

**根因**：两段排序都用 GDScript `Callable` 比较器（比较次数 ~n log n ≈ 1.1 万次，每次 2-4 次 `Callable.call` + Vector2 运算），且 `priority_score` 每次比较重复计算；视角连续转动时 30° 阈值几乎每 0.2-0.4s 触发一次。列集合只随玩家位置变化，与视线无关，完全可以增量维护。

**影响**：每 0.2-0.4s 一次 9-16ms 主线程尖刺（[推导]：1089 列、2×11.8k 次比较、GDScript 闭包调用开销按 0.4-0.7µs 估），转视角时周期性掉帧；与网格/光照尖刺叠加时更明显。

**修复方案**
- **A（推荐）**：缓存 `desired_columns`（键 `(center, radius)`，玩家移动 1 格才重建，且第 1 次排序可省——直接按环序号生成，天然近似有序）；视线偏转改为「8-16 扇区桶 + 桶内保持原序」，只在桶边界处做 O(n) 分区，无 `sort_custom`。
- **B（小改）**：把 `priority_score` 的 `view_bias` 项改为「距离项预计算 + 视线项一次乘法」，并把偏转阈值从 `0.866` 降到 0.5（60°）以减频；或每 N 帧最多重建一次。

**验证**：加探针测 `_update_streaming` 在连续转视角 600 帧下的 max/p99（目标 <2ms）；`test_streaming` 的列顺序断言（若有）需同步；目视确认加载顺序无跳变。

---

### B2 [P1] 光照编辑队列「名义分帧、实际同步」：单条不可切分、预算小于单条、队列无界

**位置**：[systems/lighting/voxel_light.gd](systems/lighting/voxel_light.gd):305-321、:329-342

**证据**
```gdscript
# voxel_light.gd:311-321
const LIGHT_DRAIN_BUDGET_USEC := 2000
...
func _on_block_changed(pos, old_id, new_id) -> void:
	_edit_queue.append([pos, old_id, new_id])
	_edit_pending = true
	_drain_edits()          # 发信号者帧内同步处理全部
...
# :329-342
for i in _edit_queue.size():
	... 整条处理（可达 7 块 ~3.5ms）...
	if Time.get_ticks_usec() - t0 > LIGHT_DRAIN_BUDGET_USEC:
		break                # 预算只在「条与条之间」生效
```

**根因**：三处叠加——① `_drain_edits` 在 `_on_block_changed` 末尾同步调用，等于同步执行；② 单条编辑固定做 7 块重算（~3.5ms），而预算 2000µs 永远小于单条，预算形同虚设；③ `pop_front()` 是 O(n) 且队列无上界；④ 无「块级合并」，同块 50 次编辑算 50 次。

**影响**：连续编辑（水流、批量脚本、砍树）时主线程被执行时间钉住；单帧内 512 条同步 drain 就是 B1 的 137ms。即使修好 B1，玩家快速连点、TNT/连锁场景仍会命中。

**修复方案**
- **A（推荐，随 B1 一起做）**：把队列从「格事件」改为「块脏集合」——`_on_block_changed` 只做 `_dirty_chunks[chunk_coord]=true` 并置 `_dirty=true`，`_process` 每帧按 `LIGHT_DRAIN_BUDGET_USEC=2000` 处理 1-2 块（每块 0.9ms 封盖），并保留「单次编辑立即处理」的快路径（队列空且只此一条时同步算，保证测试与手感）；块级去重天然把 50 次编辑合并成 1 次。
- **B（快修）**：`_drain_edits` 改为 `while` + 头指针（`_edit_head: int`，定期 `slice` 压缩），单条拆成「每帧最多 N 块」，并把 `_recalc_cover_native` 改成可续（先算本块，6 邻分帧）。

**验证**：`test_light_manager`（同步语义）、`test_water_flow`；探针连续 200 次编辑的每帧耗时 p99（目标 <2.5ms）；确认单次挖/放后**同一帧**光照已正确（老的测试依赖同步）。

---

### B3 [P1] 每次光照重算复制 0.3-0.5MB（7×`light.duplicate()` + C# 双向 marshal）

**位置**：[systems/lighting/voxel_light.gd](systems/lighting/voxel_light.gd):355-371

**证据**
```gdscript
for coord in coords:                       # 7 块
	var before := c.light.duplicate()      # 每块 Sky+Block 两份 4096 字节
	if not _init_chunk_light_native(c, six, six[2] == null):
		return false
	if c.light != before:
		c.mesh_dirty = true
```

**根因**：为了「diff 有变化才标脏」，每块先整块 `duplicate()` 两份 4KB，再让 C# 覆盖 4096×2 字节并回写；7 块 = 7×(复制 + marshal + 比较)。真正的变化通常只有几十格。

**影响**：每次编辑 0.3-0.5MB 托管分配（[perf-B 静态推导]，含 C# 侧数组进出）→ 连续编辑 10 次/s 时 3-5MB/s 垃圾；与 B1/B2 叠加放大 GC 压力。

**修复方案**
- **A（推荐）**：给 `ChunkData.light_version` 计数器，C# `InitChunkLight` 直接写入并返回「变化的格数/末次改动位置」；只有 changes>0 才 `mesh_dirty`，删除 `before` 复制。若必须 diff，复用每块一个持久 `PackedByteArray` 缓冲池（7 个）。
- **B**：先做「粗判」——只在该格所在块的入口/出口处比较 26 邻光照采样，不复制整块。

**验证**：`test_native_equivalence`/`test_light_manager` 全绿；连续 200 次编辑时 `Performance.get_monitor(MEMORY_STATIC)` 无阶梯上涨；单格编辑 p50 不劣化。

---

### B4 [P1] 音效反射「走廊裁剪」判据恒通过，8-30ms 主线程扫描仍在

**位置**：[systems/sound/early_reflections.gd](systems/sound/early_reflections.gd):98-146；调用方 [systems/sound/sound_manager.gd](systems/sound/sound_manager.gd):218-220

**证据**
```gdscript
# early_reflections.gd:111-129
var corridor: float = sqrt(seg_len2) * 0.5 + 3.0   # 随距离线性增长
var corridor2 := corridor * corridor
...
	if cc.distance_squared_to(closest) > corridor2:
		continue                                    # 实际保留率 97.5-100%
	var b := world.get_block(cell)
	if not Acoustic.is_opaque_block(b):
		continue
	for k in 6:                                     # 每实心格再 6 次 get_block
```

**根因**：包围盒是源/听者 AABB ± `SCAN_MARGIN`，盒内任一点到线段的最大距离 ≤ ~`SCAN_MARGIN·√2`（固定 ~8.5 格），而阈值 `0.5·L+3` 随距离增长（10 格距离即 8，30 格即 18）→ 判据几乎不剪枝。批次 2 的「优化」因此无效（实测保留率 97.5-100%），每次方块音的 O(盒体积) 扫描原封不动。

**影响**：盒体积 `(L+2·MARGIN)³`，10 格距离约 17 万次 `get_block`（每次 6 邻再加 6 次）→ 单事件 8-30ms 主线程，放在方块破坏/放置路径上＝**每挖一块卡一下**。

**修复方案**
- **A（推荐，几何正确）**：1 阶镜像面只可能在「源→听者」线段穿过的体素边界附近——用 **3D DDA 沿线段走**（O(L) ≈ 10-30 步），对经过的每格收集 6 个面，再算镜像路径合法性。复杂度从 O(L³) 降到 O(L)，且不是近似。
- **B（工程折衷）**：把扫描搬到 `WorkerThreadPool`（结果晚 1-2 帧到达，短音效听不出），并加「每帧最多 1 个音效事件」限流；同时把走廊半径改成 `SCAN_MARGIN*1.5` 这种与距离无关的常数（真剪枝 50%+）。

**验证**：`test_sound` 168 项；新增「裁剪前后反射面集合等价」测试（DDA vs 全扫）；实测单事件耗时（目标 <2ms）。

---

### B5 [P1] 一次砍树 = 27 块同步光照重算（13.5ms）+ 同步全树重建（5-24.5ms）+ 掉落计算（3-7.5ms）

**位置**：[systems/trees/tree_manager.gd](systems/trees/tree_manager.gd):631-646；[systems/lighting/voxel_light.gd](systems/lighting/voxel_light.gd):46-73（batch 订阅）

**证据**
```gdscript
# tree_manager.gd:631-646
var clear_cells: Array = []
...
if not clear_cells.is_empty():
	world.set_blocks_batch(clear_cells, VoxelTypes.AIR_ID)   # → 27 块 batch 光照重算
...
tree.revision += 1
if tree.cell_to_branch.is_empty():
	_destroy_tree(tree.tree_id)
else:
	_build_visual(tree.tree_id)      # 同步重建，实测峰值 24.5ms
```

**根因**：批次 2 把「逐格 set_block（每格 1 次光照 BFS）」改成「一次 batch」，方向对，但 batch 消费者 `_on_blocks_changed` 对**全部 27 块**做全量重算（清理格实际只覆盖 3×3×3 内的 2-6 块），且 `_build_visual` 仍在主线程同步执行（3-F5 未修），`_collect_leaves_near` 也在主线程。三者串起来就是「砍一刀顿一下」。

**影响**：单次斧击 20-45ms（perf-B 实测 + 3-F5 实测 24.5ms），玩家连砍/砍树动画期间反复触发；树多时叠加 B6。

**修复方案**
- **A（推荐）**：① batch 光照只重算「clear_cells 实际所在块的 3×3×3 邻域」并去重（用 cell → chunk 集合）；② `_build_visual` 改「先标脏、下一帧 `_process` 预算内重建」（复用现有 `_light_dirty` 通道，但按 ms 预算而非棵数）；③ 掉落体生成延迟 1 帧。
- **B（最小）**：把 `_build_visual` 强制走「丢弃旧 mesh + 下一帧重建」，并给 `set_blocks_batch` 传「影响块集合」参数，避免全 27 块。

**验证**：`test_tree_manager`/`test_stress_edits`；探针「砍树单次总耗时」目标 <8ms；目视确认无「跳半格」。

---

### B6 [P1] 水流/砍树标脏周边树 → 每帧同步重建 5-24.5ms，持续 20-40 帧

**位置**：[systems/trees/tree_manager.gd](systems/trees/tree_manager.gd):113-120、:134-156、:1069-1092

**证据**
```gdscript
# tree_manager.gd:134-156
func _mark_light_dirty(pos: Vector3i, ...) -> void:
	var r := ceil(margin) + TREE_MAX_RADIUS
	for x in range(-r, r + 1):
		for z in range(-r, r + 1):
			var col := ...
			for tree in _trees_by_col.get(col, []):   # 每次未命中新建空数组
				...
# :1069-1092
if not _light_dirty.is_empty():
	...
	for tid in _light_dirty.keys():
		if built >= REBUILD_BUDGET_PER_FRAME:   # 按「棵数」限量，单棵可达 24.5ms
			break
		...
		_build_visual(tid, true)               # 同步
```

**根因**：水流每写一格 → `block_changed` → 树系统对 (2r+1)²≈529 列逐列查索引（未命中产生空数组分配），命中则标脏并 clamp/distance；随后 `_process` 在 **0.15s 合并窗口后**每帧重建 1 棵（预算按棵数），但单棵重建 5-24.5ms 远超帧预算；水流持续 0.5-2s 时就是连续 20-40 帧卡顿。`REBUILD_BUDGET_PER_FRAME=1` 是「伪预算」。

**影响**：溃坝期逐帧 5-24.5ms（叠加 B1 达 137ms）；单机树 10-30 棵时尤其明显。

**修复方案**
- **A（推荐）**：重建改**异步**——`TreeMeshBuilder.build_mesh` 在 `WorkerThreadPool` 生成 `ArrayMesh`（需把 `world.get_block` 访问改为快照，或只读已提交的 chunk 数组），主线程只做 `ArrayMesh` 提交；预算改为 **ms 制**（每帧 ≤3ms）。
- **B（快修）**：`_mark_light_dirty` 的 529 次迭代改「按 chunk 3×3 邻域查树索引」（块坐标系，最多 9 列查询），空数组提为常量 `static var EMPTY: Array = []`；重建只对「相机 64 格内」的树触发，远处延后到流式空闲。

**验证**：`test_tree_manager`；水流探针期间打印树重建耗时（目标每帧 ≤3ms）；目视确认树叶光照最终收敛（允许 0.3-0.5s 延迟）。

---

### C1 [P1] 水面 shader 在 fragment 里把 13 迭代波场重算 3 遍（≈195 transcendental/像素）

**位置**：[presentation/water_surface.gdshader](presentation/water_surface.gdshader):64-101、:127-145；同款副本 [presentation/water_side.gdshader](presentation/water_side.gdshader):121-139

**证据**
```glsl
// water_surface.gdshader:64-100（每次调用 13 迭代，每迭代 4-5 次 transcendental）
for (int i = 0; i < ITERATIONS; i++) {
	vec2 direction = vec2(sin(iter), cos(iter));   // iter 只由 i 决定 → 编译期常量！
	float x = dot(direction, p) * frequency + modified_time * speed;
	float wave = exp(sin(x) - 1.0);
	float result = wave * cos(x);
	...
}
// :127-145（fragment）
float h0 = wave_field(world_pos.xz, t);
float hx = wave_field(world_pos.xz + vec2(e, 0.0), t);      // 同样 13 迭代
float hz = wave_field(world_pos.xz + vec2(0.0, e), t);      // 同样 13 迭代
float r0 = ripple_height(...); float rx = ...; float rz = ...;  // + 3 次纹理采样
```

**根因**：法线用「同函数 3 次数值差分」求，且 `wave_field` 里 `direction = (sin(iter), cos(iter))` 的输入只依赖循环序号，本可编译期展开成常量，却被逐像素 13 次 `sin/cos` 重算；13 迭代 × 3 次调用 × (2 sin/cos + 1 sin + 1 exp + 1 cos) ≈ **195 次 transcendental + 6 次纹理采样/像素**。1080p 水面占屏 40% ≈ 83 万像素。

**影响**：[待真机验证] iGPU 3-8ms/帧、独显 1-2ms/帧；水面越多越重，且 `water_side` 的复制粘贴版本让成本翻倍在近岸区域。

**修复方案**
- **A（推荐，改法小、收益大）**：
  1. 把 13 个 `direction` 提成 `const vec2 DIRS[13]`（`sin(12i), cos(12i)` 手算填表，或写生成器）——直接砍掉 26 次 transcendental/调用；
  2. 法线改为**解析梯度**：在顶点/single-pass 内累计 `dHeight/dp`（每迭代已有 `force = result*weight*dir`，`dH/dp = Σ wave*weight*frequency*dir·…` 可顺手累加），fragment 不再调 3 次 `wave_field`；
  3. `ripple_height` 的 r0/rx/rz 改用 `dFdx/dFdy` 重建（水面近似平面，误差可接受）。
- **B（保守）**：只保留 vertex 的 1 次 `wave_field`，法线用 `varying` 传「波高 + 解析梯度」，fragment 只做 `normalize`；迭代数 13→9 并以 `#define` 分档。

**验证**：真机（桌面 Forward+ 与 mobile GL Compatibility 各一次）用 GPU 计时/帧时间对比；水面观感截图 diff（波峰/法线高光不得明显变化）；`test_meshing` 无关，无需改测试。

---

### C2 [P1] WaterRipples 每步 3.72ms、每步 140KB 内存流量、24s 才休眠（=D2，合并）

**位置**：[world/water_ripples.gd](world/water_ripples.gd):79-122

**证据**
```gdscript
# water_ripples.gd:79-107
var next := PackedFloat32Array()
next.resize(W * H)                  # 9216 → 36KB 新分配（每步）
for y in H:
	for x in W:
		... 双线性/波动方程 GDScript 内层循环 ...
# :112-122
var data := _image.get_data()       # 36KB
... 逐字节写 RGBA ...
_image.set_data(data)               # 36KB
_texture.update(_image)             # 36KB 上传
```

**根因**：96×96 的波动方程在 GDScript 里逐格算（9216 次/步、每步 2 层循环），每步新分配 `next` 36KB，再经 `get_data/set_data/update` 走 3 份 36KB 流量；休眠判据 `energy < 1e-4` 过严（DAMPING 0.99 下要 1449 步），且**任何** `add_impulse`（哪怕强度 0）都清零 `_idle_steps` 唤醒。

**影响（实测，probe_ripple2）**：`active_step_ms p50=3.716 / max=4.713`（22% 的 60fps 预算），`sleep_after_steps=1449`（≈24s @60fps），游泳时每帧注入冲量 → **永不休眠**；每步 ~144KB 内存流量。

**修复方案**
- **A（推荐，改法小）**：① `FORMAT_R8`（高度单通道）→ 每步 9.2KB 而非 36KB；② `next` 改 3 个持久 `PackedFloat32Array` 轮转（零分配）；③ 30Hz 步进（渲染仍 60fps，纹理由 GPU 平滑）；④ 休眠阈值抬到 `1e-3`、加「无冲量 2s 后强制休眠」与「冲量强度 <0.05 不唤醒」。
- **B（治本）**：波动方程整体搬 fragment/GPU ping-pong（两张 R16F 纹理，每帧 1 pass），CPU 归零；成本是 1 次额外 RT 与实现量。

**验证**：重跑 `probe_ripple2`（目标 p50 <1ms、休眠 <2s）；`test_water_ripples` 若有则保持；目视涟漪清晰度（R8 量化 256 级对 0.05 幅度足够）。

## 五、P2 / P3 索引

### 5.1 P2（23 条）：边缘 case / 明确技术债 / 局部尖刺

| 编号 | 位置 | 问题 | 修法（A 推荐 / B 备选） |
|---|---|---|---|
| A4 | [world/chunk_manager.gd](world/chunk_manager.gd):387-390、:401-405、:423-434 | 三处每帧/每次焦点变化遍历全部区块（`keys()` 副本 + 全带扫描） | A：脏集合/反查索引；B：按帧分片（每帧 1/4） |
| A5 | [world/chunk_manager.gd](world/chunk_manager.gd):645-674 | `_enqueue_mesh` 主线程突发：27 邻 `collect_neighbors` + `sparse_block_states.duplicate(true)` + 水位收集，一次 3-10ms | A：快照改 worker 内只读已提交数据；B：每帧最多入队 1-2 个 |
| A6 | [meshing/chunk_mesher.gd](meshing/chunk_mesher.gd):724-730、:774-777、:810-826 | 草叶预算只在 naive 路径生效，greedy 与 `plant_cells` 高草不计入 → 单块 9.7-17MB 顶点内存 | A：统一 `_detail_budget` 累加器覆盖三路径；B：降档阈值改为按顶点数 |
| A7 | [meshing/chunk_mesher.gd](meshing/chunk_mesher.gd) 多处、[world/voxel_world.gd](world/voxel_world.gd):169-177 | 热路径 `get_state(k, {})` 每格新建空字典（0.4-0.8MB/块垃圾） | A：`static var EMPTY_STATE := {}` 只读共享；B：缺失返回 null 并让调用点判空 |
| A8 | [world/chunk_manager.gd](world/chunk_manager.gd):455-460、:569-578 | 生成/入队侧不判 `_is_wanted`：padding 环（最多 ~500 块）先完整生成再丢弃 | A：生成前判 `_is_wanted(coord)`；B：延迟生成到带内 |
| B7 | [systems/lighting/voxel_light.gd](systems/lighting/voxel_light.gd):46-73 | **正确性回归**：batch 光照单遍顺序相关（先算块用邻块旧光照，C# 只播种不迭代）→ 跨块 1-2 格永久错光带（Δ 可达 15 级） | A：batch 涉及的块按拓扑序迭代 2-3 遍；B：batch 后对边界做一次有预算的 BFS 收敛 |
| B8 | [systems/lighting/cave_fog.gd](systems/lighting/cave_fog.gd):61-79、:95-109 | 任意编辑 `_dirty=true` → 全洞 68k `get_block`（40-100ms）摊进 16-40 帧，稳态 2.5ms/帧 | A：只重算脏块 + 区块高度范围；B：VoxelLight 变化块集合直接复用 |
| B9 | [world/water_flow.gd](world/water_flow.gd):33、:59-77、:154-173 | `_pending` 无上界（溃坝可上万格）+ 每 tick `keys()` 全量拷贝；`_spread_dirs` 每格 4×4 次 `get_block` | A：按块分组 + 每块最多 N 格/帧；B：环形缓冲 + 逐格结果缓存 |
| B10 | [world/voxel_world.gd](world/voxel_world.gd):102-108、:156-158、[presentation/chunk_renderer.gd](presentation/chunk_renderer.gd):96-103、[voxel_light.gd](systems/lighting/voxel_light.gd):368-370 | `[perf]` 打点阈值低于新常态（2ms/4ms/5ms）→ 水流期 400-800 行/s 日志，本身 0.5-5ms | A：阈值提到预算之上 + `--perf-log` 门控；B：2s 聚合 p50/p95/max 一次打印 |
| C3 | [world/water_ripples.gd](world/water_ripples.gd):59-66、:170-191 | 窗口平移重采样在休眠判定**之前** → 陆地走路每 2-3 帧 2×9216 迭代 | A：环形缓冲只改 offset（O(1)）；B：量化 2 格 + 10-15Hz |
| C4 | [presentation/distant_shell.gd](presentation/distant_shell.gd):51-64 | 远景壳单 `MeshInstance3D`（4 surface 合一）→ 225 万顶点全过 VS，无扇区剔除 | A：拆 8-16 扇区；B：`visibility_range` + 外环步长 4→8 |
| C5 | [scenes/main.gd](scenes/main.gd):418-425 | 每帧写 4 个天空色 + ambient → radiance cubemap 每帧重烘（0.2-0.6ms GPU） | A：缓存 `_last_day01`，变化 >0.002 才写；B：离散档位 |
| C6 | [scenes/main.gd](scenes/main.gd):624-632 | 体积雾全局常开（density=0 也跑 froxel）→ 桌面 0.3-1.2ms/帧 | A：进/出洞滞回开关；B：`length 48→24` + 关 temporal reprojection |
| C7 | [player/player_controller.gd](player/player_controller.gd):385-388 | 第一人称 `avatar.visible=false` 仍每物理帧全动画 + 骨骼纹理上传（0.3-0.8ms） | A：`not avatar.visible` 直接 return（切换时补一帧）；B：15-20Hz |
| D1 | [scenes/main.gd](scenes/main.gd):503-522、[persistence/world_save.gd](persistence/world_save.gd):49-62 | HUD 每 0.25s 全目录枚举存档（2000 文件 ≈1ms → 4ms/s） | A：维护计数器；B：0.5-1Hz 或异步 |
| D4 | [items/item_drop.gd](items/item_drop.gd):97-126 | 每掉落每物理帧 13-25 次 `get_block` + 注册表字典查；128 上限 → 1.7-3.2k/帧 | A：物理帧 30Hz 分片 + 预算；B：落地后进入休眠态（只在被扰动时唤醒） |
| D5 | [items/item_drop.gd](items/item_drop.gd):136-201 | 浮水掉落每帧 8 邻居 + 两处向上扫水柱 + 8 次落地探测（O(水深) 无上限） | A：缓存水面高度 + 上限 8 格；B：只在速度/环境变化时重算 |
| D6 | [items/drop_manager.gd](items/drop_manager.gd):168-176、[items/grid_inventory.gd](items/grid_inventory.gd):185-211 | 每帧每掉落 `can_fit` 重建 `occupied`（3 元素 Array 键，100-250 次分配/帧） | A：`occupied` 缓存 + 版本号失效；B：位图表示 |
| D7 | [items/grid_inventory.gd](items/grid_inventory.gd):227-251、[player/player_controller.gd](player/player_controller.gd):698-712 | 一次合成 3-5 次 `changed.emit` → 3-5 次 `_refresh_hud`（8 次 `hotbar_pick` 全扫）+ 背包全量重建（3-12ms/次） | A：`begin_batch/end_batch` 合并信号；B：HUD 只更新变化槽 |
| D8 | [items/item_drop.gd](items/item_drop.gd):341-351、[core/voxel_registry.gd](core/voxel_registry.gd):47-50 | 热路径 `definition_for_id(id).get("collision")` 字符串键查 | A：预计算 `PackedByteArray is_collidable`；B：静态 `Dictionary` id→bool |
| D9 | [items/drop_manager.gd](items/drop_manager.gd):205-238 | 合并道具 O(n²) + 一次 8 个并行 `Array.remove_at` | A：`swap_remove` + 单次重建；B：合并键做邻域哈希 |
| D10 | [items/drop_manager.gd](items/drop_manager.gd):267-271、:371-411 | `count` 变化重建 ≤4 个 `MeshInstance3D` 子树 | A：固定副本改 `visible`；B：复用 mesh 实例改数量纹理 |
| L1 | [world/voxel_world.gd](world/voxel_world.gd):111-137 对 [tree_manager.gd](systems/trees/tree_manager.gd):113、[block_entity_renderer.gd](presentation/block_entity_renderer.gd):19、[sound_manager.gd](systems/sound/sound_manager.gd):99、[water_flow.gd](world/water_flow.gd):39 | **正确性回归**：batch 只发 `blocks_changed_batch`，这 4 个消费者只订阅 `block_changed` → 砍树清叶后邻树烘焙光照不刷新（树叶消失但仍投影/高亮）；将来批量删火把会留幽灵实体 | A：batch 事件带 `changed_cells`，消费者各按需处理（树标脏/实体重扫/水流入队/音效忽略）；B：batch 也对每格调 `edit_dirty_cb` 类回调（不用全发 signal） |

### 5.2 P3（14 条）：风格 / 微优化

| 编号 | 位置 | 问题 | 修法 |
|---|---|---|---|
| A9 | [world/chunk_data.gd](world/chunk_data.gd):16、:85-93 | `has_water` 只置不清 → 水退去后每块仍走水位收集 | `set_block` 里旧新值比较后更新（AIR 时重扫必要性低，可接受只置不清但加注释） |
| A10 | [world/voxel_world.gd](world/voxel_world.gd):111-137 | `set_blocks_batch` 仍逐格 `_invalidate_affected_meshes`（每格最多 13 块字典操作） | 先聚合到 `Dictionary` 再去重标脏 |
| A11 | [meshing/native_mesh_bridge.gd](meshing/native_mesh_bridge.gd):124-131 | 每任务重建 `_tile_tables`/`lookup`/`light_padded`（有缓存但仍每次组装） | 把三份表打包成一个 `Dictionary` 一次性缓存 |
| B11 | [systems/sound/sound_manager.gd](systems/sound/sound_manager.gd):170-230 | 每音效新建 `AudioStreamPlayer` + Timer；遮挡射线 32m 而可听 24m | 对象池 + 遮挡距离与可听距离保持一致 |
| B12 | [systems/lighting/cave_fog.gd](systems/lighting/cave_fog.gd) 材质循环 | 每帧对 6 份雾材质写 `u_time` | 统一为 1 个全局参数/共享材质 |
| B13 | [systems/trees/tree_manager.gd](systems/trees/tree_manager.gd):197-215、`_bake_last` | 卸载列按 `_trees.keys()` 全表扫；`_bake_last` 无界增长 | 反向列索引；`_bake_last` 随树删除清理 |
| C8 | [presentation/block_entity_renderer.gd](presentation/block_entity_renderer.gd):86-98、[torch_renderer.gd](presentation/torch_renderer.gd):48-88 | 每火把 3 surface 独立 `MeshInstance3D` → 200 火把 ≈600 draw call | `MultiMeshInstance3D` + per-instance 相位；远处只留光照 |
| C9 | [presentation/texture_atlas_loader.gd](presentation/texture_atlas_loader.gd):69-123 | 每次 generate 25 次 `ResourceLoader.load` + `get_image()`，dock 每 0.4s 重复解码 | 静态缓存 + dock 监听 import 变更 |
| D11 | [scenes/main.gd](scenes/main.gd):341、:461、:562、:570-572 | 每帧新建字面量数组 + 无脏检查重发 `ripple_window`/重复 `texture()` 调用 | 常量数组提成员 + 只在变化时写 uniform |
| D12 | [player/player_controller.gd](player/player_controller.gd) 与 world/items 多处 | 玩家所在格被 4 个系统各自重复采样/查方块 | 每帧算一次 `player_cell` 缓存传递 |
| D13 | [player/player_controller.gd](player/player_controller.gd) 鼠标处理 | `_unhandled_input` 每个 MouseMotion 事件同时 `rotate_y` + 写 `camera.rotation`（1000Hz 鼠标 3-8ms/s） | 累积 delta，`_physics_process` 里一次应用 |
| D14 | [items/grid_inventory.gd](items/grid_inventory.gd) `first_fit` | 每次放入全网格扫描 | 维护首个空位游标（放入后推进，移除后回退） |
| D15 | [scenes/main.gd](scenes/main.gd) 加载期 | 加载遮罩期间 main 仍全帧跑日夜/涟漪/曝光 | 加载期跳过这些子系统 |
| D16 | [scenes/main.gd](scenes/main.gd):527-572 | `_update_ripples` 遍历全部掉落 + 每帧两次 `texture()`/`texture_center()` 调用 | 只遍历水中掉落（已有 `in_water`）+ 缓存引用 |

---

## 六、跨模块根因归纳（8 类）

| # | 根因 | 命中编号 | 为什么反复出现 |
|---|---|---|---|
| 1 | **块级全量重算 × 逐格写入 = 乘数放大** | B1 B5 B6 L1 | 方块写入是「格」事务，光照/树/音效是「块/区域」事务；两者之间没有「一次事务只处理一次区域」的聚合层 |
| 2 | **队列/预算形同虚设** | B2 B6 A8 | 预算只在「条与条之间」检查，单条内部不可切分（单条 3.5ms vs 预算 2ms；单树 24.5ms vs 预算 1 棵） |
| 3 | **每帧全量扫描、没有脏索引** | A1 A4 B8 B9 B13 D1 D4 | 数据结构只有「全集」，没有「脏集合」；先有 `_edit_dirty` 这类局部正确做法，但没有推广 |
| 4 | **无脏检查的每帧重发** | C5 D11 D16 C6 C7 | 参数每帧写一次「反正便宜」，但在 GPU/骨骼上传侧并不便宜（radiance 重烘、骨骼纹理上传） |
| 5 | **热路径分配** | A2 A7 B3 C2 D6 D11 | GDScript 侧的「新建临时 PackedArray / Dictionary / Array 字面量」被当成零成本；>85KB 直接进 LOH |
| 6 | **同步重活无预算** | B4 B5 B6 A5 C1 | 主线程上直接做 O(体积)/O(顶点)/O(字节) 工作，没有「分帧/异步/降级」三选一 |
| 7 | **信号风暴与全量重建** | D7 L1 B10 | 一个逻辑操作发多次 `changed`，消费者按「全量重建」处理；批量通道又绕过了订阅者 |
| 8 | **修复缺少「消费侧」闭环** | B4 B7 L1 B1 | 修的是「生产者」（少发信号/少发事件/换算法），但没核对全部消费者；batch 路径与单格路径的语义分叉无人守护 |

**一句话**：这不是零散的性能问题，而是**缺少「帧预算 + 脏集合 + 批量事务」这一层基础设施**。批次 0-2 的修法本质上都在补这一层，建议在路线图里把它做成显式模块（`FrameBudget` + `DirtySet` + `BatchScope`），而不是继续在各系统内手写。

---

## 七、修复路线图（批次 0-4）

> 排序原则：先止血（P0/秒级卡顿）→ 再补基础设施（光照/水流/脏集合）→ 再攻渲染与流式 → 最后清技术债。每批结束跑 34 套件全绿 + 本报告对应探针。

### 批次 0（1-2 天，止血，风险低）
| 项 | 内容 | 验证 |
|---|---|---|
| B1 | 水流 tick 末聚合批量写 + 光照按块集合去重重算（方案 A，先做「写水静默 + 末尾脏块」的最小版） | `probe_water3` p50<25ms / max<60ms |
| B2 | 光照编辑改块级脏集合 + 每帧 2 块预算（保留单次编辑同步快路径） | 连续 200 次编辑 p99<2.5ms；`test_light_manager` |
| B4 | 音效反射：走廊半径改常数（先止 8-30ms）或直接 DDA | `test_sound` 168 项 |
| A3 | 列排序：缓存 `desired_columns` + 偏转阈值 30°→60°（先降频） | 转视角 600 帧 p99<2ms |

### 批次 1（3-5 天，基础设施，中风险）
| 项 | 内容 | 验证 |
|---|---|---|
| B1/B2 收尾 | `BatchScope`（begin/end 聚合信号）+ 光照块脏集合完整化 + 队列头指针 | 探针 + 回归 |
| B7 | batch 光照顺序无关化（拓扑序 2-3 遍或边界 BFS 收敛） | 新增「跨块光照缝」用例 |
| L1 | batch 事件携带 `changed_cells`，4 个消费者接入 | 砍树后邻树光照刷新；批量删火把无幽灵 |
| D7 | `GridInventory.begin_batch/end_batch` 合并 `changed` | 合成一次只 1 次 HUD 刷新 |

### 批次 2（3-5 天，流式与网格，中高风险）
| 项 | 内容 | 验证 |
|---|---|---|
| A2 | 网格桥只传外壳 1736 格（或复用缓冲 + Span） | `test_native_equivalence` 226 项 + 内存峰值 |
| A1/A4/A5 | `_mesh_dirty_set` + 脏集合驱动 `_poll_jobs` + 入队快照移出主线程 | 800 块场景 `_poll_jobs`<50µs |
| A6/A7 | 草叶统一预算 + `EMPTY_STATE` 常量 | 单块顶点内存上限断言 |
| B5/B6 | 砍树 batch 限定邻域 + `_build_visual` 异步/ms 预算 + `_mark_light_dirty` 按块查 | 单次斧击 <8ms；水流期每帧树重建 ≤3ms |
| B13 | 树列反向索引 + `_bake_last` 清理 | 卸载 200 块后无残留 |

### 批次 3（2-4 天，渲染/GPU，需真机验证）
| 项 | 内容 | 验证 |
|---|---|---|
| C1 | 水面 shader：`DIRS[13]` 常量 + 解析梯度法线（`water_side` 同步） | 真机 GPU 帧时间；水面截图 diff |
| C2/C3 | 涟漪 R8 + 持久缓冲 + 30Hz + 抬高休眠；窗口平移改 offset | `probe_ripple2` p50<1ms、休眠<2s |
| C4/C5/C6 | 远景壳扇区化、天空脏检查、体积雾滞回 | 真机帧时间 + 观感 |
| C7/C8/C9 | 第一人称跳过动画、火把 MultiMesh、图集缓存 | 真机 draw call / 帧时间 |

### 批次 4（2-3 天，玩法与杂项）
| 项 | 内容 | 验证 |
|---|---|---|
| D1/D4-D10 | HUD 计数器、掉落分片与休眠、背包位图、合成批信号、预计算碰撞表、swap_remove、mesh 复用 | `test_items`/`test_drop_manager` 等 |
| D11-D16 | main 常量数组、玩家格缓存、鼠标累积、first_fit 游标、加载期降载、涟漪遍历收窄 | 帧时间探针 |
| A9-A11、B8-B12 | 剩余 P2/P3 | 逐项 |

**不建议做的**：
- 不要在批次 0 直接上「GPU 涟漪」或「多线程光照」——两者都会在 P0 未定时掩盖 B1 的真实收益，且回滚成本高。
- 不要用「降低视距/分辨率」掩盖问题：本报告的实测显示 90% 的峰值来自 O(N) 结构而非绝对负载。

---

## 八、性能预算建议（60fps = 16.6ms）

| 域 | 预算/帧 | 当前观测 | 依据 |
|---|---|---|---|
| 流式调度（`_poll_jobs`+`_update_streaming`） | ≤0.3ms | 0.6-1.5ms（A1）+ 尖刺 9-16ms（A3） | 16.6ms 的 2% |
| 光照（编辑/水流/封盖） | ≤2ms | 单次 0.9ms ✓；水流 tick 137-950ms ✗ | 实测 p50 |
| 网格提交 + 应用 | ≤1ms | 单次 1.05-1.75ms（6 块） | `fc2` |
| 树系统（重建/标脏） | ≤3ms | 5-24.5ms/棵 ✗ | 3-F5 + perf-B |
| 涟漪 | ≤1ms | 3.72ms ✗ | `probe_ripple2` |
| 掉落物物理 | ≤0.5ms | 1.7-3.2k 次 `get_block` ✗ | D4 |
| HUD/UI | ≤0.3ms | 0.25s 节流 + 全目录扫描（~1ms/次）≈ 可接受 | `probe_perfD` |
| **每帧托管分配** | <64KB | B1-B3 单次 0.3-1.8MB ✗ | A2/B3 |
| **GC/LOH** | 0 次/分钟 | 20-90MB/s（A2）✗ | A2 |

可观测性建议：把 `[perf]` 打点统一到 `--perf-log` 门控 + 每秒聚合（p50/p95/max）输出一行，避免日志本身成为尖刺（B10）。

---

## 九、附录

### A. 环境与复现

- Godot 4.7.2.stable.mono，Windows 10/11，headless 跑测（`--headless --script`）。
- 静态：逐文件读 + `git diff fb01aea..HEAD`。
- 动态探针（临时目录已删除，脚本要点已收录于本报告，可按下述方式重建）：
  - 光照/编辑：新建 `SceneTree` 脚本，造 5×5×3 块（16³），挖/放单格后 `Time.get_ticks_usec()` 计时；512 连锁放置看 `burst`。
  - 水流：3×3 水源 + 400 tick，统计 tick 时长分位（开/关 `voxel_light.gd` 两次对比）。
  - 涟漪：直接 `new` `WaterRipples` 实例，`add_impulse` 后逐帧 `step()` 计时直到 `is_idle()`。
  - 全量测试：`tests/run_all_tests.gd`（README 方式，34 套件）。
- GPU 类数字全部标 [待真机验证]：本机 headless dummy 渲染器无法测。

### B. 覆盖缺口与后续验证清单

1. 首轮 100 条中约 52 条 P3/风格类本轮**未逐条重核**（未改文件默认视为未修），见 3.3 列表。
2. GPU：C1/C4/C5/C6/C8 的 ms 为静态推导，需桌面 Forward+ 与 mobile GL Compatibility 各跑一次真机。
3. v9 垂直带（512 高世界）仍**零测试覆盖**（首轮 7-F3 未修）；B1/B2 的改动必须在 `chunks_y∈{1,3}` 之外补一组垂直带用例。
4. B7（跨块光照缝）为静态推导 + C# 语义分析，**必须**先用 Godot 内建场景确认复现（batch 写两跨块格 → 采样边界光照），再决定修法。
5. headless 退出期 `226 RID / 842 ObjectDB leaked` 属既有噪声，但 A2/B6 的改动可能改变数量，建议把该计数纳入回归（差值 >10% 报警）。
6. `test_stress_edits` 的 600 帧超时在慢机上可能偶发失败，建议改成「等到 is_idle 或 1200 帧」并允许 `--slow` 环境变量放宽。

### C. 与首轮报告的关系

- 首轮 [docs/CODE_AUDIT.md](CODE_AUDIT.md) 覆盖：正确性/结构/技术债（100 条，基线 `fb01aea`）。
- 本轮聚焦：**修复复核 + 性能**（48 条，基线 `4d671b2`），不重复首轮条目；修复复核结论见第三章。
- 两份文档可并存：首轮当「缺陷总账」，本轮当「性能专项 + 修复验收单」。建议把本轮 P0/P1 并入首轮路线图批次 0-2 的验收标准。

### D. 统计核对

| 项 | 数 |
|---|---|
| 新发现总数 | 48（P0 1 / P1 10 / P2 23 / P3 14） |
| 其中「新引入（回归）」 | 3（B1 / B7 / L1） |
| 首轮可验证项复核 | 48（修好 13 / 部分 8 / 未修 27） |
| 动态探针 | 8 组（fc2、water2、water3、probe_light_cost、probe_ripple2、probe_perfD、fixcost、tests） |
| 测试基线 | 34 套件 / 12971 项 / 0 失败 / 0 跳过 |

---

*本报告由 4 路并行静态审查 + lead 独立动态验证生成；所有 file:line 均经 read 工具核实，[待验证]/[推导] 标注处未做真机实测。*


