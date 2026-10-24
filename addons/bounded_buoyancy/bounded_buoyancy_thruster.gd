@icon("res://addons/bounded_buoyancy/icon_thruster.svg")
class_name BoundedBuoyancyThruster
extends Node3D
## A propeller (in the water) or a fan (in the air) on a BoundedBuoyancyBody.
##
## Add it anywhere under the body, facing the way it should push the body (its -Z, the way Godot
## nodes face). At rest it pushes with max_thrust x throttle; the push falls in a straight line as
## its speed through its medium along that direction grows, to nothing at throttle x max_speed. So it
## gives a boat a top speed of its own, and a reversed throttle pushes it astern. Out of its medium
## (a propeller lifted clear of the water, a fan dipped in it) it pushes nothing.
##
## Like the buoyancy, the push is bounded: worked out with the speed at the end of the step, against
## the inertia the body has at the thruster, it brings the body up to its speed but never past it,
## however strong the thruster or light the body.

enum Medium {
	WATER, ## A propeller or a water jet: pushes while under the water.
	AIR,   ## A fan or an air propeller (an airboat, an airship): pushes while above the water.
}

## What the thruster works in.
@export var medium: Medium = Medium.WATER
## Push at full throttle from rest, in newtons.
@export_range(0.0, 1000000.0, 1.0, "or_greater", "suffix:N") var max_thrust: float = 200.0
## Speed through the medium at which full throttle pushes no more, in m/s.
@export_range(0.01, 200.0, 0.01, "or_greater", "suffix:m/s") var max_speed: float = 5.0
## -1 (full astern) to 1 (full ahead).
@export_range(-1.0, 1.0, 0.01) var throttle: float = 0.0
## Diameter, in metres: how deep a propeller must be to work fully.
@export_range(0.01, 20.0, 0.01, "or_greater", "suffix:m") var diameter: float = 0.3

## Mean push over the last physics step (world frame, newtons).
var force: Vector3 = Vector3.ZERO
## Fraction of the thruster in its medium this step.
var immersion: float = 0.0

var _body: Node = null


func _enter_tree() -> void:
	var p := get_parent()
	while p:
		if p.has_method(&"_add_appendage"):
			_body = p
			p._add_appendage(self)
			return
		p = p.get_parent()


func _exit_tree() -> void:
	if _body and is_instance_valid(_body):
		_body._remove_appendage(self)
	_body = null
