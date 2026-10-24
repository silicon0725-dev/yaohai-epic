@icon("res://addons/bounded_buoyancy/icon_compartment.svg")
class_name BoundedBuoyancyCompartment
extends Node3D
## A space inside a BoundedBuoyancyBody that can flood: a ship's hold, a bow or stern section, a
## tank, the inside of a barrel or a boat.
##
## Add it under the body and set its size: it is a box centred on this node, inside the body's
## shape. Give it holes (in the inspector, or from code with add_hole(), say where a cannonball hit)
## and water pours in through those below the waterline, faster the deeper they are, by the orifice
## law Q = C A √(2 g Δh), Δh the difference between the water's depth outside and inside at the hole;
## holes above the water let flood water drain out again. The water inside stays level whichever way
## the body leans. Its weight acts at its own centre, which moves to the low side as the body leans
## (the free-surface effect), so a holed ship settles lower, lists toward its flooded side, and sinks
## or capsizes when it has taken in more than its reserve of buoyancy will carry. The body's hull keeps
## its buoyancy: the flood water is weight it carries, as in the added-weight method of naval
## architecture.
##
## Pumps (pump_rate) take water out again. Set flood_volume from code to start a compartment part
## full, or to fill or empty it at once. The compartment is taken to be vented, as a ship's holds are
## through their hatches: air gets out as water comes in.

## Width (X), height (Y) and length (Z) of the space, in metres. Keep it inside the body's shape.
@export var size: Vector3 = Vector3(1.0, 1.0, 1.0):
	set(value):
		size = value.max(Vector3(0.001, 0.001, 0.001))
## The holes, each as (x, y, z, area): its position in this compartment's own coordinates, on or
## inside the box, and its area in m² (a cannonball of 15 cm makes about 0.018 m²).
@export var holes: Array[Vector4] = []
## Discharge coefficient of the holes: 0.6 for a sharp-edged hole, up to about 0.95 for a smooth one.
@export_range(0.1, 1.0, 0.01) var discharge_coefficient: float = 0.6
## Water the pumps take out, in m³ per second, while there is water to take.
@export_range(0.0, 100.0, 0.001, "or_greater", "suffix:m³/s") var pump_rate: float = 0.0
## Water in the compartment now, in m³.
@export_range(0.0, 100000.0, 0.001, "or_greater", "suffix:m³") var flood_volume: float = 0.0:
	set(value):
		flood_volume = maxf(value, 0.0)

## Volume of the space (m³), with this node's scale.
var capacity: float:
	get:
		var v := size.x * size.y * size.z
		return v * absf(global_basis.determinant()) if is_inside_tree() else v
## Fraction of the space full of water, 0 to 1.
var fill_fraction: float:
	get:
		var full := capacity
		return clampf(flood_volume / full, 0.0, 1.0) if full > 0.0 else 0.0
## Flow of water in through the holes over the last step, m³/s (negative when it drains out).
var inflow: float = 0.0
## Height of the water inside (world Y) over the last step.
var water_level: float = 0.0
## Centre of the water inside (world) over the last step.
var water_centre: Vector3 = Vector3.ZERO

var _body: Node = null

# The box's twelve faces as corner indices, wound so that each faces outward. Corner i is at
# (±x, ±y, ±z) with bit 0 for +x, bit 1 for +y and bit 2 for +z.
const _FACES := [0, 2, 3, 0, 3, 1,   4, 5, 7, 4, 7, 6,   0, 1, 5, 0, 5, 4,
	2, 6, 7, 2, 7, 3,   0, 4, 6, 0, 6, 2,   1, 3, 7, 1, 7, 5]


func _enter_tree() -> void:
	var p := get_parent()
	while p:
		if p.has_method(&"_add_compartment"):
			_body = p
			p._add_compartment(self)
			return
		p = p.get_parent()


func _exit_tree() -> void:
	if _body and is_instance_valid(_body):
		_body._remove_compartment(self)
	_body = null


## Make a hole of `area` m² at the world point `at` (moved onto the box if it lies outside it).
## Returns its index in holes.
func add_hole(at: Vector3, area: float) -> int:
	var l := to_local(at)
	var h := 0.5 * size
	l = l.clamp(-h, h)
	holes.append(Vector4(l.x, l.y, l.z, maxf(area, 0.0)))
	return holes.size() - 1


## Close every hole.
func patch_holes() -> void:
	holes.clear()


## World positions of the box's eight corners, for the box at `xf` (world). A mirrored box (a
## negative scale) has its corners taken in mirrored order, so its faces still wind outward.
func corners(xf: Transform3D) -> PackedVector3Array:
	var h := 0.5 * size
	if xf.basis.determinant() < 0.0:
		h.x = -h.x
	var c := PackedVector3Array()
	c.resize(8)
	for i in 8:
		c[i] = xf * Vector3(h.x if i & 1 else -h.x, h.y if i & 2 else -h.y, h.z if i & 4 else -h.z)
	return c


## Volume of the box with corners `c` (world) below the world height `level`, and the first moment
## of that volume: Vector4(volume, moment x 4). Its centre is (y, z, w) / (4 x volume).
static func below(c: PackedVector3Array, level: float) -> Vector4:
	var lo := INF
	var hi := -INF
	var mid := Vector3.ZERO
	for p in c:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
		mid += p
	mid /= 8.0
	if level <= lo:
		return Vector4.ZERO
	var p := Vector3(mid.x, level, mid.z)
	var vol := 0.0
	var m := Vector3.ZERO
	var i := 0
	while i < 36:
		var a: Vector3 = c[_FACES[i]]
		var b: Vector3 = c[_FACES[i + 1]]
		var d: Vector3 = c[_FACES[i + 2]]
		i += 3
		var da := level - a.y
		var db := level - b.y
		var dd := level - d.y
		var under := int(da > 0.0) + int(db > 0.0) + int(dd > 0.0)
		if under == 0:
			continue
		if under == 3:
			var t3 := (a - p).dot((b - p).cross(d - p)) / 6.0
			vol += t3
			m += t3 * (p + a + b + d)
			continue
		# Turn the triangle (keeping its winding) so that the odd vertex out comes first.
		if (under == 1 and db > 0.0) or (under == 2 and db <= 0.0):
			var tv := a; a = b; b = d; d = tv
			var td := da; da = db; db = dd; dd = td
		elif (under == 1 and dd > 0.0) or (under == 2 and dd <= 0.0):
			var tv := d; d = b; b = a; a = tv
			var td := dd; dd = db; db = da; da = td
		var ab := a + (b - a) * (da / (da - db))
		var da2 := d + (a - d) * (dd / (dd - da))
		if under == 1:
			var t1 := (a - p).dot((ab - p).cross(da2 - p)) / 6.0
			vol += t1
			m += t1 * (p + a + ab + da2)
		else:
			var t2a := (ab - p).dot((b - p).cross(d - p)) / 6.0
			var t2b := (ab - p).dot((d - p).cross(da2 - p)) / 6.0
			vol += t2a + t2b
			m += t2a * (p + ab + b + d) + t2b * (p + ab + d + da2)
	return Vector4(vol, m.x, m.y, m.z)


## The height (world Y) of the water's surface when `volume` m³ of water lies level in the box with
## corners `c`, and the water's centre: [level, centre].
static func level_for(c: PackedVector3Array, volume: float) -> Array:
	var lo := INF
	var hi := -INF
	var mid := Vector3.ZERO
	for p in c:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
		mid += p
	mid /= 8.0
	if volume <= 0.0:
		return [lo, Vector3(mid.x, lo, mid.z)]
	var full := below(c, hi + 1.0).x
	if volume >= full:
		return [hi, mid]
	# The volume below a level grows smoothly and steadily with it: find the level by the Illinois
	# method (regula falsi that halves the stale end), a handful of steps.
	var a := lo
	var fa := -volume
	var b := hi
	var fb := full - volume
	var side := 0
	var level := 0.5 * (lo + hi)
	var r := Vector4.ZERO
	for n in 60:
		level = (a * fb - b * fa) / (fb - fa)
		r = below(c, level)
		var f := r.x - volume
		if absf(f) <= 1e-10 * full or b - a <= 1e-9 * (hi - lo):
			break
		if f * fb > 0.0:
			b = level
			fb = f
			if side == -1:
				fa *= 0.5
			side = -1
		else:
			a = level
			fa = f
			if side == 1:
				fb *= 0.5
			side = 1
	var centre := Vector3(r.y, r.z, r.w) / (4.0 * r.x) if r.x > 1e-15 else Vector3(mid.x, level, mid.z)
	return [level, centre]


## One physics step of `dt` for the compartment at `xf` (world), on a body whose surroundings have
## water whose surface is at `surface.call(p)` for a world point p (NAN where there is none), of
## density `rho`, under gravity `g`. Moves water through the holes and the pumps, and returns the
## water's mass and centre (world): [mass, centre].
func flood_step(xf: Transform3D, surface: Callable, rho: float, g: float, dt: float) -> Array:
	var c := corners(xf)
	var full := size.x * size.y * size.z * absf(xf.basis.determinant())
	flood_volume = minf(flood_volume, full)
	var before := flood_volume
	var state := level_for(c, flood_volume)
	var level: float = state[0]
	var vol := flood_volume
	for hole in holes:
		if hole.w <= 0.0:
			continue
		var at := xf * Vector3(hole.x, hole.y, hole.z)
		var outside: float = surface.call(at)
		var d_out := maxf(outside - at.y, 0.0) if not is_nan(outside) else 0.0
		var d_in := maxf(level - at.y, 0.0) if before > 0.0 else 0.0
		var head := d_out - d_in
		if absf(head) < 1e-9:
			continue
		var q := discharge_coefficient * hole.w * sqrt(2.0 * g * absf(head)) * dt
		# Never past the level at which the flow through this hole would stop: the water outside
		# when filling; the water outside, or the hole itself, when draining.
		if head > 0.0:
			var stop := below(c, outside).x
			vol = maxf(vol, minf(vol + q, stop))
		else:
			var stop_level := maxf(outside, at.y) if not is_nan(outside) else at.y
			var stop := below(c, stop_level).x
			vol = minf(vol, maxf(vol - q, stop))
	if pump_rate > 0.0:
		vol -= pump_rate * dt
	flood_volume = clampf(vol, 0.0, full)
	inflow = (flood_volume - before) / dt if dt > 0.0 else 0.0
	if flood_volume != before:
		state = level_for(c, flood_volume)
	water_level = state[0]
	water_centre = state[1]
	return [rho * flood_volume, water_centre]
