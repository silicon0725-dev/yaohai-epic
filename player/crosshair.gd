## 第一人称准星：纯绘制的四臂十字（带中心空隙），无资源依赖。
## 黑色加宽描边 + 白色细线，任何背景下可见；中心空隙
## 恰好标出屏幕正中（射线交汇点）。
class_name Crosshair
extends Control

const ARM_LENGTH := 10.0   # 单臂长（不含空隙）
const CENTER_GAP := 4.0    # 中心空隙半径
const LINE_WIDTH := 2.0
const OUTLINE_WIDTH := 4.0


func _ready() -> void:
	# 注意：必须用带 offsets 的版本。仅 set_anchors_preset 不改编移，
	# 控件实际矩形仍为 0x0，_draw 里 size 为零导致什么都画不出来。
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func _draw() -> void:
	var center := size * 0.5
	_draw_arms(center, OUTLINE_WIDTH, Color.BLACK)
	_draw_arms(center, LINE_WIDTH, Color.WHITE)


func _draw_arms(center: Vector2, width: float, color: Color) -> void:
	var inner := CENTER_GAP
	var outer := CENTER_GAP + ARM_LENGTH
	draw_line(
			Vector2(center.x - outer, center.y),
			Vector2(center.x - inner, center.y), color, width)
	draw_line(
			Vector2(center.x + inner, center.y),
			Vector2(center.x + outer, center.y), color, width)
	draw_line(
			Vector2(center.x, center.y - outer),
			Vector2(center.x, center.y - inner), color, width)
	draw_line(
			Vector2(center.x, center.y + inner),
			Vector2(center.x, center.y + outer), color, width)
