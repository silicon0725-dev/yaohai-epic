@tool
@icon("res://addons/bounded_buoyancy/icon_wind.svg")
class_name BoundedBuoyancyWind2D
extends Node2D
## Wind for BoundedBuoyancyBody2D, with gusts. It pushes on the part of each body out of the water
## and on any sail. Speeds are in pixels per second.

## Velocity of the wind, in pixels per second.
@export var velocity: Vector2 = Vector2(400.0, 0.0)
## How much gusts change the speed: 0.3 makes it vary by up to 30% either side.
@export_range(0.0, 1.0, 0.01) var gust_strength: float = 0.3
## Typical time from one gust to the next, in seconds.
@export_range(0.1, 60.0, 0.1, "or_greater", "suffix:s") var gust_period: float = 5.0:
	set(value):
		gust_period = maxf(value, 0.01)
## Blow everywhere. Turn off to limit the wind to a rectangle of `size` centred on this node.
@export var everywhere: bool = true
## Size of the rectangle the wind fills when everywhere is off, in pixels.
@export var size: Vector2 = Vector2(1000.0, 1000.0)

var time: float = 0.0
static var instances: Array[Node2D] = []
var world: World2D


func _enter_tree() -> void:
	world = get_world_2d()
	process_physics_priority = -1000
	if not instances.has(self):
		instances.append(self)


func _exit_tree() -> void:
	instances.erase(self)


func _physics_process(dt: float) -> void:
	if not Engine.is_editor_hint():
		time += dt


## Velocity of the wind at the global point `p`, gusts included.
func velocity_at(p: Vector2) -> Vector2:
	if not everywhere:
		var l := p - global_position
		if absf(l.x) > 0.5 * size.x or absf(l.y) > 0.5 * size.y:
			return Vector2.ZERO
	var speed := velocity.length()
	if speed < 1e-6 or gust_strength <= 0.0:
		return velocity
	var s := (time - p.dot(velocity) / (speed * speed)) / gust_period
	var g := 0.6 * sin(TAU * s) + 0.3 * sin(TAU * 2.3 * s + 1.7) + 0.1 * sin(TAU * 5.1 * s + 0.4)
	return velocity * (1.0 + gust_strength * g)


static func total_at(p: Vector2, in_world: World2D) -> Vector2:
	var w := Vector2.ZERO
	for node in instances:
		if node.world == in_world:
			w += node.velocity_at(p)
	return w
