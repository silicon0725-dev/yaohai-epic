# 角色模型资源（YSM 风格）

来源：ModernYSM（MIT）内置模型包 builtin/default 与 builtin/misc/3_default_boy，
两包的 ysm.json metadata 均声明 `license: CC 0`（作者：哥斯拉 等，见 ysm.json）。

- `ysm_default/` — 默认模型（女版，64 骨骼：长发/裙摆/睫毛等细骨骼）
- `ysm_default_boy/` — 默认男版模型
- 只拷贝了主模型（main/arm）、主动画、贴图与语言文件；投射物/载具模型未拷。

**红线**：不要把其它第三方 YSM 模型包（尤其 `builtin/wine_fox`，CC BY-NC-SA 4.0）
拷进本仓库；Epic Fight 的动画资产（animations/animmodels 目录）为 All-Rights-Reserved，
禁止拷贝——动作数据后续用自研程序化动画或自研录制替代。
