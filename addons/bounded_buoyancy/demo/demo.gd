extends Node3D
## Side-by-side demo: the usual engine buoyancy (left, orange) against Bounded Buoyancy
## (right, teal). Physics values match the paper's benchmarks.
##   RELEASE: four light spheres (radius 2 cm) released from rest 0.5 m under water;
##            each ball's first-frame acceleration is shown under it.
##   FLOAT:   a light float (radius 10 cm, 5% of water's density) released with its lowest point at the surface
##            from touching the surface; the bobbing still left after each second is shown.
##   TILT:    a raft, a tall block and a boat dropped into the water: buoyancy acts at the centre of the
##            immersed volume, so the raft settles flat, the block tips onto its side and the boat rights itself.
##   WAVES:   a BoundedBuoyancyWater node with waves; a boat, a raft, a crate, a log and a ball ride the swell.
##   MANY:    300 crates, barrels, balls and buoys dropped onto waves, with the time the buoyancy takes
##            each frame (N switches between the native kernel and GDScript).
##   RIVER:   a river flowing at 1.5 m/s, slower along its banks; crates, logs, balls and boats are dropped in
##            upstream and carried down.
##   WIND:    gusty wind over a lake: boats with sails run before it and heel, balloons drift, crates and a
##            log barely move. Arrow keys turn the wind and make it stronger or weaker.
##   SKY:     the same law in air. Two foil helium balloons rise and float where the air (thinning upward,
##            halving every 10 m here) is as light as they are, and a hot-air balloon lifts off when heated.
##   OCEAN:   another water system's waves: an ocean drawn by its own shader (ocean_example.gd), with a
##            BoundedBuoyancyWater taking its surface from it. The same bodies as WAVES ride it.
##   BOATS:   (demo_boats.gd) drive a motorboat with a keel, a rudder and a propeller, while a dinghy with a
##            self-trimming sail beats up into the wind in tacks and runs back.
## Keys: Space = run again, T = tip them over (TILT), W = calm or rough (WAVES, OCEAN), B = burner, G = gust (SKY),
## N = native kernel on or off (MANY), Tab = next scene.

const BB := preload("res://addons/bounded_buoyancy/bounded_buoyancy_body.gd")
enum Scene { RELEASE, FLOAT, TILT, WAVES, SKY, MANY, RIVER, WIND, OCEAN }

@export var scene: Scene = Scene.RELEASE

const G := 9.80665
const RELEASE_CASES := [
	["air bubble", 0.001225],
	["foam ball", 0.03],
	["table-tennis ball", 0.0805721899],
	["cork", 0.25],
]
const ORANGE := Color(0.93, 0.5, 0.15)
const TEAL := Color(0.16, 0.62, 0.56)
const INK := Color(0.12, 0.14, 0.18)
const SCENE_FILES := ["res://addons/bounded_buoyancy/demo/demo.tscn", "res://addons/bounded_buoyancy/demo/demo_float.tscn", "res://addons/bounded_buoyancy/demo/demo_tilt.tscn", "res://addons/bounded_buoyancy/demo/demo_waves.tscn", "res://addons/bounded_buoyancy/demo/demo_sky.tscn", "res://addons/bounded_buoyancy/demo/demo_many.tscn", "res://addons/bounded_buoyancy/demo/demo_river.tscn", "res://addons/bounded_buoyancy/demo/demo_wind.tscn", "res://addons/bounded_buoyancy/demo/demo_ocean.tscn", "res://addons/bounded_buoyancy/demo/demo_boats.tscn", "res://addons/bounded_buoyancy/demo/demo_flood.tscn", "res://addons/bounded_buoyancy/demo/demo_cannons.tscn", "res://addons/bounded_buoyancy/demo/demo_2d.tscn"]
const BW := preload("res://addons/bounded_buoyancy/bounded_buoyancy_water.gd")
const OCEAN_EXAMPLE := preload("res://addons/bounded_buoyancy/demo/ocean_example.gd")

var _rows: Array = []        # [name, usual body, bounded body, usual label, bounded label]
var _first: Dictionary = {}  # body -> first-frame acceleration in g
var _swing: Dictionary = {}  # body -> [largest distance from rest this second, last full second]
var _t := 0.0
var _released := false
var _tilt_rows: Array = []   # [body, label, caption]
var _sea: Node3D
var _ocean: Node3D            # OCEAN scene: the other water system (ocean_example.gd)

# SKY scene. For the foil balloons the air halves in density every AIR_HALF metres (real air halves
# every 6 km, too slowly to see in a scene this size); a foil balloon keeps its volume, so it floats
# where the air is as dense as it is. The hot-air balloon is in the real air (the standard atmosphere,
# on a day as warm as the D key sets): its density is its envelope, basket and load (STRUCTURE, per
# cubic metre of balloon) plus the air inside, which is the air outside made less dense by heating,
# at the same pressure: outside density x outside temperature / inside temperature. Nothing stops it
# rising in real air, so its pilot holds it at HOLD, burning as needed; on a hot day the air inside
# must be hotter.
const AIR_HALF := 10.0
const HELIUM := 0.6          # foil balloon with its ribbon, kg/m³
const STRUCTURE := 0.2       # kg per m³ of balloon, about right for a real hot-air balloon
const T_AIR := 293.0         # 20 °C
const HOLD := 6.0            # m, the height the pilot holds the hot-air balloon at
const DAYS := [[0.0, "a cold morning"], [15.0, "a mild day"], [30.0, "a hot afternoon"]]
const T_BURNER := 393.0      # 120 °C, near the working limit of a real envelope
const FRONT := (18.0 - 3.05) / 18.0   # labels on the front of the ground, seen from the camera at z = 18
var _hot: RigidBody3D
var _hot_label: Label3D
var _flame: Node3D
var _burner := true
var _pilot := true            # the pilot holds the height; off, the burner is off and it comes down
var _day := 1
var _sky_air: Node3D          # the real air the hot-air balloon is in
var _temp := T_AIR
var _burner_off_at := -1.0   # for recordings: --burner-off=<seconds after release>

# MANY scene: the time from the start of each physics frame to the end of the bodies' updates.
const MANY_COUNT := 300

# RIVER scene: bodies dropped in upstream every so often, removed once they have gone downstream.
const RIVER_SPEED := 1.5
var _river_bodies: Array = []
var _river_clock := 0.0
var _river_rng := RandomNumberGenerator.new()

# WIND scene.
const BWIND := preload("res://addons/bounded_buoyancy/bounded_buoyancy_wind.gd")
var _wind: Node3D
var _wind_label: Label
var _wind_bodies: Array = []
var _sails: Array = []        # [boat, sail mesh]: the sail is turned to face the wind the boat feels
var _frame_start := 0
var _cost_sum := 0.0
var _cost_n := 0
var _cost_label: Label


func _ready() -> void:
	_build_world()
	_reset()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_reset()
		elif event.keycode == KEY_TAB:
			get_tree().change_scene_to_file(SCENE_FILES[(scene + 1) % SCENE_FILES.size()])   # then BOATS (demo_boats.gd), FLOOD (demo_flood.gd), CANNONS (demo_cannons.gd), then 2D
		elif event.keycode == KEY_W and scene == Scene.WAVES:
			_sea.wave_height = 0.12 if _sea.wave_height < 0.1 else 0.06
		elif event.keycode == KEY_W and scene == Scene.OCEAN:
			_ocean.roughness = 2.0 if _ocean.roughness < 1.5 else 1.0
			_sea.surface_max_wave = _ocean.max_wave()
		elif event.keycode == KEY_N and scene == Scene.MANY:
			BB.use_native = not BB.use_native
			_cost_sum = 0.0
			_cost_n = 0
		elif scene == Scene.WIND and event.keycode in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]:
			if event.keycode == KEY_LEFT:
				_wind.rotate_y(deg_to_rad(15.0))
			elif event.keycode == KEY_RIGHT:
				_wind.rotate_y(deg_to_rad(-15.0))
			elif event.keycode == KEY_UP:
				_wind.velocity.x = minf(_wind.velocity.x + 1.0, 12.0)
			else:
				_wind.velocity.x = maxf(_wind.velocity.x - 1.0, 0.0)
		elif event.keycode == KEY_B and scene == Scene.SKY:
			_pilot = not _pilot
		elif event.keycode == KEY_D and scene == Scene.SKY:
			_day = (_day + 1) % DAYS.size()
			_sky_air.temperature = DAYS[_day][0]
		elif event.keycode == KEY_G and scene == Scene.SKY:
			# The same push for both balloons: the one carrying its air with it moves off more slowly.
			for row in _rows:
				row[1].apply_central_impulse(Vector3(1.0, 0, 0))
				row[2].apply_central_impulse(Vector3(1.0, 0, 0))
		elif event.keycode == KEY_T and scene == Scene.TILT:
			for row in _tilt_rows:
				var b: RigidBody3D = row[0]
				b.apply_torque_impulse(Vector3(0, 0, 9.0 * b.inertia.z))


func _physics_process(dt: float) -> void:
	_t += dt
	if not _released:
		if _t >= 1.0:
			_released = true
			for row in _rows:
				row[1].freeze = false
				row[2].freeze = false
			for row in _tilt_rows:
				row[0].freeze = false
			if _hot:
				_hot.freeze = false
		return
	if scene == Scene.SKY:
		_sky_step(dt)
	if scene == Scene.MANY:
		_many_step()
		return
	if scene == Scene.RIVER:
		_river_step(dt)
		return
	if scene == Scene.WIND:
		_wind_step()
		return
	if scene == Scene.TILT or scene == Scene.WAVES or scene == Scene.OCEAN:
		_update_labels()
		return
	for row in _rows:
		for k in [1, 2]:
			var b: RigidBody3D = row[k]
			if not _first.has(b):
				_first[b] = b.linear_velocity.y / dt / G
			if scene == Scene.SKY:
				continue
			if scene == Scene.FLOAT:
				var d: float = abs(b.global_position.y - _float_level())
				var s: Array = _swing.get(b, [0.0, -1.0])
				s[0] = max(s[0], d)
				if fmod(_t - 1.0, 1.0) < dt:
					s[1] = s[0]
					s[0] = 0.0
				_swing[b] = s
	_update_labels()


func _reset() -> void:
	for row in _rows:
		for k in range(1, 5):
			row[k].queue_free()
	_rows.clear()
	for row in _tilt_rows:
		row[0].queue_free()
		if row[1]:
			row[1].queue_free()
	_tilt_rows.clear()
	_first.clear()
	_swing.clear()
	_t = 0.0
	_released = false
	if _hot:
		_hot.queue_free()
		_hot_label.queue_free()
		_hot = null
	for b in _river_bodies:
		b.queue_free()
	_river_bodies.clear()
	for b in _wind_bodies:
		b.queue_free()
	_wind_bodies.clear()
	_sails.clear()
	if scene == Scene.WIND:
		for i in 3:
			_wind_bodies.append(_sail_boat(Vector3(-7.5 + 1.5 * i, 0.05, 5.0 - 2.0 * i), 0.3 + 0.25 * i))
		for i in 2:
			_many_body(0, Vector3(-8.5 + 1.2 * i, 0.3, 3.8), Vector3(0, 20 * i, 0))
			_wind_bodies.append(_tilt_rows.pop_back()[0])
		_many_body(1, Vector3(-6.0, 0.3, 3.8), Vector3(0, 0, 90))
		_wind_bodies.append(_tilt_rows.pop_back()[0])
		for i in 3:
			var bl := _balloon(BB.Model.BOUNDED, Vector3(-10.0 + 1.8 * i, 3.5, 2.0 - 1.5 * i))
			bl.air_half_height = 4.0
			_wind_bodies.append(bl)
		for b in _wind_bodies:
			b.collision_layer = 1
			b.collision_mask = 1
	_river_clock = 0.0
	_river_rng.seed = 11
	if scene == Scene.MANY:
		_cost_sum = 0.0
		_cost_n = 0
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		for i in MANY_COUNT:
			var at := Vector3(rng.randf_range(-9.0, 9.0), rng.randf_range(0.6, 3.5), rng.randf_range(-8.0, 6.0))
			_many_body(i % 4, at, Vector3(rng.randf_range(-40, 40), rng.randf_range(0, 360), rng.randf_range(-40, 40)))
	elif scene == Scene.SKY:
		_burner = true
		_pilot = true
		_temp = DAYS[_day][0] + 273.15
		var u := _balloon(BB.Model.USUAL, Vector3(-6.8, 1.8, 0))
		var b := _balloon(BB.Model.BOUNDED, Vector3(-2.2, 1.8, 0))
		_rows.append(["foil helium balloon", u, b, _label3d("", Vector3(-6.8 * FRONT, -0.85, 3.05), INK, 28),
			_label3d("", Vector3(-2.2 * FRONT, -0.85, 3.05), INK, 28)])
		_hot_air_balloon(Vector3(4.8, 2.66, 0))
	elif scene == Scene.RELEASE:
		var x := 0.09
		for c in RELEASE_CASES:
			var u := _ball(c[1], BB.Model.USUAL, Vector3(-0.66 + x, -0.5, 0), 0.02)
			var b := _ball(c[1], BB.Model.BOUNDED, Vector3(0.12 + x, -0.5, 0), 0.02)
			_rows.append([c[0], u, b, _label3d(c[0], Vector3(-0.66 + x, -0.575, 0), INK, 17),
				_label3d(c[0], Vector3(0.12 + x, -0.575, 0), INK, 17)])
			x += 0.15
	elif scene == Scene.TILT:
		_tilt_body("Raft", _box_shape(Vector3(0.36, 0.09, 0.24)), 400.0, Vector3(-0.62, 0.16, 0), 30.0, Vector3.ZERO, false)
		_tilt_body("Tall block", _box_shape(Vector3(0.07, 0.3, 0.07)), 600.0, Vector3(0.0, 0.2, 0), 3.0, Vector3.ZERO, false)
		var hull := ConvexPolygonShape3D.new()
		hull.points = PackedVector3Array([Vector3(-0.2, 0.05, -0.2), Vector3(0.2, 0.05, -0.2), Vector3(-0.1, -0.05, -0.2), Vector3(0.1, -0.05, -0.2),
			Vector3(-0.2, 0.05, 0.2), Vector3(0.2, 0.05, 0.2), Vector3(-0.1, -0.05, 0.2), Vector3(0.1, -0.05, 0.2)])
		_tilt_body("Boat, low centre of mass", hull, 300.0, Vector3(0.62, 0.16, 0), 70.0, Vector3(0, -0.04, 0), true)
	elif scene == Scene.WAVES or scene == Scene.OCEAN:
		var hull := ConvexPolygonShape3D.new()
		hull.points = PackedVector3Array([Vector3(-0.2, 0.05, -0.32), Vector3(0.2, 0.05, -0.32), Vector3(-0.1, -0.05, -0.28), Vector3(0.1, -0.05, -0.28),
			Vector3(-0.2, 0.05, 0.32), Vector3(0.2, 0.05, 0.32), Vector3(-0.1, -0.05, 0.28), Vector3(0.1, -0.05, 0.28), Vector3(0, 0.05, 0.48)])
		_tilt_body("", hull, 300.0, Vector3(-0.2, 0.25, 0.2), 0.0, Vector3(0, -0.04, 0), true)
		_tilt_body("", _box_shape(Vector3(0.5, 0.08, 0.35)), 450.0, Vector3(-1.2, 0.3, -0.4), 15.0, Vector3.ZERO, false)
		_tilt_body("", _box_shape(Vector3(0.22, 0.22, 0.22)), 600.0, Vector3(0.9, 0.4, -0.3), 25.0, Vector3.ZERO, false)
		var log_shape := CylinderShape3D.new()
		log_shape.radius = 0.07
		log_shape.height = 0.7
		_tilt_body("", log_shape, 650.0, Vector3(0.6, 0.35, 0.7), 80.0, Vector3.ZERO, false)
		var ball := SphereShape3D.new()
		ball.radius = 0.09
		_tilt_body("", ball, 120.0, Vector3(1.4, 0.5, 0.4), 0.0, Vector3.ZERO, false)
	elif scene == Scene.FLOAT:
		var u := _ball(0.05, BB.Model.USUAL, Vector3(-0.3, 0.1, 0), 0.1)
		var b := _ball(0.05, BB.Model.BOUNDED, Vector3(0.3, 0.1, 0), 0.1)
		_rows.append(["float", u, b, _label3d("", Vector3(-0.3, -0.3, 0), INK, 20),
			_label3d("", Vector3(0.3, -0.3, 0), INK, 20)])
	_update_labels()


func _update_labels() -> void:
	for row in _tilt_rows:
		if row[1] == null:
			continue
		var b: RigidBody3D = row[0]
		var tilt := rad_to_deg(acos(clampf(b.global_transform.basis.y.normalized().dot(Vector3.UP), -1.0, 1.0)))
		row[1].text = "%s\ntilt %d°" % [row[2], roundi(tilt)]
	for row in _rows:
		for k in [1, 2]:
			var b: RigidBody3D = row[k]
			var l: Label3D = row[k + 2]
			if scene == Scene.SKY:
				l.text = row[0] if not _first.has(b) else "first frame %.2f g up" % _first[b]
			elif scene == Scene.RELEASE:
				l.text = row[0] if not _first.has(b) else "%s\n%s g" % [row[0], ("%.1f" if _first[b] >= 10.0 else "%.2f") % _first[b]]
			else:
				var s: Array = _swing.get(b, [0.0, -1.0])
				l.text = "dropped at 1 s" if s[1] < 0.0 else "still bobbing\n±%.1f mm" % (1000.0 * s[1])


func _ball(r: float, model: int, at: Vector3, radius: float) -> RigidBody3D:
	var b := BB.new()
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = radius
	cs.shape = sh
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ORANGE if model == BB.Model.USUAL else TEAL
	mat.roughness = 0.4
	mesh.material = mat
	mi.mesh = mesh
	b.add_child(mi)
	b.density = r * 1000.0
	b.model = model
	b.air_density = 0.0   # the paper's benchmarks leave out air
	b.collision_layer = 0
	b.collision_mask = 0
	b.freeze = true
	b.position = at
	add_child(b)
	return b


## A foil helium balloon, 1 m across, with a ribbon (for show) hanging below it.
func _balloon(model: int, at: Vector3) -> RigidBody3D:
	var b := BB.new()
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.5
	cs.shape = sh
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ORANGE if model == BB.Model.USUAL else TEAL
	mat.metallic = 0.35
	mat.roughness = 0.25
	mesh.material = mat
	mi.mesh = mesh
	b.add_child(mi)
	var ribbon := MeshInstance3D.new()
	var rm := CylinderMesh.new()
	rm.top_radius = 0.012
	rm.bottom_radius = 0.012
	rm.height = 1.2
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = INK.lightened(0.3)
	rm.material = rmat
	ribbon.mesh = rm
	ribbon.position = Vector3(0, -1.1, 0)
	b.add_child(ribbon)
	b.density = HELIUM
	b.model = model
	b.air_half_height = AIR_HALF
	b.freeze = true
	b.position = at
	add_child(b)
	return b


## A hot-air balloon: an envelope 3.2 m across and a basket, as one body with its centre of mass low.
func _hot_air_balloon(at: Vector3) -> void:
	var b := BB.new()
	var envelope := CollisionShape3D.new()
	var es := SphereShape3D.new()
	es.radius = 1.6
	envelope.shape = es
	b.add_child(envelope)
	var basket := CollisionShape3D.new()
	basket.shape = _box_shape(Vector3(0.9, 0.7, 0.9))
	basket.position = Vector3(0, -2.31, 0)
	b.add_child(basket)
	var em := MeshInstance3D.new()
	var esm := SphereMesh.new()
	esm.radius = 1.6
	esm.height = 3.2
	var emat := StandardMaterial3D.new()
	emat.albedo_color = Color(0.86, 0.33, 0.26)
	emat.roughness = 0.6
	esm.material = emat
	em.mesh = esm
	b.add_child(em)
	var bm := MeshInstance3D.new()
	var bbox := BoxMesh.new()
	bbox.size = Vector3(0.9, 0.7, 0.9)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.55, 0.38, 0.22)
	bbox.material = bmat
	bm.mesh = bbox
	bm.position = basket.position
	b.add_child(bm)
	for corner in [Vector2(-0.4, -0.4), Vector2(0.4, -0.4), Vector2(-0.4, 0.4), Vector2(0.4, 0.4)]:
		var top := Vector3(corner.x * 1.6, -1.25, corner.y * 1.6)
		var bottom := Vector3(corner.x, -1.96, corner.y)
		var rope := MeshInstance3D.new()
		var rmesh := CylinderMesh.new()
		rmesh.top_radius = 0.015
		rmesh.bottom_radius = 0.015
		rmesh.height = top.distance_to(bottom)
		var rmat := StandardMaterial3D.new()
		rmat.albedo_color = INK.lightened(0.3)
		rmesh.material = rmat
		rope.mesh = rmesh
		rope.position = 0.5 * (top + bottom)
		rope.basis = Basis(Quaternion(Vector3.UP, (top - bottom).normalized()))
		b.add_child(rope)
	var fm := MeshInstance3D.new()
	var flame := CylinderMesh.new()
	flame.top_radius = 0.0
	flame.bottom_radius = 0.13
	flame.height = 0.45
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(1.0, 0.62, 0.12)
	fmat.emission_enabled = true
	fmat.emission = Color(1.0, 0.5, 0.1)
	flame.material = fmat
	fm.mesh = flame
	fm.position = Vector3(0, -1.65, 0)
	b.add_child(fm)
	_flame = fm
	b.fixed_air = false   # the real air
	b.density = STRUCTURE + BoundedBuoyancyAir.standard_density(at.y, DAYS[_day][0])   # cold: denser than the air around it
	b.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	b.center_of_mass = Vector3(0, -1.4, 0)
	b.freeze = true
	b.position = at
	add_child(b)
	_hot = b
	_hot_label = _label3d("burner off, air inside 20 °C", Vector3(at.x * FRONT, -0.85, 3.05), INK, 28)


## Heat or cool the air in the hot-air balloon, and set the balloon's density from it and the real air
## around it. The pilot burns while it is low or sinking toward its height, and lets it cool above.
func _sky_step(dt: float) -> void:
	if _burner_off_at >= 0.0 and _pilot and _t - 1.0 >= _burner_off_at:
		_pilot = false
		_burner_off_at = -1.0
	var p := _hot.global_position
	var t_out: float = _sky_air.temperature_at(p) + 273.15
	var outside: float = _sky_air.density_at(p)
	# The pilot aims for the air inside that just floats it (as dense on the whole as the air outside),
	# a little hotter while it is low or sinking, a little cooler while high or rising.
	var floats := t_out * outside / maxf(outside - STRUCTURE, 0.01)
	var aim := floats + 2.0 * (HOLD - p.y) - 6.0 * _hot.linear_velocity.y
	_burner = _pilot and _temp < aim
	if _burner:
		_temp += (T_BURNER - _temp) * dt / 4.0
	# The envelope loses heat to the air outside.
	_temp += (t_out - _temp) * dt / 25.0
	_hot.density = STRUCTURE + outside * t_out / _temp
	_flame.visible = _burner
	_hot_label.text = "%s: outside %d °C, inside %d °C\nburner %s%s" % [DAYS[_day][1], roundi(t_out - 273.15), roundi(_temp - 273.15),
		"ON" if _burner else "off", "" if _pilot else " (coming down: B)"]


func _tilt_body(caption: String, shape: Shape3D, dens: float, at: Vector3, roll_deg: float, com: Vector3, custom_com: bool) -> void:
	var b := BB.new()
	var cs := CollisionShape3D.new()
	cs.shape = shape
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = TEAL
	mat.roughness = 0.5
	if shape is BoxShape3D:
		var bm := BoxMesh.new()
		bm.size = shape.size
		bm.material = mat
		mi.mesh = bm
	elif shape is CylinderShape3D:
		var cyl := CylinderMesh.new()
		cyl.top_radius = shape.radius
		cyl.bottom_radius = shape.radius
		cyl.height = shape.height
		mat.albedo_color = Color(0.62, 0.45, 0.28)
		cyl.material = mat
		mi.mesh = cyl
	elif shape is SphereShape3D:
		var sm := SphereMesh.new()
		sm.radius = shape.radius
		sm.height = 2.0 * shape.radius
		mat.albedo_color = ORANGE
		sm.material = mat
		mi.mesh = sm
	else:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var faces: PackedVector3Array = shape.get_debug_mesh().get_faces()
		for i in range(0, faces.size(), 3):
			st.add_vertex(faces[i])
			st.add_vertex(faces[i + 1])
			st.add_vertex(faces[i + 2])
		st.generate_normals()
		st.set_material(mat)
		mi.mesh = st.commit()
		# A mast, for show only: buoyancy comes from the hull shape.
		var mast := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.006
		cm.bottom_radius = 0.006
		cm.height = 0.22
		var mm := StandardMaterial3D.new()
		mm.albedo_color = INK.lightened(0.25)
		cm.material = mm
		mast.mesh = cm
		mast.position = Vector3(0, 0.16, 0)
		b.add_child(mast)
	b.add_child(mi)
	b.density = dens
	if custom_com:
		b.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		b.center_of_mass = com
	b.collision_layer = 0
	b.collision_mask = 0
	b.freeze = true
	b.position = at
	b.rotation_degrees = Vector3(0, 0, roll_deg)
	add_child(b)
	var label: Label3D = null if caption.is_empty() else _label3d(caption, Vector3(at.x, -0.38, 0.55), INK, 20)
	_tilt_rows.append([b, label, caption])


func _box_shape(size: Vector3) -> BoxShape3D:
	var s := BoxShape3D.new()
	s.size = size
	return s


func _build_world() -> void:
	if scene == Scene.WAVES or scene == Scene.OCEAN:
		_build_sea()
		return
	if scene == Scene.SKY:
		_build_sky()
		return
	if scene == Scene.MANY:
		_build_many()
		return
	if scene == Scene.RIVER:
		_build_river()
		return
	if scene == Scene.WIND:
		_build_wind()
		return
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.94, 0.95, 0.97)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	add_child(sun)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = [1.0, 0.9, 1.15][scene]
	cam.position = Vector3(0, [-0.24, -0.02, -0.08][scene], 2.0)
	add_child(cam)
	# Water: a translucent block whose top face is the surface at y = 0.
	var water := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(4.0, 1.5, 0.3)
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.35, 0.62, 0.9, 0.32)
	wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box.material = wm
	water.mesh = box
	water.position = Vector3(0, -0.75, -0.2)
	if scene == Scene.TILT:
		# Deep enough front to back that the immersed part of each body shows through the water.
		box.size = Vector3(4.0, 1.5, 1.0)
		water.position = Vector3(0, -0.75, 0.0)
	add_child(water)
	var line := MeshInstance3D.new()
	var lb := BoxMesh.new()
	lb.size = Vector3(4.0, 0.004, 0.01)
	var lm := StandardMaterial3D.new()
	lm.albedo_color = Color(0.15, 0.4, 0.7)
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lb.material = lm
	line.mesh = lb
	add_child(line)
	if scene != Scene.TILT:
		var xt := 0.36 if scene == Scene.RELEASE else 0.3
		var yt := 0.17 if scene == Scene.RELEASE else 0.3
		_label3d("Usual engine buoyancy", Vector3(-xt, yt, 0), ORANGE.darkened(0.2), 30)
		_label3d("Bounded Buoyancy", Vector3(xt, yt, 0), TEAL.darkened(0.2), 30)
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = ["Released from rest 0.5 m under water: first-frame acceleration under each ball",
		"A light float (10 cm, 5% of water's density) released at the water surface",
		"Buoyancy acts at the centre of the immersed volume: shapes tilt, tip and right themselves"][scene]
	title.position = Vector2(24, 14)
	title.add_theme_color_override("font_color", INK)
	title.add_theme_font_size_override("font_size", 20)
	layer.add_child(title)
	var keys := Label.new()
	keys.text = "Space: run again     T: tip them over     Tab: next scene" if scene == Scene.TILT else "Space: run again     Tab: next scene"
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 24
	keys.offset_top = -38
	keys.add_theme_color_override("font_color", INK.lightened(0.35))
	keys.add_theme_font_size_override("font_size", 16)
	layer.add_child(keys)


func _build_sea() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.86, 0.92, 0.97)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.55
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 50.0
	cam.position = Vector3(0, 1.35, 3.3)
	cam.rotation_degrees = Vector3(-21, 0, 0)
	add_child(cam)
	_sea = BW.new()
	_sea.size = Vector3(24.0, 2.0, 24.0)
	if scene == Scene.OCEAN:
		# Another water system draws the sea; the water node takes its surface from it.
		_ocean = OCEAN_EXAMPLE.new()
		add_child(_ocean)
		_sea.surface_source = _ocean
		_sea.surface_method = &"get_height"
		_sea.surface_acceleration_method = &"get_vertical_acceleration"
		_sea.surface_max_wave = _ocean.max_wave()
	else:
		_sea.wave_height = 0.06
		_sea.wave_length = 2.4
		_sea.wave_direction = 20.0
	add_child(_sea)
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "A water node with waves: each body rides and rocks with the surface it sits on" if scene == Scene.WAVES \
		else "Another water system's waves: the sea is drawn by its own shader, and Bounded Buoyancy does the physics"
	title.position = Vector2(24, 14)
	title.add_theme_color_override("font_color", INK)
	title.add_theme_font_size_override("font_size", 20)
	layer.add_child(title)
	var keys := Label.new()
	keys.text = "Space: run again     W: calm or rough     Tab: next scene"
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 24
	keys.offset_top = -38
	keys.add_theme_color_override("font_color", INK.lightened(0.35))
	keys.add_theme_font_size_override("font_size", 16)
	layer.add_child(keys)


func _build_sky() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--burner-off="):
			_burner_off_at = float(arg.get_slice("=", 1))
	# The real air, sea level at the ground, for the hot-air balloon.
	_sky_air = BoundedBuoyancyAir.new()
	_sky_air.temperature = DAYS[_day][0]
	_sky_air.position = Vector3(0, -1.5, 0)
	add_child(_sky_air)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.80, 0.89, 0.97)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 50.0
	cam.position = Vector3(0, 5.0, 18.0)
	add_child(cam)
	# Ground: a solid floor at y = 0 for the balloons to stand on.
	var ground := StaticBody3D.new()
	var gs := CollisionShape3D.new()
	gs.shape = _box_shape(Vector3(60, 3, 12))
	ground.add_child(gs)
	var gm := MeshInstance3D.new()
	var gbox := BoxMesh.new()
	gbox.size = Vector3(60, 3, 12)
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.56, 0.68, 0.5)
	gbox.material = gmat
	gm.mesh = gbox
	ground.add_child(gm)
	ground.position = Vector3(0, -1.5, -3)
	add_child(ground)
	# The level where the air is as light as the foil balloons.
	var line := MeshInstance3D.new()
	var lb := BoxMesh.new()
	lb.size = Vector3(9.0, 0.03, 0.03)
	var lm := StandardMaterial3D.new()
	lm.albedo_color = Color(0.15, 0.4, 0.7)
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lb.material = lm
	line.mesh = lb
	line.position = Vector3(-4.5, AIR_HALF * log(1.2 / HELIUM) / log(2.0), 0)
	add_child(line)
	var level := _label3d("air as light\nas the balloons", line.position + Vector3(-4.7, 0, 0), Color(0.15, 0.4, 0.7), 28)
	level.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label3d("Usual engine buoyancy", Vector3(-6.8 * FRONT, -0.35, 3.05), ORANGE.darkened(0.2), 30)
	_label3d("Bounded Buoyancy", Vector3(-2.2 * FRONT, -0.35, 3.05), TEAL.darkened(0.2), 30)
	_label3d("Hot-air balloon", Vector3(4.8 * FRONT, -0.35, 3.05), Color(0.7, 0.25, 0.2), 30)
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "The same law in air: helium balloons float where the air is as dense as they are (their air halves every 10 m; real air, every 6 km)"
	title.position = Vector2(24, 14)
	title.add_theme_color_override("font_color", INK)
	title.add_theme_font_size_override("font_size", 20)
	layer.add_child(title)
	var keys := Label.new()
	keys.text = "Space: run again     B: pilot holds the hot-air balloon up, or lets it down     D: colder or warmer day     G: gust     Tab: next scene"
	keys.position = Vector2(24, 44)
	keys.add_theme_color_override("font_color", INK.lightened(0.35))
	keys.add_theme_font_size_override("font_size", 16)
	layer.add_child(keys)


## One of four kinds of body for the MANY scene: a crate, a barrel, a ball or a buoy.
func _many_body(kind: int, at: Vector3, rot: Vector3) -> void:
	var b := BB.new()
	var cs := CollisionShape3D.new()
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.6
	match kind:
		0:
			cs.shape = _box_shape(Vector3(0.6, 0.4, 0.4))
			var m := BoxMesh.new()
			m.size = Vector3(0.6, 0.4, 0.4)
			mi.mesh = m
			mat.albedo_color = Color(0.62, 0.45, 0.28)
			b.density = 500.0
		1:
			var c := CylinderShape3D.new()
			c.radius = 0.25
			c.height = 0.7
			cs.shape = c
			var m := CylinderMesh.new()
			m.top_radius = 0.25
			m.bottom_radius = 0.25
			m.height = 0.7
			mi.mesh = m
			mat.albedo_color = Color(0.2, 0.42, 0.62)
			b.density = 600.0
			b.added_mass_coefficient = 0.8
		2:
			var sp := SphereShape3D.new()
			sp.radius = 0.25
			cs.shape = sp
			var m := SphereMesh.new()
			m.radius = 0.25
			m.height = 0.5
			mi.mesh = m
			mat.albedo_color = ORANGE
			b.density = 200.0
		_:
			var cp := CapsuleShape3D.new()
			cp.radius = 0.15
			cp.height = 0.8
			cs.shape = cp
			var m := CapsuleMesh.new()
			m.radius = 0.15
			m.height = 0.8
			mi.mesh = m
			mat.albedo_color = Color(0.85, 0.25, 0.22)
			b.density = 400.0
			b.added_mass_coefficient = 0.9
	mi.mesh.material = mat
	b.add_child(cs)
	b.add_child(mi)
	b.freeze = true
	b.position = at
	b.rotation_degrees = rot
	add_child(b)
	_tilt_rows.append([b, null, ""])


## Drop a body into the river every 0.9 s, and take away those that have gone past the end of the view.
func _river_step(dt: float) -> void:
	_river_clock -= dt
	if _river_clock <= 0.0:
		_river_clock = 0.9
		var kind := _river_rng.randi() % 5
		var at := Vector3(_river_rng.randf_range(-9.0, -6.0), _river_rng.randf_range(1.2, 2.2), _river_rng.randf_range(-2.4, 2.4))
		var rot := Vector3(_river_rng.randf_range(-30, 30), _river_rng.randf_range(0, 360), _river_rng.randf_range(-30, 30))
		var b: RigidBody3D
		if kind == 4:
			b = _river_boat(at)
		else:
			_many_body(kind, at, rot)
			b = _tilt_rows.pop_back()[0]
		b.freeze = false
		b.collision_layer = 1
		b.collision_mask = 1
		_river_bodies.append(b)
	for b in _river_bodies.duplicate():
		if b.global_position.x > 13.0 or b.global_position.y < -3.0 or absf(b.global_position.z) > 3.3:
			_river_bodies.erase(b)
			b.queue_free()


## A small boat for the river: a convex hull with a low centre of mass and a mast.
func _river_boat(at: Vector3) -> RigidBody3D:
	var hull := ConvexPolygonShape3D.new()
	hull.points = PackedVector3Array([Vector3(-0.45, 0.12, -0.25), Vector3(0.45, 0.12, -0.25), Vector3(-0.35, -0.12, -0.15), Vector3(0.35, -0.12, -0.15),
		Vector3(-0.45, 0.12, 0.25), Vector3(0.45, 0.12, 0.25), Vector3(-0.35, -0.12, 0.15), Vector3(0.35, -0.12, 0.15), Vector3(0.75, 0.12, 0.0)])
	_tilt_body("", hull, 300.0, at, 0.0, Vector3(0, -0.08, 0), true)
	var b: RigidBody3D = _tilt_rows.pop_back()[0]
	return b


## Release the bodies at 1 s, keep them in view by carrying any that drift too far back to the
## other side, and show the wind.
func _wind_step() -> void:
	for b in _wind_bodies:
		if b.freeze:
			b.freeze = false
		var p: Vector3 = b.global_position
		if absf(p.x) > 13.0 or absf(p.z - 1.0) > 9.0:
			# Back to the upwind side, keeping its height and a little of its sideways place.
			var dir := _wind.global_transform.basis * Vector3.RIGHT
			var side := Vector3(-dir.z, 0.0, dir.x)
			var offset := side.dot(p) * 0.5
			b.global_position = Vector3(0, p.y, 1.0) - dir * 9.0 + side * clampf(offset, -3.0, 3.0)
	for pair in _sails:
		var boat: RigidBody3D = pair[0]
		var feel: Vector3 = boat.wind_here - boat.linear_velocity
		var local := boat.global_transform.basis.transposed() * Vector3(feel.x, 0.0, feel.z)
		if local.length_squared() > 1e-6:
			pair[1].rotation = Vector3(0.0, atan2(-local.z, local.x), 0.0)
	var w: Vector3 = _wind.velocity_at(Vector3.ZERO)
	_wind_label.text = "Wind now %.1f m/s (mean %.0f m/s), blowing towards %s" % [w.length(), _wind.velocity.length(), _compass(w)]


func _compass(w: Vector3) -> String:
	var names := ["the right", "the back right", "the back", "the back left", "the left", "the front left", "the front", "the front right"]
	var a := fposmod(atan2(-w.z, w.x), TAU)
	return names[int(round(a / (TAU / 8.0))) % 8]


## A small sailing boat: a ballasted hull, a mast and a sail the wind pushes on.
func _sail_boat(at: Vector3, sail: float) -> RigidBody3D:
	var hull := ConvexPolygonShape3D.new()
	hull.points = PackedVector3Array([Vector3(-0.45, 0.12, -0.25), Vector3(0.45, 0.12, -0.25), Vector3(-0.35, -0.12, -0.15), Vector3(0.35, -0.12, -0.15),
		Vector3(-0.45, 0.12, 0.25), Vector3(0.45, 0.12, 0.25), Vector3(-0.35, -0.12, 0.15), Vector3(0.35, -0.12, 0.15), Vector3(0.75, 0.12, 0.0)])
	_tilt_body("", hull, 300.0, at, 0.0, Vector3(0, -0.08, 0), true)
	var b: RigidBody3D = _tilt_rows.pop_back()[0]
	b.sail_area = sail
	b.sail_centre = Vector3(0, 0.55, 0)
	var side := sqrt(sail)
	var cloth := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.015, side, side * 0.8)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.97, 0.96, 0.92)
	cm.material = mat
	cloth.mesh = cm
	cloth.position = Vector3(0.0, 0.2 + 0.5 * side, 0)
	b.add_child(cloth)
	_sails.append([b, cloth])
	return b


func _many_step() -> void:
	_cost_sum += float(Time.get_ticks_usec() - _frame_start) / 1000.0
	_cost_n += 1
	if _cost_n >= 30:
		var mode := "native kernel" if BB._kernel and BB.use_native else ("GDScript" if BB._kernel else "GDScript; native kernel not installed")
		_cost_label.text = "%d bodies: buoyancy takes %.1f ms per frame (%s)" % [MANY_COUNT, _cost_sum / _cost_n, mode]
		_cost_sum = 0.0
		_cost_n = 0


func _build_river() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.86, 0.92, 0.97)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.55
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 55.0
	cam.position = Vector3(0, 6.0, 9.5)
	cam.rotation_degrees = Vector3(-34, 0, 0)
	add_child(cam)
	_sea = BW.new()
	_sea.size = Vector3(40.0, 2.5, 6.0)
	_sea.current = Vector3(RIVER_SPEED, 0, 0)
	_sea.current_edge = 1.5
	_sea.wave_height = 0.02
	_sea.wave_length = 1.6
	_sea.surface_color = Color(0.25, 0.5, 0.72, 0.92)
	add_child(_sea)
	# Banks: solid ground either side of the water, and a river bed beneath it.
	for side in [-1.0, 1.0]:
		var bank := StaticBody3D.new()
		var bs := CollisionShape3D.new()
		bs.shape = _box_shape(Vector3(44.0, 3.0, 12.0))
		bank.add_child(bs)
		var bm := MeshInstance3D.new()
		var bbox := BoxMesh.new()
		bbox.size = Vector3(44.0, 3.0, 12.0)
		var bmat := StandardMaterial3D.new()
		bmat.albedo_color = Color(0.5, 0.66, 0.42)
		bbox.material = bmat
		bm.mesh = bbox
		bank.add_child(bm)
		bank.position = Vector3(0, -1.3, side * 9.0)
		add_child(bank)
	var bed := StaticBody3D.new()
	var bds := CollisionShape3D.new()
	bds.shape = _box_shape(Vector3(44.0, 1.0, 6.0))
	bed.add_child(bds)
	var bedm := MeshInstance3D.new()
	var bedbox := BoxMesh.new()
	bedbox.size = Vector3(44.0, 1.0, 6.0)
	var bedmat := StandardMaterial3D.new()
	bedmat.albedo_color = Color(0.42, 0.38, 0.3)
	bedbox.material = bedmat
	bedm.mesh = bedbox
	bed.add_child(bedm)
	bed.position = Vector3(0, -3.0, 0)
	add_child(bed)
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "A river flowing at 1.5 m/s: everything drifts with it, slower near the banks"
	title.position = Vector2(24, 14)
	title.add_theme_color_override("font_color", INK)
	title.add_theme_font_size_override("font_size", 20)
	layer.add_child(title)
	var keys := Label.new()
	keys.text = "Space: run again     Tab: next scene"
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 24
	keys.offset_top = -38
	keys.add_theme_color_override("font_color", INK.lightened(0.35))
	keys.add_theme_font_size_override("font_size", 16)
	layer.add_child(keys)


func _build_wind() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.84, 0.91, 0.97)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.55
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 55.0
	cam.position = Vector3(0, 6.5, 13.0)
	cam.rotation_degrees = Vector3(-22, 0, 0)
	add_child(cam)
	_sea = BW.new()
	_sea.size = Vector3(80.0, 3.0, 80.0)
	_sea.wave_height = 0.04
	_sea.wave_length = 2.0
	add_child(_sea)
	_wind = BWIND.new()
	_wind.velocity = Vector3(4.0, 0, 0)
	_wind.gust_strength = 0.35
	_wind.gust_period = 4.0
	_wind.direction_swing = 12.0
	_wind.rotation_degrees = Vector3(0, 50, 0)   # blowing away from the camera and to the right
	add_child(_wind)
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "Gusty wind: boats with sails run before it and heel, balloons drift, crates and a log barely move"
	title.position = Vector2(24, 14)
	title.add_theme_color_override("font_color", INK)
	title.add_theme_font_size_override("font_size", 20)
	layer.add_child(title)
	_wind_label = Label.new()
	_wind_label.position = Vector2(24, 44)
	_wind_label.add_theme_color_override("font_color", TEAL.darkened(0.25))
	_wind_label.add_theme_font_size_override("font_size", 18)
	layer.add_child(_wind_label)
	var keys := Label.new()
	keys.text = "Space: run again     Left / Right: turn the wind     Up / Down: stronger or weaker     Tab: next scene"
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 24
	keys.offset_top = -38
	keys.add_theme_color_override("font_color", INK.lightened(0.35))
	keys.add_theme_font_size_override("font_size", 16)
	layer.add_child(keys)


func _build_many() -> void:
	# Bodies run their physics update between the tree's physics_frame signal and this node, which goes last.
	process_physics_priority = 1000
	get_tree().physics_frame.connect(func(): _frame_start = Time.get_ticks_usec())
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.86, 0.92, 0.97)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.55
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 55.0
	cam.position = Vector3(0, 8.5, 15.0)
	cam.rotation_degrees = Vector3(-30, 0, 0)
	add_child(cam)
	_sea = BW.new()
	_sea.size = Vector3(80.0, 4.0, 80.0)
	_sea.wave_height = 0.15
	_sea.wave_length = 6.0
	_sea.wave_direction = 25.0
	add_child(_sea)
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "300 crates, barrels, balls and buoys dropped onto waves"
	title.position = Vector2(24, 14)
	title.add_theme_color_override("font_color", INK)
	title.add_theme_font_size_override("font_size", 20)
	layer.add_child(title)
	_cost_label = Label.new()
	_cost_label.text = ""
	_cost_label.position = Vector2(24, 44)
	_cost_label.add_theme_color_override("font_color", TEAL.darkened(0.25))
	_cost_label.add_theme_font_size_override("font_size", 18)
	layer.add_child(_cost_label)
	var keys := Label.new()
	keys.text = "Space: run again     N: native kernel on or off     Tab: next scene"
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 24
	keys.offset_top = -38
	keys.add_theme_color_override("font_color", INK.lightened(0.35))
	keys.add_theme_font_size_override("font_size", 16)
	layer.add_child(keys)


func _label3d(text: String, at: Vector3, color: Color, size := 30) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.position = at
	l.modulate = color
	l.font_size = size
	l.pixel_size = 0.01 if scene == Scene.SKY else 0.0012   # the sky scene is in metres, the others in centimetres
	l.outline_size = 0
	add_child(l)
	return l


## Centre height at which a sphere of radius 0.1 m and density ratio 0.05 floats.
func _float_level() -> float:
	var R := 0.1
	var lo := 0.0
	var hi := 2.0 * R
	for i in 60:
		var h := 0.5 * (lo + hi)
		if h * h * (3.0 * R - h) / (4.0 * R * R * R) < 0.05:
			lo = h
		else:
			hi = h
	return R - 0.5 * (lo + hi)
