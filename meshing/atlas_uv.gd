## 图集 UV 计算（开发文档 §7.1）。
## 纹理渗色防范：当前 MVP 使用 Nearest 过滤且关闭 mipmap，
## 因此 inset 取 0；一旦引入线性过滤或 mipmap，必须启用边缘收缩、
## 修改 mipmap 策略或改用纹理数组，并用真实纹理尺寸测试边缘。
class_name AtlasUV
extends RefCounted


## tile 在图集中的归一化 UV 矩形。tile 原点为左上角，以格计数。
static func tile_rect(tile: Vector2i, atlas_cols: int, atlas_rows: int) -> Rect2:
	return Rect2(
		Vector2(float(tile.x) / atlas_cols, float(tile.y) / atlas_rows),
		Vector2(1.0 / atlas_cols, 1.0 / atlas_rows)
	)


## 将单位角点 UV（0~1）映射进图集矩形。
## inset 为边缘收缩比例（0.0 ~ 0.5），用于防止过滤渗色。
static func corner_uv(rect: Rect2, corner: Vector2, inset := 0.0) -> Vector2:
	var margin := Vector2(rect.size.x * inset, rect.size.y * inset)
	return Vector2(
		clampf(
			rect.position.x + margin.x + corner.x * (rect.size.x - 2.0 * margin.x),
			0.0, 1.0
		),
		clampf(
			rect.position.y + margin.y + corner.y * (rect.size.y - 2.0 * margin.y),
			0.0, 1.0
		)
	)
