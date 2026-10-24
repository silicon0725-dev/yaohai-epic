@icon("res://addons/bounded_buoyancy/icon_fish.svg")
class_name BoundedBuoyancyFish
extends BoundedBuoyancyBody
## A fish: a BoundedBuoyancyBody that swims, takes bait, and fights a line.
##
## Give it a collision shape as for any body (a capsule along Z does), its head toward -Z. Its swim
## bladder keeps it as dense as the water round it, so it neither sinks nor rises, and it swims by its
## tail: a push forward that falls to nothing at burst_speed (as a BoundedBuoyancyThruster's does),
## against the water's drag on its body. It turns itself to where it is going and keeps itself upright.
##
## It wanders near where it started, between min_depth and max_depth. Bait (a body in the group
## "bounded_buoyancy_bait", or the one set as bait) within sense_range may draw it: it comes up to it,
## nibbles at it (each nibble a small tug, bite_pull, which dips a float), and then takes it and swims
## off with it. Any BoundedBuoyancyLine tied to the bait is then tied to the fish's mouth. Strike (pull
## the line harder than strike_pull) while it has the bait and it is hooked; wait too long and it drops
## the bait and keeps away from bait for a while.
##
## Hooked, it runs away from the pull, veering and diving, with all the strength it has. Fighting tires
## it (endurance is how many seconds of full effort it has in it), resting brings some strength back,
## and a tired fish may make one more run. It throws the hook if the line goes slack for slack_escape
## seconds, and escapes if the line breaks.

signal noticed_bait(bait: Node3D)
signal nibbled(bait: Node3D)
signal took_bait(bait: Node3D)
signal dropped_bait(bait: Node3D)
signal hooked
signal tired
signal escaped

enum State { WANDER, APPROACH, NIBBLE, TAKE, HOOKED, TIRED, FREE }

@export_group("Swimming")
## Its usual swimming speed, in m/s.
@export_range(0.0, 20.0, 0.01, "or_greater", "suffix:m/s") var cruise_speed: float = 0.4
## Its fastest, in a dash, in m/s.
@export_range(0.01, 30.0, 0.01, "or_greater", "suffix:m/s") var burst_speed: float = 3.0
## The push of its tail from rest, in newtons.
@export_range(0.0, 10000.0, 0.01, "or_greater", "suffix:N") var max_thrust: float = 8.0
## How fast it can turn, in degrees a second.
@export_range(1.0, 2000.0, 1.0, "suffix:°/s") var turn_rate: float = 180.0
## Keep it as dense as the water round it (as a swim bladder does).
@export var swim_bladder: bool = true
## Shallowest it swims, metres below the surface.
@export_range(0.0, 1000.0, 0.01, "or_greater", "suffix:m") var min_depth: float = 0.5
## Deepest it swims, metres below the surface.
@export_range(0.0, 1000.0, 0.01, "or_greater", "suffix:m") var max_depth: float = 3.0
## How far it wanders from where it started, in metres.
@export_range(0.0, 1000.0, 0.1, "or_greater", "suffix:m") var home_range: float = 8.0

@export_group("Feeding")
## Bait it goes for. Empty: any body in the group "bounded_buoyancy_bait".
@export var bait: RigidBody3D
## How far it notices bait from, in metres.
@export_range(0.0, 100.0, 0.1, "or_greater", "suffix:m") var sense_range: float = 5.0
## How keen it is: the chance a second that it goes for bait it has noticed.
@export_range(0.0, 10.0, 0.01, "or_greater") var appetite: float = 0.3
## Most nibbles before it takes the bait (it makes 1 to this many).
@export_range(0, 20, 1) var nibbles: int = 3
## The tug of a nibble, in newtons.
@export_range(0.0, 100.0, 0.001, "or_greater", "suffix:N") var bite_pull: float = 0.04
## Where its mouth is, in its own frame.
@export var mouth: Vector3 = Vector3(0.0, 0.0, -0.15)
## Seconds it holds the bait before dropping it if not struck.
@export_range(0.1, 60.0, 0.1, "or_greater", "suffix:s") var take_time: float = 2.5
## A pull on the line this hard while it has the bait hooks it, in newtons.
@export_range(0.0, 1000.0, 0.01, "or_greater", "suffix:N") var strike_pull: float = 2.0
## Seconds it keeps away from bait after dropping it.
@export_range(0.0, 600.0, 0.1, "or_greater", "suffix:s") var wary_time: float = 15.0

@export_group("Fighting")
## Seconds of full effort it has in it, hooked. Resting, it gets a quarter of that back in as long again.
@export_range(0.1, 3600.0, 0.1, "or_greater", "suffix:s") var endurance: float = 20.0
## Seconds of slack line after which a hooked fish throws the hook. 0: never.
@export_range(0.0, 60.0, 0.1, "or_greater", "suffix:s") var slack_escape: float = 3.0
## Seed for its choices. 0: different each run.
@export var random_seed: int = 0

## What it is doing.
var state: State = State.WANDER
## Its strength left, 1 (fresh) to 0 (spent).
var stamina: float = 1.0
## How hard it is swimming, 0 to 1.
var effort: float = 0.0
## The line it is on, if hooked or holding bait.
var line: Node3D = null

const _Thruster := preload("res://addons/bounded_buoyancy/bounded_buoyancy_thruster.gd")
const _Line := preload("res://addons/bounded_buoyancy/bounded_buoyancy_line.gd")

var _tail: Node3D
var _rng := RandomNumberGenerator.new()
var _home := Vector3.ZERO
var _goal := Vector3.ZERO
var _goal_time := 0.0
var _speed := 0.0               # speed it wants to go, m/s
var _timer := 0.0
var _tug := 0.0                 # seconds left of the current tug
var _nibbles_left := 0
var _wary := 0.0
var _slack := 0.0
var _veer := 0.0
var _veer_time := 0.0
var _target_bait: RigidBody3D = null
var _lines: Array = []          # lines tied to the bait it holds, each [line, where it was tied on the bait]
var _patience := 0.0            # seconds left to get the bait before it gives up
var _hook_layers := Vector2i.ZERO


func _ready() -> void:
	if swim_bladder:
		density = water_surface.density if water_surface is BoundedBuoyancyWater else water_density
	super._ready()
	if Engine.is_editor_hint():
		return
	if random_seed != 0:
		_rng.seed = random_seed
	else:
		_rng.randomize()
	_home = global_position
	# Its tail: its own, or the one a copy of a fish brings with it.
	for c in get_children(true):
		if c is _Thruster:
			_tail = c
	if _tail == null:
		_tail = _Thruster.new()
		_tail.medium = _Thruster.Medium.WATER
		add_child(_tail, false, Node.INTERNAL_MODE_BACK)
	_tail.throttle = 0.0
	_new_goal()


func _exit_tree() -> void:
	# Taken out of the water (freed, or removed from the scene) with the bait in its mouth: it lets go.
	if not Engine.is_editor_hint() and state in [State.TAKE, State.HOOKED, State.TIRED]:
		_let_go_of_bait()
		_target_bait = null
		state = State.WANDER


## Its mouth, in the world.
func mouth_position() -> Vector3:
	return global_transform * mouth


func _physics_process(dt: float) -> void:
	if Engine.is_editor_hint():
		return
	if swim_bladder and water:
		# Its swim bladder matches the water where it is, whatever the depth, salt or warmth.
		var here: float = water.density_at(global_transform * _centroid)
		if absf(density - here) > 1e-6:
			density = here
	super._physics_process(dt)
	if freeze or dt <= 0.0:
		return
	_tail.max_thrust = max_thrust
	_tail.max_speed = burst_speed
	_tail.diameter = maxf(_box_size.y, 0.01)
	_think(dt)
	var full := clampf(_speed / burst_speed, 0.0, 1.0)
	effort = minf(full, 0.15 + 0.85 * stamina) if state in [State.HOOKED, State.TIRED, State.FREE] else full
	_tail.throttle = effort
	# Fighting tires it; out of the fight (or spent and only drifting) it gets its strength back, slowly.
	if state == State.HOOKED:
		stamina = maxf(stamina - effort * dt / endurance, 0.0)
	else:
		stamina = minf(stamina + (1.0 - effort) * dt / (4.0 * endurance), 1.0)
	_steer(dt)


func _think(dt: float) -> void:
	var here := global_position
	_wary = maxf(_wary - dt, 0.0)
	match state:
		State.WANDER:
			_speed = cruise_speed
			_goal_time -= dt
			if _goal_time <= 0.0 or here.distance_to(_goal) < 0.5:
				_new_goal()
			if _wary <= 0.0:
				var b := _find_bait()
				if b and _rng.randf() < appetite * dt:
					_target_bait = b
					_nibbles_left = _rng.randi_range(1, maxi(nibbles, 1)) if nibbles > 0 else 0
					_patience = 40.0
					state = State.APPROACH
					noticed_bait.emit(b)
		State.APPROACH:
			_patience -= dt
			if not _bait_ok() or _patience <= 0.0:
				_wary = wary_time if _patience <= 0.0 else _wary
				_back_to_wander()
				return
			var b := _target_bait.global_position
			var off := (here - b)
			off.y = 0.0
			off = off.normalized() * 0.25 if off.length() > 1e-3 else Vector3(0.25, 0, 0)
			var to := mouth_position().distance_to(b)
			_goal = b if to < 0.4 else b + off
			_speed = clampf(to, 0.15, 1.0) * cruise_speed
			if to < _reach():
				if _nibbles_left > 0:
					state = State.NIBBLE
					_tug = 0.12
					_timer = 0.0
					nibbled.emit(_target_bait)
				else:
					_take()
		State.NIBBLE:
			_patience -= dt
			if not _bait_ok() or _patience <= 0.0:
				_wary = wary_time if _patience <= 0.0 else _wary
				_back_to_wander()
				return
			var b := _target_bait.global_position
			if _tug > 0.0:
				_tug -= dt
				var away := (here - b).normalized() + Vector3.DOWN * 0.5
				_target_bait.apply_central_force(away.normalized() * bite_pull)
				_goal = b
				_speed = 0.1
				if _tug <= 0.0:
					_nibbles_left -= 1
					_timer = _rng.randf_range(0.5, 1.6)
			else:
				# Backs off a little between nibbles.
				_goal = b + (here - b).normalized() * 0.3
				_speed = 0.2
				_timer -= dt
				if _timer <= 0.0:
					state = State.APPROACH
		State.TAKE:
			_timer -= dt
			_hold_hook()
			_speed = cruise_speed
			if here.distance_to(_goal) < 0.4:
				_goal = here + _flat(-global_transform.basis.z).rotated(Vector3.UP, _rng.randf_range(-1.0, 1.0)) * 3.0
			# Struck: the angler's line pulled hard (or the fish ran against a tight one).
			for held in _lines:
				var l: Node3D = held[0]
				if is_instance_valid(l) and _chain_from(l)[-1].tension > strike_pull:
					state = State.HOOKED
					line = l
					_slack = 0.0
					hooked.emit()
					return
			if _timer <= 0.0:
				_drop()
		State.HOOKED, State.TIRED:
			_hold_hook()
			if line == null or not is_instance_valid(line):
				_escape()
				return
			var chain := lines_to_angler()
			for l in chain:
				if l.broken:
					_escape()
					return
			var angler: Node3D = chain[-1]
			# A slack line from the angler and the hook works loose.
			_slack = _slack + dt if angler.tension <= 0.0 else 0.0
			if slack_escape > 0.0 and _slack > slack_escape:
				_escape()
				return
			if state == State.HOOKED and stamina < 0.12:
				state = State.TIRED
				tired.emit()
			elif state == State.TIRED and stamina > 0.35:
				state = State.HOOKED   # one more run
			var pull: Vector3 = (angler.global_position - mouth_position()).normalized()
			if state == State.TIRED:
				_speed = 0.1 * burst_speed
				_goal = here + _flat(-global_transform.basis.z) * 2.0
			else:
				_veer_time -= dt
				if _veer_time <= 0.0:
					_veer = _rng.randf_range(-0.7, 0.7)
					_veer_time = _rng.randf_range(1.5, 4.0)
				var run := _flat(-pull).rotated(Vector3.UP, _veer)
				_goal = here + run * 4.0 + Vector3.DOWN * 1.5
				_speed = burst_speed
		State.FREE:
			_speed = burst_speed if _timer > 0.0 else cruise_speed
			_timer -= dt
			if here.distance_to(_goal) < 0.5:
				_goal = here + _flat(-global_transform.basis.z) * 5.0
			if _timer < -5.0:
				_home = here
				_back_to_wander()
	# Stay between min_depth and max_depth (the goal's depth), in the water; after bait, it goes where
	# the bait is, short of the surface.
	var surface: float = water.height_at(_goal) if water else _goal.y + min_depth
	if state in [State.APPROACH, State.NIBBLE]:
		_goal.y = minf(_goal.y, surface - 0.05)
	else:
		_goal.y = clampf(_goal.y, surface - max_depth, surface - min_depth)


## The lines from its mouth back to the angler, through any float or weight between: the first is the
## one tied to it, the last the one the angler holds.
func lines_to_angler() -> Array:
	return _chain_from(line) if line and is_instance_valid(line) else []


func _chain_from(first: Node3D) -> Array:
	var chain: Array = [first]
	for i in 8:
		var holder: Node = chain[-1].get(&"_holder")
		var next: Node3D = null
		if holder:
			for other in get_tree().get_nodes_in_group(&"bounded_buoyancy_lines"):
				if other.body == holder and not chain.has(other):
					next = other
					break
		if next == null:
			break
		chain.append(next)
	return chain


## How far from its mouth it can suck in bait: half the distance from its middle to its mouth.
func _reach() -> float:
	return maxf(0.5 * mouth.length(), 0.02)


func _new_goal() -> void:
	var a := _rng.randf() * TAU
	var r := sqrt(_rng.randf()) * home_range
	var surface: float = water.height_at(_home) if water else _home.y
	_goal = _home + Vector3(cos(a) * r, 0.0, sin(a) * r)
	_goal.y = surface - _rng.randf_range(min_depth, max_depth)
	_goal_time = _rng.randf_range(4.0, 10.0)


func _find_bait() -> RigidBody3D:
	var best: RigidBody3D = null
	var near := sense_range
	var candidates: Array = [bait] if bait else get_tree().get_nodes_in_group(&"bounded_buoyancy_bait")
	for b in candidates:
		if b is RigidBody3D and is_instance_valid(b) and b.is_inside_tree() and not b.freeze:
			var d := global_position.distance_to(b.global_position)
			if d < near and (water == null or b.global_position.y < water.height_at(b.global_position)):
				near = d
				best = b
	return best


func _bait_ok() -> bool:
	return _target_bait != null and is_instance_valid(_target_bait) and not _target_bait.freeze \
		and global_position.distance_to(_target_bait.global_position) < sense_range * 1.5


func _back_to_wander() -> void:
	state = State.WANDER
	_target_bait = null
	_new_goal()


func _take() -> void:
	state = State.TAKE
	_timer = take_time
	_lines.clear()
	for l in get_tree().get_nodes_in_group(&"bounded_buoyancy_lines"):
		if l.body == _target_bait and not l.broken:
			_lines.append([l, l.end_offset])
			l.body = self
			l.end_offset = mouth
	_target_bait.freeze = true
	_hook_layers = Vector2i(_target_bait.collision_layer, _target_bait.collision_mask)
	_target_bait.collision_layer = 0
	_target_bait.collision_mask = 0
	_goal = global_position + _flat(-global_transform.basis.z) * 3.0
	took_bait.emit(_target_bait)


## The bait (the hook) stays in its mouth.
func _hold_hook() -> void:
	if _target_bait and is_instance_valid(_target_bait):
		_target_bait.global_position = mouth_position()


func _let_go_of_bait() -> void:
	var has_bait := _target_bait != null and is_instance_valid(_target_bait)
	for held in _lines:
		var l: Node3D = held[0]
		if is_instance_valid(l) and l.body == self:
			# Tied back to the bait as it was; the bait gone, the line hangs free.
			l.body = _target_bait if has_bait else null
			l.end_offset = held[1]
	_lines.clear()
	line = null
	if has_bait:
		_target_bait.collision_layer = _hook_layers.x
		_target_bait.collision_mask = _hook_layers.y
		_target_bait.freeze = false
		_target_bait.linear_velocity = linear_velocity


func _drop() -> void:
	var b := _target_bait
	_let_go_of_bait()
	_wary = wary_time
	_back_to_wander()
	dropped_bait.emit(b)


func _escape() -> void:
	_let_go_of_bait()
	_target_bait = null
	state = State.FREE
	_timer = 4.0
	_wary = wary_time * 4.0
	_goal = global_position + _flat(-global_transform.basis.z) * 5.0
	escaped.emit()


static func _flat(v: Vector3) -> Vector3:
	v.y = 0.0
	return v.normalized() if v.length_squared() > 1e-8 else Vector3.FORWARD


## Turn toward the goal and keep upright: a turn rate toward each, reached over a quarter of a
## second against its own inertia, never faster than turn_rate.
func _steer(dt: float) -> void:
	var state3 := PhysicsServer3D.body_get_direct_state(get_rid())
	if state3 == null:
		return
	var b := global_transform.basis.orthonormalized()
	var fwd := -b.z
	var to := _goal - global_position
	var want := Vector3.ZERO
	if to.length() > 0.05:
		var d := to.normalized()
		# Fish swim level-ish: no steeper than 40°, unless right at what they are after.
		var steep := tan(deg_to_rad(40.0))
		if to.length() > 0.5 and absf(d.y) > Vector2(d.x, d.z).length() * steep:
			d = (_flat(d) + Vector3.UP * signf(d.y) * steep).normalized()
		var axis := fwd.cross(d)
		var angle := atan2(axis.length(), fwd.dot(d))
		if axis.length() > 1e-6:
			want += axis.normalized() * angle * 3.0
	if state != State.TIRED:
		# Upright: its back toward the sky, about its own length.
		var up := Vector3.UP - fwd * fwd.y
		if up.length() > 1e-3:
			var roll := b.y.cross(up.normalized())
			want += fwd * roll.dot(fwd) * 4.0
	var limit := deg_to_rad(turn_rate)
	if want.length() > limit:
		want = want.normalized() * limit
	var tau := maxf(0.25, 2.0 * dt)
	var inv := state3.inverse_inertia_tensor
	if inv.determinant() == 0.0:
		return
	apply_torque(inv.inverse() * (want - angular_velocity) / tau)
