@icon("res://addons/bounded_buoyancy/icon.svg")
class_name BoundedBuoyancyBody2D
extends RigidBody2D
## Bounded Buoyancy for 2D games: buoyancy with the added mass of the submerged part in the body's
## inertia, every physics step, for RigidBody2D.
##
## The same method as BoundedBuoyancyBody, in a side view: buoyancy drives no fall faster than g and
## no rise faster than g/C, the first frame after a release is the classical value, and buoyancy acts
## at the centre of the immersed area, so bodies tip, roll and right themselves. Out of the water the
## body is in air; water nodes can flow and have waves, wind nodes blow, and entries make splashes.
##
## Use: give a RigidBody2D one or more CollisionShape2D children (circle, rectangle, capsule or
## convex polygon) or CollisionPolygon2D children, attach this script and set its density. Then add a
## BoundedBuoyancyWater2D node, or set water_level (the y of a flat surface, in pixels). Lengths and
## speeds are in pixels, as everywhere in Godot 2D; densities are in kg/m³ as in 3D. pixels_per_metre
## and thickness only turn areas into masses in kilograms, so that collisions with other bodies are fair.
##
## Method and benchmarks: Parkyn, N. (2026). Bounded Buoyancy: Added Mass and Two Ceilings for Stable,
## Accurate Buoyancy in Game and Simulation Engines, v1.1. Licence: MIT.

## The body has just touched the water, at `speed` (px/s, through the water), at the point `at` on the surface.
signal water_entered(speed: float, at: Vector2)
## The body has just come wholly out of the water.
signal water_exited(speed: float, at: Vector2)

enum Model {
	BOUNDED, ## Added mass of the submerged part in the inertia (Bounded Buoyancy).
	USUAL,   ## Buoyancy applied to the body's own mass, as most engines do. For comparison.
}

## Which buoyancy model to use. USUAL is there for side-by-side comparisons.
@export var model: Model = Model.BOUNDED
## Density of the body in kg/m³ (water is 1000). It can be changed while running.
@export_range(0.01, 20000.0, 0.01, "or_greater", "suffix:kg/m³") var density: float = 500.0:
	set(value):
		density = maxf(value, 0.001)
		if area > 0.0:
			own_mass = density * area * _kg
			if _auto_inertia:
				inertia = _unit_inertia * density
## Added-mass coefficient C of the shape in 2D: 1 for a circle, more for a flat plate moving face-on.
## Buoyancy-driven rising is capped at g/C.
@export_range(0.0, 5.0, 0.01) var added_mass_coefficient: float = 1.0
## Height (y, in pixels) of a flat water surface, used when the scene has no BoundedBuoyancyWater2D.
@export var water_level: float = 0.0
## Density of the water (a BoundedBuoyancyWater2D uses its own).
@export_range(1.0, 20000.0, 1.0, "or_greater", "suffix:kg/m³") var water_density: float = 1000.0
## Quadratic drag coefficient, in the water and in the air (about 1 for a circle in 2D).
@export_range(0.0, 3.0, 0.01) var drag_coefficient: float = 1.0
## Damping of spin in the water, per second when fully submerged; in air, in proportion to how light
## the body is against the air.
@export_range(0.0, 20.0, 0.01, "or_greater", "suffix:1/s") var angular_drag: float = 3.0
## Keep momentum when the added mass grows as the body enters the water.
@export var keep_momentum_on_entry: bool = true
## Wave-making damping: a body bobbing at the surface sends out ripples (here to the left and right)
## that carry its energy away, so it settles: within a few bobs if it is wide and shallow (a raft, a
## boat), slowly if it is deep and narrow, as linear wave theory gives it. It acts on bobbing relative
## to the surface, so riding waves is not held back. 1 is the physics; 0 leaves it out; other values
## scale it. Bounded model only.
@export_range(0.0, 3.0, 0.01) var wave_damping: float = 1.0

@export_group("Air")
## Density of the air (1.2 kg/m³). 0 leaves air out.
@export_range(0.0, 20.0, 0.001, "or_greater", "suffix:kg/m³") var air_density: float = 1.2
## Height in pixels over which the air's density halves, measured up from y = 0. 0 keeps it the same.
@export_range(0.0, 1000000.0, 1.0, "or_greater", "suffix:px") var air_half_height: float = 0.0
## Length of a sail for the wind to push on, in pixels (0 for none).
@export_range(0.0, 10000.0, 0.1, "or_greater", "suffix:px") var sail_size: float = 0.0
## Where the wind pushes the sail, in the body's own coordinates.
@export var sail_centre: Vector2 = Vector2(0.0, -40.0)

@export_group("Scale")
## Pixels per metre, used only to turn areas into kilograms (Godot's 2D gravity of 980 px/s² is 9.8 m/s² at 100).
@export_range(1.0, 10000.0, 0.1, "or_greater") var pixels_per_metre: float = 100.0
## Depth of the body into the screen in metres, used only to turn areas into kilograms.
@export_range(0.001, 100.0, 0.001, "or_greater", "suffix:m") var thickness: float = 0.2

## The body's own mass (kg).
var own_mass: float = 0.0
## Area of the body's shape (px²).
var area: float = 0.0
## Area under water this step (px²).
var submerged_area: float = 0.0
## Added mass of the water and air taken along this step (kg).
var added_mass: float = 0.0
## Acceleration from weight, buoyancy and drag in the last step (px/s²).
var last_acceleration: Vector2 = Vector2.ZERO
## Centre of the area under water this step, in global coordinates.
var centre_of_buoyancy: Vector2 = Vector2.ZERO
## The BoundedBuoyancyWater2D the body is in this step, if any.
var water: Node2D = null
## Velocity of the wind at the body this step (px/s).
var wind_here: Vector2 = Vector2.ZERO
## Wave-making damping of bobbing this step, N per m/s (0 when the body is not at the surface).
var heave_damping: float = 0.0
## Acceleration of the water in the waves at the body this step, along +y (downwards, px/s²), which pushes it.
var wave_acceleration: float = 0.0

const _Water2D := preload("res://addons/bounded_buoyancy/bounded_buoyancy_water_2d.gd")
const _Wind2D := preload("res://addons/bounded_buoyancy/bounded_buoyancy_wind_2d.gd")
const SAIL_DRAG := 1.2
const TELEPORT_DISTANCE := 0.1   # a body this far from where its velocity would have carried it, or water whose level moves this far in a step, has been moved (m)

var _kg := 0.0                          # kilograms per px² of area at unit density
var _circle := false
var _radius := 0.0
var _circle_centre := Vector2.ZERO
var _polys: Array[PackedVector2Array] = []
var _poly_scale := PackedFloat32Array()  # exact / polygon area, per polygon
var _centroid := Vector2.ZERO
var _bound_radius := 0.0
var _box := Vector2.ZERO                 # bounding box size, body space
var _fill := 1.0
var _auto_inertia := false
var _unit_inertia := 0.0
var _prev_added_mass := -1.0
var _was_in_water := false
var _first_step := true
var _auto_com := false
var _set_up := false
var _warned := false
var _world: World2D
var _world_has_water := false
var _prev_surface := NAN                 # height of the surface under the body last step
var _prev_water: Node2D = null           # the water it was in then
var _prev_level := 0.0                   # that water's level
var _prev_com := Vector2.ZERO            # where its centre of mass was
var _prev_frame := -1                    # and which physics frame that was


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_build_shape()
	if area > 0.0:
		_set_up_body()


## Re-read the body's collision shapes. Call it after adding, removing or resizing shapes while the
## game runs; the mass, centre of mass and inertia follow (unless set by hand).
func rebuild_shape() -> void:
	_build_shape()
	if area <= 0.0:
		return
	if not _set_up:
		_set_up_body()
		return
	own_mass = density * area * _kg
	if _auto_com:
		center_of_mass = _centroid
	if _auto_inertia:
		_unit_inertia = _own_inertia(center_of_mass) / density
		inertia = _unit_inertia * density


func _set_up_body() -> void:
	_set_up = true
	_world = get_world_2d()
	_kg = thickness / (pixels_per_metre * pixels_per_metre)
	own_mass = density * area * _kg
	mass = own_mass
	gravity_scale = 0.0
	linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	angular_damp = 0.0
	if center_of_mass_mode == RigidBody2D.CENTER_OF_MASS_MODE_AUTO or _auto_com:
		_auto_com = true
		center_of_mass_mode = RigidBody2D.CENTER_OF_MASS_MODE_CUSTOM
		center_of_mass = _centroid
	if inertia == 0.0:
		_unit_inertia = _own_inertia(center_of_mass) / density
		_auto_inertia = true
		inertia = _unit_inertia * density


func _physics_process(dt: float) -> void:
	if Engine.is_editor_hint():
		return
	if not _set_up:
		_build_shape()
		if area <= 0.0:
			if not _warned:
				_warned = true
				push_warning("BoundedBuoyancyBody2D '%s': needs a CollisionShape2D (circle, rectangle, capsule, convex polygon) or a CollisionPolygon2D." % name)
			return
		_set_up_body()
	if freeze:
		_prev_added_mass = -1.0
		_prev_surface = NAN
		last_acceleration = Vector2.ZERO
		return
	var g := float(ProjectSettings.get_setting("physics/2d/default_gravity"))
	var xf := global_transform
	var cw := xf * _centroid
	var rho := water_density
	var flow := Vector2.ZERO
	water = _find_water(cw)
	if water:
		rho = water.density
		flow = water.current_at(cw)
		_immerse(xf, water)
	elif not _world_has_water:
		_immerse(xf, null)
	else:
		submerged_area = 0.0
		centre_of_buoyancy = cw
	var rho_air := air_density
	if air_half_height > 0.0:
		rho_air *= pow(0.5, maxf(-cw.y / air_half_height, -10.0))
	var air_area := area - submerged_area
	var displaced := (rho * submerged_area + rho_air * air_area) * _kg   # kg of water and air displaced
	added_mass = added_mass_coefficient * displaced
	if _prev_added_mass < 0.0:
		_prev_added_mass = added_mass
	var in_water := submerged_area > 0.0
	if _first_step:
		_was_in_water = in_water
		_first_step = false
	elif in_water != _was_in_water:
		_was_in_water = in_water
		_report_crossing(in_water, cw, flow)

	var inertial_mass := own_mass + added_mass if model == Model.BOUNDED else own_mass
	var v := linear_velocity
	if model == Model.BOUNDED and keep_momentum_on_entry and added_mass > _prev_added_mass:
		v = flow + (v - flow) * ((own_mass + _prev_added_mass) / inertial_mass)

	# Density-state drive (weight minus buoyancy; y points down), then drag on the speed through the
	# water and through the air, applied implicitly.
	var drive := Vector2(0.0, (own_mass - displaced) * g)
	# The water's own motion in waves pushes the body with it, as in BoundedBuoyancyBody, averaged
	# across the body (two Gauss points across its bounding box).
	wave_acceleration = 0.0
	if model == Model.BOUNDED and submerged_area > 0.0 and water:
		var a: float = water.vertical_acceleration_at(centre_of_buoyancy, absf(xf.x.x) * _box.x + absf(xf.y.x) * _box.y)
		wave_acceleration = clampf(a, -0.5 * g, 0.5 * g)
		drive += Vector2(0.0, (1.0 + added_mass_coefficient) * rho * submerged_area * _kg * wave_acceleration)
	var wind := _Wind2D.total_at(cw, _world) if not _Wind2D.instances.is_empty() else Vector2.ZERO
	wind_here = wind
	var through_water := v - flow
	var through_air := v - wind
	var c_water := 0.5 * drag_coefficient * _drag_length(through_water, xf) * rho * _kg * (submerged_area / area) \
		* through_water.length() * dt / inertial_mass
	var c_air := 0.5 * drag_coefficient * _drag_length(through_air, xf) * rho_air * _kg * (air_area / area) \
		* through_air.length() * dt / inertial_mass
	var c_sail := 0.5 * SAIL_DRAG * sail_size * rho_air * _kg * through_air.length() * dt / inertial_mass
	var v_target := (v + drive / inertial_mass * dt + c_water * flow + (c_air + c_sail) * wind) / (1.0 + c_water + c_air + c_sail)
	var sail_target := v_target

	# Wave-making damping of bobbing relative to the surface under the body, as in BoundedBuoyancyBody.
	heave_damping = 0.0
	if model == Model.BOUNDED and wave_damping > 0.0 and submerged_area > 0.0 and submerged_area < area * (1.0 - 1e-9):
		var surface_here := _surface_at(cw.x, water)
		var level_now: float = water.global_position.y if water else water_level
		var com_now := xf * center_of_mass
		var frame := Engine.get_physics_frames()
		var jump := TELEPORT_DISTANCE * pixels_per_metre
		var follows := not is_nan(_prev_surface) and water == _prev_water and frame == _prev_frame + 1 \
			and absf(level_now - _prev_level) < jump \
			and (com_now - _prev_com - linear_velocity * dt).length_squared() < jump * jump
		var surface_rate := (surface_here - _prev_surface) / dt if follows else 0.0
		_prev_surface = surface_here
		_prev_water = water
		_prev_level = level_now
		_prev_com = com_now
		_prev_frame = frame
		var depth := centre_of_buoyancy.y - surface_here   # y points down
		if depth > 1e-9 and g > 0.0 and rho > 0.0:
			# The rectangle with the same area under water and the same depth of its centre; its own
			# bobbing frequency ω = √(ρ g beam thickness / m), in metres and kilograms.
			var draft := 2.0 * depth
			var beam := submerged_area / draft
			var omega := sqrt(rho * g * beam * _kg / inertial_mass)
			heave_damping = wave_damping * 2.0 * wave_damping_ratio(beam / draft) * inertial_mass * omega
			# Damped for as long as it is at the surface this step: until it leaves the water or goes
			# under (rising is -y here).
			var rel := v.y - surface_rate
			var time := _at_surface(depth, (area - submerged_area) / submerged_area, -rel, dt)
			v_target.y -= (1.0 - exp(-heave_damping * time / inertial_mass)) * rel
	else:
		_prev_surface = NAN

	mass = inertial_mass
	apply_central_force(inertial_mass * (v_target - linear_velocity) / dt)
	last_acceleration = (v_target - v) / dt

	var com := xf * center_of_mass
	if c_sail > 0.0:
		var push := c_sail * inertial_mass / dt * (wind - sail_target)
		apply_torque((xf * sail_centre - com).cross(push))
	# Righting moment: buoyancy of the water and the air at the centres of the parts they displace.
	if displaced > 0.0:
		var centre := ((rho - rho_air) * submerged_area * centre_of_buoyancy + rho_air * area * cw) * _kg / displaced
		apply_torque((centre - com).cross(Vector2(0.0, -displaced * g)))
	var damp := angular_drag * (submerged_area + air_area * minf(1.0, rho_air / density)) / area
	if absf(damp - angular_damp) > 1e-6:
		angular_damp = damp
	_prev_added_mass = added_mass


## Damping ratio of bobbing from the waves a body makes in a side view, where the waves it sends out
## run only left and right (a long body, like a strip of a ship's hull): ζ = 0.0591 r / (1 + 0.15 r),
## r its beam over its draft. About 0.03 for a deep, narrow body (r = 0.5), 0.05 for a square floating
## half under (1), 0.15 for a raft (4) and 0.3 for a plank lying flat (20). Fitted within 2% to the
## exact results of linear wave theory for long floating boxes, computed with the boundary-element
## solver Capytaine (reference/wave_damping.py).
static func wave_damping_ratio(beam_to_draft: float) -> float:
	if not (beam_to_draft > 0.0):
		return 0.0
	return 0.0591 * beam_to_draft / (1.0 + 0.15 * beam_to_draft)


## How long in a step of `dt` the body stays at the surface, moving up at `rise` (as in BoundedBuoyancyBody).
static func _at_surface(depth: float, dry_over_wet: float, rise: float, dt: float) -> float:
	if rise > 0.0:
		return minf(dt, 2.0 * depth / rise)
	if rise < 0.0:
		return minf(dt, 2.0 * depth * dry_over_wet / -rise)
	return dt


func _find_water(at: Vector2) -> Node2D:
	_world_has_water = false
	for w in _Water2D.instances:
		if w.world != _world:
			continue
		_world_has_water = true
		if w.contains(at):
			return w
	return null


func _surface_at(x: float, w: Node2D) -> float:
	return w.height_at(x) if w else water_level


## Area under water and its centre (global), for the body at `xf`.
func _immerse(xf: Transform2D, w: Node2D) -> void:
	if _circle:
		var c := xf * _circle_centre
		var q := _surface_at(c.x, w) - c.y          # distance from the centre down to the surface
		if q >= _radius:
			submerged_area = 0.0
			centre_of_buoyancy = c
		elif q <= -_radius:
			submerged_area = area
			centre_of_buoyancy = c
		else:
			var s := sqrt(_radius * _radius - q * q)
			submerged_area = _radius * _radius * acos(q / _radius) - q * s
			centre_of_buoyancy = c + Vector2(0.0, (2.0 / 3.0) * s * s * s / submerged_area)
		return
	var cw := xf * _centroid
	# swell bounds how far the surface anywhere under the body can be from its height over the
	# centre: twice the most it rises or falls from its mean.
	var swell: float = 2.0 * w.max_wave() if w else 0.0
	var top := _surface_at(cw.x, w)
	if cw.y + _bound_radius <= top - swell:
		submerged_area = 0.0
		centre_of_buoyancy = cw
		return
	if cw.y - _bound_radius >= top + swell:
		submerged_area = area
		centre_of_buoyancy = cw
		return
	var total := 0.0
	var moment := Vector2.ZERO
	for k in _polys.size():
		var poly := _polys[k]
		var n := poly.size()
		var pts := PackedVector2Array()
		var depth := PackedFloat32Array()
		pts.resize(n)
		depth.resize(n)
		for j in n:
			var p := xf * poly[j]
			pts[j] = p
			depth[j] = p.y - _surface_at(p.x, w)   # positive below the surface
		var clipped := PackedVector2Array()
		for j in n:
			var a := pts[j]
			var b := pts[(j + 1) % n]
			var da := depth[j]
			var db := depth[(j + 1) % n]
			if da > 0.0:
				clipped.append(a)
			if (da > 0.0) != (db > 0.0):
				clipped.append(a + (b - a) * (da / (da - db)))
		var m := clipped.size()
		if m < 3:
			continue
		var a2 := 0.0
		var cm := Vector2.ZERO
		var o := clipped[0]
		for j in range(1, m - 1):
			var e1 := clipped[j] - o
			var e2 := clipped[j + 1] - o
			var t := 0.5 * e1.cross(e2)
			a2 += t
			cm += t * (o + clipped[j] + clipped[j + 1]) / 3.0
		var s := _poly_scale[k]
		total += absf(a2) * s
		moment += cm * signf(a2) * s
	submerged_area = clampf(total, 0.0, area)
	centre_of_buoyancy = moment / total if total > 1e-9 else cw


func _report_crossing(entering: bool, cw: Vector2, flow: Vector2) -> void:
	var speed := (linear_velocity - flow).length()
	var at := Vector2(cw.x, _surface_at(cw.x, water))
	if entering:
		water_entered.emit(speed, at)
	else:
		water_exited.emit(speed, at)
	if water and water.has_method(&"splash"):
		water.splash(at, speed if entering else 0.4 * speed, _box.x)


## Length the body shows to a flow along `along`: its bounding box seen at that angle, times its fill.
func _drag_length(along: Vector2, xf: Transform2D) -> float:
	if _circle:
		return 2.0 * _radius
	var n := along.length()
	if n < 1e-9:
		return _box.x * _fill
	var d := (xf.basis_xform_inv(along) / n).abs()
	return (d.x * _box.y + d.y * _box.x) * _fill


func _build_shape() -> void:
	_polys.clear()
	_poly_scale = PackedFloat32Array()
	_circle = false
	area = 0.0
	var parts := []
	for child in get_children():
		if child is CollisionShape2D and child.shape != null and not child.disabled:
			parts.append([child.shape, child.transform])
		elif child is CollisionPolygon2D and not child.disabled and child.polygon.size() >= 3:
			parts.append([child.polygon, child.transform])
	if parts.size() == 1 and parts[0][0] is CircleShape2D:
		var xf: Transform2D = parts[0][1]
		_circle = true
		_radius = parts[0][0].radius * xf.get_scale().x
		_circle_centre = xf.origin
		area = PI * _radius * _radius
		_centroid = _circle_centre
		_bound_radius = _radius
		_box = Vector2(2.0 * _radius, 2.0 * _radius)
		_fill = PI / 4.0
		return
	var moment := Vector2.ZERO
	for part in parts:
		var pts := PackedVector2Array()
		var exact := -1.0
		var shape = part[0]
		if shape is RectangleShape2D:
			var h: Vector2 = shape.size * 0.5
			pts = PackedVector2Array([Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)])
		elif shape is CircleShape2D:
			for i in 24:
				pts.append(Vector2.from_angle(TAU * i / 24.0) * shape.radius)
			exact = PI * shape.radius * shape.radius
		elif shape is CapsuleShape2D:
			var r: float = shape.radius
			var half := maxf(0.5 * shape.height - r, 0.0)
			for i in 13:
				pts.append(Vector2(0.0, -half) + Vector2.from_angle(PI + PI * i / 12.0) * r)
			for i in 13:
				pts.append(Vector2(0.0, half) + Vector2.from_angle(PI * i / 12.0) * r)
			exact = 2.0 * r * 2.0 * half + PI * r * r
		elif shape is ConvexPolygonShape2D:
			pts = shape.points
		elif shape is PackedVector2Array:
			pts = shape
		else:
			push_warning("BoundedBuoyancyBody2D '%s': %s is not supported." % [name, shape.get_class()])
			continue
		var xf: Transform2D = part[1]
		var placed := PackedVector2Array()
		for p in pts:
			placed.append(xf * p)
		var a := _signed_area(placed)
		if absf(a) < 1e-9:
			continue
		var s := (exact * absf(xf.determinant()) / absf(a)) if exact > 0.0 else 1.0
		_polys.append(placed)
		_poly_scale.append(s)
		area += absf(a) * s
		moment += _polygon_centroid(placed) * absf(a) * s
	if area <= 0.0:
		return
	_centroid = moment / area
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	_bound_radius = 0.0
	for poly in _polys:
		for p in poly:
			lo = lo.min(p)
			hi = hi.max(p)
			_bound_radius = maxf(_bound_radius, p.distance_to(_centroid))
	_box = hi - lo
	_fill = clampf(area / (_box.x * _box.y), 0.3, 1.0)


func _signed_area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		a += p[i].cross(p[(i + 1) % p.size()])
	return 0.5 * a


func _polygon_centroid(p: PackedVector2Array) -> Vector2:
	var a := 0.0
	var c := Vector2.ZERO
	for i in p.size():
		var q := p[(i + 1) % p.size()]
		var cr := p[i].cross(q)
		a += cr
		c += (p[i] + q) * cr
	return c / (3.0 * a)


## Rotational inertia of the body's own mass about `com` (kg·px²).
func _own_inertia(com: Vector2) -> float:
	if _circle:
		var d := _circle_centre - com
		return own_mass * (0.5 * _radius * _radius + d.length_squared())
	var j := 0.0
	for k in _polys.size():
		var p := _polys[k]
		var jk := 0.0
		for i in p.size():
			var a := p[i] - com
			var b := p[(i + 1) % p.size()] - com
			var cr := a.cross(b)
			jk += cr * (a.dot(a) + a.dot(b) + b.dot(b))
		j += absf(jk) / 12.0 * _poly_scale[k]
	return density * _kg * j
