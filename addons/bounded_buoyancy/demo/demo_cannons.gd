extends Node3D
## CANNONS: a ship fires broadsides at another at close range. Fired low, round shot skips off the
## water, as gunners' ricochet fire did, splashing at every touch; fired higher it plunges in. Each gun
## kicks the ship back as it fires, so a broadside heels it, and each gun fires as the roll brings it
## to bear. Shot that reaches the other ship, deep with cargo, goes through its 25 cm oak sides
## (BoundedBuoyancyHull) and out of the far side, holing the compartments it passes. Shot skips up
## off the water, so it holes her at and above the waterline, not below it; but water comes in at the
## lowest holes, she settles, more of them go under, and in the end she lists and sinks. The splinters
## the shot knocks out float.
##   Space   fire a broadside (it fires by itself every few seconds too)
##   Up/Down raise or lower the guns
##   S       slow motion
##   F       fast forward, to watch the other ship sink
##   C       change the camera
##   R       run again
##   Tab     next scene
## Everything here is ordinary Bounded Buoyancy bodies, BoundedBuoyancyCannon nodes on the ship, and
## the BoundedBuoyancyCannonball shot they fire. The smoke and the tall splashes are for show, and the
## shot is drawn three times its size so that it can be seen. Both ships are moored fore and aft, so
## that the recoil and the shot do not push them out of range: their cables are a gentle pull,
## sideways only, on bow and stern. Run with -- --slow to start slowed down.

const BB := preload("res://addons/bounded_buoyancy/bounded_buoyancy_body.gd")
const LOOK := preload("res://addons/bounded_buoyancy/demo/demo_look.gd")
const SHIP := preload("res://addons/bounded_buoyancy/demo/demo_ship.gd")
const BW := preload("res://addons/bounded_buoyancy/bounded_buoyancy_water.gd")
const CANNON := preload("res://addons/bounded_buoyancy/bounded_buoyancy_cannon.gd")
const NEXT_SCENE := "res://addons/bounded_buoyancy/demo/demo_fishing.tscn"

const GAP := 40.0           # m between the ships
const GUNS := 5
const COMPARTMENT := preload("res://addons/bounded_buoyancy/bounded_buoyancy_compartment.gd")
const PLANKING := preload("res://addons/bounded_buoyancy/bounded_buoyancy_hull.gd")
const EVERY := 6.0          # s between broadsides fired by themselves
const VIEWS := [[Vector3(-0.36 * GAP, 7.5, 25.0), Vector3(0.6 * GAP, 5.0, -4.0)], [Vector3(1.4 * GAP, 7.0, 32.0), Vector3(0.3 * GAP, 4.0, -4.0)]]
const LADEN := 480.0        # kg/m³: the other ship, deep with cargo
const MOORING := 20.0       # s: how fast the cables bring a ship back to its place

var _ship: RigidBody3D
var _enemy: RigidBody3D
var _guns: Array = []
var _elevation := -2.0
var _t := 0.0
var _next := 0.8
var _ripple: Array = []     # guns still to fire in this broadside, [gun, time]
var _shots: Array = []
var _hits := 0
var _sunk := false
var _cam: Camera3D
var _view := 0
var _status: Label
var _hole_mesh: SphereMesh
var _hole_mat: StandardMaterial3D
var _ticks := Engine.physics_ticks_per_second
var _max_steps := Engine.max_physics_steps_per_frame


func _ready() -> void:
	LOOK.sea_and_sky(self, Vector2(-32.0, -55.0))
	var water := BW.new()
	water.size = Vector3(3000, 400, 3000)
	water.wave_height = 0.04
	water.wave_length = 9.0
	water.wave_direction = 20.0
	water.splash_min_speed = 1.0
	water.surface_color = Color(0.06, 0.22, 0.30, 0.9)
	add_child(water)
	_cam = Camera3D.new()
	_cam.fov = 55.0
	add_child(_cam)
	_place_camera()
	if "--slow" in OS.get_cmdline_user_args():
		_speed(0.25)
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "Broadside: shot skips off the water and holes the other ship; the sea comes in"
	title.position = Vector2(24, 14)
	_outline(title, Color(1, 1, 1))
	title.add_theme_font_size_override("font_size", 20)
	layer.add_child(title)
	_status = Label.new()
	_status.position = Vector2(24, 44)
	_outline(_status, Color(0.93, 0.95, 0.98))
	_status.add_theme_font_size_override("font_size", 16)
	layer.add_child(_status)
	var keys := Label.new()
	keys.text = "Space: fire     Up/Down: raise or lower the guns     S: slow motion     F: fast forward     C: camera     R: run again     Tab: next scene"
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 24
	keys.offset_top = -38
	_outline(keys, Color(0.9, 0.94, 1.0))
	keys.add_theme_font_size_override("font_size", 16)
	layer.add_child(keys)
	_hole_mesh = SphereMesh.new()
	_hole_mesh.radius = 1.0
	_hole_mesh.height = 2.0
	_hole_mesh.radial_segments = 8
	_hole_mesh.rings = 4
	_hole_mat = StandardMaterial3D.new()
	_hole_mat.albedo_color = Color(0.06, 0.05, 0.04)
	_reset()


## White text with a dark outline, readable over sky and sea.
func _outline(label: Label, colour: Color) -> void:
	label.add_theme_color_override("font_color", colour)
	label.add_theme_color_override("font_outline_color", Color(0.05, 0.08, 0.12, 0.85))
	label.add_theme_constant_override("outline_size", 5)


## Put the camera at the view chosen: from astern of the firing ship, or from the other ship's
## quarter, looking back at the broadside.
func _place_camera() -> void:
	var v: Array = VIEWS[_view]
	_cam.look_at_from_position(v[0], v[1], Vector3.UP)


func _exit_tree() -> void:
	_speed(1.0)


## Run the game `scale` times as fast as real time. The engine's physics steps are scaled too, so
## there are `scale` times as many of them a second when faster, to keep them as short as usual.
func _speed(scale: float) -> void:
	Engine.time_scale = scale
	Engine.physics_ticks_per_second = maxi(_ticks, roundi(_ticks * scale))
	Engine.max_physics_steps_per_frame = maxi(_max_steps, roundi(_max_steps * scale))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_broadside()
		elif event.keycode == KEY_UP:
			_elevation = minf(_elevation + 1.0, 10.0)
			_aim()
		elif event.keycode == KEY_DOWN:
			_elevation = maxf(_elevation - 1.0, -3.0)
			_aim()
		elif event.keycode == KEY_S:
			_speed(0.2 if Engine.time_scale > 0.5 else 1.0)
		elif event.keycode == KEY_F:
			_speed(4.0 if Engine.time_scale < 2.0 else 1.0)
		elif event.keycode == KEY_R:
			_reset()
		elif event.keycode == KEY_C:
			_view = (_view + 1) % VIEWS.size()
			_place_camera()
		elif event.keycode == KEY_TAB:
			_speed(1.0)
			get_tree().change_scene_to_file(NEXT_SCENE)


func _physics_process(dt: float) -> void:
	_t += dt
	if _t >= _next and not _sunk:
		_next = _t + EVERY
		_broadside()
	# Each gun fires in turn as the roll brings it to bear, as gun captains fired, or after a few
	# seconds whatever the roll.
	for r in _ripple.duplicate():
		if _t >= r[1] and (_bears(r[0]) or _t >= r[1] + 3.0):
			_ripple.erase(r)
			r[0].fire()
			for later in _ripple:
				later[1] = maxf(later[1], _t + 0.15)
	var skips := 0
	var shown := 0
	for s in _shots.duplicate():
		if not is_instance_valid(s):
			_shots.erase(s)
			continue
		skips = maxi(skips, s.skips)
		shown += 1
	_moor(_ship)
	_moor(_enemy)
	var heel := rad_to_deg(asin(clampf(_ship.global_transform.basis.x.normalized().y, -1.0, 1.0)))
	var heel_enemy := rad_to_deg(asin(clampf(_enemy.global_transform.basis.x.normalized().y, -1.0, 1.0)))
	var holes := 0
	var water := 0.0
	for c in _enemy.get_children():
		if c is COMPARTMENT:
			holes += c.holes.size() - (1 if c.has_meta(&"open") else 0)   # not the open top of a well
			water += c.flood_volume
	var state := "afloat"
	_sunk = _sunk or (_enemy.global_transform * Vector3(0, SHIP.DECK, 0)).y < -1.0
	if _sunk:
		state = "sunk"
	elif water > 1.0:
		state = "sinking" if water > 25.0 else "taking in water"
	_status.text = "Guns at %+.0f°, 12-pounders at 488 m/s.   Most skips by one shot: %d.   Heel: this ship %+.1f°.\nThe other ship: %d hits, %d holes, %.1f t of water in, heel %+.1f°, %s." % [
		_elevation, skips, heel, _hits, holes, water, heel_enemy, state]


func _reset() -> void:
	for n in [_ship, _enemy]:
		if n and is_instance_valid(n):
			n.queue_free()
	for s in _shots:
		if is_instance_valid(s):
			s.queue_free()
	_shots.clear()
	for n in get_children():
		if n.name.begins_with("Splinter"):
			n.queue_free()
	_ripple.clear()
	_guns.clear()
	_hits = 0
	_sunk = false
	_t = 0.0
	_next = 0.8
	_ship = _make_ship(Vector3(0, 0, 0), SHIP.NAVY, true, 330.0)
	_enemy = _make_ship(Vector3(GAP, 0, 0), SHIP.MERCHANT, false, LADEN)
	_aim()


## A brig, 15 m long and 4.6 m across, ballasted low, of `density` (with its cargo); with guns on its
## starboard (+X) side if armed. Its 25 cm oak sides are planking that shot can hole, and it has six
## compartments inside, three down each side.
func _make_ship(at: Vector3, colours: Dictionary, armed: bool, density: float) -> RigidBody3D:
	var ports := []
	for i in GUNS:
		ports.append(-4.0 + 2.0 * i)
	var b := SHIP.make(self, at, colours, density, ports, not armed)
	b.set_meta(&"home", at)
	var planking: Node = PLANKING.new()
	planking.thickness = 0.25
	b.add_child(planking)
	planking.holed.connect(_mark_hole.bind(b))
	planking.struck.connect(func(ball: RigidBody3D, at: Vector3, _through: bool, _out: float) -> void:
		if is_instance_valid(ball):
			LOOK.dust(self, at, -ball.linear_velocity.normalized()))
	SHIP.compartments(b, COMPARTMENT, [-6.7, -4.6, -1.6, 1.6, 4.6, 7.3])
	if armed:
		for port in b.get_meta(&"ports"):
			var gun: Node3D = CANNON.new()
			gun.gun = CANNON.Gun.POUNDER_12
			gun.spread = 0.4
			gun.shot_lifetime = 12.0
			gun.shot_parent = self
			gun.position = port
			b.add_child(gun)
			SHIP.gun_look(gun)
			gun.fired.connect(_on_fired.bind(gun))
			_guns.append(gun)
	return b


func _aim() -> void:
	for gun in _guns:
		gun.rotation_degrees = Vector3(_elevation, -90.0, 0.0)


func _broadside() -> void:
	for i in _guns.size():
		_ripple.append([_guns[i], _t + 0.15 * i])


## A dark mark where shot has holed `ship`, drawn three times the size of the hole, as the shot is.
## For show.
func _mark_hole(at: Vector3, area: float, _room: Node, ship: Node3D) -> void:
	var mark := MeshInstance3D.new()
	mark.mesh = _hole_mesh
	mark.material_override = _hole_mat
	ship.add_child(mark)
	mark.global_position = at
	mark.scale = Vector3.ONE * 3.0 * sqrt(area / PI)


## Pull `b` back toward its place by cables at bow and stern: a gentle spring, sideways only.
func _moor(b: RigidBody3D) -> void:
	var w := TAU / MOORING
	var home: Vector3 = b.get_meta(&"home")
	var com := b.global_transform * b.center_of_mass
	for end in [-5.0, 5.0]:
		var p := b.global_transform * Vector3(0, 0, end)
		var v := b.linear_velocity + b.angular_velocity.cross(p - com)
		var f := -0.5 * b.mass * (w * w * (p - home - Vector3(0, 0, end)) + w * v)
		f.y = 0.0
		b.apply_force(f, p - b.global_position)


## Whether the roll has brought `gun` to within half a degree of the elevation it is laid at.
func _bears(gun: Node3D) -> bool:
	var up := rad_to_deg(asin(clampf(-gun.global_transform.basis.z.normalized().y, -1.0, 1.0)))
	return absf(up - _elevation) < 0.5


func _on_fired(ball: RigidBody3D, gun: Node3D) -> void:
	_shots.append(ball)
	ball.hit.connect(func(body: Node, _at: Vector3, _v: Vector3) -> void:
		if body == _enemy and not ball.has_meta(&"counted"):   # once a shot, though it strikes both sides
			ball.set_meta(&"counted", true)
			_hits += 1)
	ball.water_entered.connect(_plume)
	for child in ball.get_children():
		if child is MeshInstance3D:
			child.scale = Vector3.ONE * 3.0
	# Smoke and a flash, for show.
	LOOK.smoke(self, gun.global_position, -gun.global_transform.basis.z)


## A column of spray where shot meets the water, taller the faster it hits. For show.
func _plume(speed: float, at: Vector3) -> void:
	LOOK.plume(self, at, speed)   # this scene's root is at the world's origin
