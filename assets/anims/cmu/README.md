# CMU Mocap 精选动作（转换后 Clip）

数据来源：Carnegie Mellon University Graphics Lab Motion Capture Database
（cgspeed Daz-friendly BVH 转换版），原始数据 `free for all uses`。

按 CMU 官方要求署名：

> This motion data is from the Carnegie Mellon University Graphics Lab
> Motion Capture Database, created with funding from NSF EIA-0196217.

- `box_combo.txt`：13_17（boxing）1.5–3.5s 切片，30fps 重定向到本引擎
  canonical 20 关节（转换工具 `debug/export_bvh_clips.gd`）。
- 用户可自放其他 `.bvh` 到 `user://anim_bvh/` 运行时自动加载（同名覆盖）。
