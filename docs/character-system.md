# 角色系统（YSM 模型 + Epic Fight 风格动画）

2026-11-06 首轮落地。目标（用户）：**人物用 YSM 式样模型、动作用 Epic Fight
风格**，后续自建动作管理系统（蒙太奇/混合），动作素材可网上找或自研。

## 总览

```
assets/characters/<pack>/          模型包（CC0，入库）
  ysm.json / models/main.json / textures/...
characters/
  ysm_model.gd        YSM/Bedrock 几何解析（数据层）
  character_rig.gd    规范 20 关节骨架 + 蒙皮网格（骨骼映射/关节定位/混合权重）
  ef_reference_rig.gf EF biped 绑定常量 + EF 动画 JSON 加载/重定向
  clip_lib.gd         Clip 数据结构 + 采样 + 程序化内置动作（许可洁净）
  character_animator.gd 分层动画器（基础层+动作层+快照过渡+头部注视）
  player_avatar.gd    化身节点（模型装载/状态机/光照采样/蒙皮矩阵下发）
  character_surface.gdshader 角色表面 + 自研 GPU 蒙皮（数据纹理）
player/player_controller.gd  F5 相机三态 / F6 换模型 / 挖掘·拳击动作触发
debug/capture_character.gd    验收截图场景
tests/test_character.gd       107 项检查（解析/映射/网格/重定向/动画器）
```

## 模型层（YSM / Bedrock 几何）

约定（源码核对 ModernYSM + ysm_epicfight_compat，两边实现一致）：

- 像素 → 方块 ÷16；**pivot.x 取负**（Bedrock X 镜像）；
- 骨骼/盒件旋转欧拉 **ZYX 序**（先 X 后 Y 后 Z），角度 x/y 取负、z 不取负；
- 骨骼变换 = `T(pivot)·R·T(-pivot)`（绕 pivot 旋转，平移链不累积）；
- 逐面 UV `{uv, uv_size}`，**v 向下、负尺寸合法**（翻转采样）；
  盒 UV 摊平布局同 Bedrock（down 面高为负）；
- **非 mirror 时 u 方向交换**（ModernYSM 逐字语义）；mirror 时东西面贴图矩形互换；
- 贴图透明面剔除（矩形全 alpha=0 整面剔除）、半透明面双面渲染；
- `height_scale/width_scale`：y × height_scale、x/z × width_scale（两参考实现
  变量名相反但默认同为 0.7，此处取 compat 语义）。

## 规范骨架（canonical rig）

20 关节 = **Epic Fight biped 同名同层**（Root / Thigh-Leg-Knee ×L/R /
Torso-Chest-Head / Shoulder-Arm-Hand-Tool-Elbow ×L/R），EF 风格动画可直接
重定向（见下）。**EF 的"Hand"在肘、"Tool"在腕**（肩=EF Arm）——解剖命名
与 EF 命名错位是有意对齐。

- **骨骼名映射**：标准化（小写/去_/尾数字/default 后缀）后查表；未映射骨
  （发型/裙摆/面部/定位器）继承最近已映射祖先 → 随头/胸刚性；
- **关节位置** = 各锚骨 pivot（大腿 pivot=髋、ForeArm pivot=肘、
  HandLocator=腕…），Root=双大腿均值；叶关节/别名就位（Knee=Leg 位、
  Shoulder=Arm 位、Elbow=Hand 位）；
- **骨架绑定帧=单位旋转**（纯平移链）：YSM 骨骼静止旋转（如 LeftArm
  z=-18° 外张）全部烘进网格顶点——换任何 EF 风格动画都无需重烘；
- **蒙皮**：顶点绑定 COLOR 通道（r/b=骨索引/255、g/a=权重，≤2 影响）；
  关节邻接带（肘/膝/腕/脖/胸）父顶点在段末 25% smoothstep 渐入子关节
  （compat 的刚体权重 + 我们加的邻接平滑）。

## 动画层

**Clip 格式**（ef_reference_rig / clip_lib 共用）：

```gdscript
{ "name": ..., "length": 秒, "loop": bool,
  "tracks": { 关节名: {"times": PackedFloat32Array,
                        "quats": Array[Quaternion],   # 规范局部旋转
                        "poss":  PackedVector3Array}}, # 规范局部平移（绝对）
  "events": [{"time": t, "name": ...}] }
```

- **EF 动画重定向**（`ef_reference_rig.retarget(raw, rig)`，逐键烘焙）：
  - JSON `{animation:[{name, time[], transform[][16]}]}`，矩阵原样读
    （列向量约定，平移在 12/13/14——biped 骨架锚点实测验证）；
  - Root 轨有效局部 = `Rx(-90°)·M_json`（Blender→MC 根修正），其余 = M_json；
  - MC 世界增量 `Δ_j = W_j·B_j⁻¹`（B_j=EF 绑定世界，内嵌 20 关节常量）；
    本引擎空间共轭 `D = R180y·Δ·R180y`；目标局部 = `D_parent⁻¹·D_j`
    （绑定帧=单位）；Root 位移按腿长比缩放；
  - **许可红线**：EF 动画资产 All-Rights-Reserved——仓库只内嵌绑定姿态
    接口常量（脚本换算），**动画 JSON 由用户放入 `user://anim_ef/`**
    （`biped/living/idle` 等自动按名优先于内置程序化动作）。
- **内置程序化动作**（clip_lib，自研许可洁净）：idle 呼吸 / walk / run /
  jump / fall / swim / dig / 空手三连拳——单位帧骨架下局部欧拉直接可读
  （+X 摆动=肢体向前，角色面向 -Z）。
- **分层动画器**：基础层（状态机 idle/walk/run/fall/swim，速率=速度/参考
  速度，倒放=后退）+ 动作层（dig/punch，上身遮罩，0.1s 淡入淡出，事件帧
  预留命中回调）+ 快照过渡（切基础动画 0.15s 从当前姿态混入）+ 头部注视
  （±75° yaw + pitch，身体朝向 14/s 滞后跟随视线）。

## 渲染：自研 GPU 蒙皮（重要踩坑）

**引擎蒙皮路径全部失效**（探针实测，Forward+）：
- 运行时 ArrayMesh 的 ARRAY_BONES/ARRAY_WEIGHTS **不自动蒙皮**；
- 显式 `Skin` + bind 逆矩阵也**不生效**；
- `uniform mat4 u_bones[20]` 数组参数：**裸场景生效，进游戏（主视口+阴影
  +水面反射 RT 多通道）后 GPU 侧被写坏**（CPU get_shader_parameter 读回
  正确、渲染爆炸成碎块）——多通道 UBO 生命周期问题。

**现行方案**（character_surface.gdshader）：骨骼矩阵走 **20×3 RGBA32F
数据纹理**逐帧 `update()`（与水面 CPU 波场同路，稳定）——
`texel(骨i, 行k) = 第 k 列基 + w 平铺原点`，顶点着色器 texelFetch 重组
mat4 后蒙皮（COLOR 通道权重归一防 RGBA8 量化微缩）。

表面光照对齐地形双通道：天光→ALBEDO×u_sky³×u_day（main 日夜下发）；
方块光→EMISSION×b³×BSL 暖色；镂空 alpha 裁切。

## 玩家接入

- **F5** 相机四态循环：第一人称（化身隐藏）/ 第三人称背后（3.2m）/
  第二人称面前（3.6m，看角色正面）/ **越肩**（2.1m + 右偏 0.55/抬 0.15，
  角色呈现在准星左侧，TPS 构图）；
- **遮挡自动调节**（外置三态共用）：眼位→期望机位体素 DDA，命中即
  收缩到命中面-0.3（下限 0.5m），**两侧均限速**——收拢 9m/s（2026-11-07：
  曾瞬间直设，俯仰到阈值角时眼→机射线首次捅进树冠/坡地，相机猛拉近
  读作"头抽一下"；限速仍快于跑速 8m/s 防穿墙）、解除 3m/s 慢回弹——
  快收慢放防抖；位置指数平滑（14/s）、模式切换大跳直接贴位；
- **F6** 循环 assets/characters 下模型包；
- 挖掘=动作层 dig；对空左键=空手三连拳（战斗阶段接命中判定）；
- 光照采样 0.15s 节流（玩家头顶格 s³/b³ → 材质）。

相机验收（debug/capture_camera.gd）：四态距离数值 3.2/3.6/2.18
（越肩含侧偏模长）✓；立墙→收缩 0.50、拆墙→回弹 2.21（回弹上限被
墙后 2.51m 处真实地形限制，探针射线实证）✓；越肩构图用合成几何测试
定地面真值（品红占位块落画面 38% 宽=准星左），实机像素统计因地形
噪声不可靠。

## 动作系统 v2：CMU mocap 素材管线（2026-11-07）

**开源调研结论**：CMU Mocap 库（2548 动作 BVH，"free for all uses"+署名）
为唯一许可洁净可入库的真实动作源；Mixamo 禁独立再分发（同 EF 自放模式，
`user://anim_mixamo/` 预留未接）；Kenney/Quaternius CC0 但低模卡通比例不匹配。

- **`characters/bvh_loader.gd`**：CMU Daz-friendly BVH（31 骨，0.1m 单位制，
  ZYX 欧拉，120fps）→ canonical 20 关节 Clip。数学与 EF 管线同框架
  （世界增量 Δ→R180y 共轭→T(pivot)·R 局部化）；**绑定=第 0 帧世界链**
  （CMU 根世界位置在通道平移非 offset，且首帧非全零旋转——T(offset) 假绑定
  曾致 leg_ratio 除零+Root delta 4117）。骨架映射：Spine→Torso/Spine1→Chest、
  ForeArm→Hand(肘)/Hand→Tool(腕)、脚/手指丢弃、Knee/Elbow 占位无轨沿用绑定。
- **`debug/export_bvh_clips.gd`**（离线工具）：`-- <bvh> [t0 t1 名]`——
  双腕+根速度滑窗排行找动作段 → 切片 30fps → var_to_str Clip JSON 入库。
- **`assets/anims/cmu/box_combo.txt`**：13_17 boxing 1.5-3.5s 切片
  （署名 README 在目录内）。avatar 自动加载（res + `user://anim_bvh/` 用户
  自放 .bvh 运行时重定向，同名覆盖）。
- **play_punch → cmu/box_combo**（ACTION_OVERRIDES，mask="all"）：拳击幅度
  96% 在 Root 转体轨（局部 95.9° vs 手臂 9°），上身遮罩下只剩微动——
  mocap 战斗动作必须全身驱动（Epic Fight 风格）。
- 验收：数值（Root 19°→49°→75° 随时间推进、无冻结）+ 近景视觉（收拳→
  出拳肩前送→收拳防守完整节奏、无穿模）双通过；远景小角色视觉判读不可靠
  （老坑复现，须拉近机位）。
- 已知限制：mocap Root poss delta（演员脚步）为视觉位移不驱动物理位置
  （root motion 集成在路线图）；连击输入缓冲/取消点未做。

## 拔刀战斗：EF yamato 动作集移植（2026-11-07）

**素材**：用户整合包 DevilMineCraft-1.0.5.jar 内 97 个 EF 动画
（`assets/invincible_dmc/animmodels/animations/`：yamato 攻击 38/闪避 8/
living 18/受击 12 等；86 个 attributes 格式 + run/parry×2 共 3 个
biped matrix 格式（无 format 字段默认 matrix）+ 8 个 effect matrix）
——提取至 `user://anim_ef/`（**All-Rights-Reserved
不入库**，用户自放模式；轨道名与 canonical 同名，
现有 `ef_reference_rig` 管线双格式直读，零适配）。

- **拔刀模式（F7）**：`set_armed`——持刀 yamato 动作集（idle/run 持刀姿态、
  walk 借 run 慢放 0.75×）+ 太刀可见 + 左键分流；收刀恢复挖掘/徒手。
- **三段连击（左键）**：yamato_combo_a×3；提前按=缓冲（`_buffered`），动作
  进度 ≥45%（`action_progress()`）自动接段；错过窗口播完自然回 idle。
- **闪避（双击 WASD，0.28s 窗口）**：四向 dodge 全身动作 + 7m/s 冲量脉冲
  （controller `take_dodge_impulse` 局部→世界，22m/s 指数衰减 ~0.35s）+
  0.55s 硬直锁。
- **太刀（自建 CC0 盒件）**：柄/格挡/刀身三盒，挂 Tool_R 腕关节
  （`_apply_pose` 每帧 `globals[Tool_R] × 握持旋转`，不占蒙皮纹理通道）。
- 验收：数值（连击 1→2→3 段推进 34%→22%→3%、闪避触发、刀可见）+ 视觉
  （持刀自然不穿模、三帧挥砍刀向变化、后撤闪避、无畸变）双通过。
- **动画器修复**：`_advance_action` 淡出触发移到权重更新前——大 delta 单帧
  曾用旧 target 算权重致动作滞留（进度 2.44 active=true，测试抓到）。
- 未接：受击动画（无敌人触发源）、挥砍命中判定、特效（summoned_sword
  等特效轨为非 biped 骨架，加载器自动忽略）。

## 动作编辑器插件（2026-11-07）

`addons/anim_editor/`（已启用，编辑器右下面板"动作编辑器"）：

- **左资源面板**：模型列表（assets/characters 全包，双击切换/重定向重算）、
  动作列表（**全 106 个同源游戏**：程序化 8 + CMU mocap + EF yamato 97，
  拖到时间轴或双击加入）、武器下拉（无/太刀）；
- **预览**：SubViewport 内嵌 PlayerAvatar（数据纹理蒙皮/动画器/重定向
  全套复用）+ 地板/双光源/轨道相机（拖转+滚轮缩放）；
- **时间轴**（`anim_timeline.gd` 自绘）：秒刻度/clip 色块/播放头；点击
  seek（支持往回拖）、滚轮横移、Del 删块；
- **播放控制**：播放/暂停/停止/循环/速度 0.25-2×；**播放真值源=时间轴
  playhead**——每帧 locate 段内时间直写 `animator._base_time` 后带 delta
  update（delta 供快照过渡；曾 update(0) 零推进致 seek 跨段过渡永停
  alpha=0 画面冻结，集成测试抓到），_base_time 逐帧重写自动纠正漂移。
- **@tool 链**：player_avatar/animator/rig/ysm_model/clip_lib/ef_rig/
  bvh_loader 全加 @tool（编辑器进程执行前提；运行时行为不变）。
- **v2 升级（CwcMontage 概念移植，2026-11-07）**：调研确认 Godot 生态
  无同类插件（官方 cutscene 编辑器仍 open proposal #1356）；CwcMontage
  （Unity，专有许可）仅借鉴设计——① **段级修剪+倍速**（队列项存
  t0/t1/speed，表观时长=(t1-t0)/speed，采样经 source_time 映射回源轴；
  选中块属性区调入/出点/倍速，时间轴橙角标显示修剪）；② **区间事件
  扫掠**（事件={t0,t1,name} 粉带显示，半开区间 (prev,curr] 扫掠
  OnEnter/OnExit 严格成对、大步跳不漏 exit——战斗命中窗口基石，
  播放时打印到 Output）；③ **蒙太奇导出/导入**
  （assets/anims/montages/montage_1.txt var_to_str 往返保留全部属性）。
- 测试：test_anim_editor（时间轴数据层单元 + dock 入树集成 + seek/播放/
  武器）；窗口冒烟截图：角色+太刀完整渲染、时间轴/控制栏正常。
- **编辑器实机三连坑（用户"没法正常用"，2026-11-07 复现修复）**：
  ① **_exit_tree 手动清 avatar=误杀**——编辑器布局恢复 reparent dock
  触发 _exit_tree，re-enter 后 _ready 不再执行 → avatar 永久 null
  预览只剩地板（实例计数+定时器诊断定位；子节点随树自动释放勿手动清）；
  ② **蒙皮 bone 纹理初始全零=顶点塌原点**（游戏首帧被 _apply_pose 掩盖，
  dock 空队列即露馅；`_seed_bind_pose` 填绑定矩阵链）；
  ③ **SubViewport 挂编辑器 dock 必设 `own_world_3d=true`**（默认继承
  父视口=正在编辑场景的世界）。
  另修：模型列表名（get_base_dir 多一层全显示 "characters"）、EF 97 个
  重定向分帧异步（曾同步卡主线程十几秒，游戏启动同受益）、相机初始取景
  拉近+3/4 正面、"⤢ 大窗口"弹出（dock 面板窄）。
  终审（编辑器实进程截屏+像素+视觉三验）：粉双马尾红结黑裙角色持太刀
  完整可见无散架。

- **肘弯方向反（用户实机"手应该向前弯却向后弯"）**：程序化 clip 的
  肘键曾照膝盖直觉写负号——人体膝向后弯（Leg 负号正确）、肘向前弯
  （Hand 应正号）；三源数值判决（上臂→肘→腕世界向量投影 z 分量）：
  proc_run +0.6 向后=实锤、EF/CMU 世界增量链正常（yamato 挥刀以肩
  为主肘几乎伸直）。修复=clip_lib 全部 Hand 键取正（run 45/swim 20/
  dig 30-45/punch 8-35），回归断言"跑步左肘弯向 z<-0.2"。
  （远景小角色视觉判读不可靠老坑——首轮出拳验收只看了轮廓差异没验
  弯向，本轮编辑器拉近才暴露。）

- **EF attributes 动画全崩（用户实机"除 YSM 自带动作其他都出问题"）**：
  DMC 包（attributes 格式）rot 四元数是 **(w,x,y,z) 序**——首帧
  [1,0,0,0]=单位实锤；加载器曾按 Godot (x,y,z,w) 序解析成"绕 X 180°"，
  97 个动画全帧错位 → 世界链崩塌（挥刀手臂塌进躯干，近景截图判定）。
  回归：attributes 单位/绕 Y90° 落位 + attr_space 打标断言
  （_test_ef_attributes_quat_order）。CMU（BVH 直链不经 EF loader）
  不受此 bug 影响。

- **attributes 语义修正（epicfight 1.21.1 源码定谳，2026-11-07 二轮）**：
  用户"不会拧麻花了但错位、扭曲"截图 → 翻 EF 源码
  `JsonAssetLoader.getTransformSheet`/`getAnimationBoundMatrix` 拿到
  权威语义：**ATTRIBUTES 分支 rot 取 xyz 负＝共轭**（fromPrimitives
  (-rot[1..3], rot[0])），且动画增量叠在 bind 局部之上——世界链
  `W_j = PARENT · L_bind_j · T(loc) · R(conj(rot))`（不乘 invLocal、
  Root 不乘 B2MC：B2MC 已烘进 armature bind 常量；MATRIX 分支的
  invLocal 恰与合成序的 JOINT_LOCAL 相消＝矩阵直读，两分支在
  "世界链统一 MC 空间"下殊途同归）。此前"Blender 姿态空间/恒等共轭/
  不取负"的推断全部推翻——恒等帧两解同值所以恒等测试测不出，真动作
  帧 conj 方向反+丢 BIND_QUAT 因子（肩/腿 180° 绑定旋转）＝深链关节
  锯齿折叠。修复后：attributes 与 matrix 仅"局部构建"一处分流，下游
  （R180 共轭、root_off 翻转、bind_worlds 分母）与 matrix 完全同路。
  数值验证（debug/audit_ef_world.gd 直接按源码公式建 MC 世界链）：
  idle 站姿/剑道架势、walk 矢状面摆腿+反相摆臂、knockback 平躺后飞
  6m、combo 突刺——全部解剖正确。DMC 97 个里 86 attributes +
  run/parry×2 等 3 个 biped matrix（无 format 字段默认 matrix）+
  8 个 effect matrix。

- **"部件原地拧"根治（纯旋转局部化，attributes 语义修正同轮）**：
  三连环时代引入的"几何式局部化"（G=T(绑定pivot)·R(D) 取
  p_out=rel.origin−Δpivot）有隐性大坑——它把**父旋转抵消进局部平移**：
  FK 还原后关节恒钉在绑定链位置、只各自原地旋转，多关节大幅旋转动作
  （knockback 平躺、挥砍收臂）渲染成部件原地拧＝用户"错位、扭曲"的
  残余真身（蒙皮 v'=R(D_i)(v−pivot_i)+pivot_i，i 各自为政）。
  正确语义＝**纯旋转局部：q=D_p⁻¹·D_j、p_out=0**——骨架位置=绑定骨长
  链，动画器 FK 携带父旋转（子骨偏移随父姿态转动，与 EF 原生蒙皮同构）。
  ef_reference_rig 与 bvh_loader 同步修复（CMU 拳击远景验证当年漏检：
  幅度在 Root 转体+摆臂，前臂原地拧不明显）。回归
  _test_ef_rotation_chain_carry（knockback 倾倒段 Head 偏移随父旋转，
  曾恒=绑定竖直偏移）。出向四元数 .normalized()（BIND 常量非严格单位，
  乘积模亏缺被 angle_to 放大成假转角，恒等输入曾测得 0.04°）。
  span 断言改"防爆不锁站姿"（0.3~2.5：坠落 0.69/突刺 1.25 是真姿态）。

- **前肢顶端扭曲＝手骨映射到肘（2026-11-07 三轮，用户实机验收动作正常
  后的残余反馈）**：YSM `righthand`（手部方块父骨）曾映射 canonical
  Hand_R（=EF 的**肘**），腕旋转（Tool_R：idle 反手待机 173.7°、combo
  104.2°）只作用于无网格的 `righthandlocator`——手部方块跟着肘转＋
  Hand→Tool 邻接混合带把肘/腕两套大差异旋转剪切插值＝前臂末端方块
  扭曲。修复：`lefthand/righthand/handleft/handright`→**Tool**（手骨
  =腕），`forearm→Hand`（肘）不变；武器挂点语义不变（Tool_R 优先）。
  EF 侧 Elbow_R 经查仅为参考关节（挂 Arm 下，供碰撞体/姿态参考，
  无 twist 分配机制）。

- **面被异常拉伸＝顶点级 LBS 混合带剪切（2026-11-07 四轮，改刚体分块）**：
  角色首轮自带的"关节邻接混合带"（父段末 25% 顶点 smoothstep 混入子
  关节）在两关节旋转差大时把跨带 quad 剪切拉长——CPU 复刻蒙皮量化
  （debug/audit_skin_stretch.gd）：idle/attack 帧最差对角线 1.24-1.25×
  （面积 ~1.5×，最狠顶点 w≈1.0＝quad 单角被拉走）；腕反手 173° 手骨
  归腕后显性化。MC/YSM/EF 原版均为**刚体分块**（每方块 8 顶点随单
  关节，YSM 在 MC 里就是刚体骨骼动画）——删除 `_apply_blend_zones`
  与 BLEND_PAIRS，全部顶点单关节权重 1.0；混合 quad=0、拉伸消失。
  副作用=关节弯曲处相邻方块间细缝/台阶＝MC 原生观感。回归
  _test_blend_zones 反向锁定（无双权重顶点+全权重 1.0）。

- **武器垂直前臂 + 刀鞘（2026-11-07 五轮，用户实机两条反馈）**：
  ①太刀挂接曾 Rx(-28°)=刀身贴臂共线（长枪式）——改 Rx(-90°)：刀局部
  +Y（刀尖）转到腕局部 -Z（掌前），垂直于骨骼延伸；②自建刀鞘（黑漆
  鞘体+金口环/鞘尾，鞘口=原点 +Y 口外，容刃 0.86m）挂 Torso 左腰
  （Rx(-40°) 斜佩），刀恒可见：拔刀在手、收刀插鞘（握点悬鞘口上
  0.25 露柄）。set_weapon_visible 废除。
- **⚠ 测试协程坑：run() 调含 await 的子测试必须加 await**——
  test_anim_editor 的 _test_dock_integration 曾被裸调用：协程在 wait
  循环首个 await 挂起即被弃，**其后全部断言（含武器断言）从未执行**
  （31 项假象=时间轴 30+avatar 1 项，多轮改动靠假绿通过）。修=run()
  内 `await _test_dock_integration()`；连带暴露 wait 条件竞速（只看
  clips≥100 而 CMU 排在 EF 之后装载→"清单含 CMU"假失败），wait 改
  数量+cmu/ 前缀双条件。修后 45 项真执行。

- **DMC 官方阎魔刀+鞘模型接入（2026-11-07 六轮，用户"mod 包里应该
  有刀和鞘的建模"）**：jar `animmodels/weapon/devil_sword/` 5 个 EF
  mesh（顶点数判定形态：blade=纯刀绑 Tool_R/13、in_sheath=插鞘刀绑
  Tool_L/18、on_torso=插鞘刀挂躯干绑 Torso/7、all=双手刀+鞘、jc=次元
  斩）。提取 blade/on_torso+主纹理+_l 发光层到 user://anim_ef/weapon/
  （**All-Rights-Reserved 不入库**，同动画红线）。新 ef_mesh_loader.gd：
  EF mesh json（Blender 空间）→ `R180y·B_joint⁻¹·Rx(-90°)·v` 顶点变
  换（复刻 EF 静态蒙皮 M·B⁻¹·v）→ ArrayMesh（part 三元组=(pos,uv,
  normal) 索引、每 3 元组 1 三角、面序翻转、UV v 翻转、去重）。挂接
  =关节 global 局部原样（**持刀几何数据自带**，与 EF 原生渲染同构，
  不加姿态补偿——回退自建刀才用 Rx(-90°) 垂直姿态）。状态机：拔刀
  =刀显+on_torso 鞘隐；收刀=鞘显（含刀）刀隐。缩放 0.5（RenderYamato
  .weaponScale 反编译常量；建模刀 2.32m×0.5=1.16 与自建 1.15 一致）。
  纹理=主图 albedo + _l 发光层 emission。测试 DMC/回退双路断言
  （46 项）。
- **武器三态+鞘定位收尾（2026-11-07 七轮，用户"刀位置不对/选无场景
  里也有刀"）**：①武器三态 enum（NONE/HOLSTERED/ARMED）——dock 下拉
  三项（无/收刀/拔刀，预览默认无），F7=armed↔holstered，"选无=全隐"
  修复；②刀位置经实机截图+反编译定谳：**DMC 渲染=poses[Tool_R] 直乘
  无校正、常态 scale=1.0**（RenderYamato/SdtWeaponRenderer 字节码），
  我们挂接公式与官方一致——armed 截图验收"柄在拳心、垂直向下待机、
  长度合理"✓；③"红色漂浮物"=DMC on_torso 鞘（其建模挂姿按 DMC 大
  比例躯干，挂 0.7 小躯干=肩背悬空水平）——**撤除，鞘恒用自建盒件**；
  ④自建鞘挂位修 x=-0.34 出体侧（曾 -0.16/-0.02 **嵌在躯干方块内部**
  被身体挡住=实机判读"鞘缺失"），斜佩 40° 验收"贴腰侧、无穿模"✓。
  拔刀后空鞘恒挂腰=真实佩戴。实机工具 debug/capture_weapon.gd（正面+
  背后双机位）。**教训：挂点/附件位置必须实机截图验收（体内嵌藏/
  悬空这类错数值断言看不见）；视觉模型色彩判读不可靠（树影误读
  红色物体），用 PIL 像素采样定谳。**

- **DMC 刀握点定标（2026-11-07 八轮，"位置还是不对"两轮实机迭代）**：
  三大隐藏错全靠像素级判读（picture-looking agent）+数值对账挖出：
  ①**建模轴心悬空**——DMC 刀几何是平行局部 y 的弯刀但轴心悬在离
  Tool_R 原点 z≈-0.71（建模参考位=bind 骨架侧方）→ ef_mesh_loader
  axis_snap：握段 x/z 归零+沿 +Y 平移 0.95（镡=柄刃交界露拳前贴指根，
  曾握在刀身中段：镡拳后 0.36m）；②**拳心实测**——Tool_R=腕点，
  _grip_off=rig 网格中 Tool_R 权重顶点均值（bind 缓存，每帧随腕基
  变换；纯沿前臂平移差 8px≈半拳高，前臂与刀身近同向平移多白费）；
  ③**idle 动画错配**——armed idle 曾用 yamato_idle（空手收刀待机），
  换 yamato_idle_2（持刀战斗待机：刀水平指前⊥前臂）。鞘轴向=from-to
  四元数（局部 -Y=鞘尾→左后下；**-Z=角色前方，tail_dir z 正=朝后**，
  曾反号朝前被正面机位漏判——前后倾必须 3/4 或背后第二机位验）。
  终态验收：拳握刀柄、刀身水平朝前 ~1m、背后仅露拳侧短柄尾、鞘挂
  左髋斜向后下。判读方法论：像素级 picture-looking+三角化可量出
  0.36m 级偏移；连续迭代保留旧图对比。
- **EF 空间定调：面 -Z 无 R180（2026-11-07 十轮，用户"攻击四肢
  错位"）**：armature 官方 bind Tool_R 右腕 x=+0.375 ⇒ 面 -Z 时右=+X
  ⇒ **EF 数据空间面向 -Z=本引擎**（MC Java 实体惯例；"MC 面 +Z"是
  B2MC 对 Blender -Y 惯例的误推，EF 工具链建模面 +Y）。数据自证：
  combo 突刺 -Z ✓ / knockback +Z ✓。retarget 去 R180+root_off 直取
  （CMU 保留）；曾用 R180 在不对称大位移动作上暴露：突刺朝后
  0.9m+挥刀镜像。**同步坑：ef_mesh_loader.to_local 同步去 R180**
  （曾漏=刀向差 180°）。**Root 水平位移清零**（EF 原版由实体
  MoveCoord 消费；原样写入=网格脱离胶囊冲相机 2m+接段弹回，root
  motion 接入时从此处取水平分量）。**连击接段 hard 权重直起**
  （曾 0 淡入=中段弹回 idle）。实机四帧验收：连贯挥砍+模型稳定+
  刀弧正确。遗留打磨：发力帧刀刃侧对相机不可见（可加刀光拖尾）、
  攻击头部俯仰大（源动画风格）。
- **官方 armature 终审（2026-11-07 九轮，用户供 epicfight-1.21.1
  源码包）**：armature 定义在 `animmodels/entity/biped.json` 的
  "armature" 字段（hierarchy 16 元素行主序矩阵、平移在第 4 列、Root
  左乘 B2MC）——与我们的 BIND_QUAT/BIND_POS **逐关节 0.0°/0.000 全
  吻合**（唯一 Elbow_R/L 差 120°=无动画消费的参考关节，零影响）。
  即：挂接数学无误，DMC 刀建模轴心悬空 z≈-0.71 是建模事实，
  axis_snap 校准方案正确。刀可见性（用户"看不到刀"）：黑刃蓝纹
  夜景不可见——材质提亮（albedo tint 1.55×+metallic 0.7/roughness
  0.3 借环境高光+发光层 2.5×），实测刀区青蓝发光 5152px（曾 1-2px
  暗线）。

- **ysm_epicfight_compat 官方源码对照（2026-11-07，MIT，解包
  F:/character_inspect/ysm_ef_compat_v2/）**：两大映射获官方确认——
  ① EF joint 12=elbowR（"EF Hand=肘"命名错位一致）；② 武器握点
  GRIP_JOINTS={"Tool_R","Tool_L","Hand_R","Hand_L"} Tool 优先，fist=
  手部几何质心（拳心）——太刀锚点由腕原点下移 -Y 0.10m 到拳心。
  该包跑在 EF 运行时内不解析动画 JSON（attributes 语义无官方参考，
  我们的三连环修复以数值审计为准）；其路线=换关节 pivot（YSM 几何
  推导）vs 我们=世界增量重定向，殊途同归。可再挖：realcamera
  （第一人称真身）、EFMeshJsonWriter（YSM→EF mesh 反向导出）、
  动画过渡守卫。

## 实机修正记录（2026-11-07）

- **第二人称头俯仰反向**（用户报"低头/抬头到一定程度头抽一下"，
  P1 低头→头抬、P2 抬头→头低）：根因=头部俯仰源读 `cam.rotation.x`——
  模式 0/1/3 相机旋转被直接设为 `(_pitch,0,0)` 侥幸正确；第二人称相机
  是 `look_at` 派生的**自身俯仰**（低位仰拍 rotation.x 为正）→ 头反向，
  且俯仰过 ~7°（`sinθ·3.6 > 0.45` 胸口偏移，几何过零）后才明显=「到
  一定程度」。修复：`head_pitch` 直读 `player._pitch`（四模式统一语义
  低头→低头）。回归测试 `_test_second_person_head_pitch_source` 钉死
  「相机俯仰≠玩家俯仰」（二身低头相机仰拍 rotation.x=+0.48）。
  诊断要点：头/相机全部链路四模式数值扫描连续（0 跳变）——纯俯仰
  "抽动"假象先查**语义源**（跟错对象）再查连续性。
- **倒走切换相位跳变**：`set_base` 同名反向切换曾直接翻转时间映射
  （0.25↔0.75 半周期姿态跳变）；修复=镜像采样相位保持当帧连续
  （回归断言"倒走切换姿态连续"）。

## 验收记录（2026-11-06）

33 套件 12801 检查 0 失败（含 test_character 107 项）。截图验收链：
CPU 探针（idle 绑定最大顶点位移 0.0056=呼吸量）→ 品红对照（几何无畸变）
→ 定帧 PIL：出拳三帧差分 6785px、轮廓签名随相位变化（勾拳最宽 1543px/
刺拳 1011px/滞空展开最高 240px）→ 视觉确认绑定站姿完整（贴图/比例/落地
零畸变）。已知限制：远景小人肢体角度视觉模型判读不可靠（用 PIL 真值）。

## 路线图

- 战斗阶段：EF 攻击段位（antic/contact/recovery）+ 命中判定 + 根位移
  （Coord 轨已在加载器跳过处预留）；
- 次级运动：头发/裙摆/尾巴摆锤解算（compat 的骨段求解器算法已调研：
  强迫摆锤+锥角限+链预算+接触锚，非 verlet）；
- YSM Bedrock 动画+Molang 子集（默认包 main.animation.json 仅需
  sin/cos/lerp/clamp + q.ground_speed 等 6 查询）；
- 第一人称手臂模型（models/arm.json + 独立相机空间渲染）；
- 换装/表情（纹理切换 + 骨骼可见性，extra_animation 表已解析）。

## 战斗系统下线（2026-11-11，用户指示暂藏）

`characters/player_avatar.gd` 顶部 `const COMBAT_ENABLED := false`：
false＝刀/鞘模型不构建（局内不可见）、F7 拔刀/双击闪避/连击入口全
guard（attack 回退徒手拳）、dock 武器下拉禁用、武器测试断言跳过。
**恢复＝翻回 true**，全部代码/测试/截图工具（debug/capture_weapon.gd）
原样保留。角色基础系统（YSM 模型/程序化动作/CMU mocap/动作编辑器）
不受影响。
