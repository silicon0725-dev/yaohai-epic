# 桌面模式（HTTP）工具速查

桌面模式驱动**正在运行的 Blockbench 应用**（单线程、单活动工程，同一时刻只有一个 agent 能用）。本插件默认只注册 headless server；要接桌面模式需手动加一个 HTTP MCP server：`http://localhost:3000/bb-mcp`（端口/路径可在 Blockbench **Settings → General → MCP Server Port / Endpoint** 改）。

前提：Blockbench 桌面版安装了上游插件 —— File → Plugins → Load Plugin from URL：
`https://jasonjgardner.github.io/blockbench-mcp-plugin/mcp.js`

也可以从 headless 侧一键拉起并等它就绪：`blockbench_launch {file:"mobs/golem.bbmodel", wait_for_mcp_ms: 15000}`（自动发现标准安装目录里的 Blockbench）。

## 常用工具（按用途分组）

- **工程/结构**：`get_capabilities`（先看格式与可用能力）、`create_project`、`list_outline`、`add_group`、`place_cube`、`modify_cube`、`remove_element`、`rename_element`、`duplicate_element`、`from_geo_json`（直接把 .geo.json 文本导入成模型）
- **造型**：`create_sphere`、`create_cylinder`、`create_polyhedron`、`extrude_mesh`、`loop_cut_mesh`、`subdivide_mesh`、`merge_mesh_vertices`、`move_mesh_vertices`、`knife_cut_cube`
- **UV/纹理**：`create_texture`、`import_texture_set`、`apply_texture`、`assign_texture_channel`、`auto_uv_mesh`、`set_cube_uv`、`get_cube_uv`、`texture_layer_management`
- **PBR**：`create_pbr_material`、`configure_material`、`list_materials`、`get_material_info`、`set_face_material_instance`
- **骨骼/动画**：`bone_rigging`、`add_armature`、`manage_keyframes`、`animation_graph_editor`、`animation_timeline`、`batch_keyframe_operations`、`create_animation`
- **绘制**：`paint_with_brush`、`paint_fill_tool`、`color_picker_tool`、`create_brush_preset`
- **视图/截图**：`set_camera_angle`、`capture_screenshot`、`capture_app_screenshot`、`create_offscreen_view`（离屏多视角截图，不影响用户视图）
- **导出**：`list_export_formats`（先列可用 codec）、`export_model`
- **撤销**：`undo`、`redo`、`get_undo_stack`、`save_checkpoint`
- **交互兜底**：`trigger_action`、`fill_dialog`、`emulate_clicks`、`risky_eval`（执行任意 JS，需在设置里开启；写插件代码时参考 vendor 仓库 prompts/ 下的 v5 安全模型文档）

## glTF 导出（Godot 路线）

```
export_model {
  codec: "gltf",
  options: {
    encoding: "binary",      // .glb；"ascii" 为 .gltf
    scale: 1,
    embed_textures: true,
    armature: true,          // group 作为骨骼导出，动画随行
    animations: true
  },
  output_path: "<绝对或工程相对路径>.glb"
}
```

先用 `list_export_formats` 确认 glTF codec 可用。Java/Bedrock codec 同理（`java_block`、`bedrock` 等）。

## 与 headless 的取舍

- 桌面工具针对"当前打开的活动工程"，没有 revision 协议；多 agent 会互相踩。
- `export_model` 的 glTF/obj 等 codec 是桌面模式独有能力（headless 只有 Bedrock/Java/modded entity 导出器）。
- headless 的 `bbmodel_validate` 几何闸门比桌面齐全，交付前仍值得跑。
- 不要同时在 headless 和桌面编辑同一个文件（Blockbench 不重载磁盘变更）。
