# 建模配方

## 通用自检流程（每个模型交付前）

1. `bbmodel_validate`（必要时 `self_test: true`）→ 0 violations
2. `bbmodel_render` 或 `bbmodel_contact_sheet` 出图 → **读图检查**：比例、对称、穿插、UV 错位
3. 有动画再跑 `bbmodel_validate_animations` + `bbmodel_sample_pose` 抽查几个时刻
4. 交付时附 `bbmodel_web_url` 让用户浏览器预览

## Minecraft Bedrock 方块（bedrock_block）

约束：每维 ≤30 像素，可从方块中心偏心最多 7 像素；坐标以方块角为原点，常用范围 -7..23（再减 [8,0,8] 偏移由导出器处理，直接按 Blockbench 习惯摆即可）。

```
bbmodel_create {file:"blocks/lantern.bbmodel", format:"bedrock_block", resolution:{width:32,height:32}}
bbmodel_edit ops:
  add_cube {name:"base", from:[4,0,4], to:[12,6,12], box_uv:true, uv_offset:[0,0]}
  add_cube {name:"pole", from:[7,6,7], to:[9,14,9], box_uv:true, uv_offset:[16,0]}
bbmodel_add_texture {file:"blocks/lantern.bbmodel", image:"textures/lantern.png", assign_to:["base","pole"]}
bbmodel_render → 目检
bbmodel_export_bedrock_geometry {file:"blocks/lantern.bbmodel", output:"blocks/lantern.geo.json"}
```

## Minecraft Java 方块（java_block）

约束：立方体在 -16..32 内；旋转只能单轴且 22.5° 步进；不允许 group 旋转。模型 3×3×3 格内。导出 `bbmodel_export_java_block`。

## 简单角色 / 生物（bedrock 或 free）

骨骼思路（16 单位 = 1 格，人形参考高度 ~32 单位）：

```
add_group body    {origin:[0,12,0]}
add_group head    {origin:[0,24,0], parent:"body"}
add_group arm_left {origin:[-6,22,0], parent:"body"}   # 挂点=肩
add_group arm_right{origin:[ 6,22,0], parent:"body"}
add_group leg_left {origin:[-3,12,0]}
add_group leg_right{origin:[ 3,12,0]}
```

- 每个 group 的 `origin` 是关节轴心；四肢立方体从关节向下/向外延伸。
- 对称件先建一侧，另一侧改坐标镜像（X 取反），`bbmodel_validate` 的 mirror 闸门会检查。
- 动画：`add_animation {name:"animation.walk", length:1, loop:"loop"}`，对 leg_left/leg_right 设 `rotation` 关键帧（0/0.5s 反相摆动 ±30°），`catmullrom` 更自然。
- 纹理分辨率按模型复杂度选 64×64 或 128×128；box UV 时 `uv_offset` 在图集里给每个立方体留出 (宽+深)×(高+深) 的框。

## 硬表面 / 有机造型（free 格式 + mesh）

```
bbmodel_create {file:"props/drone.bbmodel", format:"free"}
bbmodel_edit ops:
  add_mesh_primitive {shape:"cuboid", diameter:14, height:6, name:"hull", origin:[-7,10,-7]}
  add_mesh_primitive {shape:"cylinder", diameter:3, height:10, sides:12, name:"rotor_arm", origin:[8,12,0]}
  edit_mesh {target:"hull", actions:[ extrude_faces {faces:[...], distance:2}, bevel 效果用 beveled_cuboid 或手动切角 ]}
  map_mesh_uv {target:"hull", mode:"auto"}
```

- 直边圆柱 `align_edges` 平滑法线看需求；`sphere`/`icosphere` 有 `detail` 细分级。
- 记得：mesh 只能在 `free` 格式；MC 系导出器会跳过 mesh。

## Godot / 通用引擎（glTF 路线）

headless 工具集没有 glTF 导出器，两条路：

1. **桌面导出（推荐）**：`blockbench_launch {file:"mobs/golem.bbmodel", wait_for_mcp_ms: 15000}` 打开模型 → 按桌面模式接入（见 desktop-tools.md）→ `export_model {codec:"gltf", options:{encoding:"binary", scale:1, embed_textures:true, armature:true}}` 产出 `.glb` 直接拖进 Godot。
2. 手动：`bbmodel_web_url` 或 `blockbench_launch` 让用户在 Blockbench 里 File → Export → glTF。

Godot 提示：Blockbench 1 单位 = 1/16 米，glTF 导出的 `scale` 会换算成米；骨骼动画随 `armature:true` 导出。

## 粒子（Bedrock Snowstorm）

```
bbmodel_particle_effect {name:"flame", preset:"flame", knobs:{...}}  # 写 particles/flame.json
bbmodel_edit ops: add_locator {name:"fx_muzzle", parent:"arm_right", position:[6,20,2]}
                 set_particle_keyframe {animation:"animation.attack", time:0.2, effect:"flame", locator:"fx_muzzle"}
```

交付资源包用 `bbmodel_particle_pack`。
