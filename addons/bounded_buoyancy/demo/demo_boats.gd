extends Node3D
## BOATS: foils and propellers. Drive the motorboat (a keel, a rudder and a propeller) while a dinghy
## (a centreboard, a rudder and a sail that trims itself) sails a course on its own: beating up into
## the wind in tacks, then running back before it.
##   W / S       throttle up / down (astern below zero)
##   A / D       rudder to port / starboard (it centres itself when let go)
##   C           camera: follow the motorboat, follow the dinghy, both boats, or look over the lake
##   Space       run again
##   Tab         next scene
## Everything here is ordinary Bounded Buoyancy bodies with BoundedBuoyancyFoil and
## BoundedBuoyancyThruster nodes under them; the meshes are for show.

const LOOK := preload("res://addons/bounded_buoyancy/demo/demo_look.gd")
const BB := preload("res://addons/bounded_buoyancy/bounded_buoyancy_body.gd")
const BW := preload("res://addons/bounded_buoyancy/bounded_buoyancy_water.gd")
const BWIND := preload("res://addons/bounded_buoyancy/bounded_buoyancy_wind.gd")
const FOIL := preload("res://addons/bounded_buoyancy/bounded_buoyancy_foil.gd")
const THRUSTER := preload("res://addons/bounded_buoyancy/bounded_buoyancy_thruster.gd")
const NEXT_SCENE := "res://addons/bounded_buoyancy/demo/demo_flood.tscn"

const ORANGE := Color(0.93, 0.5, 0.15)
const TEAL := Color(0.16, 0.62, 0.56)
const INK := Color(0.12, 0.14, 0.18)
const CLOTH := Color(0.97, 0.96, 0.92)
const KNOTS := 1.943844      # m/s to knots
const WIND_SPEED := 5.0      # m/s, blowing towards +z (from the far side of the lake)
const UPWIND_LIMIT := -70.0  # the dinghy turns to run back once it is this far upwind
const DOWNWIND_LIMIT := 15.0

var _water: Node3D
var _wind: Node3D
var _boat: RigidBody3D       # the motorboat
var _rudder: Node3D
var _prop: Node3D
var _prop_mesh: Node3D
var _dinghy: RigidBody3D
var _d_rudder: Node3D
var _sail: Node3D
var _buoys: Array = []
var _cam: Camera3D
var _view := 0               # 0 motorboat, 1 dinghy, 2 both boats, 3 overview
var _status: Label
var _d_status: Label
var _throttle := 0.0
var _helm := 0.0
var _leg := 0                # dinghy: 0 starboard tack, 1 port tack, 2 running back
var _leg_time := 0.0
var _t := 0.0
var _autodrive := false      # for recordings: --autodrive drives the motorboat on a set course


func _ready() -> void:
	LOOK.sea_and_sky(self, Vector2(-40.0, -35.0), 0.004)
	_water = BW.new()
	_water.size = Vector3(3000.0, 4.0, 3000.0)
	_water.surface_color = Color(0.06, 0.24, 0.32, 0.85)
	_water.position = Vector3(0, 0, -30)
	_water.wave_height = 0.05
	_water.wave_length = 3.0
	_water.wave_direction = 80.0
	add_child(_water)
	_wind = BWIND.new()
	_wind.velocity = Vector3(0, 0, WIND_SPEED)
	_wind.gust_strength = 0.2
	_wind.gust_period = 7.0
	_wind.direction_swing = 6.0
	add_child(_wind)
	_cam = Camera3D.new()
	_cam.fov = 60.0
	_cam.far = 600.0
	add_child(_cam)
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "Boats: drive the motorboat; the dinghy sails up into the wind on its own"
	title.position = Vector2(24, 14)
	title.add_theme_color_override("font_color", INK)
	title.add_theme_font_size_override("font_size", 20)
	layer.add_child(title)
	_status = Label.new()
	_status.position = Vector2(24, 44)
	_status.add_theme_color_override("font_color", ORANGE.darkened(0.3))
	_status.add_theme_font_size_override("font_size", 18)
	layer.add_child(_status)
	_d_status = Label.new()
	_d_status.position = Vector2(24, 70)
	_d_status.add_theme_color_override("font_color", TEAL.darkened(0.3))
	_d_status.add_theme_font_size_override("font_size", 18)
	layer.add_child(_d_status)
	var keys := Label.new()
	keys.text = "W / S: throttle     A / D: rudder     C: camera     Space: run again     Tab: next scene"
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 24
	keys.offset_top = -38
	keys.add_theme_color_override("font_color", INK.lightened(0.35))
	keys.add_theme_font_size_override("font_size", 16)
	layer.add_child(keys)
	for arg in OS.get_cmdline_user_args():
		if arg == "--autodrive":
			_autodrive = true
		elif arg.begins_with("--view="):
			_view = int(arg.get_slice("=", 1))
	_reset()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_reset()
		elif event.keycode == KEY_TAB:
			get_tree().change_scene_to_file(NEXT_SCENE)
		elif event.keycode == KEY_C:
			_view = (_view + 1) % 4


func _reset() -> void:
	for n in [_boat, _dinghy]:
		if n:
			n.queue_free()
	for n in _buoys:
		n.queue_free()
	_buoys.clear()
	_throttle = 0.0
	_helm = 0.0
	_leg = 0
	_leg_time = 0.0
	_t = 0.0
	_motorboat(Vector3(-4, 0.05, 8))
	_sailing_dinghy(Vector3(8, 0.05, 2), -45.0)
	for at in [Vector3(-14, 0.2, -40), Vector3(14, 0.2, -40), Vector3(0, 0.2, -80)]:
		_buoys.append(_buoy(at))
	_cam.global_position = Vector3(-4, 4.5, 18)
	_cam.look_at(Vector3(-4, 0, 8))


func _physics_process(dt: float) -> void:
	if not _boat:
		return
	_t += dt
	# The motorboat: throttle moves with W / S and stays; the rudder follows A / D and centres itself.
	var up := Input.is_key_pressed(KEY_W)
	var down := Input.is_key_pressed(KEY_S)
	var steer := 0.0
	if Input.is_key_pressed(KEY_A):
		steer -= 1.0
	if Input.is_key_pressed(KEY_D):
		steer += 1.0
	if _autodrive:
		# Full ahead, then a turn to port, a run, a turn to starboard, and round again.
		up = _t > 0.5
		var phase := fmod(_t, 22.0)
		steer = 0.0 if phase < 5.0 else (-1.0 if phase < 11.0 else (0.0 if phase < 14.0 else 1.0))
	if up:
		_throttle = minf(_throttle + 0.6 * dt, 1.0)
	if down:
		_throttle = maxf(_throttle - 0.6 * dt, -0.5)
	_helm = move_toward(_helm, 30.0 * steer, 90.0 * dt)
	_rudder.angle = _helm
	_prop.throttle = _throttle
	_prop_mesh.rotate_z(_throttle * 40.0 * dt)
	_steer_dinghy(dt)
	_keep_on_the_lake(_boat)
	_keep_on_the_lake(_dinghy)
	_update_hud()


## A boat that runs off the edge of the lake comes back near the middle, heading the same way.
func _keep_on_the_lake(b: RigidBody3D) -> void:
	var d := b.global_position - _water.global_position
	if absf(d.x) < 0.45 * _water.size.x and absf(d.z) < 0.45 * _water.size.z:
		return
	var heading := -b.global_transform.basis.z
	heading.y = 0.0
	b.global_position = _water.global_position - heading.normalized() * 60.0 + Vector3(0, 0.1, 0)


func _process(dt: float) -> void:
	if not _boat:
		return
	var target: RigidBody3D = _boat if _view == 0 else _dinghy
	var want_pos: Vector3
	var look: Vector3
	if _view == 3:
		want_pos = _water.global_position + Vector3(0, 45, 60)
		look = _water.global_position + Vector3(0, 0, -10)
	elif _view == 2:
		# Both boats in view, from downwind and a little to the side.
		var a := _boat.global_position
		var b := _dinghy.global_position
		var mid := 0.5 * (a + b)
		var apart := maxf(Vector2(a.x - b.x, a.z - b.z).length(), 8.0)
		want_pos = mid + Vector3(-0.35 * apart, 0.55 * apart + 3.0, 0.9 * apart + 6.0)
		look = mid + Vector3(0, 1.0, 0)
	else:
		var fwd := -target.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized() if fwd.length_squared() > 1e-6 else Vector3.FORWARD
		var back := 11.0 if _view == 0 else 15.0
		want_pos = target.global_position - fwd * back + Vector3(0, 5.0 if _view == 0 else 6.5, 0)
		look = target.global_position + Vector3(0, 0.8, 0) + fwd * 3.0
	var k := 1.0 - exp(-3.0 * dt)
	_cam.global_position = _cam.global_position.lerp(want_pos, k)
	var basis_now := _cam.global_transform.basis
	var basis_want := Transform3D(Basis(), _cam.global_position).looking_at(look, Vector3.UP).basis
	_cam.global_transform.basis = basis_now.slerp(basis_want, k).orthonormalized()


## The dinghy sails a course by itself: up into the wind in tacks 45 degrees off it, turning
## through the wind every 25 s (or when it nears the side of the lake), until it is well upwind; then
## it runs back before the wind and starts again.
func _steer_dinghy(dt: float) -> void:
	_leg_time += dt
	var p := _dinghy.global_position
	if _leg == 2:
		if p.z > DOWNWIND_LIMIT:
			_leg = 0 if p.x < 0.0 else 1
			_leg_time = 0.0
	elif p.z < UPWIND_LIMIT:
		_leg = 2
		_leg_time = 0.0
	elif _leg_time > 25.0 or (_leg == 0 and p.x > 40.0) or (_leg == 1 and p.x < -40.0):
		_leg = 1 - _leg
		_leg_time = 0.0
	var off := 180.0 if _leg == 2 else 45.0
	var side := 1.0 if _leg == 0 else -1.0
	# The wind comes from -z: a course `off` degrees off it, to starboard (+x) or to port.
	var course := Vector3(side * sin(deg_to_rad(off)), 0, -cos(deg_to_rad(off)))
	var f := -_dinghy.global_transform.basis.z
	var error := rad_to_deg(atan2(f.cross(course).y, f.x * course.x + f.z * course.z))
	_d_rudder.angle = clampf(-1.5 * error + 25.0 * rad_to_deg(_dinghy.angular_velocity.y) / 60.0, -30.0, 30.0)


func _update_hud() -> void:
	var v := _boat.linear_velocity
	var speed := Vector2(v.x, v.z).length()
	_status.text = "Motorboat  %.1f knots   throttle %d%%   rudder %+d°   thrust %d N" % [speed * KNOTS,
		roundi(100.0 * _throttle), roundi(_helm), roundi(_prop.force.length())]
	var dv := _dinghy.linear_velocity
	var f := -_dinghy.global_transform.basis.z
	var off := rad_to_deg(Vector2(f.x, f.z).angle_to(Vector2(0, -1)))
	var tilt := rad_to_deg(acos(clampf(_dinghy.global_transform.basis.y.dot(Vector3.UP), -1.0, 1.0)))
	var what := "running before the wind" if _leg == 2 else ("beating, starboard tack" if _leg == 1 else "beating, port tack")
	_d_status.text = "Dinghy  %.1f knots   %d° off the wind   sail out %d°   heel %d°   %s" % [Vector2(dv.x, dv.z).length() * KNOTS,
		roundi(absf(off)), roundi(absf(_sail.angle)), roundi(tilt), what]


func _material(c: Color, rough := 0.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


func _hull_mesh(points: PackedVector3Array, color: Color) -> MeshInstance3D:
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces: PackedVector3Array = shape.get_debug_mesh().get_faces()
	for i in range(0, faces.size(), 3):
		st.add_vertex(faces[i])
		st.add_vertex(faces[i + 1])
		st.add_vertex(faces[i + 2])
	st.generate_normals()
	st.set_material(_material(color))
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	return mi


## A thin blade for a foil's mesh: span along Y, chord along Z from `from_z` aft.
func _blade(foil: Node3D, color: Color, from_z: float, thickness := 0.03) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(thickness, foil.span_length(), foil.chord_length())
	bm.material = _material(color, 0.8)
	mi.mesh = bm
	mi.position = Vector3(0, 0, from_z + 0.5 * foil.chord_length())
	foil.add_child(mi)


func _foil(b: Node3D, at: Vector3, area: float, ar: float, medium := 0, effort := 0.0) -> Node3D:
	var f: Node3D = FOIL.new()
	f.area = area
	f.aspect_ratio = ar
	f.medium = medium
	f.effort_offset = effort
	f.position = at
	b.add_child(f)
	return f


## The motorboat: 2.4 m, 180 kg, ballasted low, with a keel, a rudder at the stern and a propeller
## under it (400 N, top speed 5 m/s, about 10 knots).
func _motorboat(at: Vector3) -> void:
	var points := PackedVector3Array([Vector3(-0.45, 0.2, -1.1), Vector3(0.45, 0.2, -1.1), Vector3(-0.3, -0.2, -0.9), Vector3(0.3, -0.2, -0.9),
		Vector3(-0.45, 0.2, 1.2), Vector3(0.45, 0.2, 1.2), Vector3(-0.3, -0.2, 1.1), Vector3(0.3, -0.2, 1.1), Vector3(0, 0.2, -1.6), Vector3(0, -0.1, -1.4)])
	var b := BB.new()
	var cs := CollisionShape3D.new()
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	cs.shape = shape
	b.add_child(cs)
	b.add_child(_hull_mesh(points, ORANGE))
	b.density = 250.0
	_boat_settings(b, 0.2)
	b.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	b.center_of_mass = Vector3(0, -0.1, -0.04)
	var keel := _foil(b, Vector3(0, -0.4, 0), 0.15, 1.5)
	_blade(keel, INK.lightened(0.2), -0.5 * keel.chord_length())
	_rudder = _foil(b, Vector3(0, -0.3, 1.15), 0.06, 2.0, 0, 0.04)
	_blade(_rudder, INK.lightened(0.2), 0.0)
	_prop = THRUSTER.new()
	_prop.max_thrust = 400.0
	_prop.max_speed = 5.0
	_prop.diameter = 0.25
	_prop.position = Vector3(0, -0.3, 1.1)
	b.add_child(_prop)
	_prop_mesh = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.12
	disc.bottom_radius = 0.12
	disc.height = 0.02
	disc.radial_segments = 3
	disc.material = _material(Color(0.75, 0.68, 0.4), 0.3)
	_prop_mesh.mesh = disc
	_prop_mesh.rotation_degrees = Vector3(90, 0, 0)
	_prop.add_child(_prop_mesh)
	# A windscreen and a seat, for show.
	var screen := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(0.8, 0.25, 0.03)
	sm.material = _material(Color(0.7, 0.85, 0.95, 0.6), 0.1)
	sm.material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	screen.mesh = sm
	screen.position = Vector3(0, 0.33, -0.4)
	screen.rotation_degrees = Vector3(-20, 0, 0)
	b.add_child(screen)
	b.position = at
	add_child(b)
	_boat = b


## The dinghy: 3.6 m, a heavy centreboard and the crew's weight low down, a rudder, and an 8 m² sail on
## a mast, trimming itself 15 degrees to the wind it feels.
func _sailing_dinghy(at: Vector3, yaw_deg: float) -> void:
	var points := PackedVector3Array([Vector3(-0.7, 0.25, -1.4), Vector3(0.7, 0.25, -1.4), Vector3(-0.45, -0.15, -1.2), Vector3(0.45, -0.15, -1.2),
		Vector3(-0.7, 0.25, 1.7), Vector3(0.7, 0.25, 1.7), Vector3(-0.45, -0.15, 1.6), Vector3(0.45, -0.15, 1.6), Vector3(0, 0.25, -1.9), Vector3(0, -0.05, -1.7)])
	var b := BB.new()
	var cs := CollisionShape3D.new()
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	cs.shape = shape
	b.add_child(cs)
	b.add_child(_hull_mesh(points, CLOTH.darkened(0.05)))
	b.density = 160.0
	_boat_settings(b, 0.12)
	b.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	b.center_of_mass = Vector3(0, -0.38, 0.06)
	var board := _foil(b, Vector3(0, -0.6, -0.1), 0.5, 2.0)
	_blade(board, INK.lightened(0.25), -0.5 * board.chord_length(), 0.025)
	_d_rudder = _foil(b, Vector3(0, -0.35, 1.65), 0.12, 2.5, 0, 0.06)
	_blade(_d_rudder, INK.lightened(0.25), 0.0, 0.025)
	_sail = _foil(b, Vector3(0, 2.8, -0.6), 8.0, 2.5, 1, 0.6)
	_sail.auto_trim = true
	_blade(_sail, CLOTH, 0.0, 0.015)
	var mast := MeshInstance3D.new()
	var mm := CylinderMesh.new()
	mm.top_radius = 0.035
	mm.bottom_radius = 0.05
	mm.height = 5.4
	mm.material = _material(INK.lightened(0.4), 0.4)
	mast.mesh = mm
	mast.position = Vector3(0, 2.9, -0.62)
	b.add_child(mast)
	var boom := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.03
	bm.bottom_radius = 0.03
	bm.height = _sail.chord_length()
	bm.material = mm.material
	boom.mesh = bm
	boom.rotation_degrees = Vector3(90, 0, 0)
	boom.position = Vector3(0, -0.5 * _sail.span_length(), 0.5 * _sail.chord_length())
	_sail.add_child(boom)
	b.position = at
	b.rotation_degrees = Vector3(0, yaw_deg, 0)
	add_child(b)
	_dinghy = b


## Settings that suit a hull: a streamlined hull has far less drag than the default (a sphere's), and
## a hull dipping in waves is not plunging into the water, so it shares no momentum as it dips.
func _boat_settings(b: RigidBody3D, drag: float) -> void:
	b.drag_coefficient = drag
	b.keep_momentum_on_entry = false


## A floating mark: a ball the boats can bump into.
func _buoy(at: Vector3) -> RigidBody3D:
	var b := BB.new()
	var cs := CollisionShape3D.new()
	var s := SphereShape3D.new()
	s.radius = 0.35
	cs.shape = s
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.35
	sm.height = 0.7
	sm.material = _material(Color(0.95, 0.85, 0.2), 0.4)
	mi.mesh = sm
	b.add_child(mi)
	b.density = 300.0
	b.position = at
	add_child(b)
	return b
