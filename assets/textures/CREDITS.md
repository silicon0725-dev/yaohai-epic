# 材质来源与许可证（开发文档 §7.3）

当前内置贴图（assets/textures/*.png）来自 Conquest 材质包；
此前的开源贴图组完整备份在 assets/textures/open_cc0_backup/。

## Conquest（当前使用 — 注意：不可再分发）

- 来源: 用户提供的 Conquest_1.21.11.zip（官方发布渠道 Modrinth:
  https://modrinth.com/resourcepack/conquest_ ，"V1.0 for MC 1.21.11"）
- 许可: 包内未附带许可文本。Conquest 允许个人游玩使用，
  **不允许将贴图再分发或打包进独立游戏发布**（与 §7.3 的商用标准不符）。
- 下载/安装日期: 2026-10-18
- 使用文件（原始名 -> 本项目 tile，均来自 assets/minecraft/textures/block/，
  32x32 像素，项目 TILE_SIZE 已随包调整为 32）:
  - grass_block_top.png -> grass_top
  - grass_block_side.png -> grass_side
  - dirt.png -> dirt
  - stone.png -> stone
  - bedrock.png -> bedrock
  - oak_log_top.png -> log_top
  - oak_log.png -> log_side
  - oak_planks.png -> planks
  - cobblestone.png -> cobblestone
  - bricks.png -> bricks
  - sand.png -> sand
  - sandstone.png -> sandstone
  - gravel.png -> gravel
  - coal_ore.png -> coal_ore
  - iron_ore.png -> iron_ore
- **发布前动作**: 若本项目需要对外分发，将 open_cc0_backup/ 内的
  同名文件复制回上级目录即可整体换回可商用贴图组。

## Malcolm Riley — unused-textures（CC BY 4.0，现为备份组）

- 来源: https://github.com/malcolmriley/unused-textures
- 许可: CC BY 4.0 International（完整文本见 LICENSE-malcolmriley-ccby40.txt）
- 下载日期: 2026-10-18
- 使用文件（原始名 -> 本项目 tile）:
  - earth_loam_grassy_top.png -> grass_top
  - earth_loam_grassy_sides.png -> grass_side
  - earth_loam.png -> dirt
  - concrete_plain.png -> stone
  - meteorite.png -> bedrock
  - stone_tiles_small.png -> cobblestone
  - sturdy_bricks.png -> bricks
  - contaminated_sand_1.png -> sand
  - alabaster_plain.png -> sandstone
  - gravel_packedflint.png -> gravel
  - ore_stone_anthracite.png -> coal_ore
  - ore_stone_brimstone.png -> iron_ore

## Auseawesome — Minecraft-Textures（CC0 1.0）

- 来源: https://github.com/Auseawesome/Minecraft-Textures
- 许可: CC0 1.0 Universal（无署名要求，此处仍记录来源）
- 下载日期: 2026-10-18
- 使用文件（原始路径 -> 本项目 tile）:
  - blocks/wood/baobab/log_top.png -> log_top
  - blocks/wood/baobab/log.png -> log_side
  - blocks/wood/baobab/planks.png -> planks

## 程序化占位贴图

未覆盖的 tile 由 presentation/texture_atlas_loader.gd 以固定种子
程序化生成（同样可自由使用）。当前内置贴图已覆盖全部 15 个 tile，
程序化方案保留为缺图回退与测试基线。
