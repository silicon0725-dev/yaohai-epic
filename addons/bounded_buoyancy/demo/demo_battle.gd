extends Node3D
## BATTLE: a pirate brig against a navy brig, under sail. Both sail as the BOATS scene's dinghy does:
## their sails are foils that trim themselves to the wind (square sails, so they cannot point higher
## than about 65 degrees off it), a keel stops them sliding sideways, and a rudder turns them. Each has
## five 12-pounders a side. Broadsides heel the ship that fires them; shot skips off the water and goes
## through the other ship's 25 cm oak sides, holing the compartments behind (BoundedBuoyancyHull);
## the sea comes in at the holes at and below the waterline, the ship settles and heels, more holes go
## under, and in the end she sinks. Fired low, shot skips into a ship; fired high, it goes over her.
## You sail the pirate (black hull, black sails); the navy brig manoeuvres to bring her broadside to
## bear on you, and fires when it does. Guns are laid at the other ship's waterline, with the heel
## taken out, as gun crews did with the wedge under the breech. A ship with more than 35 t of water
## in her strikes her colours (surrenders), as most holed ships did long before they sank.
##   A/D     rudder                    W/S     more or less sail
##   Q / E   fire to port / starboard  Up/Down raise or lower the guns
##   P       sail the pirate by itself C       change the camera
##   F       four times faster         R       start again          Tab   next scene

const BB := preload("res://addons/bounded_buoyancy/bounded_buoyancy_body.gd")
const BW := preload("res://addons/bounded_buoyancy/bounded_buoyancy_water.gd")
const LOOK := preload("res://addons/bounded_buoyancy/demo/demo_look.gd")
const SHIP := preload("res://addons/bounded_buoyancy/demo/demo_ship.gd")
const CANNON := preload("res://addons/bounded_buoyancy/bounded_buoyancy_cannon.gd")
const COMPARTMENT := preload("res://addons/bounded_buoyancy/bounded_buoyancy_compartment.gd")
const PLANKING := preload("res://addons/bounded_buoyancy/bounded_buoyancy_hull.gd")
const FOIL := preload("res://addons/bounded_buoyancy/bounded_buoyancy_foil.gd")
const WIND := preload("res://addons/bounded_buoyancy/bounded_buoyancy_wind.gd")
const NEXT_SCENE := "res://addons/bounded_buoyancy/demo/demo_2d.tscn"

const PIRATE := {wood = Color(0.26, 0.17, 0.10), band = Color(0.55, 0.10, 0.08), bottom = Color(0.40, 0.30, 0.22), ports = Color(0.55, 0.10, 0.08), flag = Color(0.02, 0.02, 0.02), waterline = 0.35}
const GUNS := 5
const DENSITY := 400.0          # kg/m³: each brig with her guns, stores and crew
const WIND_SPEED := 9.0         # m/s, a fresh breeze, from the north (-z) toward the south (+z)
const RELOAD := 18.0            # s, a good gun crew's time to sponge, load and run out
const SAIL_AREA := 115.0        # m², each mast's sails when all are set
const CLOSE := 65.0             # degrees: the nearest a square-rigger sails to the wind
const STRIKES := 35.0           # t of water in: a ship this badly holed strikes her colours

var _wind: Node3D
var _pirate: RigidBody3D
var _navy: RigidBody3D
var _cam: Camera3D
var _view := 0
var _status: Label
var _message: Label
var _t := 0.0
var _auto := false
var _over := false
var _hole_mesh: SphereMesh
var _hole_mat: StandardMaterial3D
var _ticks := Engine.physics_ticks_per_second
var _max_steps := Engine.max_physics_steps_per_frame


func _ready() -> void:
	LOOK.sea_and_sky(self, Vector2(-30.0, 40.0))
	var water := BW.new()
	water.size = Vector3(4000, 400, 4000)
	water.salinity = 35.0
	water.wave_height = 0.25
	water.wave_length = 22.0
	water.wave_direction = 90.0
	water.splash_min_speed = 1.0
	water.surface_color = Color(0.06, 0.22, 0.30, 0.9)
	add_child(water)
	_wind = WIND.new()
	_wind.velocity = Vector3(0, 0, WIND_SPEED)
	_wind.gust_strength = 0.15
	_wind.direction_swing = 4.0
	add_child(_wind)
	_cam = Camera3D.new()
	_cam.fov = 60.0
	_cam.far = 3000.0
	add_child(_cam)
	_hole_mesh = SphereMesh.new()
	_hole_mesh.radius = 1.0
	_hole_mesh.height = 2.0
	_hole_mesh.radial_segments = 8
	_hole_mesh.rings = 4
	_hole_mat = StandardMaterial3D.new()
	_hole_mat.albedo_color = Color(0.06, 0.05, 0.04)
	_hud()
	if "--auto" in OS.get_cmdline_user_args():
		_auto = true
	_reset()


func _reset() -> void:
	for n in [_pirate, _navy]:
		if n and is_instance_valid(n):
			n.queue_free()
	for n in get_children():
		if n.name.begins_with("Splinter") or n.has_meta(&"shot"):
			n.queue_free()
	_t = 0.0
	_over = false
	_message.text = ""
	# Both reaching across the wind on converging courses, to pass broadside to broadside: the pirate
	# heading east, the navy brig west, to the south of her.
	_pirate = _brig(Vector3(0, 0, 0), 90.0, PIRATE, "pirate")
	_navy = _brig(Vector3(230, 0, 55), 270.0, SHIP.NAVY, "navy")
	_pirate.set_meta(&"enemy", _navy)
	_navy.set_meta(&"enemy", _pirate)


# --- The ships --------------------------------------------------------------------------------

## A brig at `at`, heading `heading` degrees clockwise from north (-z), sails set: the ship of the
## FLOOD and CANNONS scenes, with five guns a side, sails, a keel and a rudder.
func _brig(at: Vector3, heading: float, colours: Dictionary, who: String) -> RigidBody3D:
	var ports := []
	for i in GUNS:
		ports.append(-4.0 + 2.0 * i)
	var b := SHIP.make(self, at, colours, DENSITY, ports, false)
	b.rotation.y = -deg_to_rad(heading)
	b.drag_coefficient = 0.05      # a ship's hull is shaped to slip through the water
	b.set_meta(&"who", who)
	var planking: Node = PLANKING.new()
	planking.thickness = 0.25
	b.add_child(planking)
	planking.holed.connect(_mark_hole.bind(b))
	planking.struck.connect(func(ball: RigidBody3D, p: Vector3, _through: bool, _out: float) -> void:
		if is_instance_valid(ball):
			LOOK.dust(self, p, -ball.linear_velocity.normalized())
			b.set_meta(&"hits", int(b.get_meta(&"hits", 0)) + (0 if ball.has_meta(&"counted") else 1))
			ball.set_meta(&"counted", true))
	SHIP.compartments(b, COMPARTMENT, [-6.7, -4.6, -1.6, 1.6, 4.6, 7.3])
	# Guns both sides: starboard (+x) as the ship builder places them, port mirrored.
	var guns := {1: [], -1: []}
	for port in b.get_meta(&"ports"):
		for side in [1, -1]:
			var gun: Node3D = CANNON.new()
			gun.gun = CANNON.Gun.POUNDER_12
			gun.spread = 0.5
			gun.reload_time = RELOAD
			gun.shot_lifetime = 10.0
			gun.shot_parent = self
			gun.position = Vector3(side * port.x, port.y, port.z)
			gun.rotation_degrees = Vector3(0.0, -90.0 * side, 0.0)
			b.add_child(gun)
			SHIP.gun_look(gun)
			gun.fired.connect(_on_fired.bind(gun))
			guns[side].append(gun)
	b.set_meta(&"guns", guns)
	b.set_meta(&"elevation", 1.0)
	b.set_meta(&"ripple", [])
	# Sailing: a keel (the hull's long underwater side), a rudder, and the sails on each mast, trimming
	# themselves to the wind.
	var keel: Node3D = FOIL.new()
	keel.area = 16.0
	keel.aspect_ratio = 0.6
	keel.position = Vector3(0, SHIP.KEEL + 0.5, 0)
	b.add_child(keel)
	var rudder: Node3D = FOIL.new()
	rudder.area = 3.5
	rudder.aspect_ratio = 1.5
	rudder.effort_offset = 0.4
	rudder.position = Vector3(0, SHIP.KEEL + 0.8, 0.5 * SHIP.LENGTH - 0.2)
	b.add_child(rudder)
	b.set_meta(&"rudder", rudder)
	var sails := []
	for z in [-0.22 * SHIP.LENGTH, 0.1 * SHIP.LENGTH]:
		var s: Node3D = FOIL.new()
		s.medium = FOIL.Medium.AIR
		s.area = SAIL_AREA
		s.aspect_ratio = 1.2
		s.auto_trim = true
		s.max_trim = 70.0     # the yards swing no further round the mast
		s.trim_angle_of_attack = 18.0
		s.position = Vector3(0, SHIP.DECK + 7.5, z)
		b.add_child(s)
		sails.append(s)
	b.set_meta(&"sails", sails)
	b.set_meta(&"set", 1.0)
	return b


func _sail_set(b: RigidBody3D, amount: float) -> void:
	b.set_meta(&"set", clampf(amount, 0.0, 1.0))
	for s in b.get_meta(&"sails"):
		s.area = SAIL_AREA * b.get_meta(&"set")


## Fire `side`'s broadside (1 starboard, -1 port): each loaded gun in turn, as the roll brings it to
## bear, as gun captains fired.
func broadside(b: RigidBody3D, side: int) -> void:
	if not is_instance_valid(b) or _sunk(b) or b.has_meta(&"struck"):
		return
	var ripple: Array = b.get_meta(&"ripple")
	var i := 0
	for gun in b.get_meta(&"guns")[side]:
		if gun.is_loaded():
			ripple.append([gun, _t + 0.2 * i])
			i += 1


func _lay_guns(b: RigidBody3D) -> void:
	var e: float = b.get_meta(&"elevation")
	for side in [1, -1]:
		for gun in b.get_meta(&"guns")[side]:
			gun.rotation_degrees = Vector3(e, -90.0 * side, 0.0)


## Lay each gun of `b` against the horizon, as gun crews did with the wedge (the quoin) under the
## breech: the ship's heel taken out, within the 8 degrees down and 12 up the quoin allows.
func _quoins(b: RigidBody3D) -> void:
	var e: float = b.get_meta(&"elevation")
	for side in [1, -1]:
		for gun in b.get_meta(&"guns")[side]:
			var up := rad_to_deg(asin(clampf(-gun.global_transform.basis.z.normalized().y, -1.0, 1.0)))
			var lay := clampf(gun.rotation_degrees.x + (e - up), -8.0, 12.0)
			gun.rotation_degrees = Vector3(lay, -90.0 * side, 0.0)


func _bears(gun: Node3D, elevation: float) -> bool:
	var up := rad_to_deg(asin(clampf(-gun.global_transform.basis.z.normalized().y, -1.0, 1.0)))
	return absf(up - elevation) < 0.6


func _loaded(b: RigidBody3D, side: int) -> int:
	var n := 0
	for g in b.get_meta(&"guns")[side]:
		if g.is_loaded():
			n += 1
	return n


func _sunk(b: RigidBody3D) -> bool:
	return (b.global_transform * Vector3(0, SHIP.DECK, 0)).y < -1.5


func _water_in(b: RigidBody3D) -> float:
	var w := 0.0
	for c in b.get_children():
		if c is COMPARTMENT:
			w += c.flood_volume
	return w


# --- Sailing them -----------------------------------------------------------------------------

## The heading, degrees clockwise from north, of `b`.
static func _heading(b: Node3D) -> float:
	var f := -b.global_transform.basis.z
	return fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0)


## Steer `b` toward heading `want` (degrees from north), but no nearer the wind than a square-rigger
## can sail.
func _steer(b: RigidBody3D, want: float) -> void:
	# The wind blows toward the south, so it comes from the north: heading 0.
	var off := wrapf(want, -180.0, 180.0)
	if absf(off) < CLOSE:
		off = CLOSE * (1.0 if off >= 0.0 else -1.0)
	var error := wrapf(off - _heading(b), -180.0, 180.0)
	var rudder: Node3D = b.get_meta(&"rudder")
	rudder.angle = clampf(1.2 * error + 30.0 * b.angular_velocity.y, -30.0, 30.0)


## A captain: close in when far off, then sail across her bearing with loaded guns toward her (turning
## to show her the other side while one side reloads), and fire when she is abeam.
func _captain(b: RigidBody3D) -> void:
	var enemy: RigidBody3D = b.get_meta(&"enemy")
	if not is_instance_valid(enemy) or _sunk(b) or b.has_meta(&"struck") or enemy.has_meta(&"struck"):
		return
	var to := enemy.global_position - b.global_position
	to.y = 0.0
	var range_m := to.length()
	# Aim at where she will be, a little ahead.
	var lead := to + enemy.linear_velocity * clampf(range_m / 8.0, 0.0, 15.0)
	lead.y = 0.0
	var bearing := fposmod(rad_to_deg(atan2(lead.x, -lead.z)), 360.0)
	# Which side she is on now, and which side has its guns loaded.
	var side := 1 if wrapf(bearing - _heading(b), -180.0, 180.0) > 0.0 else -1
	if _loaded(b, side) == 0 and _loaded(b, -side) > 0:
		side = -side
	var across := 90.0
	if range_m > 120.0:
		across = 20.0
	elif range_m < 50.0:
		across = 125.0
	_steer(b, bearing - side * across)
	# Guns laid for the range, and a little low: shot that falls short skips off the water into her
	# hull at the waterline, where holes let the sea in, as gunners laid them to.
	# Aimed from the guns' height at her waterline, a little below it, plus the drop over the range.
	var gun_y: float = (b.global_transform * Vector3(0, SHIP.DECK + 0.4, 0)).y
	var aim_y: float = enemy.global_position.y + 0.1
	var e := clampf(rad_to_deg(atan2(aim_y - gun_y, maxf(range_m, 1.0)) + 0.5 * asin(clampf(9.8 * range_m / (488.0 * 488.0), 0.0, 1.0))), -6.0, 6.0)
	if absf(e - float(b.get_meta(&"elevation"))) > 0.2:
		b.set_meta(&"elevation", e)
		_lay_guns(b)
	var now := fposmod(rad_to_deg(atan2(to.x, -to.z)), 360.0)
	var rel := wrapf(now - _heading(b), -180.0, 180.0)
	var facing := 1 if rel > 0.0 else -1
	if range_m < 160.0 and absf(absf(rel) - 90.0) < 8.0 and _loaded(b, facing) >= 3:
		broadside(b, facing)


# --- Playing ----------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_Q:
			broadside(_pirate, -1)
		KEY_E:
			broadside(_pirate, 1)
		KEY_W:
			_sail_set(_pirate, float(_pirate.get_meta(&"set")) + 0.25)
		KEY_S:
			_sail_set(_pirate, float(_pirate.get_meta(&"set")) - 0.25)
		KEY_UP:
			_pirate.set_meta(&"elevation", minf(float(_pirate.get_meta(&"elevation")) + 0.5, 8.0))
			_lay_guns(_pirate)
		KEY_DOWN:
			_pirate.set_meta(&"elevation", maxf(float(_pirate.get_meta(&"elevation")) - 0.5, -3.0))
			_lay_guns(_pirate)
		KEY_P:
			_auto = not _auto
		KEY_C:
			_view = (_view + 1) % 3
		KEY_F:
			_speed(4.0 if Engine.time_scale < 2.0 else 1.0)
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


func _physics_process(dt: float) -> void:
	_t += dt
	if not (is_instance_valid(_pirate) and is_instance_valid(_navy)):
		return
	_captain(_navy)
	if _auto:
		_captain(_pirate)
	else:
		var rudder: Node3D = _pirate.get_meta(&"rudder")
		var want := 0.0
		if Input.is_key_pressed(KEY_A):
			want = -25.0
		elif Input.is_key_pressed(KEY_D):
			want = 25.0
		rudder.angle = move_toward(rudder.angle, want, 40.0 * dt)
	for b in [_pirate, _navy]:
		_quoins(b)
		var ripple: Array = b.get_meta(&"ripple")
		for r in ripple.duplicate():
			if _t >= r[1] and (_bears(r[0], b.get_meta(&"elevation")) or _t >= r[1] + 2.0):
				ripple.erase(r)
				if is_instance_valid(r[0]) and r[0].is_loaded():
					r[0].fire()
				for later in ripple:
					later[1] = maxf(later[1], _t + 0.2)
		# A sinking ship's sails come down as she goes.
		if _sunk(b):
			_sail_set(b, 0.0)
	if not _over:
		# A ship holed so badly that she cannot fight on strikes her colours (surrenders), as most did
		# long before they sank; one that sinks first has lost too.
		for b in [_navy, _pirate]:
			if _sunk(b) or _water_in(b) > STRIKES:
				_over = true
				_strike(b)
				var won := "The pirates have won." if b == _navy else "The navy has won."
				_message.text = "%s %s   R: again" % [
					("The navy brig" if b == _navy else "Your ship") + (" sinks." if _sunk(b) else " strikes her colours."), won]
				break


## `b` strikes her colours: her flag comes down, her guns fall silent, and she lies to.
func _strike(b: RigidBody3D) -> void:
	b.set_meta(&"struck", true)
	var flag := b.get_node_or_null(^"Flag")
	if flag:
		flag.visible = false
	b.get_meta(&"ripple").clear()
	_sail_set(b, 0.25)


func _on_fired(ball: RigidBody3D, gun: Node3D) -> void:
	ball.set_meta(&"shot", true)
	ball.water_entered.connect(func(speed: float, p: Vector3) -> void:
		if speed > 30.0:
			LOOK.plume(self, p, speed))
	for child in ball.get_children():
		if child is MeshInstance3D:
			child.scale = Vector3.ONE * 3.0
	LOOK.smoke(self, gun.global_position, -gun.global_transform.basis.z)


func _mark_hole(at: Vector3, area: float, _room: Node, ship: Node3D) -> void:
	var mark := MeshInstance3D.new()
	mark.mesh = _hole_mesh
	mark.material_override = _hole_mat
	ship.add_child(mark)
	mark.global_position = at
	mark.scale = Vector3.ONE * 3.0 * sqrt(area / PI)


# --- The view and the words --------------------------------------------------------------------

func _process(dt: float) -> void:
	if not (is_instance_valid(_pirate) and is_instance_valid(_navy)):
		return
	var p := _pirate.global_position
	var n := _navy.global_position
	var from: Vector3
	var look: Vector3
	match _view:
		0:
			# Astern of the pirate and above, looking past her toward the navy brig.
			var away := (p - n)
			away.y = 0.0
			away = away.normalized() if away.length() > 1.0 else Vector3.BACK
			from = p + away * 34.0 + Vector3(0, 13.0, 0) + away.cross(Vector3.UP) * 8.0
			look = p.lerp(n, 0.35) + Vector3(0, 2.0, 0)
		1:
			# Off to one side of both, to see them together.
			var mid := 0.5 * (p + n)
			var line := (n - p)
			line.y = 0.0
			var across := line.cross(Vector3.UP).normalized()
			from = mid + across * maxf(0.9 * line.length(), 60.0) + Vector3(0, 16.0, 0)
			look = mid + Vector3(0, 2.0, 0)
		_:
			# On the pirate's deck, looking at the enemy.
			from = _pirate.global_transform * Vector3(0, SHIP.DECK + 2.2, 3.0)
			look = n + Vector3(0, 3.0, 0)
	_cam.global_position = _cam.global_position.lerp(from, 1.0 - exp(-dt / 0.5)) if _t > 0.1 else from
	_cam.look_at(look, Vector3.UP)
	_status.text = _report()


func _report() -> String:
	var lines := []
	for b in [_pirate, _navy]:
		var load_text := ""
		for side in [-1, 1]:
			var ready := 0
			for g in b.get_meta(&"guns")[side]:
				if g.is_loaded():
					ready += 1
			load_text += "%s %d/%d  " % ["port" if side < 0 else "starboard", ready, GUNS]
		var heel := rad_to_deg(asin(clampf(b.global_transform.basis.x.normalized().y, -1.0, 1.0)))
		lines.append("%s: %4.1f knots, heading %03d°, sails %d%%, heel %+4.1f°, guns loaded %s, hit %d times, %.1f t of water in" % [
			"Pirate" if b == _pirate else "Navy  ", b.linear_velocity.length() * 1.944, roundi(_heading(b)),
			roundi(100.0 * float(b.get_meta(&"set"))), heel, load_text, int(b.get_meta(&"hits", 0)), _water_in(b)])
	var to := _navy.global_position - _pirate.global_position
	to.y = 0.0
	lines.append("Range %d m.   Wind from the north, %d knots.   Guns laid at %+.1f°.%s" % [roundi(to.length()), roundi(WIND_SPEED * 1.944),
		float(_pirate.get_meta(&"elevation")), "   The pirate sails herself (P)." if _auto else ""])
	return "\n".join(lines)


func _hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "Pirates! Two brigs under sail, broadside to broadside"
	title.position = Vector2(24, 14)
	_outline(title, Color(1, 1, 1))
	title.add_theme_font_size_override("font_size", 20)
	layer.add_child(title)
	_status = Label.new()
	_status.position = Vector2(24, 44)
	_outline(_status, Color(0.93, 0.95, 0.98))
	_status.add_theme_font_size_override("font_size", 14)
	layer.add_child(_status)
	_message = Label.new()
	_message.position = Vector2(24, 112)
	_outline(_message, Color(1.0, 0.85, 0.4))
	_message.add_theme_font_size_override("font_size", 22)
	layer.add_child(_message)
	var keys := Label.new()
	keys.text = "A/D: rudder     W/S: sail     Q/E: fire port/starboard     Up/Down: guns     P: sail herself     C: camera     F: faster     R: again     Tab: next"
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 24
	keys.offset_top = -38
	_outline(keys, Color(0.9, 0.94, 1.0))
	keys.add_theme_font_size_override("font_size", 15)
	layer.add_child(keys)


func _outline(label: Label, colour: Color) -> void:
	label.add_theme_color_override("font_color", colour)
	label.add_theme_color_override("font_outline_color", Color(0.05, 0.08, 0.12, 0.85))
	label.add_theme_constant_override("outline_size", 5)
