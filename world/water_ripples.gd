## 互动涟漪：Physics Mod（ocean_ripple_simulate.fsh）波动方程模拟的
## CPU 移植（mod 用 GPU 高度场 ping-pong 纹理；gl_compatibility 的
## SubViewport 无浮点渲染目标，改为 GDScript 数组模拟 + ImageTexture
## 上传，方法与参数不变）：
##
##   new = (cur*2 - prev)*阻尼 + 拉普拉斯*传播 + 冲量
##   （拉普拉斯 = 邻四格和 - 自身*4）
##
## - 96x96 高度场，窗口 16 格跟随玩家（平移重采样）；
## - 冲量：玩家（水中移动/落水）与掉落物（水中漂流）圆斑注入；
## - 纹理 RGBA8：R 通道编码高度 (r-0.5)*2，水面 shader 解码后
##   叠加顶点位移与法线扰动（mod：位移小、法线为主）。
## 纯视觉层：水位物理不读涟漪（掉落物随波起伏由言波 CPU 采样承担）。
class_name WaterRipples
extends Node

const MAP_SIZE := 96
const WINDOW := 16.0     # 模拟窗口边长（格）：玩家周围 ±8 格有涟漪
## 模拟参数（mod 常数同量级）
const DAMPING := 0.99
const PROPAGATION := 0.40
const IMPULSE_STRENGTH := 3.0
const EDGE_FADE := 6     # 边缘衰减宽度（格数，防边界反射）

var center := Vector2.ZERO

var _cur := PackedFloat32Array()
var _prev := PackedFloat32Array()
var _pending: Array[Dictionary] = []  # 本帧冲量 {pos, strength, radius}
var _shifted_center := Vector2.ZERO   # 高度场对应的窗口中心
var _texture: ImageTexture
var _image: Image
var _idle_steps := 0  # 连续静止步数（休眠判定）
const IDLE_SLEEP_STEPS := 30  # 半秒无冲量且全场静止则休眠


func _init() -> void:
	_cur.resize(MAP_SIZE * MAP_SIZE)
	_prev.resize(MAP_SIZE * MAP_SIZE)
	_image = Image.create(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)


func _ready() -> void:
	set_process_priority(100)  # 在 main._process 注入冲量之后步进


func _process(_delta: float) -> void:
	step()


## 步进一次模拟并同步纹理。每帧一步（60fps 下传播速度合适）。
## 空闲休眠：无冲量且全场能量低于阈值连续 30 步则跳步进与纹理
## 上传（曾无论玩家在哪每帧跑 96x96 波动方程 + ~37KB 纹理上传
## ——审查发现；窗口平移的重采样仍执行，冲量注入即唤醒）。
func step() -> void:
	var n := MAP_SIZE
	# 窗口平移：把高度场按中心位移重采样（最近邻，一帧位移 <1 格）
	var shift := center - _shifted_center
	if absf(shift.x) > 0.001 or absf(shift.y) > 0.001:
		var cell := WINDOW / float(n)  # 每格世界尺寸
		var dx := int(round(shift.x / cell))
		var dy := int(round(shift.y / cell))
		if dx != 0 or dy != 0:
			_resample_shifted(dx, dy)
			_shifted_center += Vector2(dx, dy) * cell

	# 冲量：世界坐标 -> 格坐标，圆斑注入 cur（有冲量立即唤醒）
	if not _pending.is_empty():
		_idle_steps = 0
	for src in _pending:
		_add_impulse_cell(src["pos"], src["strength"], src["radius"])
	_pending.clear()

	if _idle_steps >= IDLE_SLEEP_STEPS:
		return  # 休眠：无波可传

	# 波动方程：new = (cur*2-prev)*damp + laplacian*prop
	var next := PackedFloat32Array()
	next.resize(n * n)
	var cell_size := WINDOW / float(n)
	var energy := 0.0
	for y in n:
		var edge_y := minf(y, n - 1 - y) * cell_size
		for x in n:
			var i := y * n + x
			var cur := _cur[i]
			var lap := -cur * 4.0
			if x > 0:
				lap += _cur[i - 1]
			if x < n - 1:
				lap += _cur[i + 1]
			if y > 0:
				lap += _cur[i - n]
			if y < n - 1:
				lap += _cur[i + n]
			var v := (cur * 2.0 - _prev[i]) * DAMPING + lap * PROPAGATION
			# 边缘衰减（防边界反射）：距边距离封顶 EDGE_FADE（格），
			# 中心区（>6 格）不衰减。注意不能把封顶值写成 1.0——
			# 那会让全场每步乘 <=1/6，能量 8 步衰减百万倍
			var edge := minf(minf(minf(x, n - 1 - x) * cell_size, edge_y),
					float(EDGE_FADE))
			v *= edge / float(EDGE_FADE)
			next[i] = clampf(v, -1.0, 1.0)
			energy += absf(v)
	_prev = _cur
	_cur = next

	# 休眠判定：全场能量近零（阻尼终将归零）则累计静止步数
	_idle_steps = _idle_steps + 1 if energy < 0.0001 else 0

	# 同步纹理：R 编码高度（水面 shader 解码 (r-0.5)*2）
	var data := _image.get_data()
	var di := 0
	for i in n * n:
		data[di] = int(clampf((_cur[i] * 0.5 + 0.5) * 255.0, 0.0, 255.0))
		data[di + 1] = 255
		data[di + 2] = 255
		data[di + 3] = 255
		di += 4
	_image.set_data(n, n, false, Image.FORMAT_RGBA8, data)
	_texture.update(_image)


## 注入扰动（世界 xz、强度 0..1、半径格）。调用方：玩家/掉落物。
func add_impulse(world_xz: Vector2, strength: float, radius: float) -> void:
	_pending.append({"pos": world_xz, "strength": strength, "radius": radius})


## 涟漪纹理（水面材质采样）。
func texture() -> ImageTexture:
	return _texture


## 高度场实际中心（与冲量注入同源；水面 shader 采样用它而非玩家
## 实时位置，否则平移重采样的量化延迟会造成采样偏移）。
func texture_center() -> Vector2:
	return _shifted_center


## 世界 xz -> 高度场格坐标（越界返回 (-1,-1)）。
func _world_to_cell(world_xz: Vector2) -> Vector2i:
	var local := (world_xz - _shifted_center) / WINDOW + Vector2(0.5, 0.5)
	var c := Vector2i(int(local.x * MAP_SIZE), int(local.y * MAP_SIZE))
	if c.x < 0 or c.y < 0 or c.x >= MAP_SIZE or c.y >= MAP_SIZE:
		return Vector2i(-1, -1)
	return c


func _add_impulse_cell(world_xz: Vector2, strength: float, radius: float) -> void:
	var c := _world_to_cell(world_xz)
	if c.x < 0:
		return
	var cell := WINDOW / float(MAP_SIZE)
	var r_cells := maxi(int(radius / cell), 1)
	for dy in range(-r_cells, r_cells + 1):
		var y := c.y + dy
		if y < 0 or y >= MAP_SIZE:
			continue
		for dx in range(-r_cells, r_cells + 1):
			var x := c.x + dx
			if x < 0 or x >= MAP_SIZE:
				continue
			var d := Vector2(dx, dy).length() * cell / maxf(radius, 0.01)
			_cur[y * MAP_SIZE + x] += strength * IMPULSE_STRENGTH \
					* exp(-d * d)


## 窗口平移重采样：整场按格偏移搬移（空出的边缘补 0）。
func _resample_shifted(dx: int, dy: int) -> void:
	var n := MAP_SIZE
	var moved := _shift_array(_cur, dx, dy)
	var moved_prev := _shift_array(_prev, dx, dy)
	_cur = moved
	_prev = moved_prev


static func _shift_array(src: PackedFloat32Array, dx: int, dy: int) -> PackedFloat32Array:
	var n := MAP_SIZE
	var out := PackedFloat32Array()
	out.resize(n * n)
	for y in n:
		var sy := y - dy
		if sy < 0 or sy >= n:
			continue
		for x in n:
			var sx := x - dx
			if sx < 0 or sx >= n:
				continue
			out[y * n + x] = src[sy * n + sx]
	return out
