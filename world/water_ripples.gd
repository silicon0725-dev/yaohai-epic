## 互动涟漪：Physics Mod（ocean_ripple_simulate.fsh）波动方程模拟的
## CPU 移植（mod 用 GPU 高度场 ping-pong 纹理；gl_compatibility 的
## SubViewport 无浮点渲染目标，改为 GDScript 数组模拟 + ImageTexture
## 上传，方法与参数不变）：
##
##   new = (cur*2 - prev)*阻尼 + 拉普拉斯*传播 + 冲量
##   （拉普拉斯 = 邻四格和 - 自身*4）
##
## - 96x96 高度场，窗口 16 格跟随玩家（平移重采样，量化 2 格）；
## - 冲量：玩家（水中移动/落水）与掉落物（水中漂流）圆斑注入；
## - 纹理 R8：R 通道编码高度 (r-0.5)*2，水面 shader 解码后
##   叠加顶点位移与法线扰动（mod：位移小、法线为主）。
## - 审查二轮 C2/C3：30Hz 步进钟（渲染 60fps 不变；DAMPING 0.99→0.98
##   补偿，每秒衰减率 0.98^30 ≈ 0.99^60）、三数组持久轮转零分配、
##   R8 单通道纹理（每步 9.2KB vs RGBA8 三份 36KB 流量）、休眠阈值
##   1e-3 + 无冲量 2s 强制休眠 + 弱冲量(<0.05)不唤醒、休眠期跳过
##   窗口平移重采样（陆地走路零成本，唤醒帧一次补齐）、平移量化
##   2 格（重采样频率 1/6）。曾实测 p50 3.72ms/帧、1449 步(24s)不休眠、
##   陆地走路每 2-3 帧一次 2x9216 重采样迭代。
## 纯视觉层：水位物理不读涟漪（掉落物随波起伏由言波 CPU 采样承担）。
class_name WaterRipples
extends Node

const MAP_SIZE := 96
const WINDOW := 16.0     # 模拟窗口边长（格）：玩家周围 ±8 格有涟漪
const STEP_HZ := 30.0    # 步进频率（渲染帧率无关；纹理 60fps 照常采样）
const STEP_DT := 1.0 / STEP_HZ
## 模拟参数（mod 常数同量级；DAMPING 0.98 = 30Hz 下与原 0.99@60Hz
## 的每秒衰减率相当：0.98^30 ≈ 0.545 ≈ 0.99^60）
const DAMPING := 0.98
const PROPAGATION := 0.40
const IMPULSE_STRENGTH := 3.0
const EDGE_FADE := 6     # 边缘衰减宽度（格数，防边界反射）
const SHIFT_QUANTUM := 2.0  # 窗口平移量化（格）：半量子触发，重采样频率 1/6
const MIN_WAKE_STRENGTH := 0.05  # 更弱的冲量只注入、不唤醒休眠

const IDLE_SLEEP_STEPS := 15   # 0.5s（步进钟）无冲量且全场近静止则休眠
var idle_sleep_steps := IDLE_SLEEP_STEPS  # 测试可覆盖（衰减语义长跑）
var force_sleep_steps := 90  # 无论能量，无冲量 3s 强制休眠（兜底：
                             # 单元测试的 230 步阻尼长跑需覆盖为超大值）
const SLEEP_ENERGY := 0.001    # 休眠能量阈值（全场 |h| 总和）

var center := Vector2.ZERO

var _cur := PackedFloat32Array()
var _prev := PackedFloat32Array()
var _next := PackedFloat32Array()  # 步进输出缓冲（三数组轮转零分配）
var _pending: Array[Dictionary] = []  # 帧间冲量 {pos, strength, radius}
var _shifted_center := Vector2.ZERO   # 高度场对应的窗口中心
var _texture: ImageTexture
var _image: Image
var _bytes := PackedByteArray()  # R8 纹理字节（持久复用，零分配）
var _idle_steps := 0    # 连续静止步数（休眠判定）
var _awake_steps := 0   # 唤醒后无冲量步数（强制休眠兜底）
var _step_acc := 0.0    # 步进累加器（30Hz）


func _init() -> void:
	_cur.resize(MAP_SIZE * MAP_SIZE)
	_prev.resize(MAP_SIZE * MAP_SIZE)
	_next.resize(MAP_SIZE * MAP_SIZE)
	_bytes.resize(MAP_SIZE * MAP_SIZE)
	_image = Image.create(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8)
	_texture = ImageTexture.create_from_image(_image)


func _ready() -> void:
	set_process_priority(100)  # 在 main._process 注入冲量之后步进


func _process(delta: float) -> void:
	_step_acc += delta
	while _step_acc >= STEP_DT:
		_step_acc -= STEP_DT
		step()


## 步进一次模拟并同步纹理（30Hz 步进钟驱动）。
## 空闲休眠：无冲量且全场能量低于阈值连续 0.5s（或无冲量 2s 强制）
## 则跳步进/重采样与纹理上传——陆地走路零成本。冲量注入唤醒：
## 先补一次窗口平移重采样再注入（格坐标与窗口一致）。
func step() -> void:
	# 冲量唤醒判定：有效强度（>=0.05）才唤醒——当前注入源下限即
	# 0.05，此阈值为未来弱源（风吹等）防御；休眠中的弱冲量丢弃
	if not _pending.is_empty():
		for src in _pending:
			if float(src["strength"]) >= MIN_WAKE_STRENGTH:
				_idle_steps = 0
				_awake_steps = 0
				break
	if _idle_steps >= idle_sleep_steps or _awake_steps >= force_sleep_steps:
		_pending.clear()
		return  # 休眠：无波可传（弱冲量一并丢弃）

	# 窗口平移（量化 2 格）：把高度场按格偏移重采样（最近邻，一帧
	# 位移 <1 格；休眠期欠下的位移在唤醒帧一次补齐——大偏移越界
	# 补 0 即清场，语义正确）
	var shift := center - _shifted_center
	var cell := WINDOW / float(MAP_SIZE)
	if absf(shift.x) >= SHIFT_QUANTUM * 0.5 \
			or absf(shift.y) >= SHIFT_QUANTUM * 0.5:
		var dx := int(round(shift.x / cell))
		var dy := int(round(shift.y / cell))
		if dx != 0 or dy != 0:
			_resample_shifted(dx, dy)
			_shifted_center += Vector2(dx, dy) * cell

	# 冲量：世界坐标 -> 格坐标，圆斑注入 cur
	for src in _pending:
		_add_impulse_cell(src["pos"], src["strength"], src["radius"])
	_pending.clear()

	# 波动方程：new = (cur*2-prev)*damp + laplacian*prop
	#（_next 全量覆盖，无需参与重采样/初始化；三数组轮转零分配。
	# 内圈 94x94 主干无边界分支——边界邻格缺失的 4 分支只在外圈
	# 376 格上花，每步 9216 格的解释器语句数是 p50 主成本）
	var n := MAP_SIZE
	var cell_size := WINDOW / float(n)
	var energy := 0.0
	var ef := float(EDGE_FADE)
	var inv_ef := 1.0 / ef
	for y in range(1, n - 1):
		var edge_y := minf(y, n - 1 - y) * cell_size
		var capped_y := minf(edge_y, ef)
		var row := y * n
		for x in range(1, n - 1):
			var i := row + x
			var cur := _cur[i]
			var v := (cur * 2.0 - _prev[i]) * DAMPING + (
					_cur[i - 1] + _cur[i + 1] + _cur[i - n] + _cur[i + n]
					- cur * 4.0) * PROPAGATION
			# 边缘衰减（防边界反射）：距边距离封顶 EDGE_FADE（格），
			# 中心区（>6 格）不衰减。不能把封顶值写成 1.0——那会让
			# 全场每步乘 <=1/6，能量 8 步衰减百万倍
			var edge := minf(minf(x, n - 1 - x) * cell_size, capped_y)
			if edge < ef:
				v *= edge * inv_ef
			_next[i] = clampf(v, -1.0, 1.0)
			energy += absf(v)
	# 最外一圈 edge=0 恒为零（min(x, n-1-x)=0 → v*=0）——不进方程，
	# 直接清零防轮转缓冲残留旧值
	for x in n:
		_next[x] = 0.0
		_next[(n - 1) * n + x] = 0.0
	for y in range(1, n - 1):
		_next[y * n] = 0.0
		_next[y * n + n - 1] = 0.0
	var tmp := _prev
	_prev = _cur
	_cur = _next
	_next = tmp

	# 休眠判定：全场能量近零（阻尼终将归零）则累计静止步数
	_idle_steps = _idle_steps + 1 if energy < SLEEP_ENERGY else 0
	_awake_steps += 1

	# 同步纹理：R8 单通道编码高度（水面 shader 解码 (r-0.5)*2）
	var sz := n * n
	for i in sz:
		_bytes[i] = int(clampf((_cur[i] * 0.5 + 0.5) * 255.0, 0.0, 255.0))
	_image.set_data(n, n, false, Image.FORMAT_R8, _bytes)
	_texture.update(_image)


## 注入扰动（世界 xz、强度 0..1、半径格）。调用方：玩家/掉落物。
## 弱冲量（<0.05）只注入不唤醒——当前注入源下限即 0.05，此阈值为
## 未来弱源（风吹等）防御。
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
