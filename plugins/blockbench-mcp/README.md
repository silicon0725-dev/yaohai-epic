# blockbench-mcp（ZCode 插件）

让 AI 直接用 Blockbench 做 3D 建模的 ZCode 插件。

- **MCP server（`bbmodel`，stdio）**：内嵌 [blockbench-mcp-plugin](https://github.com/jasonjgardner/blockbench-mcp-plugin) v1.10.1 的 headless 模式，不依赖 Blockbench 运行即可创建/编辑/校验/渲染 `.bbmodel`，并导出 Bedrock `.geo.json`、Java 方块模型、Java 实体类。每个会话独立进程，多 agent 可并行。
- **技能 `blockbench-modeling`**：教 AI 建模工作流——骨骼分组、立方体/网格、UV 与贴图、动画、几何校验闸门、渲染目检、导出配方（含 Godot 用 glTF 路线）。

## 目录

```
.zcode-plugin/plugin.json   插件清单
.mcp.json                   MCP server 注册（node launcher.mjs）
launcher.mjs                启动器：找 Bun → 解析模型根目录 → 拉起 headless server
skills/blockbench-modeling/ 建模技能（SKILL.md + references/）
vendor/blockbench-mcp/      上游仓库裁剪副本（GPL-3.0，含生产依赖 node_modules）
.smoke/                     端到端冒烟测试（裸 JSON-RPC 客户端）
```

## 模型根目录（`--root`）解析顺序

1. 环境变量 `BBMCP_ROOT`（可在 .mcp.json 的 env 里配）
2. 从 MCP server 进程 cwd 向上找工程标记（project.godot / .git / package.json 等）——通常是当前工作区
3. 都没有则退回插件内 `models/`

所有模型文件路径必须落在根目录内。想换根目录：改 `.mcp.json` 加 `"env": {"BBMCP_ROOT": "..."}`。

## 依赖

- Node.js（启动器）——随插件附带 Bun（vendor/node_modules/bun），无需系统安装
- 首次 `bbmodel_render` 会往 `%LOCALAPPDATA%\blockbench-mcp-headless` 下载约 130MB 渲染引擎（一次性，之后复用）
- 可选：Blockbench 桌面版 + 上游插件（HTTP 模式，`http://localhost:3000/bb-mcp`），用于 glTF 导出与 UI 驱动，见技能 references/desktop-tools.md

## 验证过的功能（v0.1.0，本机）

launcher 握手 → tools/list（23 个工具）→ `bbmodel_create` → `bbmodel_edit`（13 个操作原子提交）→ `bbmodel_validate`（0 错误）→ `bbmodel_render`（768×768 PNG，22.6% 覆盖率）→ `bbmodel_info`，全部通过（`.smoke/client.mjs` 可复跑）。

## 上游许可

vendor/ 内为 GPL-3.0 上游代码的裁剪副本（去掉了 .agents/.github/benchmarks/tests/docs/build 等开发资产），保留原 LICENSE。桌面 HTTP 模式、benchmarks 等完整能力请参考上游仓库。
