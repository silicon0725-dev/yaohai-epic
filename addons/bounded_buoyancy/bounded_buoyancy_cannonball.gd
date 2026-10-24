@icon("res://addons/bounded_buoyancy/icon_cannonball.svg")
class_name BoundedBuoyancyCannonball
extends BoundedBuoyancyBody
## A ball in fast flight: round shot from a cannon, a musket ball, or any ball fired or thrown hard.
## Give it one SphereShape3D child; BoundedBuoyancyCannon makes them ready to fly.
##
## Drag in the air: a fast ball's drag changes with its speed. Below about two thirds of the speed of
## sound, a cannonball's drag coefficient is about 0.2, well under a slow ball's 0.47, as the air
## round it is turbulent (the drag crisis); it rises through the speed of sound to about 1. The drag
## coefficient here is that of the sphere drag of Miller and Bailey (1979), worked out from 18th and
## 19th century cannon firings, as fitted by Collins, with Morrison's (2013) correlation for the
## Reynolds number. So a 24-pounder carries about a mile at 5 degrees, as the gunners' tables give.
##
## Skipping off the water: a ball that meets the water at a shallow angle skips off it, as round shot
## fired to ricochet across the sea did. The water pushes on the part of the ball under its surface
## that faces into the ball's path, with pressure ½ ρ u², u the ball's speed into the surface there,
## square to it (Birkhoff and others, 1944). Over a ball the push across its path is a lift, and a
## ball skips when it comes down at less than about 18° / √σ, σ its density over the water's: 6.5° for
## iron, 11° for aluminium, 18° for a ball as dense as water. A steel ball 7 mm across skipping at
## 57 m/s leaves the water at the speed and angle Lyu, Yun and Wei (2021) measured. The contact lasts
## much less than a physics step, so a step in which the ball meets the water is worked through in
## short steps while it is in the water, each taking it no more than a fifth of its depth further in
## or out (second order, by the midpoint). Waves tilt the surface, so a ball meets the face of a wave
## more steeply and plunges sooner. The lift comes in between Froude numbers 1 and 2 (a speed of
## √(g d) to 2 √(g d), d the diameter), where the water's push on a moving ball stops being mostly
## buoyancy.
##
## Hitting things: it flies too far in a step for the engine's usual collision tests, so continuous
## collision detection is on and it strikes a hull instead of passing through it; hit is emitted.
## A body with a BoundedBuoyancyHull (its planking) is struck by the ball's own reckoning instead: the
## ball goes through the planking if it has the speed (the wood resists it with σ + ρ v²), holing the
## nearest compartment, flies on through the ship and out of the far side if it still has the speed,
## and otherwise lodges in the wood; splinters fly, and the body takes the momentum it loses, less theirs. A
## ball that meets the sea on its way to the planking skips off it, or plunges in, first, so shot
## fired low holes a ship at and above its waterline. Under the water and once slow, it is an ordinary
## BoundedBuoyancyBody: an iron ball sinks.

## The ball has struck `body` at the world point `at`, flying at `velocity` (world frame) just before.
## Through a ship, it strikes it twice: going in, and coming out.
signal hit(body: Node, at: Vector3, velocity: Vector3)

## Skip off the water at shallow angles. Off, the water takes the ball as it does any body.
@export var ricochet: bool = true
## Speed of sound in the air, m/s, with Fixed Air: 343 at 20 °C, 331 at 0 °C. In real air it is
## the air's own where the ball is, from its temperature (√(1.4 R T); 340.3 at 15 °C).
@export_range(1.0, 2000.0, 0.1, "or_greater", "suffix:m/s") var speed_of_sound: float = 343.0
## Seconds after which the ball removes itself. 0 keeps it.
@export_range(0.0, 3600.0, 0.1, "or_greater", "suffix:s") var lifetime: float = 30.0

## Mach number of the ball's flight through the air this step.
var mach: float = 0.0
## How many times the ball has skipped off the water.
var skips: int = 0
## The ball's velocity as it last left the water (world frame).
var exit_velocity: Vector3 = Vector3.ZERO
## How far the ball went into the wood it last lodged in, along its path (m).
var penetration: float = 0.0

const AIR_VISCOSITY := 1.81e-5      # kg/(m s), air at 15 °C
const HIT_SPEED := 2.0              # m/s, slowest strike reported by hit
const SUB_STEP := 0.2               # in the water, each short step moves the ball in or out by this share of its depth
# The sphere drag of Miller and Bailey (1979), as fitted by Collins: C_D = k(M) + t(M) C_Re(s(M) Re),
# k and t cubic Bezier curves through these control points (Mach number, value).
const _SHOCK := [Vector2(0.1, 0.0), Vector2(0.95, 0.0), Vector2(0.55, 0.95), Vector2(1.5, 1.0)]
const _MASK := [Vector2(0.0, 1.1), Vector2(0.85, 1.1), Vector2(0.57, 0.05), Vector2(1.0, 0.0)]
# Four-point Gauss-Legendre rule.
const _GX := [-0.8611363115940526, -0.3399810435848563, 0.3399810435848563, 0.8611363115940526]
const _GW := [0.3478548451374538, 0.6521451548625461, 0.6521451548625461, 0.3478548451374538]

static var _shock_table := PackedFloat32Array()
static var _mask_table := PackedFloat32Array()

var _age := 0.0
var _flight_velocity := Vector3.ZERO
var _touching := {}
var _chord := Vector3.ZERO      # velocity the engine was given for the last worked-through step
var _true_velocity := Vector3.ZERO   # and the ball's real velocity at its end
var _carry := false
var _rate := 0.0
var _inside: CollisionObject3D = null   # the body the ball has gone into, and is flying through
var _inside_hull: Node = null
var _exit_local := Vector3.ZERO          # where its path leaves that body, and the far side's normal,
var _exit_normal := Vector3.ZERO         # in the body's own frame
var _inside_time := 0.0
var _passing: Array = []   # bodies it is passing through, as collision exceptions
var _query: PhysicsShapeQueryParameters3D
var _query_shape: SphereShape3D
const _Hull := preload("res://addons/bounded_buoyancy/bounded_buoyancy_hull.gd")


func _ready() -> void:
	super()
	if Engine.is_editor_hint():
		return
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = maxi(max_contacts_reported, 4)


func _physics_process(dt: float) -> void:
	if Engine.is_editor_hint():
		return
	_age += dt
	if lifetime > 0.0 and _age >= lifetime:
		queue_free()
		return
	if _carry:
		# The engine carried the ball along the chord of its last worked-through step; unless something
		# has struck it since, it goes on with its real velocity.
		_carry = false
		if (linear_velocity - _chord).length() <= 1e-4 * maxf(_chord.length(), 1.0):
			linear_velocity = _true_velocity
	_flight_velocity = linear_velocity
	if _set_up and not freeze and _single_sphere and _strike_step(dt):
		return
	if ricochet and _set_up and not freeze and model == Model.BOUNDED and _single_sphere and _skip_step(dt):
		return
	super(dt)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var now := {}
	for i in state.get_contact_count():
		var other := state.get_contact_collider_object(i)
		if other == null:
			continue
		now[other] = true
		if not _touching.has(other) and _flight_velocity.length() >= HIT_SPEED:
			hit.emit(other, state.get_contact_collider_position(i), _flight_velocity)
	_touching = now


func _air_drag_coefficient(speed: float) -> float:
	if not _single_sphere:
		return drag_coefficient   # a fast ball's drag is for a ball
	var sound := speed_of_sound if fixed_air else _Air.sound_speed_in(get_world_3d(), global_position)
	mach = speed / maxf(sound, 1.0)
	return drag_coefficient_at(speed, 2.0 * _radius, air_density_here, sound)


## Drag coefficient in air of density `air_density` of a ball `diameter` metres across flying at
## `speed`, the speed of sound being `sound_speed`: the sphere drag of Miller and Bailey (1979), as
## fitted by Collins (arc.id.au), C_D = k(M) + t(M) C_Re(s(M) Re), with Morrison's (2013) correlation
## for C_Re. About 0.2 for a cannonball below Mach 0.6, 0.8 at Mach 1, 1 above Mach 1.4.
static func drag_coefficient_at(speed: float, diameter: float, air_density: float, sound_speed := 343.0) -> float:
	if _shock_table.is_empty():
		_build_tables()
	var m := clampf(speed / maxf(sound_speed, 1.0), 0.2, 1.5)
	var f := (m - 0.2) / 0.005
	var i := mini(int(f), _shock_table.size() - 2)
	f -= i
	var k := lerpf(_shock_table[i], _shock_table[i + 1], f)
	var t := lerpf(_mask_table[i], _mask_table[i + 1], f)
	var s := 0.78 + 0.22 * atan(-12.0 * (m - 0.23))
	var re := maxf(speed * diameter * maxf(air_density, 1e-6) / AIR_VISCOSITY, 1.0)
	return k + t * morrison_drag(s * re)


## Drag coefficient of a smooth sphere at the Reynolds number `re`, from creeping flow through the drag
## crisis (Morrison, 2013): 0.47 at 10^5, about 0.1 just past the crisis at 5 x 10^5.
static func morrison_drag(re: float) -> float:
	return 24.0 / re + 2.6 * (re / 5.0) / (1.0 + pow(re / 5.0, 1.52)) \
		+ 0.411 * pow(re / 2.63e5, -7.94) / (1.0 + pow(re / 2.63e5, -8.0)) \
		+ 0.25 * (re / 1.0e6) / (1.0 + re / 1.0e6)


static func _build_tables() -> void:
	# k(M) and t(M) every 0.005 from Mach 0.2 to 1.5, from their Bezier curves.
	var n := 261
	_shock_table.resize(n)
	_mask_table.resize(n)
	for j in n:
		var m := 0.2 + 0.005 * j
		_shock_table[j] = 1.0 if m >= 1.5 else _bezier_at(_SHOCK, m)
		_mask_table[j] = 0.0 if m > 1.0 else _bezier_at(_MASK, m)


## The value of the cubic Bezier curve with control points `p` (x, value) at x, its x rising along it.
static func _bezier_at(p: Array, x: float) -> float:
	var lo := 0.0
	var hi := 1.0
	for n in 40:
		var u := 0.5 * (lo + hi)
		var w := 1.0 - u
		if w * w * w * p[0].x + 3.0 * w * w * u * p[1].x + 3.0 * w * u * u * p[2].x + u * u * u * p[3].x < x:
			lo = u
		else:
			hi = u
	var u := 0.5 * (lo + hi)
	var w := 1.0 - u
	return w * w * w * p[0].y + 3.0 * w * w * u * p[1].y + 3.0 * w * u * u * p[2].y + u * u * u * p[3].y


## The water's push on a ball of unit radius moving with unit velocity (uh along the level, uy up),
## its centre `c` radii above the surface: the integral of (u·n)² n over the part of the ball under the
## surface that faces into its path (u·n > 0), as Vector2(along uh's direction, up). The force is
## -½ ρ U² a² times this. The part's edge, z = -c, and the edges of the facing side, at z = ±uh, split
## the integral over height z; round the ball (angle φ) it is worked out exactly.
static func newton_push(uh: float, uy: float, c: float) -> Vector2:
	var lo := -1.0
	var hi := minf(-c, 1.0)
	if hi <= lo:
		return Vector2.ZERO
	var cuts := PackedFloat64Array([lo])
	if -uh > lo and -uh < hi:
		cuts.append(-uh)
	if uh > lo and uh < hi and uh > -uh:
		cuts.append(uh)
	cuts.append(hi)
	var along := 0.0
	var up := 0.0
	for j in cuts.size() - 1:
		var mid := 0.5 * (cuts[j] + cuts[j + 1])
		var half := 0.5 * (cuts[j + 1] - cuts[j])
		for q in 4:
			var z: float = mid + half * _GX[q]
			var s := sqrt(maxf(1.0 - z * z, 0.0))
			var a := uh * s
			var b := uy * z
			var p0 := PI
			if a < 1e-12:
				if b <= 0.0:
					continue
			else:
				var r := -b / a
				if r >= 1.0:
					continue
				if r > -1.0:
					p0 = acos(r)
			var sp := sin(p0)
			var cp := cos(p0)
			var j0 := a * a * (p0 + sp * cp) + 4.0 * a * b * sp + 2.0 * b * b * p0
			var j1 := a * a * 2.0 * (sp - sp * sp * sp / 3.0) + 2.0 * a * b * (p0 + sp * cp) + 2.0 * b * b * sp
			along += _GW[q] * half * s * j1
			up += _GW[q] * half * z * j0
	return Vector2(along, up)


## A step in which a fast ball meets the water, worked through in short steps. Returns false, leaving
## the step to BoundedBuoyancyBody, when the ball is slow (Froude number below 1), wholly under the
## water, out of the water all step, or where there is no water.
func _skip_step(dt: float) -> bool:
	var frame := Engine.get_physics_frames()
	if frame != _g_frame:
		_g = float(ProjectSettings.get_setting("physics/3d/default_gravity"))
		_g_frame = frame
	var g := _g
	var xf := global_transform
	var c := xf * _sphere_centre
	var a := _radius
	water = _find_water(c)
	if water == null and not (water_surface or not _world_has_water):
		return false
	var flow: Vector3 = water.current_at(c) if water else Vector3.ZERO
	var v := linear_velocity
	if (v - flow).length_squared() < 2.0 * g * a:
		return false
	var depth := _surface_at(c) - (c.y - a)
	if depth >= 2.0 * a:
		return false
	if depth <= 0.0:
		# Out of the water: does it reach it this step? Its path's lowest point is at one end of it;
		# over waves, the surface between may reach as high as the crests.
		var end := c + v * dt + Vector3.DOWN * (0.5 * g * dt * dt)
		var lowest := minf(c.y, end.y) - a
		if water and water.is_wavy():
			if lowest > water.global_position.y + water.max_wave():
				return false
		elif end.y - a > _surface_at(end):
			return false
	_through_the_water(dt, c, v, flow, g)
	return true


## The step worked through in short steps, from `start` at `v_start`. With a `wall` (the planking the
## ball's straight path strikes this step: target, hull, normal, and centre, where the ball's centre
## would be as it touches it), the ball strikes it where its path through the water takes it.
func _through_the_water(dt: float, start: Vector3, v_start: Vector3, flow: Vector3, g: float, wall := {}) -> void:
	var a := _radius
	var vol := volume
	var m := own_mass
	var rho: float = water.density if water else water_density
	air_density_here = air_density
	if air_half_height > 0.0:
		air_density_here *= pow(0.5, maxf(start.y / air_half_height, -10.0))
	var air := air_density_here
	var wind := _Wind.total_at(start, _world) if not _Wind.instances.is_empty() else Vector3.ZERO
	wind_here = wind
	var slope := _wave_slope()
	var x := start
	var v := v_start
	var t := 0.0
	var wet := _was_in_water   # as the last step left it, so each touch is reported once
	var prev_added := _prev_added_mass   # -1 on a first step: nothing to share then
	var wet_time := 0.0
	var n := 0
	var has_wall := not wall.is_empty()
	var wall_centre: Vector3 = wall.centre if has_wall else Vector3.ZERO
	var wall_normal: Vector3 = wall.normal if has_wall else Vector3.UP
	var struck := false
	while t < dt - 1e-12 and n < 5000:
		n += 1
		var rest := dt - t
		var x0 := x
		var v0 := v
		var t0 := t
		var level := _surface_at(x)
		if level - (x.y - a) <= 0.0:
			if wet:
				wet = false
				skips += 1
				exit_velocity = v
				_cross(false, Vector3(x.x, level, x.z), (v - flow).length())
			# Clear of the water: fly on for as long as it surely stays clear, or to the end of the step.
			var clear := (x.y - a) - level
			var closing := maxf(-v.y, 0.0) + slope * Vector2(v.x, v.z).length() + g * rest
			var h := rest if closing <= 0.0 else minf(rest, maxf(clear, 0.05 * a) / closing)
			var mi_air := m + added_mass_coefficient * air * vol
			var ua := v - wind
			var ca := 0.5 * _air_drag_coefficient(ua.length()) * _area * air * ua.length() * h / mi_air
			v = (v + Vector3.UP * ((air * vol - m) * g / mi_air * h) + ca * wind) / (1.0 + ca)
			x += v * h
			t += h
			prev_added = added_mass_coefficient * air * vol
		else:
			if not wet:
				wet = true
				_cross(true, Vector3(x.x, level, x.z), (v - flow).length())
			# Depth measured square to the surface, which waves tilt: a ball meets the face of a wave steeply.
			var normal := _surface_normal(x)
			var dd := clampf(a - (x.y - level) * normal.y, 0.0, 2.0 * a)
			var under := PI * dd * dd * (3.0 * a - dd) / 3.0
			var added := added_mass_coefficient * (rho * under + air * (vol - under))
			if keep_momentum_on_entry and prev_added >= 0.0 and added > prev_added:
				# Water taken along starts with the water's own velocity.
				v = flow + (v - flow) * ((m + prev_added) / (m + added))
			prev_added = added
			if dd >= 2.0 * a:
				# Wholly under, the push across its path is nothing (the ball is round): the rest of the
				# step as BoundedBuoyancyBody takes it, its drag worked out with the speed at the end; on
				# its way to planking, a diameter at a time, so that it gets there at the speed it has then.
				var mi := m + added
				var u := v - flow
				var h := rest if not has_wall else minf(rest, 2.0 * a / maxf(u.length(), 1e-6))
				var cw := 0.5 * drag_coefficient * _area * rho * u.length() * h / mi
				v = (v + Vector3.UP * ((rho * vol - m) * g / mi * h) + cw * flow) / (1.0 + cw)
				x += v * h
				wet_time += h
				t += h
			else:
				# A short step, second order (midpoint): short enough that the ball moves into or out of
				# the water by no more than a fifth of how deep it is, and goes no more than ten radii.
				var acc := _water_accel(x, v, level, normal, dd, flow, wind, rho, air, g)
				var speed := (v - flow).length()
				var ref := maxf(dd, 0.05 * a)
				var h := minf(rest, 10.0 * a / maxf(speed, 1e-6))
				h = minf(h, SUB_STEP * ref / maxf(absf((v - flow).dot(normal)), 1e-6))
				h = minf(h, sqrt(2.0 * SUB_STEP * ref / maxf(absf(acc.dot(normal)), 1e-9)))
				h = minf(h, 0.5 / maxf(_rate, 1e-9))
				var xm := x + v * (0.5 * h)
				var vm := v + acc * (0.5 * h)
				var lm := _surface_at(xm)
				var nm := _surface_normal(xm)
				var ddm := clampf(a - (xm.y - lm) * nm.y, 0.0, 2.0 * a)
				var accm := _water_accel(xm, vm, lm, nm, ddm, flow, wind, rho, air, g)
				x += vm * h
				v += accm * h
				t += h
				wet_time += h * under / vol
		if has_wall:
			# Has it come to the planking? Its face is taken as flat over the little way the water has
			# turned the ball from its straight path.
			var d1 := (x - wall_centre).dot(wall_normal)
			if d1 <= 0.0:
				var d0 := (x0 - wall_centre).dot(wall_normal)
				var f := clampf(d0 / (d0 - d1), 0.0, 1.0) if d0 > 0.0 else 0.0
				var vw := v0.lerp(v, f)
				var sw := vw.length()
				if sw >= _Hull.STRIKE_SPEED and -vw.dot(wall_normal) >= _Hull.GLANCE * sw:
					x = x0.lerp(x, f)
					v = vw
					t = t0 + (t - t0) * f
					struck = true
					break
				has_wall = false   # glancing, or slow: the engine meets it as it does any collision
	if struck:
		# Into the planking from the water, or from the air after skipping: out of the sea inside it
		# (unless it comes out of the far side under the water within the step).
		submerged_volume = 0.0
		centre_of_buoyancy = x
		added_mass = added_mass_coefficient * air * vol
		mass = m + added_mass
		heave_damping = 0.0
		wave_acceleration = 0.0
		_prev_added_mass = added_mass
		_prev_surface = NAN
		_was_in_water = false
		_first_step = false
		var flown := _strike_at(wall.target, wall.hull, x - wall_normal * a, wall_normal, x, v, dt - t)
		if flown.is_empty():
			return   # lodged in it
		_hand_on(start, flown[0], flown[1], dt)
		return
	# Where the step leaves it: a touch, or a skip, in its last moment counts too.
	var level_end := _surface_at(x)
	if level_end - (x.y - a) > 0.0 and not wet:
		_cross(true, Vector3(x.x, level_end, x.z), (v - flow).length())
	elif level_end - (x.y - a) <= 0.0 and wet:
		skips += 1
		exit_velocity = v
		_cross(false, Vector3(x.x, level_end, x.z), (v - flow).length())
	var d_end := clampf(level_end - (x.y - a), 0.0, 2.0 * a)
	submerged_volume = PI * d_end * d_end * (3.0 * a - d_end) / 3.0
	var sunk := 3.0 * (2.0 * a - d_end) * (2.0 * a - d_end) / (4.0 * (3.0 * a - d_end))   # cap's centre below the ball's
	centre_of_buoyancy = x + Vector3.DOWN * sunk if submerged_volume > 0.0 else x
	added_mass = added_mass_coefficient * (rho * submerged_volume + air * (vol - submerged_volume))
	var mi_end := m + added_mass
	mass = mi_end
	# The engine moves the ball on by the velocity it ends the step with, so it is given the chord of the
	# step's path, from where the ball was to where the short steps leave it; the real velocity at the end
	# is handed back at the start of the next step. No teleport, and continuous collision detection
	# sweeps the chord.
	var chord := (x - start) / dt
	apply_central_force(mi_end * (chord - v_start) / dt)
	_chord = chord
	_true_velocity = v
	_carry = true
	last_acceleration = (v - v_start) / dt
	heave_damping = 0.0
	wave_acceleration = 0.0
	_prev_added_mass = added_mass
	_prev_surface = NAN
	_was_in_water = submerged_volume > 0.0
	_first_step = false
	var wet_share := wet_time / dt
	var damp := angular_drag * (wet_share + (1.0 - wet_share) * minf(1.0, air / density))
	if absf(damp - angular_damp) > 1e-6:
		angular_damp = damp


## Acceleration of a ball at `x` moving at `v`, `dd` deep in water whose surface there is at `level`
## with normal `normal`: weight, buoyancy, the water's push on the part under it and the air's drag on
## the rest, against the ball's mass and the water and air it takes along. Leaves in _rate how fast
## drag takes away its speed (1/s).
func _water_accel(x: Vector3, v: Vector3, level: float, normal: Vector3, dd: float, flow: Vector3, wind: Vector3, rho: float, air: float, g: float) -> Vector3:
	var a := _radius
	var vol := volume
	var under := PI * dd * dd * (3.0 * a - dd) / 3.0
	var displaced := rho * under + air * (vol - under)
	var mi := own_mass + added_mass_coefficient * displaced
	var acc := Vector3.UP * ((displaced - own_mass) * g / mi)
	var u := v - flow
	var speed := u.length()
	# Drag in the water: as BoundedBuoyancyBody's, the area times the share of the ball under water.
	var drag_area := _area * under / vol
	if dd > 0.0 and speed > 1e-9:
		var fast := smoothstep(1.0, 2.0, speed / sqrt(2.0 * g * a))
		if fast > 0.0:
			# The water's push on the part under the surface that faces into the ball's path: across the
			# path, a lift; along it, a drag, scaled so that wholly under it is the ball's own drag.
			var into := u.dot(normal)
			var skim := u - normal * into
			var skim_speed := skim.length()
			var along := skim / skim_speed if skim_speed > 1e-12 else Vector3.ZERO
			var p := newton_push(skim_speed / speed, into / speed, 1.0 - dd / a)
			var push := (along * p.x + normal * p.y) * (-0.5 * rho * speed * speed * a * a)
			var dir := u / speed
			var back := -push.dot(dir)
			acc += (push + dir * back) * (fast / mi)
			drag_area = lerpf(drag_area, back / (0.25 * rho * speed * speed), fast)
	var rate_water := 0.5 * drag_coefficient * drag_area * rho * speed / mi
	var ua := v - wind
	var air_speed := ua.length()
	var rate_air := 0.5 * _air_drag_coefficient(air_speed) * _area * air * (vol - under) / vol * air_speed / mi
	_rate = rate_water + rate_air
	return acc - u * rate_water - ua * rate_air


## A step in which the ball strikes planking (a body with a BoundedBuoyancyHull), or flies on through
## the body it has gone into. Returns false, leaving the step to the rest, when it strikes nothing
## of the kind this step.
func _strike_step(dt: float) -> bool:
	if _inside:
		return _inside_step(dt)
	var v := linear_velocity
	var speed := v.length()
	if speed < _Hull.STRIKE_SPEED:
		return false
	var a := _radius
	var c := global_transform * _sphere_centre
	var space := get_world_3d().direct_space_state
	if _query == null:
		_query = PhysicsShapeQueryParameters3D.new()
		_query_shape = SphereShape3D.new()
		_query.shape = _query_shape
	_query_shape.radius = a
	_query.collision_mask = collision_mask
	var exclude: Array[RID] = [get_rid()]
	for b in _passing:
		if is_instance_valid(b):
			exclude.append(b.get_rid())
	# The first planking on its path this step, past anything lighter than the ball (a splinter), which
	# the engine meets as it meets anything.
	var target: CollisionObject3D = null
	var info := {}
	var t := 1.0
	for i in 4:
		_query.exclude = exclude
		_query.transform = Transform3D(Basis(), c)
		_query.motion = v * dt
		var r := space.cast_motion(_query)
		if r.is_empty() or r[1] >= 1.0:
			return false
		t = r[1]
		_query.transform = Transform3D(Basis(), c + v * dt * t)
		_query.motion = Vector3.ZERO
		info = space.get_rest_info(_query)
		if info.is_empty():
			return false
		var other := instance_from_id(info.collider_id) as CollisionObject3D
		if other and other.has_meta(_Hull.META):
			target = other
			break
		if not (other is RigidBody3D and not other.freeze and other.mass < own_mass):
			return false   # something solid in the way: the engine meets it as it meets anything
		exclude.append(info.rid)   # a splinter, or anything lighter than the ball: on past it
	if target == null:
		return false
	var hull: Node = target.get_meta(_Hull.META)
	var n: Vector3 = info.normal
	if -(v / speed).dot(n) < _Hull.GLANCE:
		return false   # glancing: it bounces off, as the engine makes it
	var centre := c + v * (dt * t)
	# A ball in the sea on its way skips off it, or plunges in, before it gets to the planking.
	if ricochet and model == Model.BOUNDED and _water_first(c, centre):
		var flow: Vector3 = water.current_at(c) if water else Vector3.ZERO
		_through_the_water(dt, c, v, flow, _gravity(), {target = target, hull = hull, normal = n, centre = centre})
		return true
	var flown := _strike_at(target, hull, info.point, n, centre, v, dt * (1.0 - t))
	if not flown.is_empty():
		_hand_on(c, flown[0], flown[1], dt)
	return true


## Whether the ball, flying straight from `c` to `centre`, is in the water on the way, or already in
## it. Sets water.
func _water_first(c: Vector3, centre: Vector3) -> bool:
	water = _find_water(c)
	if water == null and not (water_surface or not _world_has_water):
		return false
	var a := _radius
	for i in 9:
		var p := c.lerp(centre, i / 8.0)
		if _surface_at(p) - (p.y - a) > 0.0:
			return true
	return false


## The ball, its centre at `centre` and flying at `v`, strikes the planking (`hull`) of `target` at the
## world point `at`, where its face has the outward normal `n`: it goes through, holing it, or lodges in
## it. Then on through the body for `time_after` seconds. Returns [where it ends, its velocity then], or
## empty if it lodged. Speeds are taken relative to the body there.
func _strike_at(target: CollisionObject3D, hull: Node, at: Vector3, n: Vector3, centre: Vector3, v: Vector3, time_after: float) -> Array:
	var moving := _velocity_at(target, at)
	var u := v - moving
	var speed := u.length()
	var dir := u / speed
	var cos_in := maxf(-dir.dot(n), 0.0)
	var a := _radius
	var m := own_mass
	var v1: float = hull.speed_through(m, a, speed, cos_in)
	hit.emit(target, at, v)
	if v1 <= 0.0:
		penetration = _Hull.penetration_depth(m, PI * a * a, speed, hull.density, hull.strength * 1e6)
		_lodge(target, hull, at, v)
		return []
	# Through the planking: a hole, and splinters off the face. The body takes the momentum the ball
	# loses, less what the splinters carry off.
	hull.make_hole(at, PI * a * a * hull.hole_size)
	var thrown: Vector3 = hull.throw_splinters(at, (n - dir).normalized(), 0.05 * speed, a, cos_in, moving, get_parent(), self)
	if target is RigidBody3D:
		target.apply_impulse(dir * (m * (speed - v1)) - thrown, at - target.global_position)
	hull.struck.emit(self, at, true, v1)
	# On through the body: where its path leaves it, the far side.
	if target is PhysicsBody3D:
		pass_through(target, 0.0)
	var far := _far_side(target, at, dir)
	_inside = target
	_inside_hull = hull
	_inside_time = 0.0
	if far.is_empty():
		# No far side to be found (a shape open on that side): it stops in the body here.
		penetration = 0.0
		_lodge(target, hull, at, moving + dir * v1)
		return []
	var xf := target.global_transform
	_exit_local = xf.affine_inverse() * far[0]
	_exit_normal = (xf.basis.transposed() * far[1]).normalized()   # a normal, so by the transpose
	return _through(centre, moving + dir * v1, time_after)


## A step of flying through the body the ball has gone into.
func _inside_step(dt: float) -> bool:
	if not is_instance_valid(_inside) or not is_instance_valid(_inside_hull):
		if is_instance_valid(_inside) and _inside is PhysicsBody3D:
			_stop_passing(_inside)   # its planking is gone: an ordinary body again
		_inside = null
		return false
	_inside_time += dt
	var c := global_transform * _sphere_centre
	if _inside_time > 2.0:
		penetration = 0.0
		_lodge(_inside, _inside_hull, c, linear_velocity)
		return true
	var flown := _through(c, linear_velocity, dt)
	if not flown.is_empty():
		_hand_on(c, flown[0], flown[1], dt)
	return true


## The ball flies on inside the body it has gone into, from `p` at `v`, for `time`: out of the far
## side if it gets there with the speed to go through that planking, and otherwise lodged in it.
## Inside the hull it is out of the sea and the wind, under gravity alone. Returns [where it ends,
## its velocity then], or empty if it lodged. Speeds are taken relative to the body.
func _through(p: Vector3, v: Vector3, time: float) -> Array:
	var target := _inside
	var hull := _inside_hull
	var xf := target.global_transform
	var exit := xf * _exit_local
	var normal := (xf.basis.inverse().transposed() * _exit_normal).normalized()
	var g := _gravity()
	var moving := _velocity_at(target, p)
	var u := v - moving
	var speed := u.length()
	var dir := u / speed if speed > 1e-6 else Vector3.ZERO
	var cos_out := dir.dot(normal)
	if speed < 1e-3 or cos_out < _Hull.GLANCE:
		penetration = 0.0
		_lodge(target, hull, p, v)
		return []
	var s := (exit - p).dot(normal) / cos_out   # how far on its path, through the body, to the far side
	if s > speed * time:
		return [p + v * time + Vector3.DOWN * (0.5 * g * time * time), v + Vector3.DOWN * g * time]
	var to_far := maxf(s, 0.0) / speed
	var at := p + v * to_far + Vector3.DOWN * (0.5 * g * to_far * to_far)
	var m := own_mass
	var a := _radius
	var v2: float = hull.speed_through(m, a, speed, cos_out)
	hit.emit(target, at, v)
	if v2 <= 0.0:
		penetration = _Hull.penetration_depth(m, PI * a * a, speed, hull.density, hull.strength * 1e6)
		_lodge(target, hull, at, v)
		return []
	hull.make_hole(at, PI * a * a * hull.hole_size)
	moving = _velocity_at(target, at)
	var thrown: Vector3 = hull.throw_splinters(at, dir, 0.3 * v2, a, cos_out, moving, get_parent(), self)
	if target is RigidBody3D:
		target.apply_impulse(dir * (m * (speed - v2)) - thrown, at - target.global_position)
	hull.struck.emit(self, at, true, v2)
	_inside = null
	if target is PhysicsBody3D:
		pass_through(target, 0.3)   # clear of its far side before it can strike it again
	var rest := time - to_far
	var v_out := moving + dir * v2
	if _in_the_sea(at):
		# Out into the sea: the water's drag slows it from there, as v / (1 + k v t) (net weight aside),
		# and it is in the water already, so it makes no splash.
		_was_in_water = true
		var rho: float = water.density if water else water_density
		var k := 0.5 * drag_coefficient * _area * rho / (m + added_mass_coefficient * rho * volume)
		var net := g * (m - rho * volume) / (m + added_mass_coefficient * rho * volume)
		var gone := log(1.0 + k * v2 * rest) / k if k > 1e-9 else v2 * rest
		var v_end := moving + dir * (v2 / (1.0 + k * v2 * rest))
		return [at + moving * rest + dir * gone + Vector3.DOWN * (0.5 * net * rest * rest), v_end + Vector3.DOWN * net * rest]
	return [at + v_out * rest + Vector3.DOWN * (0.5 * g * rest * rest), v_out + Vector3.DOWN * g * rest]


## Whether the ball's centre is under the sea at `p`. Sets water.
func _in_the_sea(p: Vector3) -> bool:
	water = _find_water(p)
	if water == null and not (water_surface or not _world_has_water):
		return false
	return _surface_at(p) > p.y


## The ball stops in the wood of `target` at `at`: the body takes all its momentum (relative to the
## body there), and it is gone.
func _lodge(target: CollisionObject3D, hull: Node, at: Vector3, v: Vector3) -> void:
	if target is RigidBody3D:
		target.apply_impulse((v - _velocity_at(target, at)) * own_mass, at - target.global_position)
	if target is PhysicsBody3D:
		pass_through(target, 0.0)
	hull.struck.emit(self, at, false, 0.0)
	_inside = null
	linear_velocity = Vector3.ZERO
	freeze = true
	queue_free()


## Where a path along `dir` from `at`, inside `target`, comes out of it: [point, outward normal], or
## empty if it cannot be found. The body's shapes are taken as solid, and as one where they touch or
## overlap (a ship of several convex pieces): points along the path are tested until one lies outside
## them all, and a ray cast back from there finds the face the path leaves by. A shape with no inside
## (a ConcavePolygonShape3D) is taken as solid from its first face along the path to its last.
func _far_side(target: CollisionObject3D, at: Vector3, dir: Vector3) -> Array:
	var space := get_world_3d().direct_space_state
	var q := PhysicsPointQueryParameters3D.new()
	q.collision_mask = target.collision_layer
	var own: Array[RID] = [get_rid()]
	q.exclude = own
	const STEP := 0.1
	var s := 0.02
	var last := -1.0   # the furthest point along the path found inside the body
	while s < 1000.0:
		q.position = at + dir * s
		var inside := false
		for h in space.intersect_point(q, 32):
			if h.collider == target:
				inside = true
				break
		if inside:
			last = s
		elif last >= 0.0 or s > 2.0 * _radius + STEP:
			break   # out of it again, or never in it (a shape with no inside)
		s += STEP
	if last >= 0.0:
		return _ray_to(target, at + dir * (last + STEP), at + dir * 0.01)
	return _ray_to(target, at + dir * 1000.0, at + dir * 0.01)


## Where a ray from `from` to `to` first meets `target`, past anything else in the way: [point,
## normal], or empty.
func _ray_to(target: CollisionObject3D, from: Vector3, to: Vector3) -> Array:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to, target.collision_layer)
	var exclude: Array[RID] = [get_rid()]
	for n in 32:
		q.exclude = exclude
		var r := space.intersect_ray(q)
		if r.is_empty():
			return []
		if r.collider == target:
			return [r.position, r.normal]
		exclude.append(r.rid)
	return []


## The engine moves the ball on by the velocity it ends the step with, so it is given the chord of the
## step's path, from `start` to `end`; the real velocity `v_end` is handed back at the start of the next
## step.
func _hand_on(start: Vector3, end: Vector3, v_end: Vector3, dt: float) -> void:
	var chord := (end - start) / dt
	apply_central_force(mass * (chord - linear_velocity) / dt)
	last_acceleration = (v_end - linear_velocity) / dt
	_chord = chord
	_true_velocity = v_end
	_carry = true


## Let the ball pass through `body` (its own ship as it is fired, a ship it has gone into) for
## `seconds`, or until told otherwise if 0.
func pass_through(body: PhysicsBody3D, seconds: float) -> void:
	add_collision_exception_with(body)
	if not _passing.has(body):
		_passing.append(body)
		body.tree_exiting.connect(_stop_passing.bind(body), CONNECT_ONE_SHOT)
	if seconds > 0.0:
		var wb := weakref(body)
		get_tree().create_timer(seconds, false, true).timeout.connect(func() -> void:
			var b: PhysicsBody3D = wb.get_ref()
			if b and is_instance_valid(self) and _inside != b:
				_stop_passing(b))


func _stop_passing(body: PhysicsBody3D) -> void:
	if is_instance_valid(body):
		remove_collision_exception_with(body)
		var call := _stop_passing.bind(body)
		if body.tree_exiting.is_connected(call):
			body.tree_exiting.disconnect(call)
	_passing.erase(body)


## The velocity of `body` at the world point `at` (nothing for a body that does not move).
func _velocity_at(body: Node, at: Vector3) -> Vector3:
	if body is RigidBody3D:
		var state := PhysicsServer3D.body_get_direct_state(body.get_rid())
		if state:
			return state.get_velocity_at_local_position(at - body.global_position)
		return body.linear_velocity
	return Vector3.ZERO


func _gravity() -> float:
	var frame := Engine.get_physics_frames()
	if frame != _g_frame:
		_g = float(ProjectSettings.get_setting("physics/3d/default_gravity"))
		_g_frame = frame
	return _g


## Height of the water's surface over the world point `p`.
func _surface_at(p: Vector3) -> float:
	if water:
		return water.height_at(p)
	return water_surface.global_position.y if water_surface else water_level


## The surface's normal under the world point `p`, from its heights a radius either side.
func _surface_normal(p: Vector3) -> Vector3:
	if water == null or not water.is_wavy():
		return Vector3.UP
	var e := maxf(_radius, 0.02)
	var dx := _surface_at(p + Vector3(e, 0.0, 0.0)) - _surface_at(p - Vector3(e, 0.0, 0.0))
	var dz := _surface_at(p + Vector3(0.0, 0.0, e)) - _surface_at(p - Vector3(0.0, 0.0, e))
	return Vector3(-dx, 2.0 * e, -dz).normalized()


## How steeply the surface can slope: for this water's waves, k H for each wave.
func _wave_slope() -> float:
	if water == null or not water.is_wavy():
		return 0.0
	if water.outside_height().is_valid():
		return 0.3
	return TAU * water.wave_height / water.wave_length * (1.0 + _Water.SECOND_HEIGHT / _Water.SECOND_LENGTH)


## Emit water_entered or water_exited at `at` on the surface, and ask the water for a splash.
func _cross(entering: bool, at: Vector3, speed: float) -> void:
	if entering:
		water_entered.emit(speed, at)
	else:
		water_exited.emit(speed, at)
	if water and water.has_method(&"splash"):
		water.splash(at, speed if entering else 0.4 * speed, 2.0 * _radius)
