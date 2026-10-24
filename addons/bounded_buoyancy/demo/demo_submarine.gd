extends Node3D
## SUBMARINE: real sea water, layered as it is off a river mouth or in a fjord: brackish water at the
## top over cold, salty water from about 25 m down. Its density comes from its temperature, its salt
## and the pressure (UNESCO's equation of state), and grows by about 5 kg/m³ across the layer.
##
## Flood the submarine's main ballast tanks and it sinks until the water around it is as dense as it
## is, and stays there with nothing holding it: it rests on the salt layer, as submarines do (a
## "liquid bottom"). The trim tank takes in or pumps out a few hundred kilograms of water: a little
## heavier and it settles a little deeper, where the water is denser still; a little lighter and it
## rises to where the water is less dense. Blow the main tanks and it comes up to the surface.
## Three drifting floats, each as dense as the water at one depth, hang at 10, 25 and 45 m; the fish's
## swim bladders match the water they are in.
##   F       flood the main ballast tanks      B   blow them (come up)
##   Up/Down pump water into / out of the trim tank
##   W/S     propeller ahead / astern          A/D rudder
##   T       four times faster                 C   change the camera
##   R       start again                       Tab next scene

const BB := preload("res://addons/bounded_buoyancy/bounded_buoyancy_body.gd")
const BW := preload("res://addons/bounded_buoyancy/bounded_buoyancy_water.gd")
const FISH := preload("res://addons/bounded_buoyancy/bounded_buoyancy_fish.gd")
const FOIL := preload("res://addons/bounded_buoyancy/bounded_buoyancy_foil.gd")
const THRUSTER := preload("res://addons/bounded_buoyancy/bounded_buoyancy_thruster.gd")
const LOOK := preload("res://addons/bounded_buoyancy/demo/demo_look.gd")
const NEXT_SCENE := "res://addons/bounded_buoyancy/demo/demo_battle.tscn"

const LONG := 22.0              # m, the submarine's length
const RADIUS := 1.6             # m, its hull's
const RESTS_AT := 26.0          # m down: where it is neutral with its main tanks full and no trim
const MAIN_FILL := 14.0         # s to flood the main tanks
const MAIN_BLOW := 9.0          # s to blow them
const TRIM_RATE := 60.0         # kg/s the trim pump moves
const TRIM_MAX := 1500.0        # kg either way
const FLOOR := 70.0             # m, the sea bed
const FLOAT_DEPTHS := [10.0, 25.0, 45.0]

var _water: Node3D
var _sub: RigidBody3D
var _prop: Node3D
var _rudder: Node3D
var _dry := 0.0                 # kg: the submarine without ballast
var _main_capacity := 0.0       # kg of water its main tanks hold
var _main := 0.0                # 0 empty, 1 full
var _main_to := 0.0
var _trim := 0.0                # kg in the trim tank (negative: pumped out below its middle)
var _floats: Array = []
var _fish: Array = []
var _cam: Camera3D
var _view := 0
var _env: Environment
var _sky_fog := 0.0
var _status: Label
var _chart: Control
var _ticks := Engine.physics_ticks_per_second
var _max_steps := Engine.max_physics_steps_per_frame
var _fast := false


func _ready() -> void:
	LOOK.sea_and_sky(self, Vector2(-40.0, -30.0))
	_env = (get_child(0) as WorldEnvironment).environment
	_sky_fog = _env.fog_density
	_water = BW.new()
	_water.size = Vector3(1200, FLOOR + 10.0, 1200)
	_water.salinity = 28.0
	_water.temperature = 16.0
	_water.deep_temperature = 6.0
	_water.deep_salinity_change = 6.0
	_water.thermocline_depth = 25.0
	_water.wave_height = 0.15
	_water.wave_length = 14.0
	_water.surface_color = Color(0.05, 0.20, 0.26, 0.85)
	add_child(_water)
	_bed()
	_cam = Camera3D.new()
	_cam.fov = 60.0
	_cam.far = 900.0
	add_child(_cam)
	_hud()
	_reset()


func _reset() -> void:
	for n in [_sub] + _floats + _fish:
		if n and is_instance_valid(n):
			n.queue_free()
	_floats.clear()
	_fish.clear()
	_main = 0.0
	_main_to = 0.0
	_trim = 0.0
	_make_sub()
	for d in FLOAT_DEPTHS:
		_add_float(d)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	for i in 8:
		_add_fish(Vector3(rng.randf_range(-30, 30), -rng.randf_range(8, 40), rng.randf_range(-60, -15)), rng)


# --- The submarine ----------------------------------------------------------------------------

func _make_sub() -> void:
	_sub = BB.new()
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = RADIUS
	cap.height = LONG
	cs.shape = cap
	cs.rotation_degrees = Vector3(90, 0, 0)
	_sub.add_child(cs)
	_sub.collision_layer = 2
	_sub.collision_mask = 1
	_sub.added_mass_coefficient = 0.1     # a long body moving along its length takes little water with it
	_sub.angular_drag = 2.0
	# Its weight low in the hull keeps it upright.
	_sub.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	_sub.center_of_mass = Vector3(0, -0.45, 0)
	_sub.position = Vector3(0, 0.6, 0)
	_sub.add_child(_sub_look())
	# Propeller and rudder at the stern; a sail (the fin) on top steadies it.
	_prop = THRUSTER.new()
	_prop.max_thrust = 60000.0
	_prop.max_speed = 6.0
	_prop.diameter = 2.0
	_prop.position = Vector3(0, 0, 0.5 * LONG)
	_sub.add_child(_prop)
	_rudder = FOIL.new()
	_rudder.area = 4.0
	_rudder.aspect_ratio = 1.5
	_rudder.position = Vector3(0, 0, 0.5 * LONG - 0.5)
	_sub.add_child(_rudder)
	var fin: Node3D = FOIL.new()
	fin.area = 6.0
	fin.aspect_ratio = 0.8
	fin.position = Vector3(0, RADIUS + 1.2, -0.2 * LONG)
	_sub.add_child(fin)
	add_child(_sub)
	# Its weight without ballast: with its main tanks full and the trim tank at its middle, it is
	# as dense as the water RESTS_AT down. Its main tanks hold a tenth of its displacement (its
	# reserve of buoyancy on the surface, as a real submarine's).
	var vol: float = PI * RADIUS * RADIUS * (LONG - 2.0 * RADIUS) + 4.0 / 3.0 * PI * pow(RADIUS, 3)
	var neutral: float = _water.density_at(Vector3(0, -RESTS_AT, 0)) * vol
	_main_capacity = 0.1 * neutral
	_dry = neutral - _main_capacity
	_ballast()


## Its density from its own weight and the water in its tanks.
func _ballast() -> void:
	var vol: float = _sub.volume if _sub.volume > 0.0 else PI * RADIUS * RADIUS * (LONG - 2.0 * RADIUS) + 4.0 / 3.0 * PI * pow(RADIUS, 3)
	_sub.density = (_dry + _main * _main_capacity + _trim) / vol


func _sub_look() -> Node3D:
	var root := Node3D.new()
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.13, 0.14, 0.16)
	steel.roughness = 0.55
	steel.metallic = 0.3
	var hull := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = RADIUS
	cm.height = LONG
	cm.radial_segments = 24
	cm.rings = 8
	hull.mesh = cm
	hull.rotation_degrees = Vector3(90, 0, 0)
	hull.material_override = steel
	root.add_child(hull)
	var sail := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.9, 2.6, 4.0)
	sail.mesh = bm
	sail.position = Vector3(0, RADIUS + 1.0, -0.2 * LONG)
	sail.material_override = steel
	root.add_child(sail)
	var planes := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(4.6, 0.12, 1.4)
	planes.mesh = pm
	planes.position = Vector3(0, 0, 0.5 * LONG - 1.2)
	planes.material_override = steel
	root.add_child(planes)
	var rudder := MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(0.12, 3.6, 1.6)
	rudder.mesh = rm
	rudder.position = Vector3(0, 0, 0.5 * LONG - 0.6)
	rudder.material_override = steel
	root.add_child(rudder)
	return root


# --- Floats and fish --------------------------------------------------------------------------

## A drifting float (as oceanographers' floats are), as dense as the water `depth` down, with its
## depth written on it.
func _add_float(depth: float) -> void:
	var f := BB.new()
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.12
	cyl.height = 1.6
	cs.shape = cyl
	f.add_child(cs)
	f.collision_layer = 0
	f.collision_mask = 0
	f.angular_drag = 8.0
	var at := Vector3(-12.0 + 12.0 * _floats.size(), -depth + 6.0, -30.0)
	f.density = _water.density_at(Vector3(at.x, -depth, at.z))
	f.position = at
	f.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	f.center_of_mass = Vector3(0, -0.5, 0)
	var look := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.12
	cm.bottom_radius = 0.12
	cm.height = 1.6
	look.mesh = cm
	var yellow := StandardMaterial3D.new()
	yellow.albedo_color = Color(1.0, 0.78, 0.1)
	yellow.emission_enabled = true
	yellow.emission = Color(0.5, 0.35, 0.0)
	look.material_override = yellow
	f.add_child(look)
	var tag := Label3D.new()
	tag.text = "%.1f kg/m³" % f.density
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.position = Vector3(0, 1.4, 0)
	tag.font_size = 48
	tag.pixel_size = 0.01
	tag.outline_size = 10
	tag.no_depth_test = true
	f.add_child(tag)
	f.set_meta(&"depth", depth)
	add_child(f)
	_floats.append(f)


func _add_fish(at: Vector3, rng: RandomNumberGenerator) -> void:
	var f: RigidBody3D = FISH.new()
	var long := rng.randf_range(0.5, 0.9)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.1 * long
	cap.height = long
	cs.shape = cap
	cs.rotation_degrees = Vector3(90, 0, 0)
	f.add_child(cs)
	f.collision_layer = 0
	f.collision_mask = 0
	f.position = at
	f.mouth = Vector3(0, 0, -0.5 * long)
	f.cruise_speed = 1.2 * long
	f.burst_speed = 6.0 * long
	f.max_thrust = 30.0 * long
	f.min_depth = -at.y - 4.0
	f.max_depth = -at.y + 4.0
	f.home_range = 12.0
	f.appetite = 0.0
	f.random_seed = rng.randi() | 1
	var look := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.1 * long
	sm.height = long
	look.mesh = sm
	look.rotation_degrees = Vector3(90, 0, 0)
	var silver := StandardMaterial3D.new()
	silver.albedo_color = Color(0.6, 0.66, 0.7)
	silver.metallic = 0.6
	silver.roughness = 0.3
	look.material_override = silver
	f.add_child(look)
	add_child(f)
	_fish.append(f)


# --- Playing ----------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F:
				_main_to = 1.0
			KEY_B:
				_main_to = 0.0
			KEY_C:
				_view = (_view + 1) % 2
			KEY_T:
				_fast = not _fast
				_speed(4.0 if _fast else 1.0)
			KEY_R:
				_reset()
			KEY_TAB:
				_speed(1.0)
				get_tree().change_scene_to_file(NEXT_SCENE)


func _exit_tree() -> void:
	_speed(1.0)


func _speed(scale: float) -> void:
	Engine.time_scale = scale
	Engine.physics_ticks_per_second = maxi(_ticks, roundi(_ticks * scale))
	Engine.max_physics_steps_per_frame = maxi(_max_steps, roundi(_max_steps * scale))


## Flood or blow the main tanks, pump the trim tank; the propeller and the rudder.
func flood(full: bool) -> void:
	_main_to = 1.0 if full else 0.0


func pump(kg: float) -> void:
	_trim = clampf(_trim + kg, -TRIM_MAX, TRIM_MAX)


func _physics_process(dt: float) -> void:
	if not is_instance_valid(_sub):
		return
	# Flooding is slower than blowing; both stop when the tanks are full or empty.
	if _main < _main_to:
		_main = minf(_main + dt / MAIN_FILL, _main_to)
	elif _main > _main_to:
		_main = maxf(_main - dt / MAIN_BLOW, _main_to)
	if Input.is_key_pressed(KEY_UP):
		pump(-TRIM_RATE * dt)
	elif Input.is_key_pressed(KEY_DOWN):
		pump(TRIM_RATE * dt)
	_ballast()
	var throttle := 0.0
	if Input.is_key_pressed(KEY_W):
		throttle = 1.0
	elif Input.is_key_pressed(KEY_S):
		throttle = -0.5
	_prop.throttle = throttle
	var turn := 0.0
	if Input.is_key_pressed(KEY_A):
		turn = -25.0
	elif Input.is_key_pressed(KEY_D):
		turn = 25.0
	_rudder.angle = turn


func _process(dt: float) -> void:
	if not is_instance_valid(_sub):
		return
	var at := _sub.global_position
	var fwd := -_sub.global_transform.basis.z
	var from: Vector3
	var look_at_point := at
	if _view == 0:
		# Alongside and a little astern, at its depth.
		from = at + fwd.cross(Vector3.UP).normalized() * -22.0 - fwd * 8.0 + Vector3(0, 3.0, 0)
	else:
		# Further off and below, looking up at it against the light.
		from = Vector3(at.x + 30.0, clampf(at.y - 8.0, -FLOOR + 3.0, -2.0), at.z + 18.0)
		look_at_point = Vector3(at.x, at.y, at.z - 10.0)
	_cam.global_position = _cam.global_position.lerp(from, 1.0 - exp(-dt / 0.6)) if _cam.global_position != Vector3.ZERO else from
	_cam.look_at(look_at_point, Vector3.UP)
	# Under the water the light is lost with depth.
	var depth: float = _water.height_at(_cam.global_position) - _cam.global_position.y
	if depth > 0.0:
		var dark := clampf(depth / FLOOR, 0.0, 1.0)
		_env.fog_density = 0.035
		_env.fog_light_color = Color(0.06, 0.22, 0.28).lerp(Color(0.01, 0.04, 0.07), dark)
		_env.fog_sky_affect = 1.0
		_env.fog_aerial_perspective = 0.0
		_env.ambient_light_energy = lerpf(0.9, 0.25, dark)
	else:
		_env.fog_density = _sky_fog
		_env.fog_light_color = Color(0.68, 0.77, 0.86)
		_env.fog_sky_affect = 0.0
		_env.fog_aerial_perspective = 0.4
		_env.ambient_light_energy = 0.9
	_status.text = _report()
	_chart.queue_redraw()


func _report() -> String:
	var depth := -_sub.global_position.y
	var here: float = _water.density_at(_sub.global_position)
	return "Depth %5.1f m   rising %+5.2f m/s     submarine %7.1f kg/m³   water there %7.1f kg/m³     main tanks %3d%%   trim %+5.0f kg" % [
		depth, _sub.linear_velocity.y, _sub.density, here, roundi(_main * 100.0), _trim]


# --- Words and the chart ----------------------------------------------------------------------

func _hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "Submarine on the salt layer: real sea water, denser with depth"
	title.position = Vector2(24, 14)
	_outline(title)
	title.add_theme_font_size_override("font_size", 20)
	layer.add_child(title)
	_status = Label.new()
	_status.position = Vector2(24, 44)
	_outline(_status)
	_status.add_theme_font_size_override("font_size", 15)
	layer.add_child(_status)
	var keys := Label.new()
	keys.text = "F: flood main tanks     B: blow them     Up/Down: trim tank     W/S: propeller     A/D: rudder     T: faster     C: camera     R: again     Tab: next"
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 24
	keys.offset_top = -38
	_outline(keys)
	keys.add_theme_font_size_override("font_size", 15)
	layer.add_child(keys)
	_chart = Control.new()
	_chart.position = Vector2(24, 80)
	_chart.size = Vector2(170, 260)
	_chart.draw.connect(_draw_chart)
	layer.add_child(_chart)


## Density against depth, 0 to the sea bed: the water's, with the submarine's density at its depth.
func _draw_chart() -> void:
	var w := _chart.size.x
	var h := _chart.size.y
	_chart.draw_rect(Rect2(Vector2.ZERO, _chart.size), Color(0.02, 0.06, 0.1, 0.55))
	var lo := 1018.0
	var hi := 1030.0
	var pts := PackedVector2Array()
	for i in 41:
		var d := FLOOR * i / 40.0
		var rho: float = _water.density_at(Vector3(0, -d, 0))
		pts.append(Vector2((rho - lo) / (hi - lo) * w, d / FLOOR * h))
	_chart.draw_polyline(pts, Color(0.5, 0.85, 1.0), 2.0, true)
	if is_instance_valid(_sub):
		var d := clampf(-_sub.global_position.y, 0.0, FLOOR)
		var x := clampf((_sub.density - lo) / (hi - lo), 0.0, 1.0) * w
		_chart.draw_circle(Vector2(x, d / FLOOR * h), 5.0, Color(1.0, 0.4, 0.3))
	for f in _floats:
		if is_instance_valid(f):
			var d := clampf(-f.global_position.y, 0.0, FLOOR)
			_chart.draw_circle(Vector2((f.density - lo) / (hi - lo) * w, d / FLOOR * h), 3.5, Color(1.0, 0.8, 0.1))
	var font := ThemeDB.fallback_font
	_chart.draw_string(font, Vector2(4, 14), "density, kg/m³", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.92, 1.0))
	_chart.draw_string(font, Vector2(4, h - 6), "%d" % int(lo), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.7, 0.8, 0.9))
	_chart.draw_string(font, Vector2(w - 34, h - 6), "%d" % int(hi), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.7, 0.8, 0.9))
	_chart.draw_string(font, Vector2(w - 64, 28), "%d m" % 0, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.7, 0.8, 0.9))
	_chart.draw_string(font, Vector2(w - 64, h - 20), "%d m" % int(FLOOR), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.7, 0.8, 0.9))


func _outline(label: Label) -> void:
	label.add_theme_color_override("font_color", Color(0.93, 0.96, 1.0))
	label.add_theme_color_override("font_outline_color", Color(0.02, 0.05, 0.1, 0.9))
	label.add_theme_constant_override("outline_size", 5)


## The sea bed: sand, with rocks and weed.
func _bed() -> void:
	var sand := StandardMaterial3D.new()
	sand.albedo_color = Color(0.45, 0.42, 0.33)
	sand.roughness = 1.0
	var bed := StaticBody3D.new()
	var bcs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(600, 2, 600)
	bcs.shape = box
	bed.add_child(bcs)
	bed.position = Vector3(0, -FLOOR - 1.0, 0)
	var bm := MeshInstance3D.new()
	var bmm := BoxMesh.new()
	bmm.size = box.size
	bm.mesh = bmm
	bm.material_override = sand
	bed.add_child(bm)
	add_child(bed)
	var rock := StandardMaterial3D.new()
	rock.albedo_color = Color(0.25, 0.26, 0.25)
	var weed := StandardMaterial3D.new()
	weed.albedo_color = Color(0.12, 0.3, 0.12)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	for i in 60:
		var r := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = rng.randf_range(0.6, 3.5)
		sm.height = sm.radius * rng.randf_range(0.8, 1.4)
		r.mesh = sm
		r.material_override = rock
		r.position = Vector3(rng.randf_range(-120, 120), -FLOOR + 0.3 * sm.radius, rng.randf_range(-160, 60))
		add_child(r)
	for i in 120:
		var w := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.02
		cm.bottom_radius = 0.08
		cm.height = rng.randf_range(1.0, 5.0)
		cm.radial_segments = 4
		w.mesh = cm
		w.material_override = weed
		w.position = Vector3(rng.randf_range(-80, 80), -FLOOR + 0.5 * cm.height, rng.randf_range(-120, 40))
		w.rotation = Vector3(rng.randf_range(-0.2, 0.2), 0, rng.randf_range(-0.2, 0.2))
		add_child(w)
