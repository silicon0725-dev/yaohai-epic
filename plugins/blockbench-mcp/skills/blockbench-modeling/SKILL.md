---
name: blockbench-modeling
description: 用 Blockbench MCP 做 3D 建模：headless 模式直接创建/编辑/校验/渲染 .bbmodel，桌面模式驱动 Blockbench 应用并导出 glTF/glTF-Binary（Godot 可用）、Bedrock geo.json、Java 方块模型。当用户要求做模型、方块、角色、硬表面网格、贴图或动画时使用。
---

# Blockbench 建模

本插件提供两种 MCP 模式，**默认用 headless 模式**（无需打开 Blockbench，多 agent 可并行）：

| 模式 | 工具前缀 | 何时用 |
|---|---|---|
| headless（stdio，已随插件启动） | `bbmodel_*`、`blockbench_launch` | 创建、编辑、校验、渲染 .bbmodel 文件；导出 Bedrock/Java |
| 桌面（HTTP，需 Blockbench 运行并装插件） | `create_project`、`place_cube`、`export_model` 等 | 需要导出 glTF/glTF-Binary、驱动真实 UI、绘制贴图 |

## 核心工作流（headless）

1. **创建** `bbmodel_create` → 得到 `revision`。常用格式：`free`（通用，唯一支持 mesh）、`bedrock`、`bedrock_block`、`java_block`、`geckolib_model`、`modded_entity`。
2. **搭建结构** `bbmodel_edit` 原子批处理：先 `add_group`（骨骼/分组，设 `origin` 关节点）再 `add_cube`（`from`/`to` 两角，绝对模型单位）挂到分组下；自由造型用 `add_mesh_primitive`（cuboid/sphere/cylinder/torus…）+ `edit_mesh`（extrude/loop_cut/subdivide/移动顶点）+ `map_mesh_uv`。
3. **贴图** `bbmodel_add_texture`（嵌入 PNG 并可一次指派到面）。发光材质用 `render_mode: "emissive"`。
4. **校验** `bbmodel_validate`（悬空、穿插、薄片、方块尺寸、左右镜像）；动画用 `bbmodel_validate_animations`。
5. **渲染自检** `bbmodel_render` 出 PNG —— **必须读图目检**后再交付。首次渲染会自动下载约 130MB 渲染引擎（一次性）。多视角用 `bbmodel_contact_sheet`。
6. **交付**：Bedrock → `bbmodel_export_bedrock_geometry`；Java → `bbmodel_export_java_block`；给用户预览 → `bbmodel_web_url`（浏览器打开）；要 glTF/在编辑器里继续 → `blockbench_launch` 打开桌面版，或见 desktop-tools.md。

## 关键规则

- **修订号协议**：每次读返回 `revision`，写操作带 `expected_revision`；冲突被拒就重读重试（必要时减小批量）。
- **坐标系**：Blockbench 单位（MC 中 16 单位 = 1 方块），X 东、Y 上、Z 南，模型正面朝 -Z。`from` ≤ `to`。旋转是绕 `origin` 的欧拉角（度，Z·Y·X 顺序）。
- **格式硬约束**：mesh 只允许 `free`；`java_block` 立方体限制在 -16..32、旋转 22.5° 步进/单轴；`bedrock_block` 每维 ≤30 像素、可偏心 7 像素；部分格式强制 box UV 和整数尺寸。违反时整批拒写，按报错逐项修。
- **root 限制**：所有文件路径必须在模型根目录（本工作区）内，用相对路径。
- 渲染只支持 PNG 纹理；粒子效果无法 headless 渲染，需打开 Blockbench 预览。

## 参考文档

- [headless-tools.md](references/headless-tools.md) — `bbmodel_*` 全部工具、参数与调用示例
- [recipes.md](references/recipes.md) — 常见任务配方：MC 方块、角色骨骼、Godot 用 glTF、动画循环
- [desktop-tools.md](references/desktop-tools.md) — 桌面模式（HTTP）接入与 `export_model` glTF 导出
