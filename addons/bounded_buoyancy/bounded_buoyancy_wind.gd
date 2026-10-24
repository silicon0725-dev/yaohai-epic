@tool
@icon("res://addons/bounded_buoyancy/icon_wind.svg")
class_name BoundedBuoyancyWind
extends Node3D
## Wind for BoundedBuoyancyBody, with gusts.
##
## The wind pushes on the part of each body that is out of the water, by drag on the body's speed
## through the air, and on any sail a body has. Balloons drift with it, a boat with a sail runs
## before it and heels, and a crate barely moves. Gusts make the speed and direction vary, and
## travel downwind, so nearby bodies feel each gust one after another.
##
## Turn the node to aim the wind: velocity is in the node's own frame. Set everywhere off to limit
## the wind to a box of the given size around the node, such as a gap between buildings or a fan.

## Velocity of the wind in metres per second, in this node's own frame.
@export var velocity: Vector3 = Vector3(5.0, 0.0, 0.0)
## How much gusts change the speed: 0.3 makes it vary by up to 30% either side of the mean.
@export_range(0.0, 1.0, 0.01) var gust_strength: float = 0.3
## Typical time from one gust to the next, in seconds.
@export_range(0.1, 60.0, 0.1, "or_greater", "suffix:s") var gust_period: float = 5.0:
	set(value):
		gust_period = maxf(value, 0.01)
## How far the gusts swing the direction, in degrees either side.
@export_range(0.0, 90.0, 0.1) var direction_swing: float = 10.0
## Blow everywhere in the scene. Turn off to limit the wind to the box below.
@export var everywhere: bool = true
## Size of the box the wind fills when everywhere is off, centred on this node.
@export var size: Vector3 = Vector3(10.0, 10.0, 10.0)

## Wind clock in seconds, advanced with the physics step.
var time: float = 0.0

## Every BoundedBuoyancyWind in the scene tree, for bodies to search quickly.
static var instances: Array[Node3D] = []
## The world this wind is in; bodies only feel wind in their own world.
var world: World3D


func _enter_tree() -> void:
	world = get_world_3d()
	process_physics_priority = -1000
	if not instances.has(self):
		instances.append(self)


func _exit_tree() -> void:
	instances.erase(self)


func _physics_process(dt: float) -> void:
	if not Engine.is_editor_hint():
		time += dt


## Velocity of the wind at the world point `p` (world frame), gusts included.
func velocity_at(p: Vector3) -> Vector3:
	var base := global_transform.basis * velocity
	if not everywhere:
		var l := global_transform.affine_inverse() * p
		if absf(l.x) > 0.5 * size.x or absf(l.y) > 0.5 * size.y or absf(l.z) > 0.5 * size.z:
			return Vector3.ZERO
	var speed := base.length()
	if speed < 1e-6 or (gust_strength <= 0.0 and direction_swing <= 0.0):
		return base
	# Gusts travel with the wind: the phase depends on the time and on the distance downwind.
	var s := (time - p.dot(base) / (speed * speed)) / gust_period
	var g := 0.6 * sin(TAU * s) + 0.3 * sin(TAU * 2.3 * s + 1.7) + 0.1 * sin(TAU * 5.1 * s + 0.4)
	var turn := deg_to_rad(direction_swing) * sin(TAU * 0.37 * s + 2.1)
	return base.rotated(Vector3.UP, turn) * (1.0 + gust_strength * g)


## Total wind at the world point `p` from every wind node in `in_world` that reaches it, and the
## rising air of any thermals (BoundedBuoyancyThermal).
static func total_at(p: Vector3, in_world: World3D) -> Vector3:
	var w := Vector3.ZERO
	for node in instances:
		if node.world == in_world:
			w += node.velocity_at(p)
	for t in BoundedBuoyancyThermal.instances:
		if t.world == in_world:
			w += t.updraft_at(p)
	return w
