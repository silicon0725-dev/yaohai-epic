# C# 体素沙盒开源项目对比调研（2026-11-14）

调研背景：对比 6 个指定 C# 体素沙盒项目 + GitHub 追加侦察 7 个，与瑶海 EPIC（Godot 4.7.2 mono，GDScript+C# 混合）逐项对照。全部结论来自 gh api 元数据 + tarball/文件树实际精读，来源标注在文中。

自家基线（盘点实测）：自研 211 个 .gd（38,250 行）+ 4 个 .cs（2,474 行）；vendor 插件 26,565 行；34 测试套件约 12,971 项；98 个 debug 验收脚本；16³ 区块 / 无限 XZ + 垂直 512 高流式 / 视距 16 + 三级远景壳 4096 格。

---

## 一、六个指定项目档案

### 1. japsuu/Korpi — 数据层教科书，玩法空壳（⚠ 不是 Godot）

| 项 | 值 |
|---|---|
| Stars/状态 | 20★ / 2024-05-20 起停更约 18 个月 |
| 技术栈 | 自研 KorpiEngine + OpenTK 4.8.2 (OpenGL 4.2) + ImGui.NET，.NET 6 |
| 规模 | 315 .cs / 37,638 行（含 vendored LiteNetLib 1.4 万行；引擎自体约 6.4k + 客户端 7k） |
| 世界 | 32×512×32 列式（16 个 32³ 子块）；曾用 cubic chunks 后主动改回列式（决策文档 `docs/technical/data-management/world-chunking.md`） |
| License | 自定义 Shared Source，**禁止商用——学设计，忌抄代码** |

- 网格：naive 面剔除（非 greedy）；`ThreadLocal<ChunkMesher>` 零分配；**MeshingDataCache 邻域快照免锁**（拷 34³ 邻域后全程无锁）。
- 顶点：**每顶点 2×uint 共 56bit 位打包**（位置存局部索引 18bit + 纹理 12bit + 光照 14bit + 法线 3bit + AO 2bit），shader 解包（`MeshingBuffer.cs:280-330` + `blocks_common.vert`）。
- 存储：**Palette + BitBuffer 调色板压缩**（Minecraft 1.13 式，1bit/格起步倍增），Flat/Layered/Palette 三策略按 chunk 熵自动选择，全套单测。
- 线程：四级优先级工作队列；**Job-ID 防孤儿**（chunk 记 `CurrentJobId`，过期任务比对即弃）；主线程节流队列（每 tick ≤64 回调）防 mesh 上传风暴。
- 加载：螺旋预计算顺序 + 每 tick 加载/卸载上限，卸载半径=加载+2。
- 地形：FastNoiseLite vendored；3D 密度 + **4×4×4 brick 角点采样三线性插值**（非逐格）；DEBUG 下 ImGui 实时热调参。
- **没有**：光照传播（预留未实现）、流体、存档序列化、物品/背包/生物/音效、greedy、LOD。服务器是 TODO 骨架。
- 测试：NUnit 覆盖 BitBuffer/三种 BlockStorage/Heightmap；三 OS 矩阵 CI + docfx 文档站。

### 2. wieslawsoltes/Minecraftonia — 已归档的 CPU 光追实验

| 项 | 值 |
|---|---|
| Stars/状态 | 92★ / **已归档**（2025-09 创建，仅存活 7 周） |
| 技术栈 | 自研 CPU 软件光追 + Avalonia UI，.NET 9 |
| 规模 | 98 .cs / 12,963 行，拆 13 个 NuGet 包 |
| License | MIT |

- 无网格生成：每像素 DDA 光线步进，360×202 内部分辨率，`Parallel.For` 行级并行。固定小世界 96×48×96，8 种方块，整世界 JSON 存档。
- 独特点：**3D Wave Function Collapse 地形**（8×H×8 体素 tile 拼接）+ **MarkovJunior 规则引擎生成聚落建筑** + **OSM Overpass 真实地理高程导入**；可选软件 GI（次级反弹）。
- 价值：库拆分工程化范例（README 每包用法段）；程序化生成三件套思路。渲染路线与做"游戏"不同向。

### 3. eric-patton/ra-engine — 唯一同为 Godot 的直接可比项目

| 项 | 值 |
|---|---|
| Stars/状态 | 0★ / 2026-08-30（约 2.5 个月开发期） |
| 技术栈 | **Godot 4.6.3 Mono**，Forward+，net8.0 |
| 规模 | 70 .cs / 16,063 行 + README 352 行 + docs 3 篇 |
| License | MIT |

定位：课堂教学用块世界沙盒（圣经/历史课程 JSON 数据驱动），完成度可玩。
- 网格：**greedy meshing + AO-uniform 才合并**（共面且四角 AO 一致才合并，有梯度回退 1×1；水面按 flow 通道匹配合并）——`ChunkMesher.cs:96-119,192-275`，注释含数学依据。
- 多线程：**Capture(主线程快照 18³)/BuildData(工作线程纯 struct 零 Godot 对象)/Apply(主线程上传)** 三步流水线；`MeshVersion` 版本号丢弃过期网格。
- 存储：RWLD 二进制 + 方块名调色板（注册表变更兼容）+ 每 chunk RLE + 原子写。
- 水：**确定性洪水填充**——按 Y 优先队列、每 WaterStepSeconds 推进 N 格（帧率无关、最终态确定，注释明言可直接复制到多人服务器）。
- **没有**：体素光照传播（AO+动态点光撑）、流体渲染细分、CI、正式测试框架（30 个 `--test-*` headless 自测模式替代）。`Game.cs` 单文件 2,218 行。

### 4. sbarisic/RaylibGame（Aurora Falls / Voxelgine）— 多人网络与性能工程标杆

| 项 | 值 |
|---|---|
| Stars/状态 | 5★ / 2026-09-05（2020 年起近 6 年演化） |
| 技术栈 | 自研 FishGfx(OpenGL)（Raylib 已弃用），net10，Windows-only 客户端 |
| 规模 | 411 .cs / 约 7 万行 + 5 个测试项目；仓库 374MB 含 submodule |
| 世界 | **有限规划世界**（WorldPlan 默认 1024×1024×64） |
| License | MIT |

- 光照：天光+方块光 BFS；**预分配环形队列 + 代次戳 visited（免清零）+ 每列 16×16 SkyExposureCache**；最多 32 点光源边界扫描缓冲（`Chunk.Lighting.cs`）。
- Meshing：默认 culled，greedy（同纹理+uniform 光照/AO 才合并）opt-in 未默认启用；均匀实心 chunk 9,216→36 顶点。
- 存储：**列级独立 Deflate 压缩归档，未变列原样复用压缩块只重编码修订列**；不兼容归档自动备份再再生。
- 多人（最完整）：UDP+协议 2，**P-256 持久身份 + 全 datagram 认证 + 服务器密钥 pin**；客户端预测/和解/插值、可靠通道、分片、批处理、带宽跟踪（Engine/Net/ 30+ 文件）；流式核心 32 格 + 16 格 halo + 16 列在途上限。
- 性能框架：**2ms/512 单位可恢复列事务、光照 2ms、网格上传 1ms 预算**；dirty chunk 按列索引+相机范围调度 0.41→0.004ms；基准套件入库 + 变更说明带前后测量表 + **被否决的优化也记录原因**（`docs/VOXEL_PERFORMANCE.md`）。
- **没有**：流体模拟（静态水贴图）、无限世界、每 PR CI（仅 tag release 流水线）。

### 5. HilthonTT/Minecraft — 玩法完整度与文档质量标杆（活跃）

| 项 | 值 |
|---|---|
| Stars/状态 | 0★ / 2026-11-07（一周前，活跃开发） |
| 技术栈 | OpenTK + OpenGL 4.0 自写 GLSL，.NET 10，Windows-only |
| 规模 | 462 .cs / 约 3.5–4 万行（Core/App/Tests 三项目）；基于 Ladadoos 引擎起步重构 |
| 世界 | 16×16×256（16 section），XZ 无限 |
| License | MIT |

- 光照：**四通道 RGB+阳光 flood fill 压进一个 ushort**；放置/破坏只增量修复受影响区域；网格期邻域平均得平滑光照+AO；彩色方块光驱动泛光。
- 流体：水/岩浆统一 `BlockFluid`，**深度编码进方块 id（源+下落+7 级=9 个注册项，无 per-cell 状态对象）**；事件驱动调度（静止海洋零开销）；水岩浆交汇生成黑曜石/圆石；泉水生成期"写结果不写源"保确定性。
- 地形：气候图**采样点位移扭曲**（群系边界互锁舌状）；河流=精细场零等值线+扭曲；CaveCarver 近地表 pinch；峡谷零等值线下窄上宽；**结构（村庄等）=种子+位置的纯函数**经 I terrainSampler 每 chunk 独立重算同一布局（跨 chunk 无缝、确定性是存储基石）。
- 存储：`c.X.Z.gz` 每 chunk 一文件，**只存被修改过的 chunk，其余从种子确定性再生**；格式版本不兼容拒绝而非误读；箱子/熔炉内容随方块状态走。
- 多人：TCP 服务端权威；**"客户端只报告观察（瞄了什么/按了多久/摔了多远），服务器定价值"**，背包是唯一故意放客户端的所有权且 DESIGN.md 把这条缝的后果写透。
- 写实管线：2048² 深度图阴影（整 texel 步进防爬动、贴图镂空花影、叶摆与阴影同步）、HDR+bloom+柔和 tone curve（试过全 filmic 压暗影被否决并记录）。
- 工程：57 个测试文件（无窗口无 GPU）；ci.yml（push/PR）+ codeql + release（AOT 双 zip+SHA256+资产校验脚本）；**DESIGN.md 998 行**，写"为什么+试过什么被否决"，开源体素项目最佳架构文档。
- 弱点：无 greedy（纯 culled）；每 chunk 一个 gzip 小文件在超大世界有文件数压力；TCP 多人扩展性一般。

### 6. EggyStudio/Voxel-Sandbox — 隐藏的单人大作，整体完成度最高（极活跃）

| 项 | 值 |
|---|---|
| Stars/状态 | 2★（严重低估）/ 2026-11-12（两天前） |
| 技术栈 | 自研 3DEngine（NuGet 6.2.60，另一仓库）+ Vulkan + Slang 着色器，net10 |
| 规模 | 主项目 124 .cs / 27,481 行 + 测试 67 文件 8,568 行 + 680 行 Slang；README 约 1700 行含逐项毫秒级基准 |
| 世界 | 无限，16×16 列，**-64..320（对齐 MC 主世界）**，253 种方块 |
| License | MPL-2.0（文件级 copyleft：抄整文件会传染，学思路安全） |

- 光照：MC 式双 4bit 通道 BFS + 平滑光照角点 AO + 引擎级 **radiance cascades 全局光照**（场景 SDF 追踪）+ shadow-only draws。
- 剔除：**Minecraft 式可见性洪泛剔除**（face-join 图 BFS，未见于地下/墙后的 section 不 mesh 不绘制）——洞穴场景实测 16ms→4ms。
- 网格：naive（作者明言 greedy 未写，理由：逐角颜色/CTM 连接纹理需要每角独立数据）；每角点 18 字节位打包；**Gather(主线程拷 18³ padded)/Build(任意线程)** 分离；玩家编辑列当帧主线程重 mesh。
- 生成：气候双噪声 14+ 群系、MC 新式三维洞穴（cheese/spaghetti/noodle，4×8 cell 角点密度插值）、含水层、繁茂洞穴、峡谷；村庄/矿井/沉船等结构；**洞穴噪声 GPU compute 预算 + 异步 readback，噪声全定点整数实现保证 GPU/CPU 逐位一致**（可互相验证）。
- 内存：open-sky section 全体共享一对静态数组（COW）；冷 section Brotli 压缩（每帧 16 个）；12 列视距约 1.5GB。
- 存档：region 文件制（32×32 列二进制+压缩+临时文件改名原子写）；**未修改的列不存盘靠种子重生成**；JSON source-gen 兼容 native AOT；30 秒自动存。
- 玩法：四模式、36 格背包、2×2/3×3 合成、熔炉/箱子、耐久、饥饿/氧气、TNT/苦力怕、**9 友好+4 敌对生物含寻路（`Entities/Pathfinder.cs`）**、天气粒子、程序合成音效；**Minecraft 资源包加载含 OptiFine CTM 连接纹理与 CEM 实体模型**。
- 测试：67 个 xunit 全 headless；`./e3d` 本地 socket 远程控制运行中游戏（截图/命令/状态，827 行）；CI 在 lavapipe 软件光追上**脚本化实机通关（约 84 分钟）**+ 固定种子截图回归。
- 弱点：依赖作者私人引擎包（渲染/GI/ECS 不在本仓库）、Vulkan+net10+slangc 门槛、浮点原点搬迁有 0.2-0.4s 卡顿、无 greedy、无多人、bus factor 1。

---

## 二、追加侦察的 7 个项目（简表）

| 项目 | Stars | 状态 | License | 栈 | 核心看点 |
|---|---|---|---|---|---|
| etodd/Lemma | 571 | 完结 | 自定义 | XNA 自研 | 唯一已发售 Steam 的 C# 体素游戏；物理驱动动态体素世界+关卡编辑器 |
| manicdigger | 403 | 维护 | 自定义 | OpenTK | 最老牌多人体素；**服务端 Mod API 驱动玩法**（Fortress/War 全是 mod） |
| paternostrox/Minecraft4Unity | 161 | 中 | MIT | Unity+Burst | 65 文件小而精；**Burst+NativeArray greedy 两档**（代码级验证） |
| BLaZeKiLL/VloxyEngine | 130 | 中 | MIT | Unity+Jobs | 体素引擎做成 UPM/OpenUPM 正规包（GreedyMesher+Job 调度+池化），工程化范本 |
| generatives/Wrecker | 56 | 高 | MIT | Veldrid+Bepu+ECS | 天光传播+greedy/MC/SurfaceNets 三网格器并存；**可移动体素刚体构造（飞船）**独一份 |
| Acueres/SharpCraft | 54 | 高 | MIT | MonoGame | 最易读的纯 C# MC；**ulong 位打包存储**（BitStorage）+ SQLite chunk 持久化 |
| SuperAnt30/Vge | 26 | 极高 | **无 LICENSE（不可复用代码）** | 自研+OpenGL | 3.66MB/632 .cs 单人自研引擎+**完整联机协议**（20+ Packet）活教材 |

落选备查：bonesoul/voxeliq（169★，重写停滞）、sjoerdev/voxel-engine（75★，软光追+体积 AO，非 chunk 地形）、vycdev/MineDirt（58★，透明面排序亮点）、jeanpmathes/VoxelGame（C#+C++/DX12 混合）、betairylia/Caelix（31★，已归档转私有）。

---

## 三、与瑶海 EPIC 对比矩阵

| 维度 | 瑶海 EPIC | Eggy Voxel-Sandbox | HilthonTT | RaylibGame | ra-engine | Korpi | Minecraftonia |
|---|---|---|---|---|---|---|---|
| 引擎 | Godot 4.7 mono | 自研+Vulkan | OpenTK | 自研 FishGfx | **Godot 4.6 mono** | 自研 OpenTK | Avalonia+CPU 光追 |
| 自研代码量 | ~40.8k 行 | ~36k 行 | ~3.5-4 万 | ~7 万 | 16k | ~13.4k(去 vendored) | 13k |
| 世界高度 | **512+垂直流式（唯一）** | 384 | 256 | 64 | 32+ | 512 固定列 | 48 固定 |
| 视距/LOD | **16 区块+三级远景壳 4096（唯一 LOD）** | 上限 16 区块无 LOD | 2-16 无 | 有限世界 | 无限无 LOD | 半径 14 列 | 固定 |
| Meshing | 面剔除默认 + C# Greedy（22.8% 顶点） | naive（位打包 18B/角） | culled | culled/greedy opt-in | **greedy+AO-uniform** | naive（8B/顶点） | 无（DDA） |
| 体素光照 | 天光+方块光 BFS+局部失效+顶点色日夜双通道+洞穴雾 | 双通道+AO+**GI(radiance cascades)** | **RGB 四通道 ushort** | 双通道 BFS | 无 | 无 | 无（软 GI） |
| 流体 | **CA 流动+13 次迭代言波+波动方程涟漪+镜像反射** | MC 式 5tick+平面反射 | 水岩浆完整（深度入 id） | 无 | 确定性洪水填充 | 无 | 静态 |
| 地形 | v5 分位匹配+v8 大陆 4096/侵蚀/河流+洞穴矿脉 | 气候 14+群系/三维洞穴/含水层/结构 20 文件 | 位移扭曲群系/峡谷/纯函数结构 | WorldPlan 规划式 | 7 群系 | 3D 密度 brick 插值 | WFC/MarkovJunior/OSM |
| 生物/AI | **无** | **13 种+寻路** | 5 种+刷怪 cap | NPC 指令机+寻路 | 敌人 AI(视线+翻台地) | 无 | 无 |
| 多人 | 无 | 无 | TCP 权威 | **UDP+认证+预测和解** | 无 | 骨架 | 无 |
| 存档 | palette+zstd+原子写 | region+未改不存+source-gen | 每 chunk gzip 只存修改 | 列级 deflate 复用未变块 | RWLD 调色板+RLE | 无 | JSON 整世界 |
| 树 | **结构化图+BFS 连通+整树倒伏（唯一）** | 放置式 | 放置式 | 确定性树位 | hashed grid 跨 chunk | 无 | 有 |
| 测试/CI | **34 套件 12,971 项+98 验收脚本+GD/C# 对拍；无 CI** | 67 文件+CI 通关 84min | 57 文件+ci/codeql/release | 5 测试项目+基准（仅 release CI） | 30 自测模式无 CI | 9 文件+三 OS CI | 无测试 |
| 编辑器工具 | **4 个自研 dock（唯一）** | e3d 远程控制 | F3 调试层 | ImGui 系 | 无 | ImGui 调参窗 | 无 |
| 活跃度 | 持续 | 极活跃 | 活跃 | 持续 6 年 | 停（2.5 月项目） | 停 18 个月 | 归档 |

---

## 四、我们领先的方面（证据在矩阵）

1. **引擎生态位**：唯一在 Godot 4 上做到此完成度的体素沙盒（ra-engine 同引擎但无体素光照传播/流体/测试框架，规模 16k 行）。对手 5/6 自研引擎，编辑器/动画/UI/音频生态全要自己造，我们白得整套工具链，还多出 4 个自研 dock（注册表/光照探查/图集预览/动画编辑）——无任何对手有编辑器工具。
2. **垂直尺度**：512 高 + 垂直流式带是全场唯一（最高对手 Korpi 512 但是固定列不流式，Eggy 384，HilthonTT 256）。
3. **远景**：三级不重叠远景壳推到 4096 格，唯一有 LOD 机制的项目（Eggy 明言无 LOD 且浮点原点搬迁卡顿）。
4. **光照第一梯队**：天光/方块光 BFS+局部失效+顶点色日夜双通道+洞穴体积雾，与 Eggy（多 GI）、HilthonTT（多 RGB 通道）同档；Korpi/ra-engine/Minecraftonia 无传播。
5. **水系统最讲究**：CA 流动+Physics Mod 13 次迭代言波+波动方程涟漪+SubViewport 镜像反射，渲染细度全场第一（Eggy/HilthonTT 有 MC 式流体但渲染朴素；RaylibGame/Korpi/ra-engine 无流体模拟——ra-engine 的确定性填充思想我们已具备）。
6. **结构化树唯一**：枝干图+BFS 连通+引用计数+整树刚体倒伏，所有对手都是放置式树。
7. **验收文化第一梯队且独特**：34 套件 12,971 项+GD/C# 逐位等价对拍+98 个 debug 验收脚本+perf bench+`--give` 实机注入——Eggy（67 文件+CI 通关）、HilthonTT（57 文件）、RaylibGame（5 项目）同档，但"验收脚本+等价对拍"组合是我们独有。
8. **角色与移动**：YSM+EF 数据纹理蒙皮（无对手同类）；移动手感 v2（土狼/缓冲/短跳/FOV 拉镜）这种细体验没人做。
9. **声音细度**：程序化脚步+MAtmos 音景机+一阶早期反射声学，比多数对手的"播音频文件"深一层（Eggy 的程序合成音频同级）。

## 五、值得学习的方面（按优先级）

### P0 — 补明显短板

1. **生物/AI 缺失**（全场唯一没有生物的可玩项目）：学 Eggy `Entities/Pathfinder.cs`（体素 A*）+ 13 种生物的敌对/友好分 cap 结构；HilthonTT `MobSpawner` 被动/敌对分 cap。Lemma 是"体素玩法驱动"的完整样本。
2. **CI 准入**（我们 0 CI，README 已列下一步）：HilthonTT ci.yml（push/PR format+build+test）+ codeql + release（AOT 双 zip+SHA256+`Verify-RuntimeAssets.ps1`）三级最完整；Eggy lavapipe 软渲染实机通关（84min）+ 固定种子截图回归可远期追；Korpi 三 OS 矩阵。我们 headless 测试已就绪，接 GH Actions 成本低。
3. **存档"未改不落盘"**：HilthonTT 只存修改过的 chunk 其余种子再生（确定性是 load-bearing 设计）；Eggy region 制未改列不存；RaylibGame 未变列复用原压缩块。我们地形是固定种子确定性的，天然满足前提——直接砍存档体积与写放大，顺带评估 region 合并格式（避免每 chunk 一文件）。

### P1 — 性能与架构增强

4. **可见性洪泛剔除 + shadow-only draws**（Eggy，洞穴实测 16ms→4ms）：face-join 图 BFS，未见于地表下的 section 不 mesh 不绘制。对我们高视距+洞穴雾场景收益直接。
5. **位打包顶点**（Korpi 8B/顶点含 shader 解包、Eggy 18B/角）：我们网格桥传输已压到 7KB，但 GPU 顶点内存若仍是 float3+color+uv（~32B+）还有 2-4× 空间；Godot 用 `ARRAY_CUSTOM0/1` + spatial shader CUSTOM0 解包同款。
6. **过期任务丢弃**（ra-engine `MeshVersion`、Korpi `CurrentJobId` 一行比对防旧 job 覆盖新数据）：检查我们 chunk 管线是否已有等价物，没有则成本极低收益明确。
7. **内存态区块存储分层**（Korpi Flat/Layered/Palette 按 chunk 熵自动选择 + BitBuffer；SharpCraft ulong 位打包）：我们持久化已是 palette+zstd，内存态均匀 chunk 仍是全量数组，可引入三策略。
8. **光照零分配**（RaylibGame 预分配环形队列+代次戳 visited 免清零+每列 SkyExposureCache）：我们刚完成块级脏集合（950→29.6ms），这是下一档增量的候选。
9. **可恢复性能事务**（RaylibGame 2ms/512 单位"准备/提交不可分割、其余断点续跑"）：我们已有 ms 预算框架，补"可恢复"语义可消预算截断造成的长尾。

### P2 — 玩法/生态/远期

10. **结构=种子+位置纯函数**（HilthonTT 村庄跨 chunk 每 chunk 独立重算同一布局；Eggy 结构 20 文件）：v9 垂直流式下大型结构（村庄/遗迹）的正解，我们树已用 chunk 级引用计数，结构可沿用哲学。
11. **CTM 连接纹理 + 资源包加载**（Eggy 加载 MC 资源包含 OptiFine CTM/CEM）：与 Conquest 写实材质天然搭配，提升画面一致性的高杠杆。
12. **地形升级参考**：HilthonTT 群系采样位移扭曲（边界互锁舌状）、峡谷 carver；Eggy 三维洞穴 cheese/spaghetti/noodle+含水层（cell 角点插值省采样）。
13. **GPU 参与生成 + 定点噪声 GPU/CPU 位一致**（Eggy cavefields.slang + verify 命令）：远期把 NativeTerrain 部分噪声搬 compute。
14. **多人（若立项）**：先读 RaylibGame 认证 UDP+预测/和解与 HilthonTT"客户端只报告观察、服务器定价值"的信任边界划分（含背包例外的风险论证）；Vge 的 20+ Packet 清单可当协议设计核对表。
15. **文档与发布范式**：HilthonTT DESIGN.md 式"为什么+被否决方案"记录（我们 README 决策记录已接近，补"否决记录"小节）；发布时抄 HilthonTT 的校验和+资产完整性验证脚本流程。
16. **小而美专项**：Korpi 螺旋加载顺序（我们已有列排序缓存，确认覆盖）；Minecraftonia 的 WFC/MarkovJunior/OSM 生成三件套适合洞穴装饰/废墟结构远期取材。

## 六、许可证红线

- **不可复用代码**：Korpi（自定义禁商用）、Vge（无 LICENSE）、Lemma/Manic Digger（自定义+素材限制）、Minecraftonia（MIT 但已归档，无维护）。
- **文件级传染**：Eggy Voxel-Sandbox 是 MPL-2.0——抄整文件该文件变 MPL；学思路/算法安全。
- MIT 干净可用：ra-engine、RaylibGame、HilthonTT/Minecraft、Minecraft4Unity、VloxyEngine、Wrecker、SharpCraft。
- 自家注意：Conquest 材质不可再分发（README 已承诺发布前换 CC0 备份组）。
