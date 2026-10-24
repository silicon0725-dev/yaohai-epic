@icon("res://addons/bounded_buoyancy/icon_foil.svg")
class_name BoundedBuoyancyFoil
extends Node3D
## A thin flat foil on a BoundedBuoyancyBody: a keel, centreboard, rudder, fin, sail or wing.
##
## Add it anywhere under the body. Its span runs along its own Y axis (up a keel or a mast) and its
## chord along its Z axis, leading edge forward (-Z, the way Godot nodes face), trailing edge aft
## (+Z); its faces look along X. The flow past it makes a force square to its faces, lift and
## pressure drag together as for a flat plate, and a little friction along it, at its centre of
## effort, so a keel stops a boat sliding sideways, a rudder turns it, and a sail drives it across
## the wind and up into it.
##
## The force square to the faces is ½ ρ A q² C_N(α), with α the angle between the flow and the foil
## and C_N(α) = k sin α cos α + 1.2 sin² α, no more than 1.4 (a stalled plate). k is the lift slope
## of a wing of the foil's aspect ratio (Helmbold: 2π AR / (2 + √(AR² + 4))); 1.2 is a flat plate
## square to the flow, the drag the body's own sail_area has always had.
##
## Like the buoyancy, the force is bounded: each step it is worked out with the flow at the end of
## the step, against the inertia the body has at the foil, so it can stop the flow across the foil
## but never throw the body back the other way, however large the foil or light the body.
##
## In the water a foil acts on its part under the surface; in the air, on its part above it, with
## the wind. Turn a rudder by setting angle (degrees about its span: positive swings the trailing
## edge to starboard, +X, which turns a boat with the rudder at its stern to starboard). A sail with
## auto_trim swings itself away from the wind it feels, keeping trim_angle_of_attack to it, no
## further than max_trim; put its node at the mast and set effort_offset to where its push acts.
## Its children (a mesh, say) turn with it.

enum Medium {
	WATER, ## A keel, centreboard, rudder or fin: acts on its part under the water.
	AIR,   ## A sail, wing or tail fin: acts on its part above the water, with the wind.
}

const SQUARE_ON := 1.2     # normal-force coefficient of a flat plate square to the flow
const MAX_NORMAL := 1.4    # a stalled plate makes no more, at any angle
const FRICTION := 0.02     # skin friction along the chord, both faces

## What the foil works in.
@export var medium: Medium = Medium.WATER
## Area of one face, in square metres.
@export_range(0.0, 1000.0, 0.001, "or_greater", "suffix:m²") var area: float = 0.1
## Span² / area: about 1 to 2 for a keel, 2 to 3 for a rudder, 3 to 5 for a sail. Longer, narrower
## foils give more lift for their area.
@export_range(0.05, 30.0, 0.05, "or_greater") var aspect_ratio: float = 2.0
## Angle the foil is turned about its span from where it was placed, in degrees: a rudder's angle.
## Positive swings the trailing edge towards +X. With auto_trim on, the foil sets it itself.
@export_range(-180.0, 180.0, 0.1, "suffix:°") var angle: float = 0.0:
	set(value):
		angle = value
		if _placed:
			_show_angle()
## Distance from the node (the pivot: a mast, a rudder stock) to where the force acts, along the
## chord towards the trailing edge, in metres. 0: the node is the centre of the foil. A sail pushes
## about a third of its chord aft of the mast.
@export_range(0.0, 50.0, 0.01, "or_greater", "suffix:m") var effort_offset: float = 0.0

@export_group("Sail")
## Trim like a sail: swing about the span, away from the wind, to meet the flow at
## trim_angle_of_attack, but no further than max_trim from where it was placed. Head to wind it
## lines up with the wind and makes no lift; running before the wind it swings out to max_trim.
@export var auto_trim: bool = false
## Angle of attack a trimmed sail keeps to the flow, in degrees.
@export_range(0.0, 60.0, 0.5, "suffix:°") var trim_angle_of_attack: float = 15.0
## How far a trimmed sail may swing either way, in degrees (the boom's limit).
@export_range(0.0, 180.0, 0.5, "suffix:°") var max_trim: float = 85.0

## Where the foil was placed (its rotation and scale with angle 0), kept with the node so that a copy
## made while running does not turn by its angle twice.
@export_storage var placed_basis := Basis.IDENTITY
@export_storage var placed_saved := false

## Mean force on the foil over the last physics step (world frame, newtons).
var force: Vector3 = Vector3.ZERO
## Fraction of the foil in its medium this step.
var immersion: float = 0.0
## Angle between the flow and the foil this step, in degrees.
var angle_of_attack: float = 0.0

var _placed := false
var _body: Node = null

## Running nearly dead downwind, a trimmed sail keeps to its side until the wind comes this many
## degrees round to the other side, so it does not flick from side to side.
const GYBE_MARGIN := 10.0


func _ready() -> void:
	if not placed_saved:
		placed_basis = transform.basis
		placed_saved = true
	_placed = true
	if angle != 0.0:
		_show_angle()


## Call after turning the foil's node by script while running, so that its present orientation
## (less its angle) becomes where it was placed.
func replace() -> void:
	placed_basis = transform.basis * Basis(Vector3.UP, deg_to_rad(-angle))
	placed_saved = true


## Turn the node about its span by angle, keeping its scale (so a scaled blade does not shear).
func _show_angle() -> void:
	transform.basis = placed_basis.orthonormalized() * Basis(Vector3.UP, deg_to_rad(angle)) * Basis.from_scale(placed_basis.get_scale())


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


## Length of the span (m).
func span_length() -> float:
	return sqrt(maxf(area, 0.0) * maxf(aspect_ratio, 1e-6))


## Length of the chord (m).
func chord_length() -> float:
	var s := span_length()
	return area / s if s > 0.0 else 0.0


## Lift slope of a wing of aspect ratio `ar`, per radian (Helmbold).
static func lift_slope(ar: float) -> float:
	ar = maxf(ar, 1e-6)
	return TAU * ar / (2.0 + sqrt(ar * ar + 4.0))


## Normal-force coefficient at angle of attack `alpha` (radians) for lift slope `k`.
static func normal_coefficient(alpha: float, k: float) -> float:
	var s := sin(alpha)
	var cn := minf(k * absf(s) * absf(cos(alpha)) + SQUARE_ON * s * s, MAX_NORMAL)
	return -cn if s < 0.0 else cn


## Where the foil was placed (angle 0), in world space: the span (Y) and the chord towards the
## trailing edge (Z).
func rest_basis() -> Basis:
	var parent := get_parent_node_3d()
	var b := placed_basis if _placed else transform.basis * Basis(Vector3.UP, deg_to_rad(-angle))
	return (parent.global_transform.basis * b).orthonormalized() if parent else b.orthonormalized()


## The angle (degrees about the span) a sail at rest along `rest_chord` swings to, for air moving
## past it at `air_past`: away from the wind, meeting the flow at `aoa`, no further than `most`.
## `current` is the angle it has now: within GYBE_MARGIN of dead downwind it keeps to that side.
static func trim(rest_chord: Vector3, span: Vector3, air_past: Vector3, aoa: float, most: float, current := 0.0) -> float:
	var a := air_past - span * span.dot(air_past)
	if a.length_squared() < 1e-18:
		return current
	var beta := rad_to_deg(atan2(rest_chord.cross(a).dot(span), rest_chord.dot(a)))
	var swing := minf(maxf(absf(beta) - aoa, 0.0), most)
	var port := beta < 0.0
	if current != 0.0 and (current < 0.0) != port and absf(beta) > 180.0 - GYBE_MARGIN:
		port = current < 0.0   # by the lee: keep the side it is on
	return -swing if port else swing
