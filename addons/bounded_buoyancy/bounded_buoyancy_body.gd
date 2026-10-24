@icon("res://addons/bounded_buoyancy/icon.svg")
class_name BoundedBuoyancyBody
extends RigidBody3D
## Bounded Buoyancy for Godot 4.4+: buoyancy with the added mass of the submerged part
## in the body's inertia, every physics step.
##
## Buoyancy drives no fall faster than g and no rise faster than g/C, for every density (drag and
## collisions act on top); the first frame after a release is the classical value, and momentum is
## kept as the body enters the water. Buoyancy acts at the centre of the immersed volume, so bodies
## of any shape tilt, roll and right themselves: a raft settles flat, a log floats on its side, and a
## boat with a low centre of mass comes back upright.
##
## Method and benchmarks: Parkyn, N. (2026). Bounded Buoyancy: Added Mass and Two Ceilings
## for Stable, Accurate Buoyancy in Game and Simulation Engines, v1.1. Companion paper to
## ValerieX (VXXX) v2.2. Zenodo. Licence: MIT.
##
## Use: give a RigidBody3D one or more CollisionShape3D children (sphere, box, cylinder, capsule or
## convex polygon) and this script, set its density, and set the water level. For any other shape,
## such as a detailed hull, set buoyancy_mesh to a closed mesh. The script sets the body's mass,
## turns off its built-in gravity and damping, and applies weight, buoyancy, drag and the righting
## moment itself. Other forces (collisions, pushes) act as usual and are resisted by the full
## inertia, water included. Drag acts on the body's speed through the water and through the air, so
## a current carries it along and wind pushes it; neither is set moving by the body.
##
## Water: once a scene has any BoundedBuoyancyWater node, the body floats only inside one (riding
## its waves and drifting with its current). Without one, it uses water_level, or the height of the
## water_surface node. Entering or leaving the water emits water_entered or water_exited, and the
## water node draws a splash.
##
## Air: the part of the body out of the water is in air, which the same law covers with air's
## density. A helium balloon rises and a hot-air balloon lifts off when heated (change density
## while running); with air_half_height set, the air thins with height and balloons float at a level.
## A BoundedBuoyancyWind node makes the air move, and a sail (sail_area) lets the wind drive a boat.
##
## Boats: BoundedBuoyancyFoil children (keels, rudders, sails) and BoundedBuoyancyThruster children
## (propellers, fans) are applied after the buoyancy each step, each with a bounded impulse at its
## own point, so a boat holds its course, steers, sails across and into the wind, and drives.
##
## Flooding: BoundedBuoyancyCompartment children are spaces inside the body that fill with water
## through their holes. The water inside is weight the body carries, at the water's own centre, so a
## holed ship settles, lists toward its flooded side and sinks or capsizes.

## The body has just touched the water, at `speed` (m/s, through the water) at the world point `at`
## on the surface. Use it for splash sounds.
signal water_entered(speed: float, at: Vector3)
## The body has just come wholly out of the water.
signal water_exited(speed: float, at: Vector3)

enum Model {
	BOUNDED, ## Added mass of the submerged part in the inertia (Bounded Buoyancy).
	USUAL,   ## Buoyancy applied to the body's own mass, as most engines do. For comparison.
}

## Which buoyancy model to use. USUAL is there for side-by-side comparisons.
@export var model: Model = Model.BOUNDED
## Density of the body. The body's own mass is density x volume of its shape. It can be changed
## while running: ballast tanks, or a hot-air balloon whose air is heated (helium balloon about 0.5).
@export_range(0.01, 20000.0, 0.01, "or_greater", "suffix:kg/m³") var density: float = 500.0:
	set(value):
		density = maxf(value, 0.001)
		if volume > 0.0:
			own_mass = density * volume
			if _auto_inertia:
				inertia = _unit_inertia * density
## Added-mass coefficient C of the shape: 0.5 for a sphere, about 1 for a long cylinder
## moving side-on. Buoyancy-driven rising is capped at g/C.
@export_range(0.0, 5.0, 0.01) var added_mass_coefficient: float = 0.5
## Height of a flat water surface, in world units. Used when the scene has no BoundedBuoyancyWater
## and water_surface is not set.
@export var water_level: float = 0.0
## Optional node for the water surface: a BoundedBuoyancyWater (its surface, waves and current are
## used), or any Node3D whose global Y is a flat surface. If set, it takes priority over water nodes.
@export var water_surface: Node3D
## Density of the water (or other liquid). A BoundedBuoyancyWater uses its own density instead.
@export_range(1.0, 20000.0, 1.0, "or_greater", "suffix:kg/m³") var water_density: float = 1000.0
## Quadratic drag coefficient (0.47 for a sphere), in the water and in the air.
@export_range(0.0, 3.0, 0.01) var drag_coefficient: float = 0.47
## Damping of spin in the water, per second when fully submerged; it scales with the submerged
## fraction. It stands in for the energy that rolling and pitching lose to the water. In air it acts in
## proportion to how light the body is against the air, so balloons are steadied and stones are not.
@export_range(0.0, 20.0, 0.01, "or_greater", "suffix:1/s") var angular_drag: float = 3.0
## Keep momentum when the added mass grows as the body enters the water (von Kármán, 1929).
@export var keep_momentum_on_entry: bool = true
## Wave-making damping: a body bobbing at the surface sends out ripples that carry its energy away,
## so it settles: within a few bobs if it is wide and shallow (a raft, a boat), slowly if it is deep
## and narrow (a post, a spar buoy), as linear wave theory gives it. It acts on bobbing relative to
## the surface, so riding waves is not held back. 1 is the physics; 0 leaves it out, as the paper's
## benchmarks do; other values scale it. Bounded model only.
@export_range(0.0, 3.0, 0.01) var wave_damping: float = 1.0

@export_group("Air")
## The air is real air by default: the standard atmosphere, thinning with height, from the scene's
## BoundedBuoyancyAir (the day's temperature, pressure and humidity at sea level) or, without one, at
## 15 °C with sea level at height 0; warmer where a BoundedBuoyancyThermal warms it. Balloons rise
## in it; for wood, stone or metal it changes the weight by less than half a percent.
## Use Air Density and Air Half Height below instead of the real air. Setting either sets this.
@export var fixed_air: bool = false
## With Fixed Air: density of the air around the body at height 0 (1.2 kg/m³ at room temperature).
## 0 leaves air out, as the paper's benchmarks do. Setting it fixes the air (Fixed Air).
@export_range(0.0, 20.0, 0.001, "or_greater", "suffix:kg/m³") var air_density: float = 1.2:
	set(value):
		air_density = value
		fixed_air = true
## With Fixed Air: height over which the air's density halves, so that a balloon rises until it
## floats where the air is as dense as it is. 0 keeps the air the same at every height. Real air
## halves about every 6 km; games can use far less. Setting it fixes the air (Fixed Air).
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:m") var air_half_height: float = 0.0:
	set(value):
		air_half_height = value
		fixed_air = true
## Area of a sail or flag for the wind to push on, in square metres, as well as the body itself.
## The sail turns to face the wind it feels, like a sail let out to run before the wind.
@export_range(0.0, 1000.0, 0.01, "or_greater", "suffix:m²") var sail_area: float = 0.0
## Where on the body the wind pushes the sail, in the body's own coordinates. Above the centre of
## mass the push heels the body over; a low centre of mass (ballast) holds it up.
@export var sail_centre: Vector3 = Vector3(0.0, 0.5, 0.0)

@export_group("Shape")
## Optional closed mesh used for buoyancy instead of the collision shapes, in the body's own
## coordinates: for example a simplified, watertight hull of a boat. Leave empty to use the shapes.
@export var buoyancy_mesh: Mesh
## Facets around the curve of cylinders, capsules and spheres that share a body with other
## shapes. The volume is corrected to the exact value, so a few facets are enough.
@export_range(8, 64, 1) var curve_segments: int = 16

## The body's own mass, density x volume (kg).
var own_mass: float = 0.0
## Volume of the body's shape (m³).
var volume: float = 0.0
## Submerged volume this step (m³).
var submerged_volume: float = 0.0
## Added mass of the submerged part this step (kg).
var added_mass: float = 0.0
## Acceleration produced by weight, buoyancy and drag in the last step (m/s²).
var last_acceleration: Vector3 = Vector3.ZERO
## Centre of the submerged volume this step, in world space. The water's buoyancy acts here.
var centre_of_buoyancy: Vector3 = Vector3.ZERO
## Density of the air at the body this step (kg/m³).
var air_density_here: float = 0.0
## Velocity of the wind at the body this step (m/s, world frame).
var wind_here: Vector3 = Vector3.ZERO
## The BoundedBuoyancyWater the body is in this step, if any.
var water: Node3D = null
## Wave-making damping of bobbing this step, N per m/s (0 when the body is not at the surface).
var heave_damping: float = 0.0
## Upward acceleration of the water in the waves at the body this step (m/s²), which pushes it.
var wave_acceleration: float = 0.0
## Mass of the water inside the body's compartments this step (kg).
var flood_mass: float = 0.0
## Mean density of the water the body displaces this step, kg/m³ (the water's own, or, where it
## changes from place to place, what the body's part in each place weighs).
var water_density_here: float = 0.0
## How much harder the water it is in is to move through than water this step (1 for water; mud more).
var medium_drag: float = 1.0

## Use the native kernel (addons/bounded_buoyancy_native) when it is installed. The results are the
## same either way; the native kernel is many times faster for bodies crossing the surface.
static var use_native := true
static var _kernel: RefCounted = null
static var _kernel_checked := false
static var _g := 9.8
static var _g_frame := -1
const _Water := preload("res://addons/bounded_buoyancy/bounded_buoyancy_water.gd")
const _Wind := preload("res://addons/bounded_buoyancy/bounded_buoyancy_wind.gd")
const _Air := preload("res://addons/bounded_buoyancy/bounded_buoyancy_air.gd")
const _Foil := preload("res://addons/bounded_buoyancy/bounded_buoyancy_foil.gd")
const SAIL_DRAG := 1.2     # drag coefficient of a flat sail facing the wind
const TELEPORT_DISTANCE := 0.1   # a body this far from where its velocity would have carried it, or water whose level moves this far in a step, has been moved (m)

var _single_sphere := false
var _radius := 0.0
var _sphere_centre := Vector3.ZERO            # body space
var _verts := PackedVector3Array()            # body-space vertices, each stored once
var _idx := PackedInt32Array()                # three vertex indices per triangle
var _tri_weight := PackedFloat32Array()       # orientation sign x exact/faceted volume, per triangle
var _depth := PackedFloat32Array()            # depth of each vertex below the surface, this step
var _centroid := Vector3.ZERO                 # body space
var _bound_radius := 0.0                      # about _centroid
var _area := 0.0
var _face_area := Vector3.ZERO                # area seen looking along each body axis, for drag
var _box_size := Vector3.ZERO                 # bounding box along the body axes
var _prev_added_mass := -1.0
var _auto_inertia := false
var _was_in_water := false
var _first_step := true
var _unit_inertia := Vector3.ZERO             # own rotational inertia per unit density
var _auto_com := false
var _set_up := false
var _warned := false
var _world: World3D
var _world_has_water := false
var _prev_surface := NAN                      # height of the surface under the body last step
var _prev_water: Node3D = null                # the water it was in then
var _prev_level := 0.0                        # that water's level
var _prev_com := Vector3.ZERO                 # where its centre of mass was
var _prev_frame := -1                         # and which physics frame that was
var _foils: Array = []                        # BoundedBuoyancyFoil nodes under the body
var _thrusters: Array = []                    # BoundedBuoyancyThruster nodes under the body
var _compartments: Array = []                 # BoundedBuoyancyCompartment nodes under the body
var _prev_flood := 0.0                        # flood water's mass last step
var _flooded := false                         # the inertia includes flood water
var _dry_inertia := Vector3.ZERO              # the inertia without it, when set by hand
var _wet_inertia := Vector3.ZERO              # the inertia as last set with it
var _interfaces: Array = []                   # boundaries between layers the body is across: [jump in density, volume below, depth of its centre]
var _flood_torque := Vector3.ZERO             # the flood water's weight about the centre of mass, this step


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if not _kernel_checked:
		_kernel_checked = true
		if ClassDB.class_exists(&"BoundedBuoyancyKernel"):
			_kernel = ClassDB.instantiate(&"BoundedBuoyancyKernel")
	# Shapes added after the body joins the scene are picked up on the first physics step.
	_build_shape()
	if volume > 0.0:
		_set_up_body()


## Re-read the body's collision shapes or buoyancy mesh. Call it after adding, removing or resizing
## shapes while the game runs; the mass, centre of mass and inertia follow (unless set by hand).
func rebuild_shape() -> void:
	_build_shape()
	if volume <= 0.0:
		return
	if not _set_up:
		_set_up_body()
		return
	own_mass = density * volume
	if _auto_com:
		center_of_mass = _centroid
	if _auto_inertia:
		_unit_inertia = _own_inertia(center_of_mass) / density
		inertia = _unit_inertia * density


func _set_up_body() -> void:
	_set_up = true
	_world = get_world_3d()
	own_mass = density * volume
	mass = own_mass
	gravity_scale = 0.0
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = 0.0
	# Put the centre of mass at the centre of the volume, so both physics engines agree, unless
	# it has been set by hand (a lower centre of mass is how a boat is given ballast).
	if center_of_mass_mode == RigidBody3D.CENTER_OF_MASS_MODE_AUTO or _auto_com:
		_auto_com = true
		center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		center_of_mass = _centroid
	# Fix the rotational inertia at the body's own value. Engines that derive inertia from mass
	# would otherwise scale it with the added mass each step.
	if inertia == Vector3.ZERO:
		_unit_inertia = _own_inertia(center_of_mass) / density
		_auto_inertia = true
		inertia = _unit_inertia * density


func _physics_process(dt: float) -> void:
	if Engine.is_editor_hint():
		return
	if not _set_up:
		_build_shape()
		if volume <= 0.0:
			if not _warned:
				_warned = true
				push_warning("BoundedBuoyancyBody '%s': needs a CollisionShape3D child (sphere, box, cylinder, capsule or convex polygon) or a closed buoyancy_mesh." % name)
			return
		_set_up_body()
	if freeze:
		_prev_added_mass = -1.0
		_prev_surface = NAN
		last_acceleration = Vector3.ZERO
		return
	var frame := Engine.get_physics_frames()
	if frame != _g_frame:
		_g = float(ProjectSettings.get_setting("physics/3d/default_gravity"))
		_g_frame = frame
	var g := _g
	var xf := global_transform
	var cw := xf * _centroid
	var rho := water_density
	var flow := Vector3.ZERO
	var surface_here := 0.0   # height of the surface over the centre of the body's volume
	medium_drag = 1.0
	_interfaces.clear()
	water = _find_water(cw)
	if water:
		rho = water.density
		flow = water.current_at(cw)
		surface_here = water.height_at(cw)
		_immerse(xf, surface_here, water)
		if submerged_volume > 0.0 and water.is_layered():
			rho = _weigh_displaced(xf, water)
	elif water_surface or not _world_has_water:
		surface_here = water_surface.global_position.y if water_surface else water_level
		_immerse(xf, surface_here)
	else:
		submerged_volume = 0.0
		centre_of_buoyancy = cw
	water_density_here = rho if submerged_volume > 0.0 else 0.0
	# The rest of the body is in air: real air, or as set (thinning with height if air_half_height is).
	if fixed_air:
		air_density_here = air_density
		if air_half_height > 0.0:
			air_density_here *= pow(0.5, maxf(cw.y / air_half_height, -10.0))
	else:
		air_density_here = _Air.density_in(_world, cw)
	var air_volume := volume - submerged_volume
	var displaced := rho * submerged_volume + air_density_here * air_volume   # mass of water and air displaced
	added_mass = added_mass_coefficient * displaced
	# Water in the compartments: weight the body carries, at the water's own centre.
	flood_mass = _flood(xf, rho, g, dt) if not _compartments.is_empty() or _flooded else 0.0
	if _prev_added_mass < 0.0:
		# The first step, or the first since it was frozen: the water it carries and takes along now
		# is its own.
		_prev_added_mass = added_mass
		_prev_flood = flood_mass
	var in_water := submerged_volume > 0.0
	if _first_step:
		_was_in_water = in_water
		_first_step = false
	elif in_water != _was_in_water:
		_was_in_water = in_water
		_report_crossing(in_water, cw, flow)

	var carried := own_mass + flood_mass   # what the body weighs: itself and the water inside it
	var inertial_mass := carried + added_mass if model == Model.BOUNDED else carried
	var v_start := linear_velocity
	var v := v_start
	if model == Model.BOUNDED and keep_momentum_on_entry:
		# Water taken along, or let in, starts with the water's own velocity, so momentum is shared
		# relative to the water.
		var grown := maxf(added_mass - _prev_added_mass, 0.0) + maxf(flood_mass - _prev_flood, 0.0)
		if grown > 0.0:
			v = flow + (v - flow) * ((inertial_mass - grown) / inertial_mass)

	# Density-state drive (weight minus buoyancy), then drag applied implicitly, as engines
	# apply damping. Drag acts on the body's speed through each medium: through the water (which
	# may be flowing) on the part under water, and through the air on the rest. With still water
	# and air this reproduces the reference update of the paper step for step.
	var drive := Vector3.UP * (displaced - carried) * g
	# The water's own motion in waves pushes the body with it. The pressure in an accelerating wave
	# gives the water the body displaces the water's acceleration (ρ V a), and the water it takes
	# along is set moving by the waves as well as by the body (C ρ V a): (1 + C) ρ V a in all, a the
	# water's upward acceleration at the centre of buoyancy, averaged over the body's footprint as its
	# buoyancy is. So a floating body rises and falls with the waves as linear wave theory gives, not a
	# little further, and a body under water moves up and down with the water round it. Water under a
	# real wave never accelerates faster than about half of g (steeper waves break), so a is held to that.
	wave_acceleration = 0.0
	if model == Model.BOUNDED and submerged_volume > 0.0 and water and (water.wave_height > 0.0 or water.surface_source or water.height_function.is_valid()):
		var b := xf.basis
		var across := absf(b.x.x) * _box_size.x + absf(b.y.x) * _box_size.y + absf(b.z.x) * _box_size.z
		var along := absf(b.x.z) * _box_size.x + absf(b.y.z) * _box_size.y + absf(b.z.z) * _box_size.z
		var a: float = water.vertical_acceleration_at(centre_of_buoyancy, across, along)
		wave_acceleration = clampf(a, -0.5 * g, 0.5 * g)
		drive += Vector3.UP * (1.0 + added_mass_coefficient) * rho * submerged_volume * wave_acceleration
	var wind := _Wind.total_at(cw, _world) if not (_Wind.instances.is_empty() and BoundedBuoyancyThermal.instances.is_empty()) else Vector3.ZERO
	wind_here = wind
	var through_water := v - flow
	var through_air := v - wind
	var c_water := 0.5 * drag_coefficient * medium_drag * _drag_area(through_water, xf.basis) * rho * submerged_volume / volume \
		* through_water.length() * dt / inertial_mass
	var c_air := 0.5 * _air_drag_coefficient(through_air.length()) * _drag_area(through_air, xf.basis) * air_density_here * air_volume / volume \
		* through_air.length() * dt / inertial_mass
	var c_sail := 0.5 * SAIL_DRAG * sail_area * air_density_here * through_air.length() * dt / inertial_mass
	var v_target := (v + drive / inertial_mass * dt + c_water * flow + (c_air + c_sail) * wind) / (1.0 + c_water + c_air + c_sail)
	var sail_target := v_target

	# Wave-making damping: bobbing relative to the surface under the body (which rises and falls with
	# any waves, so riding them is not held back) sends out ripples that carry its energy away. It acts
	# on the speed at the start of the step, so a body let go from rest starts exactly as before, and
	# takes away less than that speed, so it slows the bobbing but never reverses it. The surface's
	# own rise and fall is read from its height under the body last step, unless the body has since
	# moved to other water, been moved by more than its speed (a teleport), or missed a step, or the
	# water itself has been moved up or down by more than that.
	heave_damping = 0.0
	if model == Model.BOUNDED and wave_damping > 0.0 and submerged_volume > 0.0 and submerged_volume < volume * (1.0 - 1e-9):
		var com_now := xf * center_of_mass
		var level_now: float = water.global_position.y if water else (water_surface.global_position.y if water_surface else water_level)
		var follows := not is_nan(_prev_surface) and water == _prev_water and frame == _prev_frame + 1 \
			and absf(level_now - _prev_level) < TELEPORT_DISTANCE \
			and (com_now - _prev_com - v_start * dt).length_squared() < TELEPORT_DISTANCE * TELEPORT_DISTANCE
		var surface_rate := (surface_here - _prev_surface) / dt if follows else 0.0
		_prev_surface = surface_here
		_prev_water = water
		_prev_level = level_now
		_prev_com = com_now
		_prev_frame = frame
		# wave_damping_coefficient() and at_surface(), written out here, as this runs for every body.
		var depth := surface_here - centre_of_buoyancy.y
		if depth > 1e-9 and rho > 0.0 and g > 0.0:
			var draft := 2.0 * depth
			var waterplane := submerged_volume / draft
			var x := pow(waterplane / (draft * draft), 0.869)
			heave_damping = wave_damping * 2.0 * 0.0182 * x / (1.0 + 0.0798 * x) * sqrt(rho * g * waterplane * inertial_mass)
			# Damped for as long as it is at the surface this step: until it leaves the water or goes under.
			var rel := v.y - surface_rate
			var time := dt
			if rel > 0.0:
				time = minf(dt, draft / rel)
			elif rel < 0.0:
				time = minf(dt, draft * (volume - submerged_volume) / submerged_volume / -rel)
			v_target.y -= (1.0 - exp(-heave_damping * time / inertial_mass)) * rel
	else:
		_prev_surface = NAN
	# The same at each boundary between layers the body is across: bobbing there sends out waves
	# along the boundary (internal waves), which carry its energy away as ripples on the surface do.
	# The same law, with the jump in density across the boundary in place of the water's against air.
	if model == Model.BOUNDED and wave_damping > 0.0:
		for f in _interfaces:
			var b_int := wave_damping * wave_damping_coefficient(f[0], g, f[1], f[2], inertial_mass)
			v_target.y -= (1.0 - exp(-b_int * dt / inertial_mass)) * v.y

	# Foils and thrusters, each a bounded impulse at its own point, after the buoyancy and drag.
	var turn := Vector3.ZERO
	if not (_foils.is_empty() and _thrusters.is_empty()):
		var r := _apply_appendages(v_target, xf, inertial_mass, rho, flow, wind, dt)
		v_target = r[0]
		turn = r[1]

	# The engine integrates F / mass over this step, so this force lands exactly on v_target.
	mass = inertial_mass
	var dv := v_target - v_start
	apply_central_force(inertial_mass * dv / dt)
	last_acceleration = (v_target - v) / dt

	# The sail's push acts at the sail's centre, so it heels the body as well as driving it.
	if c_sail > 0.0:
		var push := c_sail * inertial_mass / dt * (wind - sail_target)
		apply_torque((xf * sail_centre - xf * center_of_mass).cross(push))
	# Righting moment: the lift of the water and of the air act at the centres of the parts they
	# displace, the weight at the centre of mass.
	if displaced > 0.0:
		var centre := ((rho - air_density_here) * submerged_volume * centre_of_buoyancy + air_density_here * volume * cw) / displaced
		var arm := centre - xf * center_of_mass
		if arm.x * arm.x + arm.z * arm.z > 1e-14:
			apply_torque(arm.cross(Vector3.UP * displaced * g))
	if flood_mass > 0.0:
		apply_torque(_flood_torque)
	if turn != Vector3.ZERO:
		apply_torque(turn / dt)
	# Spin is damped by the water, and by the air in proportion to how light the body is against it.
	var damp := angular_drag * (submerged_volume + air_volume * minf(1.0, air_density_here / density)) / volume
	if absf(damp - angular_damp) > 1e-6:
		angular_damp = damp
	_prev_added_mass = added_mass
	_prev_flood = flood_mass


## Wave-making (radiation) damping of bobbing, N per m/s, for a body with `submerged` m³ under water
## whose centre of buoyancy is `depth` m below the surface and whose inertial mass (water taken along
## included) is `m` kg, in water of density `rho` under gravity `g`: B = 2 ζ m ω, with ω = √(ρ g A / m)
## its own bobbing frequency and ζ from wave_damping_ratio, for the prism with the same volume under
## water and the same depth of its centre (draft d = 2 depth, waterplane area A = V / d).
static func wave_damping_coefficient(rho: float, g: float, submerged: float, depth: float, m: float) -> float:
	if submerged <= 0.0 or depth <= 1e-9 or m <= 0.0 or rho <= 0.0 or g <= 0.0:
		return 0.0
	var draft := 2.0 * depth
	var a := submerged / draft
	var omega := sqrt(rho * g * a / m)
	return 2.0 * wave_damping_ratio(a / (draft * draft)) * m * omega


## How long in a step of `dt` a body stays at the surface (partly under), its centre of buoyancy
## `depth` below it and `dry_over_wet` its volume out of the water over its volume in, moving up at
## `rise` relative to the surface: all of the step, unless it will be out of the water, or wholly
## under, before the step ends. Measured on its equivalent prism (draft 2 x depth, the dry part
## dry_over_wet times as tall). So a body leaping out of the water or plunging into it is damped
## only while it is at the surface.
static func at_surface(depth: float, dry_over_wet: float, rise: float, dt: float) -> float:
	if rise > 0.0:
		return minf(dt, 2.0 * depth / rise)
	if rise < 0.0:
		return minf(dt, 2.0 * depth * dry_over_wet / -rise)
	return dt


## Damping ratio of bobbing from the waves a floating body makes, for a body whose waterplane area
## over its draft squared is `width_to_draft`: about 0.005 for a deep post or spar buoy (0.2), 0.05 for
## a cube or a ball floating half under (4 to 5), 0.14 for a light ball or a log (30) and 0.2 for a raft
## or a boat (100 to 400). Fitted to the exact damping ratios of linear wave theory for floating boxes,
## upright cylinders, spheres and logs, computed with the boundary-element solver Capytaine
## (reference/wave_damping.py): 0.8 to 1.5 times the exact value for flat-bottomed bodies, about 0.6
## to 0.7 times for round-bottomed ones (balls, logs) floating at least half out of the water, and more
## for heavy balls floating mostly under (4 times at nine tenths under).
static func wave_damping_ratio(width_to_draft: float) -> float:
	if not (width_to_draft > 0.0):
		return 0.0
	var x := pow(width_to_draft, 0.869)
	return 0.0182 * x / (1.0 + 0.0798 * x)


func _add_compartment(node: Node) -> void:
	if not _compartments.has(node):
		_compartments.append(node)


func _remove_compartment(node: Node) -> void:
	_compartments.erase(node)


## The compartments for one step: moves water through their holes and pumps, and puts the water's
## weight on the body. The water is weight carried at its own centre, which stays level in its
## compartment as the body leans, so its weight acts toward the low side (the free-surface effect).
## It is applied as a weight on the body plus its turning moment about the body's own centre of mass,
## which balances exactly as the weight at the shifted centre of mass would, without moving the body's
## centre of mass in the engine. The water does not turn with the body, so it adds to the inertia only
## as weight at its centre. Returns the water's mass (kg).
func _flood(xf: Transform3D, rho: float, g: float, dt: float) -> float:
	var surface: Callable
	if water:
		var w: Node3D = water
		surface = func(p: Vector3) -> float: return w.height_at(p)
	elif water_surface or not _world_has_water:
		var level: float = water_surface.global_position.y if water_surface else water_level
		surface = func(_p: Vector3) -> float: return level
	else:
		surface = func(_p: Vector3) -> float: return NAN
	var com := xf * center_of_mass
	var axes := xf.basis.orthonormalized()
	var total := 0.0
	var spin := Vector3.ZERO
	var torque := Vector3.ZERO
	for comp in _compartments:
		if not is_instance_valid(comp) or not comp.is_inside_tree():
			continue
		var r: Array = comp.flood_step(comp.global_transform, surface, rho, g, dt)
		var m: float = r[0]
		if m <= 0.0:
			continue
		var arm: Vector3 = r[1] - com
		total += m
		torque += arm.cross(Vector3.DOWN * m * g)
		var e := axes.transposed() * arm   # in the body's own axes
		spin += m * Vector3(e.y * e.y + e.z * e.z, e.x * e.x + e.z * e.z, e.x * e.x + e.y * e.y)
	_flood_torque = torque
	if _flooded and inertia != _wet_inertia:
		# Set from elsewhere while flooded (by hand, or the density or the shape changed): that is the
		# body's own inertia now.
		_dry_inertia = inertia
	if total <= 0.0:
		if _flooded:
			# Dry again: back to the body's own inertia.
			_flooded = false
			inertia = _own_inertia_now()
		return 0.0
	if not _flooded:
		_flooded = true
		_dry_inertia = inertia
	# Godot's inertia is along the body's own axes only, so the water's products of inertia (from
	# water off to one side and below, say) are left out; Unity's port includes them.
	var i := _own_inertia_now() + spin
	if (i - inertia).length_squared() > 1e-4 * i.length_squared():   # set when it has changed by 1%
		inertia = i
	_wet_inertia = inertia
	return total


## The body's own rotational inertia, without any flood water.
func _own_inertia_now() -> Vector3:
	return _unit_inertia * density if _auto_inertia else _dry_inertia


func _add_appendage(node: Node) -> void:
	var list := _foils if node is _Foil else _thrusters
	if not list.has(node):
		list.append(node)


func _remove_appendage(node: Node) -> void:
	_foils.erase(node)
	_thrusters.erase(node)


## The foils and thrusters for one step, after the buoyancy and drag that brought the body to
## velocity `v`: each gives an impulse at its own point, worked out with the motion at the end of
## the step against the inertia the body has there, so it stops the flow across a foil, or brings a
## propeller up to its speed, but never overshoots. One after another, each seeing the motion the
## ones before it left. Returns [new velocity, angular impulse about the centre of mass].
func _apply_appendages(v: Vector3, xf: Transform3D, m: float, rho: float, flow: Vector3, wind: Vector3, dt: float) -> Array:
	var w := angular_velocity
	var com := xf * center_of_mass
	var axes := xf.basis.orthonormalized()
	var angular := Vector3.ZERO
	var has_water := water != null or water_surface != null or not _world_has_water
	var level: float = water_surface.global_position.y if water_surface else water_level
	for f in _foils:
		f.force = Vector3.ZERO
		f.immersion = 0.0
		f.angle_of_attack = 0.0
		if f.area <= 0.0 or not f.is_inside_tree():
			continue
		var rest: Basis = f.rest_basis()
		var s := rest.y
		var pivot: Vector3 = f.global_position
		var in_water: bool = f.medium == _Foil.Medium.WATER
		if f.auto_trim:
			# A sail swings away from the wind it feels at its pivot.
			var air := (flow if in_water else wind) - (v + w.cross(pivot - com))
			f.angle = _Foil.trim(rest.z, s, air, f.trim_angle_of_attack, f.max_trim, f.angle)
		var c: Vector3 = _turn(rest.z, s, f.angle)
		var p: Vector3 = pivot + c * float(f.effort_offset)
		var half: float = 0.5 * (float(f.span_length()) * absf(s.y) + float(f.chord_length()) * absf(c.y))
		var wet: float = _wet_fraction(p, half, has_water, level)
		var frac := wet if in_water else 1.0 - wet
		var medium_density := rho if in_water else air_density_here
		f.immersion = frac
		if frac <= 0.0 or medium_density <= 0.0:
			continue
		var medium := flow if in_water else wind
		var r: Vector3 = p - com
		var u := v + w.cross(r) - medium          # the foil's velocity through its medium
		var up := u - s * s.dot(u)                 # the part across the span
		var q := up.length()
		if q < 1e-9:
			continue
		var n := s.cross(c)
		var un := up.dot(n)
		var uc := up.dot(c)
		var aoa := rad_to_deg(atan2(-un, -uc))
		f.angle_of_attack = aoa - 180.0 if aoa > 90.0 else (aoa + 180.0 if aoa < -90.0 else aoa)
		var a: float = f.area * frac
		# Square to the faces: ½ ρ A (k |uc| + 1.2 |un|) un, no more than ½ ρ A 1.4 q² (stall).
		var coeff: float = _Foil.lift_slope(f.aspect_ratio) * absf(uc) + _Foil.SQUARE_ON * absf(un)
		if absf(un) > 1e-12:
			coeff = minf(coeff, _Foil.MAX_NORMAL * q * q / absf(un))
		var jn := _impulse(n, 0.5 * medium_density * a * coeff, un, 0.0, -INF, INF, r, m, axes, dt)
		v += jn / m
		w += _inverse_inertia(r.cross(jn), axes)
		angular += r.cross(jn)
		# Friction along the chord, with the flow left after the push across it.
		var u2 := v + w.cross(r) - medium
		var jc := _impulse(c, 0.5 * medium_density * a * _Foil.FRICTION * q, u2.dot(c), 0.0, -INF, INF, r, m, axes, dt)
		v += jc / m
		w += _inverse_inertia(r.cross(jc), axes)
		angular += r.cross(jc)
		f.force = (jn + jc) / dt
	for t in _thrusters:
		t.force = Vector3.ZERO
		t.immersion = 0.0
		if not t.is_inside_tree():
			continue
		var at: Vector3 = t.global_position
		var wet: float = _wet_fraction(at, 0.5 * maxf(t.diameter, 1e-3), has_water, level)
		var in_water: bool = t.medium == 0
		var frac := wet if in_water else 1.0 - wet
		t.immersion = frac
		var throttle: float = clampf(t.throttle, -1.0, 1.0)
		var full: float = t.max_thrust * frac
		if full <= 0.0 or throttle == 0.0 or t.max_speed <= 0.0:
			continue
		var d: Vector3 = -t.global_transform.basis.z.normalized()
		var r: Vector3 = at - com
		var ua := (v + w.cross(r) - (flow if in_water else wind)).dot(d)
		# Thrust full x (throttle - ua / max_speed): a pull towards throttle x max_speed, kept between
		# nothing and full x throttle.
		var j := _impulse(d, full / t.max_speed, ua, throttle * t.max_speed,
			minf(0.0, throttle) * full * dt, maxf(0.0, throttle) * full * dt, r, m, axes, dt)
		v += j / m
		w += _inverse_inertia(r.cross(j), axes)
		angular += r.cross(j)
		t.force = j / dt
	return [v, angular]


## Fraction of a part `half` metres tall either side of `p` that is under the water.
func _wet_fraction(p: Vector3, half: float, has_water: bool, level: float) -> float:
	if not has_water:
		return 0.0
	var depth: float = (water.height_at(p) if water else level) - p.y
	if half < 1e-6:
		return 1.0 if depth > 0.0 else 0.0
	return clampf(0.5 + 0.5 * depth / half, 0.0, 1.0)


## The impulse along unit `d` at `r` (from the centre of mass) that a pull of `coeff` newtons per
## m/s towards the speed `target` gives over dt, the speed along d there being `speed` now: worked
## out with the speed at the end of the step, against the body's inertia at that point, so it never
## carries the point past the target. Kept between lo and hi.
func _impulse(d: Vector3, coeff: float, speed: float, target: float, lo: float, hi: float, r: Vector3, m: float, axes: Basis, dt: float) -> Vector3:
	if coeff <= 0.0:
		return Vector3.ZERO
	var rd := r.cross(d)
	var inv := 1.0 / m + rd.dot(_inverse_inertia(rd, axes))
	var k := coeff * dt
	return d * clampf(k * (target - speed) / (1.0 + k * inv), lo, hi)


## The body's own inverse inertia tensor, about the centre of mass, applied to `a` (world frame).
func _inverse_inertia(a: Vector3, axes: Basis) -> Vector3:
	var l := axes.transposed() * a
	return axes * Vector3(l.x / inertia.x if inertia.x > 0.0 else 0.0, l.y / inertia.y if inertia.y > 0.0 else 0.0,
		l.z / inertia.z if inertia.z > 0.0 else 0.0)


## `v` turned by `degrees` about the unit `axis` (right-handed).
static func _turn(v: Vector3, axis: Vector3, degrees: float) -> Vector3:
	var a := deg_to_rad(degrees)
	return v * cos(a) + axis.cross(v) * sin(a) + axis * (axis.dot(v) * (1.0 - cos(a)))


## Emit water_entered or water_exited, and ask the water for a splash.
func _report_crossing(entering: bool, cw: Vector3, flow: Vector3) -> void:
	var speed := (linear_velocity - flow).length()
	var surface: float = water.height_at(cw) if water else (water_surface.global_position.y if water_surface else water_level)
	var at := Vector3(cw.x, surface, cw.z)
	if entering:
		water_entered.emit(speed, at)
	else:
		water_exited.emit(speed, at)
	if water and water.has_method(&"splash"):
		var across := 2.0 * sqrt(maxf(_face_area.y, 1e-6) / PI)
		water.splash(at, speed if entering else 0.4 * speed, across)


## Drag coefficient in the air at `speed` (m/s through the air): drag_coefficient, the same as in the
## water. BoundedBuoyancyCannonball gives the drag of a fast ball instead.
func _air_drag_coefficient(_speed: float) -> float:
	return drag_coefficient


## Area the body shows to a flow along `along` (world frame): the faces of its bounding box, each
## seen at its angle to the flow, times how much of the box the shape fills.
func _drag_area(along: Vector3, basis: Basis) -> float:
	var n := along.length()
	if _single_sphere or n < 1e-9:
		return _area
	var d := (basis.transposed() * along).abs() / n
	return d.dot(_face_area)


## The water the body is in: water_surface if it is a BoundedBuoyancyWater, otherwise the first
## BoundedBuoyancyWater in the body's world that contains `at`.
func _find_water(at: Vector3) -> Node3D:
	_world_has_water = false
	if water_surface:
		return water_surface if water_surface is _Water else null
	for w in _Water.instances:
		if w.world != _world:
			continue
		_world_has_water = true
		if w.contains(at):
			return w
	return null


## Submerged volume and its centre for the body at `xf`, with the water surface at height `surface`
## over the body's centre. With a wavy `wavy_water`, each vertex is measured against the surface above it.
func _immerse(xf: Transform3D, surface: float, wavy_water: Node3D = null) -> void:
	# swell bounds how far the surface anywhere under the body can be from its height over the
	# centre: twice the most it rises or falls from its mean.
	var swell := 0.0
	var outside := Callable()   # another water system's surface, if the water uses one
	if wavy_water and wavy_water.is_wavy():
		swell = 2.0 * wavy_water.max_wave()
		outside = wavy_water.outside_height()
	else:
		wavy_water = null
	if _single_sphere:
		# Exact spherical cap, which is the same whichever way the sphere has turned. The sphere's
		# centre is the body's centroid, so `surface` is already the height over it.
		var c := xf * _sphere_centre
		var h := clampf(_radius + surface - c.y, 0.0, 2.0 * _radius)
		submerged_volume = PI * h * h * (3.0 * _radius - h) / 3.0
		var drop := 0.0 if h <= 0.0 else 3.0 * pow(2.0 * _radius - h, 2) / (4.0 * (3.0 * _radius - h))
		centre_of_buoyancy = c - Vector3.UP * drop
		return
	var cw := xf * _centroid
	if cw.y - _bound_radius >= surface + swell:
		submerged_volume = 0.0
		centre_of_buoyancy = cw
		return
	if cw.y + _bound_radius <= surface - swell:
		submerged_volume = volume
		centre_of_buoyancy = cw
		return
	# Work in the body's own coordinates: only the depth of each vertex needs the transform.
	# Each triangle is cut at the surface, and the part below makes tetrahedra with a point p on
	# the surface. The cut face lies in the surface plane, so it adds nothing: the sum is the exact
	# volume below the surface, and its first moment gives the centre of buoyancy.
	var up := Vector3(xf.basis.x.y, xf.basis.y.y, xf.basis.z.y)   # world height per unit of each body axis
	var h := surface - xf.origin.y
	var p := _centroid + up * ((h - up.dot(_centroid)) / up.length_squared())
	if _kernel and use_native and not outside.is_valid():
		var r: Vector4 = _kernel.clip_waves(_verts, _idx, _tri_weight, xf, wavy_water.inverse_transform(), wavy_water.wave_params(), p) \
			if wavy_water else _kernel.clip_flat(_verts, _idx, _tri_weight, up, h, p)
		submerged_volume = clampf(r.x, 0.0, volume)
		centre_of_buoyancy = xf * (Vector3(r.y, r.z, r.w) / (4.0 * r.x)) if r.x > 1e-12 else cw
		return
	if outside.is_valid():
		# Another water system's surface: ask it for the height over each vertex.
		for j in _verts.size():
			var wp := xf * _verts[j]
			_depth[j] = float(outside.call(wp)) - wp.y
	elif wavy_water:
		# Waves: measure each vertex against the surface above it. The cut face then follows the
		# waves, which is accurate while the waves are long compared with the body.
		for j in _verts.size():
			var wp := xf * _verts[j]
			_depth[j] = wavy_water.height_at(wp) - wp.y
	else:
		for j in _verts.size():
			_depth[j] = h - up.dot(_verts[j])
	var r := _clip(p)
	var vol: float = r[0]
	var moment: Vector3 = r[1]
	submerged_volume = clampf(vol, 0.0, volume)
	centre_of_buoyancy = xf * (moment / (4.0 * vol)) if vol > 1e-12 else cw


## Volume (times one) and first moment (times four) of the part of the body whose vertices have
## positive _depth, made of tetrahedra with the point `p` on the cut: [volume, moment].
func _clip(p: Vector3) -> Array:
	var vol := 0.0
	var moment := Vector3.ZERO
	var nt := _idx.size()
	var i := 0
	while i < nt:
		var ia := _idx[i]
		var ib := _idx[i + 1]
		var ic := _idx[i + 2]
		var w := _tri_weight[i / 3]
		i += 3
		var da := _depth[ia]
		var db := _depth[ib]
		var dc := _depth[ic]
		var under := int(da > 0.0) + int(db > 0.0) + int(dc > 0.0)
		if under == 0:
			continue
		var a := _verts[ia]
		var b := _verts[ib]
		var c := _verts[ic]
		if under == 3:
			var t3 := w * (a - p).dot((b - p).cross(c - p)) / 6.0
			vol += t3
			moment += t3 * (p + a + b + c)
			continue
		# Turn the triangle (keeping its winding) so that the odd vertex out comes first.
		if (under == 1 and db > 0.0) or (under == 2 and db <= 0.0):
			var tv := a; a = b; b = c; c = tv
			var td := da; da = db; db = dc; dc = td
		elif (under == 1 and dc > 0.0) or (under == 2 and dc <= 0.0):
			var tv := c; c = b; b = a; a = tv
			var td := dc; dc = db; db = da; da = td
		var ab := a + (b - a) * (da / (da - db))
		var ca := c + (a - c) * (dc / (dc - da))
		if under == 1:
			var t1 := w * (a - p).dot((ab - p).cross(ca - p)) / 6.0
			vol += t1
			moment += t1 * (p + a + ab + ca)
		else:
			var t2a := w * (ab - p).dot((b - p).cross(c - p)) / 6.0
			var t2b := w * (ab - p).dot((c - p).cross(ca - p)) / 6.0
			vol += t2a + t2b
			moment += t2a * (p + ab + b + c) + t2b * (p + ab + c + ca)
	return [vol, moment]


## Volume of the body below the level plane at height `y` (world), and its centre (world), with the
## body at `xf`: [volume, centre].
func _below_plane(xf: Transform3D, y: float) -> Array:
	var cw := xf * _centroid
	if _single_sphere:
		var c := xf * _sphere_centre
		var hs := clampf(_radius + y - c.y, 0.0, 2.0 * _radius)
		var vs := PI * hs * hs * (3.0 * _radius - hs) / 3.0
		var drop := 0.0 if hs <= 0.0 else 3.0 * pow(2.0 * _radius - hs, 2) / (4.0 * (3.0 * _radius - hs))
		return [vs, c - Vector3.UP * drop]
	if cw.y - _bound_radius >= y:
		return [0.0, cw]
	if cw.y + _bound_radius <= y:
		return [volume, cw]
	var up := Vector3(xf.basis.x.y, xf.basis.y.y, xf.basis.z.y)
	var h := y - xf.origin.y
	var p := _centroid + up * ((h - up.dot(_centroid)) / up.length_squared())
	if _kernel and use_native:
		var k: Vector4 = _kernel.clip_flat(_verts, _idx, _tri_weight, up, h, p)
		return [clampf(k.x, 0.0, volume), xf * (Vector3(k.y, k.z, k.w) / (4.0 * k.x)) if k.x > 1e-12 else cw]
	for j in _verts.size():
		_depth[j] = h - up.dot(_verts[j])
	var r := _clip(p)
	var v: float = r[0]
	return [clampf(v, 0.0, volume), xf * (r[1] / (4.0 * v)) if v > 1e-12 else cw]


## In water whose density changes from place to place: the mean density of the water the body
## displaces (into `rho`), how much harder to move through it is (medium_drag), and the centre of
## its weight (centre_of_buoyancy). Without layers, the density at the centre of buoyancy, which is
## exact while the density changes evenly over the body's height; with layers, the body is cut at
## each boundary and each part weighed at its own centre.
func _weigh_displaced(xf: Transform3D, w: Node3D) -> float:
	_interfaces.clear()
	if w.layers.is_empty():
		medium_drag = w.drag
		return w.density_at(centre_of_buoyancy)
	var s: Array = w.strata()
	var cuts: Array = []
	for i in range(1, s.size()):
		var cut := _below_plane(xf, s[i][0])
		cuts.append(cut)
		# Across this boundary: the jump in density there, the part below it and how deep its centre is.
		if cut[0] > 1e-12 and cut[0] < submerged_volume - 1e-12:
			var plane: float = s[i][0]
			var jump: float = s[i][1] - w.density_at(Vector3(xf.origin.x, plane + 1e-4, xf.origin.z))
			if jump > 0.0:
				_interfaces.append([jump, cut[0], plane - cut[1].y])
	var mass := 0.0
	var drag_sum := 0.0
	var weighed := Vector3.ZERO
	var above_v := submerged_volume
	var above_m := submerged_volume * centre_of_buoyancy
	for i in s.size():
		var below_v: float = cuts[i][0] if i < cuts.size() else 0.0
		var below_m: Vector3 = cuts[i][0] * cuts[i][1] if i < cuts.size() else Vector3.ZERO
		below_v = minf(below_v, above_v)
		var v := above_v - below_v
		if v > 1e-12:
			var c := (above_m - below_m) / v
			var rho_here: float = w.density_at(c)
			mass += rho_here * v
			drag_sum += float(s[i][3]) * v
			weighed += rho_here * v * c
		above_v = below_v
		above_m = below_m
	if mass <= 0.0:
		medium_drag = w.drag
		return w.density
	medium_drag = drag_sum / submerged_volume
	centre_of_buoyancy = weighed / mass
	return mass / submerged_volume


func _build_shape() -> void:
	_verts = PackedVector3Array()
	_idx = PackedInt32Array()
	_tri_weight = PackedFloat32Array()
	_single_sphere = false
	volume = 0.0
	var shapes := []
	for child in get_children():
		if child is CollisionShape3D and child.shape != null and not child.disabled:
			shapes.append([child.shape, child.transform])
	if buoyancy_mesh == null and shapes.size() == 1 and shapes[0][0] is SphereShape3D:
		var xf: Transform3D = shapes[0][1]
		_single_sphere = true
		_radius = shapes[0][0].radius * xf.basis.get_scale().x
		_sphere_centre = xf.origin
		volume = 4.0 / 3.0 * PI * pow(_radius, 3)
		_centroid = _sphere_centre
		_bound_radius = _radius
		_area = PI * _radius * _radius
		_face_area = Vector3.ONE * _area
		_box_size = Vector3.ONE * 2.0 * _radius
		return
	if buoyancy_mesh != null:
		_add_faces(buoyancy_mesh.get_faces(), Transform3D.IDENTITY, -1.0)
	else:
		for s in shapes:
			var faces := PackedVector3Array()
			var exact := -1.0
			var shape: Shape3D = s[0]
			if shape is BoxShape3D:
				var m := BoxMesh.new()
				m.size = shape.size
				faces = m.get_faces()
				exact = shape.size.x * shape.size.y * shape.size.z
			elif shape is CylinderShape3D:
				var m := CylinderMesh.new()
				m.top_radius = shape.radius
				m.bottom_radius = shape.radius
				m.height = shape.height
				m.radial_segments = curve_segments
				m.rings = 0
				faces = m.get_faces()
				exact = PI * shape.radius * shape.radius * shape.height
			elif shape is CapsuleShape3D:
				var m := CapsuleMesh.new()
				m.radius = shape.radius
				m.height = shape.height
				m.radial_segments = curve_segments
				m.rings = 1
				faces = m.get_faces()
				exact = PI * shape.radius * shape.radius * (shape.height - 2.0 * shape.radius) + 4.0 / 3.0 * PI * pow(shape.radius, 3)
			elif shape is SphereShape3D:
				var m := SphereMesh.new()
				m.radius = shape.radius
				m.height = 2.0 * shape.radius
				m.radial_segments = curve_segments
				m.rings = maxi(4, curve_segments / 4)
				faces = m.get_faces()
				exact = 4.0 / 3.0 * PI * pow(shape.radius, 3)
			elif shape is ConvexPolygonShape3D:
				# A fresh copy, so that the shape's own debug settings cannot turn its faces into outlines.
				var hull := ConvexPolygonShape3D.new()
				hull.points = shape.points
				faces = hull.get_debug_mesh().get_faces()
			else:
				push_warning("BoundedBuoyancyBody '%s': %s is not supported; set buoyancy_mesh instead." % [name, shape.get_class()])
				continue
			_add_faces(faces, s[1], exact)
	if _idx.is_empty() or volume <= 0.0:
		volume = 0.0
		return
	_depth.resize(_verts.size())
	var moment := Vector3.ZERO
	for i in range(0, _idx.size(), 3):
		var a := _verts[_idx[i]]
		var b := _verts[_idx[i + 1]]
		var c := _verts[_idx[i + 2]]
		var t := _tri_weight[i / 3] * a.dot(b.cross(c)) / 6.0
		moment += t * (a + b + c) * 0.25
	_centroid = moment / volume
	var lo := _verts[0]
	var hi := _verts[0]
	_bound_radius = 0.0
	for v in _verts:
		lo = lo.min(v)
		hi = hi.max(v)
		_bound_radius = maxf(_bound_radius, v.distance_to(_centroid))
	var size := hi - lo
	_box_size = size
	var fill := clampf(volume / (size.x * size.y * size.z), 0.3, 1.0)
	_face_area = Vector3(size.y * size.z, size.x * size.z, size.x * size.y) * fill
	_area = _face_area.y


## Adds a closed set of triangles (shape coordinates) placed by `xf`. With `exact` > 0 the faceted
## volume is scaled to that value; the sign corrects for the winding of the triangles.
func _add_faces(faces: PackedVector3Array, xf: Transform3D, exact: float) -> void:
	var faceted := 0.0
	for i in range(0, faces.size() - 2, 3):
		faceted += faces[i].dot(faces[i + 1].cross(faces[i + 2])) / 6.0
	if absf(faceted) < 1e-12:
		push_warning("BoundedBuoyancyBody '%s': a buoyancy shape has no volume; is the mesh closed?" % name)
		return
	var det := xf.basis.determinant()
	var w := signf(faceted * det) * (exact / absf(faceted) if exact > 0.0 else 1.0)
	var index := {}
	for v in faces:
		var key: Vector3 = xf * v
		if not index.has(key):
			index[key] = _verts.size()
			_verts.append(key)
	for i in range(0, faces.size() - 2, 3):
		_idx.append(index[xf * faces[i]])
		_idx.append(index[xf * faces[i + 1]])
		_idx.append(index[xf * faces[i + 2]])
		_tri_weight.append(w)
	volume += absf(faceted) * absf(det) * absf(w)


## Principal moments of inertia of the body's own mass about `com` (body axes).
func _own_inertia(com: Vector3) -> Vector3:
	if _single_sphere:
		var d := _sphere_centre - com
		var i0 := 0.4 * own_mass * _radius * _radius
		return Vector3(i0 + own_mass * (d.y * d.y + d.z * d.z), i0 + own_mass * (d.x * d.x + d.z * d.z), i0 + own_mass * (d.x * d.x + d.y * d.y))
	var sxx := 0.0
	var syy := 0.0
	var szz := 0.0
	for i in range(0, _idx.size(), 3):
		var a := _verts[_idx[i]] - com
		var b := _verts[_idx[i + 1]] - com
		var c := _verts[_idx[i + 2]] - com
		var v := _tri_weight[i / 3] * a.dot(b.cross(c)) / 6.0
		sxx += v / 10.0 * (a.x * a.x + b.x * b.x + c.x * c.x + a.x * b.x + a.x * c.x + b.x * c.x)
		syy += v / 10.0 * (a.y * a.y + b.y * b.y + c.y * c.y + a.y * b.y + a.y * c.y + b.y * c.y)
		szz += v / 10.0 * (a.z * a.z + b.z * b.z + c.z * c.z + a.z * b.z + a.z * c.z + b.z * c.z)
	return density * Vector3(syy + szz, sxx + szz, sxx + syy)
