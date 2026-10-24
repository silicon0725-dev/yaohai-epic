@icon("res://addons/bounded_buoyancy/icon_hull.svg")
class_name BoundedBuoyancyHull
extends Node
## The planking of a ship (or of anything shot can strike: a fort's timber, a target): how thick it is
## and what it is made of. Put it directly under the body (a BoundedBuoyancyBody, or any
## CollisionObject3D).
##
## Shot that strikes the body (BoundedBuoyancyCannonball) is resisted by the wood with a pressure
## σ + ρ v² on its cross-section, v its speed through it: the wood's strength σ and its density ρ
## (Poncelet's law of penetration). With oak (ρ 750 kg/m³, σ 15 MPa) a 32-pounder shot goes 42
## inches into solid oak from 400 yards and 31.5 inches from 1000 yards, as the gunners' handbook
## gives (Elvin, 1805). Shot that has the speed to go through the planking does, slower, punching a
## hole as big as itself; through a hole below the waterline the sea comes in (the hole goes in the
## nearest BoundedBuoyancyCompartment of the body), so a ship holed there floods, lists and sinks.
## The wood it punches out flies off as splinters, which float, and the body takes the momentum the
## shot loses, less what the splinters carry off. Shot without the speed lodges in the wood. A shot
## meeting the planking at a glancing angle (more than about 78° off square) glances off.
##
## The body's collision shapes are taken as its outside, and as solid: shot goes in through the
## planking where it strikes them and out through the planking where its path leaves them. Shapes that
## touch or overlap (a convex decomposition) count as one; a part beyond a gap along the shot's path (a
## mast clear of the hull) is not struck by the same shot.

## Shot has struck the planking at `at` (world): `through` if it went through, leaving at `speed_out`
## (m/s; 0 if it lodged).
signal struck(ball: RigidBody3D, at: Vector3, through: bool, speed_out: float)
## A hole of `area` m² has been made at `at` (world), in `compartment` (null if the body has none).
signal holed(at: Vector3, area: float, compartment: Node)

## Thickness of the planking, in metres. A frigate's side was about 0.4 m of oak at the waterline,
## a ship of the line's 0.6 m; a small boat's a few centimetres.
@export_range(0.001, 5.0, 0.001, "or_greater", "suffix:m") var thickness: float = 0.2
## Density of the wood, kg/m³: oak 750. It resists fast shot (ρ v²), and the splinters are made of it.
@export_range(1.0, 20000.0, 1.0, "or_greater", "suffix:kg/m³") var density: float = 750.0
## Strength of the wood against shot, in MPa: oak 15. It stops slow shot.
@export_range(0.0, 1000.0, 0.01, "or_greater", "suffix:MPa") var strength: float = 15.0
## Size of a shot hole, as a multiple of the shot's own cross-section.
@export_range(0.0, 10.0, 0.01, "or_greater") var hole_size: float = 1.0
## Splinters thrown off each time shot goes in or out, made of the wood it punches out. 0 for none.
@export_range(0, 32, 1) var splinters: int = 4
## Seconds the splinters last. 0 keeps them.
@export_range(0.0, 3600.0, 0.1, "or_greater", "suffix:s") var splinter_lifetime: float = 60.0
## Colour of the splinters.
@export var splinter_color: Color = Color(0.62, 0.45, 0.28)

## Shot below this speed meets the body as an ordinary collision (m/s).
const STRIKE_SPEED := 20.0
## Cosine of the most glancing angle at which shot bites into the planking.
const GLANCE := 0.2
const META := &"bounded_buoyancy_hull"
const _Body := preload("res://addons/bounded_buoyancy/bounded_buoyancy_body.gd")

var _mesh: BoxMesh
var _material: StandardMaterial3D


func _enter_tree() -> void:
	get_parent().set_meta(META, self)


func _exit_tree() -> void:
	var p := get_parent()
	if p and p.get_meta(META, null) == self:
		p.remove_meta(META)


## How deep shot of `mass` kg and cross-section `area` m² goes into thick wood of `density` and
## `strength` (Pa) when it strikes square at `speed`: (m / 2 ρ A) ln(1 + ρ v² / σ).
static func penetration_depth(mass: float, area: float, speed: float, density: float, strength: float) -> float:
	if area <= 0.0 or density <= 0.0:
		return INF
	if strength <= 0.0:
		return INF
	return mass / (2.0 * density * area) * log(1.0 + density * speed * speed / strength)


## The speed of that shot after going `path` metres through the wood: from m v dv = -A (σ + ρ v²) dx,
## v² + σ/ρ falls as exp(-2 ρ A x / m). 0 if it stops in it.
static func speed_after(mass: float, area: float, speed: float, path: float, density: float, strength: float) -> float:
	if density <= 0.0 or area <= 0.0:
		return speed
	var k := strength / density
	var u := (speed * speed + k) * exp(-2.0 * density * area * path / mass) - k
	return sqrt(u) if u > 0.0 else 0.0


## The speed of `ball` (mass, radius) after going through this planking, met at `cos_in` (the cosine
## of its angle off square) at `speed`. 0 if it lodges.
func speed_through(mass: float, radius: float, speed: float, cos_in: float) -> float:
	var path := thickness / maxf(cos_in, GLANCE)
	return speed_after(mass, PI * radius * radius, speed, path, density, strength * 1e6)


## Make a hole of `area` m² at `at` (world) in the body's nearest compartment, if it has any; emits
## holed. Returns the compartment.
func make_hole(at: Vector3, area: float) -> Node:
	var body := get_parent()
	var best: Node3D = null
	var best_d := INF
	if body is _Body:
		for c in body._compartments:
			if not is_instance_valid(c) or not c.is_inside_tree():
				continue
			var l: Vector3 = c.to_local(at)
			var h: Vector3 = 0.5 * c.size
			var d := (l - l.clamp(-h, h)).length()
			if d < best_d:
				best_d = d
				best = c
	if best:
		best.add_hole(at, area)
	holed.emit(at, area, best)
	return best


## Throw the wood punched out by shot of `radius` going through here, as splinters from `at` (world)
## along `dir`, at up to `speed`, carried along with the body's own `velocity` there. They float. They
## do not strike `ignore` (the shot) or each other, nor the body for the first moment. Returns the
## momentum they carry off, relative to the body (kg m/s).
func throw_splinters(at: Vector3, dir: Vector3, speed: float, radius: float, cos_in: float, velocity: Vector3, parent: Node, ignore: PhysicsBody3D = null) -> Vector3:
	if splinters <= 0 or parent == null:
		return Vector3.ZERO
	var wood := PI * radius * radius * thickness / maxf(cos_in, GLANCE)   # the wood punched out, m³
	var each := wood / splinters
	var s := pow(each / 8.0, 1.0 / 3.0)   # each a splinter 8 x 1 x 1
	if _mesh == null or not is_equal_approx(_mesh.size.y, s):
		_mesh = BoxMesh.new()
		_mesh.size = Vector3(s, s, 8.0 * s)
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.roughness = 0.9
	_material.albedo_color = splinter_color
	var body := get_parent()
	var side := dir.cross(Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT).normalized()
	var up := side.cross(dir).normalized()
	var thrown: Array[PhysicsBody3D] = []
	var momentum := Vector3.ZERO
	for i in splinters:
		var b := _Body.new()
		b.name = "Splinter"
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(s, s, 8.0 * s)
		cs.shape = box
		b.add_child(cs)
		var mi := MeshInstance3D.new()
		mi.mesh = _mesh
		mi.material_override = _material
		b.add_child(mi)
		b.density = density
		parent.add_child(b, true)
		var off := randf() * deg_to_rad(40.0)
		var turn := randf() * TAU
		var d := (dir * cos(off) + (side * cos(turn) + up * sin(turn)) * sin(off)).normalized()
		b.global_transform = Transform3D(Basis(Quaternion(Vector3.BACK, d)) if d.cross(Vector3.BACK).length() > 1e-4 else Basis(), at + d * (4.0 * s))
		var out := d * speed * randf_range(0.3, 1.0)
		b.linear_velocity = velocity + out
		momentum += density * each * out
		b.angular_velocity = Vector3(randf_range(-10, 10), randf_range(-10, 10), randf_range(-10, 10))
		if ignore:
			b.add_collision_exception_with(ignore)
		for other in thrown:
			b.add_collision_exception_with(other)
		thrown.append(b)
		if body is PhysicsBody3D:
			b.add_collision_exception_with(body)
			var wb := weakref(b)
			var ws := weakref(body)
			b.get_tree().create_timer(0.4, false, true).timeout.connect(func() -> void:
				var sp: PhysicsBody3D = wb.get_ref()
				var hull_body: PhysicsBody3D = ws.get_ref()
				if sp and hull_body:
					sp.remove_collision_exception_with(hull_body))
		if splinter_lifetime > 0.0:
			var wr := weakref(b)
			b.get_tree().create_timer(splinter_lifetime, false, true).timeout.connect(func() -> void:
				var sp: Node = wr.get_ref()
				if sp:
					sp.queue_free())
	return momentum
