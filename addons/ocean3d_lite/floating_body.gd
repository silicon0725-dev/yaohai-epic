@tool
class_name FloatingBody
extends RigidBody3D

# Multi-probe buoyancy. Each probe samples the water height under it and
# applies an upward force proportional to how deep it sits. Probes at the
# corners give you pitch and roll for free as waves pass underneath.
# Probe points draw as crosses in the 3D editor (see the Ocean3D gizmo).
#
# Tuning notes:
# - buoyancy_strength sets the resting waterline. Equilibrium submersion
#   depth is roughly Ocean.GRAVITY / buoyancy_strength meters (36.0 gives
#   ~0.27m). Size it per body, against hull height: on a hull only 0.5m
#   tall, anything near 20 puts the deck at the waterline and waves
#   swamp it. Small bodies (a barrel, a crate) need much higher values,
#   because this sets absolute draft depth, not relative density.
# - Drag values fake water resistance. Raise linear drag for a heavier,
#   wallowing feel; raise angular drag to calm down rocking.
# - vertical_damping resists each probe's motion relative to the moving
#   water surface, not relative to the world. This is what lets small
#   bodies ride waves instead of pogo-sticking through them (undamped)
#   or hanging still while crests wash over (world-frame damping).
#   Critical damping is about 2 * sqrt(buoyancy_strength).

@export var probe_points: Array[Vector3] = []:
	set(value):
		probe_points = value
		update_gizmos()
# Optional per-probe share of the total lift, parallel to probe_points.
# Empty means equal shares. A builder system can weight probes by the
# buoyancy of the hull section nearest each one, so a buoyant stern
# rides high while a waterlogged bow digs in.
@export var probe_weights: Array[float] = []:
	set(value):
		probe_weights = value
		update_gizmos()
@export var buoyancy_strength := 36.0
@export var max_depth_force := 2.0
@export var vertical_damping := 6.0
@export var water_linear_drag := 1.4
@export var water_angular_drag := 1.8
@export var air_angular_drag := 0.05

# Last tick's water height per probe, for the surface-velocity finite
# difference. Sampling the height once and differencing beats calling
# Ocean.get_surface_velocity_y (3 extra Gerstner inversions per probe),
# which matters when a big hull carries a probe per cell.
var _prev_water_h := PackedFloat32Array()


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	# The engine's world defaults (physics/3d/default_linear_damp and
	# default_angular_damp, both 0.1) silently COMBINE with per-body
	# damp. On a heavy hull that is a hidden brake per m/s that caps
	# top speed no matter how much force drives it. REPLACE makes this
	# component's numbers the only water/air damping there is.
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	if probe_points.is_empty():
		# Fallback: a unit footprint. Real bodies should set their own probes.
		probe_points = [
			Vector3(-0.5, 0.0, -0.5),
			Vector3(0.5, 0.0, -0.5),
			Vector3(-0.5, 0.0, 0.5),
			Vector3(0.5, 0.0, 0.5),
		]


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# A frozen body never integrates, so forces applied to it PILE UP
	# in the physics server and release as one giant kick on unfreeze.
	# Apply nothing while frozen; clearing the height history restarts
	# the surface-velocity finite difference cleanly on unfreeze
	# instead of differencing against stale water.
	if freeze:
		_prev_water_h.resize(0)
		return
	var n := probe_points.size()
	var weighted := probe_weights.size() == n
	var w_sum := 0.0
	if weighted:
		for w in probe_weights:
			w_sum += w
		weighted = w_sum > 0.0

	# Probe set changed (rebuild): reset the height history.
	var fresh := _prev_water_h.size() != n
	if fresh:
		_prev_water_h.resize(n)

	var submerged_count := 0
	for i in n:
		var share := (probe_weights[i] / w_sum) if weighted else (1.0 / n)
		var world_p := to_global(probe_points[i])
		var water_h: float = Ocean.get_height(world_p.x, world_p.z)
		var water_vel_y := 0.0
		if not fresh:
			water_vel_y = (water_h - _prev_water_h[i]) / delta
		_prev_water_h[i] = water_h
		var depth: float = water_h - world_p.y
		if depth > 0.0:
			submerged_count += 1
			var offset := world_p - global_position
			var force := Vector3.UP * buoyancy_strength * mass * share \
				* minf(depth, max_depth_force)
			# Damp against the surface's own vertical motion so the body
			# tracks the wave rather than the world rest frame.
			var probe_vel_y := linear_velocity.y + angular_velocity.cross(offset).y
			var rel_vel_y := probe_vel_y - water_vel_y
			force += Vector3.DOWN * rel_vel_y * vertical_damping * mass * share
			apply_force(force, offset)

	if submerged_count > 0:
		var frac := float(submerged_count) / probe_points.size()
		linear_damp = water_linear_drag * frac
		angular_damp = water_angular_drag * frac
	else:
		linear_damp = 0.0
		angular_damp = air_angular_drag
