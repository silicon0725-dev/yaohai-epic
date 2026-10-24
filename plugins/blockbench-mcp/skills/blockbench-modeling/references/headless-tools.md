# headless 工具速查（`bbmodel_*`）

来源：vendor/blockbench-mcp/headless（v1.10.1）。路径均相对模型根目录。所有写操作支持 `expected_revision` 乐观并发。

## 读取

| 工具 | 说明 |
|---|---|
| `bbmodel_info` | 文件概要：格式、版本、分辨率、节点数、包围盒、`revision`。**编辑前先调它** |
| `bbmodel_outline` | 大纲树（group/element），`transforms: true` 带 origin/rotation/from/to |
| `bbmodel_find_elements` | 按名称/类型/所在分组/纹理查元素，返回世界坐标包围盒 |
| `bbmodel_get_node` | 按 UUID 或精确名取单个节点完整数据、父节点、包围盒 |
| `bbmodel_list_textures` | 纹理列表：索引、尺寸、是否内嵌（不返回图像数据） |
| `bbmodel_list_animations` | 动画列表：长度、循环模式、每骨骼每通道关键帧数 |
| `bbmodel_sample_pose` | 数值采样某时刻各骨骼世界枢轴与姿态包围盒（不渲染检查动画） |

## 创建与编辑

### `bbmodel_create`
```json
{ "file": "mobs/golem.bbmodel", "format": "free", "name": "Golem",
  "resolution": { "width": 64, "height": 64 }, "overwrite": false }
```
- `format`：`free`（Generic，唯一允许 mesh）、`bedrock`、`bedrock_block`、`java_block`、`geckolib_model`、`modded_entity`、`bedrock_old`、`optifine_entity`、`skin` 等。bedrock 系/geckolib/modded/skin 默认强制 box UV。
- `resolution` 是纹理分辨率（UV 像素密度），默认 16×16。

### `bbmodel_edit` —— 原子批处理
`operations` 按序执行，任一失败整批不写并指出失败操作。常用 op：

- `add_group` `{name, origin, rotation?, parent?}` —— 骨骼/分组；`origin` 是旋转轴心（关节）。
- `add_cube` `{name, from, to, origin?, rotation?, inflate?, parent?, box_uv?, uv_offset?, mirror_uv?, texture?, faces?}` —— `from`/`to` 是两角（绝对模型单位，整数最稳）；box UV 时面自动布局，`uv_offset` 是布局左上角。
- `update_node` `{target, ...同上字段}` —— 改名/移动/改几何/换父级；改尺寸会自动重算 box UV。
- `remove_node` `{target}` —— 连同子树一起删。
- `add_texture` `{name, source: <PNG data URL>, width, height, material?, channel?, wrap_mode?, render_mode?}`；`render_mode: "emissive"` 发光、`"additive"`/`"layered"` 透明混合；`wrap_mode: "repeat"` 平铺。
- `assign_texture` `{targets: [元素名/UUID], texture, faces?}`。
- `add_material` / `update_material` —— PBR 材质（`color_value` 颜色、`mer_value` [金属度, 自发光, 粗糙度]、`subsurface_value`），配合法线/高度/MER 贴图通道。
- `add_animation` `{name, length, loop: "once"|"loop"|"hold", snapping}`；`set_keyframe` `{animation, bone, channel: rotation|position|scale, time, value, interpolation: linear|step|catmullrom|bezier}`；`remove_keyframe` / `remove_animation`。
- `add_locator` `{name, parent?, position, rotation?}` —— 粒子挂点（绝对模型单位）。
- `set_particle_keyframe` —— 在动画某时刻触发粒子（文件来自 `bbmodel_particle_effect`）。
- `set_model_properties` `{name?, model_identifier?, resolution?}`。

**Mesh op（仅 `free` 格式）：**
- `add_mesh` `{name, vertices: {"v1":[x,y,z],...} 或 [[x,y,z],...]（相对 origin）, faces: [{vertices:["v1","v2","v3"(,"v4")], uv?, texture?}], origin?, rotation?, parent?}`；无 uv 的面自动 Auto UV。
- `add_mesh_primitive` `{shape: cuboid|beveled_cuboid|pyramid|plane|circle|cylinder|tube|cone|sphere|icosphere|octahedron|dodecahedron|torus, diameter?, height?, sides?, detail?, minor_diameter?, minor_sides?, edge_size?, origin?, name?, parent?, texture?}` —— 与 Blockbench「Add Mesh」对话框同款几何与 UV。
- `edit_mesh` `{target, actions: [...]}`：
  - `set_vertices {vertices}` / `move_vertices {keys?, offset}` / `delete_vertices {keys}`
  - `transform {keys?, translate?, rotate?, scale?, pivot?}`
  - `add_faces {faces}` / `delete_faces` / `flip_faces`
  - `merge_vertices {distance?, keys?, in_center?}`
  - `extrude_faces {faces, distance, direction?, even_extend?}`
  - `subdivide {faces?, cuts?}` / `loop_cut {face, direction?, cuts?, offset?, spacing?}`
- `map_mesh_uv` `{target, faces?, mode: auto|project_x|project_y|project_z|explicit, uv?, scale?}`。

节点寻址：UUID 或**精确名称**。

### `bbmodel_add_texture`
从工作区 PNG 文件或 data URL 嵌入纹理，可同时指派到若干 cube/组的所有面：
```json
{ "file": "mobs/golem.bbmodel", "expected_revision": "<上次写入返回的 revision>",
  "image": "textures/golem_skin.png", "assign_to": ["body", "head"],
  "render_mode": "default", "wrap_mode": "limited" }
```
法线/高度/MER 贴图不要直接指派到面——先 `add_material`，把它们放进材质通道。

## 校验

- `bbmodel_validate` —— 静止姿态几何闸门：outliner（坏引用/重复 UUID）、degenerate（薄片/反立方体）、block_limits（Java/Bedrock 尺寸）、floating（悬空部件）、interpenetration（组间深穿插）、mirror（左右不对称）。`self_test: true` 会植入缺陷证明每个闸门有效。GeckoLib 模型自动跑 GeckoLib 规则。
- `bbmodel_validate_animations` —— 密集采样动画：骨骼存在性、关键帧时刻、ground_sink（下沉入地）、detachment（肢体脱开）。贝塞尔按线性采样，Molang 表达式跳过并列出。

## 渲染

- `bbmodel_render` —— WebGPU 出 PNG（正对 -Z 为正面）。可 `time` + `animation` 摆姿态。**首次渲染自动 npm 安装约 130MB 引擎到用户缓存目录**，需 Node ≥ 23.6 与 GPU。
- `bbmodel_contact_sheet` —— 一次多视角（如 `["top", "bottom", "left", "right", "front", "back"]` 或组合 `top_front2`）。
- 渲染只读内嵌 PNG 或工作区内链接的 PNG；根目录外纹理不渲染并警告。

## 导出 / 转换 / 启动

| 工具 | 说明 |
|---|---|
| `bbmodel_export_bedrock_geometry` | 编译 `.geo.json`（镜像 X、bb_main 等同 Blockbench 导出器约定）；只导出 cube |
| `bbmodel_export_java_block` | Java 方块/物品模型 `.json`（16 制 UV、旋转、cullface、tintindex、display）；mesh 跳过并列出 |
| `bbmodel_import_java_block` | Java 模型 `.json` → `java_block` 格式 `.bbmodel`（解析 parent、嵌纹理） |
| `bbmodel_export_modded_entity` | Java 实体模型类（Forge 1.7–1.17+、Fabric Yarn 模板） |
| `bbmodel_convert_legacy` | 转 4.10 布局副本（Blockbench 4.x 可开） |
| `bbmodel_particle_effect` / `bbmodel_particle_pack` | 写 Bedrock Snowstorm 粒子 / 打包进资源包 |
| `bbmodel_web_url` | 生成在浏览器 Blockbench Web 版打开该模型的链接（模型在 `#` 后，不上传服务器） |
| `blockbench_launch` | 启动 Blockbench 桌面版并打开文件；`wait_for_mcp_ms` 可等桌面 MCP 就绪后接着用桌面工具 |

## 行为要点

- 写入走临时文件 + 原子改名；写者间用锁文件互斥（30 秒被视作废弃并接管）。
- 被拒的写：报错说明每个违规元素怎么修；软问题以 `format_warnings` 返回但照写。
- 已在磁盘上改过的文件，Blockbench 不会自动重载——headless 编辑后要重新打开；不要两边同时编辑同一文件。
- 写出的模型带 `ai_used`/`ai_agents` 标记（AI 披露）。
