# 瑶海 EPIC 代码审查报告

> 审查日期：2026-11-14 · 审查对象：F:\yaohai-epic（Godot 4.7.2.stable.mono 体素沙盒原型，GDScript + C#）
> 审查方式：7 路并行静态审查（逐条 read 到行级）+ lead 侧 headless 动态验证（全量单元测试、日志取证）
> 结论：**未发现 P0 级缺陷**；共 100 条发现（P1 16 / P2 48 / P3 36）。最优先修的是 3 条数据安全类（存档兜底、掉落丢失、幽灵树）与 6 条帧尖刺类问题。

---

## 一、总体结论

**健康面**：体素内核（坐标/区块/注册表/网格/存档/水流/光照/物品/合成/掉落/树/角色）34 套件 12968 项断言全绿；worker 并发已有深拷贝与 serial 自愈、提交预算、C#/GDScript 对拍等成熟防护；注释密度高且记录了历史修复原因（避免重复踩坑），近两次提交（f097e44 全面审查修复、fb01aea 植被资产）确实修掉了上一轮 P1。

**主要风险集中在四处**：

1. **数据安全（3 条 P1）**：`_dormant` 写盘失败缓存永不重试（退出即丢玩家修改）；挖支撑方块时上方花掉落被丢弃、`_drop_held` 满掉落时不回滚（物品永久消失）；树砍伐事件超上限后重放只剪结构不清体素，产生不可砍的幽灵树干并随存档永久化。
2. **帧尖刺（6 条 P1）**：水流每写一格触发整块 C# 全量重光照（512 格可 250ms+）、方块音早期反射主线程 O(体积) 扫描（10-40ms）、砍树逐格 set_block 触发光照 BFS（可卡数秒）、网格化每块重复打包 27 邻域（干块 0.89MB/水块 1.8MB 托管垃圾）、detail=2 草叶无块级预算（单块上限约 19MB 顶点）、撒树逐层无垂直剪枝（4-10× 冗余生成）。另外 lead 实测 `set_block` 在特定方块上出现 70.6ms（95% 在 `light_on_block_changed`）。
3. **测试体系假信号（3 条 P1/P2）**：C# 生产路径不可用时对拍套件静默 SKIP 仍全绿退出码 0；`test_stress_edits` 误用 `wait_for_task_completion` 使每次跑测刷 1265~1401 条引擎 ERROR 淹没真实错误；512 高垂直流式与 v9 世界零测试覆盖。
4. **结构债**：GD/C# 常量（方块 id、tile 顺序、生成版本）靠人工同步；无 CI/lint/格式化；addons 与 plugins 约 40% 跟踪文件与游戏无关；README 运行段整体失效。

**如果只做 5 件事**：① 修 `_dormant` 落盘兜底；② 修掉落丢失/回滚；③ 修砍树幽灵树 + 批量清叶；④ 把水流/编辑路径的光照重算合并成每帧一次队列；⑤ 让测试的 SKIP 与错误不再静默（退出码与日志判定）。这 5 项合计约 2-3 人日，能消掉全部 P1 的数据安全面与最大帧尖刺面。

---

## 二、测试基线与动态验证（lead 执行）

### 2.1 执行方式

README 给定的入口 `godot --headless --path . -s tests/run_all_tests.gd` 在本机需要绕过两个环境限制：exe 必须先复制进 workspace 才能被沙箱执行；Godot 是 GUI 子系统程序，PowerShell 需轮询 `Get-Process` 等待退出，且需把 `$env:APPDATA` 指向 workspace 内目录（否则 `user://` 写日志被拒）。实际命令：

```powershell
$env:APPDATA = (Resolve-Path .audit_work\appdata).Path
& .\.audit_work\godot.exe --headless --path . -s tests/run_all_tests.gd --log-file .audit_work\tests.log
# 随后循环 Get-Process -Name godot 直到进程退出
```

### 2.2 结果：34 套件 / 12968 项检查 / 0 失败

与 f097e44 提交声称的数字完全一致（12285 + 683 = 12968）。但 0 失败并不等于没问题，见 2.3。

| 指标 | 实测值 |
| --- | --- |
| 套件数 | 34（前 22 套件在 tests.log，后 12 套件用临时 runner 补跑） |
| 断言数 | 12968（12285 + 683） |
| 失败数 | 0 |
| 引擎 ERROR 行 | 每次运行 1265~1401 条 `Invalid Task ID` |
| 导出相关 WARNING | 69 条，覆盖 23 张贴图 |
| 退出期 RID 泄漏 | 1 个 `DummyMesh`（headless 下网格 RID 未释放） |

### 2.3 动态验证暴露的 4 个问题（已与静态审查交叉印证）

#### L1 [P1] 图集贴图用 `Image.load_from_file` 直读 PNG，导出构建整体失效（= part-6 F9）

- 位置：`presentation/texture_atlas_loader.gd:110-114`
- 证据：`return Image.load_from_file(path)`；测试日志中 69 条 `WARNING: Loaded resource as image file, this will not work on export: res://assets/textures/grass_top.png ...`，覆盖 grass_top / grass_side / dirt / stone / log_side / leaves / flower_poppy 等 23 张贴图。
- 根因：编辑器中 res:// 下 .png 是真文件可直读；导出后 png 被导入成 `.ctex`，`res://…/x.png` 不再是原始文件，`Image.load_from_file` 读不到。引擎对此专门发 WARNING，属**导出阻断型**。
- 影响：导出包中 23 张真实材质全部退化为 `_pixel_color()` 程序化色块（树叶 cutout 变实色），贴图包覆盖功能失效。
- 修复 A（首选）：`if not ResourceLoader.exists(path): return null` → `var tex := ResourceLoader.load(path) as Texture2D` → `return tex.get_image()`；
- 修复 B：编辑器工具脚本把 23 张 png 预合成为 res:// 图集资源入库，运行时只 `load` 该资源。
- 验证：导出后运行（或 headless 跑图集生成），确认该 WARNING 归零且图集像素与编辑器一致。

#### L2 [P1] `test_stress_edits` 误用 `wait_for_task_completion`，每次跑测刷约 1400 条引擎错误（= part-7 F6）

- 位置：`tests/test_stress_edits.gd:71-81` ← `world/chunk_manager.gd:461-468`
- 证据：日志尾部反复出现 `ERROR: Invalid Task ID at: is_task_completed (core/object/worker_thread_pool.cpp:397)`，backtrace `_poll_jobs (chunk_manager.gd:466) ← test_stress_edits.gd:76/81`；单次运行 1265 条（tests.log）/ 1401 条（补跑）。
- 根因：`WorkerThreadPool.wait_for_task_completion(id)` 完成后该 task id 即失效，但测试没有把条目从 `_mesh_jobs`/`_gen_jobs` 删除，随后 `_poll_jobs` 对失效 id 调 `is_task_completed`。测试最终 PASS（`is_idle` 终为真），但依赖了不成立的假设。
- 影响：400KB 日志里 1265+ 行同一错误，任何真实 SCRIPT ERROR 都会被淹没；CI 无法据此判定。
- 修复 A：测试只调 `manager._poll_jobs()` + `await tree.process_frame` 直到 `is_idle`（带超时），不要直接 `wait_for_task_completion`。
- 修复 B（更好）：`ChunkManager` 提供公开 `wait_until_idle(timeout)`/`all_idle` 信号，内部自己 poll+wait，测试不再碰私有字典。

#### L3 [P1] `set_block` 单次尖刺约 70ms，耗时几乎全在光照信号分派

- 证据（test_light_manager 内 `[perf]` 行）：`light_on_block_changed 70.2ms` + `signal_fanout 70.4ms` + `set_block 70.6ms` at (8,2,8) block id 17；另一轮 38.7/38.9/39.5ms；其余 set_block 普遍 2-7ms。
- 结论：编辑 1 个方块 95%+ 时间花在 `light_on_block_changed`，是 60fps 单帧预算（16.6ms）的 4 倍。与 part-6 F2（水流逐格触发整块全量重光照）同源，详见 part-6。

#### L4 [P2] 测试能跑但结果不可信：测试日志无法作为 CI 依据

- 现象：一次运行中日志停在 `test_stress_edits` 的刷屏错误处、未见 `=== 总计 … ===` 收尾行（本机 headless 进程在长刷屏下难以判定是完成还是被中断）；退出期还有 `1 RID allocations of type 'N13RendererDummy9DummyMeshE' were leaked at exit.`
- 结论：与 part-7 F8（runner 无超时/无隔离）同一问题——在错误刷屏与无超时叠加下，"全绿"的可信度低。修 L2 + part-7 F2 后此问题自然消失。

### 2.4 静态审查无法覆盖的部分

- 真机渲染/帧时间：审查只做了代码量级推导与测试内埋点，未在带显示环境跑游戏（README 明确本机禁跑 `--import`，且 GUI 下测试会互相抢占）。
- 导出版本行为：L1 是通过 WARNING 推出而非实际导出验证（本机未执行 export）。
- user:// 资产相关（EF JSON、BVH、贴图包）：测试环境无这些资产，相关分支只在逻辑上核对。

---

## 三、发现统计

| 部分 | 审查范围 | P0 | P1 | P2 | P3 | 小计 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | world / physics / persistence | 0 | 2 | 8 | 4 | 14 |
| 2 | meshing / native | 0 | 2 | 6 | 5 | 13 |
| 3 | generation / trees | 0 | 3 | 6 | 5 | 14 |
| 4 | player / characters / main | 0 | 3 | 6 | 8 | 17 |
| 5 | items / interaction / UI | 0 | 2 | 5 | 5 | 12 |
| 6 | presentation / lighting / sound | 0 | 2 | 7 | 7 | 16 |
| 7 | 结构 / 技术债 | 0 | 2 | 10 | 2 | 14 |
| **合计** | — | **0** | **16** | **48** | **36** | **100** |

优先级定义：P0=崩溃/存档损坏/泄漏（本次没有）；P1=真实功能 bug、数据丢失或可感知卡顿；P2=边缘 case、性能隐患、技术债；P3=风格/可维护性。

---

## 四、P1 严重问题汇总（16 条）

| # | 模块 | 问题 | 主要位置 | 建议 |
| --- | --- | --- | --- | --- |
| 1-F1 | part-1 | 视距 padding 环内区块永久网格活锁（commit 必败 + 每帧重入队） | world/chunk_manager.gd:488-494<br>world/chunk_manager.gd:644-651 | 入队侧同时校验水平 `_is_wanted`，统一 wanted 判定与卸载线；commit 拒收时清标记转 dormant。 |
| 1-F2 | part-1 | `_dormant` 写盘失败缓存永不重试，退出即丢玩家修改（与 README 承诺不符） | world/chunk_manager.gd:161-171<br>world/chunk_manager.gd:711-732 | 定期重试落盘 + 退出前 flush pending；写失败降级到 `.bak` 目录。 |
| 2-F1 | part-2 | 每区块网格化重复打包 27 邻域 + C# 侧二次拷贝（托管 LOH 与 GDScript 垃圾主源） | native/NativeMesher.cs:99-101<br>native/NativeMesher.cs:504-520 | 桥侧复用打包缓冲（缓存/pin 27 邻域），避免每次 `AsInt32Array` + 二次拷贝。 |
| 2-F2 | part-2 | detail=2 近距草叶几何规模无块级预算（单块上限约 19 MB，编辑必整块重烘） | meshing/chunk_mesher.gd:724-730<br>meshing/chunk_mesher.gd:774-777 | 按块顶点上限裁剪 detail，复用现有 LOD 降档队列；编辑重烘也走预算。 |
| 3-F1 | part-3 | 撒树按垂直层无条件重放，无垂直剪枝：每层 576 列全扫 + 期望 ~20 棵全树生成全部白算 | generation/terrain_generator.gd:554-588 | 按列先算地表/湿润度再决定是否落树（O(576) 而非 576×层×树）。 |
| 3-F2 | part-3 | 砍伐事件 256 条上限 + 重放只剪结构不清体素：已砍树会“长回”成不可砍的实体树干 / 悬浮叶 | systems/trees/tree_manager.gd:580-589 | cut 事件与体素清理同源：改用 chunk 级 cut 位图，超限也不重置结构版本。 |
| 3-F3 | part-3 | 砍树逐格 world.set_block 清占位：每格触发 529 次空间索引查 + 光照重算，单次砍伐可卡数秒 | systems/trees/tree_manager.gd:625-637 | 批量清叶：直接改 chunk 数组 + 一次性标脏，把光照 BFS 合并到队列。 |
| 4-F1 | part-4 | 键盘事件未过滤 echo：按住 Q 会按系统重复率连续丢物品，按住 E 背包反复开关 | player/player_controller.gd:198-239 | `InputEventKey` 分支统一 `if event.echo: return`（闪避分支已有此判）。 |
| 4-F2 | part-4 | 挖掘动作 0.5s 后冻结：dig 片段 loop=true 而动作层只按 not loop 结束 | characters/clip_lib.gd:205-207<br>characters/character_animator.gd:162-176 | dig/EF 片段改 `loop=false` 或用 `loop_end` 判定结束，动作层支持 loop_end。 |
| 4-F3 | part-4 | 第三人称相机遮挡收缩下限 0.5m 会把机位塞进实心方块（贴墙黑屏/穿墙） | player/player_controller.gd:66-72 | 收缩下限与回退余量同源（或改用 `ShapeCast3D`），限制机位不越过命中面。 |
| 5-F1 | part-5 | 挖掉支撑方块时，上方花的掉落被丢弃（物品永久丢失） | interaction/block_mining.gd:78-86<br>player/player_controller.gd:422-426 | 把 `above` 的 `drops_for()` 结果并入 `mine()` 返回值，由 caller 统一入包。 |
| 5-F2 | part-5 | _drop_held 先扣背包再生成掉落，128 上限时生成失败不回滚，整堆消失 | player/player_controller.gd:452-467<br>items/drop_manager.gd:109-111 | 先 spawn 成功再扣背包（或 spawn 失败回滚），与 `_dispatch_drop` 保持同一兜底。 |
| 6-F1 | part-6 | 每次方块音的早期反射规划在主线程做 O(包围盒体积) 体素扫描，单帧 10-40ms 卡顿 | systems/sound/early_reflections.gd:98-131<br>systems/sound/early_reflections.gd:40-91 | 早期反射结果按方块位置缓存 + 分帧预算，别在音效回调里同步扫体素。 |
| 6-F2 | part-6 | 水流每写入一格水都触发整块 C# 全量重光照 + 光照数组拷贝（洪水/挖渠时 CPU 尖峰） | systems/lighting/voxel_light.gd:292-316<br>world/water_flow.gd:17-19 | 水流写入只标脏，光照重算合并为每帧一次队列；`duplicate` 改按需分块。 |
| 7-F1 | part-7 | 写盘失败的内存兜底 _dormant 永不落盘：退出即永久丢失玩家修改，且内存无回收上限 | world/chunk_manager.gd:711-732<br>world/chunk_manager.gd:161-171 | 同 part-1 F2（同一问题）。 |
| 7-F2 | part-7 | 测试可「零断言 PASS」：C# 生产路径不可用时整套对拍静默 SKIP，全绿退出码 0 | tests/run_all_tests.gd:59-67<br>tests/test_framework.gd:19-22 | 对拍套件的 SKIP 计入失败/启动时显式检查；退出码必须反映覆盖缺失。 |

---

## 五、P2 问题索引（48 条，详情见第七部分）

| # | 模块 | 问题 | 主要位置 |
| --- | --- | --- | --- |
| 1-F3 | part-1 | 存档写盘全部同步在主线程，无分帧预算/后台化（autosave 与卸载双触发） | world/chunk_manager.gd:152-156 |
| 1-F4 | part-1 | `_mark_neighbors_dirty` 只标 6 面，与 26 邻过期比对/对角网格采样不一致 | world/chunk_manager.gd:689-698 |
| 1-F5 | part-1 | 碰撞圈补建走整块重网格，而非仅重建碰撞形状 | world/chunk_manager.gd:409-421 |
| 1-F6 | part-1 | 存档容器 `raw_length` 未校验，损坏文件可触发巨量分配 | persistence/world_save.gd:227-237 |
| 1-F7 | part-1 | 高版本/损坏存档被静默当作新世界，旧档可被覆盖 | persistence/world_save.gd:147-166 |
| 1-F8 | part-1 | worker 光照初始化读取活邻块数据（与主线程并发写竞态） | world/chunk_manager.gd:503-508 |
| 1-F9 | part-1 | water_flow 追帧无上限，掉帧后单帧多 tick 造成尖刺 | world/water_flow.gd:42-46 |
| 1-F10 | part-1 | 主线程每次网格入队做 27×4096 的水位前置扫描 | world/chunk_manager.gd:596 |
| 2-F3 | part-2 | `--greedy` 模式树叶无 cutout 通道 → 树冠变不透明实心大面（GD 与 C# 一致地错） | meshing/greedy_mesher.gd:124-126 |
| 2-F4 | part-2 | GD 贪心回退忽略草 LOD（grass_detail 未传）→ 三级路径密度不一致 | meshing/greedy_mesher.gd:259-265 |
| 2-F5 | part-2 | NativeTerrain 实例缓存键只有 world_seed —— 高度/注册表变更后复用旧实例（可污染存档） | meshing/native_terrain_bridge.gd:16 |
| 2-F6 | part-2 | 出生列同步建网格：主线程逐块 build + ArrayMesh + 碰撞（单帧数十至数百 ms）[待验证] | world/chunk_manager.gd:241-265 |
| 2-F7 | part-2 | 每次入队主线程预收集水位表：27 邻块 × 4096 线性扫描 + states 深拷贝 | world/chunk_manager.gd:596 |
| 2-F8 | part-2 | 远景壳 GenerateShellMesh：逐格独立 4 顶点 + 每格 16 次树采样，单次重建百 MB 级临时分配 [待验证] | native/NativeTerrain.cs:538-543 |
| 3-F4 | part-3 | 旧档 treegen-v1 的 cut 事件被静默丢弃，无迁移、无玩家提示、无测试 | systems/trees/tree_manager.gd:1263-1271 |
| 3-F5 | part-3 | 单棵树重烘实测峰值 24.5ms，注释“毫秒级毛刺”低估；预算按棵数而非耗时 | systems/trees/tree_manager.gd:87-92 |
| 3-F6 | part-3 | 撒树扫 ±TREE_REACH 外圈、TreeManager 只扫本列：视距边缘只见浮空树叶、无树干实体 | systems/trees/tree_manager.gd:185-193 |
| 3-F7 | part-3 | 重建失败路径先 queue_free 旧节点却不置 null 即 return → entry 悬空引用，后续 previously freed 报错 | systems/trees/tree_manager.gd:343-355 |
| 3-F8 | part-3 | 异步 mesh job 只有结构版本号，光照快照陈旧时会覆盖刚完成的同步重烘 | systems/trees/tree_manager.gd:426-448 |
| 3-F9 | part-3 | 倒伏动画/刚体 holder 与树实例解耦：chunk 卸载销毁树不取消倒伏与结算 | systems/trees/tree_manager.gd:548-562 |
| 4-F4 | part-4 | 读档后相机俯仰角丢失（存档写 camera.rotation.x，恢复只写 camera.rotation.x 不写 _pitch） | player/player_controller.gd:91 |
| 4-F5 | part-4 | EF 原始动作片段一律 loop=true，retarget 透传 → 一旦开启战斗，攻击/闪避动作永不结束 | characters/ef_reference_rig.gd:175-181 |
| 4-F6 | part-4 | character_rig 在每个面的循环里重复整盒 classify_faces：每个 cube 做 6 次全量像素级分类 | characters/character_rig.gd:240-248 |
| 4-F7 | part-4 | main 在 focus 接线前调用 load_column_now：新世界出生列被并进 y≈0 的玩家带，多同步生成约 4-6 个区块随即卸载 | scenes/main.gd:220-223 |
| 4-F8 | part-4 | 化身 setup 在加载界面出现之前同步解析全部 EF JSON（97 个文件 ≈ 100-300ms 黑屏） | characters/player_avatar.gd:112-120 |
| 4-F9 | part-4 | _load_cmu_clips 在 retarget 协程最后一帧同步加载全部 user://anim_bvh（单帧数十万次 Transform3D 合成） | characters/player_avatar.gd:280-301 |
| 5-F3 | part-5 | 拖拽期间掉落仍自动入包；原位被占后 _bounce_back 的兜底 add 忽略 leftover，满包时静默丢物品 | player/player_controller.gd:1006-1017 |
| 5-F4 | part-5 | 砍树掉落直连 DropManager，失败无背包兜底（掉落满 128 时整棵树产物丢失） | scenes/main.gd:150-151 |
| 5-F5 | part-5 | 满包合成：材料被扣、产物丢失，can_craft 不校验产出空间且 craft 返回 true | items/crafting_recipes.gd:60-83 |
| 5-F6 | part-5 | 持续挖掘时进度/掉落判定沿用开始挖掘时的工具快照，切换工具不生效 | player/player_controller.gd:388-419 |
| 5-F7 | part-5 | 背包 deserialize 的 typed for 缺少坏元素防护，坏档可能中断读档（与掉落侧防护不一致） | items/grid_inventory.gd:344 |
| 6-F3 | part-6 | 水面镜像 SubViewport 每帧 UPDATE_ALWAYS 再渲染一遍世界，相机静止时也不降频 | presentation/water_reflection.gd:37-41 |
| 6-F4 | part-6 | 洞穴雾脏标不过滤写入类型（水流/树占位写入也标脏）→ 连续编辑期几乎每帧烧 2.5ms；预算只在"柱之间"检查 | systems/lighting/cave_fog.gd:47 |
| 6-F5 | part-6 | voxel_light 的"封盖兜底"只在 C# 可用时生效，GD 回退路径静默跳过 → 残留脏光 | systems/lighting/voxel_light.gd:307-316 |
| 6-F6 | part-6 | 火把/提灯延迟生成不复查方块身份 → 同帧放置+拆除会留下幽灵实体 | presentation/block_entity_renderer.gd:59-73 |
| 6-F7 | part-6 | 964 行未挂载的 sspr_reflection.gd：PREDELETE 漏释放 6 个 pipeline RID 与 2 个 sampler | presentation/water/sspr_reflection.gd:14-22 |
| 6-F8 | part-6 | distant_shell 后台烘壳任务与 _exit_tree 存在 UAF 窗口（窄，退出/重载期） | presentation/distant_shell.gd:99-102 |
| 6-F9 | part-6 | 图集加载在导出包中整体失效：Image.load_from_file 对 res:// 返回 null → 25 个 tile 静默退化为程序化占位 | presentation/texture_atlas_loader.gd:110-114 |
| 7-F3 | part-7 | v9 垂直流式与 512 高世界零单元测试覆盖：所有测试 chunks_y∈{1,3}，column_band 永远走 legacy 全列分支 | core/world_config.gd:12-17 |
| 7-F4 | part-7 | 20+ 验收/探针仍在用遗留 SEA_LEVEL=7：512 高世界里 water/shore 定位永远回退到硬编码 (34,34) | debug/capture_lib.gd:37-47 |
| 7-F5 | part-7 | GD/C# 双份实现的方块 ID、纹理序号、生成版本靠人工同步：错位表现为贴图串色/水变实体，且对拍测试可被 SKIP 绕过 | native/NativeMesher.cs:732-733 |
| 7-F6 | part-7 | 测试直接操作 ChunkManager 私有任务字典并误用 wait_for_task_completion：每轮刷 ~1300 条引擎 ERROR，真实错误被淹没 | tests/test_stress_edits.gd:71-81 |
| 7-F7 | part-7 | 无 CI / 无 lint / 无格式化：12968 项检查没有任何自动准入，测试只能手动跑 |  |
| 7-F8 | part-7 | 测试运行器无超时、无套件隔离：任一 await 悬挂即 headless 永久卡死，静态缓存跨套件累积 | tests/run_all_tests.gd:45-67 |
| 7-F9 | part-7 | addons/plugins 死重：约 40% 跟踪文件与游戏无关，含 1.8MB 预编译二进制与 .smoke 构建产物入库 |  |
| 7-F10 | part-7 | README 运行段整体失效（19 处 ~/godot/godot、首步是已知会卡死的 --import），测试数字与目录结构均已漂移 | tests/run_all_tests.gd:2-3 |
| 7-F11 | part-7 | 分层破坏：单槽 Callable 生命周期总线 + 组合根直写私有成员 + 树系统每帧轮询 chunk_manager 全量状态 | scenes/main.gd:156-159 |
| 7-F12 | part-7 | debug 归档纪律再次被破坏：6 份 capture_lod* 近似副本留在顶层，capture_shadow16 未归档，跨层直读私有字段 | debug/capture_lod3.gd:51 |

P3 共 36 条（风格/注释/死代码/防御性缺口），逐条见第七部分对应模块，未在此展开。

---

## 六、修复路线图

批次划分按「风险 × 依赖」排序，每批内部可按模块并行。

### 批次 0：立即（半天，先恢复可信的绿灯）

1. 修 `test_stress_edits` 误用（part-7 F6 / L2）：改为 poll + 超时，跑测后日志 `Invalid Task ID` 应为 0。
2. 让对拍套件的 SKIP 不再静默（part-7 F2）：SKIP 记为失败或输出显式 `[SKIP]` 并在退出码体现。
3. 给 runner 加超时与逐套件日志（part-7 F8），避免 headless 卡死和 400KB 噪音。

### 批次 1：数据安全与正确性（1-2 天，全部 P1 功能 bug）

1. `_dormant` 落盘兜底（part-1 F2 = part-7 F1）——**最高优先**，涉及玩家修改丢失。
2. 掉落丢失三处（part-5 F1/F2、part-5 F4 的砍树兜底）。
3. 砍树幽灵树（part-3 F2）+ 批量清叶（part-3 F3）——两者同改 `tree_manager`，建议一起做。
4. 玩家侧三条：键盘 echo（part-4 F1）、挖掘冻结（part-4 F2）、相机穿墙（part-4 F3）。
5. 图集导出（part-6 F9 / L1）——一条 5 行改动，但决定导出版观感。
6. 视距 padding 环网格活锁（part-1 F1）——影响流式稳定性，改动小、需补测试。

### 批次 2：帧尖刺（2-4 天，性能 P1）

1. 光照重算队列化：水流（part-6 F2）+ 编辑（L3）合并为每帧一次；`voxel_light` 增加 dirty 队列与预算。
2. 砍树/撒树：part-3 F1（垂直剪枝）与 F3（批量清叶）在同一路径，一起做。
3. 网格化内存：part-2 F1（27 邻域打包）→ part-2 F2（草叶预算）→ part-1 F10 / part-2 F7（入队前置扫描）。
4. 音效早期反射（part-6 F1）：缓存 + 分帧。
5. 存档同步写盘（part-1 F3）：至少改为分帧/后台队列，避免 autosave 与卸载叠加卡帧。

### 批次 3：测试与工程化（1-2 天）

1. 补 512 高 / v9 垂直流式测试（part-7 F3）与 `SEA_LEVEL` 迁移（part-7 F4）。
2. 消 GD/C# 常量手工同步（part-7 F5）：把方块 id / tile 顺序 / 生成版本收敛为一份契约（生成脚本或共享 JSON）。
3. 加 CI：headless 测试 + 退出码 + 日志关键字扫描（`Invalid Task ID`、`leaked`、`this will not work on export` 任一出现即失败）（part-7 F7）。
4. 清理 addons/plugins 死重与 `.smoke` 产物（part-7 F9）；修 README 运行段（part-7 F10）。

### 批次 4：持续清扫（P2/P3）

1. 原则：每个 P2 在碰到相关文件时顺手修；P3（注释/死代码/风格）批量清理，优先 `debug/` 与 `presentation/water/sspr_reflection.gd` 这类未挂载/未使用代码。
2. 性能类 P2（part-6 F3/F4、part-2 F3/F8、part-1 F9）建议先做「可观测性」：把已有 `[perf]` 埋点接成帧时间统计，再决定改哪个。

---


## 七、各模块详情

### 7.1 part-1 — world / physics / persistence

#### 概览

审查范围：`world/`（chunk_manager 889、chunk_data 158、chunk_state 16、voxel_world 210、water_flow 248、water_ripples 191）、`physics/`（chunk_collision_builder 32、voxel_raycast 90）、`persistence/`（world_save 318、chunk_serializer 170、save_migrations 22），共 11 个 .gd 文件、2344 行（read totalLines）。已读全部文件正文，重点精读 chunk_manager 全文与 world_save/chunk_serializer/water_flow 全量；另对照 README.md、tests/、debug/、git log（fb01aea、f097e44、ff07d1b、005c668、257877b）核实设计意图。

健康度结论：分层清晰（数据/流式/表现/存档解耦，任务预算与 edit_serial 过期检查到位），f097e44 的已知修复已落地；但流式加载存在「入队宽、提交严」的双阈值缺口（F1，P1 活锁），存档侧有两条可靠性缺口（F2 dormant 永不重试=数据丢失；F3 写盘全在主线程=周期卡顿）。其余为边缘 case、并发技术债与文档漂移。P0 未发现（未看到无条件崩溃/不可控内存泄漏路径）。

#### 发现

##### F1 [P1] 视距 padding 环内区块永久网格活锁（commit 必败 + 每帧重入队）
- 位置：`world/chunk_manager.gd:488-494`（入队）、`world/chunk_manager.gd:644-651`（提交拒收）、`world/chunk_manager.gd:735-743`（严格 wanted）、`world/chunk_manager.gd:287-295`（卸载线 view+padding）、`world/chunk_manager.gd:556`+`world/chunk_manager.gd:689-698`（触发标脏）
- 证据：
```gdscript
	for coord in world.chunks:
		if in_flight_count() >= max_in_flight:
			break
		var chunk: ChunkData = world.chunks[coord]
		if (chunk.mesh_dirty or chunk.collision_dirty) \
				and not _mesh_by_coord.has(coord):
			_enqueue_mesh(coord)
```
```gdscript
	if not _is_wanted(coord):
		# 水平出视距。仍在卸载缓冲内（padding>0）的区块不会被卸载、
		# 也无重排源——补回 mesh_dirty 触发重排，否则网格缺失卡
		# MESH_QUEUED（_enqueue_mesh 已清标记）
		if not should_unload_column(coord, _focus_column(),
				view_distance, unload_padding):
			chunk.mesh_dirty = true
		return false
```
```gdscript
	var col := Vector2i(coord.x, coord.z)
	if col.distance_squared_to(center) > view_distance * view_distance:
		return false
```
- 根因：入队侧脏循环只按垂直 `_in_band`（`_enqueue_mesh` 内部 `world/chunk_manager.gd:571`）过滤，不检查水平 `_is_wanted`；提交侧用严格 view_distance=16 判废，而卸载用 view_distance+unload_padding=18，于是水平距离 17-18 的「已加载、可被标脏、但永不需要网格」区块成为活锁区：commit 失败后 :648-650 把 mesh_dirty 回写，下一帧脏循环再入队，worker 全量建网格→丢弃→再标脏，无限循环。触发链：玩家前进 1 列后停步，前沿新生成的距离 16 区块在 `_commit_generation`（:556）调 `_mark_neighbors_dirty`，把已加载的距离 17 前邻居标脏（`_mark_neighbors_dirty` 只标 6 面邻居）。
- 影响：停步后数十个 padding 区块持续占用 WorkerThreadPool 做全量网格构建（每块 3-10ms）并被丢弃，CPU 长跑、真正需要的区块重建吞吐下降；`is_idle()`（`world/chunk_manager.gd:202-209`）恒 false，`scenes/main.gd:157`、`tests/test_stress_edits.gd:73`、`debug/streaming_check.gd:59` 及全部 debug/capture 工具的「等待流式安定」会超时（capture 超时后截到的画面可能缺区块）。玩家移动后（距离降到 16 以内）或走出 18 才会自愈。
- 修复方案：A) 推荐：`_commit_mesh` 的 `not _is_wanted(coord)` 分支改为「视为无需网格化」——清 `chunk.mesh_dirty`/`chunk.collision_dirty` 并置 `chunk.state = ChunkState.State.DATA_READY`，不再回写脏标记（与 `_enqueue_mesh` :571-575 的带外语义一致；padding 环本来就不需要网格）。B) 或在 `_poll_jobs` 脏循环与 `_enqueue_mesh` 入口同时加水平过滤 `_is_wanted(coord)`（保留垂直 band 检查），从源头不产生这些任务。取舍：A 改动最小且不会误伤「带内、但提交时已出视距」的极端情形；B 会多一次半径计算。
- 验证：站到新到达位置静止 300 帧，断言 `chunk_manager.is_idle() == true` 且 `in_flight_count() == 0`；加探针统计「`_commit_mesh` 因 `not _is_wanted` 返回 false 且随后 `mesh_dirty` 被回写」的次数，修复后 10 秒内应为 0；`debug/streaming_check.gd` 的 `_wait_idle` 应不再打印卡脏区块。

##### F2 [P1] `_dormant` 写盘失败缓存永不重试，退出即丢玩家修改（与 README 承诺不符）
- 位置：`world/chunk_manager.gd:161-171`（save_all）、`world/chunk_manager.gd:711-732`（_unload_chunk 入 dormant）、`world/chunk_manager.gd:127-139`（_exit_tree）、`README.md:529`
- 证据：
```gdscript
func save_all(player_state: Dictionary) -> int:
	var saved := 0
	for coord in world.chunks:
		var chunk: ChunkData = world.chunks[coord]
		if chunk.save_needed and save_system.save_chunk(chunk):
			saved += 1
```
```gdscript
		if not persisted:
			# 写盘失败：内存兜底缓存，绝不丢玩家修改（§4.4）
			chunk.state = ChunkState.State.EVICT_PENDING
			_dormant[coord] = chunk
```
```gdscript
	if save_system != null:
		save_all(_current_player_state())
```
- 根因：`_dormant` 语义是「卸载时写盘失败的待保存队列」，但 save_all 只遍历 `world.chunks`（dormant 已 `world.remove_chunk`，不在其中）；退出保存同样只走 save_all；`_dormant` 唯一出口是区块重新进视距时的 `_restore_dormant`（`world/chunk_manager.gd:701-708`）。README.md:529 写「保留内存缓存绝不丢玩家修改…下次卸载/自动保存重试写盘」，实现里没有任何重试路径。
- 影响：磁盘满/文件被占用（杀软、同步盘）/权限错误导致卸载写盘失败时，该区块所有修改只留在内存；之后 10 秒自动保存与退出保存都不会补写，退出即永久丢失（数据丢失），且 `_dormant` 无上限增长（长时间运行内存只增不减）。
- 修复方案：A) 推荐：save_all 末尾追加遍历 `_dormant`，逐块 `if save_system.save_chunk(chunk): _dormant.erase(coord)`（区块已不在 world，无需 add/remove；注意不在遍历中直接 erase，先收集成功列表）。B) 或在 `_process` 的 autosave 分支单独调用 `_flush_dormant()`，失败保留并在 HUD 告警。
- 验证：单测用 mock save_system 令首次 save_chunk 返回 false：改方块→走出视距（进 dormant）→调 save_all→断言 dormant_count()==0 且文件已写；真实场景可用只读目录/占满磁盘模拟，确认退出后重进修改仍在。

##### F3 [P2] 存档写盘全部同步在主线程，无分帧预算/后台化（autosave 与卸载双触发）
- 位置：`world/chunk_manager.gd:152-156`（10s autosave）、`world/chunk_manager.gd:161-171`（save_all）、`world/chunk_manager.gd:711-732`（卸载内同步 save_chunk）、`persistence/world_save.gd:173-198`（save_chunk）
- 证据：
```gdscript
	if save_system != null:
		_autosave_accumulator += _delta
		if _autosave_accumulator >= autosave_interval:
			_autosave_accumulator = 0.0
			save_all(_current_player_state())
```
```gdscript
	var payload := ChunkSerializer.serialize(registry, chunk)
	if payload.is_empty():
		return false
	var compressed := payload.compress(FileAccess.COMPRESSION_ZSTD)
	var container := StreamPeerBuffer.new()
	...
	var ok := _atomic_write(path, container.data_array, verify)
```
- 根因：每块保存 = 调色板遍历 4096 体素 + 稀疏状态 JSON + zstd 压缩 + 写文件 + 回读校验 + rename，全部在主线程；三个触发点（10s autosave、区块卸载、退出）都没有每帧时间预算或后台化。
- 影响：一次大范围水/树/建造后若有 50 个脏区块，autosave 帧 ≈ 50-150ms 单帧尖刺（按 1-3ms/块静态估算）；快速旅行时 `_update_streaming` 同帧卸载并保存多块（`_unload_chunk` :720-727 内同步写）可能有百 ms 级卡顿，与网格提交峰值叠加。周期性出现（每 10s），可感知。
- 修复方案：A) 推荐：serialize+zstd 前把区块数据快照（`block_ids.duplicate()`、`sparse_block_states.duplicate(true)`、dimensions/coord）后交给 worker 压缩，主线程只做写文件+rename；同时给 save_all 加每帧 4ms 时间预算，剩余留到下一帧。B) 最低成本：卸载路径改为把「待写区块」入队，由 autosave 预算统一调度，避免卸载帧集中写。
- 验证：debug 探针统计 save_all/单块 save_chunk 耗时（`world_save.gd:173-198` 前后埋点）；50 块脏时单帧应 <8ms；编辑 50 块后记录 autosave 帧时间。

##### F4 [P2] `_mark_neighbors_dirty` 只标 6 面，与 26 邻过期比对/对角网格采样不一致
- 位置：`world/chunk_manager.gd:689-698`、`world/chunk_manager.gd:632-634`、`world/voxel_world.gd:193-204`（编辑路径已补对角）
- 证据：
```gdscript
func _mark_neighbors_dirty(coord: Vector3i, horizontal_only := false) -> void:
	var deltas := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0)]
	if not horizontal_only:
		deltas.append_array([Vector3i(0, 1, 0), Vector3i(0, -1, 0)])
	deltas.append_array([Vector3i(0, 0, 1), Vector3i(0, 0, -1)])
```
```gdscript
## 过期比对覆盖全部 26 邻（曾只查 6 面——水面角点高度/岸衰减与
## 光照平滑采样都会读对角区块，角格编辑后对角网格曾带旧数据提交）
```
- 根因：数据到达路径（`world/chunk_manager.gd:556`、`:384`、`:268`）只把 6 面邻居标脏；但网格采样确实读对角区块：水位表 27 邻合并（`meshing/chunk_mesher.gd:888-908`）+ 水面角点高度读跨块 padded 的 2x2 四格（`meshing/chunk_mesher.gd:1070-1094`），过期比对也扩到 26 邻（`world/chunk_manager.gd:634`）。编辑路径已在 `world/voxel_world.gd:196-204` 补 xz 对角，两条路径不一致。
- 影响：新对角区块数据（水体/地形/光照）到达时，已 ACTIVE 的对角邻居不会重建，其区块角落保留「邻块未加载=空气」时代的水面高度/岸衰减/平滑光照 → 角落水面错位、裂缝或光照缝，直到玩家在该处编辑触发重网格或区块重新加载。视觉瑕疵、随机出现（取决于加载顺序），不崩溃。
- 修复方案：A) `_mark_neighbors_dirty` 水平方向追加 4 个 xz 对角 `Vector3i(±1, 0, ±1)`；B) 若担心标脏成本，可在 `_commit_generation` 成功路径单独对 26 邻标脏（与 `NEIGHBOR_EXPIRE_INDICES` 对齐），预热列路径 `horizontal_only` 只补对角 4 个。
- 验证：两区块交界角放/挖水后截图对比角点水面高度与两侧是否连续；单测：加载邻块后断言其 xz 对角邻居 `mesh_dirty == true`。

##### F5 [P2] 碰撞圈补建走整块重网格，而非仅重建碰撞形状
- 位置：`world/chunk_manager.gd:409-421`（_ensure_collision_ring）、`world/chunk_manager.gd:488-494`（脏循环→全量网格）、`world/chunk_manager.gd:672-676`（commit 应用）、`presentation/chunk_renderer.gd:155-164`（重建 ConcavePolygonShape3D）
- 证据：
```gdscript
	for coord in world.chunks:
		var chunk: ChunkData = world.chunks[coord]
		if chunk.state != ChunkState.State.ACTIVE:
			continue
		if Vector2i(coord.x, coord.z).distance_squared_to(center) > r2:
			continue
		if renderer.has_collision(coord):
			continue
		chunk.collision_dirty = true
```
```gdscript
	var want_collision := Vector2i(coord.x, coord.z) \
			.distance_squared_to(_stream_center) \
			<= collision_radius * collision_radius
	renderer.apply_mesh(coord, mesh_arrays,
			chunk.collision_dirty and want_collision)
```
- 根因：`collision_dirty` 复用了 mesh 脏标记的整条管线——脏循环会 `_enqueue_mesh` 让 worker 全量重建网格数组，`apply_mesh` 同时重建 ArrayMesh 与顶点汤；但这些区块的面数据没变，只需要重建碰撞形状。
- 影响：玩家每跨 1 列，新进入 collision_radius=4 圈的列（约 7 列 × 带内 2-4 层 ≈ 15-30 块）全部整块重网格+碰撞重建，持续吃满每帧网格提交预算（3 块/8ms），跑动时掉帧并延迟玩家视野内区块的网格更新；ConcavePolygonShape3D 顶点汤重建本身是 `chunk_renderer.gd:157` 的较贵操作。
- 修复方案：A) 推荐：`ChunkRenderer` 增加仅碰撞重建入口（缓存每块最近一次 mesh_arrays 或碰撞 faces），`apply_mesh` 拆出 `rebuild_collision_only`，跳过 ArrayMesh/instance 重建；B) 若不想缓存：`collision_dirty` 且 `chunk.state == ACTIVE` 的区块在主线程直接同步重建碰撞（无 worker 任务），网格不动。
- 验证：跑动探针统计 `apply_mesh`/`collision_build` 次数与帧时间；跨列后应只有碰撞重建、`chunk_mesh` worker 任务数为 0；帧时间不超 8ms 预算。

##### F6 [P2] 存档容器 `raw_length` 未校验，损坏文件可触发巨量分配
- 位置：`persistence/world_save.gd:227-237`（load_chunk）
- 证据：
```gdscript
	var raw_length := peer.get_u32()
	# 此时光标恰在读完 10 字节容器头之后（magic 4 + 版本 2 + 长度 4）
	var compressed_result: Array = peer.get_data(raw.size() - 10)
	...
	var payload := (compressed_result[1] as PackedByteArray).decompress(
			raw_length, FileAccess.COMPRESSION_ZSTD)
```
- 根因：`raw_length` 直接取自文件头，未与文件实际长度/合理上限比对即作为 `decompress` 的输出缓冲大小；写入路径写的是 `payload.size()`（`persistence/world_save.gd:191`），但读路径完全信任头部。
- 影响：文件位翻转/手工伪造使 raw_length 变成 0xFFFFFFFF 时，读档按 4GiB 预分配 → OOM 崩溃或长时间卡死（读档在 worker 线程也救不了进程内存）。正常流程（原子写保证自身一致）概率低，属健壮性缺口。
- 修复方案：A) 读头部后加 `if raw_length <= 0 or raw_length > 64 * 1024 * 1024: push_warning(...); return null`，并校验 `raw.size()` 与压缩体长度下限；B) 改用流式解压并设置输出上限，或对 16³ 区块按 dims/调色板估算上限。
- 验证：单测把容器头 raw_length 改成 0xFFFFFFFF，`load_chunk` 应返回 null（走重新生成）且内存不暴涨；`_verify_chunk_file` 可复用于读路径。

##### F7 [P2] 高版本/损坏存档被静默当作新世界，旧档可被覆盖
- 位置：`persistence/world_save.gd:147-166`（load_meta 返回 {}）、`persistence/world_save.gd:224-226`（高版本区块直接 null）、`scenes/main.gd:88-91`（空 meta→新世界，save_root 不变）、`persistence/save_migrations.gd:3,9`
- 证据：
```gdscript
	if not SaveMigrations.is_format_compatible(
			int(meta.get("format_version", -1))):
		push_warning("存档格式版本 %d 不受支持，按新世界处理" % [
			int(meta.get("format_version", -1))])
		return {}
```
```gdscript
	var meta := save_system.load_meta()
	if meta.is_empty():
		config.world_seed = WORLD_SEED
		config.chunks_y = NEW_WORLD_CHUNKS_Y
```
- 根因：`save_migrations.gd:3` 明确「格式版本不向前兼容（高版本存档拒读）」；load_meta 对不兼容/损坏 meta 返回 {}，main 按新世界（seed 1337/chunks_y 32）启动且**沿用同一 save_root**；10 秒后 autosave 用 `_atomic_write` 覆盖 world.json，玩家继续游玩时同名坐标的新区块覆盖旧 chunk 文件。`load_chunk` 对 `container_version > FORMAT_VERSION` 也返回 null（:224-226），区块被重新生成后同样会被写回。
- 影响：未来格式升级后降级运行、或 world.json 损坏时，旧世界被静默替换：无明确提示（只有控制台 push_warning），旧元数据先丢，旧区块被新世界同坐标数据逐步覆盖 = 不可逆数据丢失。README.md:530 把「损坏元数据按新世界处理」列为策略，但没有保护旧档。
- 修复方案：A) 推荐：load_meta 返回不可兼容标记（区分「无存档」与「有存档但不可读」），main 在后者走保护分支——启动时把整个 root 重命名为 `world1.bak-<时间戳>`（或改用新目录），并 HUD 明确提示；B) 或进入只读模式（禁止 autosave/退出保存）等用户确认，UI 成本更高。
- 验证：tests 造 `format_version=99` 的 world.json + 若干区块，启动后断言原目录未被写入（或已备份），且提示可见；`load_meta` 返回 {} 时 main 不走「同目录新世界」分支。

##### F8 [P2] worker 光照初始化读取活邻块数据（与主线程并发写竞态）
- 位置：`world/chunk_manager.gd:503-508`（只快照引用）、`world/chunk_manager.gd:527-538`（worker 内调 light_init_cb）、`systems/lighting/voxel_light.gd:54-58,70-81`（读 nb.light）、`systems/lighting/voxel_light.gd:180-206`（_seed_in_from_neighbors 读邻块 light）
- 证据：
```gdscript
	var job := {
		"coord": coord,
		"result": null,
		# 光照初始化用的 6 面邻块快照（worker 内查 dict 有并发风险）
		"light_neighbors": _collect_light_neighbors(coord),
	}
```
```gdscript
	if light_init_cb.is_valid():
		light_init_cb.call(chunk, job["light_neighbors"])
```
```gdscript
		else:
			nlights.append(nb.light)
			nexists[k] = 1
```
- 根因：`light_neighbors` 只是 6 个 ChunkData 的**引用**（注释自认「worker 内查 dict 有并发风险」），worker 线程内 `init_chunk_light` 读邻块 `light`/`block_ids`，而主线程同时可能执行玩家编辑/光照传播写同一邻块数组 → 非原子读。mesher 路径已用 `states.duplicate(true)`（`world/chunk_manager.gd:601`）修过同类哈希表并发问题，光照路径漏了。
- 影响：区块边界光照可能算错（块边亮/暗缝、水面附近光斑），属视觉瑕疵；之后 `on_chunk_ready` 边界播出/任意编辑会重算，可自愈。不崩溃，属并发技术债。
- 修复方案：A) 推荐：入队时深拷贝 6 邻光照（每块 4096B，6 块 ≈24KB/任务，可接受）随 job 传入 worker，worker 只读快照；B) 或把光照初始化移到主线程（C# 路径注释称 ~1ms；GD 回退 p50 23ms 偏高，仅在 Native 不可用时考虑）。
- 验证：stress 并发编辑测试增加光照参考真值断言（或单线程模式对比）；用 worker 写屏障/日志确认 worker 不再读活 ChunkData。

##### F9 [P2] water_flow 追帧无上限，掉帧后单帧多 tick 造成尖刺
- 位置：`world/water_flow.gd:42-46`（_process 累积循环）、`world/water_flow.gd:17-19`（TICK_INTERVAL/MAX_CELLS_PER_TICK）、`world/water_flow.gd:65-77`（tick）
- 证据：
```gdscript
func _process(delta: float) -> void:
	_accumulator += delta
	while _accumulator >= TICK_INTERVAL:
		_accumulator -= TICK_INTERVAL
		tick()
```
```gdscript
	for pos in positions:
		if evaluated >= MAX_CELLS_PER_TICK:
			_pending[pos] = true  # 顺延下一 tick
			continue
```
- 根因：tick 频率追赶按真实时间累积，没有单帧 tick 数上限；预算只在 tick 内按格数（512/tick）限制。加载停顿/切后台/卡顿 2 秒后同一帧跑 8 个 tick。
- 影响：8×512=4096 格评估；每格 `_evaluate`（`world/water_flow.gd:82-130`）至少 6 次 `world.get_block`（每次边界检查+坐标换算+字典查）+ `_spread_dirs`（:154-173）最多 16 次查找，还有最多数千次 `set_block`/水位状态写（每次触发数据标脏）→ 单帧 20-60ms 级尖刺，且卡顿会进一步累积 accumulator，形成恶性循环。
- 修复方案：A) 每帧最多 2 tick：`var steps := mini(2, int(_accumulator / TICK_INTERVAL))` 循环，随后 `_accumulator = minf(_accumulator, TICK_INTERVAL * 2)`；B) 改「单帧总评估格数预算」（如 1024 格/帧），跨帧顺延。
- 验证：测试注入 `delta = 2.0` 的单帧，测量 tick 耗时/评估格数；断言单帧 evaluated ≤ 2×MAX_CELLS_PER_TICK，且 `pending_count()` 不会因累积暴涨。

##### F10 [P2] 主线程每次网格入队做 27×4096 的水位前置扫描
- 位置：`world/chunk_manager.gd:596`（主线程 collect）、`meshing/chunk_mesher.gd:899-908`（_merge_water_levels 的 has 扫描）
- 证据：
```gdscript
		# 主线程预收集水位表：worker 侧 collect 遍历 sparse_block_states
		# Dictionary，与主线程水位 tick 的增删并发可致哈希表损坏
		#（审查发现）；PackedArray 撕裂由 serial 比对自愈不需快照
		"water_levels": ChunkMesher.collect_water_levels_world(chunk, neighbors),
```
```gdscript
static func _merge_water_levels(levels: Dictionary, chunk: ChunkData) -> void:
	if chunk == null or not chunk.block_ids.has(VoxelTypes.WATER_ID):
		return
```
- 根因：为避免遍历稀疏状态字典的并发问题，`collect_water_levels_world` 对 27 邻逐块先做 `PackedInt32Array.has(WATER_ID)` 线性扫描（4096 元素）判断有无水；多数陆地区块无水 → 每次入队白扫 27×4096≈11 万次整数比较，全部在主线程完成。
- 影响：加载期与大范围编辑后的重建风暴中，`_poll_jobs` 脏循环每帧可入队数十块 → 数百万次比较/帧（静态估算 2-8ms，未实测），延迟入队/提交；不改变正确性。海/湖附近区块水位表本身也只为角点高度服务。
- 修复方案：A) `ChunkData` 增加 `has_water` 布尔（`set_block` 写/清 WATER 时更新，生成结束时统计一次），`_merge_water_levels` 直接跳过无水块，避免线性扫描；B) 缓存每区块水位字典（按 edit_serial/水位版本失效），入队只合并增量。
- 验证：probe 统计 `_enqueue_mesh` 主线程耗时（含 27 邻），改 has_water 后单块入队应 <0.1ms；对比加载 300 帧的总耗时。

##### F11 [P3] chunk_serializer 状态段长度只用 assert 保护（release 下截断）
- 位置：`persistence/chunk_serializer.gd:68`（count u16）、`persistence/chunk_serializer.gd:74-77`（长度 assert）
- 证据：
```gdscript
	peer.put_u16(chunk.dimensions.z)
	peer.put_u16(palette_names.size())
	for block_name in palette_names:
		var name_bytes := block_name.to_utf8_buffer()
		peer.put_u16(name_bytes.size())
		peer.put_data(name_bytes)
	peer.put_data(data)
	# v2：稀疏状态段（局部坐标 -> JSON 状态字典）
	peer.put_u16(chunk.sparse_block_states.size())
	for local in chunk.sparse_block_states:
		var state: Dictionary = chunk.sparse_block_states[local]
		peer.put_u16(local.x)
		peer.put_u16(local.y)
		peer.put_u16(local.z)
		var state_bytes := JSON.stringify(state).to_utf8_buffer()
		assert(state_bytes.size() < 65536, "状态字典过大，需分片存储")
		peer.put_u16(state_bytes.size())
		peer.put_data(state_bytes)
	return peer.data_array

## 返回 null 表示数据损坏/不兼容（已记录日志），调用方回退到重新生成。
```
- 根因：稀疏状态条数与单条 JSON 字节数都写 u16，但只 assert 上限；Godot release 导出默认剥离 assert 后，超长状态段会写截断长度，读取端按截断长度取 JSON 解析失败（`chunk_serializer.gd` deserialize 状态段循环里 json_length 不足 break）→ 该格状态被静默丢弃。调色板 255 已在 `serialize` 中改为显式失败返回空载荷，状态段未对齐。
- 影响：极端情况（单格状态 JSON ≥64KB，如异常/超长容器内容）存档状态静默丢失且无报错；概率低，但属于「写坏档」类风险。
- 修复方案：A) 与调色板一致：写 u16 前显式检查 `if state_bytes.size() >= 65536: push_error(...); return PackedByteArray()`，让 `world_save.save_chunk` 返回 false 保留旧档；B) 状态段改 u32 长度 + CHUNK_FORMAT_VERSION 3 迁移。
- 验证：构造超长状态 JSON 的区块调用 `ChunkSerializer.serialize`，断言返回空载荷且不写文件；release 构建重复。

##### F12 [P3] `_commit_generation` 注释/提交记录声称的「带+pad 宽判」与实现不符
- 位置：`world/chunk_manager.gd:547-550`
- 证据：
```gdscript
	# 提交期用带+pad 宽判（与卸载一致）——曾用 _is_wanted 严格带判：
	# 玩家层波动让刚生成的 pad 缓冲层在此被丢弃，state 卡 DATA_READY
	# 且 mesh 永不建立（实测 512 世界单区块无限重入队、is_idle 恒 false）
	if not _is_wanted(coord) or _outside_band(coord) \
			or world.has_chunk(coord):
```
- 根因：注释（以及 ff07d1b 提交说明「提交期带+pad 宽判…」）声称已改为宽判，但 `_is_wanted`（`world/chunk_manager.gd:735-743`）仍是严格 band：`not _is_wanted(coord)` 为 true 时直接丢弃，pad 层永远到不了 `_outside_band` 的 ±1 滞回。
- 影响：垂直带扩张/收缩瞬间，刚生成的 pad 层任务被丢弃（数据不保留，等下次带扩展重新生成），浪费生成工作；与 F1 不同不会卡死（pad 层不再被请求）。属可维护性风险：后人按注释修改会误判行为；也有回归复发的可能。
- 修复方案：A) 按注释意图改宽判：`if _outside_band(coord) or world.has_chunk(coord): return false`（band+1 内保留数据，是否网格化交由 `_enqueue_mesh` 的 `_in_band` 判断）；B) 或修正注释与提交记录，明确当前为严格 band 丢弃。
- 验证：垂直带上下移动时观察 pad 层任务是否被保留（state DATA_READY 但不在 band）；单测断言 commit 后区块存在；`git blame` 确认该行最近一次修改。

##### F13 [P3] README / 调试注释过时（视距 5、垂直 3 区块）
- 位置：`README.md:507`、`README.md:513`、`debug/streaming_check.gd:75-86`
- 证据：
```md
| 区块管理器 | `world/chunk_manager.gd`：按玩家位置流式加载/卸载（视距 5 区块半径 + 卸载缓冲 2） |
```
```md
| 世界无限化 | 水平方向无限流式，垂直高度固定（3 区块）；玩家脚下区块未就绪时冻结物理 |
```
- 根因：005c668 把默认视距 5→16 chunks（256 格），ff07d1b 把 chunks_y 改为 32（512 格）；README 与 `debug/streaming_check.gd` 的注释/期望（「视距 5：圆内约81列×3=243区块」）未同步。`world/chunk_manager.gd:27-64` 的导出默认值才是事实来源（view_distance=16、collision_radius=4、unload_padding=2）。
- 影响：文档误导后续审查/调参（本次审查即先被 README:507 误导）；调试工具判读基准错误，可能误判区块数异常。不影响运行。
- 修复方案：更新 README:507/513 与 streaming_check 注释/期望，或直接引用导出变量名（view_distance、chunks_y）而非硬编码数字。
- 验证：grep「视距 5」无残留；streaming_check 启动时打印实际 view_distance/chunk_count 对照。

##### F14 [P3] voxel_raycast.gd 不可达 return（死代码）
- 位置：`physics/voxel_raycast.gd:58-90`
- 证据：
```gdscript
	while true:
		...
		if world.registry.is_targetable(world.get_block(pos)):
			result.hit = true
			...
			return result
	return result
```
- 根因：`while true` 内所有分支都 return（`t_next > max_distance` 时 return、命中时 return），循环后的 `return result` 不可达；GDScript 不报错，属死代码。
- 影响：无功能影响，仅可读性/静态检查噪音。
- 修复方案：删除末尾 `return result`；或把循环改成有界 `for` + 显式结束返回（便于静态分析器检查）。
- 验证：测试行为不变（`tests/test_voxel_raycast` 类用例若存在应全绿）；静态检查无 unreachable 警告。

#### 已核查无问题的风险点

1. `world/chunk_manager.gd:313-325`：卸载遍历用 `world.chunks.keys()` 副本再 `_unload_chunk`，边遍历边删字典安全（注释亦写明）。
2. `world/chunk_manager.gd:656-667`：提交时重新 `collect_neighbors` 比对 26 邻 edit_serial（:634），邻居新增/卸载（-1→serial）均判过期，无漏判。
3. `world/chunk_manager.gd:652-653`：任务期间自身被编辑（`chunk.mesh_dirty` 被重新置位）即丢弃旧结果，防旧网格覆盖新数据。
4. `world/chunk_manager.gd:571-575`：垂直带外缓冲层只清脏不网格化（刻意，防「孤儿层邻居全无」的重网格风暴），`is_idle` 语义因此成立。
5. `world/chunk_manager.gd:701-708`：`_restore_dormant` 正确恢复 state/脏标记并 add_chunk；`load_column_now`/`_fill_column` 调用后未重复 add，`renderer.register_chunk` 幂等（`presentation/chunk_renderer.gd:53-55`）。
6. `world/chunk_manager.gd:424-437`：生成提交预算 8/帧、`_gen_by_coord` 防重复提交；任务完成后先 erase 再提交，被丢弃的坐标可由后续扫描重发（无死锁）。
7. `world/voxel_world.gd:176-210`：编辑失效覆盖自身+6 面贴边+ xz 对角+y 角对角，并区分 `affects_collision`；`world/voxel_world.gd:193-204` 的对角补齐与 26 邻过期检查一致（仅加载路径见 F4）。
8. `world/voxel_world.gd:71-86`：`get_block_for_mesh` 的 y<0 实心、越界空气、未加载区块空气语义与网格剔除/README:511 一致（刻意取舍）。
9. `world/chunk_data.gd:80-88,136-149`：`set_block`/`set_state` 正确标记 data_modified/save_needed/edit_serial；`generated=true` 不持久化（f097e44 修复有效），加载/生成两条路径未发现漏标记。
10. `persistence/chunk_serializer.gd:106-145`：dims/volume 有 `get_data(volume)` 剩余字节兜底（超量返回 ERR_OUT_OF_DATA，不会巨量分配），palette 名称长度 1..128、slot 越界返回 null，未发现可致崩的解析路径（raw_length 见 F6、状态段见 F11）。
11. `persistence/world_save.gd:257-287`：原子写 tmp→大小校验→回读 verify→rename 替换，失败清 tmp 保留旧档；meta 同样走原子写（:138-140），写一半崩溃不会破坏旧档（README:526 一致）。
12. `persistence/world_save.gd:83-110`：`_remove_tree` 拒绝 user:// 根与 user://saves（f097e44 修复有效），`erase_all` 只能删具体存档目录，防误删共享目录。
13. `meshing/chunk_mesher.gd:974-979`：朝未加载邻块的侧壁不出面（刻意取舍，防加载边界「水幕帘」）；`:1070-1094` 角点高度/岸衰减只读单圈 padded+27 邻水位表，跨区块两侧算同值防裂缝（与 m00044 前摘要中 README 语义一致）。
14. `presentation/chunk_renderer.gd:53-55,171-184`：register 幂等；remove 释放 RS/PS RID 并回退 total_faces/_chunk_faces 记账，未发现 RID 泄漏（`_exit_tree` :82-84 兜底全部释放）。
15. `physics/chunk_collision_builder.gd:9-32`：合并 indices+cutout（树叶碰撞保留）、`set_faces`、`backface_collision = true`（防流式替换瞬间/高速穿角坠穿）；植物 cross 桶不进碰撞（刻意）。`physics/voxel_raycast.gd:14-90`：DDA 零分量轴、起点在实体内、并列轴确定性处理正确，未发现越界/漏检。

#### 覆盖缺口

- 未读全文：`meshing/greedy_mesher.gd`（`--greedy` 的另一实现，`world/chunk_manager.gd` 会调用，本次未审）、`systems/lighting/voxel_light.gd` 仅读 40-209（BFS 细节未全读）、`systems/tree_manager` 与 chunk_manager 的 idle/cb 接线（只 grep 到 `scenes/main.gd:157`）、`tests/test_stress_edits.gd` 全文、`debug/streaming_check.gd` 全文（只读关键段）。
- 受约束未验证：未运行 Godot（lead 正在跑测试套件），F1 触发频率、F9/F10 的毫秒数为静态推算；F12 是否由 ff07d1b 回归需 `git log -L547,552:world/chunk_manager.gd` 进一步确认；F8 的并发窗口需 stress/实机复现；F6 需手工构造损坏文件。
- 范围外但相关：ChunkSerializer v2 状态 JSON 的 int→float 往返由读取方 `int()` 修正，未逐系统核对所有状态消费方（`systems/` 不在本次范围）；`main.gd` 的加载 45s 超时/进度分母口径未深入（属 scenes/）。

---

### 7.2 part-2 — meshing / native（GDScript ↔ C# 等价性）

#### 概览

审查范围（全部亲自 read 到行级）：`meshing/` 6 个文件 1992 行（mesh_builder.gd 182、atlas_uv.gd 30、native_mesh_bridge.gd 194、native_terrain_bridge.gd 99、chunk_mesher.gd 1101、greedy_mesher.gd 386）与 `native/` 4 个文件 2438 行（NativeMesher.cs 878、NativeMesher.Grass.cs 245、NativeMesher.Lighting.cs 250、NativeTerrain.cs 1065）。另为判定"是不是 bug"通读了调用侧与判据文件：world/chunk_manager.gd（主要流程）、presentation/chunk_renderer.gd、presentation/texture_atlas_loader.gd、presentation/atlas_tiling.gdshader、presentation/distant_shell.gd、core/voxel_types.gd、tests/test_native_equivalence.gd、README/DEVELOPMENT_PLAN 相关章节。未运行 Godot/--import/dotnet build（lead 在跑测试套件），所有性能数字均为代码量级推导，标注为估算。

健康度结论：GD 与 C# 两套网格器的**几何等价性**做得相当扎实——面表/角点/UV/绕序/顶点光照/BetterGrassify/水通道/草叶双精度链/hash 盐逐项对得上（见"已核查无问题"），此前的等价性审查修复（f097e44）确实落地了。剩余问题集中在三块：① 每次建网格把 27 邻域重复打包并二次拷贝（托管 LOH 分配 + GDScript PackedArray 拷贝），是流式加载期最大的垃圾源；② 近距草叶几何规模没有块级预算，detail=2 单块上限约 19 MB；③ `--greedy` 对比模式缺 cutout 通道、且 GD 贪心回退忽略草 LOD，与 naive/C# 三路径不一致。**未发现 P0**（没有崩溃/存档损坏/不可控泄漏：worker 快照、serial 自愈、水/不透明同源回退这几处关键防护都在）。

#### 发现

##### F1 [P1] 每区块网格化重复打包 27 邻域 + C# 侧二次拷贝（托管 LOH 与 GDScript 垃圾主源）

- 位置：`native/NativeMesher.cs:99-101`、`native/NativeMesher.cs:504-520`、`native/NativeMesher.cs:112-113`、`native/NativeMesher.cs:291-292`、`native/NativeMesher.cs:752-753`、`meshing/native_mesh_bridge.gd:120`、`meshing/native_mesh_bridge.gd:184`
- 证据：

```csharp
// NativeMesher.cs:99-101（BuildNaive / BuildGreedy 各自入口，BuildWater 同）
int[] blockIds = blockIdsV.AsInt32Array();
int[] neighborIds = neighborIdsV.AsInt32Array();
byte[] neighborExists = (byte[])neighborExistsV;
```

```csharp
// NativeMesher.cs:504-520（BuildPaddedCache：把扁平 27×volume 再拆成 27 个 int[]）
int[] padded = new int[ps * ps * ps];
int[][] nb = new int[27][];
for (int i = 0; i < 27; i++)
{
    if (neighborExists[i] != 0)
    {
        int[] arr = new int[volume];
        System.Array.Copy(neighborIds, i * volume, arr, 0, volume);
        nb[i] = arr;
    }
}
```

```gdscript
# native_mesh_bridge.gd:120（build）与 :184（build_water）各打一次同一份 27 邻域
var packed := _pack_neighbors(chunk, neighbors)
```

- 根因：C# 入口先把变长 Variant 复制成托管数组，随后 BuildPaddedCache 为"按邻块二维访问"把扁平数组再拆成 `int[27][]`——但输入 `neighborIds` 本来就是 `i*volume + 局部偏移` 的扁平布局，可直接索引，`nb[][]` 完全是多余的 26 份 16 KB 拷贝。桥侧 build 与 build_water 分两次调 `_pack_neighbors`，同一 27 邻域被打包两遍（水区块必然两条都走：chunk_mesher.gd:334-339 先 build 再 build_water）。
- 影响（chunk 16³，volume=4096）：`neighborIds` = 27×4096×4 = **442,368 B**，超过 .NET LOH 85,000 B 阈值 → **每次建网格一次 LOH 分配**；`nb[][]` 最多 26×16,384 = **425,984 B**；`padded` 23,328 B。干区块 ≈ **0.89 MB 托管垃圾/次**；水区块（BuildNaive+BuildWater 各一次）≈ **1.8 MB/次**。GDScript 桥侧每次 `_pack_neighbors` 产 442,368 B PackedInt32Array（27 次 append_array 拷 110,592 int），水区块打包两次 = **884 KB/块**。按流式吞吐 20-50 块/s 估算 → 20-90 MB/s 托管垃圾 + 40-90 次/s LOH 分配 → 周期性 gen2/LOH 回收掉帧（量级由代码确定，具体停顿未 profile）。2 核机上尤其明显（桥接注释 :103-104 记录 20.6 vs 4.6 ms 的 A/B 就是含桥的）。
- 修复方案：A）删掉 `nb[][]` 与 `Array.Copy`，padded 边界循环直接读 `neighborIds[i * volume + la + s * lb + s * s * lc]`；`padded` 按 chunk size 用 `[ThreadStatic]` 缓存复用（worker 每线程一份即可，18³ = 23 KB）。桥侧新增 `build_both()`，一次 `_pack_neighbors` 同时喂 `BuildNaive/BuildGreedy` 与 `BuildWater`（或由 build 返回 packed 让调用方复用）。B）只做最小改动：把 `packed` 提升到 job 字典里，入队时（或 `_mesh_job` 里）打一次包，build/build_water 都接收现成 ids/exists。
- 验证：给 BuildPaddedCache 加 C# 单测——不同邻域组合下与旧实现逐格对比（或用 `VOXEL_NO_NATIVE=1` 与默认路径的等价测试保持全绿）；在 `_mesh_job` 里包 `GC.GetTotalAllocatedBytes()`/次与 `GC.CollectionCount(2)` 打印，改前后各跑 30 s 流式飞行对比。

##### F2 [P1] detail=2 近距草叶几何规模无块级预算（单块上限约 19 MB，编辑必整块重烘）

- 位置：`meshing/chunk_mesher.gd:724-730`、`meshing/chunk_mesher.gd:774-777`、`meshing/chunk_mesher.gd:810-826`、`meshing/chunk_mesher.gd:835-843`、`meshing/chunk_mesher.gd:861-871`、`world/chunk_manager.gd:803-805`
- 证据：

```gdscript
# chunk_mesher.gd:774-777（每草顶格叶片数）
var rn: float = TreeScatter.hash01(wx, wz, BLADE_SALT_N)
var n := n_override if n_override > 0 \
        else ((56 if rn < 0.40 else (64 if rn < 0.80 else 72)) \
        if detail >= 2 else (48 if detail == 1 else 32))
```

```gdscript
# chunk_mesher.gd:814-824（detail>=2 时 4 关键 × 十字双面）
var ckeys: int = 4 if detail >= 2 else 2
...
var faces: int = 2 if detail >= 2 else 1
```

```gdscript
# world/chunk_manager.gd:803-805（detail=2 的半径：Chebyshev ≤1 chunk）
func _grass_detail_for(coord: Vector3i, center: Vector2i) -> int:
    var d := maxi(absi(coord.x - center.x), absi(coord.z - center.y))
    return 2 if d <= 1 else (1 if d <= 5 else 0)
```

- 根因：detail=2 的每片叶是 4 关键 × 2 面 × 2 顶点 = **16 顶点/36 索引**，每格最多 72 片 → **1152 顶点/格**；平坦草区一个 16×16 区块最多 256 个草顶格 → **294,912 顶点 / 663,552 索引**。顶点属性 pos12+norm12+uv8+uv2 8+color16 = **56 B/顶点** ⇒ 约 **16.5 MB** 顶点 + **2.65 MB** 索引 ≈ **19.2 MB/块**（仅 cross 表面）。没有块级顶点/面积预算，也没有"草顶格数超阈值就降档"的保护。
- 影响：detail=2 覆盖 3×3 列（`_grass_detail_for` ≤1 chunk），每列垂直带 3 块左右、含草顶的 1-2 块 ⇒ 近区 **9-18 个 detail=2 草块**，估算 **上界 170-340 MB** 顶点数据（树/水/花占格会显著降低，实际可能只有该值的 30-70%）；一旦玩家在近区挖掘/放置（触发 `mesh_dirty` 整块重烘），GD 回退路径重建 20.6 ms 基准之上再叠加 PackedArray 增长/ArrayMesh 重传，C# 路径 4.6 ms 也需整块重发 2.6 万 ~ 76 万顶点——连续编辑时是持续掉帧尖峰；低显存机器有 OOM 风险。**量级由代码推导确定，实际 VRAM 未实测**（[待验证]）。
- 修复方案：A）加块级草叶预算：建网格前统计 `grass_top_cells` 数量，>160 格时把该块 detail 强制降 1（密度 48、单面、2 关键 ⇒ 4 顶点/叶，顶点 -75%），既保住远处不花屏又把最坏块压到 ~4.8 MB。B）更彻底：草叶模板改为按格实例化（MultiMeshInstance3D：一实例 = 一格草簇，顶点 ~16×72 共享，GPU 端渲染），或把 (格 hash, detail) 作为顶点属性由上端点生成；C）保守调参：detail=2 密度 72/64/56 → 48/44/40。
- 验证：debug 打印每块 `cross_vertices.size()` 与 `Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)`；编辑草块前后各测单帧耗时与进程 RSS；加断言"每块 cross 顶点 < 120k"（当前上限会直接触发）。

##### F3 [P2] `--greedy` 模式树叶无 cutout 通道 → 树冠变不透明实心大面（GD 与 C# 一致地错）

- 位置：`meshing/greedy_mesher.gd:124-126`、`meshing/greedy_mesher.gd:236-244`、`presentation/atlas_tiling.gdshader:32-33`、`presentation/voxel_material_registry.gd:87-94`、`scenes/main.gd:122-126`
- 证据：

```gdscript
# greedy_mesher.gd:124-126（面掩码：只排除水/枝/植物，CUTOUT 未排除）
if a_real and a != VoxelTypes.BRANCH_ID \
        and solid_by_id[a] == 1 and occludes_by_id[b] == 0 \
        and render_kind[a] != ChunkMesher.RENDER_PLANT:
```

```gdscript
# greedy_mesher.gd:236-244（结果字典无 cutout_indices 桶）
var result := {
    "vertices": vertices,
    "normals": normals,
    "uvs": uvs,
    "uv2": uv2s,
    "colors": colors,
    "indices": indices,
    "quads": quads,
}
```

```glsl
// atlas_tiling.gdshader:32-33（只取 .rgb，无 alpha/discard 裁切）
vec2 local = clamp(fract(tile_space), vec2(0.002), vec2(0.998));
vec3 tex = texture(atlas, tile_origin + local * tile_fraction).rgb;
```

- 根因：树叶（`core:leaves`，render_type cutout、`occludes_neighbors=false`）的 `render_kind` = RENDER_CUTOUT(2)，既不是 WATER/BRANCH 也不是 RENDER_PLANT，于是照常进入贪心掩码并被合并进 `indices`；贪心结果没有 cutout 桶，材质 `create_greedy_material` 只设了 atlas/tile_fraction（无 cutout uniform），平铺 shader 从不采样 alpha、无 discard。naive 路径（chunk_mesher.gd:549-555）会把 CUTOUT 分流到 `cutout_indices` 并挂带 cutout_mode 的材质——两条路径观感不同；C# BuildGreedy 同样无 cutout 桶。
- 影响：仅 `--greedy` 对比/基准模式（默认 `use_greedy_meshing=false`，chunk_manager.gd:64），但该模式是 A/B 与性能结论的载体：树叶被读作不透明方块 + 树冠内部面被合并成大块平铺重复纹理，任何用贪心模式做的观感/截图对比都会失真，也容易让"贪心可用"的结论被误采。属真实视觉 bug，不影响普通玩家默认路径。
- 修复方案：A）掩码处显式排除 `render_kind == RENDER_CUTOUT`（与 naive 同语义：cutout 面不参与合并，逐面发到独立 `cutout_indices` 桶），并给 `create_greedy_material` 增加 cutout 版本（shader 加 uniform + `vec4 t = texture(...); if (t.a < 0.5) discard;`），chunk_renderer 已有 cutout 表面通道可直接复用。B）若贪心只作面数基准：在 `--greedy` 启动时打印明确警告，文档注明"不渲染镂空/草 LOD"。
- 验证：`--greedy` 截图看树冠是否镂空；加等价测试用例——同一树叶区块 greedy 与 naive 的 cutout 面数/顶点数对照（不是逐位相等，但面数应 >0）；另断言贪心结果键完整（有 cutout_indices 或显式声明无）。

##### F4 [P2] GD 贪心回退忽略草 LOD（grass_detail 未传）→ 三级路径密度不一致

- 位置：`meshing/greedy_mesher.gd:259-265`、`meshing/greedy_mesher.gd:278-280`（对照 `meshing/chunk_mesher.gd:578-582`、`meshing/chunk_mesher.gd:588-592`）
- 证据：

```gdscript
# greedy_mesher.gd:257-265（高草固定 18 片，不传 grass_detail）
if bid == VoxelTypes.TALL_GRASS_ID:
    ChunkMesher.append_grass_blades(result, x, y, z,
            light_padded, ps, pidx, inv_cols, inv_rows,
            wc.x * wd.x + x, wc.z * wd.z + z,
            ChunkMesher.TALL_PLANT_N,
            ChunkMesher.TALL_PLANT_MULT,
            ChunkMesher.TALL_PLANT_Y0,
            ChunkMesher.TALL_W_MULT)
```

```gdscript
# greedy_mesher.gd:278-280（草顶用默认 detail=2）
ChunkMesher.append_grass_blades(result, x, y, z,
        light_padded, ps, pidx, inv_cols, inv_rows,
        wc.x * wd.x + x, wc.z * wd.z + z)
```

```gdscript
# chunk_mesher.gd:578-582（naive 路径正确传档位）
append_grass_blades(result, cell[0], cell[1], cell[2],
        light_padded, ps, cell[3], inv_cols, inv_rows,
        world_origin.x + cell[0], world_origin.z + cell[2],
        TALL_N_BY_DETAIL[grass_detail], TALL_PLANT_MULT,
        TALL_PLANT_Y0, TALL_W_MULT, grass_detail)
```

- 根因：`append_grass_blades` 签名（chunk_mesher.gd:724-730）的 `n_override=0, detail=2` 是默认值，贪心路径两处调用都没传 `grass_detail`；高草还写死 `TALL_PLANT_N`（18）而不是 `TALL_N_BY_DETAIL[grass_detail]`。C# `BuildGreedy`（NativeMesher.cs:464-493）是正确用 `TallNByDetail[grassDetail]` 的，所以只有 **GD 贪心回退路径**（C# 不可用/未 build）错。
- 影响：C# 不可用时 `--greedy` 的远景草仍按 detail=2 全密度（72 叶/格、4 关键、双面），比 naive 远景（detail=0：32 叶、2 关键、单面 = 128 顶点/格）重得多——"贪心比面剔除还慢"的假象会污染性能结论；同一场景三条路径（GD naive / GD greedy / C#）草密度不同。单元测试只跑 detail=2（test_native_equivalence.gd），覆盖不到。
- 修复方案：A）两处调用都传 `grass_detail`：高草用 `ChunkMesher.TALL_N_BY_DETAIL[grass_detail]`，草顶追加 `0, 1.0, 1.0, 1.0, grass_detail`（与 chunk_mesher.gd:588-592 完全对齐）。B）无取舍，属遗漏。
- 验证：给 test_native_equivalence 加 detail=0/1 用例（GD greedy vs C# greedy 的 cross 顶点数逐位相等）；`--greedy` + `VOXEL_NO_NATIVE=1` 下远离出生点观察草密度是否随距离下降。

##### F5 [P2] NativeTerrain 实例缓存键只有 world_seed —— 高度/注册表变更后复用旧实例（可污染存档）

- 位置：`meshing/native_terrain_bridge.gd:16`、`:53-58`、`:63-69`、`:92-95`；相关：`core/world_config.gd:12-21`、`scenes/main.gd:91`、`scenes/main.gd:96`
- 证据：

```gdscript
# native_terrain_bridge.gd:16
static var _native_by_seed := {}  # world_seed -> NativeTerrain 实例

# native_terrain_bridge.gd:53-58（prewarm：高度只在首次构造时生效）
static func prewarm(world_seed: int, world_height_blocks: int) -> void:
    if not available():
        return
    if not _native_by_seed.has(world_seed):
        _native_by_seed[world_seed] = _factory.CreateTerrain(
                world_seed, world_height_blocks, _block_id_table())

# native_terrain_bridge.gd:92-95（generate_chunk 同样是 has(seed) 即复用）
if not _native_by_seed.has(world_seed):
    _native_by_seed[world_seed] = _factory.CreateTerrain(
            world_seed, world_height_blocks, _block_id_table())
var native = _native_by_seed[world_seed]
```

- 根因：缓存键 = `world_seed` 单键，`world_height_blocks` 与 block_id 表只在 `CreateTerrain` 首次调用时生效。而 `world_height_blocks` 会随世界配置变化（world_config.gd 默认 3 层=48 高；main.gd:91 新世界 `NEW_WORLD_CHUNKS_Y`=32=512 高；main.gd:96 读档按存档 `chunks_y` 恢复），同一进程内回到主菜单换世界/读另一个档是可行流程。
- 影响：同 seed 但不同高度的第二个世界会复用按旧高度构造的 NativeTerrain——`_seaLevel`/`ShapeHeight`/高度钳制全按旧值，地形剖面与真实 GD 生成器不一致（海平面、山顶被压扁/裁掉），且玩家在新世界里改过的区块按错误高度写盘 ⇒ **不可逆的存档污染**；`column_surface_range` 算出的活跃带也会错，导致垂直流式加载漏列/空洞。默认单世界会话不触发。
- 修复方案：A）缓存键改为 `Vector3i(world_seed, world_height_blocks, block_id_table_signature)`（signature 可用 ids 数组 hash 或注册表 `get_instance_id()`）；B）`_native_by_seed[seed]` 存 `{native, height, sig}`，每次取用时校验不一致就重建并覆盖；`_exit_tree`/`reset` 时清空。
- 验证：加测试——同进程先 `CreateTerrain(seed, 48)` 再 `get_native(seed, 512)`，断言 `GenerateChunk` 的地表高度与新高度一致（或断言缓存 key 不同）；另测 `column_surface_range` 在两高度下返回合理区间。

##### F6 [P2] 出生列同步建网格：主线程逐块 build + ArrayMesh + 碰撞（单帧数十至数百 ms）[待验证]

- 位置：`world/chunk_manager.gd:241-265`（调用侧，跨目录，建议与 world part 去重）、被调入口 `meshing/chunk_mesher.gd:323-342`、`presentation/chunk_renderer.gd:106-167`
- 证据：

```gdscript
# chunk_manager.gd:241-265（load_column_now：主线程同步逐块网格化并提交）
for y in range(band.y, band.x - 1, -1):
    var coord := Vector3i(column.x, y, column.y)
    var chunk: ChunkData = world.get_chunk(coord)
    if chunk == null or not chunk.mesh_dirty:
        continue
    var arrays := {}
    var grass_detail := _grass_detail_for(coord, _focus_column())
    _chunk_grass_detail[coord] = grass_detail
    if use_greedy_meshing:
        arrays = GreedyMesher.build_mesh_arrays(
                registry, chunk, world.collect_neighbors(coord),
                null, grass_detail)
    else:
        arrays = ChunkMesher.build_mesh_arrays(
                registry, chunk, world.collect_neighbors(coord),
                null, grass_detail)
    renderer.apply_mesh(coord, arrays, chunk.collision_dirty)
```

- 根因：`load_column_now` 为让出生点首帧可见，在主线程把整条垂直带（`column_band` 由 BAND_BELOW_BLOCKS/BAND_ABOVE_BLOCKS 定，通常 3-4 块）同步 `build_mesh_arrays` 再 `apply_mesh`；后者每个区块要新建 ArrayMesh（+水面实例）并重建 ConcavePolygonShape3D 碰撞体。此处 `water_levels` 传 `null`，水区块还会走 `build_water` 内的 `collect_water_levels_world` 主线程收集。chunk_manager.gd:54-55 注释已承认"单个重提交 2-60 ms 不等"。
- 影响：`scenes/main.gd:223` 出生列同步调用 ⇒ 启动/传送瞬间 **单帧几十到数百 ms**（3-4 块 × (4.6-20.6 ms 网格 + 2-60 ms 提交/碰撞)），黑屏/卡顿可感知；`load_column_now` 也被 test_chunk_manager/test_stress_edits 当同步接口用，所以不能简单删。**未实测具体帧时间**（[待验证]，禁止运行 Godot）。
- 修复方案：A）只同步顶部 1 块（保证落点脚下有地面），其余进入正常异步队列（`_enqueue_mesh` + 首帧前多 poll 几次预算）；碰撞体在异步提交里建（已有 `collision_dirty`/`_ensure_collision_ring` 机制）。B）保留同步 API 但加 `budget_usec` 参数，超过预算即 break 把剩余块入队，测试传 `INF` 保持旧行为。
- 验证：在 `load_column_now` 前后打 `Time.get_ticks_usec()`，断言出生列总耗时 <50 ms（或记录基线）；`--print-frames`/debug 帧时间曲线确认首帧尖峰消失。

##### F7 [P2] 每次入队主线程预收集水位表：27 邻块 × 4096 线性扫描 + states 深拷贝

- 位置：`world/chunk_manager.gd:596`、`:601`（调用侧，跨目录）；`meshing/chunk_mesher.gd:888-908`；另 `meshing/chunk_mesher.gd:334`
- 证据：

```gdscript
# chunk_manager.gd:593-601（主线程入队时）
"water_levels": ChunkMesher.collect_water_levels_world(chunk, neighbors),
...
"states": chunk.sparse_block_states.duplicate(true),
```

```gdscript
# chunk_mesher.gd:899-908（每个邻块都做一次 block_ids.has 线性扫描）
static func _merge_water_levels(levels: Dictionary, chunk: ChunkData) -> void:
    if chunk == null or not chunk.block_ids.has(VoxelTypes.WATER_ID):
        return
    var c := chunk.chunk_coord
    var d := chunk.dimensions
    var origin := Vector3i(c.x * d.x, c.y * d.y, c.z * d.z)
    for local in chunk.sparse_block_states:
        var state: Dictionary = chunk.sparse_block_states[local]
        if state.has("level") and chunk.get_block(local) == VoxelTypes.WATER_ID:
            levels[origin + local] = int(state["level"])
```

- 根因：注释（:593-595）说明主线程收集是为避免 worker 并发遍历 `sparse_block_states` 导致哈希损坏，这个取舍是对的；但代价是每块入队都做：`collect_water_levels_world` → 1 自身 + 26 邻 = 最多 27 次 `PackedInt32Array.has(WATER_ID)`（O(4096) 线性扫描）= **最多 110,592 次整数比较/入队**，再对每个有水邻块遍历整张 states 字典；`states.duplicate(true)` 每次深拷贝整张字典（水位流动时条目多，每格一个 Vector3i 键 + level）。`chunk_mesher.gd:334` 在 build 路径上还有同类 `block_ids.has(WATER_ID)` 扫描。
- 影响：流式加载高峰每帧多次入队时主线程被这些扫描占住，与用户输入/物理抢帧；states 深拷贝还会在 GC 上叠加（GDScript Dictionary 深拷贝逐项复制，含 24 B/键值以上）。量级随水/状态数量增长，属持续开销。
- 修复方案：A）`ChunkData` 维护 `has_water` 布尔（生成/放水/取水时更新，O(1) 读），`has()` 扫描全部替换；B）states 深拷贝加条件：`sparse_block_states.is_empty()` 时直接传空字典（当前恒拷贝一张空表），非空时按需 `duplicate(true)`；C）水位表可缓存到 chunk 上并随 `edit_serial` 失效，避免 26 邻重复遍历。
- 验证：加探针统计单次入队主线程耗时（`Time.get_ticks_usec` 包住 :588-605），改前后对比；断言无水区块入队不做 has 扫描。

##### F8 [P2] 远景壳 GenerateShellMesh：逐格独立 4 顶点 + 每格 16 次树采样，单次重建百 MB 级临时分配 [待验证]

- 位置：`native/NativeTerrain.cs:538-543`、`:564`、`:570-585`、`:818-827`、`:1050-1062`；调用侧 `presentation/distant_shell.gd:127-142`
- 证据：

```csharp
// NativeTerrain.cs:538-543 / :564（三环，最大 W=512，每格 S=16 世界格）
private static readonly (int s, int inner, int outer)[] ShellLevels =
{
    (4, 160, 768),
    (8, 768, 2048),
    (16, 2048, 4096),
};
...
int W = (RingOuter / S) * 2;
```

```csharp
// NativeTerrain.cs:818-827（每个 quad 独立 4 顶点，不复用相邻格顶点）
int v0 = verts.Count;
verts.Add(a); verts.Add(b); verts.Add(c); verts.Add(d);
norms.Add(n); norms.Add(n); norms.Add(n); norms.Add(n);
cols.Add(col); cols.Add(col); cols.Add(col); cols.Add(col);
idxs.Add(v0); idxs.Add(v0 + 2); idxs.Add(v0 + 1);
idxs.Add(v0 + 1); idxs.Add(v0 + 2); idxs.Add(v0 + 3);
```

```csharp
// NativeTerrain.cs:1050-1062（List → ToArray → Variant 再复制一次）
arrays[(int)Mesh.ArrayType.Vertex] = Variant.CreateFrom(verts.ToArray());
...
mesh.AddSurfaceFromArrays(Mesh.PrimitiveType.Triangles, arrays);
```

- 根因：壳网格按"每格 1 个顶面 quad + up to 4 个壁 quad"发射，quad 之间不共享顶点；顶点/法线/颜色/索引用 `List<T>` 累积后再 `ToArray()` + `Variant.CreateFrom`，全程至少两份拷贝。格数：ring2 W=512 → 圆环内 ≈ π(2048²-768²)/8² ≈ 17.7 万格、ring3 ≈ π(4096²-2048²)/16² ≈ 15.4 万格、ring1 ≈ 11.1 万格；顶面就 4 顶点/格（ring2 ≈ 70.8 万顶点），加壁约 100-170 万顶点/环。属性 12+12+16 B + 索引 4 B ⇒ List 阶段 60-110 MB/环，ToArray + Variant 再翻一倍 ⇒ **单次重建临时 150-250 MB**。另外每格采样 `q=2×2` 群系 + 4×4=16 次 `TreeAt`（三环都是 16 次：`tStep = max(1, S/4)`，段数恒 4），总计 ≈ 4.4×10⁵ 格 ×16 ≈ **7.1×10⁶ 次 TreeAt**（每次含 noise+hash）+ 每格 5 次 ColumnProfile。`distant_shell.gd:117-124` 在玩家每跨 64 世界格且上一次构建完成后就重建。
- 影响：构建在 WorkerThreadPool 线程上（不直接卡帧），但：① 2 核机上与区块生成/网格化抢同一线程池，跨 64 格移动时后台 CPU 长时间占满，流式加载变慢；② 百 MB 级临时分配 → GC/内存峰值，低内存设备易抖动；③ 主线程替换 `_mesh_instance.mesh` 时释放上一张大 ArrayMesh，可产生一次可感知的停顿。**实际 ms/内存未 profile**（[待验证]）。
- 修复方案：A）`List` 预分配 `Capacity` 到上界（inRing 格数×4×5），并直接写 `PackedVector3Array`/`PackedColorArray`（省一轮 ToArray 拷贝）；B）顶点共享：顶面相邻格共享 2 个顶点（每格 4→2 顶点），壁与顶面共享棱边，顶点数可降 40-50%；C）远环采样降档：S=8/16 环用 2×2 树采样（现 4×4 恒定），树斑比例对远观足够，采样量 -75%；D）把壳重建改成"环级分帧"（每步只重建最外的 1 环，跨 64 格时通常只有外环变化）。
- 验证：给 GenerateShellMesh 加 `--bench-shell` 计时与 `GC.GetTotalAllocatedBytes()` 打印（顶点数/耗时/分配字节）；跨中心两次测重建耗时与进程峰值内存；截图对比降采样后远景树斑是否可辨。

##### F9 [P3] 非 27 元素邻域快照时，水侧壁语义 GD 与 C# 相反

- 位置：`meshing/chunk_mesher.gd:604-611` 对 `native/NativeMesher.cs:766-768`
- 证据：

```gdscript
# chunk_mesher.gd:601-611（size!=27 ⇒ 返回空表 ⇒ "视为全加载" ⇒ 出全部侧壁）
## 27 元素邻域快照索引 = (dz+1)*9 + (dy+1)*3 + (dx+1)；快照不是
## 27 元素时一律视为已加载（保持旧行为）。
static func loaded_dirs(neighbors: Array) -> PackedByteArray:
    var dirs := PackedByteArray()
    if neighbors.size() != 27:
        return dirs
```

```csharp
// NativeMesher.cs:759-768（length<27 ⇒ dirLoaded 全 false ⇒ 不出任何侧壁）
// 缺失=尚未加载：那里格子的"空气"只是未知，不能据此给水柱出侧壁，否则加载边界
// ...会立起一圈从水面直落海底的竖墙
bool[] dirLoaded = new bool[6];
if (neighborExists != null && neighborExists.Length >= 27)
    for (int f = 0; f < 6; f++)
        dirLoaded[f] = neighborExists[dirNeighborIndex[f]] != 0;
```

- 根因：两实现对"快照不足 27 邻"的降级策略相反——GD 视为"全加载"（空表 ⇒ `dir_loaded[f]==0` ⇒ 出水侧壁），C# 视为"全未加载"（不出侧壁）。生产路径不可达：`native_mesh_bridge.gd:81-98` 的 `_pack_neighbors` 恒产 27 个元素（缺邻 resize 补 0），所以线上两种实现看到的输入都合法。
- 影响：仅影响直调 API/自定义快照（单测、工具、未来重构）；一旦有人让桥接层透传"部分邻域"，水柱侧壁会按两套相反语义生成 ⇒ 视觉不一致（GD 出现"幕帘竖墙"，C# 水面缺口）。属等价性契约漏洞，不是现网 bug。
- 修复方案：A）统一为 C# 语义（未知邻不臆测，不出侧壁），GD 的 `size()!=27` 分支改为返回 6 个 0；B）若坚持 GD 旧行为，C# 侧改成"length<27 ⇒ dirLoaded 全 true"，并在 `native_mesh_bridge.gd` 加断言保护长度恒 27。
- 验证：test_native_equivalence 加"27 以外的邻域快照"用例，断言两条路径 water_side_vertices 数量相等（无论选哪种语义）；桥接层加 `assert(neighbor_exists.size() == 27)`。

##### F10 [P3] C# BuildNaive 的 BetterGrassify 硬编码草 id/草贴图名（注册表/贴图名一变即漂移）

- 位置：`native/NativeMesher.cs:172-197`（对照 `meshing/chunk_mesher.gd:483-519`）
- 证据：

```csharp
// NativeMesher.cs:172-197
if (blockId == 1 && f != 2 && f != 3)
{
    int outward = FaceNormalSign[f] > 0 ? step : -step;
    int diagBelow = pidx + outward - ps;
    if (padded[diagBelow] == 1)
        tile = topTile[1];
    else
    {
        ...
        if (variant == 1) tile = GrassSideU0;
        else if (variant == 2) tile = GrassSideU1;
        else if (variant == 3) tile = GrassSideU01;
    }
}
```

- 根因：C# 用字面量 `1` 判草方块、`topTile[1]` 取草顶、常量 `GrassSideU0/U1/U01`（=22/23/24，写死在 NativeMesher.cs 顶部）——不读注册表 `textures` 里的 `side_u0/side_u1/side_u01` 与 top。GD 侧（chunk_mesher.gd:483-519）是查 `textures_by_id[GRASS].get("side_u0", ...)` + `tile_grid` 并带 fallback。默认注册表（core/voxel_types.gd:98-102 定义了 grass 的 side_u0/u1/side_u01/top）下完全等价——这正是等价测试能过的原因。
- 影响：注册表一旦被数据驱动化、改 grass id、或图集顺序调整（TILE_NAMES 重排），C# 会静默渲染错贴图/丢失草坡过渡，而 GD 正常；调试时表现为"开 C# 就花、关 C# 就好"的鬼影 bug。另 C# 无 GD chunk_mesher.gd:471 那处 `state.is_empty()` 守卫（草块不带状态，当前无实际差异）。
- 修复方案：A）C# 增加 `int grassId` 与 `int grassSideTile0/1/01` 参数，由 `native_mesh_bridge.gd` 从注册表按名字（`VoxelTypes.GRASS_ID` 与 `tile_grid("grass_side_u0")` 等）解析后传入（与 topTile/sideTile 表同路径）；B）至少加静态断言：启动时校验注册表 grass 的 side_u0..u01 贴图名恰好映射到 22/23/24，不一致就打印警告并禁用 C# 路径。
- 验证：改注册表 grass 的 side_u1 贴图名后分别跑 C#/GD 路径截图比对（当前会不同）；加 `test_native_equivalence` 自定义注册表用例。

##### F11 [P3] 贴图名不在 TILE_NAMES 时贪心整面静默消失（注册表契约无校验）

- 位置：`meshing/native_mesh_bridge.gd:68-74`、`meshing/native_mesh_bridge.gd:15-28`；配合 `meshing/greedy_mesher.gd:133-137`、`presentation/texture_atlas_loader.gd`（tile_grid 的 assert）
- 证据：

```gdscript
# native_mesh_bridge.gd:68-74（找不到 = -1，静默进入 tile 表）
for id in registry.block_count():
    var textures: Dictionary = registry.definition_for_id(id).get("textures", {})
    top.append(TILE_NAMES.find(String(textures.get("top", ""))))
    side.append(TILE_NAMES.find(String(textures.get("side", ""))))
    bottom.append(TILE_NAMES.find(String(textures.get("bottom", ""))))
```

- 根因：`PackedInt32Array.find` 找不到返回 -1；贪心掩码把该 tile 编码为 `tile+1 = 0` ⇒ **该面被当作"无面"整面丢弃**（`greedy_mesher.gd:133-137` 直接 `int(tile_rows[a][...]) + 1`），且无任何日志。GD naive 路径同样用 name→index 查询，但 `texture_atlas_loader.tile_grid` 有 `assert(index >= 0)`（debug 下会炸、release 下 UV 越界采样）；两条路径的失败模式不一致：一个静默丢面、一个断言。
- 影响：目前 `TILE_NAMES`（25 项）与 `TextureAtlasLoader.TILES`（25 项）经核对同序同名，默认注册表全部命中，所以是潜在风险；新增方块/改贴图名时忘记同步 TILE_NAMES，会得到"某些方块整块消失但碰撞还在"的极难排查 bug（无警告）。属契约缺测试。
- 修复方案：A）`_tile_tables` 里对 `find() < 0` 直接 `push_error` 并记录方块名/贴图名（或 `assert`），启动时 prewarm 就能暴露；B）加一条启动自检：遍历注册表所有 textures 名，断言都在 TILE_NAMES 中且顺序与 TextureAtlasLoader.TILES 一致（现有等价测试只覆盖默认注册表的部分方块）。
- 验证：临时改某方块贴图名，启动应看到 error 而非静默；加测试遍历注册表断言全部命中。

##### F12 [P3] `_tile_cache` 以 registry.instance_id 为键且从不清理（id 复用可能命中旧表）

- 位置：`meshing/native_mesh_bridge.gd:13`、`:61-75`、`:51-57`（prewarm）
- 证据：

```gdscript
# native_mesh_bridge.gd:13 / :61-75
static var _tile_cache := {}  # registry_id -> {top, side, bottom: PackedInt32Array}
...
static func _tile_tables(registry: VoxelRegistry) -> Dictionary:
    var key := registry.get_instance_id()
    if _tile_cache.has(key):
        return _tile_cache[key]
```

- 根因：缓存键用 `get_instance_id()`（int），注册表对象释放后条目永不删除；Godot 的实例 id 会复用（静态缓存跨场景/测试存活时可能被新对象取到同一 id）。另外键与 "block_count/textures" 内容无关，注册表内容被修改（运行时注册方块）不会失效。
- 影响：正常单注册表流程无影响（prewarm 后固定）；编辑器/测试/重载场景多次构造注册表时缓存只增不减（条目本身小，泄漏量可忽略），真正风险是 id 复用 ⇒ 新注册表拿到旧 tile 表 ⇒ 贴图错乱，且完全无法复现定位。属 P3 稳健性债。
- 修复方案：A）键改内容键：`block_count` + 各 id 的 top/side/bottom 名 hash（可用 `String.hash()` 组合）；或直接存 `registry`（强引用）到 `{ref: registry, tables: ...}` 并比较 `is_same()`；B）注册 `registry.tree_exiting` 时清理对应条目；`_tile_cache.clear()` 暴露给测试。
- 验证：构造两个注册表（不同贴图名/顺序）交替调用 `build`，断言 tile 表随注册表变化；对象释放后再次构造，断言不命中旧键（可临时打印 key 与命中状态）。

##### F13 [P3] chunk_mesher.gd 文件尾四段已删"枝干几何"注释挤在一行

- 位置：`meshing/chunk_mesher.gd:1097-1101`
- 证据：

```gdscript
## ---- 枝干几何（动态树，参考 Dynamic Trees 的 radius 语义）----

## 枝干按 radius 状态（1-8，1 格 = 16 半径单位）出几何：
## - radius 1-2：十字交叉面片（植物式细枝，全高，宽 = radius*2/16）；
## - radius 3-8：方形柱（宽 = radius*2/16 居中），四侧 + 顶/底。## 渐缩方管：从中心（截面 r0）沿 dir 到格边（截面 r1），## 盒面：复用 opaque 的 FACES 角点表（单位盒角 0/1 映射到 mn/mx），
```

- 根因：B 系列迭代中枝干几何代码被删除（改由树实体渲染），注释残留且多段被拼到同一行（1097-1101 行尾粘接）。
- 影响：读代码者会以为存在 `append_branch_faces` 一类的缺失实现，或按注释去找已不存在的 radius 状态几何；无运行时影响。属整洁度问题，但属于"误导性注释"，优先于纯格式问题。
- 修复方案：A）整段删除（改由 `world/tree_scatter` 或树实体文件记录枝干视觉方案）；B）若想保留设计记录，改写为"枝干几何由树实体渲染（见 tree_renderer），本文件不含枝干面发射"，并放到文件头注释区。
- 验证：grep `枝干几何` 只剩有意保留的一处；无代码引用。

#### 已核查无问题的风险点

1. 面表/角点/UV/法线/kind 与 C# 逐项一致：`meshing/chunk_mesher.gd:31-68`（FACES）对 `native/NativeMesher.cs:15-45`（FaceCorners/FaceCornerUvs/FaceNormalAxis/FaceNormalSign/FaceKind/FaceTanAxes）。
2. 三角形绕序三处一致（Godot 正面=外侧顺时针）：`chunk_mesher.gd:549-555`、`greedy_mesher.gd:231`、`NativeMesher.cs:219-221/445-451`，均为 (0,2,1)(0,3,2)。
3. BetterGrassify 三实现公式逐项一致（斜下格草→草顶、切向 blend bit 1/2/3 → side_u0/u1/u01、flip=f==0||f==5）：`chunk_mesher.gd:483-519`、`greedy_mesher.gd:157-191`、`NativeMesher.cs:172-197`；注册表对应名见 `core/voxel_types.gd:98-102`。
4. 草顶密叶发射条件（上方 AIR/PLANT/BRANCH/LEAVES 才发）三处一致：`chunk_mesher.gd:447-457`、`greedy_mesher.gd:274-277`、`NativeMesher.cs:226-260`（植物/草顶统一发射）。
5. 水通道公式与键名一致：`chunk_mesher.gd:913-918`（surface height）、`:986-996`（角点高度+岸衰减）、`:1070-1094`（2×2 角点 max）对 `NativeMesher.cs:735-840`；方向索引 `{14,12,16,10,22,4}` 两侧相同。
6. 光照 BFS 与天空特例一致：`native/NativeMesher.Lighting.cs` 的 StepLevel/TrySky（sky && down && lv==15 && op==0 保 15）、IsSkyBorder、种子筛选、邻块播入与 `systems/lighting/voxel_light.gd` 的 `_step_level/_is_sky_border` 逐规则对得上（GD `fill(0)` 原地写 vs C# 新建数组，语义等价）。
7. PackResult 条件键与消费端一致：`NativeMesher.cs:842-878`（uv2 非空才写、quads>=0 才写、cutout_indices 非空、colors 非空、cross_* 仅非空）对 `mesh_builder.gd` 的 surface 判定与 `chunk_renderer.gd:106-167` 的读取方式——naive 无 uv2 不会炸。
8. worker 并发防护齐备：states 深拷贝 + water_levels 主线程预收集 + 提交时 26 邻 edit_serial 比对 + mesh_dirty 丢弃后重排，见 `world/chunk_manager.gd:588-610`、`:637-684`、`:634`（NEIGHBOR_EXPIRE_INDICES 去中心 13）——打包数组撕裂由 serial 自愈是明确设计取舍，非 bug。
9. 提交预算不会一次塞满一帧：`chunk_manager.gd:461-465` 数量+时间双预算（`mesh_committed > 0 and 耗时 > MESH_COMMIT_BUDGET_USEC` 才 break，首块超预算仍提交属已知取舍）；编辑块插队豁免 `:446-460`。
10. 草 LOD 升降档正确：`chunk_manager.gd:803-805`（阈值 1/5 chunk）、`:810-840`（升档立即、降档 3 s 合并、无草区块只记不改网格、`_detail_demote.erase` 防重复）——`:804` 的 `center.y`（Vector2i.z 语义）命名混淆但计算正确。
11. 水/不透明必须同源的回退守卫正确：`chunk_mesher.gd:331-342`——C# build 成功但 build_water 失败时整体回退 GD，避免混搭两套面。
12. 草叶 hash 盐/双精度链/UV2/双面索引三实现一致：`chunk_mesher.gd:750-871` 对 `native/NativeMesher.Grass.cs`（同盐 911-981、CurveW、sway_w、indices stride=faces*2 单对角线；f32 截断点相同）。
13. 原生不可用/强制回退路径完整：`native_mesh_bridge.gd:31-43`（`VOXEL_NO_NATIVE=1`）、`native_terrain_bridge.gd:45-58`（主线程 prewarm 避免 worker 并发写静态字典）、`scenes/main.gd:103-107` 接线。
14. 远景壳几何绕序/flip 正确（cull_disabled 下法线语义）：`NativeTerrain.cs:818-827`（顶面 (0,2,1)(1,2,3)）、`:927-940`（PushWall flip 交换 vb/vc）、`:950-1048`（壁只对非水格、跨界壁双/内侧兜底）、`:1050-1061`（每环一个 surface）。索引 32 位安全（Godot 4 ArrayMesh 内部 4 字节索引，壳单环顶点 10⁶ 级不会溢出）。
15. 顶点数上限：naive 路径每块最多 4096×6×4 = 98,304 顶点，超过 65535 但 Godot 4 统一 32 位索引，无 16 位溢出风险；`atlas_uv.gd` 的 inset 默认 0 与 Nearest 采样一致（无 mipmap 泄漏）。

#### 覆盖缺口

- **未运行任何实机验证**（lead 占用测试套件，禁止起 Godot/--import/dotnet build）。所有性能数字均为代码量级推导：F1 的 MB/s、F2 的 19.2 MB/块、F6 的单帧 ms、F8 的 150-250 MB 临时分配都未用 profiler 核实，已在对应条目标 [待验证]。
- `native/NativeTerrain.cs`（1065 行）只精读了壳网格相关部分（ShellLevels/W/采样循环/PushQuad/PushWall/数组拼装/水色/边界钳制）；生成主体（Height/ShapeHeight/群系/树分布采样、Hash01 之外的噪声调用、ColumnProfile 内部）未逐行审，属 generation part，本报告 F8 只覆盖其"壳网格内存/采样成本"一面。
- `NativeMesher.cs` 的 `FaceTile/ResolveTile`（:620-652）状态方块分支（stairs/slab/axis 状态）只对照了语义摘要，未穷举全部状态组合；`NativeMesher.Grass.cs` 的 `AppendPlantFaces`/草叶顶点发射逐行比对过，但其 UV 原点与 GD 的 f32 截断点只核对了结果式，未做逐位数值验证。
- `presentation/` 的材质/shader 只读到"greedy 缺 cutout"这一层：`water.gdshader`、`water_side.gdshader`、`terrain_surface_cross.gdshader`、`distant_shell.gdshader` 的波/雾/裁剪细节未审（F3/F8 的视觉影响依赖这些 shader 的行为，可能有额外因素）。
- `texture_atlas_loader.gd` 只核对了 TILES 与 TILE_NAMES 的 25 项同序同名，未核 iterate atlas 资源本身（贴图内容、是否为 Nearest/mipmap 设置）。
- 未审 `tests/` 其余网格相关测试（只精读 test_native_equivalence.gd），故"无测试覆盖"的结论仅针对该文件。
- 未验证 `_prune_band_cache`/`_surface_bands` 在长时间流式加载下的增长（只读了清理代码，未跑长时测试）。

---

### 7.3 part-3 — generation / trees（地形生成与树系统）

#### 概览

审查文件（GDScript 共约 3390 行）：generation/terrain_generator.gd（621 行 / 27.9KB）、systems/trees/tree_manager.gd（1279 行 / 55KB）、tree_generator.gd（428 行）、tree_mesh_builder.gd（639 行）、tree_instance.gd（260 行）、tree_scatter.gd（114 行）、tree_species.gd（49 行）；交叉核对 world/ 与 scenes/ 管线：world/world_save.gd、world/chunk_manager.gd、scenes/main.gd、core/voxel_types.gd、meshing/chunk_mesher.gd，以及 EmacEArtStylizedGrass/ 的引用与许可（未计入行数）。

整体健康度：模块边界清晰、注释中大量记录了历史 bug 与取舍（复盘质量高），树的生命周期主循环均有 _trees.has / revision 守卫，未发现直接崩溃或内存无界泄漏的路径，故本次无 P0。主要问题集中在两处：一是“树结构重放”与“体素占位/存档”容易脱钩（砍伐事件上限、旧档迁移、生成器升版都会产出实体化幽灵树或悬浮叶）；二是逐层撒树无垂直剪枝，把主线程出生列加载（world/chunk_manager.gd:215-230 load_column_now 同步生成）放大数倍。性能问题均有 debug 日志实测值支撑。

#### 发现

##### F1 [P1] 撒树按垂直层无条件重放，无垂直剪枝：每层 576 列全扫 + 期望 ~20 棵全树生成全部白算

- 位置：generation/terrain_generator.gd:554-588、:592-594（调用点 :450/:454 对所有层无条件调用）
- 证据：

        for wx in range(origin.x - TREE_REACH, origin.x + size + TREE_REACH):
            for wz in range(origin.z - TREE_REACH, origin.z + size + TREE_REACH):
                if not TreeGenerator.has_tree_at(config.world_seed,
                        Vector2i(wx, wz)):
        ...
            if surf <= sea_level:
                continue  # 水域/滩涂不种树
            # 草地判定（荒漠/裸岩不种）
            if is_sandy or is_rocky:
                continue
            _grow_tree_into_chunk(chunk, Vector3i(wx, surf + 1, wz))

- 根因：generate_chunk 对每个垂直层都调 _scatter_trees，而该函数只按水平 ±TREE_REACH 枚举候选根列，既没比较树根 surf+1 与本 chunk 的 y 区间，也没有按物种最大高度做上界拒绝；树只向上生长，大部分层与树占位完全不相交。:592-594 又在每次命中时新建 TreeSpecies 并跑完整 TreeGenerator.generate + leaf_cells。
- 影响（量化）：每层 24×24=576 列，has_tree_at 对 35/36 的列 2 次 hash01 早退（约 1.1k 次 hash/层）；湿润区每层期望命中 1.3-19.8 棵（约 20 棵），每棵 generate 实测 ≈504µs（debug/perf_tree_v4.log:289 "generate=504"，bench 以 µs 计），即单层约 10ms 全部白算；一列 chunk（band 常见 8-12 层）只有 2-3 层真正写入格 → 4-10 倍冗余。生成走 WorkerThreadPool，但出生点/传送有同步路径 world/chunk_manager.gd:215-230 load_column_now 在主线程逐层 generate_chunk，冗余直接变成进世界卡顿（估算 80-150ms/列）。
- 修复方案：A) 在 :565 前加垂直拒绝——树根及以上不在本层：if surf + 1 >= origin.y + size 就 continue；再按最大树高加下界拒绝：if surf + 1 + MAX_TREE_HEIGHT < origin.y 就 continue（MAX_TREE_HEIGHT 取物种最大 trunk_height+叶冠，实测约 24-30），可消掉绝大多数层。B) 把“候选根列 (wx,wz,surf,sandy,rocky)”按 chunk 列缓存一次（水平枚举只做一次），跨层复用，兼顾 C# 侧同构成本。
- 验证：探针统计 _grow_tree_into_chunk 调用次数与实际写入 BRANCH/LEAVES 格数之比（目标 <2）；对 100 个 chunk 计时对比；确认 tests/test_generation.gd 的撒种对拍/密度区间用例仍通过。

##### F2 [P1] 砍伐事件 256 条上限 + 重放只剪结构不清体素：已砍树会“长回”成不可砍的实体树干 / 悬浮叶

- 位置：systems/trees/tree_manager.gd:580-589（事件上限）、:298-307（_apply_cuts 只改结构）、:592-618 生成器写占位
- 证据：

        # 存档膨胀防护：只保留最近 MAX_CUT_EVENTS 条（旧事件丢失仅
        # 表现为已砍树在远古区域重放长回——可接受；曾无限增长整体写入
        # world.json，审查发现）
        if _cut_events.size() >= MAX_CUT_EVENTS:
            _cut_events = _cut_events.slice(_cut_events.size() - MAX_CUT_EVENTS + 1)
        _cut_events.append({
            "op": "cut",
            "cell": [cell.x, cell.y, cell.z],
            "tree": [tree.origin.x, tree.origin.y, tree.origin.z],
        })

        func _apply_cuts(tree: TreeInstance, tree_id: int) -> void:
            for event in _cut_events:
                ...
                    tree.split_branch_at_cell(cell)
                    tree.record_cut(cell)
            # 清除被切格与失支撑分量的索引
            _prune_unsupported(tree)

- 根因：读档时树结构由 TreeGenerator.generate 确定性重建，再按剩余 cut 事件剪枝；事件被上限挤掉后，该树结构完整复活（trunk/branch mesh + StaticBody 碰撞），但对应 BRANCH/LEAVES 体素早在 on_branch_broken :631-637 被写成 AIR 并随区块 data_modified 落盘。_apply_cuts 只操作 TreeInstance，不校验也不清理体素层。生成器升版重建未修改区块时是同一根因的另一触发面：结构按新算法重建、体素占位也重写，重放剪枝后叶占位无人清（悬浮叶盒、隐形 BRANCH 格）。
- 影响：玩家累计砍超过 256 棵后，回头进入早期区域/读档会看到“可见树干+树枝、带碰撞挡路、无叶、砍不动”的幽灵树（BRANCH 格已是 AIR，BlockMining 不会触发 on_branch_broken），再次保存事件仍缺失 → 永久化。树冠叶格在升版重建路线下表现为悬浮叶块。属于真实 gameplay bug 且不可自愈。
- 修复方案：A) 上限内改为按树聚合的紧凑事件（op=removed + tree=[ox,oy,oz]，每树 1 条，可安全存数千条），上限提到 4096；B) _ref_tree 首建后补一致性兜底：若树根附近应有 BRANCH 的格在体素层是 AIR，判定该树已被清，直接不建实体（或在 _apply_cuts 里对剪掉的 cells 批量 world.set_block AIR 清理）。C) 生成器升版迁移时把“结构已砍但体素重建”的树统一清体素。
- 验证：tests/test_trees.gd 增加“砍 300 棵后重放最早那棵”用例：断言 get_tree_at(根格)==null、_trees 无该 id、无 mesh/body 节点；实机砍 300 棵后返回出生点目视无幽灵树。

##### F3 [P1] 砍树逐格 world.set_block 清占位：每格触发 529 次空间索引查 + 光照重算，单次砍伐可卡数秒

- 位置：systems/trees/tree_manager.gd:625-637（清占位循环）、:116-120 与 :134-156（_on_block_changed → _mark_light_dirty 双循环）、注释 :1140-1143
- 证据：

        for c in cells:
            if world.get_block(c) == VoxelTypes.BRANCH_ID:
                world.set_block(c, VoxelTypes.AIR_ID, false)
        # 叶占位清除（走区块管线）
        for leaf_cell in fallen_leaves:
            if world.get_block(leaf_cell) == VoxelTypes.LEAVES_ID:
                world.set_block(leaf_cell, VoxelTypes.AIR_ID, false)

        # delta 钳制：砍树触发 set_block 重网格化会卡出数秒巨帧——
        # 单 tick ang=4/h·delta² 直接冲破 160° 上限假落地（capture
        # "LANDED at frame 1" 实锤）。DT 跑固定 tick 天然免疫，

- 根因：每格 set_block 都 emit block_changed → _on_block_changed → _mark_light_dirty，后者对每个变更格做 (2r+1)² 空间索引查（r=ceil(margin=16 或 3)+TREE_MAX_RADIUS=8，普通遮挡即 r=11 → 529 次 _trees_by_col 字典查），并触发区块光照 BFS 与 8 邻块 mesh 标脏；一次倒树要清 200-300 叶格 + 数十枝格，全部逐格走这条昂贵路径，且都在主线程同一帧内。
- 影响：单棵 ~250 格 → 约 13 万次字典查 + 约 250 次光照传播/区块标脏，注释自述可“卡出数秒巨帧”；玩家砍倒大树时输入/动画明显停顿，若同时有倒树动画还会被 delta 钳制（:1144）拖慢。
- 修复方案：A) 新增批量清除 API：world.clear_cells_batch(cells, AIR) 一次 clear_state / 一次 emit（或干脆不逐格发信号），结束后对 cells 并集 AABB 调一次 _mark_light_dirty 并统一标脏受影响 chunk；B) 若保留逐格，分帧处理（每帧 ≤32 格）且把光照更新合并到一次 BFS 调用。
- 验证：砍一棵 250-300 叶的树，用 Time.get_ticks_usec 包住 on_branch_broken 打印总耗时（目标 <30ms）；Performance.get_monitor(Performance.TIME_PROCESS) 无 >100ms 尖峰。

##### F4 [P2] 旧档 treegen-v1 的 cut 事件被静默丢弃，无迁移、无玩家提示、无测试

- 位置：systems/trees/tree_manager.gd:1263-1271；旧版本标签见 git fbdcc3a:systems/trees/tree_manager.gd:420
- 证据：

        func get_save_bundle() -> Dictionary:
            return {"trees": {"algorithm": "treegen-v2", "events": _cut_events}}

        func apply_save_state(data: Dictionary) -> void:
            var trees_data: Dictionary = data.get("trees", {})
            if trees_data.get("algorithm", "") != "treegen-v2":
                push_warning("未知树存档算法版本，跳过树事件重放")
                return
            _cut_events = trees_data.get("events", [])

        （git show fbdcc3a:systems/trees/tree_manager.gd）
        419: func get_save_bundle() -> Dictionary:
        420:     return {"trees": {"algorithm": "treegen-v1", "events": _cut_events}}

- 根因：commit 43f9453 明确“树位置全变+存档算法版本 treegen-v2（旧 cut 事件作废）”，但只改了生成器/撒种，没有迁移代码：treegen-v1 档的 events 直接不读，仅控制台 push_warning。
- 影响：旧档载入后 _cut_events 为空，任何需要结构重放的已砍树按 F2 路径完整长回（实体树干+碰撞），玩家砍伐历史全部丢失且无 UI 感知；下次保存把空事件写死，旧档不可逆丢失砍伐记录。因 treegen-v2 树位置整体改变，多数旧事件本也无对应格，影响可容忍，但缺“迁移/提示/备份”三件套。
- 修复方案：A) 检测到 algorithm != treegen-v2 时走显式迁移：把旧事件按 tree origin 聚合为 removed 事件（体素层已由 data_modified 区块保存，只需阻止结构重建），写入新算法标签并打一条明确迁移日志；B) 至少 UI 提示“旧存档树数据不兼容，已砍树将重新出现”，保存前备份 world.json。
- 验证：手工构造 algorithm=treegen-v1 + 若干 events 的 world.json 加载，断言不崩、事件按迁移策略处理、日志可见；tests/test_trees.gd 增加该用例（现无任何存档测试，见覆盖缺口）。

##### F5 [P2] 单棵树重烘实测峰值 24.5ms，注释“毫秒级毛刺”低估；预算按棵数而非耗时

- 位置：systems/trees/tree_manager.gd:87-92（注释 + REBUILD_BUDGET_PER_FRAME=1）、:1071-1088（光照快通道）；实测 debug/perf_session5.log:199、debug/perf_session6.log:569-703
- 证据：

        ## 每帧重烘棵数上限：单棵全量重建（几何+逐面光照采样+冠影+上传）
        ## 5-15ms——曾 4 棵/帧=20-60ms 硬卡（实机"放/挖方块卡一下"：挖放
        ## 把 3 格内树标脏，合并窗后一次烘）。1 棵/帧把峰值摊成毫秒级毛刺，
        ## 多棵依次更新 2-3 帧完成，火把点亮感知仍即时
        const REBUILD_BUDGET_PER_FRAME := 1

        （debug/perf_session5.log:199）
        [perf] tree_rebuild 24.5ms tid=1924191362 (mesh 4.1 crown 1.4 shadow 0.4)

- 根因：重烘在主线程同步完成几何 + 逐面顶点光照采样 + ArrayMesh 上传，成本随树大小变化很大（同一份日志 3.4-10.7ms，session6 多条 2.3-12.0ms）；预算逻辑是固定每帧 1 棵（:1077/:1088），不是时间预算。
- 影响：60fps 帧预算 16.6ms，单棵 24.5ms 即掉 1-2 帧；连续挖放方块时每帧都烘一棵会持续掉帧。注释 :172 也自承“budget=1 下仍每帧 4-10ms 毛刺”，说明作者已知但未按耗时收敛。
- 修复方案：A) 改为时间预算：本帧烘完一棵后检查 Time.get_ticks_usec()-frame_start，超过约 4000µs 就 break，留下次帧；B) 中期把 trunk 顶点光采样搬进 worker（光照快照 :453-469 已可序列化传递），主线程只做 ArrayMesh 上传。
- 验证：perf_tree_bench 场景批量放拆方块，统计 p99 帧时间与单帧 tree 重烘累计耗时；断言 ≤4ms。

##### F6 [P2] 撒树扫 ±TREE_REACH 外圈、TreeManager 只扫本列：视距边缘只见浮空树叶、无树干实体

- 位置：systems/trees/tree_manager.gd:185-193（只扫本列 16×16）vs generation/terrain_generator.gd:563-564（±4 列，TREE_REACH=4）
- 证据：

        ## 本列 16×16 根列撒树（确定性重建，_ref_tree 内做地形合法性判定）。
        func _scan_column_trees(col: Vector2i) -> void:
            var size := world.config.chunk_size
            var ox := col.x * size
            var oz := col.y * size
            for wx in range(ox, ox + size):
                for wz in range(oz, oz + size):
                    if TreeGenerator.has_tree_at(world.config.world_seed,
                            Vector2i(wx, wz)):
                        _ref_tree(Vector2i(wx, wz))

        （terrain_generator.gd:563-564）
        for wx in range(origin.x - TREE_REACH, origin.x + size + TREE_REACH):
            for wz in range(origin.z - TREE_REACH, origin.z + size + TREE_REACH):

- 根因：生成器为跨块树冠把邻列树的枝干/树叶占位写进本区块（外圈），但 TreeManager 的实体建树只按“树根所在列 chunk”触发；两个半径/边界口径不一致。
- 影响：站在已加载区域边缘时，邻列树只以 LEAVES 占位（可见 cutout 立方体）出现，树干 mesh 与碰撞缺失 → 浮空树叶块；走近使邻列加载后树干突然弹出。反向走远时树干先消失而邻块叶占位仍在。
- 修复方案：A) _scan_column_trees 扩到 ±ceil(TREE_MAX_RADIUS / chunk_size) 列（当前 TREE_MAX_RADIUS=8 不跨列，但树冠半径/树高可能超过，需用实际 aabb 判定），并用 _cell_lookup 去重防止多次建同一棵；B) 或收紧撒树外圈（树冠由实体 mesh 表现，不再写邻块占位），减小跨块耦合。
- 验证：站在两列 chunk 边界观察同一棵树树冠：树干与叶同时出现/消失；单测断言 _cell_lookup 覆盖本 chunk 内所有 BRANCH 格。

##### F7 [P2] 重建失败路径先 queue_free 旧节点却不置 null 即 return → entry 悬空引用，后续 previously freed 报错

- 位置：systems/trees/tree_manager.gd:343-355（_build_visual_impl）、:472-482（_commit_visual_arrays）
- 证据：

        # 清旧
        if entry["mesh_node"] != null:
            entry["mesh_node"].queue_free()
        if entry["body"] != null:
            entry["body"].queue_free()
        ...
        var mesh := TreeMeshBuilder.build_mesh(tree, {}, world)
        if mesh == null:
            return {}
        ...
        var trunk: Array = job["trunk"]
        if trunk.is_empty():
            return

- 根因：两个可视化入口都“先释放旧节点，再构建新网格”，但构建结果为空时直接 return，entry["mesh_node"]/["body"] 仍指向已 queue_free 的实例；下次重烘或 _destroy_tree:551-554 再判定 != null 后 queue_free 已释放对象。
- 影响：触发条件罕见（树被剪到无可见几何但未销毁、或光照快照全黑导致数组空），一旦命中：Godot 报 Attempt to call function 'queue_free' in base 'previously freed instance' 并中断函数，该树视觉/碰撞停留在半更新状态或永久不更新。
- 修复方案：free 后立即置空——entry["mesh_node"].queue_free() 后接 entry["mesh_node"] = null（body 同理），空网格分支也保持 null；或统一用 is_instance_valid() 判定。
- 验证：构造无枝干 TreeInstance 连续调用 _build_visual 两次，断言无 previously freed 报错、entry 两字段为 null。

##### F8 [P2] 异步 mesh job 只有结构版本号，光照快照陈旧时会覆盖刚完成的同步重烘

- 位置：systems/trees/tree_manager.gd:426-448（job 组装与 worker）、:1071-1088（同步光照重烘）、:1116-1133（提交）
- 证据：

        var job := {
            "tid": tid, "tree": tree, "rev": tree.revision,
            "snap": _snapshot_light(tid), "cs": world.config.chunk_size,
            "trunk": [], "crown": [], "shadow": [],
        }
        ...
        func _tree_mesh_job(job: Dictionary) -> void:
            job["trunk"] = TreeMeshBuilder.build_mesh_snap_arrays(
                    job["tree"], job["snap"], int(job["cs"]))

- 根因：job 用 tree.revision 判新旧，但光照变化（火把/方块/天光）不 bump revision，只标 _light_dirty 走同步 _build_visual；此时在飞的 worker job 与同步重烘可并存，job 完成时 rev 相同 → _commit_visual_arrays 用旧光照快照生成的顶点色覆盖刚烘好的新结果。
- 影响：火把点亮/方块变化后，该树顶点光照回退到旧值，直到下一次标脏才恢复（可能长时间肉眼可见的亮度错误）；并发本身不崩（结构读取前有 _flush_tree_async 保护 :576）。
- 修复方案：A) 增加独立的 light_rev（任何光照变更 ++），job 记录并与当前比对，不一致则丢弃并重新入队；B) 同步重烘前先 _flush_tree_async(tid) 再构建（成本：等 worker 完成一次）。
- 验证：单测：_enqueue_tree_async 后立刻改光照触发同步重烘，等待 job 完成后断言顶点色=新光照（或 job 被丢弃）。

##### F9 [P2] 倒伏动画/刚体 holder 与树实例解耦：chunk 卸载销毁树不取消倒伏与结算

- 位置：systems/trees/tree_manager.gd:548-562（_destroy_tree 不清 _falling/_falling_anims）、:604-609（倒树分流）
- 证据：

        func _destroy_tree(tree_id: int) -> void:
            _flush_tree_async(tree_id)
            var entry: Dictionary = _trees[tree_id]
            if entry["mesh_node"] != null:
                entry["mesh_node"].queue_free()
            if entry["body"] != null:
                entry["body"].queue_free()
            var o := (entry["instance"] as TreeInstance).origin
            var arr: Array = _trees_by_col.get(Vector2i(o.x, o.z), [])
            arr.erase(tree_id)
            ...
            _trees.erase(tree_id)

- 根因：_falling_anims/_falling 以 holder/body 为键、独立于 _trees；树实体销毁时没有查找并取消仍在该位置的倒伏体，倒伏体继续运行，溶解结束 _settle_drop 在可能已卸载的坐标生成掉落物。
- 影响：砍树后立刻走远使 chunk 卸载再回来：倒伏动画/残留体消失、掉落物落进虚空或悬空；若 _falling/_falling_anims 槽被占满（各 8 个）而树已删，后续倒树退化到 _settle_drop 分支（无倒伏表现）。
- 修复方案：在 _falling/_falling_anims 的 info 中记录 tree_id 与树 origin 列，_destroy_tree 时遍历查找并立即结算+free；或把 holder 挂到树 entry 的节点下随树销毁。
- 验证：砍树后立刻跨 chunk 走远再返回，检查无残留 holder、掉落物只出现在已加载区；单测断言 _destroy_tree 后两个容器长度不增。

##### F10 [P3] _bake_last 只增不减 + refs 计数是死字段

- 位置：systems/trees/tree_manager.gd:73（_bake_last 声明）、:1087（写入）、:548-562（_destroy_tree 不清理）、:248-258（refs+1）、:273-276（entry）
- 证据：

        73| var _bake_last := {}
        ...
        1087|                     _bake_last[tid] = now_msec

        （_ref_tree 内）
        else:
            entry["refs"] = int(entry["refs"]) + 1
            return

- 根因：_bake_last 每棵烘过的树留一个 tid→msec 条目且永不删除；refs 只在 _ref_tree 已存在时 +1，而销毁逻辑按 origin 列扫描不看 refs，引用计数不参与任何判定。
- 影响：长时间漫游后 _bake_last 随经过的树数量单调增长（1 万棵约 0.4MB 级，非失控但无界）；refs 给人“有引用计数”的错觉，后续维护可能误用。
- 修复方案：_destroy_tree 中 _bake_last.erase(tree_id)；refs 字段要么删除，要么真正参与 _destroy_tree 判定并列进 entry 注释。
- 验证：单测：建 N 棵树 → 全部销毁 → 断言 _bake_last 为空。

##### F11 [P3] tree_id 用内置 32 位 hash([seed,x,z])，哈希碰撞时两树共用同一 entry

- 位置：systems/trees/tree_manager.gd:255
- 证据：

        var tree_id := hash([world.config.world_seed, origin.x, origin.z])

- 根因：GDScript 内置 hash 返回 32 位；_trees 是单一 Dictionary，冲突时后者覆盖前者（同一 id 的两棵树只能存在一棵，另一棵的 cell 索引会串到错误树）。
- 影响：概率量化：n 棵树碰撞概率 ≈ n²/2³³；单世界 2000 棵约 0.05%，1 万棵约 1.2%——不是零。命中时表现为某棵树消失/被另一棵结构污染，且难以复现。
- 修复方案：用 tree_scatter.hash01 的 32 位混合作高位拼成 64 位 id（hash01(seed,x,z) 与 (hash01(seed,z,x) << 32) 异或），或直接存 Vector3i 键（origin 唯一即可）。
- 验证：构造 1 万棵 origin 的 hash 集合，断言无重复（或改 64 位后重复率 0）。

##### F12 [P3] hash01 注释声称“GD int 64 位乘积 < 2^61 不溢出”错误，实现依赖有符号 64 位回绕

- 位置：systems/trees/tree_scatter.gd:55-58
- 证据：

        ## 显式数值 hash → [0,1)：三整数 splitmix 风格混合。u32 环算术
        ##（GD int 64 位乘积 < 2^61 不溢出；C# uint 同式——对拍测试钉死）。
        ## 三次迭代手写展开（曾 for v in [a,b,c]：每调用分配一个 Array，
        ## 撒种热路径 90k 列/区块全在 GC 压力上）

- 根因：0xFFFFFFFF × 0x85EBCA6B ≈ 9.65e18 > 2^63-1 ≈ 9.22e18，乘法确实溢出（依赖 GDScript 有符号 64 位回绕的补码行为）；每步随后 & 0xFFFFFFFF，低 32 位与 C# uint 一致，所以对拍仍成立。
- 影响：当前无 bug；但注释误导后续维护者，且若未来把该函数复制到 C++/GDScript 之外的语言，有符号乘法溢出是 UB，跨端一致性会悄然破裂。
- 修复方案：改正注释为“依赖 64 位有符号回绕，取低 32 位；两端行为等价”，并在函数内/测试注释标注该不变量；或改用显式的无溢出实现（如位运算乘）。
- 验证：tests/test_native_equivalence 已有 hash 逐位对拍（226 项），保留并补注释。

##### F13 [P3] 撒种注释“最小树距恒 ≥ 4.2 格 ≥ 冠半径”不成立，cell 边缘 jitter 可让两树干仅隔 1 格

- 位置：systems/trees/tree_scatter.gd:1-8（注释）、:100-114（has_tree_at）
- 证据：

        ##   cell+jitter：世界划 6 格 cell，每 cell 至多 1 树（jitter 落点
        ##   唯一）——最小树距恒 ≥ 对角半宽 ≈ 4.2 格 ≥ 冠半径，DT 的位图
        ##   圆/弧掩码/三角化是 MC 跨 chunk 确定性+存档 16B 的过度工程。

        var jx := int(hash01(world_seed + 2, cx, cz) * float(CELL))
        if col.x != cx * CELL + jx:
            return false

- 根因：jitter 落在 cell 内任意一格，相邻 cell 的落点可以贴着共同边（x=cx*6+5 与 (cx+1)*6+0），实际最小距 1 格；注释把“cell 内唯一”误当成“cell 中心距离”。DENSITY_MAX 时 cell 存在概率 = 0.022×36 ≈ 0.79，邻格同时有树是常态。
- 影响：树干/树冠互相重叠，两个“树”的占位格先写先得，后一棵的树干在交叉格上缺失 → 该树部分格不可砍/结构不完整；视觉上两株穿插。属数据模型取舍，不是崩溃。
- 修复方案：A) 若确实要最小间距，改为“落点距离最近邻 ≤ 2 时丢弃”（需要邻 cell 查询，成本低，仅 4 邻）；B) 若不要求，改注释说明“允许重叠，先写先得”，并把 reach/碰撞影响写清。
- 验证：统计 100 个 chunk 内最近树距分布，确认与注释一致；或加单测断言两 cell 落点可贴边。

##### F14 [P3] 格式与陈旧注释：超长单行 if、旧“高草 10%”说明、与实测不符的性能注释

- 位置：generation/terrain_generator.gd:601、:615（压成一行的越界 if，中间大量制表符）；:495-496（注释“高草 10%”）vs :500（TALL_GRASS_DENSITY=0.22）；systems/trees/tree_manager.gd:87-91（见 F5）
- 证据：

        （terrain_generator.gd:495-496 与 :498-501 附近）
        ## 其余格：罂粟 1%、蒲公英 1%、高草 10%
        ...
        const TALL_GRASS_DENSITY := 0.22

- 根因：历史编辑留下的排版/文档漂移，语法合法但降低可读性，也让后续审查误判概率。
- 影响：无运行时影响；审查成本/维护风险。
- 修复方案：把 :601/:615 拆成多行按 while 对齐；更新 :495-496 注释为 22%；在 :87-91 注明实测峰值 24.5ms（见 F5）。
- 验证：gdformat 或编辑器导入无格式告警；注释数字与常量一致。

#### 已核查无问题的风险点

- systems/trees/tree_manager.gd:1084-1088 光照快通道先 erase 再 _trees.has(tid) 守卫，树在构建期间被销毁不会崩。
- systems/trees/tree_manager.gd:1105-1106 慢通道先 _build_pending.erase 再 has 检查；:1116-1133 异步提交 erase 后 has/revision 双重守卫（注释“构建期间被回收”），无悬空访问。
- systems/trees/tree_manager.gd:426-448 worker 任务只碰 job 字典与静态构建函数（无 world/场景树），光照以主线程 duplicate 快照传递（:453-469），无数据竞争。
- systems/trees/tree_manager.gd:576 砍伐 split 前先 _flush_tree_async 等 worker 结束，避免 worker 读结构时主线程改结构。
- systems/trees/tree_manager.gd:1144 delta 钳到 1/30s 防巨帧假落地；:1201-1207 land_at 与 landed 同处赋值，land_at 不会未初始化使用。
- systems/trees/tree_manager.gd:1237-1248 _ground_top_y 向下 48 格排除 AIR/LEAVES/BRANCH、把水当落地（树停水面），是刻意的取舍且与倒树路径一致。
- systems/trees/tree_instance.gd:96-98 split_branch_at_cell 对不在 cell_to_branch 的格安全 no-op，陈旧 cut 事件不会崩；:122-173 三种切法半径插值正确，:178-190 子枝重挂无环。
- systems/trees/tree_instance.gd:198-223 find_supported 要求 root.start_cell==origin 且用无向 BFS（parent+child），断根树能被判为全失支撑。
- tests/test_trees.gd 覆盖较实：:44 光照重烘、:104 落地掉落位置、:137 确定性、:154 形状约束、:186-269 split 各情形、:289 顶切脱冠、:308 连通性、:329 叶冠、:342 冠影、:404 清叶覆盖。
- world/world_save.gd:173-198 只有 data_modified 区块落盘、:204-250 读档标记 data_modified，砍伐体素随区块增量持久化，设计正确（F2/F4 的问题不在这一层）。
- scenes/main.gd:146-149 tree_manager.apply_save_state 在 chunk 激活之前调用，cut 事件先于 _ref_tree 重放，顺序正确。
- generation/terrain_generator.gd:583-586 与 tree_manager.gd:248-252 使用同一套 sea_level/sandy/rocky 判定，两侧对“哪儿不种树”一致，未发现幽灵树来源。
- systems/trees/tree_scatter.gd:37-52 configure 先写 _precip 再写 _precip_seed，配合读取端双检，避免并发半配置密度错。
- EmacEArtStylizedGrass：全仓库 .gd/.tscn/.tres 零引用（grep emac/EA_Grass/grass_clump/stylizedgrass 均 0 命中）；git ls-files 结果 0 行、.gitignore:36 已有 EmacEArtStylizedGrass/（注释写明第三方专有许可、禁止再分发，同 conquest_local 先例），LICENSE.txt 禁止转售/再分发素材本体——不入库即合规。目录自带独立 project.godot 但被忽略，不影响主工程。

#### 覆盖缺口

- 未运行任何 Godot 测试/基准（lead 正在跑测试套件，按要求避免竞争），F1 的 80-150ms 主线程代价、F3 的砍树耗时均为日志推算，未在本机复测。
- F2 的 256 上限路径未实机复现（需砍 300 棵并回访），结论基于代码路径推理 + 根因一致。
- native/NativeTerrain.cs 的远景壳 TreeAt/抬升（43f9453 改动 121 行）未深读，只核对了 GD 侧撒种；C# 壳与真实地形重叠带问题未覆盖。
- debug/ 下探针与基准脚本仅读了 perf_tree_replay.gd、perf_tree_bench.gd 的头部与日志，未逐一运行；debug/perf_session5/6/8.log 只抽样了 tree_rebuild 行。
- tests/test_generation.gd 全文（+62 行撒种对拍）未逐行读，只确认存在；tests/test_native_equivalence.gd 的 226 项未看列表。
- tree_manager.gd 200-245、700-1040 之间的部分函数（_crown_shadow_arrays、_spawn_falling_rigid 细节）只做了 grep/局部读，未逐行审。
- chunk_mesher 对 LEAVES/BRANCH 的叶片几何（:780-869）只确认了调用 TreeScatter.hash01 的确定性用法，未审具体顶点生成。
- EmacEArtStylizedGrass/Documentation 下 PDF 商业许可全文未读，许可结论基于 README.txt + LICENSE.txt 文本。
- 未核查 git 历史中 43f9453 之外其他树相关修复提交（如 eafcb11 前的倒树回归）是否引入遗留代码。

---

### 7.4 part-4 — player / characters / main（玩家、角色与主场景）

#### 概览

- 审查范围（全部全文通读）：player/player_controller.gd 1324 行、player/player_avatar.gd 705 行、player/crosshair.gd 41 行、characters/ 其余 7 个文件（character_rig.gd 324、ef_reference_rig.gd 369、bvh_loader.gd 345、character_animator.gd 275、clip_lib.gd 269、ysm_model.gd 261、ef_mesh_loader.gd 143）、scenes/main.gd 719 行；合计约 4775 行。另只读核查 world/chunk_manager.gd、generation/terrain_generator.gd、world/water_ripples.gd 的相关函数。
- 健康度：注释密度高且大量记录了历史缺陷与取舍（相机“快收慢放”、垂直带流式、加载预算恢复、退回出生点必须在门禁之前等），跨系统接线基本清晰，player/characters 侧没有发现存档损坏类风险。本轮共 17 条：P0 0 条、P1 3 条、P2 6 条、P3 8 条；未发现 P0 的理由是：存档只在主线程由 SaveSystem + chunk_manager._exit_tree（先 save_all 再等线程，chunk_manager.gd:127-139）串行写，不存在异步写竞态；区块与化身对象的生命周期都收敛在 add_child / queue_free / _dormant 三处。
- 最值得先修的是三处“输入边沿/状态机边界”：键盘事件未过滤 echo、动作层 loop 动作永不结束、第三人称相机遮挡收缩下限。其余 P2 多为“有用户资产（YSM/EF/BVH 包）时”的同步加载卡顿，属条件性风险。

#### 发现

##### F1 [P1] 键盘事件未过滤 echo：按住 Q 会按系统重复率连续丢物品，按住 E 背包反复开关
- 位置：player/player_controller.gd:198-239（另见 :171 鼠标分支）
- 证据：
~~~
	elif event is InputEventKey and event.pressed:
		# 双击方向键 = 闪避（拔刀态；0.28s 窗口内同键二击）
		var tap_dir := _dodge_dir_name(event.keycode)
		if tap_dir != "" and not event.echo:
~~~
  紧接其后的 match（与上方闪避判定之间没有其他语句）:
~~~
		match event.keycode:
			KEY_E:
				_toggle_inventory()
			KEY_Q:
				# Q 扔 1 个，Ctrl+Q 扔整堆（背包界面打开时不响应）
				if not inventory_open:
					_drop_held(event.ctrl_pressed)
~~~
  以及 :226-230 的 KEY_F5 → _cycle_camera()、KEY_F6 → avatar.cycle_model()、:236-239 KEY_1..8 → _select。
- 根因：作者在闪避分支（:201）已显式判断 not event.echo，证明知道按键重复的存在；但 :198 的入口条件与后面的 match 分支没有过滤 echo，OS 自动重复（约 30 次/秒）会重复触发一次性动作。
- 影响：按住 Q 会连续触发 _drop_held：普通 Q 每次丢 1 个，Ctrl+Q 第一次丢整堆、后续按重复率把剩余堆继续丢到世界里（物品层掉落带 1s 拾取保护不足以覆盖，玩家松手时物品已散落）；按住 E 以 30Hz 反复开关背包并反复切 Input.mouse_mode，期间鼠标锁定/UI 状态抖动，且玩家无法正常操作；按住 F5 连切相机四态、按住 F6 连续重建化身模型（与 F11/F6 叠加成明显卡顿）。
- 修复方案：A) 最小改法：把 :198 改为 elif event is InputEventKey and event.pressed and not event.echo:（闪避分支的 not event.echo 可保留）；更保险是在 match 前加 if event.echo: return。B) 若希望支持“按住 F5 快速循环”，可只对 KEY_E/KEY_Q/KEY_1..8 过滤 echo，F5/F6 保留（但不建议，F6 重建模型很重）。
- 验证：headless 探针里注入 InputEventKey.pressed=true、echo=true、keycode=KEY_Q 各一次，断言 _drop_held/_toggle_inventory 调用次数为 0；实机按住 Q 2 秒确认只丢 1 个。

##### F2 [P1] 挖掘动作 0.5s 后冻结：dig 片段 loop=true 而动作层只按 not loop 结束
- 位置：characters/clip_lib.gd:205-207、characters/character_animator.gd:162-176、characters/player_avatar.gd:586-588、characters/clip_lib.gd:29-32（采样末端钳制）
- 证据：
~~~
#### 挖掘（上身循环 0.5s）：右臂抡-停-落。
static func proc_dig() -> Dictionary:
	var c := _new_clip("dig", 0.5, true)
~~~
~~~
	_action["prev_time"] = _action["time"]
	_action["time"] = float(_action["time"]) + delta * float(_action["speed"])
	# 播完自动淡出（须在权重更新前判定——大 delta 单帧曾用旧 target=1 …）
	var clip: Dictionary = clips[_action["name"]]
	var length: float = clip["length"]
	if not bool(clip["loop"]) and float(_action["time"]) >= length:
		if float(_action["target"]) > 0.0:
			_action["target"] = 0.0
~~~
  播放侧：
~~~
	# 挖掘动作层
	if _mining and not animator.action_active():
		animator.play_action("dig", 1.0, "upper")
~~~
- 根因：动作层（_advance_action）没有为 loop 动作做时间回绕，循环只存在于 base 层（_advance_base 有 fmod）。dig 是 loop=true 的动作层片段，于是 time 单调增长；采样 sample_track 在 t 超过末键后钳制到最后一帧（clip_lib.gd:29-32），而 dig 的末键（Arm_R 0.5 = -60°，Hand_R 0.5 = 30°）与首键相同，视觉上手臂停在“下挖位”不再摆动；同时 action_active() 恒 true，player_avatar.gd:587 的重播条件永远不成立。
- 影响：持续挖掘（采矿/铲土 >0.5s）时角色手臂冻结、无循环挥动，属于稳定可复现的表现层 bug；挖掘进度本身由 _update_mining 独立累计，所以是“看起来不挖了但方块照掉”，容易被误判成输入丢失。
- 修复方案：A) 在 _advance_action 推进时间后回绕：if bool(clip["loop"]) and length > 0.0: _action["time"] = fmod(_action["time"], length)（prev_time 也要在同一处理里保留/回绕，否则事件扫掠会漏触发）；B) 给 play_action 增加 loop 参数，动作层按参数决定回绕/结束，语义更显式。
- 验证：在 animator 单测里播 dig、以固定 delta 推进 3s，断言 _action["time"] 始终 < length 且 action_progress() 出现多次 0→1；实机按住左键 3s 看手臂持续抡。

##### F3 [P1] 第三人称相机遮挡收缩下限 0.5m 会把机位塞进实心方块（贴墙黑屏/穿墙）
- 位置：player/player_controller.gd:66-72（常量）、:110（_cam_dist 初值）、:1090-1093（_cycle_camera）、:1149-1156（遮挡收缩）
- 证据：
~~~
const CAM_DIST := [0.0, 3.2, 3.6, 2.1]   # 各模式目标距离（米）
const CAM_MIN_DIST := 0.5                # 收缩下限（别怼进头里）
const CAM_COLLIDE_PAD := 0.3             # 命中面回退余量
~~~
~~~
	var hit := VoxelRaycast.raycast(world, eye, dir, want_len + 0.2)
	if hit.hit:
		var want_d := clampf(float(hit["distance"]) - CAM_COLLIDE_PAD,
				CAM_MIN_DIST, want_len)
		_cam_dist = move_toward(_cam_dist, want_d, CAM_PULL_IN * delta)
~~~
- 根因：真实命中距离 < CAM_MIN_DIST + CAM_COLLIDE_PAD（< 0.8m）时，hit - 0.3 会小于 0.5，clampf 的下限反而把目标距离抬回到 0.5，也就是把机位推到命中面之后（墙内/方块内）。这是“下限为防怼头”与“必须退到命中面前”两个约束的冲突，下限应按命中距离而不是固定常量截断。
- 影响：第三人称（模式 1/2/3）贴墙、进矿洞、背靠树/坡时相机进入实心方块，画面出现整屏纯色/黑屏或看到内壁，属高频可感知的 gameplay 体验缺陷；此时相机 near plane 0.05 会切掉一半视野，玩家无法观察四周。
- 修复方案：A) want_d = maxf(0.08, minf(hit_dist - CAM_COLLIDE_PAD, want_len))，即允许收缩到 0.08；同时在 _cam_dist < 0.35 时把 avatar.visible 置 false 并临时隐藏手部（第一人称已有 visible 逻辑，:381）。B) 更稳的是改成球体扫掠/多射线（眼—机位置附近 4 条射线取最近命中）而不是单射线，避免薄墙角从射线缝隙漏检。
- 验证：构造贴墙场景（玩家背靠 1 格厚墙），把 pitch 转到 ±60° 与水平各测一遍，断言 _cam_dist <= hit_dist - 0.05 且 camera 所在体素是空气；实机贴墙转视角确认不出现黑屏。

##### F4 [P2] 读档后相机俯仰角丢失（存档写 camera.rotation.x，恢复只写 camera.rotation.x 不写 _pitch）
- 位置：player/player_controller.gd:91（_pitch 声明）、:1295-1302（get_save_state）、:1318-1324（apply_save_state）、:1116-1122（第一人称每帧用 _pitch 重写相机）
- 证据：
~~~
	return {
		"position": [pos.x, pos.y, pos.z],
		"spawn_point": [spawn.x, spawn.y, spawn.z],
		"yaw": rotation.y,
		"pitch": camera.rotation.x,
		"selected_index": selected_col,
		"inventory": inventory.serialize(),
	}
~~~
~~~
	rotation.y = float(state.get("yaw", rotation.y))
	camera.rotation.x = float(state.get("pitch", camera.rotation.x))
~~~
~~~
	if camera_mode == 0:
		camera.position = Vector3(_bob_x,
				EYE_HEIGHT + _bob_y - _land_dip, 0.0)
		camera.rotation = Vector3(_pitch, 0.0, 0.0)
		return
~~~
- 根因：持久化的是相机节点的 rotation.x，而第一人称视角的唯一真源是 _pitch（鼠标在 :164-166 只更新 _pitch）；apply_save_state 恢复时只写了 camera.rotation.x，_pitch 仍为 0，下一帧 _position_camera 立刻把相机重写为 _pitch=0。另外第三人称（模式 2）的 camera.rotation 是 look_at 派生值，其 x 与 _pitch 既不同号也不同值，所以保存的 pitch 在 TPS 下也是错的。
- 影响：每次读档视角强制回到水平，玩家需要重新抬头/低头；若把该值当成“相机朝向”做别的逻辑（后续若加相机模式存档）会继续错。属于存档语义不完整而非数据损坏，P2。
- 修复方案：A) 存 "pitch": _pitch（并可选存 camera_mode），apply 时 _pitch = clampf(float(state.get("pitch", 0.0)), -PITCH_LIMIT, PITCH_LIMIT) 且同步 camera.rotation.x = _pitch；旧档兼容：若没有 pitch 键则保持 0。B) 若想保留现字段语义，可同时写 "pitch_deg" 与 camera_mode，读档时优先取 _pitch 值。
- 验证：save → 改 _pitch=1.0 → load → 断言 _pitch==1.0 且首帧 camera.rotation.x==1.0；四模式各存读一次。

##### F5 [P2] EF 原始动作片段一律 loop=true，retarget 透传 → 一旦开启战斗，攻击/闪避动作永不结束
- 位置：characters/ef_reference_rig.gd:175-181（load_file 返回，硬编码 loop:true）、:336-341（retarget 透传）、characters/player_avatar.gd:20-23、:50-62、:373
- 证据：
~~~
	return {
		"name": path.get_file().get_basename(),
		"loop": true,
		"length": length,
		"tracks": tracks,
		"attr_space": format == "attributes",  # 姿态增量格式（局部=L_bind·增量）
	}
~~~
~~~
- 战斗系统（yamato 动作集）暂时整体关闭——EF 资产尚无授权确认，
- 先把动作系统藏起来；翻回 true 即整体恢复（连击/闪避/持刀移动）。
const COMBAT_ENABLED := false
~~~
- 根因：EF JSON 里没有可靠的 loop 元数据（至少当前口径没解析），作者按“动画资产默认循环”一刀切写 true；而 ATTACK_CHAIN/DODGE_CLIPS 里的一次性动作（三段斩、闪避）走同一份 retarget 产物，于是动作层（F2 的同一个 _advance_action）不会结束它们，on_finished 回调与连击推进都不会发生。
- 影响：当前被 COMBAT_ENABLED=false 整体掩盖，属于“开关一开就爆”的潜伏 P2：三连击第一段永久停在末帧、action_active 恒 true、combo 缓冲失效。若之后单独打开闪避（不打开战斗）也会命中。
- 修复方案：A) _load_file 读 asset 的 loop 字段（缺失时默认 false，仅 living 目录 / *_idle* 显式设为 true），retarget 不要再 get("loop", true) 兜底成 true；B) 同时在 animator 里实现 F2 的 loop 回绕，双保险：即使动作标了 loop 也按“动作层用 loop 表示可重复触发”的语义处理。
- 验证：把 COMBAT_ENABLED 临时打开，按 3 次左键，断言每次攻击在 length 处 on_finished 触发、action_active() 回到 false、combo 推进到下一段。

##### F6 [P2] character_rig 在每个面的循环里重复整盒 classify_faces：每个 cube 做 6 次全量像素级分类
- 位置：characters/character_rig.gd:240-248（内层 for face_name 里调用）、characters/ysm_model.gd:232-261（classify_faces 内部又遍历全部面并逐像素读 alpha）
- 证据：
~~~
			for face_name in cube["faces"]:
				var cls := "solid"
				if tex != null:
					var classes := YsmModel.classify_faces(cube, tex)
					cls = String(classes.get(face_name, "solid"))
				if cls == "cull":
					continue
~~~
- 根因：classify_faces 的接口是“给一个 cube 返回所有面的分类”，但调用点放在面循环内部，同一个 cube 被完整分类 6 次；每次分类内部再对 6 个面各自的 UV 矩形逐像素 tex.get_pixel(...).a8（ysm_model.gd:232-261），复杂度是 6×6×像素数。
- 影响（估算，条件性）：单个 4×12 像素肢体面约 48 px、躯干 8×12≈96 px，一个 cube 6 面合计约 200-900 次 get_pixel → 6 倍重复后每 cube 约 1.2k-5k 次；一个 40-80 cube 的 YSM 模型在 build_model 里就是 5 万-40 万次 GDScript get_pixel + 大量 Rect2i 分配，估算单次构建多花 60-300ms。触发点是 player._ready（main.gd:225 add_child(player)，加载界面还未出现，见 F8）与 F6 换模型（avatar:251-257），会表现为启动黑屏加长 / 局内换装明显卡顿。仅当玩家放入 res://assets/characters 的 YSM 包时成立（仓库当前无此资产，见覆盖缺口）。
- 修复方案：A) 把 var classes := YsmModel.classify_faces(cube, tex) 移到 for face_name 循环之前，循环内只做 classes.get(face_name)；B) 更好：把分类结果按 (cube, texture) 缓存在 cube["_face_cls"] 或 rig 级字典，一次构建内只算一遍。
- 验证：给 classify_faces 加调用计数器（测试桩），构建一个 40 cube 模型，断言调用次数从 240 降到 40；用 Time.get_ticks_usec 包住 build_model 对比耗时。

##### F7 [P2] main 在 focus 接线前调用 load_column_now：新世界出生列被并进 y≈0 的玩家带，多同步生成约 4-6 个区块随即卸载
- 位置：scenes/main.gd:220-223、:232、world/chunk_manager.gd:215-269（load_column_now）、:764-776（column_band）、:843-845（_focus_chunk_y）、:873-878（_focus_column）
- 证据：
~~~
	var spawn_column := Vector2i(
			VoxelCoords.floordiv(spawn_block.x, config.chunk_size),
			VoxelCoords.floordiv(spawn_block.y, config.chunk_size))
	chunk_manager.load_column_now(spawn_column)
~~~
  中间为 _spawn_player / apply_save_state / starting_kit / player_state_provider 接线（:225-231）
~~~
	chunk_manager.focus = player
~~~
~~~
func column_band(col: Vector2i) -> Vector2i:
	var cy: int = world.config.chunks_y
	if cy <= LEGACY_FULL_COLUMN_LAYERS:
		return Vector2i(0, cy - 1)
	var band := _surface_band(col)
	if col.distance_squared_to(_focus_column()) \
			<= collision_radius * collision_radius:
		var py := _focus_chunk_y()
		band = Vector2i(mini(band.x, py - PLAYER_BAND),
				maxi(band.y, py + PLAYER_BAND))
~~~
- 根因：load_column_now 内部用 column_band 决定纵向带，而 column_band 的“玩家带”依赖 focus；main 在 :223 调它时 focus 仍是 null，_focus_column() 返回 (0,0)、_focus_chunk_y() 返回 0（chunk_manager.gd:844/874）。新世界默认出生块 SPAWN_BLOCK=(34,34)（main.gd:16）且 chunk_size=16 → 出生列 (2,2)，其到 (0,0) 的 distance_squared 恰好为 8 ≤ collision_radius²(=16)（collision_radius=4，chunk_manager.gd:35），于是玩家带 py±2 以 py=0 并入，band 下沿被拉到 0 层；chunks_y=32 时正常地表带约 4-10 层，于是多同步生成 y=0..3 约 4 个区块并逐块建网格、置 ACTIVE（load_column_now:215-269 的同步三段循环），随后 focus 被设为玩家、_outside_band（带 V_UNLOAD_PAD=1）又把这些区块当带外卸载。
- 影响：启动时白做约 4-6 个区块的生成 + 贪心网格 + 激活回调（含树系统按列计数）再立刻卸载，估算 15-35ms 启动延迟，且诱发 dormant 缓存/树计数的无谓 churn；仅当出生列距原点 ≤4 列时触发（默认新世界正是），存档在远处的世界不受影响。
- 修复方案：A) 把 :232 的 chunk_manager.focus = player 提到 :223 之前（但 player 在 :225 才 _spawn_player，需要先把 focus 设成一个与玩家同位置的空节点/或给 load_column_now 显式传玩家带中心）；B) 更干净：给 load_column_now(column, player_y) 加纵向带参数，不依赖 focus 全局状态。
- 验证：新世界启动时打印 load_column_now 生成的 coord 列表，断言只含地表带（不含 y=0..3）；或断言启动仪式 _dormant/unload 队列为空。

##### F8 [P2] 化身 setup 在加载界面出现之前同步解析全部 EF JSON（97 个文件 ≈ 100-300ms 黑屏）
- 位置：characters/player_avatar.gd:112-120、:139-147；characters/ef_reference_rig.gd:90-116
- 证据：
~~~
func setup(owner_player, voxel_world) -> void:
	player = owner_player
	world = voxel_world
	weapon_path = PACK_ROOT + "/yamato_sword.tscn"
	_load_ef_raw()
	if _build_gen == 0:
		build_model()
~~~
~~~
func _load_ef_raw() -> void:
	var abs_path := ProjectSettings.globalize_path(EF_CLIP_DIR)
	_ef_raw = EfRef.load_dir(abs_path)
~~~
- 根因：player 由 main._spawn_player 在 main.gd:225 里 add_child，触发 player._ready → avatar.setup（player_controller.gd:155）→ _load_ef_raw 同步递归扫目录 + JSON.parse_string 全部 user://anim_ef；而 main._begin_loading() 在 main.gd:239 才创建 LoadingOverlay，所以这段时间是黑屏，先做了重 IO。
- 影响：用户放入 EF 资产（作者注释自述 97 个片段）时，启动在没有任何进度提示的情况下卡 100-300ms（按单文件 JSON parse 1-3ms 估），弱机更久；若 JSON 很大（BepInEx 导出的完整骨骼轨）单文件可能 >10ms，合计可到秒级。仓库当前无 user:// 资产，故为条件性风险。
- 修复方案：A) 把 _load_ef_raw 移到 _begin_loading 之后（例如 main 在 overlay 出现后下一帧再 _spawn_player，或 avatar 收到 "assets_ready" 信号后协程分帧解析）；B) 直接丢进 Thread 解析（JSON.parse_string 的结果是普通 Array/Dictionary，可跨线程），完成后 call_deferred 回主线程；C) 至少分帧：每帧解析 4-8 个文件并推进 progress。
- 验证：在 user://anim_ef 放 97 个 JSON，用 Time.get_ticks_msec 包住 player 实例化→ready，确认 add_child 调用时延 < 一帧（16ms）；并确认黑屏期间 overlay 已可见。

##### F9 [P2] _load_cmu_clips 在 retarget 协程最后一帧同步加载全部 user://anim_bvh（单帧数十万次 Transform3D 合成）
- 位置：characters/player_avatar.gd:280-301（_load_cmu_clips，末尾 BvhLoader.load_dir）、:190-200（_retarget_async 每 8 clip 让一帧，收尾调用 _load_cmu_clips）；characters/bvh_loader.gd:53-66、:193-288
- 证据：
~~~
func _load_cmu_clips() -> void:
	var cmu_dir := DirAccess.open(CMU_DIR_RES)
	if cmu_dir != null:
~~~
  （此处是 res:// 下 CMU *.txt 片段的解析段，省略）
~~~
	var user_dir := DirAccess.open(BVH_DIR_USER)
	if user_dir != null:
		var bvh := BvhLoader.load_dir(BVH_DIR_USER, rig)
		for key in bvh:
			clips["cmu/" + key] = bvh[key]
~~~
- 根因：EF 的 retarget 是分帧让出的（每 8 个 clip await 一帧），但 BVH 的“解析 + retarget”被同步塞在协程的收尾帧里：load_dir 对每个 *.bvh 同步 parse（文本解析）并 retarget（bvh_loader.gd:193-288 对全帧、31 根骨逐帧合成 world_chain 并保留每帧 keys）。
- 影响（条件性）：CMU 动作 120fps、单文件 1000-3000 帧很常见；10 个文件 → 1-3 万帧 × 31 骨 ≈ 30-90 万次 Transform3D 合成 + 数万 Dictionary，全部落在同一帧 → 秒级卡死（F6 换模型时直接冻住，无 overlay）；同时这段内存常驻（全帧 keys），若用户放几十个 BVH 会显著胀内存。
- 修复方案：A) BVH 也走协程分帧（每个文件之间 await，且文件内部按 240 帧切片）；B) 或线程加载/重定向（rig 是只读数据，可在 Thread 里算完再回主线程合并）；C) 长期：BVH 只保留降采样后的目标帧率（如 30fps）并做关键帧压缩，丢弃每帧全骨 Transform3D 数组。
- 验证：在 user://anim_bvh 放 5 个 CMU 长度 BVH，量 F6 之后单帧耗时（Engine.get_frames_drawn 配合 Time.get_ticks_msec），要求任意帧 < 16ms；统计 clips 字典字节数。

##### F10 [P3] 不可破坏方块（基岩等）时挖掘进度条常亮（_mine_seconds=INF 使 ratio 恒 0）
- 位置：player/player_controller.gd:405-413（置 INF）、:1182-1185（进度条判定）、:470-472（_reset_mining 不重置 _mine_seconds）
- 证据：
~~~
		if not bool(info["breakable"]):
			# 不可破坏（基岩等）：记住目标并把时长置无穷——后续帧
			# target 未变直接跳过（曾每物理帧重复 break_info+mine 空转）
			_mine_active = true
			_mine_target = target
			_mine_elapsed = 0.0
			_mine_seconds = INF
~~~
~~~
	if _mine_active and _mine_seconds > 0.0:
		var ratio := clampf(_mine_elapsed / _mine_seconds, 0.0, 1.0)
		_progress_bar.visible = true
		_progress_fill.size = Vector2(ratio * 60.0, 6.0)
~~~
- 根因：判定用的是 _mine_seconds > 0.0，INF 也满足；ratio = elapsed/INF = 0，于是显示一个 60×6 背景、0 宽填充的进度条，一直挂到松开左键或移开视线。
- 影响：对准基岩/不可破坏方块按住左键时，屏幕固定位置出现“空进度条”，视觉噪声；不影响逻辑。
- 修复方案：A) 判定改为 if _mine_active and _mine_seconds > 0.0 and _mine_seconds < INF:（或 is_finite(_mine_seconds)）；B) 顺手在 _reset_mining 里把 _mine_seconds = 0.0 一起重置，避免残留状态被别处读取。
- 验证：对准基岩按住左键，断言 _progress_bar.visible == false；对准泥土按住断言 visible == true。

##### F11 [P3] build_model 把 ClipLib.builtin_clips() 在循环里调 9 次（8 个键 + 一次遍历）
- 位置：characters/player_avatar.gd:177-182；characters/clip_lib.gd:259-269
- 证据：
~~~
	clips = {}
	for key in ClipLib.builtin_clips():
		clips[key] = ClipLib.builtin_clips()[key]
	animator = Animator.new()
	animator.setup(rig, clips)
~~~
- 根因：for 的迭代对象调一次、每轮循环体里又调一次，共 1+8=9 次；而 builtin_clips() 每次调用都重新构造 8 个片段（每个片段含多关节 times/quats/poss 数组），没有任何缓存。
- 影响：每次构建模型（启动、F6 换模型）多花约 1.5-3.5ms（按单次构建 0.2-0.4ms 估），纯浪费；配合 F6 的重复触发（F1）会放大。
- 修复方案：A) var built := ClipLib.builtin_clips(); clips = built.duplicate(true)（注意 animator 若会改写片段需深拷贝；实测 animator 只读则直接用 built 即可）。B) 更彻底：给 ClipLib 加 static var _builtin_cache，首次构建后复用（片段是只读数据）。
- 验证：给 builtin_clips 加静态计数，断言一次 build_model 只构建 1 次；测量 build_model 耗时。

##### F12 [P3] 每物理帧的小对象分配与字符串反射（动画/化身热路径）
- 位置：characters/character_animator.gd:195-214（_eval_base_pose）、:217-235（_apply_action）；characters/player_avatar.gd:602（player.get("_pitch")）、:651-652（joints.find）、:615-680（_apply_pose）
- 证据：
~~~
	pose[jname] = {"q": q, "p": p}
~~~
  _apply_action 里是同款逐关节字典写法（:230-234）
~~~
~~~
~~~
	var pitch_in = player.get("_pitch")
~~~
- 根因：pose 用“每关节一个 {q,p} 字典”的表示，每物理帧重建 20 个字典（base 层）+ 动作激活时再 20 个，_eval_base_pose 里 sample_track 还会为每个关节产出 times/quats/poss 引用数组；avatar._apply_pose 每帧再 globals/skins 各 resize(20)、20 关节 × 3 次 _bone_img.set_pixel 并 _bone_tex.update（约 960B 上传），并用 joints.find("Tool_R")/find("Torso") 做字符串线性查找。player.get("_pitch") 是每帧两次字符串反射（可直接 player._pitch，player_avatar 已持有 player 引用；之所以用 get 大概是避免窄类型循环依赖）。
- 影响：60fps 下约 120-160 个短命容器/帧（≈8k/s），GC 压力在成百上千实体场景会体现为周期性小卡；纹理每帧 update 960B 可接受。属明确技术债，未构成 >100ms 单帧。
- 修复方案：A) pose 改成两个 PackedVector4Array/Array（quats、poss）按关节索引存，或复用同一批字典只写字段（避免 new）；B) joints.find 缓存为常量索引（JOINTS 顺序固定，Tool_R/Torso 的位置是编译期常量）；C) pitch 用 player.get 的结果缓存或 player_avatar 增加 set_pitch 接口。
- 验证：用 Performance.get_monitor(OBJECT_COUNT) 与 Memory 采样对比改动前后；或在 headless 跑 600 帧统计 alloc 次数（GDScript 可用 Performance 的 object count 差）。

##### F13 [P3] _loading_tick 每渲染帧全量遍历 world.chunks 统计 ACTIVE（加载期数万条目 × 每帧）
- 位置：scenes/main.gd:273-293（:278-280 的 for），分母来自 chunk_manager.estimate_band_chunks / view_distance=16（chunk_manager.gd:27、:274-283）
- 证据：
~~~
func _loading_tick(delta: float) -> void:
	_loading_time += delta
	var active := 0
	for coord in world.chunks:
		if world.chunks[coord].state == ChunkState.State.ACTIVE:
			active += 1
~~~
- 根因：active 计数没有维护缓存，靠每帧遍历字典；加载期 desired_columns 是半径 16 的圆盘（约 800 列）× 地表带高度（数层到十几层），world.chunks 可达 ~1-2 万条，逐帧遍历 + 每个 entry 一次 Dictionary 访问。
- 影响：加载期间每帧 0.3-1ms 额外 CPU（估算 1-2 万次字典迭代），且加载可能持续数秒到 LOAD_TIMEOUT=45s（main.gd:72），属可省的开销；加载结束后 _loading_tick 不再调用，不影响游玩帧率。
- 修复方案：A) ChunkManager 里维护 active_count（_commit_mesh 置 ACTIVE 时 +1，卸载/demote 时 -1），main 直接读；B) 或让 chunk_manager 暴露 get_active_count() 时缓存并每 N 帧更新一次（loading 进度条不需要 60Hz 精度）。
- 验证：加载完成时断言缓存计数 == 遍历统计值；对比 _loading_tick 单帧耗时。

##### F14 [P3] _find_land_spawn 最坏 1264 次 column_profile（含约 9-12 次噪声采样 + Dictionary 分配）
- 位置：scenes/main.gd:631-645；generation/terrain_generator.gd:286-334（column_profile）、:423-424（column_height 包装）
- 证据：
~~~
func _find_land_spawn(start: Vector2i) -> Vector2i:
	if generator.column_height(start.x, start.y) > generator.sea_level:
		return start
	for radius in range(1, 80):
		for a in 16:
			var ang := TAU * a / 16.0
			var cx := start.x + int(round(cos(ang) * radius * 8.0))
			var cz := start.y + int(round(sin(ang) * radius * 8.0))
			if generator.column_height(cx, cz) > generator.sea_level:
~~~
- 根因：新世界若出生点在海里，会按 79 圈 × 16 方向螺旋搜索陆地，每点一次 column_height = column_profile（约 9-12 次 FastNoiseLite 采样 + smoothstep + 一个 4 字段 Dictionary），无任何缓存/粗筛。
- 影响（估算）：最坏 1264 次 profile ≈ 10-40ms（按 8-30µs/次估），且仅新世界、出生在海中时发生；不是卡死级，但属可优化的启动路径。若后续在 column_profile 里加更多层噪声（作者注释的 v8/v9 方向）会线性恶化。
- 修复方案：A) 先用便宜的海陆掩码（单一 continental noise 粗采样，或 C# NativeTerrainBridge.column_surface_range 一次拿一列）粗筛，只有高于海平面的候选才走 column_profile；B) 或把搜索半径上限从 80 圈降到 24（作者注释也承认 640 格覆盖半个大陆波长已足够）。
- 验证：构造全海种子，包住 _find_land_spawn 计时，断言 < 10ms；或给 column_profile 加计数，断言调用次数 < 100。

##### F15 [P3] 化身代码死分支 + 收刀手部位置滞后一帧
- 位置：characters/player_avatar.gd:568-570（死代码）、:602（反射读 _pitch）、:670 与 :684-686（先读后用）、:678（本帧才更新 _sheath）
- 证据：
~~~
	if state != "swim" and _was_swim:
		pass  # 出水过渡由快照过渡自然衔接
~~~
~~~
		# 收刀态：手放鞘位（刀鞘跟随髋部）
		var sheath_xf: Transform3D = _sheath_in_hand_transform()
~~~
（_sheath_in_hand_transform 内部读 _sheath.transform，而 _sheath 的位置在稍后的 :678 才被更新）
- 根因：出水分支被留成空实现（依赖 base 过渡掩盖，注释已说明是刻意取舍，但 pass 分支本身是无意义代码且会误导读者以为有状态机）；收刀手部变换在 _apply_pose 中先取鞘的上一帧变换、随后才更新鞘，存在一帧滞后。
- 影响：视觉上收刀瞬间手部位置比刀鞘落后一帧（16ms，基本不可见）；死分支纯可读性/维护成本。
- 修复方案：A) 删除 568-570 的 if/pass（或改成注释说明）；B) 把 _sheath 的更新提到 _sheath_in_hand_transform 调用之前，或直接把本帧鞘变换算出来传参。
- 验证：代码审阅即可；收刀逐帧对比手/鞘变换差 < 1e-3。

##### F16 [P3] 背包打开时鼠标左键仍可触发挥拳/攻击（缺 inventory_open 判定）
- 位置：player/player_controller.gd:171-183
- 证据：
~~~
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				# 未锁定时第一次点击仅锁定视角，不触发挖掘
				if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
						and not inventory_open:
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				elif avatar != null and avatar.is_armed():
					# 拔刀：左键=三段连击（挖掘收刀后恢复）
					avatar.attack()
				elif avatar != null and not _raycast_from_camera()["hit"]:
					# 对空挥拳 = 拳击连击反馈（有目标时走挖掘动作）
					avatar.play_punch()
~~~
- 根因：只有“锁定鼠标”那个分支带了 not inventory_open；elif 的 attack/play_punch 分支没有，因此背包界面打开时点击界面空白处（不在 Panel/Control 的 mouse_filter=STOP 范围内）会走对空挥拳分支。
- 影响：背包打开时点击空白区域触发一次拳击动作（COMBAT 关闭时是 play_punch，视觉上手臂挥一下），属轻微体验瑕疵；将来打开战斗后会变成误攻击。
- 修复方案：A) 在 MOUSE_BUTTON_LEFT 分支最外层加 if inventory_open: pass（或提前 return），使左键在 UI 打开时完全不参与 gameplay；B) 统一在 _unhandled_input 入口 if inventory_open and not _drag.is_empty(): 只处理拖拽，其余 gameplay 输入全部短路。
- 验证：打开背包，点击空白处，断言 animator.action_active() == false 且无 hit 事件。

##### F17 [P3] bvh_loader 两处数值隐患：float→int 窄化、空轨 length 为负
- 位置：characters/bvh_loader.gd:198（n_frames 窄化）、:330（slice 的 length 计算）
- 证据：
~~~
	var n_frames: int = minf(parsed["n_frames"], frames.size() / maxi(channels_total(channels), 1))
~~~
~~~
	out["length"] = (quats_size(out) - 1) * step
~~~
- 根因：minf 返回 float，赋给 int 时 GDScript 隐式截断（依赖“帧数本来就是整数”的隐含前提）；slice 在轨迹为空（quats_size=0）时得到 -step 的负长度，若这份 clip 被播到，animator 的 length 判定/采样会落到负时间。
- 影响：当前输入数据正常时不可见；若用户提供 n_frames 与实际数据不一致的 BVH，会静默少帧/多帧；空轨 clip 极少出现。属防御性技术债。
- 修复方案：A) 用 int(mini(parsed["n_frames"], frames.size() / maxi(...))) 显式取整并下限钳 0；B) out["length"] = maxf(0.0, (quats_size(out) - 1) * step)，或在 slice 里对空轨直接放弃该 clip。
- 验证：构造 n_frames 带小数的 BVH 与空轨 BVH，断言 n_frames 正确、length >= 0。

#### 已核查无问题的风险点

- player/player_controller.gd:257-371：跳跃缓冲（_jump_buf/JUMP_BUFFER 0.15）+ 土狼时间（COYOTE 0.12）+ 落地轻沉、闪避冲量衰减逻辑与顺序正确，物理帧内完成；深水游泳分支每帧同步 _space_prev/_jump_buf 并丢弃跳缓冲（:342-347），避免出水瞬间 stale 边沿。
- player/player_controller.gd:260-264：基岩层以下兜底传送放在脚下区块门禁之前（注释说明了不加会永久冻结），顺序正确。
- player/player_controller.gd:1293：get_save_state 用 is_inside_tree() 分支取 position，退出保存（节点已离树）不会触发 global_position 告警。
- player/player_controller.gd:1318-1324：旧档迁移（无 inventory 键 → STARTING_KIT、槽位数组 → GridInventory.deserialize 自动迁移）语义清晰，不会把新档误判成旧档。
- world/chunk_manager.gd:127-139：_exit_tree 先 save_all(_current_player_state()) 再 WorkerThreadPool.wait_for_task_completion，退出不丢当前区块/玩家状态（我确认过顺序，不存在“先杀线程再存”）。
- world/chunk_manager.gd:735-743 与 :865-870：_is_wanted 与 estimate_band_chunks 用同一个 column_band，加载进度分母与实际可激活集合一致，不会出现进度永远 100% 不到的假死。
- world/chunk_manager.gd:756、:857-861：垂直卸载用 V_UNLOAD_PAD=1 滞回，层边界不会来回横跳。
- world/water_ripples.gd:131-132：texture() 直接返回缓存的 _texture；main.gd:540-550 只在对象/中心变化时 set_shader_parameter，没有每帧纹理分配（我按 main._update_ripples 的 6 次 getter 调用核对过，全部是成员读取）。
- characters/player_avatar.gd:546：update_locomotion 早退 if skeleton == null or animator == null or player == null: return，build_model 失败/尚未完成时不会每物理帧空指针崩溃。
- characters/player_avatar.gd:268-275：set_mining(false) 会 stop_action 清掉 dig 动作层，不会在停止挖掘后残留 loop 动作（F2 的冻结只发生在持续挖掘期间）。
- characters/player_avatar.gd:190-200：_retarget_async 用 _build_gen 递增防 F6 连续切换时的协程赛跑（旧协程发现 gen 变化直接 return），不会把旧模型的骨骼写进新骨架；每 8 个 clip await 一帧的让出策略本身正确（问题只在收尾的同步 BVH，见 F9）。
- characters/character_animator.gd:182-188：事件用 prev_time < t <= time 时间穿越触发、只在 w<=0 且 target<=0 时清空 _action，语义正确（大 delta 单帧的旧缺陷已在 :167-168 注释处修掉）。
- scenes/main.gd:225-232：先 add_child(player)（触发 _ready，注入 world/item_registry 已在 :649-656 完成）→ apply_save_state → player_state_provider → focus=player 的顺序正确；:297-308 _finish_loading 恢复 _saved_budgets 而不是硬编码，避免预算永久放大。
- characters/bvh_loader.gd:53-66：load_dir 只扫顶层 *.bvh，不递归子目录，避免把备份/临时文件误当动作加载。

#### 覆盖缺口

- 未运行 Godot（lead 在跑测试套件），所有耗时/内存数字均为静态估算，不是实测；F6/F8/F9/F14 的量化需在放有用户资产的机器上实测确认。
- 仓库不含 user:// 运行数据（user://anim_ef / user://anim_bvh）与 res://assets/characters 的 YSM 包，因此 F5/F6/F8/F9 属“用户放入资产后”的条件性风险；当前仓库状态下它们不会触发。
- characters/*.tscn 只读了 player/player.tscn；character 相关的 .tres/.tscn 资源与 shader（character_surface.gdshader）未逐行审。
- main.gd 只深挖了初始化顺序、每帧扇出、加载/存档接线；HUD 构建（_setup_hud:701-711）与 debug HUD 可见性切换只做了接口级核对。
- world/voxel_raycast.gd（相机/挖掘共用的 DDA）未读内部实现，F3 的单射线漏检（薄墙角）结论基于调用方式推断，未验证 raycast 是否已有半径/多次采样。
- world/chunk_renderer.gd、world/voxel_light.gd、world/water_flow.gd 只在 main.gd 的接线层读过，未审内部；tree_manager/drop_manager 同理（超出本 part 范围）。
- terrain_generator.column_profile 的真实单次成本未实测（F14 标了估算区间），只确认了它每次做 9-12 次噪声采样并分配一个 Dictionary。

---

### 7.5 part-5 — items / interaction / UI（物品、交互与界面）

#### 概览

- 审查范围（11 个文件，约 2414 行）：items/grid_inventory.gd(427)、items/drop_manager.gd(447)、items/item_drop.gd(394)、items/drop_table.gd(43)、items/crafting_recipes.gd(83)、items/item_registry.gd(93)；interaction/block_mining.gd(87)、interaction/block_placement.gd(74)；presentation/item_icons.gd(164)、presentation/drop_visuals.gd(290)、presentation/loading_overlay.gd(312)。为判定调用关系另读了 player/player_controller.gd（约 600 行相关段）、scenes/main.gd:100-240/700-719，以及 tests/test_items.gd、tests/test_drops.gd 的断言段。
- 健康度：数据层（占位/堆叠/合并/部分拾取/存档容错）实现扎实，主路径原子性（放置扣料、合成扣料、拾取入包）基本正确（:491-511 先放置再扣、:302-321 落格与合并分开）。缺陷集中在**失败路径兜底不对称**：同一种失败（掉落实体达上限）在 3 个调用点只有 1 个回滚，形成 2 条 P1 物品丢失；另有 2 条 P2（拖拽竞态静默丢失、合成满包产物丢失）与 1 条 P2 存档健壮性缺口。
- 未发现 P0：掉落实体上限/坏档/超堆均有拒绝或钳制，最坏结果是物品消失，没有崩溃或 world.json 损坏的直接路径。

#### 发现

##### F1 [P1] 挖掉支撑方块时，上方花的掉落被丢弃（物品永久丢失）
- 位置：interaction/block_mining.gd:78-86；调用方 player/player_controller.gd:422-426
- 证据：
    # 断支撑级联：植物失去下方实体即折断（掉自身——花可拾取，
    # 高草 DropTable 无掉落自然为空）
    var above: int = world.get_block(block_pos + Vector3i(0, 1, 0))
    if VoxelTypes.PLANT_IDS.has(above):
        world.set_block(block_pos + Vector3i(0, 1, 0), VoxelTypes.AIR_ID)
        if allow_drops:
            DropTable.drops_for(above, world.registry, item_registry)
    if not allow_drops:
        return []
    return DropTable.drops_for(block_id, world.registry, item_registry)

    # player/player_controller.gd:422-426
    func _break_block(block_pos: Vector3i) -> void:
        var drops := BlockMining.mine(
                world, block_pos, item_registry, _mine_drops)
        for drop in drops:
            _dispatch_drop(int(drop["item_id"]), int(drop["count"]), block_pos)
- 根因：:84 的 drops_for 返回值没有 append 进 mine() 的返回数组，注释自述"掉自身——花可拾取"却没接上；_break_block 只遍历 mine() 的返回值，于是这份掉落被直接丢弃。高草无物品（void 掉落）恰好掩盖了这行代码从未生效。
- 影响：花是有物品的（core/item_types.gd:73-75 注册 core:flower_poppy / core:flower_dandelion），且世界生成会在草上放花（generation/terrain_generator.gd:545-547）。挖掉花下方草方块即销毁花且不产掉落，物品永久丢失；草是最常挖的方块，触发率高，且原型无创造模式无法补回。这是真实 gameplay 物品丢失，而非风格问题。
- 修复方案：A) 先算主方块掉落再合并植物掉落：
    var drops: Array = DropTable.drops_for(block_id, world.registry, item_registry) if allow_drops else []
    if allow_drops:
        drops.append_array(DropTable.drops_for(above, world.registry, item_registry))
    return drops
  B) 保持"先破坏后结算"的顺序也行，把 :84 结果存局部数组，:85-86 返回前 append；allow_drops=false 时植物仍清除、无掉落（保持现状）。
- 验证：tests/test_items.gd 新增：构造 world 在草上放 FLOWER_POPPY，调 BlockMining.mine 断言返回含 flower item 且上方格变 AIR；再断言 allow_drops=false 时返回空、花格仍变 AIR。

##### F2 [P1] _drop_held 先扣背包再生成掉落，128 上限时生成失败不回滚，整堆消失
- 位置：player/player_controller.gd:452-467；items/drop_manager.gd:109-111
- 证据：
    # player/player_controller.gd:452-467
    var count := int(entry["count"]) if whole_stack else 1
    var item_id := int(entry["item_id"])
    inventory.remove_at_entry(entry, count)
    # 从眼睛沿视线抛出（含俯仰）；保护期覆盖飞行时间，防止瞬吸回
    var look := -camera.global_transform.basis.z
    drop_manager.spawn_drop(
            item_id, count,
            camera.global_position + look * 0.6,
            look * DROP_THROW_SPEED + Vector3.UP * DROP_ARC_UP,
            DROP_PICKUP_DELAY)

    # items/drop_manager.gd:109-111
    if _drops.size() >= MAX_DROPS:
        push_warning("掉落实体已达上限 %d，本次生成降级" % MAX_DROPS)
        return null
  （MAX_DROPS = 128，items/drop_manager.gd:20）
- 根因：先 inventory.remove_at_entry 再 spawn_drop，且不检查返回的 ItemDrop 是否为 null。DropManager 的调用契约明确要求调用方在 null 时回退入包：同文件 _dispatch_drop:431-438 与 _drop_drag_to_world:1022-1030 都这么写，tests/test_drops.gd:541-550 也注明"调用方回退直接入包语义"。_drop_held 是唯一漏掉的调用点。
- 影响：世界已有 128 个掉落物时（满包反复挖掘/砍树最容易堆到上限）按 Q 或 Ctrl+Q，物品从背包扣除后立即消失，玩家侧只有一条控制台 push_warning。属不可恢复的物品丢失，且正是玩家最需要"丢东西腾包"的时刻。
- 修复方案：A) 与 _dispatch_drop 对齐：spawn 返回 null 时 var leftover := inventory.add(item_id, count)，leftover>0 再 push_warning。B) 先 spawn 成功再 remove_at_entry（需先克隆 entry 数据防复制，remove 失败概率极低可断言）。推荐 A，改动最小且符合既有契约。
- 验证：复用 tests/test_drops.gd:542-546 的填满上限循环，新增玩家侧用例：背包放 1 堆，填满 128 实体，调 _drop_held(true)，断言 inventory.count_of 不变、drop_count 仍为 128。

##### F3 [P2] 拖拽期间掉落仍自动入包；原位被占后 _bounce_back 的兜底 add 忽略 leftover，满包时静默丢物品
- 位置：player/player_controller.gd:1006-1017；根因在 items/drop_manager.gd:167-175
- 证据：
    # player/player_controller.gd:1007-1014
    func _bounce_back() -> void:
        var e: Dictionary = _drag["entry"]
        var ok: bool = inventory.try_drop(e, int(_drag["from_zone"]),
                int(_drag["from_x"]), int(_drag["from_y"]),
                bool(_drag["rotated"])) == GridInv.DropResult.PLACED
        if not ok:
            # 理论不可达（原位无人争抢）；兜底自动寻位防丢物品
            inventory.add(int(e["item_id"]), int(e["count"]))

    # items/drop_manager.gd:167-171
    # 拾取不要求所在区块就绪（顺手清走未加载边缘的掉落）
    if player_center != null and pickup_inventory != null \
            and drop.ready_for_pickup(player_center) \
            and pickup_inventory.can_fit(drop.item_id):
        var leftover: int = pickup_inventory.add(drop.item_id, drop.count)
- 根因：注释假设"原位无人争抢"不成立——背包打开、手里拿着拖拽物时，脚边掉落仍按原有节奏自动入包（pickup 完全不感知 inventory_open，player_controller.gd:93 的 inventory_open 从未传给 DropManager），可能填掉刚空出的原格，使 try_drop 返回 BLOCKED/MERGED/PARTIAL 走兜底；这里 add 的返回值被丢弃且无 warning。
- 影响：需"满包 + 拖拽期间脚边恰好有掉落"才触发，但一旦触发物品静默消失——这是全部丢失路径里唯一连 warning 都没有的一条（_dispatch_drop、_drop_drag_to_world、craft 都有 warning）。
- 修复方案：A) 兜底改成 var leftover := inventory.add(...); if leftover > 0: push_warning("背包已满，%d 个物品丢失" % leftover)（与 _dispatch_drop 一致）。B) 更根本：DropManager 增加 pickup_enabled 开关，_toggle_inventory 打开时置 false，_begin_drag 期间暂停拾取（顺带解决"开着背包被塞满"体验问题）。
- 验证：新增用例：打开背包持拖拽物，把原格塞满（模拟自动拾取），对非法目标调用 _attempt_drop，断言背包总数不变；修复前会少 1 个以上且无 warning。

##### F4 [P2] 砍树掉落直连 DropManager，失败无背包兜底（掉落满 128 时整棵树产物丢失）
- 位置：scenes/main.gd:150-151；items/drop_manager.gd:109-111；systems/trees/tree_manager.gd:1251-1258
- 证据：
    # scenes/main.gd:150-151
    tree_manager.drop_spawner = func(item_id: int, count: int, pos: Vector3) -> void:
        drop_manager.spawn_drop(item_id, count, pos)

    # systems/trees/tree_manager.gd:1251-1258
    func _settle_drop(cell_count: int, near := Vector3.ZERO) -> void:
        if not drop_spawner.is_valid():
            return
        var logs := maxi(1, cell_count / 3)
        var sticks := maxi(1, cell_count / 5)
        drop_spawner.call(registry.id_for_name("core:log"), logs, near)
        drop_spawner.call(registry.id_for_name("core:stick"), sticks,
                near + Vector3(0.5, 0.0, 0.5))
- 根因：三个掉落入口里只有挖掘走带兜底的 _dispatch_drop；砍树回调把 spawn_drop 的 null 直接丢弃（player 引用在 main.gd 里已存在，只是没接兜底）。_settle_drop 一次发两批（logs+sticks），两批会同时丢失。
- 影响：满包采矿把实体堆到 128 上限后继续砍树，整棵树产物（约 cell_count/3 原木 + cell_count/5 木棍）消失，仅控制台 warning；砍树是核心循环，损失量比挖单块大得多。
- 修复方案：A) 回调里判断返回 null 后 add 到 player.inventory 并 warning（等价 _dispatch_drop 的兜底）；B) 抽出 main._spawn_world_drop(item_id, count, pos)，挖掘/砍树/调试统一走同一兜底。
- 验证：填满 MAX_DROPS 后砍倒一棵树，断言 player.inventory.count_of("core:log") 增加对应数量（修复前不变）。

##### F5 [P2] 满包合成：材料被扣、产物丢失，can_craft 不校验产出空间且 craft 返回 true
- 位置：items/crafting_recipes.gd:60-83；UI 启用条件见 player/player_controller.gd 的 _refresh_crafting
- 证据：
    static func can_craft(recipe: Dictionary, inventory) -> bool:
        ...
        if item_id < 0 or inventory.count_of(item_id) < int(entry[1]):
            return false

    static func craft(recipe: Dictionary, inventory) -> bool:
        if recipe.is_empty() or not can_craft(recipe, inventory):
            return false
        var items: ItemRegistry = inventory.item_registry()
        for entry: Array in recipe["inputs"]:
            inventory.remove_item(items.id_for_name(String(entry[0])), int(entry[1]))
        var output: Array = recipe["output"]
        var output_id := items.id_for_name(String(output[0]))
        var leftover: int = inventory.add(output_id, int(output[1]))
        if leftover > 0: push_warning("背包已满，%d 个合成产物丢失" % leftover)
        return true
- 根因：:69-71 注释明确声明"产出放不下时消耗照常、多余产出告警丢弃"是有意取舍；但 can_craft 是合成按钮的启用条件，它只查材料不查产出空间，满包时点合成 → 材料消失、产物只进控制台，UI 无反馈，且 craft 返回 true 让调用方认为成功。
- 影响：真实 gameplay 物品丢失（至少一次产出量），玩家完全不可感知；若配方一次产出多件则丢得更多。不是崩溃，但违背"扣料必须原子"的期望。
- 修复方案：A) can_craft 末尾加最低门槛 inventory.can_fit(output_id, 1)（:185-211，无副作用探测），UI 灰掉按钮或显示"背包已满"。B) 保留"消耗照常"语义则至少把 warning 升级为 HUD 提示，并让 craft 返回实际产出数量供 UI 显示。
- 验证：新增用例：AUTO 区全满且无法并堆的背包，craft 后断言 can_craft 为 false（修复后）；当前代码下断言材料减少、产物 0。

##### F6 [P2] 持续挖掘时进度/掉落判定沿用开始挖掘时的工具快照，切换工具不生效
- 位置：player/player_controller.gd:388-419
- 证据：
    var target: Vector3i = hit.block_pos
    if not _mine_active or target != _mine_target:
        _mine_active = true
        _mine_target = target
        _mine_elapsed = 0.0
        var info := BlockMining.break_info(
                world.get_block(target), world.registry, _held_tool())
        ...
        _mine_seconds = float(info["seconds"])
        _mine_drops = bool(info["drops"])
    _mine_elapsed += delta
    if _mine_elapsed >= _mine_seconds:
        _break_block(target)
- 根因：break_info 只在目标切换时计算，按住左键不动时按 1-8/滚轮换工具不会刷新 _mine_seconds/_mine_drops。
- 影响：① 先按住挖石头再从木镐切空手，仍按 1.375s 出石头并掉落（借用镐的判定）；② 反向从空手切石镐不会加速，玩家会以为切工具无效；③ HUD/手持模型与挖掘参数不一致。属可感知的玩法不一致，不是数据丢失。
- 修复方案：A) 每帧比较当前手持工具 id 与快照，变化时按比例换算进度：new_elapsed = old_elapsed * new_seconds / old_seconds 并重算 _mine_drops。B) 更简单：工具变化时 _reset_mining()（体验略差但一致）。
- 验证：把"是否需要重算"抽成小函数单测（给定 tool 变化返回 true）；实机按住挖石时切镐，进度条速度应立即变化。

##### F7 [P2][待验证] 背包 deserialize 的 typed for 缺少坏元素防护，坏档可能中断读档（与掉落侧防护不一致）
- 位置：items/grid_inventory.gd:344、items/grid_inventory.gd:352；对比 items/drop_manager.gd:438-440
- 证据：
    # items/grid_inventory.gd:342-344
    if data is Array:
        # 旧槽位存档：逐堆 first-fit 迁移
        for entry: Dictionary in data:
    # items/grid_inventory.gd:351-352
    if data is Dictionary and int(data.get("v", 0)) == 2:
        for entry: Dictionary in data.get("entries", []):

    # items/drop_manager.gd:438-440（同一类坏档的防护）
        for entry in drops_data:
            if not (entry is Dictionary):
                continue
- 根因：v1/v2 两条路径都用 typed for 直接假定元素为 Dictionary；若存档被手工编辑或写坏成 [null, {...}]，Godot 4 typed for 在赋值类型不匹配时的运行时行为未实机确认（[待验证]：报错中断该函数、还是跳过该元素）。掉落侧对同一场景显式跳过非 Dictionary，说明项目按"坏档要能读"的标准要求。
- 影响：最坏情况是读档时背包反序列化中断（背包清空或部分恢复），属存档可靠性问题；最好情况只是该条目跳过。因未运行 Godot 无法确认确切行为，标 [待验证]。
- 修复方案：两条路径都改成 for entry in data: if not (entry is Dictionary): continue（与 drop_manager 一致）；v2 另外防御 data.get("entries", []) 非 Array 的情况。改动 3-4 行。
- 验证：tests/test_items.gd:231-236 附近新增：{"v":2,"entries":[null,"junk",{正常条目}]}，断言正常条目仍恢复且不报错；v1 路径同样加 junk 用例。

##### F8 [P3] loading_overlay 的定种子 RNG 建了没用，注释与实现不符
- 位置：presentation/loading_overlay.gd:158-166
- 证据：
    var rng := RandomNumberGenerator.new()
    rng.seed = 20261024
    for z in N:
        var layer: Array[Vector3i] = []
        ...
        layer.shuffle()
        _order.append_array(layer)
- 根因：Array.shuffle() 使用全局 RNG，rng 从未参与洗牌（未被使用的局部变量，编辑器应有 UNUSED_VARIABLE 警告）；注释声称"层内随机（定种子）"，实际每次启动顺序不同。
- 影响：纯表现层，无功能影响；每次启动填充顺序不稳定，观感略抖动。
- 修复方案：A) 用 rng 自行洗牌（for i in range(size-1, 0, -1): var j := rng.randi_range(0, i); 交换）。B) 删除 rng 两行并把注释改成"层内随机（全局 RNG）"。
- 验证：连续启动两次记录 _order 前几项；或抽洗牌函数单测。

##### F9 [P3] add() 对 max_stack=0 的物品会死循环（当前数据不可达的防御性缺口）
- 位置：items/grid_inventory.gd:154-181（:171-178）；上限来源 item_registry.gd:67-68
- 证据：
    while remaining > 0:
        var spot := first_fit(item_id)
        if spot.is_empty():
            break
        var put := mini(limit, remaining)
        _spawn_entry(item_id, put, int(spot["zone"]),
                int(spot["x"]), int(spot["y"]), bool(spot["rotated"]))
        remaining -= put
- 根因：limit 来自 _stack_limit → _registry.max_stack，缺省 64 但定义可显式写 max_stack: 0（item_registry.gd:67-68 是裸 get，无下限钳制）；此时 put=0，first_fit 每次都能找到空位 → 无限循环并无限生成 0 数量条目，阻塞主线程。
- 影响：当前全部物品 max_stack 为 64 或 1（core/item_types.gd:41/49/58/68/87），不可达；属未来加配置时的炸点（主线程挂死）。
- 修复方案：_stack_limit 出口钳制 maxi(1, _registry.max_stack(item_id))，或 add 开头 if limit <= 0: return count。
- 验证：单测注册临时物品 {"id":"core:test_zero","max_stack":0}，add(1) 应在有限步返回。

##### F10 [P3] 合成取料覆盖 GEAR 手动区，但产物只进 AUTO 区（语义不对称）
- 位置：items/grid_inventory.gd:214-219（count_of）、:227-237（remove_item）、:146-147（_is_auto_zone）、:154-181（add）
- 证据：
    func count_of(item_id: int) -> int:
        var total := 0
        for e in entries:
            if int(e["item_id"]) == item_id:
                total += int(e["count"])
        return total

    func remove_item(item_id: int, count: int) -> int:
        ...
        for i in range(entries.size() - 1, -1, -1):
            ...
            if int(e["item_id"]) == item_id:
                remaining -= remove_at_entry(e, remaining)
- 根因：count_of/remove_item 覆盖全部分区（含 GEAR 手动仓库区），而 add 自动入包只寻 MAIN/HOTBAR（:160-169 只遍历 AUTO 区）。tests/test_items.gd:159-171 明确 GEAR 只能手动进出，于是玩家特意放在 GEAR 的合成材料会被合成消耗，而产物放不下时只能进 AUTO 并被丢弃。
- 影响：边缘 case（需玩家把材料放 GEAR 才触发），不复制物品，只扩大丢失面；属语义不一致。
- 修复方案：A) 与 add 对称：can_craft/craft 改用仅 MAIN/HOTBAR 的计数与扣料（明确 GEAR 是纯仓库）。B) 或允许 add 在 AUTO 满时溢出到 GEAR（改动大，不推荐）。
- 验证：单测：材料只放 GEAR，修复后 can_craft 应为 false。

##### F11 [P3] 背包界面每次 changed 全量重建条目节点（queue_free 后同帧新增，可能 1 帧重影）
- 位置：player/player_controller.gd:838-846、:687-701
- 证据：
    func _rebuild_entries() -> void:
        _entry_nodes.clear()
        for zone in _zones:
            var layer: Control = _zones[zone]["layer"]
            for child in layer.get_children():
                child.queue_free()
            for e in inventory.entries_in(int(zone)):
                layer.add_child(_make_entry_node(e))
- 根因：queue_free 在帧末释放，新节点立即加入，同一帧新旧条目节点同时存在（合并/移动后位置不同会出现 1 帧重影）；且每次 changed 都 O(条目数) 各建 3 个 Control 节点。
- 影响：量级小（条目数 ≤ 背包格数，<110，仅背包打开时），持续拾取/拖拽时可能有闪动。属技术债，非可感知卡顿。
- 修复方案：A) 改用 remove_child + free() 立即释放（或先置 visible=false）；B) 增量按 uid 复用节点，changed 时只处理增删改。
- 验证：打开背包在脚边连续拾取 20 个掉落，高帧率录制观察重影；或临时统计每帧节点数。

##### F12 [P3] deserialize 对超上限堆叠数静默截断（测试已固化该行为，配置变更时会吞数量）
- 位置：items/grid_inventory.gd:355-356；tests/test_items.gd:231-236
- 证据：
    var count := mini(int(entry.get("count", 0)),
            _stack_limit(item_id)) if item_id >= 0 else 0
    # tests/test_items.gd:231-236
    # 容错：未知名称跳过、超上限截断、越界/重叠降级 first-fit
    ...
    check_eq(invs2.count_of(dirt), 71, "未知名跳过 + 截断 + 越界降级不丢")
- 根因：截断是刻意设计（测试固化 999999→64），但与"物品不丢"的目标矛盾：超出部分被丢弃而非拆成多堆（v1 路径走 add() 会拆堆）。
- 影响：只有 max_stack 被下调（配置变更/老档）时才产生真实数据损失；当前配置不变，属潜在技术债。
- 修复方案：A) 截断到 limit 后把余量再 add() 拆堆，与 v1 语义一致。B) 保留截断但 push_warning，让问题可见。
- 验证：改用例断言 999999 的条目修复后 count_of 保持原值（或至少发出 warning）。

#### 已核查无问题的风险点

1. items/drop_manager.gd:205-215 _remove_at 对 _drops/_visuals/_visual_counts/_was_grounded/_landing_t/_landing_theta_from/_landing_theta_target/_last_support 八个并行数组同步删除，:158/:173/:235 三个调用点都走它，无错位。
2. items/drop_manager.gd:219-238 _merge_pass：同 item + 距离² ≤ MERGE_RADIUS² + 遵守 max_stack，溢出留对侧不超堆；n≤MAX_DROPS=128、每 0.5s 一次（约 8k 次距离比较/半秒），可忽略。
3. items/drop_manager.gd:167-175 部分拾取：add 返回 leftover 写回 drop.count，剩余留地面，不复制不吞（tests/test_drops.gd:630-646 断言 60→64、余量 6）。
4. items/grid_inventory.gd:302-321 try_drop：PLACED 先 drop_check/can_place 再 append；MERGED/PARTIAL 由 moved 决定、余量写回 entry["count"]，与 player/player_controller.gd:985-1003 四分支处理一致。
5. player/player_controller.gd:491-511 _try_place：先 BlockPlacement.place 成功后才 remove_at_entry(entry,1)，不会出现"方块放下物品没扣"或反向复制；失败有 show_hint。
6. items/drop_manager.gd:433-447 apply_save_state：非 Dictionary、未知物品、坏坐标跳过，超上限 break；配合 items/item_drop.gd:371-394 对 count/pos/vel/age 的钳制，坏档不崩溃（tests/test_drops.gd:740-749 覆盖）。
7. items/grid_inventory.gd:185-211 can_fit：已有堆空隙 + 影子网格逐堆铺入，与 add:154-181 合并+开堆语义一致（tests/test_items.gd:197-207 断言 448/449 与镐 3/4 把边界）。
8. items/grid_inventory.gd:340-367 deserialize：位置合法原位恢复、越界/重叠降级 first-fit 不丢物品；未知名称跳过（tests/test_items.gd:223-236 覆盖）。
9. player/player_controller.gd:1065-1085 关包时若有拖拽走 _drop_drag_to_world（:1022-1030），spawn 失败会 add 兜底并 warning，不吞物品；_clear_drag 同时隐藏拖拽图标与预览。
10. player/player_controller.gd:687-701 _refresh_hud 由 inventory.changed 驱动（:149）并顺带刷新背包界面（:700-701），拾取/挖掘入包时 HUD 与数据不会脱节；_refresh_inventory_screen 对关闭状态提前返回（:874-877）。
11. items/drop_manager.gd:253-271 _sync_visuals 仅 count 变化时 _rebuild_copies，正常帧无分配；visual 与 drop 数组一一对应（_register:136-147）。
12. presentation/item_icons.gd、presentation/drop_visuals.gd：静态缓存按数值 ID 键控，ItemIcons.set_atlas 清缓存（scenes/main.gd:114-117 在 UI 构建前先 set_atlas/configure，顺序正确）；extruded 图标逐像素四边形受 32×32 上限约束且被缓存。
13. items/item_drop.gd:136-201 水体浮力/阻力、:341-351 _solid_at（y<0 视为实心、注册表 collision 字段）与世界顶/底边界处理正确，未发现越界或 NaN 路径。
14. interaction/block_placement.gd:28-52 火把/提灯支撑：提灯只落地、火把可墙挂并写 attach 状态；set_block 失败即返回 false，无半成品状态。

#### 覆盖缺口

- 未运行 Godot、未执行任何测试（lead 正在跑测试套件，按要求避免竞争）；上文 tests/*.gd 的引用均为静态阅读断言段，非执行结果。
- 未审 presentation/ 其它文件（block_entity_renderer.gd、torch_renderer.gd 等不在指定范围），只按调用关系扫过。
- scenes/main.gd 仅精读 100-240 与 700-719；240-700（HUD/环境/加载流程）未逐行审。
- systems/trees/tree_manager.gd 仅按掉落回调抽查 :1235-1275，未做内部审查（不在范围）。
- [待验证] F7 中 Godot 4 typed for 遇到坏元素的运行时行为未实机确认；F6 的工具切换需要实机输入才能验证观感。
- 拖拽交互只做静态路径检查，未实机验证鼠标边界（例如 1×2 镐旋转后拖到快捷栏第二行、背包面板边缘点击遮罩的命中区域）。

---

### 7.6 part-6 — presentation / lighting / sound（表现、光照与声音）

#### 概览

审查范围：`presentation/*.gd`（14 个，约 2,290 行）、`presentation/water/sspr_reflection.gd`（964 行，头注释自述"当前未挂载"）、`*.gdshader`（14 个，约 1,850 行）、`systems/lighting/*.gd`（3 个 1,058 行：voxel_light 554 / light_manager 268 / cave_fog 236）、`systems/sound/*.gd`（5 个 1,284 行：sound_manager 295 / footstep_system 324 / ambient_system 320 / acoustic_system 214 / early_reflections 131）。合计约 7,440 行（注释密度很高，大量"实机踩坑"记录是本项目最强资产）。未运行 Godot/测试（lead 正在跑套件），全部结论来自静态阅读 + 调用链核对，性能数字为静态估算。

健康度结论：**没有 P0**（本层不碰存档/序列化，也没有不可控泄漏；RID/节点生命周期在 chunk_renderer、cave_fog、block_entity_renderer 里都收得干净）。真正的风险集中在"同步重活"四类：① 每次方块音都同步跑一遍声学反射的体素扫描（early_reflections）；② 水流每写入一格水就触发整块 C# 全量重光照（voxel_light）；③ 镜像 SubViewport 每帧无条件再渲染一遍世界（water_reflection）；④ 洞穴雾脏标对任何 block_changed 都置真（cave_fog）。另有一批"当年踩过、注释写了、但仍有遗留"的小坑（water_side 未设贴图、图集导出路径、死代码 RID）。

#### 发现

##### F1 [P1] 每次方块音的早期反射规划在主线程做 O(包围盒体积) 体素扫描，单帧 10-40ms 卡顿

- 位置：`systems/sound/early_reflections.gd:98-131`（`_candidate_faces`）、`systems/sound/early_reflections.gd:40-91`（`plan_reflections`）、`systems/sound/sound_manager.gd:218-220`（`play_3d` 内无条件调用）、`systems/sound/sound_manager.gd:227-231`
- 证据：
```gdscript
# systems/sound/early_reflections.gd:100-123
	var mn := Vector3i(mini(floori(source.x), floori(ear.x)),
			mini(floori(source.y), floori(ear.y)),
			mini(floori(source.z), floori(ear.z))) 			- Vector3i(SCAN_MARGIN, SCAN_MARGIN, SCAN_MARGIN)
	var mx := Vector3i(maxi(floori(source.x), floori(ear.x)),
			maxi(floori(source.y), floori(ear.y)),
			maxi(floori(source.z), floori(ear.z))) 			+ Vector3i(SCAN_MARGIN + 1, SCAN_MARGIN + 1,
			SCAN_MARGIN + 1)
	var faces := []
	for x in range(mn.x, mx.x):
		for y in range(mn.y, mx.y):
			for z in range(mn.z, mx.z):
				var cell := Vector3i(x, y, z)
				var b := world.get_block(cell)
				if not Acoustic.is_opaque_block(b):
					continue
				for k in 6:
					...
					if Acoustic.is_opaque_block(
							world.get_block(air_cell)):
						continue
```
```gdscript
# systems/sound/sound_manager.gd:218-220
	if _world != null:
		_spawn_reflections(stream, pos, ear,
				volume * AcousticScript.occlusion_gain(occ), pitch)
```
- 根因：候选面集合是"源↔听者 AABB 各轴再外扩 SCAN_MARGIN=2、+1"，即每轴 `Δ + 5` 格；随后每个实心格还要 6 次邻格 `get_block`，每个通过几何筛的候选面再跑一次 24m `occlusion_between` DDA。整个过程是同步的，直接发生在 `world.set_block` → `block_changed` 的调用栈里（同一帧、主线程）。这层实现没有空间索引/缓存，纯暴力体积扫描。
- 影响：`VoxelWorld.get_block`（`world/voxel_world.gd:80-86`：bounds + `chunks.get` + `world_to_local` 两个除法 + `chunk.get_block`）约 0.6-1.5µs。近距挖掘（3-4m，盒 ≈ 7×5×7 = 245 格 → ~0.5-1.5k 次查询）≈1-3ms 可忍；但砍树/清叶（15m，盒 20×20×(Δy+5)，Δy 常 2-8 → 2,800-8,000 格，实心格 30% 时 ≈8k-20k 次 `get_block`）≈8-30ms，单个 tick 内多族节流后仍会被调用 2 次（木头族 + 树叶族，各 80ms 节流 `systems/sound/sound_manager.gd:61-64`）→ 单帧 20-60ms，明显卡顿。24m 上限（`early_reflections.gd:38`）时最坏 29³ ≈ 24k 格。这是本范围最确定的 P1。
- 修复方案：A) 把扫描域从"包围盒"改为"源↔听者线段附近 2 格"——沿线段每 2 格取 1 个切片，每切片取 5×5 截面（调用量 O(距离/2 × 25) ≈ 200-400 次查询，视距 15m 时降 20-50 倍），语义上正好覆盖"能产生早期反射的墙面"；并把 `plan_reflections` 移到 `WorkerThreadPool`（纯读体素，线程安全，参考 `presentation/distant_shell.gd:133` 的只读 worker 先例），先播直达声、反射声延迟 1 帧插入（听觉无感）。B) 备选（改动最小）：给 `plan_reflections` 加距离门 `direct > 8.0 → 直接 return []`（远场反射本来就低于 ENERGY_CUTOFF=0.06，见 `:28`），并把 `SCAN_MARGIN` 降为 1。
- 验证：在 `plan_reflections` 首尾加 `Time.get_ticks_usec` 探针（与 `world/voxel_world.gd:99-103` 的 set_block perf 打印同风格），砍倒一棵 12m 外的树，断言单次 < 2ms；或单测构造 32×32 石质地板 + 24m 间距，断言候选面数 < 256、耗时 < 3ms。

##### F2 [P1] 水流每写入一格水都触发整块 C# 全量重光照 + 光照数组拷贝（洪水/挖渠时 CPU 尖峰）

- 位置：`systems/lighting/voxel_light.gd:292-316`（`_on_block_changed_impl` 的变遮挡分支）、`world/water_flow.gd:17-19`（TICK_INTERVAL 0.25 / MAX_CELLS_PER_TICK 512）、`world/water_flow.gd:96-111`（`_evaluate` 写水）
- 证据：
```gdscript
# systems/lighting/voxel_light.gd:307-316
	# 收敛兜底：宽区域逐格封盖时，回灌梯度网的减光波前会在
	# 高值残留处断链（实测封 5x5 坑残留 sky=12）——对本块做
	# C# 全量重算（~0.5ms）覆盖为精确值，diff 有变化才标脏
	var before_light := chunk.light.duplicate()
	var six := []
	for d in DIRS:
		six.append(_chunk_at(chunk.chunk_coord + d))
	if _init_chunk_light_native(chunk, six, six[2] == null) \
			and chunk.light != before_light:
		chunk.mesh_dirty = true
```
```gdscript
# world/water_flow.gd:17-19
const TICK_INTERVAL := 0.25
## 单 tick 最多评估格数（防大范围溃坝卡帧；剩余顺延下一 tick）。
const MAX_CELLS_PER_TICK := 512
```
```gdscript
# world/water_flow.gd:101-103
				world.set_block(pos, VoxelTypes.WATER_ID, false)
				world.set_block_state(pos, "level", target, true)
```
- 根因：`voxel_light._on_block_changed_impl` 的判定是 `old_op != new_op`（`:281-286`）。水的 `LIGHT_OPACITY` 是 2（`core/voxel_types.gd:49`），空气是 0 → 每一次 AIR→WATER 写入都走"变遮挡"分支，而该分支在做了 `_decrease` 之后**无条件**对整块做 `chunk.light.duplicate()` + `_init_chunk_light_native` 全量重算（注释自估 ~0.5ms，16³ 块 = 4,096 字节拷贝）。水流是引擎驱动的批量写入（每 0.25s 一 tick，最多评估 512 格），完全不区分"玩家盖房"和"水在流"。
- 影响：一个 tick 内若实际变化 100 格水 → 100 × (0.5ms 重算 + duplicate + `_decrease` BFS) ≈ 50-100ms，全部发生在同一帧的 `_process` 里（`world/water_flow.gd:42-46` 的 while 循环）；溃坝/大范围放水时单 tick 512 格全变 → 单帧 250ms+（硬卡）。挖开水渠这种常规操作也会在 1-2 秒内反复触发 10-50ms 的帧时间尖峰。顺带：`_decrease` 在浅水区（sky>0）还会走大范围波前。
- 修复方案：A) 对"半透明非实心方块"（water/branch/leaves，opacity 1-2）跳过全量兜底——它们的残值本来就能被"减光后的边界种子重扩散"修回来，全量重算只对实心封盖（opacity 15）有意义：`if new_op >= 15 and VoxelTypes.light_opacity(old_id) < 15:` 才保留 `before_light` + native 重算。B) 备选（更通用）：把重算请求按 chunk 合并——`_pending_relight[chunk_coord] = six`，在 `_process` 里每帧最多处理 1 块，同一帧多格写入只付一次 0.5ms。C) 长期：`WaterFlow` 写入走一个不触发光照信号的 `set_block_no_light`（水是均匀介质，光照只需在 tick 结束时对受影响 chunk 各重算一次）。
- 验证：`tests/test_water_flow.gd` 已有 tick 测试，可注入桩统计 `_init_chunk_light_native` 调用次数——修前"512 格水 tick"应 ≈512 次，修后应 ≤1（每 chunk 一次）；同时断言 `chunk.light` 与全量重算结果一致（光照正确性回归）。

##### F3 [P2] 水面镜像 SubViewport 每帧 UPDATE_ALWAYS 再渲染一遍世界，相机静止时也不降频

- 位置：`presentation/water_reflection.gd:37-41`、`presentation/water_reflection.gd:59-67`、`presentation/water_reflection.gd:77-107`
- 证据：
```gdscript
# presentation/water_reflection.gd:37-41
	viewport = SubViewport.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# 排除 layer 2（水面 instance）；分辨率 0.6x 降载（倒影经波纹扰动
	# +低 fresnel，半分辨率感不明显）
	viewport.size = Vector2i(768, 432)
```
```gdscript
# presentation/water_reflection.gd:95-107
	var mpos: Vector3 = mirror_cam.global_position
	if not mpos.is_equal_approx(_last_clip_pos):
		_last_clip_pos = mpos
		for mat in _clip_materials:
			if mat is ShaderMaterial:
				mat.set_shader_parameter("sspr_mirror_cam_pos", mpos)
				mat.set_shader_parameter("sspr_clip_y", water_h)
	# 视口尺寸跟随主视口（0.6x）
	var vs := get_viewport().get_visible_rect().size
```
- 根因：脏检查只省下了 4 次 uniform 重发和 `viewport.size` 重设，**渲染本身从不跳过**。镜像相机 `cull_mask = 0xFFFFF & ~(1 << 1) & ~(1 << 2)`（`:67`）意味着地形/树/实体/角色全部再画一遍；far=160（`:61`）限制的是距离，不是频次。
- 影响：第二遍完整场景 pass，像素数 = 主视口的 0.36×（0.6²），加上双倍 draw call 提交与剔除。若主线 GPU 帧为 6-8ms，镜像约 +2-4ms，即 +30-50% GPU 占用（估算，需实机 profiler 定档）。更可惜的是：玩家站着看海、看背包、看库存时倒影完全不变，仍在全速重绘。核显/低端 GPU 上这可能直接把 60fps 打到 45fps——届时应升为 P1。
- 修复方案：A) 在 `_process` 里缓存主相机 `global_transform` + `fov` + `viewport.size`，三者都没变时把 `render_target_update_mode` 设为 `UPDATE_ONCE`（相机一动立刻切回 `UPDATE_ALWAYS`）——静止期零成本，观感无损（水面自身位移/波纹不依赖 RT 更新，读到的仍是上一次正确倒影）。B) 备选：加画质档 `reflection_scale ∈ {0.3, 0.6, off}`，低档降到 0.3（0.09× 像素）或直接 `viewport.render_target_update_mode = DISABLED` 并把 `sspr_strength` 归零，水面只留天空色调制。
- 验证：加探针打印每帧 `RenderingServer.get_rendering_info(RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)` 与 `Time.get_ticks_usec` 的 GPU 帧；站着不动 30s，修后 draw call 应降到单遍水平；走动时帧时间不升。

##### F4 [P2] 洞穴雾脏标不过滤写入类型（水流/树占位写入也标脏）→ 连续编辑期几乎每帧烧 2.5ms；预算只在"柱之间"检查

- 位置：`systems/lighting/cave_fog.gd:47`、`systems/lighting/cave_fog.gd:61-79`、`systems/lighting/cave_fog.gd:95-109`、`systems/lighting/cave_fog.gd:132-146`
- 证据：
```gdscript
# systems/lighting/cave_fog.gd:47
	world.block_changed.connect(func(_p, _o, _n): _dirty = true)
```
```gdscript
# systems/lighting/cave_fog.gd:95-109
func _scan_step() -> void:
	var t0 := Time.get_ticks_usec()
	var chunk_size := world.config.chunk_size
	var y_lo := maxi(_scan_center.y - SCAN_WINDOW, 1)
	var y_hi := _scan_center.y + SCAN_WINDOW
	while not _scan_columns.is_empty():
		var col: Vector2i = _scan_columns.pop_back()
		var cells := _scan_column(world, col.x, col.y, y_lo, y_hi,
				chunk_size)
		if not cells.is_empty():
			_scan_marks["%d,%d" % [col.x, col.y]] = cells
		if Time.get_ticks_usec() - t0 > SCAN_BUDGET_USEC:
			return  # 本帧预算用尽，剩余柱下帧继续
	_scan_active = false
	_apply(_cluster(_scan_marks, _scan_center))
```
- 根因：脏标 lambda 忽略 `_p/_o/_n` 三个参数，任何 `block_changed`（含 `WaterFlow` 的每次写水、树系统清占位叶、水位降级）都置 `_dirty`；配合 `_rescan_timer > 0.5` 的节流与"玩家移动 >6 格也标脏"（`:72`），在连续写入期间 `_scan_active` 一结束就立刻开始下一轮，形成永续扫描。重扫成本：121 柱 × 28 层 ×（get_block + `_sky_at` + 最多 10 次 `_has_ceiling`），按注释实测 441 柱 = 40-120ms 折算，121 柱 ≈ 11-33ms/轮，按 2.5ms/帧摊 → 5-13 帧。预算检查在柱与柱之间，单柱最坏 ~28×(1+1+10) ≈ 300 次查询 ≈ 0.3-0.5ms，故单帧上限 ≈ 2.5ms + 0.5ms（可接受，不是主要问题）。
- 影响：站在水边看水流动、或砍树/除草造成连续写入时，帧预算被稳定吃掉 ~2.5ms（16.6ms 帧的 15%），与 chunk 网格提交 8ms 预算叠加后容易掉帧；而洞穴雾实际几乎不变（洞口几何不会因为水流而变）。
- 修复方案：A) 过滤事件：只对"会改变洞口几何"的写入置脏——`connect(func(p, o, n): if VoxelTypes.light_opacity(n) == VoxelTypes.light_opacity(o) and not (n == VoxelTypes.AIR_ID or o == VoxelTypes.AIR_ID): return; _dirty = true)`，或直接白名单"新建/破坏非空气实心块"。B) 备选：把脏标改成 tick 级合并 + 提高节流到 1.0-1.5s（雾更新延迟本来就"~1s 观感无差"，见 `:31-35` 注释）。C) 顺手把预算检查移进 `_scan_column` 的 y 循环（每 4 层一次），彻底杜绝单帧超预算。
- 验证：单测 `scan_for_mouths` 已有纯函数入口；加探针打印每轮扫描的帧数与总耗时；在瀑布旁站 30s，修后 `_scan_active` 占空比应接近 0（理想 <10%）。

##### F5 [P2] voxel_light 的"封盖兜底"只在 C# 可用时生效，GD 回退路径静默跳过 → 残留脏光

- 位置：`systems/lighting/voxel_light.gd:307-316`（`_init_chunk_light_native(...) and chunk.light != before_light`）、`systems/lighting/voxel_light.gd:88-143`（GD 回退 `_init_chunk_light_gd`）
- 证据：
```gdscript
# systems/lighting/voxel_light.gd:307-316
	# 收敛兜底：宽区域逐格封盖时，回灌梯度网的减光波前会在
	# 高值残留处断链（实测封 5x5 坑残留 sky=12）——对本块做
	# C# 全量重算（~0.5ms）覆盖为精确值，diff 有变化才标脏
	var before_light := chunk.light.duplicate()
	var six := []
	for d in DIRS:
		six.append(_chunk_at(chunk.chunk_coord + d))
	if _init_chunk_light_native(chunk, six, six[2] == null) \
			and chunk.light != before_light:
		chunk.mesh_dirty = true
```
- 根因：兜底完全依赖 `_init_chunk_light_native` 的返回值；原生桥不可用（纯 GDScript 运行、headless/测试、C# 程序集加载失败）时该函数返回 false，`chunk.light` 保持 BFS 残值，代码既不重试也不标记需要修复，属于"静默降级"。
- 影响：只在无 C# 环境出现——但项目以 headless 跑测试套件（tests/test_lighting.gd 一类），意味着测试环境的光照行为与发行版不一致；注释自述的 5×5 封坑残留 sky=12（洞内错误亮斑）在 GD 回退下永久存在，后续任何依赖天光的下游（cave_fog 的 `SKY_THRESHOLD=11` 判定、曝光、水面反射 h_gate）都跟着错。正式构建有 C#，用户不可见，因此定 P2 而非 P1。
- 修复方案：A) 返回 false 时降级调用已有的 `_init_chunk_light_gd(chunk, six, ...)`（代码就在同文件 `:88-143`，只是慢 5-10 倍；封盖是低频操作，可接受），并把结果同样与 `before_light` 对比标脏。B) 备选：在 `setup()` 时探测原生桥可用性，把"无 native"写进一个 `_native_unavailable` 标志并 `push_warning` 一次，让测试基线显式知道降级状态。
- 验证：`tests/test_lighting` 加用例：禁用 native 后执行"挖 5×5 坑再填死"，断言坑内 `get_sky_light == 0`（修前应残留 12）。

##### F6 [P2] 火把/提灯延迟生成不复查方块身份 → 同帧放置+拆除会留下幽灵实体

- 位置：`presentation/block_entity_renderer.gd:59-73`、`presentation/block_entity_renderer.gd:86-98`
- 证据：
```gdscript
# presentation/block_entity_renderer.gd:59-73
func _on_block_changed(pos: Vector3i, old_id: int, new_id: int) -> void:
	if new_id == _block_id:
		# 延迟到帧末：放置端在 set_block 之后才写 attach 状态
		#（set_block 会清状态），立即生成读不到贴墙方向
		_spawn_deferred.call_deferred(pos)
	elif old_id == _block_id:
		_despawn(pos)

func _spawn_deferred(pos: Vector3i) -> void:
	var attach := Vector3i.ZERO
	var st := world.get_block_state(pos)
	if st.has("attach"):
		attach = parse_attach(st)
	_spawn(pos, attach)
```
- 根因：`_spawn_deferred` 只读 `attach` 状态，不校验 `world.get_block(pos)` 是否仍等于 `_block_id`。若同一帧内先放置后拆除（`old_id == _block_id` 的 `_despawn` 当场执行时 `_by_cell` 里还没有该格 → no-op），随后 deferred 回调仍然创建 MeshInstance3D，该格已是空气。
- 影响：幽灵火把/提灯一直悬浮在空气里（常驻区块内不会自动消失，只有 `on_chunk_unloaded` 的包围盒清理才收掉），玩家看到"拆不掉的发光体"，且其 mesh 占用一次 draw call。触发窗口小（同帧生效）但完全可达：贴墙火把的支撑方块被挖掉时，状态清除/连带清除与放置在同一帧内先后写 `block_changed` 即可复现。
- 修复方案：A) `_spawn_deferred` 首行加 `if world.get_block(pos) != _block_id: return`（一次字典查询，成本可忽略）。B) 备选：改为监听"状态写入"信号而非 `call_deferred`，或把 attach 直接作为 `block_changed` 的附加数据传下来（需改 world 侧签名，改动大）。
- 验证：`tests/test_torch_entities.gd` 加用例：`set_block(torch)` → 同帧 `set_block(air)` → `await get_tree().process_frame` 两次 → 断言 `count() == 0`；修前应返回 1。

##### F7 [P2] 964 行未挂载的 sspr_reflection.gd：PREDELETE 漏释放 6 个 pipeline RID 与 2 个 sampler

- 位置：`presentation/water/sspr_reflection.gd:14-22`（头注释）、`presentation/water/sspr_reflection.gd:53-67`（释放列表）、`presentation/water/sspr_reflection.gd:77-88`（字段）
- 证据：
```gdscript
# presentation/water/sspr_reflection.gd:14-19
## 【当前未挂载】4.7 下 global uniform + Texture2DRD 无法送达材质：材质
## 绑定时经 Variant→get_rid() 取 RS wrapper，早于 wrapper 创建的绑定解析
## 成占位黑纹且不自动重解析（主线程/渲染线程 set 均试过，含每帧重 set）。
## 水面反射改用镜像投影 + 屏幕纹理采样（water_surface.gdshader 的
## sspr_mirror_vp，main._update_water_reflection 每帧下发），零 compute、
## 可反射天空、gl_compatibility 可用。本文件保留供任意平面反射/真 SSR
```
```gdscript
# presentation/water/sspr_reflection.gd:53-67
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if rd == null:
			return
		for rid: RID in [sspr_scatter_shader, sspr_resolve_shader,
				sspr_temporal_shader, sspr_blur_shader, sspr_blur_down_shader,
				sspr_blur_up_shader, tex_copy_shader, tex_copy_pipeline]:
			if rid.is_valid():
				rd.free_rid(rid)
		_free_texture_group()
		if view_proj_mat_buffer.is_valid():
			rd.free_rid(view_proj_mat_buffer)
		for level: Level in pyramid:
			_free_rt(level.down_rid)
			_free_rt(level.up_rid)
```
- 根因：`_notification` 的 RID 列表只有 6 个 shader + `tex_copy_pipeline`，而字段区（`:78/80/82/84/86/88`）登记的 6 个 pipeline——`sspr_scatter_pipeline`、`sspr_resolve_pipeline`、`sspr_temporal_pipeline`、`sspr_blur_pipeline`、`sspr_blur_down_pipeline`、`sspr_blur_up_pipeline`——一个都没释放；`nearest_sampler`/`linear_sampler`（`:73-74`）同样漏。当前该节点没有任何挂载点（全仓 `sspr_reflection` 仅出现在本文件自身），所以线上零影响；但只要有人按 `:19-22` 的注释"复用"，或 debug/capture 工具把它加进 Compositor 链，卸载时就会泄漏 RD 资源。
- 影响：现在 0；被复用时每次挂载/卸载/场景重载泄漏 8 个 RenderingDevice RID（pipeline/sampler），长时间反复截图/重载会累积到驱动内存并最终分配失败（RID 泄漏是"不可回收"的，只能重启进程）。
- 修复方案：A) 把这 6 个 pipeline 与 2 个 sampler 补进 `:57-59` 的数组（`for rid: RID in [...]` 一行即可，改动 3 行）。B) 备选：既然已判定 4.7 不可用，把整个文件移到 `debug/` 或 `addons/` 并改名（避免被误认为生产链路），同时修 A。
- 验证：代码审查即可确认字段与释放列表一一对应；若做运行时验证，在 `debug/capture_sspr.gd` 里挂载后释放两次，调用 `RenderingServer.get_rendering_device().get_driver_resource_count()` 前后对比无增长。

##### F8 [P2] distant_shell 后台烘壳任务与 _exit_tree 存在 UAF 窗口（窄，退出/重载期）

- 位置：`presentation/distant_shell.gd:99-102`、`presentation/distant_shell.gd:127-142`
- 证据：
```gdscript
# presentation/distant_shell.gd:99-102
func _exit_tree() -> void:
	# 在途 worker 任务的 UAF 防护：_build_task 首行检查后即返回
	_native = null
	_mesh_instance = null
```
```gdscript
# presentation/distant_shell.gd:127-142
func _start_build(center: Vector2i) -> void:
	_building = true
	_task_done = false
	WorkerThreadPool.add_task(_build_task.bind(center))

## worker 线程：C# 采样四环带产 ArrayMesh（只读噪声，线程安全）。
## 退出期防护：_exit_tree 已置空 _native——首行短路，任务空跑返回。
func _build_task(center: Vector2i) -> void:
	if _native == null:
		return
	var mesh: Mesh = _native.GenerateShellMesh(center.x, center.y)
	if mesh != null:
		_pending_mesh = mesh
		_pending_center = center
	_task_done = true
```
- 根因：防护是"检查后使用"（check-then-act），不是同步：worker 通过 `:136` 的 `_native == null` 检查后、到 `:138` 调用 `_native.GenerateShellMesh` 之间，主线程可能在 `_exit_tree` 把 `_native` 置 null 并让场景销毁 → worker 里出现 null 调用或对已释放 C# 对象的方法调用；之后 `:140-142` 还会写 `_pending_mesh/_task_done`（worker 写、主线程 `_physics_process:109-114` 读，无锁无原子）。任务 id 也没保存，`_exit_tree` 里无法等待。
- 影响：退出游戏/切换场景时，若恰好在烘壳（REBUILD_STEP=64 移动一次，烘焙 ~10-50ms）内 → 退出日志出现 `Attempt to call function 'GenerateShellMesh' on a null instance` 或对已释放实例赋值；严重时 WorkerThreadPool 在 shutdown 等待期间访问已释放对象导致退出崩溃/挂起。窗口窄（毫秒级、只在移动时），但退出崩溃会污染日志甚至掉内存。
- 修复方案：A) `_start_build` 保存 `_task_id = WorkerThreadPool.add_task(...)`；`_exit_tree` 里 `if _task_id >= 0: WorkerThreadPool.wait_for_task_completion(_task_id)`（最多等一次烘焙，退出可接受）。B) 备选：worker 用 `Mutex` 保护 `_native` 的读与置空，`_task_done` 用 `Callable.call_deferred` 回主线程提交（不再从 worker 写 GDScript 成员），并用 `_alive` 标志在回调里复查。
- 验证：压测脚本快速 quit 20 次（每次在移动中退出），grep 日志无上述错误；或用 `--quit-after` 反复启动退出。另：即使不改，也建议把 `:100` 的注释改成"窄窗口，非绝对防护"，避免后人误以为安全。

##### F9 [P2] 图集加载在导出包中整体失效：Image.load_from_file 对 res:// 返回 null → 25 个 tile 静默退化为程序化占位

- 位置：`presentation/texture_atlas_loader.gd:110-114`、`presentation/texture_atlas_loader.gd:79-97`、对照 `presentation/voxel_material_registry.gd:60-66`
- 证据：
```gdscript
# presentation/texture_atlas_loader.gd:110-114
static func _packed_image(tile_name: String) -> Image:
	var path := TEXTURE_PACK_DIR + "/" + tile_name + ".png"
	if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
		return null
	return Image.load_from_file(path)
```
```gdscript
# presentation/voxel_material_registry.gd:60-63
## 静水贴图：优先 ResourceLoader（导出包里 .png 以 .import 的
## .ctex 打包，Image.load_from_file 在导出环境对 res:// 返回 null
## → 空引用崩溃——审查发现）；加载失败回退程序化噪点（headless
```
- 根因：同一个坑在 `voxel_material_registry._water_still_texture`（`:64-66` 已改用 `load()`）被修过，但`texture_atlas_loader` 仍用 `Image.load_from_file`。导出包里 `res://assets/textures/*.png` 被导入为 `.ctex`，原始 png 不保证进包：`ResourceLoader.exists` 可能为 true（remap 存在），`Image.load_from_file` 却拿到不到文件（返回 null）→ `_packed_image` 返回 null → `generate_atlas_image`（`:79-97`）走 `_pixel_color` 程序化分支。
- 影响：导出构建里材质包**整体失效**——25 个 tile 全部变成程序化占位色；更糟的是 `_pixel_color` 生成的像素 alpha 恒 1，树叶等 cutout tile 的镂空全部变成实色块（`terrain_surface.gdshader:71-73` 的 `tex.a < 0.5` 永不命中），视觉上"树叶变成一坨实心方块"。编辑器/headless（直接读源码目录）不受影响，所以测试套件抓不到。[待验证：项目当前是否已走导出流程——README 未见发布/导出说明；若只跑源码，优先级可降为 P3，但这是"随时会踩"的已知坑]。
- 修复方案：A) 与 registry 对齐：`var tex := load(path) as Texture2D; return tex.get_image() if tex != null else null`（走 ResourceLoader remap，编辑器/导出通吃）。B) 备选：保留 `Image.load_from_file` 作为编辑器快速路径（`OS.has_feature("editor")`），导出走 `load()`；两种都应在 `packed_tile_count()` 里暴露实际命中数并在导出 CI 断言 == 25。
- 验证：`packed_tile_count()` 在导出包里应为 25（当前应为 0）；或加一个 headless 导出烟测打印该值。单测 `tests/` 里若有图集用例，用 `ResourceLoader.exists` 语义补一条。

##### F10 [P3] torch_flame 每像素 14 步 raymarch × 6 次 fbm3 × 8 hash13 ≈ 670 次 hash13/像素，缺距离 LOD

- 位置：`presentation/torch_flame.gdshader:16`、`presentation/torch_flame.gdshader:52-61`、`presentation/torch_flame.gdshader:65-78`、`presentation/torch_flame.gdshader:80-110`
- 证据：
```glsl
// presentation/torch_flame.gdshader:16
const int STEPS = 14;
// :65-70
float density(vec3 q, float t) {
	vec2 r2 = (q.xz - 0.5) * (1.0 / 0.21875);  // -1..1
	float h = (q.y - 0.5625) / 0.4375;         // 0 火根 → 1 火尖
	float n1 = fbm3(vec3(q.x * 4.0, q.y * 3.5 - t * 1.6, q.z * 4.0));
	float n2 = fbm3(vec3(q.x * 9.0, q.y * 8.0 - t * 3.0, q.z * 9.0));
// :93-94
	for (int i = 0; i < STEPS; i++) {
		float d = density(p, TIME);
```
- 根因：`fbm3` = 3 octave × `vnoise3`（8 次 `hash13`）= 24 次 hash13；`density` 调 2 次 = 48 次/步；14 步 ≈ 672 次 hash13 + 逐像素盒求交 + 色带 mix。加色混合（`render_mode ... blend_add`）无早退、无深度写，火焰片元越多成本线性增长。`STEPS` 是编译期常量，不随相机距离/画质档变化。
- 影响：量级估算——每像素约 7k ALU；1080p 下火焰占屏 0.5%（~10k px）≈ 70M ALU ≈ 0.02-0.07ms（中端 GPU），占屏 5%（~100k px，贴脸/多火把同屏）≈ 0.7ms；单看不构成 P1，但它是唯一"常驻空间体积着色"的 shader，叠加镜像 pass（F3 会把火焰在倒影里再画一遍）后成本翻倍。低端核显上值得一档 LOD。定 P3（技术债，非当前瓶颈）。
- 修复方案：A) 用相机距离驱动的 uniform 降步：`uniform int steps = 14;` + `for (int i = 0; i < 14; i++) { if (i >= steps) break; ... }`，`TorchRenderer` 按 `camera.distance_to(torch)/max_distance` 设 6-14（远处火焰本来只占几像素）。B) 备选：把 `density` 的第二层 `n2` 换成一次廉价 `vnoise3`（`fbm3` 只留 2 octave），视觉差异小、省 1/3。
- 验证：RenderingServer 帧时间对比（近距火把 + 倒影开启）；或用 GPU 捕获工具看该 draw call 耗时。修后近距帧时间不应上升、远距应下降。

##### F11 [P3] create_water_side_material 没设 water_tex：侧面水柱永远采样默认白纹理，水纹/白沫恒定

- 位置：`presentation/voxel_material_registry.gd:80-83`、`presentation/water_side.gdshader:44`、`presentation/water_side.gdshader:158-159`、`presentation/water_side.gdshader:172`
- 证据：
```gdscript
# presentation/voxel_material_registry.gd:80-83
func create_water_side_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://presentation/water_side.gdshader")
	return material
```
```glsl
// presentation/water_side.gdshader:158-159, 172
	float tex_l1 = texture(water_tex, uv1).r - 0.5;
	float tex_l2 = texture(water_tex, uv2).r - 0.5;
	...
	foam_noise *= 0.65 + (tex_l2 + 0.5);  // 贴图颗粒破碎白沫
```
- 根因：水面材质（`:53-57`）设了 `water_tex`，侧面材质（`:80-83`）漏设。未绑定的 `sampler2D` 在 Godot 里绑默认白纹理 → `tex_l1 = tex_l2 = 0.5`（恒定），`tex_flow.x = 0.5` 恒定，`foam_noise *= 1.65` 恒定增益，两层异向流动贴图完全失效。
- 影响：仅影响下落水柱/瀑布的四个侧壁（水面本体正常），观感上"侧壁没有流动细节、白沫偏多且不破碎"；不会崩溃（默认白纹理）。
- 修复方案：A) `create_water_side_material` 里补 `material.set_shader_parameter("water_tex", _water_still_texture())`（`_water_still_texture` 已存在且带程序化回退，调用一次）。B) 备选：把两个材质改成共享同一 `_water_tex` 缓存变量，避免重复生成。
- 验证：`get_shader_parameter("water_tex") != null` 断言；截图对比瀑布侧壁（修后应有方向性流动纹理）。

##### F12 [P3] ocean_waves 的过期注释与死常量会误导后续调参（CPU/GPU 波形实际同源，已核对一致）

- 位置：`presentation/ocean_waves.gd:30-33`（`WAVE_AMPLITUDE := 0.5`，全仓无第二处引用）、`presentation/ocean_waves.gd:41-46`、`presentation/ocean_waves.gd:49-52`、`presentation/water_surface.gdshader:25` 与 `:118-124`
- 证据：
```gdscript
# presentation/ocean_waves.gd:30-33
## 波起伏总幅度（格）——shader 的 wave_amplitude 与 CPU 采样共用
## 同值（视觉与浮物起伏一致）。0.5 = ±0.25 格：近景/远景可见的
## 真实起伏，波峰会轻微漫过岸线（拍岸感）
const WAVE_AMPLITUDE := 0.5
# :41-46
## 波浪位移（CPU 侧统一入口）：振幅与钳制跟 shader 完全一致
##（shader wave_amplitude=0.4 + clamp(-0.08, +0.22)；浮物/物理采样
## 必须走这里，直接调 wave_height 会与视觉水面漂移）
const SHADER_AMPLITUDE := 1.0
const DISPLACE_MIN := -0.16
const DISPLACE_MAX := 0.56
```
- 根因：`SHADER_AMPLITUDE/DISPLACE_MIN/DISPLACE_MAX` 与 `water_surface.gdshader:25`（`uniform float wave_amplitude = 1.0`）和 `:118-124` 的 `clamp(displacement, -0.16, 0.56)` 一致 → 物理/视觉确实同源；但 `WAVE_AMPLITUDE := 0.5` 无人引用（grep 仅本行），`:41-43` 注释里的 "0.4 / clamp(-0.08,+0.22)" 是三年前版本残留。`wave_offset` 实际用 `SHADER_AMPLITUDE`。
- 影响：无运行时后果，但下一个人"调水波幅度"很可能改 `WAVE_AMPLITUDE`（无效），或按过期注释把 clamp 改成 -0.08/+0.22（CPU 与 GPU 立刻不同源 → 浮物穿水/悬空，属于本项目已记录的经典事故类型）。
- 修复方案：A) 删除 `WAVE_AMPLITUDE`，`:41-43` 注释改为"与 water_surface.gdshader 的 wave_amplitude=1.0、clamp(-0.16,+0.56) 一致（改一处必改三处：本文件 44-46 行 + 两个水 shader）"。B) 若确实想保留"总幅度"概念，把它改为 `= SHADER_AMPLITUDE` 并加单测断言三者相等。
- 验证：单测里 `assert equals(OceanWaves.SHADER_AMPLITUDE, 1.0)` 并对比 `water_surface.gdshader` 无法直接读——可用 `load(shader).code` 正则断言 "wave_amplitude = 1.0" 与 "clamp(displacement, -0.16, 0.56)" 存在（防止漂移回归）。

##### F13 [P3] 区块激活时逐格扫描 4096×2 渲染器 + 卸载时全表遍历；可改为区块级索引

- 位置：`presentation/block_entity_renderer.gd:33-45`、`presentation/block_entity_renderer.gd:49-56`
- 证据：
```gdscript
# presentation/block_entity_renderer.gd:33-45
func on_chunk_active(coord: Vector3i) -> void:
	var chunk: ChunkData = world.chunks.get(coord)
	if chunk == null:
		return
	var s := chunk.dimensions.x
	for i in chunk.volume():
		if chunk.block_ids[i] == _block_id:
			...
			_spawn(coord * s + local, parse_attach(chunk.get_state(local)))
# :49-56
func on_chunk_unloaded(coord: Vector3i) -> void:
	var s := world.config.chunk_size
	var base := coord * s
	for cell in _by_cell.keys():
		if cell.x >= base.x and ...
```
- 根因：`chunk.volume()` 在 chunk_size=16 时是 4096 格（`core/world_config.gd:9`），Torch 与 Lantern 两个渲染器各扫一遍 → 每次区块激活 8192 次整数比较；卸载回调对每个卸载区块做一次 `_by_cell.keys()`（新建 Array 拷贝）再全表距离判断。好在激活回调只在首次进入 ACTIVE 时调（`world/chunk_manager.gd:680-683`，已修过"每次重网格都调"的坑），且 mesh 提交预算默认 3 块/帧（`scenes/main.gd:302`）。
- 影响：流式加载/飞行时 3 块/帧 × 8192 ≈ 2.4 万次比较/帧 ≈ 0.3-1.5ms（估算，纯整数比较，比 get_block 便宜），可接受但可归零；卸载期若火把总数 200、一次卸 20 块 → 4000 次判断 + 20 次数组拷贝，可忽略。
- 修复方案：A) 维护区块级实体索引 `_by_chunk[coord] = {cell: mi}`，卸载时按块取（O(块内实体数)）；激活扫描可改为"放置时增量登记 + 激活时只补存档恢复的块"（存档恢复场景需要全扫，但只发生一次）。B) 备选：C# 侧已有区块级方块计数/索引（NativeMeshBridge），暴露一个 `get_blocks_of_type(coord, id) -> PackedInt32Array` 直接消费。
- 验证：perf 探针打印单次 `on_chunk_active` 耗时（>1ms 打印），对比修前后飞行帧时间。

##### F14 [P3] lantern_renderer 硬编开发者机器绝对路径

- 位置：`presentation/lantern_renderer.gd:14`、`presentation/lantern_renderer.gd:17-24`
- 证据：
```gdscript
# presentation/lantern_renderer.gd:12-24
## Pastoral 包 assets/minecraft 目录。外部目录（包有自身许可，不入
## 库）；不存在时走程序化回退——游戏不依赖该路径可运行。
const PACK_DIR := "F:/pastoral_inspect/pack/assets/minecraft"

func _build_model() -> Mesh:
	if DirAccess.dir_exists_absolute(PACK_DIR):
		var mesh: ArrayMesh = McModelLoader.build_mesh(
				PACK_DIR, "models/block/lantern.json")
		if mesh != null and mesh.get_surface_count() > 0:
			_apply_glow(mesh)
			return mesh
	return _fallback_model()
```
- 根因：路径写死在常量里，注释已承认是外部目录不回库；但没有可配置入口（环境变量/用户配置/项目设置），因此任何其他机器（包括队友、CI、打包用户）都只能走程序化回退。
- 影响：无崩溃；但"提灯长什么样"取决于开发机 F: 盘是否存在，截图/验收/多人协作结果不一致，且回退模型与包模型观感差异大（`:3-5` 注释说比例对齐过）。
- 修复方案：A) 改为 `OS.get_environment("YAOHAI_PACK_DIR")`，为空则 `PACK_DIR_FALLBACK`（程序化）；README 记录该环境变量。B) 或把包内必要的 2-3 个模型文件按许可单独放 `res://assets/pack/` 并随仓库分发（需确认许可允许）。
- 验证：不设环境变量启动 → 回退模型（无报错）；设置后 → 与开发者截图一致。

##### F15 [P3] drop_visuals 两个 mesh 生成器共用同一个 block_id 缓存字典（当前调用路径互斥，属定时炸弹）

- 位置：`presentation/drop_visuals.gd:22`、`presentation/drop_visuals.gd:40-41`、`presentation/drop_visuals.gd:90-92`、`presentation/drop_visuals.gd:145`、调用方 `items/drop_manager.gd:352-364`
- 证据：
```gdscript
# presentation/drop_visuals.gd:22
static var _cube_mesh_cache := {}   # block_id -> ArrayMesh
# :90-92
static func torch_mesh_for(block_id: int, registry: VoxelRegistry) -> ArrayMesh:
	if _cube_mesh_cache.has(block_id):
		return _cube_mesh_cache[block_id]
	...
# :145
	_cube_mesh_cache[block_id] = mesh
```
```gdscript
# items/drop_manager.gd:357-361
			if world.registry.definition_for_id(block_id).get(
					"render_type", "") == "cross":
				model.mesh = DropVisuals.torch_mesh_for(block_id, world.registry)
			else:
				model.mesh = DropVisuals.cube_mesh_for(block_id, world.registry)
```
- 根因：`torch_mesh_for` 读写的是 `cube_mesh_for` 的缓存键空间，两个函数对同一个 `block_id` 返回不同网格却共享 key；当前唯一调用方按 `render_type=="cross"` 二选一（互斥），所以现在不会错。任何人将来给手持物品/背包 3D 预览对同一 id 调 `cube_mesh_for`（或火把改为可放置的整块变体）就会拿到错误网格，且是缓存级污染（`configure()` 才清）。
- 影响：当前无 bug；属"下一次改动就炸"的隐性契约。
- 修复方案：A) 拆成 `_torch_mesh_cache` 独立字典（2 行）。B) 或在 `torch_mesh_for` 里改用复合 key（如 `block_id | (1<<24)` 或字符串前缀 `"torch:%d"`）。
- 验证：`tests/test_drops.gd` 已对 cube/extruded 有断言；加一条"先 cube_mesh_for(torch_id) 再 torch_mesh_for(torch_id) 返回不同/正确网格"的用例（修前会失败）。

##### F16 [P3] tile_grid 用 assert 守卫未知 tile（release 剥离）→ 拼错 tile 名静默返回 (-1,0)

- 位置：`presentation/texture_atlas_loader.gd:53-57`
- 证据：
```gdscript
# presentation/texture_atlas_loader.gd:53-57
static func tile_grid(tile_name: String) -> Vector2i:
	var index := TILES.find(tile_name)
	assert(index >= 0, "未知图集 tile: %s" % tile_name)
	@warning_ignore("integer_division")
	return Vector2i(index % COLS, index / COLS)
```
- 根因：`assert` 只在 debug 构建有效；release/导出版里未知 tile 返回 `Vector2i(-1, 0)`（GDScript 整数除法 -1/16 = 0），调用方（`drop_visuals.gd:55`、`item_icons.gd:78`、`mc_model_loader`）会拿着负 UV 去采样图集：图集纹理若开了 repeat 会绕到另一侧 tile，否则钳到边缘 → 静默错纹理而不是报错。
- 影响：材质包/注册表里 tile 名笔误在开发期被 assert 挡住，但在 release 里变成"某些方块贴图错位"，且难定位（不会崩、不会打印）。
- 修复方案：A) 改为 `if index < 0: push_error("未知图集 tile: %s" % tile_name); return Vector2i.ZERO`（同时保留 assert 便于 debug 中断）。B) 更彻底：加一个启动期一致性测试遍历 registry 全部 tile 名并断言存在于 TILES（低成本，能一次抓全）。
- 验证：单测传入 `"not_a_tile"`，断言返回 (0,0) 且 push_error 计数 +1；再加 registry↔TILES 一致性测试。

#### 已核查无问题的风险点

1. `presentation/chunk_renderer.gd:53-184`：RID 生命周期完整——register 时 `instance_create`/`body_create`，`remove_chunk`（:171-184）释放 `inst`/`water_inst`/body 并 erase 表项，`_exit_tree`（:82-84）遍历 `keys()` 副本逐个 remove；水层懒建、先切 base 再断旧引用（:132-137）。无泄漏。
2. `presentation/water_surface.gdshader:185-215` + `presentation/water_reflection.gd:87-101`：反射采样几何自洽——镜像基向量 y 翻转、x 取反补右手性，shader 端 `1.0 - SCREEN_UV.x` 补偿；波法线扰动按 `0.3 / max(cam_dist, 6.0)` 归一（远岸不飘）；`h_gate` 只拦高处流水（`smoothstep(0.6, 1.5, |Δy|)`）保留凹坑低水位反射。与注释描述一致，非 bug。
3. `presentation/ocean_waves.gd:61-98` vs `presentation/water_surface.gdshader:64-101`：CPU/GPU 13 迭代常数逐项一致（FREQ 6.0 / SPEED 2.0 / WEIGHT 0.8 / ×1.18 / ×1.07 / 12° / DRAG 0.048 / XZ_SCALE 0.10 / TIME_MULT 0.9），`u_time` 由 main 单源推进（`scenes/main.gd:315-321`），浮物波高与水面视觉同源成立。
4. `scenes/main.gd:311-333 / 404-444`：每帧 uniform 写入已优化——水 2 次 + `u_day` 5 次 + 风摆 2 次 + 太阳方向 2 次 ≈ 11 次/帧，且材质表首帧惰性收集（避免每帧字面量数组分配）。可忽略，非性能点。
5. `presentation/texture_atlas_loader.gd:69-97`：图集 RGBA8 + `packed.convert(image.get_format())` + `blit_rect` 格式统一，树叶镂空 alpha 保留（曾因 RGB8 丢失 alpha 出过坑，已修）。
6. `presentation/mc_model_loader.gd`（209 行）：面绕序 0,2,1 / 0,3,2 与 `block_entity_renderer.gd:113-114` 的约定一致；竖向多帧贴图裁第一帧；缺贴图 MAGENTA 暴露策略与 §11.2 一致。每次 build 新建材质但每个渲染器只 setup 一次，无重复创建。
7. `systems/sound/acoustic_system.gd:63-119`（Amanatides-Woo DDA，10 次不透明累计）+ `:130-132`（`exp(-occ*1.35)^0.1`）+ `:142-182`（512 格 BFS 上限，0.5s 一次；`pop_front` 的 O(n²) 在 512 上限下约 131k 次元素移动 ≈ 0.3-1ms，可接受）。
8. `systems/sound/ambient_system.gd:100-107 / 200-243`：1Hz 一次 625 格近场扫描 + 头顶 32 格，成本 ≈0.3-0.8ms/s；`:307-320` Ogg 字节加载且失败缓存 null，无重复 IO。无问题。
9. `systems/sound/footstep_system.gd:90-135`：涉水判定在 `on_floor` 早退之前（水里也能触发踩水声），入水/出水边沿 splash、步距 `STRIDE_WALK 1.9 / SPRINT 2.4 / WADE 2.6`、`LAND_MIN_FALL 3.0` 逻辑完整；合成音每族 4 变体只在启动时跑一次。无问题。
10. `systems/lighting/cave_fog.gd:213-227`：`_apply` 复用 6 个常驻 FogVolume + ShaderMaterial（只改 size/position/visible/参数），无节点或材质泄漏；扫描结果只在队列清空时 apply，无部分更新。
11. `systems/lighting/light_manager.gd`（268 行）：距离裁剪（滞回 10%）+ 阴影预算（默认 2）+ 确定性排序实现完整、`_evaluate` 0.25s 或增删时全表 O(n log n) 合理；但**未被接线**（全仓无实例，仅 `tests/test_light_manager.gd`、`debug/light_integration.gd`、`debug/light_bench.gd` 引用，`scenes/main.gd` 无 LightManager）。属阶段 1 待接基建，非运行时风险。
12. `presentation/torch_renderer.gd:27-35`：全场火把同相闪烁是注释明说的取舍（"逐支相位偏移需逐实例 uniform，暂略"），`set_exposure` 反除曝光（:21-22）逻辑正确，非 bug。
13. `characters/character_surface.gdshader:22-48`：GPU 蒙皮 `texelFetch` RGBA32F 20×3 双骨采样，权重/索引有边界处理；角色不在本审查范围，只确认与水/镜像 pass 无冲突。
14. `presentation/block_entity_renderer.gd:101-105`：`_despawn` 先 `queue_free` 再 `erase`（帧末才真正释放，但表项立即移除），`_spawn` 对已存在格做重定位（:86-98）——这两处生命周期正确（幽灵问题只出在 F6 的 deferred 路径）。
15. `presentation/voxel_material_registry.gd:64-74`：`_water_still_texture` 已改用 `load()`（导出安全）+ 64×64 程序化噪点回退，是 F9 应该对齐的正确写法。

#### 覆盖缺口

- **未运行 Godot / 未测帧时间**：F1/F2 的毫秒数是按 `get_block ≈ 0.6-1.5µs`（`world/voxel_world.gd:80-86` 的字典查找+坐标变换）和代码注释自估的 `~0.5ms` 全量重光照推算的；F3/F10 的 GPU 成本只有静态估算，需实机 profiler 定档（F3 若在目标机掉帧应升 P1）。
- `presentation/loading_overlay.gd` 只读到约 300 行（总 330+）：`_draw` 每帧 `_landed.duplicate() + sort_custom(lambda)`（≤64 元素）与 `_draw_voxel` 每次 3 个字面量数组，判断为加载期一次性低风险，未做量化、未逐行审完。
- `presentation/water/sspr_reflection.gd` 只精读 :1-80 与字段/释放逻辑，7 个内嵌 GLSL compute（scatter/resolve/temporal/blur）未逐行审——死代码，投入产出低；若决定复用需另开一轮。
- 范围外未判（仅确认调用点）：`addons/ocean3d_lite/shaders/ocean.gdshader`、`EmacEArtStylizedGrass/Shaders/EA_GrassWind.gdshader`、`debug/*.gdshader`；`world/chunk_manager.gd`、`world/water_flow.gd`、`world/voxel_world.gd` 只读调用链相关段（它们属于其他 part）。
- `items/drop_manager.gd`、`systems/trees/tree_manager.gd` 只读了与 F1/F15 相关的调用点，其内部逻辑未审。
- 未核对 `tests/` 套件是否覆盖 F5（无 native 光照）、F6（幽灵实体）、F9（导出图集）场景；建议把验证方案补成测试用例。

---

### 7.7 part-7 — 工程结构与技术债（tests / debug / addons / docs）

审查者：struct-audit（subagent）｜任务：共享板 task-7｜时间：2026-11-14｜基线：git fb01aea（+ .audit_work 未跟踪）
审查角度：工程结构 / 技术债 / 测试与工具链（不做单系统实现深挖）。范围：tests/*.gd(37)、debug/*（97 个在库 .gd、61 个 .tscn）、addons/*（9 个）、plugins/*、docs/*、README.md、project.godot、.gitignore、voxel-terrain.csproj、以及 scenes/main.gd 与 chunk_manager/tree_manager 的跨层接线。

#### 概览

- 实际精读：README.md、docs/DEVELOPMENT_PLAN.md（§11/§12 逐行，其余标题级）、project.godot、voxel-terrain.csproj、.gitignore、tests/run_all_tests.gd、tests/run_one.gd、tests/test_framework.gd、tests/test_stress_edits.gd、tests/test_generation.gd、tests/test_native_equivalence.gd 等 7 个测试文件、scenes/main.gd（1-59/60-114/150-167/300-447）、world/chunk_manager.gd（1-100/118-177/195-216/440-479/690-799）、systems/trees/tree_manager.gd:1086-1107、debug/capture_lib.gd、debug/perf_tree_bench.gd:145-160、6 个 capture_lod* 脚本骨架比对、native/NativeMesher.cs、native/NativeMesher.Grass.cs、native/NativeTerrain.cs 常量段、meshing/native_mesh_bridge.gd、core/voxel_types.gd、core/world_config.gd、generation/terrain_generator.gd、meshing/chunk_mesher.gd:900-917。
- 统计规模：1259 个跟踪文件；tests 34 套件（静态断言点 1242 个，实测运行 12968 项检查，0 失败，数据来自 lead 会话日志）；addons 9 个仅 4 个在 project.godot 启用；5 个 addon 在自身目录外 0 引用；plugins/blockbench-mcp 独占 328/1259 个跟踪文件。
- 健康度结论：核心系统（区块流式、光照、网格）工程质量高于同规模原型，注释密度高、修复历史（f097e44）有据可查；主要债集中在三处——(1) 测试看似 1.3 万项，但存在「0 断言 PASS」「C# 不可用即 SKIP」的假绿通道，最核心的 C# 生产路径与 512 高垂直流式事实上零覆盖；(2) 写盘失败的 _dormant 兜底没有任何落盘出口，退出即永久丢玩家修改；(3) 仓库混入 ~40% 与游戏无关的第三方工具/候选插件（含 1.8MB 预编译二进制与 .smoke 产物），README 运行段在迁 Windows 后整体失效。

#### 发现

##### F1 [P1] 写盘失败的内存兜底 _dormant 永不落盘：退出即永久丢失玩家修改，且内存无回收上限
- 位置：`world/chunk_manager.gd:711-732`（写入兜底）、`world/chunk_manager.gd:161-171`（save_all 只遍历 world.chunks）、`world/chunk_manager.gd:127-139`（_exit_tree 只 save_all 一次）、`world/chunk_manager.gd:97-98`、`world/chunk_manager.gd:701-708`（唯一消费点 _restore_dormant）
- 证据：
```gdscript
# world/chunk_manager.gd:720-732
	if chunk.data_modified:
		var persisted := true
		if chunk.save_needed:
			# 增量存盘：卸载前把修改写透磁盘（§9.2）
			persisted = save_system != null and save_system.save_chunk(chunk)
		elif save_system != null and not save_system.has_chunk(coord):
			# 无待写标记但磁盘无文件（理论不可达）：兜底写一份
			persisted = save_system.save_chunk(chunk)
		if not persisted:
			# 写盘失败：内存兜底缓存，绝不丢玩家修改（§4.4）
			chunk.state = ChunkState.State.EVICT_PENDING
			_dormant[coord] = chunk
	world.remove_chunk(coord)

# world/chunk_manager.gd:161-166
func save_all(player_state: Dictionary) -> int:
	var saved := 0
	for coord in world.chunks:
		var chunk: ChunkData = world.chunks[coord]
		if chunk.save_needed and save_system.save_chunk(chunk):
			saved += 1

# world/chunk_manager.gd:127-135
func _exit_tree() -> void:
	# 退出保存（§9.2）：先落盘，再等待在途线程结束
	if save_system != null:
		save_all(_current_player_state())
	var ids: Array = []
	ids.append_array(_gen_jobs.keys())
	ids.append_array(_mesh_jobs.keys())
	for task_id in ids:
		WorkerThreadPool.wait_for_task_completion(task_id)
```
- 根因：`_dormant` 的语义是"卸载时写盘失败 → 先留内存、下次加载该列再写回"，但唯一消费点是 `_restore_dormant`（`world/chunk_manager.gd:222-223` 与 `:381-382`，都要求玩家重新走进这一列）。`save_all` 只遍历 `world.chunks`，`_dormant` 里的区块已被 `world.remove_chunk(coord)` 移出，因此自动保存（10s）与退出保存都不会碰它们。
- 影响：磁盘满 / 权限拒绝 / IO 错误时该列玩家修改在本会话退出后**永久丢失**（与 :729 注释"绝不丢玩家修改（§4.4）"的承诺相反）；且只要玩家不再回到该列，`ChunkData`（16³ 方块 + 光照 + 稀疏状态，数百 KB 级/列）常驻内存不回收，持续写盘失败时内存随卸载列增长无上界。
- 修复方案：A) `save_all` 末尾追加对 `_dormant` 的重试（遍历 `_dormant`，`save_chunk` 成功即 erase，失败保留并 `push_error` 记录 coord）；`_exit_tree` 在 `wait_for_task_completion` 循环之后再调一次 `save_all`（此时 worker 已退，无并发写风险），仍失败则把该 chunk 序列化到 `user://saves/world1/recovery/` 备份并 `push_error`。B) `_unload_chunk` 内同步重试 N 次后再放弃；若仍失败，保留 chunk 在 `world.chunks` 并标记 `EVICT_PENDING`（不 `remove_chunk`）以避免丢失，代价是流式语义复杂化。
- 验证：注入一个 `save_chunk` 恒返回 false 的 SaveSystem stub，走到 `_unload_chunk` → 断言 `dormant_count()==1` → 触发 `_exit_tree` → 断言 recovery 文件存在或 `_dormant` 被清空；再重启加载断言该列修改仍在（A 方案下）。

##### F2 [P1] 测试可「零断言 PASS」：C# 生产路径不可用时整套对拍静默 SKIP，全绿退出码 0
- 位置：`tests/run_all_tests.gd:59-67`；`tests/test_framework.gd:19-22`；`tests/test_native_terrain.gd:9-11`；`tests/test_native_equivalence.gd:9-11`；`tests/test_generation.gd:44-46`；`tests/test_stress_edits.gd:82`；`tests/test_character.gd:249/497/548/553`
- 证据：
```gdscript
# tests/run_all_tests.gd:59-64
		total_checks += suite.check_count
		total_failures += suite.failures.size()
		var status := "PASS" if suite.failures.is_empty() else "FAIL"
		print("[%s] %s — %s" % [status, path, suite.summary()])
		if not suite.failures.is_empty():
			failed_suites += 1

# tests/test_framework.gd:19-22
func check(condition: bool, label: String) -> void:
	check_count += 1
	if not condition:
		failures.append(label)

# tests/test_native_equivalence.gd:9-11（test_native_terrain.gd 同构）
	if not NativeMeshBridge.available():
		print("[SKIP] C# 原生网格器不可用，跳过等价测试（纯 GDScript 模式）")
		return

# tests/test_generation.gd:45-46
	else:
		check(true, "C# 不可用：对拍跳过（GD 内部一致性仍覆盖）")

# tests/test_stress_edits.gd:82
	check(true, "并发压力 40 轮无崩溃（worker 与水位 tick 并发）")
```
- 根因：PASS 判定只看 `failures` 不做 `check_count > 0` 下限校验；SKIP 用 `print + return` 表达，不计失败也不计跳过；`check(true, ...)` 恒真占位。README:16-17 明说"网格器与地形生成走 C# 原生路径"，而验证该路径的两个对拍套件在 C# 桥加载失败时**静默通过**。
- 影响：C# 桥/程序集损坏、`NativeMeshBridge.available()` 探测失效、`VOXEL_NO_NATIVE` 误设 —— 这三种最容易在生产发生的故障，在 34 套件里表现为全绿退出码 0（两个套件 0 检查，`test_generation` 的 hash01/TreeAt 对拍退化为恒真）。实测 12968 项检查中 6 处恒真；`test_stress_edits` 只有 3 个静态断言，其中 1 个是恒真。测试的"防回归"价值在最关键的 GD/C# 一致性面上失效。
- 修复方案：A) `run_all_tests.gd` 增加 `if suite.check_count == 0: failed_suites += 1` 并把 status 标为 `VACUOUS`；`test_framework.summary()` 对 0 检查返回 `VACUOUS（0 项检查）`；两个 native 套件在不可用时 `check(false, "C# 不可用（如需纯 GD 模式请设 VOXEL_ALLOW_SKIP=1）")`；把 6 处 `check(true,...)` 换成真实断言（如 stress 用例断言 `manager.in_flight_count()==0` 与 `dormant_count()==0`）。B) 保留 SKIP 语义，但 runner 汇总打印 skip 套件数，CI 增加 `--require-native` 模式把 skip 视为失败。
- 验证：以 `VOXEL_NO_NATIVE=1` 跑全量，期望非零退出并在汇总出现 VACUOUS/SKIP 计数；新增 runner 自测：构造一个 0 检查套件，断言 runner 判 FAIL。

##### F3 [P2] v9 垂直流式与 512 高世界零单元测试覆盖：所有测试 chunks_y∈{1,3}，column_band 永远走 legacy 全列分支
- 位置：`core/world_config.gd:12-17`；`scenes/main.gd:11-12`、`scenes/main.gd:91`；`world/chunk_manager.gd:746-752`、`world/chunk_manager.gd:766-769`；`tests/test_framework.gd:33-41`；`tests/test_generation.gd:9-13`；`tests/test_chunk_manager.gd:58`、`tests/test_meshing.gd:8`、`tests/test_greedy_meshing.gd:9`（均 =1）
- 证据：
```gdscript
# core/world_config.gd:12-17
## 垂直区块数（世界高度 = chunks_y * chunk_size）。默认 3（48 高，
## 老存档/测试语义）；新世界由 main.gd NEW_WORLD_CHUNKS_Y 设 32
## （512 格——v8 大陆尺度需要真实垂直体积，48 高的压扁比让远山
## 成为"平面"）。垂直流式见 chunk_manager（活跃带 = 地表带 ∪
## 碰撞圈玩家带，非全层加载）。
var chunks_y := 3

# scenes/main.gd:11-12
## 新世界的垂直区块数（512 格高；老存档由 meta 恢复其原值）。
const NEW_WORLD_CHUNKS_Y := 32

# world/chunk_manager.gd:747-769
## chunks_y 不超过此值的世界整列加载（48 高老世界/测试语义不变）。
const LEGACY_FULL_COLUMN_LAYERS := 4
...
func column_band(col: Vector2i) -> Vector2i:
	var cy: int = world.config.chunks_y
	if cy <= LEGACY_FULL_COLUMN_LAYERS:
		return Vector2i(0, cy - 1)

# tests/test_generation.gd:9-13
func _make_config() -> WorldConfig:
	var world_config := WorldConfig.new()
	world_config.world_seed = 20241017
	world_config.chunks_y = 3
	return world_config
```
- 根因：测试夹具（`test_framework.make_world` 用 `WorldConfig.new()` 且不设 `chunks_y`；`test_generation` 显式 3；`test_chunk_manager/test_meshing/test_greedy_meshing` 显式 1）全部 ≤ `LEGACY_FULL_COLUMN_LAYERS=4`，`column_band` 直接返回整列 —— v9 的地表带计算（`_surface_band` / `NativeTerrainBridge.column_surface_range` C# 桥）、玩家带、`V_UNLOAD_PAD` 滞回、光照自上而下初始化在测试中一次都没执行。生产新世界是 `chunks_y=32`（512 高、`sea_level=64`）。
- 影响：最新架构特性（fb01aea 仍在迭代植被 + 垂直带）只有实机截图与 debug 探针验证，回归无法被 34 套件暴露；`WorldConfig` 默认值（3）与生产值（32）分叉，任何忘记设置 `chunks_y` 的新夹具/探针都会静默跑 48 高世界（`.audit_work` 里的临时脚本也不会报错）。
- 修复方案：A) `make_world` 增加 `height_chunks: int = 3` 参数；新增 `tests/test_vertical_streaming.gd`：`chunks_y=32` 建 2×2 列，断言 `column_band(col)` 两端在 `[0,31]` 内、带内层数 < 32、`generator.sea_level == 64`、`column_surface_range` 返回的区间与 GD 回退一致（可用 `VOXEL_NO_NATIVE=1` 对拍）。B) 把 `WorldConfig.chunks_y` 默认改 32 并给老测试显式传 3——语义更安全但需改 34 个套件入口，改动面大。
- 验证：新增套件在 `chunks_y=32` 下跑通；人为把 `column_band` 改成恒返回 `(0, cy-1)`，断言必须失败。

##### F4 [P2] 20+ 验收/探针仍在用遗留 SEA_LEVEL=7：512 高世界里 water/shore 定位永远回退到硬编码 (34,34)
- 位置：`debug/capture_lib.gd:37-47`、`debug/capture_lib.gd:50-57`；调用点 `debug/capture_terrain.gd:20/59/69/84/118/127/197`、`debug/capture_grass.gd:36`、`debug/capture_water_flow.gd:23`、`debug/capture_sspr.gd:138`、`debug/capture_torch.gd:116`、`debug/capture_fog.gd:129`、`debug/capture_lantern.gd:125`、`debug/probe_water_edit_cost.gd:60/66`、`tests/test_generation.gd:85/267/269`；真源 `generation/terrain_generator.gd:41-44`、`:169`、`:178-181`
- 证据：
```gdscript
# debug/capture_lib.gd:37-47
## 从出生点向外螺旋找开阔水列（列高 <= SEA_LEVEL - min_depth）。
static func find_water_column(gen, min_depth: int = 2) -> Vector2i:
	var water := Vector2i(34, 34)
	for r in range(1, 40):
		for a in 16:
			var ang := TAU * a / 16.0
			var cx := int(34 + cos(ang) * r * 6.0)
			var cz := int(34 + sin(ang) * r * 6.0)
			if gen.column_height(cx, cz) <= TerrainGenerator.SEA_LEVEL - min_depth:
				return Vector2i(cx, cz)
	return water

# generation/terrain_generator.gd:41-44
## 遗留常量（48 高世界的值）；运行时一律用实例 sea_level（v9 起
## 随世界高度联动：48 高=7 保持老存档逐格一致，新世界 H/8——512
## 高=64，MC 同款）。仅测试（显式 chunks_y=3）与 debug 脚本引用。
const SEA_LEVEL := 7
```
- 根因：生产新世界 `chunks_y=32` → `sea_level = 512/8 = 64`；`find_water_column` 的判据是 `column_height <= 7 - 2 = 5`，在 512 高世界的地表高度分布里几乎不可能成立，函数必然返回默认 `Vector2i(34,34)`；`find_shore_from` 同样用 `> 7` 判陆地，语义错位。`tests/test_generation.gd` 因显式 `chunks_y=3` 恰好成立，所以测试不暴露。
- 影响：所有"水面/反射/涟漪/浅滩"类验收截图（capture_sspr/capture_water_flow/capture_lantern 等 15 个 CaptureLib 使用方 + 若干直属调用点）拍的不是目标地形，视觉基线（团队主要验收手段）可信度受损；`probe_water_edit_cost` 的测量点也可能落在非水列，性能数字失真。这是"文档/代码漂移"里唯一会直接污染验收证据的一条。
- 修复方案：A) `capture_lib` 改用实例字段 `gen.sea_level`（`TerrainGenerator` 一定有该字段，`generation/terrain_generator.gd:169`），即 `if gen.column_height(cx, cz) <= gen.sea_level - min_depth:` 与 `> gen.sea_level`；然后批量替换 20+ 调用点。B) 保留 `TerrainGenerator.SEA_LEVEL` 仅用于 `chunks_y<=4` 的兼容路径，并在 `capture_lib` 加 `assert(gen.sea_level == TerrainGenerator.SEA_LEVEL or gen.config.chunks_y > 4)` 的显式守卫。
- 验证：用 `chunks_y=32` 的 config 调 `CaptureLib.find_water_column(gen)`，打印命中列 `column_height`，断言 `<= gen.sea_level - 2` 且返回值 ≠ `Vector2i(34,34)`（在 40 圈螺旋内应能命中）。

##### F5 [P2] GD/C# 双份实现的方块 ID、纹理序号、生成版本靠人工同步：错位表现为贴图串色/水变实体，且对拍测试可被 SKIP 绕过
- 位置：`native/NativeMesher.cs:732-733`；`native/NativeMesher.Grass.cs:37-39`、`:52-57`；`native/NativeTerrain.cs:22-31`、`:98`、`:148`；GD 真源 `core/voxel_types.gd:14-35`、`generation/terrain_generator.gd:27/31/36/44`、`meshing/native_mesh_bridge.gd:15-28`、`meshing/chunk_mesher.gd:617`
- 证据：
```csharp
// native/NativeMesher.cs:732-733
    private const int AirId = 0;
    private const int WaterId = 14; // 与 VoxelTypes.WATER_ID 一致（写死前已对 voxel_types.gd 核对）

// native/NativeMesher.Grass.cs:37-39、52-57
    const int TallGrassId = 19;          // VoxelTypes.TALL_GRASS_ID
    const int BranchId = 15;             // VoxelTypes.BRANCH_ID（树占位）
    const int LeavesId = 16;             // VoxelTypes.LEAVES_ID
    // grass_blade 的 TILES 序号（native_mesh_bridge.TILE_NAMES 同序）
    const int BladeTileIndex = 18;
    // 草侧面过渡变体序号（TILE_NAMES 同序；GD 侧 tile_grid 同名同号）
    const int GrassSideU0 = 22;
    const int GrassSideU1 = 23;
    const int GrassSideU01 = 24;

// native/NativeTerrain.cs:22-23
    private const int GeneratorVersion = 8;
    private const int DirtLayerDepth = 3;

# core/voxel_types.gd:28-33
const WATER_ID := 14
const BRANCH_ID := 15
const LEAVES_ID := 16
const TORCH_ID := 17
const LANTERN_ID := 18
const TALL_GRASS_ID := 19

# meshing/native_mesh_bridge.gd:15-28（24 项顺序即 C# tile 下标契约）
const TILE_NAMES := [
	"grass_top", "grass_side", "dirt", "stone", "bedrock",
	"log_top", "log_side", "planks", "cobblestone", "bricks",
	"sand", "sandstone", "gravel", "coal_ore", "iron_ore", "leaves",
	"torch",
	"lantern",
	"grass_blade",
	"grass_tuft",
	"flower_poppy",
	"flower_dandelion",
	"grass_side_u0",
	"grass_side_u1",
	"grass_side_u01"
]
```
- 根因：`voxel_types.gd` 是 ID 真源，但 C# 侧为了跨语言性能写死了 AirId/WaterId/植物 ID/草叶 tile 序号；`TILE_NAMES` 的数组顺序在 GD 侧是数据，在 C# 侧是隐式契约（`BladeTileIndex=18`、`GrassSideU0=22` 等直接按序写下标）。`NativeTerrain` 的 GeneratorVersion/DirtLayerDepth 同理。唯一的自动化保险是 `test_native_equivalence`，而它可被 SKIP（见 F2）。
- 影响：在 `voxel_types.gd` 中间插入一个新方块 ID，或在 `TILE_NAMES` 中间插入一个 tile —— 前者让 C# 把新 ID 当别的方块渲染，后者让 C# 全部 tile 下标错位（草叶变石头、水变实体）。这类错误在 C# 可用时能被对拍抓住，但一旦对拍被 SKIP（F2）就无声上线；且位置错误会表现为"贴图串色"这一历史上反复踩过的症状。
- 修复方案：A) 用同一份数据生成两端常量：运行时首次 `prewarm` 时由 GD 通过 bridge 把 `TILE_NAMES` 与关键 ID 推给 C#（C# 侧删除 const，改用注入的 int 字段）；或由构建脚本从 `voxel_types.gd`/`TILE_NAMES` 生成 `VoxelIds.generated.cs`。B) 增加契约测试：断言 `TILE_NAMES.size()==24` 且 C# 暴露 `TileIndex(name)` 与 GD 索引逐一相等；断言 GD `WATER_ID/BRANCH_ID/LEAVES_ID/TALL_GRASS_ID` 与 C# 常量一致（需 C# 暴露 getter）。
- 验证：在 `TILE_NAMES` 末尾加一个 tile 后跑对拍，当前应通过（因为在末尾），在中间插入则必须失败——用测试钉死；人为改 C# `WaterId=15` 后对拍必须失败。

##### F6 [P2] 测试直接操作 ChunkManager 私有任务字典并误用 wait_for_task_completion：每轮刷 ~1300 条引擎 ERROR，真实错误被淹没
- 位置：`tests/test_stress_edits.gd:71-81`；`world/chunk_manager.gd:461-470`（`_poll_jobs` 对 task_id 调 `is_task_completed`）
- 证据：
```gdscript
# tests/test_stress_edits.gd:71-81
	# 全部任务回收（预算限流：逐个 wait + poll 直到在册清空）
	for i in 600:
		if manager.is_idle():
			break
		if manager._mesh_jobs.size() > 0:
			WorkerThreadPool.wait_for_task_completion(
					manager._mesh_jobs.keys()[0])
		elif manager._gen_jobs.size() > 0:
			WorkerThreadPool.wait_for_task_completion(
					manager._gen_jobs.keys()[0])
		manager._poll_jobs()

# world/chunk_manager.gd:461-468
	for task_id in _mesh_jobs.keys():
		if mesh_committed >= mesh_commit_budget \
				or (mesh_committed > 0 and Time.get_ticks_usec() - mesh_t0
						> MESH_COMMIT_BUDGET_USEC):
			break
		if not WorkerThreadPool.is_task_completed(task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(task_id)
```
- 根因：`wait_for_task_completion(task_id)` 完成后该 task id 在引擎内部失效，但测试没有把条目从 `_mesh_jobs/_gen_jobs` 删除；下一轮 `_poll_jobs` 仍对失效 id 调 `WorkerThreadPool.is_task_completed(task_id)` → 每帧刷 `ERROR: Invalid Task ID`。测试仍以 PASS 结束（`is_idle` 终会为真），错误只留在日志里。
- 影响：lead 本次全量日志实测每轮 1265~1401 条 `Invalid Task ID`（worker_thread_pool.cpp:397/408，backtrace `world/chunk_manager.gd:466` ← `tests/test_stress_edits.gd:76/81`），400KB 的测试日志被同一错误淹没，任何新增 SCRIPT ERROR 都会被掩盖；同时暴露 ChunkManager 没有公开的「等待空闲」API，测试只能伸手进私有字典——重构 `_mesh_jobs` 结构会直接弄坏测试。
- 修复方案：A) 测试改为不再直接调 `wait_for_task_completion`，而是 `for i in 600: if manager.is_idle(): break; manager._poll_jobs(); await tree.process_frame`（让 manager 自己提交并清理在册表），并加最长等待时间。B) 更好的重构：`ChunkManager` 增加 `func wait_until_idle(timeout_sec: float) -> bool`（内部 poll + 有界等待，返回是否收敛）公开 API，测试与 debug 脚本统一使用。
- 验证：重跑 `tests/run_all_tests.gd`，对日志 grep `Invalid Task ID` 计数为 0；`test_stress_edits` 仍 PASS 且耗时不变。

##### F7 [P2] 无 CI / 无 lint / 无格式化：12968 项检查没有任何自动准入，测试只能手动跑
- 位置：仓库根（仅 `.gitignore`/`.zcodeignore`/`project.godot`/`README.md`/`voxel-terrain.csproj`，无 `.github/`、无 `.editorconfig`、无 gdlint/gdformat/pre-commit 配置）；`docs/DEVELOPMENT_PLAN.md:426-459`（§11 测试策略全部是人工清单）
- 证据：
```markdown
# docs/DEVELOPMENT_PLAN.md:428-437
### 11.1 单元测试

-   世界坐标与区块坐标互相转换。
-   负坐标取整与边界换算。
-   区块数组索引。
-   固定种子生成确定性。
-   面剔除的正确性。
-   区块边界修改的失效传播。
-   方块修改后数据与网格状态一致。
-   存档往返一致性。

# docs/DEVELOPMENT_PLAN.md:451-458
MVP 通过条件：

-   可以在小型体素世界中行走。
-   可以挖掘和放置方块。
-   区块加载、卸载和边界更新正确。
-   贴图没有明显错位或图集串色。
-   保存后重新启动，玩家改造的世界仍然存在。
-   性能数据可以重复测量。
```
- 根因：项目从原型期一路迭代，验证手段是"跑 tests/run_all_tests.gd + debug 截图 + 人眼"，没有把这两步固化成流水线；`dotnet build` 与 GDScript 解析错误只有在手动跑时才发现（f097e44 的 10 处修复就是证据）。
- 影响：本次审查发现的 P1 里有 2 条（F1 的数据丢失路径、F2 的假绿通道）都不是"能靠再跑一次测试发现"的类型，说明现有验证没有覆盖到故障面；无格式化导致 279 个 .gd + 6 个 .cs 风格不一致（tab/空格、长行），diff 噪声大。
- 修复方案：A) 加 `.github/workflows/test.yml`（windows-latest：setup-dotnet 8 → `dotnet build` → 用 README 记录的 Godot 可执行文件跑 `--headless -s tests/run_all_tests.gd`，非零即红）+ gdtoolkit（`gdlint`/`gdformat`）的 pre-commit hook。B) 若暂不上 CI，至少加 `scripts/check.ps1`（build + 全量测试 + 关键探针）并在 README 写明，作为提交前唯一入口。
- 验证：故意把某个 `check_eq` 的期望值改错，CI 必须变红；gdlint 首跑给出基线问题清单。

##### F8 [P2] 测试运行器无超时、无套件隔离：任一 await 悬挂即 headless 永久卡死，静态缓存跨套件累积
- 位置：`tests/run_all_tests.gd:45-67`；`tests/run_one.gd:7-21`；`meshing/native_mesh_bridge.gd:11-13`（`_tile_cache` 按 registry instance id 只增不减）
- 证据：
```gdscript
# tests/run_all_tests.gd:53-58
	for path in TEST_CASES:
		var suite: VoxelTestCase = load(path).new()
		suite.tree_root = root
		# await 兼容异步套件（test_distant_shell 等 worker 流程）；
		# 同步 run() 返回立即值，await 直接继续
		await suite.run()
```
- 根因：runner 顺序 `await suite.run()`，没有墙钟超时，也没有逐套件进程隔离；Godot 的 `await` 在 worker/信号不回来时会一直挂起，而 runner 只在末尾 `quit()`。
- 影响：任一 worker 卡死（例如 F1/F6 类并发 bug、`tree.process_frame` 等待）会让 headless 永远不退出——CI 上表现为 job 超时，本地表现为"测试跑不完"，而且没有任何断言告诉你是哪套件。34 套件同进程顺序跑，静态状态（`NativeMeshBridge._tile_cache` 按 registry id 增长、`ItemIcons`/`DropVisuals` 静态图集）跨套件累积，顺序依赖/内存增长无法定位。
- 修复方案：A) runner 记录 `start_msec`，用 `Time.get_ticks_msec()` 在每次 `await` 返回后检查单套件 > 60s / 总时 > 600s 则 `push_error` + `quit(2)`；B) 每套件独立进程（`run_one.gd` 已存在），用 PowerShell 循环 34 次并汇总退出码——隔离最彻底，代价是启动开销（每次 ~1s）。
- 验证：临时写一个 `await` 永不返回的套件加进 TEST_CASES，runner 必须在 N 秒内以非零退出而不是挂死。

##### F9 [P2] addons/plugins 死重：约 40% 跟踪文件与游戏无关，含 1.8MB 预编译二进制与 .smoke 构建产物入库
- 位置：`project.godot:21-23`（仅启用 4 个插件）；`addons/bounded_buoyancy/`（102 文件 436KB）、`addons/godot_mcp/`（30 文件 409KB）、`addons/bounded_buoyancy_native/`（6 文件 1790KB，`bin/libbounded_buoyancy.windows...x86_64.dll` 1312KB + `.linux...x86_64.so` 486KB）、`addons/bbmodel-importer/`（14 文件 47KB）、`addons/ocean3d_lite/`（17 文件 25KB）；`plugins/blockbench-mcp/`（git 跟踪 328 文件，含 `.smoke/client.mjs`、`.smoke/render_out.png`、`.smoke/run.log`）
- 证据：
```ini
# project.godot:21-23
[editor_plugins]

enabled=PackedStringArray("res://addons/voxel_registry_dock/plugin.cfg", "res://addons/voxel_light_inspector/plugin.cfg", "res://addons/atlas_preview_dock/plugin.cfg", "res://addons/anim_editor/plugin.cfg")

# git ls-files plugins/blockbench-mcp/.smoke 的输出
plugins/blockbench-mcp/.smoke/client.mjs
plugins/blockbench-mcp/.smoke/render_out.png
plugins/blockbench-mcp/.smoke/run.log
```
- 根因：开发期评审/截图/试装插件时直接放进 res://addons 与 plugins/，没有"这是候选/未启用"的元数据，也没有 .gitignore 规则（`.smoke/`、`bin/` 未覆盖）；plugins/blockbench-mcp 是整包 vendored 的上游 TypeScript 项目（328 个 .ts/.png/.log 等），与 Godot 工程零引用。
- 影响：跟踪文件 1259 中约 497 个（328+102+30+6+14+17）≈ 40% 与游戏运行无关；~1.8MB 跨平台预编译 DLL/SO 入库（供应链与仓库体积风险，README:643 已记 Conquest 不可再分发的教训）；`.smoke/render_out.png`、`.smoke/run.log` 是一次性构建产物，污染 diff 并可能被误当验收证据；grep/审计时噪声大（本文件统计插件引用时 90% 命中都在这些目录内）。
- 修复方案：A) 删除 5 个无引用 addon（bounded_buoyancy 两包、godot_mcp、bbmodel-importer、ocean3d_lite）与 `plugins/blockbench-mcp`（工具移到工作区外或独立 repo）；`.gitignore` 增加 `**/.smoke/`、`addons/**/bin/`、`*.dll`/`*.so` 的例外说明；README 增加 addons 段（启用 4 个、其余候选/许可证状态）。B) 若要保留 bounded_buoyancy 作为候选，移到 `vendor/` 并在 README 标注未启用 + 许可证，二进制改用构建脚本下载（不入库）。
- 验证：`git ls-files | Measure-Object -Line` 从 1259 降到 ~760；headless 启动与全量测试仍通过（需 lead 复跑一次）；`grep -r bounded_buoyancy --include=*.gd --include=*.cs` 结果为 0。

##### F10 [P2] README 运行段整体失效（19 处 ~/godot/godot、首步是已知会卡死的 --import），测试数字与目录结构均已漂移
- 位置：`README.md:13-15`、`README.md:28-40`、`README.md:43-87`、`README.md:462`、`README.md:559-581`、`README.md:586`；`tests/run_all_tests.gd:2-3`、`tests/run_one.gd:1-3`（同样教人先 --import）
- 证据：
```markdown
# README.md:14
原 Linux 的 `~/godot/godot` 路径不可用。**本机禁跑 `--import`**——会卡死；

# README.md:28-34
cd "<本项目目录>"

# 1. 首次运行前导入（生成 .godot 全局类缓存，git 忽略该目录）
~/godot/godot --headless --path . --import

# 2. 单元测试（headless，无需显示环境；退出码 0 = 全部通过）
~/godot/godot --headless --path . -s tests/run_all_tests.gd

# README.md:462
- **验证**：16 套件 11911 项 0 失败（含树系统 29 项单测）；
```
- 根因：工作机从 Linux 迁到 Windows 后只改了引擎版本说明段（:13-15），运行命令段（:25-88，共 19 处 `~/godot/godot`）没改；README:14 自己写"禁跑 --import"，但 :30-31 又把 `--import` 作为第 1 步。测试/套件统计是手写快照，从未与 runner 输出核对（实测 34 套件 12968 项）。
- 影响：新人（或三个月后的自己）按 README 第一步就会触发已知卡死；即使跳过 --import，后续 19 条命令在本机全部不可执行。README:462 的"16 套件 11911 项"会让人低估测试规模、并把已删/新增套件当成覆盖。目录结构段（:559-581）缺 characters/、systems/、addons/、plugins/ 四个真实顶层目录。
- 修复方案：A) 运行段整体替换为当前机器可用的 Windows 命令（`& "C:<path>Godot_v4.7.2-stable_mono_win64.exe" --headless --path . -s tests/run_all_tests.gd`），删除 --import 步骤并改为"首次用编辑器打开一次工程生成 .godot 缓存（本机勿用 CLI --import）"，测试数字改为"以 runner 末尾汇总为准"；B) 保留 Linux 段但标注"2026-10 前有效"，加一句"以下命令在 Windows 机不可用"。
- 验证：`grep -n "~/godot/godot" README.md` 为 0；`grep -n "11911\|16 套件" README.md` 为 0；按新 README 从零跑一遍能进游戏。

##### F11 [P2] 分层破坏：单槽 Callable 生命周期总线 + 组合根直写私有成员 + 树系统每帧轮询 chunk_manager 全量状态
- 位置：`scenes/main.gd:156-159`、`scenes/main.gd:162`；`world/chunk_manager.gd:79-90`（6 个单槽 Callable）；`world/voxel_world.gd:95`；`systems/trees/tree_manager.gd:1093-1099`；`world/chunk_manager.gd:202-209`；`debug/perf_tree_bench.gd:152-153`
- 证据：
```gdscript
# scenes/main.gd:152-162
	# 主干动画倒伏倒向砍树的人（DT 语义）
	tree_manager.player_provider = func() -> Node3D:
		return player
	# 光照脏重烘等区块管线空闲（光照传播异步落定）再执行
	tree_manager.idle_check = func() -> bool:
		return chunk_manager.is_idle()
	# 玩家编辑区块插队重网格（放置/挖掘即时反馈）
	world.edit_dirty_cb = chunk_manager._on_player_edit
	# 掉落物撞得上树干：掉落走体素碰撞感知不到树 StaticBody，
	# 主干实心由树管理器实时查询补齐（枝干无碰撞，与玩家一致）
	drop_manager.trunk_solid_probe = tree_manager.is_solid_for_items

# world/chunk_manager.gd:202-209
## 流式是否已安定（无在途任务且无脏区块）——调试与冒烟测试用。
func is_idle() -> bool:
	if in_flight_count() > 0:
		return false
	for coord in world.chunks:
		var chunk: ChunkData = world.chunks[coord]
		if chunk.mesh_dirty or chunk.collision_dirty:
			return false
	return true

# debug/perf_tree_bench.gd:152-153
		main_ref.chunk_manager.on_chunk_active_cb = Callable()
		main_ref.chunk_manager.on_chunk_unloaded_cb = Callable()
```
- 根因：系统间契约用单个 `Callable` 字段而非信号/监听器列表，第二个订阅者赋值即覆盖第一个且无声；`main.gd` 作为组合根直接写 `world.edit_dirty_cb = chunk_manager._on_player_edit`（下划线私有方法）与清空回调字段，破坏封装；树系统用"每帧轮询 `chunk_manager.is_idle()`"来等待流式空闲，让上层子系统反向依赖下层的内部状态遍历。
- 影响：多消费者场景（第二个视觉/音效系统想监听 chunk 激活、未来插件）会被静默覆盖——`perf_tree_bench.gd:152-153` 就是现成示例（清空后树系统收不到任何 chunk 生命周期）；`main.gd:159` 一旦 chunk_manager 重命名 `_on_player_edit`，编译期无感、运行期才炸；`is_idle()` 在 `view_distance=16` 下遍历约 800 列 × 带内数层的 `world.chunks`（数千个 chunk，GDScript dict 迭代 ~0.3µs/项 → 最坏 ~1-3ms/帧），树首建等待期（`_build_pending` 非空）每帧调用一次，属于可避免的周期成本。
- 修复方案：A) 把 `on_chunk_active_cb/on_chunk_unloaded_cb` 改为 `signal chunk_activated(coord)` / `signal chunk_unloaded(coord)`（GD 信号天然支持多订阅），`main.gd` 改为 `chunk_manager.chunk_activated.connect(...)`；`edit_dirty_cb` 用公开 setter `chunk_manager.set_edit_handler(callable)`；树系统改由 chunk_manager 在 `is_idle` 状态翻转时 `emit signal pipeline_idle`，或维护 `_dirty_count` 让 `is_idle()` 变 O(1)。B) 保留单槽 Callable，但赋值处加 `assert(not cb.is_valid(), "已有订阅者：%s" % cb)`，把静默覆盖变成启动期崩溃。
- 验证：写一个同时注册两个 chunk 激活监听者的临时场景，两者都收到；把 `is_idle` 改 O(1) 后用 debug 探针对比树首建期间帧耗时（应降至噪声级）。

##### F12 [P2] debug 归档纪律再次被破坏：6 份 capture_lod* 近似副本留在顶层，capture_shadow16 未归档，跨层直读私有字段
- 位置：`debug/capture_lod.gd`(99 行)、`debug/capture_lod2.gd`(111)、`debug/capture_lod3.gd`(128)、`debug/capture_lod4.gd`(119)、`debug/capture_lod_bay.gd`(88)、`debug/capture_lod_scan.gd`(110)；`debug/capture_shadow16.gd`（`debug/archive/` 已收 capture_shadow2..15 共 15 份）；跨层点 `debug/capture_lod3.gd:51`、`:85`、`:91`
- 证据：
```gdscript
# debug/capture_lib.gd:1-6
## debug 验收场景公共库——杜绝整文件复制脚手架（capture_shadow2..16
## 共 16 份近似副本 ~1600 行就是教训）。新验收场景只写差异部分：
##
##   var main := CaptureLib.boot_isolated(self, "my_test")
##   ... await/等 main._loading == false ...
##   CaptureLib.shoot("debug/xxx_v1.png")

# debug/capture_lod3.gd:51、85（直读私有状态）
	main_ref.distant_shell._center
	var entries: Dictionary = cr._entries
```
- 根因：LOD 观感调试是"每轮加一个脚本快速改机位"的工作方式（同 capture_shadow 时期），改动集中在 `_phase` 状态机与机位，公共部分（VSYNC 关闭、窗口 1280x720、`CaptureLib.boot_isolated`、240~300s TIMEOUT、`SHOT_TAG`）仍逐文件复制；README:594 的纪律（"验收脚本不复制：新视觉验收用 debug/capture_lib.gd"）只写进文档没写进流程。
- 影响：6 份合计 655 行，两两相同非空行 27~49 行（lod vs lod2 49/99、lod vs lod4 45/99、lod3 vs lod4 39/128），改窗口尺寸/超时/路径要改 6 次且容易漏；19 个 debug .gd 各自重复 window/vsync 设置（grep 计数 19 文件，仅 15 个用 CaptureLib）；`capture_lod3.gd:85` 直接读 `cr._entries`、`:51` 读 `distant_shell._center`，distant_shell 重构即断（编译期无感）。`capture_shadow16` 未归档使 archive 与顶层的界线失效。
- 修复方案：A) 合并为 `debug/capture_lod.gd`，用用户参数分模式（`-- --mode=lod2|bay|scan`，仓库已有 `--greedy` 的用户参数机制先例），删除 5 个脚本与对应 tscn；`capture_shadow16` 移入 `debug/archive/`；把窗口/vsync/超时状态机抽进 `CaptureLib.boot_isolated`（可选参数：窗口尺寸、超时秒数）。B) 保留独立文件但改成"每文件 < 30 行、只含机位与断言"，其余一律调 CaptureLib。
- 验证：合并后用 6 个 mode 各截一张图，与原脚本同机位截图做逐像素 hash 对比一致；`grep -rl "VSYNC_DISABLED" debug/` 命中 ≤ 1 个文件（capture_lib.gd）；`debug/archive` 之外的 capture_shadow* 为 0 个。

##### F13 [P3] 每帧仍有 2 处字面量数组分配，与 main.gd 自己的修复注释矛盾
- 位置：`scenes/main.gd:317-321`、`scenes/main.gd:437-440`；对照 `scenes/main.gd:404-413` 的注释
- 证据：
```gdscript
# scenes/main.gd:404-406
	# u_day 下发（地形双 shader + cross 双面变体 + 水双 shader + 树表面；
	# 脏检查省自然达成——每帧都在变，过渡期外 day 稳定值重发成本可忽略）
	# 材质表首帧惰性收集（每帧字面量数组分配曾是隐性 GC 压力）

# scenes/main.gd:317-321（每帧 new 一个 2 元素 Array）
	if chunk_renderer != null:
		var storm := OceanWavesScript.storm_scale
		for mat in [chunk_renderer.water_material, chunk_renderer.water_side_material]:
			if mat != null:
				mat.set_shader_parameter("u_time", _wave_clock)

# scenes/main.gd:437-440
	# 水面反射的太阳方向（day/night 方位不同，随光重发）
	var sun_dir: Vector3 = -_sun.global_transform.basis.z.normalized()
	for mat in [chunk_renderer.water_material, chunk_renderer.water_side_material]:
		mat.set_shader_parameter("sun_direction", sun_dir)
```
- 根因：`_u_day_mats`/`_wind_mats` 已改惰性缓存（:407-424），但水材质的这两处循环仍每次迭代新建数组字面量。
- 影响：约 2 个数组/帧 ≈ 120 个/秒（约 6KB/s 垃圾），对 GC 影响可忽略，属技术债与"注释承诺已修但实际残留"的误导；review 时容易被当成已解决问题。
- 修复方案：A) 与 `_u_day_mats` 同法缓存 `var _water_mats: Array = []`（首帧收集两个水材质）；B) 直接写两个具名的 `if mat:` 分支（可读性更好，代价是重复三行）。
- 验证：性能探针看 GC 峰值/帧时间无可测量差异即为合格；代码审查确认 `_process` 内无 `for ... in [` 字面量。

##### F14 [P3] 输入键位全部硬编码在 player_controller，project.godot 无 [input]：不可重映射、无手柄、键位冲突无处统一
- 位置：`player/player_controller.gd:211-231`、`:245-251`、`:275`、`:297-301`；`project.godot`（无 `[input]` 段）
- 证据：
```gdscript
# player/player_controller.gd:211-217（示例段）
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_E:
				_toggle_inventory()
			KEY_Q:
				_drop_selected()
```
- 根因：原型期直接读 `InputEventKey.keycode` 完成交互，没有抽出 InputMap 动作（`project.godot` 27 行里无 `[input]`），键码常量散落在控制器 4 段代码中（移动、交互、Shift 疾跑、F5/F6/F7 调试键）。
- 影响：无法提供键位设置 UI；重绑/手柄支持要改代码；`KEY_ESCAPE` 退出与编辑器/系统快捷键、F5/F6/F7 与编辑器运行快捷键存在潜在冲突；测试无法注入动作层输入（只能伪造 InputEventKey），交互测试与键位实现耦合。
- 修复方案：A) `project.godot` 增加 `[input]` 动作（move_forward/move_back/move_left/move_right/jump/sprint/interact/drop/inventory/pause），控制器改用 `Input.is_action_pressed("move_forward")`；B) 短期把键码收敛到一个 `const KEYMAP := {...}` 表并加注释，先消掉散落。
- 验证：修改 `project.godot` 的键位后游戏内立即生效且无需改代码；交互测试用 `Input.action_press("interact")` 可通过。

#### 已核查无问题的风险点

- `meshing/chunk_mesher.gd:911-917` `water_surface_height(level)` 是水面高度唯一来源（源水 0.875、流动逐级、8 级满格），`scenes/main.gd:698` 反射平面据此推导——符合 README:588-590 的"单一来源"纪律。
- `world/chunk_manager.gd:49-56` `EDIT_BYPASS_IN_FLIGHT=2` + `MESH_COMMIT_BUDGET_USEC=8000` 双预算（数量+时间任一到达即停）与 `:443-473` 实现自洽，确实能防"3 个重提交叠一帧 30-90ms"（注释记录了实测）。
- `world/chunk_manager.gd:24-39` `view_distance`/`collision_radius`/`unload_padding`/`max_in_flight` 均为 `@export` 且 `view_distance` 的 setter 清空 `_sorted_columns`（:27-30），运行时改视距不会留陈缓存。
- `world/chunk_manager.gd:766-776` `column_band` 对 legacy/新世界分支清晰，两端 clamp 到 `[0, chunks_y-1]`，玩家带与地表带取并集保证连续（光照自上而下依赖，注释说明充分）。
- `systems/trees/tree_manager.gd:1091-1099` 树首建等待有 2s 兜底（`idle_check` 无效时降为 0.15s），不会因流式永不空闲而饿死。
- `.gitignore` 对大件产物有效：debug/ 磁盘 2537 文件 741.4MB（png 908/log 318），git 跟踪的 debug 文件里 png/log 均为 0（`git ls-files debug` 只有 .uid/.gd/.tscn/.gdshader/.md/.py）。
- `project.godot:15` `config/features=PackedStringArray("4.7","C#")` 与 `voxel-terrain.csproj` 的 `Godot.NET.Sdk/4.7.2` + `net8.0` + `RollForward=LatestMajor` 一致，无版本错配。
- `tests/test_framework.gd:25-28` `check_eq` 失败消息包含期望/实际（`"%s — 期望 %s，实际 %s"`），失败可定位，不是裸 bool。
- `tests/run_all_tests.gd:63-66` 失败套件计数与 `quit(1 if failed_suites > 0 else 0)` 在"确有失败"时行为正确（问题只在 0 断言/跳过路径，见 F2）。
- `scenes/main.gd:407-434` 材质表惰性收集 + 雾色取 `sky_horizon_color`（注释记录了曾用独立常量导致"远处发光"、PIL 实测山 25 > 天 19），当前实现与注释一致。
- `world/voxel_world.gd:16` 游戏代码只有一个 `signal block_changed(pos, old_id, new_id)`，信号扇出面可控（其余系统间通信用 Callable，问题见 F11）。
- `debug/capture_lib.gd:11-57` 的 `boot_isolated`/`shoot`/`fps_summary`/`find_water_column`/`find_shore_from` 确实被 15 个 debug 脚本复用，方向正确（残留重复见 F12、错 sea level 见 F4）。
- `meshing/native_mesh_bridge.gd:11-13` tile 表按 `registry.get_instance_id()` 缓存（`_tile_cache`），避免每 chunk 重建；生产只有一个 registry，无实质泄漏。

#### 覆盖缺口

- `docs/DEVELOPMENT_PLAN.md` 只逐行读了 §11-§12（测试策略/阶段计划）并 grep 了全部标题，§1-§10、§13-§15 未细读；`docs/reference-chisels-and-bits.md`、`docs/reference-dynamic-trees.md`、`docs/character-system.md` 未读。
- 按任务分工未深挖单系统实现：`presentation/water/sspr_reflection.gd`(780 行)、`characters/player_avatar.gd`(630)、`items/*`、`systems/lighting/voxel_light.gd`(496)、`systems/trees/tree_mesh_builder.gd`(607) 只看了接线与调用关系。
- `addons/*` 只做引用/体积/启用状态统计，未逐个读实现（godot_mcp、bounded_buoyancy 内部代码质量与许可证未评）。
- `plugins/blockbench-mcp` 未逐文件读（只统计了 328 个跟踪文件与 `.smoke/` 产物）。
- 未实跑任何 Godot 进程（任务禁止）：12968 项/0 失败、`Invalid Task ID` 1265-1401 条、退出时 1 个 `DummyMesh` RID 泄漏均引自 lead 会话日志与 `.audit_work/tests.log` 的记载，未独立复现。
- 未验证 512 高世界的运行时行为：F3/F4 的结论基于代码分支推断（`sea_level_for`、`column_band`、`find_water_column` 的常量比较），未在实际 `chunks_y=32` 世界里跑探针确认。
- 未运行 `dotnet build` / 未做 C# 侧静态检查（按任务要求避免构建竞争），F5 的跨语言一致性只做了常量文本比对。
- `debug/` 741MB 磁盘产物只看扩展名分布与少量 capture 脚本，未抽查截图质量；`.audit_work` 目录（含 lead 的 181MB godot.exe 与日志）属审查工作区，未纳入仓库评价。
- 未评估 `assets/` 24MB ogg 音频与 1022 张 png 的许可证/压缩策略（属资源审查，另 part 覆盖）。

---

## 八、附录

### A. 复现命令

```powershell
# 全量单元测试（需先把 Godot exe 复制进 workspace 并指向可写 APPDATA）
$env:APPDATA = "<workspace>/.audit_work/appdata"
& "<workspace>/.audit_work/godot.exe" --headless --path . -s tests/run_all_tests.gd --log-file .audit_work/tests.log
# 检查日志（任一命中即说明有问题）：
Select-String -Path .audit_work/tests.log -Pattern "\[FAIL\]|Invalid Task ID|leaked|this will not work on export"
```

### B. 审查方法与局限

- 每个模块由独立审查者逐文件 read 到行级；每条发现在报告中给出位置、原文证据、根因、影响、修复方案 A/B 与验证点；标 `[待验证]` 的条目为静态推导、未动态证实。
- 性能数字除测试内 `[perf]` 埋点实测外，均为代码量级估算，需真机 profile 复核后再做优化决策。
- 本次审查未修改任何源码/测试/配置，唯一新增文件是本文档。

### C. 交叉印证的重复条目

| 条目 | 重复出现 | 说明 |
| --- | --- | --- |
| `_dormant` 永不落盘 | part-1 F2 = part-7 F1 | 同一根因的实现细节视角与结构视角 |
| 图集 `Image.load_from_file` | part-6 F9 = 本文档 L1 | 静态发现 + lead 用测试日志 69 条 WARNING 实证 |
| `test_stress_edits` 误用 | part-7 F6 = 本文档 L2 | 静态发现 + lead 实测 1265~1401 条 ERROR |
| 光照重算尖刺 | part-6 F2 / 本文档 L3 / part-3 F3 砍树路径 | 同一「逐格写入 → 全量光照」模式的不同入口 |
| 测试假绿 | part-7 F2 与本文档 L4 | 同一可信度问题的两个表现 |
