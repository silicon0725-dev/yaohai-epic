@tool
@icon("res://addons/bounded_buoyancy/icon_cannon.svg")
class_name BoundedBuoyancyCannon
extends Node3D
## A muzzle-loading cannon that fires round shot.
##
## Place it at the gun's muzzle, pointing the way it fires (its -Z, the way Godot nodes face); tilt it
## up for elevation. fire() sends out a BoundedBuoyancyCannonball, which flies with a fast ball's drag,
## skips off the water when it comes down at a shallow angle, and strikes what it hits.
##
## On a ship (any RigidBody3D above it in the tree), the shot leaves with the ship's own velocity at
## the muzzle added, and the ship takes the recoil at the muzzle: the shot's momentum and the powder
## gas's, which moves on average at half the shot's speed as it leaves (Lagrange's assumption of
## interior ballistics). So a broadside heels a ship as well as pushing it.
##
## Choose a gun and the shot is set from the British round shot of Muller's Treatise of Artillery
## (1768): 6 to 32 pounds, 3.5 to 6.1 inches across, cast iron. The muzzle speed is a long gun's with
## its full charge, a third of the shot's weight: 488 m/s (1600 ft/s).

## A shot has just left the muzzle.
signal fired(ball: RigidBody3D)

enum Gun {
	POUNDER_6,  ## 6 lb shot, 3.50 in.
	POUNDER_9,  ## 9 lb shot, 4.00 in.
	POUNDER_12, ## 12 lb shot, 4.40 in.
	POUNDER_18, ## 18 lb shot, 5.04 in.
	POUNDER_24, ## 24 lb shot, 5.55 in.
	POUNDER_32, ## 32 lb shot, 6.10 in.
	CUSTOM,     ## Set the shot's diameter and mass yourself.
}

const POUND := 0.45359237   # kg
const INCH := 0.0254        # m
# Round shot by gun: weight (lb) and diameter (in), Muller (1768).
const SHOT := {
	Gun.POUNDER_6: [6.0, 3.50], Gun.POUNDER_9: [9.0, 4.00], Gun.POUNDER_12: [12.0, 4.40],
	Gun.POUNDER_18: [18.0, 5.04], Gun.POUNDER_24: [24.0, 5.55], Gun.POUNDER_32: [32.0, 6.10],
}
const _Ball := preload("res://addons/bounded_buoyancy/bounded_buoyancy_cannonball.gd")

## Size of gun: sets the shot's diameter and mass, and a full charge.
@export var gun: Gun = Gun.POUNDER_24:
	set(value):
		gun = value
		if SHOT.has(value):
			var s: Array = SHOT[value]
			shot_mass = s[0] * POUND
			shot_diameter = s[1] * INCH
			charge_mass = shot_mass / 3.0
			notify_property_list_changed()
## Diameter of the shot, in metres.
@export_range(0.005, 1.0, 0.0001, "or_greater", "suffix:m") var shot_diameter: float = 5.55 * INCH
## Mass of the shot, in kg.
@export_range(0.001, 1000.0, 0.001, "or_greater", "suffix:kg") var shot_mass: float = 24.0 * POUND
## Speed of the shot as it leaves the muzzle, in m/s.
@export_range(1.0, 2000.0, 0.1, "or_greater", "suffix:m/s") var muzzle_speed: float = 488.0
## Mass of the powder charge, in kg. Its gas adds to the recoil.
@export_range(0.0, 500.0, 0.001, "or_greater", "suffix:kg") var charge_mass: float = 8.0 * POUND
## Seconds between shots.
@export_range(0.0, 600.0, 0.01, "or_greater", "suffix:s") var reload_time: float = 3.0
## Scatter: shots leave up to this many degrees off the line the gun points along.
@export_range(0.0, 10.0, 0.01, "suffix:°") var spread: float = 0.3
## Push the ship back as the gun fires.
@export var recoil: bool = true
## Seconds each shot lasts before it removes itself. 0 keeps them.
@export_range(0.0, 3600.0, 0.1, "or_greater", "suffix:s") var shot_lifetime: float = 30.0
## Where the shots go in the scene. Empty: beside the ship, or in the current scene.
@export var shot_parent: Node
## Colour of the shot.
@export var shot_color: Color = Color(0.13, 0.13, 0.14)

## Seconds until the gun can fire again.
var reload_left: float = 0.0
## The last shot fired.
var last_shot: RigidBody3D = null

var _rng := RandomNumberGenerator.new()
var _mesh: SphereMesh
var _material: StandardMaterial3D


func _physics_process(dt: float) -> void:
	if Engine.is_editor_hint():
		return
	if reload_left > 0.0:
		reload_left = maxf(reload_left - dt, 0.0)


## Whether the gun is loaded and can fire.
func is_loaded() -> bool:
	return reload_left <= 0.0


## Seed the scatter, for shots that fall the same way every run.
func seed_spread(value: int) -> void:
	_rng.seed = value


## Momentum the recoil gives the ship, in kg m/s: the shot's, and the powder gas's at half its speed.
func recoil_momentum() -> float:
	return (shot_mass + 0.5 * charge_mass) * muzzle_speed


## Fire, if loaded. Returns the shot, or null.
func fire() -> RigidBody3D:
	if reload_left > 0.0 or not is_inside_tree() or Engine.is_editor_hint():
		return null
	reload_left = reload_time
	var xf := global_transform
	var basis := xf.basis.orthonormalized()
	var forward := -basis.z
	if spread > 0.0:
		var off := deg_to_rad(spread) * sqrt(_rng.randf())
		var turn := TAU * _rng.randf()
		forward = (forward * cos(off) + (basis.x * cos(turn) + basis.y * sin(turn)) * sin(off)).normalized()
	var muzzle := xf.origin
	var ship := _ship()
	var carried := Vector3.ZERO
	if ship:
		var state := PhysicsServer3D.body_get_direct_state(ship.get_rid())
		carried = state.get_velocity_at_local_position(muzzle - ship.global_position) if state else ship.linear_velocity
	var ball := _make_ball()
	var parent := shot_parent
	if parent == null:
		parent = ship.get_parent() if ship else get_tree().current_scene
	if parent == null:
		parent = get_tree().root
	parent.add_child(ball)
	ball.global_position = muzzle
	ball.linear_velocity = carried + forward * muzzle_speed
	if ship:
		# Clear of the ship's own hull before it can strike it.
		ball.pass_through(ship, 0.25)
		if recoil:
			ship.apply_impulse(-forward * recoil_momentum(), muzzle - ship.global_position)
	last_shot = ball
	fired.emit(ball)
	return ball


## The ship the gun is on: the nearest RigidBody3D above it.
func _ship() -> RigidBody3D:
	var p := get_parent()
	while p:
		if p is RigidBody3D:
			return p
		p = p.get_parent()
	return null


func _make_ball() -> RigidBody3D:
	var r := 0.5 * shot_diameter
	var ball := _Ball.new()
	ball.name = "Shot"
	var cs := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = r
	cs.shape = sphere
	ball.add_child(cs)
	if _mesh == null or not is_equal_approx(_mesh.radius, r):
		_mesh = SphereMesh.new()
		_mesh.radius = r
		_mesh.height = 2.0 * r
		_mesh.radial_segments = 16
		_mesh.rings = 8
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.metallic = 0.6
		_material.roughness = 0.55
	_material.albedo_color = shot_color
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh
	mi.material_override = _material
	ball.add_child(mi)
	ball.density = shot_mass / (PI / 6.0 * shot_diameter * shot_diameter * shot_diameter)
	ball.lifetime = shot_lifetime
	return ball
