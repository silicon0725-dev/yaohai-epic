@tool
@icon("res://addons/bounded_buoyancy/icon_thermal.svg")
class_name BoundedBuoyancyThermal
extends Node3D
## A warm (or cold) place in the air: a thermal over sunlit ground, the hot air over a fire or a
## chimney, a cold pool in a valley at night.
##
## Air there is warmer than the air around it by **Warming** at its middle, less toward its edge and
## none beyond it, so it is less dense (at the same pressure, as the gas law gives): a balloon rises
## faster in it. A thermal is also air on the way up: **Updraft** is how fast it rises at its middle,
## and bodies in it are carried up by it as by wind, so a glider or a soaring bird that circles in
## it climbs. A negative warming is cold air, and a negative updraft air sinking.
##
## It is a column standing up from the node (a thermal, a plume) or a ball round it, of the given
## radius and height. It acts on the air only.

enum Shape {
	COLUMN, ## Upright, from the node up to its height.
	BALL,   ## A ball of the given radius round the node.
}

## Its shape.
@export var shape: Shape = Shape.COLUMN
## Radius, m: a few hundred metres for a thermal over fields, a few metres over a bonfire.
@export_range(0.01, 10000.0, 0.01, "or_greater", "suffix:m") var radius: float = 50.0
## Height of a column, m: thermals often reach 1 to 2 km, to the base of the cloud they make.
@export_range(0.01, 50000.0, 0.01, "or_greater", "suffix:m") var height: float = 1000.0
## How much warmer than the air around it the air at its middle is, °C: 1 to 3 in a thermal, tens
## over a fire.
@export_range(-100.0, 1000.0, 0.1, "or_greater", "suffix:°C") var warming: float = 2.0
## How fast the air at its middle rises, m/s: 1 to 5 in a thermal. Negative: sinking air.
@export_range(-50.0, 50.0, 0.01, "suffix:m/s") var updraft: float = 2.0

## Every BoundedBuoyancyThermal in the scene tree.
static var instances: Array[Node3D] = []
## The world it is in.
var world: World3D


func _enter_tree() -> void:
	world = get_world_3d()
	if not instances.has(self):
		instances.append(self)


func _exit_tree() -> void:
	instances.erase(self)


## How strong it is at the world point `p`: 1 at its middle, falling smoothly to 0 at its edge.
func strength_at(p: Vector3) -> float:
	var l := global_transform.affine_inverse() * p
	var r2: float
	if shape == Shape.BALL:
		r2 = l.length_squared() / (radius * radius)
	else:
		if l.y < 0.0 or l.y > height:
			return 0.0
		r2 = (l.x * l.x + l.z * l.z) / (radius * radius)
		# It fades out over its top tenth.
		var top := clampf((height - l.y) / (0.1 * height), 0.0, 1.0)
		r2 = 1.0 - (1.0 - minf(r2, 1.0)) * top
	if r2 >= 1.0:
		return 0.0
	var f := 1.0 - r2
	return f * f


## How much warmer the air is at `p` for this thermal, °C.
func warming_at(p: Vector3) -> float:
	return warming * strength_at(p)


## The rising air at `p` (world velocity, m/s).
func updraft_at(p: Vector3) -> Vector3:
	return global_transform.basis.y.normalized() * (updraft * strength_at(p))
