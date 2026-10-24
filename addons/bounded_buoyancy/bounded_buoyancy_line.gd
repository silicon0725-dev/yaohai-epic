@icon("res://addons/bounded_buoyancy/icon_line.svg")
class_name BoundedBuoyancyLine
extends Node3D
## A line: a fishing line, a mooring rope, a tow line, a tether. It pulls but never pushes.
##
## Put the node where the line is made fast (a rod's tip, a bollard, a boat's bow) and set body to
## what is on the other end (a float, a sinker, a hooked fish, a buoy), made fast at end_offset in
## that body's own frame. If the node is under a RigidBody3D, that body is pulled too (a float with a
## hook hanging under it, a boat towing another); otherwise the node holds fast.
##
## The line is elastic, as nylon is: stretched by x beyond its length L it pulls with T = E A x / L,
## E the stiffness of its material and A its cross-section (Hooke's law). Shorter than its length it
## hangs slack and pulls nothing. Set length to reel it in or pay it out.
##
## Like the buoyancy, the pull is bounded: each step it is worked out with the stretch and the speed at
## the end of the step, against the inertia of what is on each end at the points where the line is
## made fast, so a stiff line on a light float neither shakes nor flings it, and it never pushes.
## A line pulled harder than breaking_strength breaks; one with a slip_tension runs out instead of
## pulling harder than that.
##
## The line's own weight and the water's drag on it are left out: nylon is little denser than water
## and a line is thin.

## Emitted when the line breaks, with the pull that broke it (N).
signal snapped(tension: float)

## What is on the other end. Leave empty for a line made fast to nothing.
@export var body: RigidBody3D:
	set(value):
		body = value
		_redraw()
## Where the line is made fast on body, in body's own frame.
@export var end_offset: Vector3 = Vector3.ZERO
## Length of the line unstretched, in metres. Shorter reels it in, longer pays it out.
@export_range(0.0, 1000.0, 0.001, "or_greater", "suffix:m") var length: float = 2.0:
	set(value):
		length = maxf(value, 0.0)
## Diameter of the line, in metres. A fishing line is 0.1 to 0.5 mm.
@export_range(0.00001, 0.1, 0.00001, "or_greater", "suffix:m") var diameter: float = 0.0003
## Stiffness of its material (Young's modulus), in GPa: nylon monofilament 2 to 4, braided
## polyethylene 60 to 100, steel wire 200, a rubber band 0.01.
@export_range(0.0001, 300.0, 0.0001, "or_greater", "suffix:GPa") var stiffness: float = 2.5
## Damping of the line's stretch: 0 springs back for ever, 1 settles without springing back.
@export_range(0.0, 2.0, 0.01) var damping: float = 0.2
## The pull at which the line runs out, in newtons, as a reel's drag or a winch's slipping clutch lets
## it: pulled harder, the line pays out instead of pulling harder, and its length grows. 0: it never
## runs out.
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:N") var slip_tension: float = 0.0
## The pull at which the line breaks, in newtons. 0 never breaks. A 0.3 mm nylon line breaks at about
## 60 N (6 kg).
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:N") var breaking_strength: float = 0.0

@export_group("Look")
## Show the line.
@export var visible_line: bool = true
## Its colour.
@export var colour: Color = Color(0.9, 0.9, 0.85, 0.9)

## Pull along the line over the last physics step, in newtons.
var tension: float = 0.0
## How far the line is stretched beyond its length, in metres (negative while slack).
var stretch: float = 0.0
## Distance between its ends, in metres.
var span: float = 0.0
## The line has broken.
var broken: bool = false

const SEGMENTS := 24

var _holder: RigidBody3D = null
var _mesh: ImmediateMesh
var _drawn: MeshInstance3D
var _g := 9.8


func _enter_tree() -> void:
	add_to_group(&"bounded_buoyancy_lines")
	_holder = null
	var p := get_parent()
	while p:
		if p is RigidBody3D:
			_holder = p
			break
		if p is PhysicsBody3D:
			break
		p = p.get_parent()


func _ready() -> void:
	_g = float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	_mesh = ImmediateMesh.new()
	_drawn = MeshInstance3D.new()
	_drawn.mesh = _mesh
	_drawn.top_level = true
	_drawn.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_drawn.material_override = m
	add_child(_drawn, false, Node.INTERNAL_MODE_BACK)
	_redraw()


## Where the line is made fast at this end and at the far end (world).
func ends() -> Array[Vector3]:
	var far := global_position
	if body and is_instance_valid(body):
		far = body.global_transform * end_offset
	return [global_position, far]


## Spring constant of the whole line, N/m: E A / L.
func spring_constant() -> float:
	return stiffness * 1e9 * PI * diameter * diameter * 0.25 / maxf(length, 1e-4)


## Pay out (positive) or reel in (negative) `metres` of line.
func pay_out(metres: float) -> void:
	length = maxf(length + metres, 0.0)


func _physics_process(dt: float) -> void:
	if Engine.is_editor_hint():
		return
	_redraw()
	tension = 0.0
	if broken or body == null or not is_instance_valid(body) or dt <= 0.0:
		return
	var e := ends()
	var a: Vector3 = e[0]
	var b: Vector3 = e[1]
	var d := b - a
	span = d.length()
	stretch = span - length
	if span < 1e-6:
		return
	var n := d / span   # from this end toward the far end
	var a_moves := _moves(_holder)
	var b_moves := _moves(body)
	if not (a_moves or b_moves):
		return
	# Speed at which the ends draw apart now, and how that would change over the step without the line
	# (gravity, buoyancy, drag), so that a weight hanging still stretches it by just m g / k.
	var u := 0.0
	var w := 0.0   # 1 / inertia along the line, both ends together
	if b_moves:
		u += _point_velocity(body, b).dot(n) + _other_acceleration(body).dot(n) * dt
		w += _inverse_mass_at(body, b, n)
	if a_moves:
		u -= _point_velocity(_holder, a).dot(n) + _other_acceleration(_holder).dot(n) * dt
		w += _inverse_mass_at(_holder, a, n)
	if w <= 0.0:
		return
	# Implicit (backward Euler) spring and damper: the pull J (an impulse) is the one the stretch and
	# the speed at the end of the step give. It never pushes.
	var k := spring_constant()
	var c := 2.0 * damping * sqrt(k / w)
	var j := dt * (k * stretch + (k * dt + c) * u) / (1.0 + dt * (k * dt + c) * w)
	if j <= 0.0:
		return
	if slip_tension > 0.0 and j > slip_tension * dt:
		# The line runs out: it pulls with slip_tension, and pays out what it would otherwise have
		# stretched beyond the stretch that pull gives.
		j = slip_tension * dt
		var stretched := stretch + (u - j * w) * dt
		length += maxf(stretched - slip_tension / k, 0.0)
	tension = j / dt
	if breaking_strength > 0.0 and tension > breaking_strength:
		broken = true
		snapped.emit(tension)
		tension = 0.0
		_redraw()
		return
	var pull := n * tension
	if b_moves:
		body.apply_force(-pull, b - body.global_position)
	if a_moves:
		_holder.apply_force(pull, a - _holder.global_position)


static func _moves(rb: RigidBody3D) -> bool:
	return rb != null and is_instance_valid(rb) and not rb.freeze and rb.mass > 0.0


static func _point_velocity(rb: RigidBody3D, at: Vector3) -> Vector3:
	var state := PhysicsServer3D.body_get_direct_state(rb.get_rid())
	if state:
		return state.get_velocity_at_local_position(at - state.transform.origin)
	return rb.linear_velocity


func _other_acceleration(rb: RigidBody3D) -> Vector3:
	if &"last_acceleration" in rb:
		return rb.last_acceleration
	return Vector3.DOWN * _g * rb.gravity_scale


## 1 / the inertia `rb` puts up against a pull along `n` at `at`: its mass and its turning.
static func _inverse_mass_at(rb: RigidBody3D, at: Vector3, n: Vector3) -> float:
	var inv := 1.0 / rb.mass
	var state := PhysicsServer3D.body_get_direct_state(rb.get_rid())
	if state:
		var r := at - state.transform * state.center_of_mass_local
		var rn := r.cross(n)
		inv += rn.dot(state.inverse_inertia_tensor * rn)
	return inv


## The water's surface under `p`, or NAN.
func _surface_at(p: Vector3) -> float:
	var waters: Array = BoundedBuoyancyWater.instances
	var world := get_world_3d()
	for wn in waters:
		if wn.world == world and wn.contains(Vector3(p.x, wn.global_position.y, p.z)):
			return wn.height_at(p)
	return NAN


func _redraw() -> void:
	if _mesh == null:
		return
	_mesh.clear_surfaces()
	if not visible_line or broken or body == null or not is_instance_valid(body) or not is_inside_tree():
		return
	var e := ends()
	var a: Vector3 = e[0]
	var b: Vector3 = e[1]
	var d := a.distance_to(b)
	# Slack line hangs in a curve as long as the line: a parabola of sag s has length about
	# D + 8 s² / 3 D. It lies along the water rather than sinking through it.
	var sag := sqrt(3.0 * d * maxf(length - d, 0.0) / 8.0) if d > 1e-4 else 0.0
	var floor_y := NAN
	if sag > 0.0:
		var s := _surface_at(0.5 * (a + b))
		if not is_nan(s):
			floor_y = minf(s, minf(a.y, b.y))
	_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in SEGMENTS + 1:
		var t := float(i) / SEGMENTS
		var p := a.lerp(b, t) + Vector3.DOWN * (4.0 * sag * t * (1.0 - t))
		if not is_nan(floor_y) and p.y < floor_y:
			p.y = floor_y
		_mesh.surface_set_color(colour)
		_mesh.surface_add_vertex(p)
	_mesh.surface_end()
