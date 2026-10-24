## 光源管理器（光照阶段 1）：全部局部光源的统一入口。
## - 注册制：游戏逻辑不得直接创建 OmniLight3D/SpotLight3D 节点，
##   一律走 add_light/remove_light
## - 三态分离：enabled（游戏逻辑开关）/ in_range（距离裁剪，调度器判）/
##   shadow_requested（游戏逻辑需求）与 shadow_granted（调度器授予资格）
##   分离，阶段 2 体素光照可据此接管单个光源的阴影实现
## - 距离裁剪 only：视锥裁剪（影响球 vs frustum 相交）推迟到阶段 2；
##   进出阈值各留滞回带防边界闪烁
## - 阴影预算：同一时刻允许带动态阴影的局部光源数量上限（非质量保证）；
##   确定性排序（priority 降序→距离升序→id 升序）+ 滞回等效加成，
##   已授权灯仅在自身失格或挑战者明显更优时被替换
## - set_light_position 立即写节点：移动光源不等调度器（无跟随延迟）
class_name LightManager
extends Node3D

## 默认阴影预算：同刻动态阴影局部光源上限
const DEFAULT_SHADOW_BUDGET := 2
## 默认距离裁剪半径（米）
const DEFAULT_MAX_DISTANCE := 64.0
## 默认调度节流间隔（秒）
const DEFAULT_UPDATE_INTERVAL := 0.25
## 距离裁剪滞回带：出界阈值 = max_distance * (1 + RANGE_HYST)
const RANGE_HYST := 0.10
## 阴影滞回等效加成（米）：已授权灯的排序距离减去该值，
## 挑战者需再近这么多才夺走资格
const DEFAULT_HYST_MARGIN := 4.0

## 全部注册光源：id -> LightRecord
## {id, type, config, node, enabled, in_range, shadow_requested,
##  shadow_granted, last_shadow_update}
var _records := {}
var _next_id := 1
## 灯节点统一挂载点（恒等变换；cfg.position 即世界坐标）
var light_root: Node3D
var _shadow_budget := DEFAULT_SHADOW_BUDGET
var _max_distance := DEFAULT_MAX_DISTANCE
var _update_interval := DEFAULT_UPDATE_INTERVAL
var _hyst_margin := DEFAULT_HYST_MARGIN
var _accum := 0.0
## 调度参照相机；null 时用 probe_position（测试/无相机场景）
var camera: Camera3D
## camera 为空时的参照位置
var probe_position := Vector3.ZERO


func _ready() -> void:
	_ensure_root()


## 惰性建挂载点：测试里不进场景树（无 _ready）也能直接 add_light
func _ensure_root() -> void:
	if light_root != null:
		return
	light_root = Node3D.new()
	light_root.name = "LightRoot"
	add_child(light_root)


func _process(delta: float) -> void:
	_accum += delta
	if _accum >= _update_interval:
		_accum = 0.0
		_evaluate()


func configure(cfg: Dictionary) -> void:
	if cfg.has("shadow_budget"):
		_shadow_budget = maxi(0, int(cfg.shadow_budget))
	if cfg.has("max_distance"):
		_max_distance = maxf(1.0, float(cfg.max_distance))
	if cfg.has("update_interval"):
		_update_interval = maxf(0.01, float(cfg.update_interval))
	if cfg.has("hyst_margin"):
		_hyst_margin = maxf(0.0, float(cfg.hyst_margin))
	_evaluate()


## 注册光源，返回 id（单调递增不复用）。cfg 键：
##   type: "omni"|"spot"（必填）
##   position: Vector3 世界坐标（必填）
##   color: Color（默认白）   energy: float（默认 1.0）
##   range: float（默认 8.0） attenuation: float（默认 1.0）
##   priority: int（默认 0，大者优先拿阴影预算）
##   shadow_requested: bool（默认 false——普通局部光源默认无阴影）
##   spot 专有：direction: Vector3 世界空间照射方向（默认 -Z），
##             angle: float 锥角弧度（默认 PI/6）
func add_light(cfg: Dictionary) -> int:
	_ensure_root()
	var type := str(cfg.get("type", ""))
	if type != "omni" and type != "spot":
		push_error("LightManager.add_light: type 必须为 omni/spot，得到 %s" % type)
		return -1
	var pos: Vector3 = cfg.get("position", Vector3.ZERO)
	var node: Light3D
	if type == "omni":
		var omni := OmniLight3D.new()
		omni.omni_range = float(cfg.get("range", 8.0))
		omni.omni_attenuation = float(cfg.get("attenuation", 1.0))
		node = omni
	else:
		var spot := SpotLight3D.new()
		spot.spot_range = float(cfg.get("range", 8.0))
		spot.spot_attenuation = float(cfg.get("attenuation", 1.0))
		# API 用弧度（与 Godot 3D 数学一致）；spot_angle 属性是度
		#（默认 45 度）——曾按弧度直传 0.7，锥角变 0.7° 激光点不发光
		spot.spot_angle = rad_to_deg(float(cfg.get("angle", PI / 6.0)))
		node = spot
	node.light_color = cfg.get("color", Color.WHITE)
	node.light_energy = float(cfg.get("energy", 1.0))
	node.shadow_enabled = false
	light_root.add_child(node)
	_set_node_pos(node, pos)
	if type == "spot":
		var dir: Vector3 = cfg.get("direction", Vector3.FORWARD)
		if dir.length_squared() > 0.000001:
			# -Z 对准照射方向；方向接近竖直时换上向轴避免退化。
			# 用 Basis.looking_at 而非 look_at：后者要求节点在树内
			var d := dir.normalized()
			var up := Vector3.UP
			if absf(d.dot(up)) > 0.999:
				up = Vector3.RIGHT
			node.basis = Basis.looking_at(d, up)
	var id := _next_id
	_next_id += 1
	_records[id] = {
		"id": id,
		"type": type,
		"config": cfg.duplicate(),
		"node": node,
		"enabled": true,
		"in_range": false,
		"shadow_requested": bool(cfg.get("shadow_requested", false)),
		"shadow_granted": false,
		"last_shadow_update": 0.0,
	}
	_evaluate()
	return id


## 注销并释放节点；阴影预算随记录移除即时回收。
func remove_light(id: int) -> void:
	var rec: Dictionary = _records.get(id, {})
	if rec.is_empty():
		return
	var node: Light3D = rec.node
	if is_instance_valid(node):
		# 树内走帧末释放；测试不进树时 queue_free 永不结算，直接 free
		if node.is_inside_tree():
			node.queue_free()
		else:
			node.free()
	_records.erase(id)
	_evaluate()


## 立即写节点位置（不等调度器）；阴影资格在下次求值时随新位置重排。
func set_light_position(id: int, pos: Vector3) -> void:
	var rec: Dictionary = _records.get(id, {})
	if rec.is_empty():
		return
	var node: Light3D = rec.node
	if is_instance_valid(node):
		_set_node_pos(node, pos)
	rec.config["position"] = pos


func set_light_enabled(id: int, on: bool) -> void:
	var rec: Dictionary = _records.get(id, {})
	if rec.is_empty() or rec.enabled == on:
		return
	rec.enabled = on
	_evaluate()


func set_light_shadow_requested(id: int, req: bool) -> void:
	var rec: Dictionary = _records.get(id, {})
	if rec.is_empty() or rec.shadow_requested == req:
		return
	rec.shadow_requested = req
	_evaluate()


## {registered: 注册总数, active: enabled 且 in_range,
##  shadowed: 当前持有阴影资格}
func get_stats() -> Dictionary:
	var active := 0
	var shadowed := 0
	for id in _records:
		var rec: Dictionary = _records[id]
		if rec.enabled and rec.in_range:
			active += 1
		if rec.shadow_granted:
			shadowed += 1
	return {
		"registered": _records.size(),
		"active": active,
		"shadowed": shadowed,
	}


## 调度核心（纯逻辑，可被单元测试直接驱动）：
## 1) 距离裁剪（进出滞回带）；2) 阴影预算分配（确定性排序 + 滞回）。
func _evaluate() -> void:
	var cam_pos := probe_position
	if camera != null and is_instance_valid(camera):
		cam_pos = camera.global_position
	var exit_dist := _max_distance * (1.0 + RANGE_HYST)
	var sorted_ids := _records.keys()
	sorted_ids.sort()
	# 距离裁剪：先逐灯更新 in_range 并回收出界/禁用灯的阴影资格
	for id in sorted_ids:
		var rec: Dictionary = _records[id]
		var node: Light3D = rec.node
		if not is_instance_valid(node):
			_records.erase(id)
			continue
		if not rec.enabled:
			rec.in_range = false
		else:
			var d := _get_node_pos(node).distance_to(cam_pos)
			var thresh := exit_dist if rec.in_range else _max_distance
			rec.in_range = d <= thresh
		node.visible = rec.enabled and rec.in_range
		if not (rec.enabled and rec.in_range):
			_set_shadow(rec, false)
	# 阴影预算：候选 = enabled && in_range && shadow_requested；
	# 排序键：priority 降序 → (距离 - 滞回加成) 升序 → id 升序。
	# 先定授权集合，再对全部记录统一结算——退出候选的灯（撤回请求/
	# 禁用/越界）旧授权必须回收
	var candidates: Array = []
	for id in sorted_ids:
		var rec: Dictionary = _records[id]
		if rec.enabled and rec.in_range and rec.shadow_requested:
			var d: float = _get_node_pos(rec.node).distance_to(cam_pos)
			if rec.shadow_granted:
				d -= _hyst_margin
			candidates.append([-int(rec.config.get("priority", 0)), d, id])
	candidates.sort()
	var grants := {}
	for i in mini(_shadow_budget, candidates.size()):
		grants[candidates[i][2]] = true
	for id in sorted_ids:
		_set_shadow(_records[id], grants.has(id))


func _set_shadow(rec: Dictionary, granted: bool) -> void:
	if rec.shadow_granted == granted:
		return
	rec.shadow_granted = granted
	rec.last_shadow_update = Time.get_ticks_msec() / 1000.0
	var node: Light3D = rec.node
	if is_instance_valid(node):
		node.shadow_enabled = granted


## 位置读写：树内用世界坐标；测试不进树时 global_position 不可用，
## 退化用本地坐标（LightRoot 恒等变换，两者等价——类级不变量）
func _get_node_pos(node: Node3D) -> Vector3:
	if node.is_inside_tree():
		return node.global_position
	return node.position


func _set_node_pos(node: Node3D, pos: Vector3) -> void:
	if node.is_inside_tree():
		node.global_position = pos
	else:
		node.position = pos
