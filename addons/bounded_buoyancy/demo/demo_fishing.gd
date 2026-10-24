extends Node3D
## FISHING: float fishing from a jetty on a lake. Cast the float out; the shot under it cocks it, so
## that only its tip shows. Fish come to the bait and nibble at it, and each nibble dips the float;
## then one takes it and the float slides away under. Strike (sweep the rod back) while it has the
## bait and it is hooked; wait and it drops the bait. A hooked fish runs, veers and dives; the rod
## bends with the pull, and the reel's drag gives line when the pull is more than the drag is set to,
## so a fish that runs hard takes line instead of breaking it. A fish played on a tight line tires;
## let the line go slack and it throws the hook. Reel it in to the jetty to land it.
##   Space   hold to wind up, let go to cast; with a fish on, nothing
##   E       strike (or right mouse button)
##   W/S     reel in / give line (or mouse wheel)
##   +/-     set the drag tighter or looser
##   A       let the angler fish by itself
##   C       change the camera (following the float, on the jetty, under the water by the hook)
##   R       start again
##   Tab     next scene
## The float, the shot and the fish are ordinary Bounded Buoyancy bodies; the fish are
## BoundedBuoyancyFish, the line BoundedBuoyancyLine (0.25 mm nylon, about 3 kg breaking strain).
## The rod is drawn bending with the pull on the line, and its tip moves with it. The float is drawn
## half as wide again as it is, so that it can be seen.

const BW := preload("res://addons/bounded_buoyancy/bounded_buoyancy_water.gd")
const BB := preload("res://addons/bounded_buoyancy/bounded_buoyancy_body.gd")
const LINE := preload("res://addons/bounded_buoyancy/bounded_buoyancy_line.gd")
const FISH := preload("res://addons/bounded_buoyancy/bounded_buoyancy_fish.gd")
const LOOK := preload("res://addons/bounded_buoyancy/demo/demo_look.gd")
const NEXT_SCENE := "res://addons/bounded_buoyancy/demo/demo_submarine.tscn"

const DECK := 0.8               # m: the jetty's deck above the water
const HAND := Vector3(0.45, 1.35, -0.3)   # where the angler holds the rod
const ROD := 3.6                # m long
const ROD_SEGMENTS := 14
const ROD_STIFF := 9.0          # N for each radian the rod bends
const REST_PITCH := 38.0        # degrees: the rod held up while fishing
const STRIKE_PITCH := 66.0      # and swept back to strike
const FLOAT_LONG := 0.25        # m: the float
const FLOAT_WIDE := 0.02
const FLOAT_DENSITY := 280.0
const TIP_SHOWING := 0.025      # m of the float above the water once shotted
const DEPTH := 1.3              # m from the float to the hook
const MAIN := 0.00025           # m: the line's diameter
const BREAKS := 30.0            # N: and its breaking strength
const REEL_SPEED := 0.7         # m/s
const FISH_COUNT := 5
const VIEWS := 3

var _rng := RandomNumberGenerator.new()
var _water: Node3D
var _cam: Camera3D
var _view := 0
var _look_at := Vector3(0, 0, -10)
var _env: Environment
var _sky_fog := 0.0
var _rod_parts: Array = []
var _tip: Node3D
var _float: RigidBody3D
var _hook: RigidBody3D
var _main: Node3D
var _snood: Node3D
var _fish: Array = []
var _pitch := REST_PITCH
var _pitch_to := REST_PITCH
var _bend := 0.0                # radians, smoothed
var _drag := 12.0               # N: the reel's drag
var _casting := false
var _power := 0.0
var _in_flight := false
var _cast_out := false
var _on: Node3D = null          # the hooked fish
var _auto := false
var _auto_wait := 0.0
var _idle := 0.0
var _tackle_gen := 0            # changes with each new tackle, so a late replacement of old tackle is let be
var _caught := 0
var _caught_kg := 0.0
var _status: Label
var _info: Label
var _bar: ProgressBar
var _drag_mark: ColorRect
var _message := ""
var _message_time := 0.0
var _float_mat: ShaderMaterial


func _ready() -> void:
	_rng.seed = 11
	LOOK.sea_and_sky(self, Vector2(-24.0, -150.0), 0.004)
	_env = (get_child(0) as WorldEnvironment).environment
	_env.fog_light_color = Color(0.70, 0.78, 0.82)
	_sky_fog = _env.fog_density
	_water = BW.new()
	_water.size = Vector3(400, 12, 400)
	_water.wave_height = 0.012
	_water.wave_length = 2.5
	_water.wave_direction = 35.0
	_water.splash_min_speed = 0.6
	_water.surface_color = Color(0.10, 0.24, 0.20, 0.72)
	_water.surface_detail = 0.6
	_water.foam = 0.2
	add_child(_water)
	_scenery()
	_make_rod()
	_cam = Camera3D.new()
	_cam.fov = 60.0
	_cam.near = 0.03
	add_child(_cam)
	_hud()
	_reset()
	if "--auto" in OS.get_cmdline_user_args():
		_auto = true


func _reset() -> void:
	_tackle_gen += 1
	for f in _fish:
		if is_instance_valid(f):
			f.queue_free()
	_fish.clear()
	for n in [_float, _hook]:
		if n and is_instance_valid(n):
			n.queue_free()
	if _main and is_instance_valid(_main):
		_main.queue_free()
	_on = null
	_in_flight = false
	_cast_out = false
	_casting = false
	_pitch = REST_PITCH
	_pitch_to = REST_PITCH
	_bend = 0.0
	_place_rod()
	_make_tackle()
	for i in FISH_COUNT:
		_add_fish()
	_say("Hold Space and let go to cast.", 4.0)


# --- The tackle -------------------------------------------------------------------------------

## The float (a stick float, shotted down to its tip), the hook with its shot under it, and the line
## from the rod's tip to the float, hanging from the rod ready to cast.
func _make_tackle() -> void:
	var tip := _tip.global_position
	_float = BB.new()
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = FLOAT_WIDE * 0.5
	cyl.height = FLOAT_LONG
	cs.shape = cyl
	_float.add_child(cs)
	_float.density = FLOAT_DENSITY
	_float.collision_layer = 0
	_float.collision_mask = 0
	_float.angular_drag = 6.0
	_float.position = tip + Vector3(0, -1.0, 0)
	_float.add_child(_float_mesh())
	add_child(_float)
	# The shot that cocks it: enough that it floats with only TIP_SHOWING out, less its own weight.
	var area := PI * FLOAT_WIDE * FLOAT_WIDE * 0.25
	var spare := 1000.0 * area * (FLOAT_LONG - TIP_SHOWING) - FLOAT_DENSITY * area * FLOAT_LONG
	var lead := spare / (11340.0 - 1000.0)
	var r := pow(lead * 3.0 / (4.0 * PI), 1.0 / 3.0)
	_hook = BB.new()
	var hs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = r
	hs.shape = sph
	_hook.add_child(hs)
	_hook.density = 11340.0
	_hook.collision_layer = 0
	_hook.collision_mask = 0
	_hook.position = _float.position + Vector3(0, -0.5 * FLOAT_LONG - DEPTH, 0)
	_hook.add_to_group(&"bounded_buoyancy_bait")
	var shot := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = r * 1.6
	sm.height = r * 3.2
	shot.mesh = sm
	var lead_look := StandardMaterial3D.new()
	lead_look.albedo_color = Color(0.35, 0.36, 0.38)
	lead_look.metallic = 0.6
	lead_look.roughness = 0.4
	shot.material_override = lead_look
	_hook.add_child(shot)
	add_child(_hook)
	_snood = LINE.new()
	_snood.position = Vector3(0, -0.5 * FLOAT_LONG, 0)
	_snood.body = _hook
	_snood.length = DEPTH
	_snood.diameter = 0.0002
	_snood.breaking_strength = 25.0
	_snood.colour = Color(0.85, 0.88, 0.85, 0.7)
	_float.add_child(_snood)
	_main = LINE.new()
	_main.body = _float
	_main.end_offset = Vector3(0, 0.5 * FLOAT_LONG, 0)
	_main.length = 1.0
	_main.diameter = MAIN
	_main.damping = 0.5
	_main.breaking_strength = BREAKS
	_main.slip_tension = _drag
	_main.colour = Color(0.92, 0.94, 0.9, 0.85)
	for l in [_main, _snood]:
		l.snapped.connect(func(_t: float) -> void:
			_say("Snap! The %s broke." % ("line" if l == _main else "hook length"), 4.0)
			var gen := _tackle_gen
			get_tree().create_timer(3.0, false, true).timeout.connect(func() -> void:
				if gen == _tackle_gen:
					_new_tackle()))
	_tip.add_child(_main)


## A stick float 25 cm long: dark below, a white band, an orange tip.
func _float_mesh() -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	# Drawn half as wide again as it is, so that it can be seen from the jetty.
	cm.top_radius = FLOAT_WIDE * 0.75
	cm.bottom_radius = FLOAT_WIDE * 0.4
	cm.height = FLOAT_LONG
	cm.radial_segments = 12
	m.mesh = cm
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
uniform float long = 0.25;
varying float y;
void vertex() { y = VERTEX.y / long + 0.5; }
void fragment() {
	vec3 c = vec3(0.10, 0.16, 0.10);
	if (y > 0.86) { c = vec3(1.0, 0.32, 0.04); EMISSION = c * 1.2; }
	else if (y > 0.80) { c = vec3(0.95, 0.95, 0.9); }
	ALBEDO = c;
	ROUGHNESS = 0.5;
}
"""
	_float_mat = ShaderMaterial.new()
	_float_mat.shader = sh
	_float_mat.set_shader_parameter("long", FLOAT_LONG)
	m.material_override = _float_mat
	return m


# --- The fish ---------------------------------------------------------------------------------

## A fish somewhere out from the jetty: 25 to 45 cm long, as strong as its size.
func _add_fish() -> void:
	var f: RigidBody3D = FISH.new()
	var long := _rng.randf_range(0.25, 0.45)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.11 * long
	cap.height = long
	cs.shape = cap
	cs.rotation_degrees = Vector3(90, 0, 0)
	f.add_child(cs)
	f.collision_layer = 0
	f.collision_mask = 0
	var at := Vector3(_rng.randf_range(-10, 10), -_rng.randf_range(1.0, 2.5), _rng.randf_range(-22, -6))
	f.position = at
	f.rotation.y = _rng.randf() * TAU
	f.mouth = Vector3(0, 0, -0.5 * long)
	f.cruise_speed = 1.0 * long
	f.burst_speed = 7.0 * long
	var kg := 1000.0 * PI * pow(0.11 * long, 2) * long * 0.85
	f.max_thrust = 8.0 * kg
	f.endurance = 8.0 + 10.0 * kg
	f.bite_pull = 0.08
	f.appetite = 0.08
	f.min_depth = 0.6
	f.max_depth = 3.0
	f.home_range = 6.0
	f.sense_range = 5.0
	f.random_seed = _rng.randi() | 1
	var look := _fish_mesh(long)
	f.add_child(look)
	f.set_meta(&"look", look.material_override)
	add_child(f)
	f.took_bait.connect(func(_b: Node3D) -> void:
		if not _on:
			_say("The float's going under! Strike! (E)", 2.0))
	f.nibbled.connect(func(_b: Node3D) -> void:
		if not _on and _message_time <= 0.0:
			_say("A nibble...", 1.5))
	f.dropped_bait.connect(func(_b: Node3D) -> void:
		_say("Missed it: it dropped the bait.", 2.5))
	f.hooked.connect(func() -> void:
		_on = f
		_say("Fish on! Keep the line tight; reel when it tires.", 3.0))
	f.tired.connect(func() -> void:
		if _on == f:
			_say("It's tiring: reel in!", 2.5))
	f.escaped.connect(func() -> void:
		if _on == f:
			_on = null
			_pitch_to = REST_PITCH
			_say("It threw the hook." if not _main.broken else "Gone, with the float.", 3.0))
	_fish.append(f)


## A fish's body: deep in the middle, narrow at the tail, flatter side to side, with a tail fin
## and a fin on its back; its tail beats as it swims.
func _fish_mesh(long: float) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 16
	var around := 12
	var pts: Array = []
	for i in rings + 1:
		var t := float(i) / rings          # 0 at the nose, 1 at the tail
		var z := (t - 0.5) * long
		var r := 0.11 * long * pow(sin(PI * clampf(t * 0.92 + 0.04, 0.0, 1.0)), 0.75) * (1.0 - 0.55 * t * t)
		var row: Array = []
		for j in around:
			var a := TAU * j / around
			row.append(Vector3(cos(a) * r * 0.62, sin(a) * r, z))
		pts.append(row)
	for i in rings:
		for j in around:
			var a: Vector3 = pts[i][j]
			var b: Vector3 = pts[i][(j + 1) % around]
			var c: Vector3 = pts[i + 1][j]
			var d: Vector3 = pts[i + 1][(j + 1) % around]
			for p in [a, c, b, b, c, d]:
				st.add_vertex(p)
	# Tail fin and back fin, both sides.
	var tail_z := 0.5 * long
	var fins := [
		[Vector3(0, 0, tail_z - 0.04 * long), Vector3(0, 0.13 * long, tail_z + 0.13 * long), Vector3(0, -0.13 * long, tail_z + 0.13 * long)],
		[Vector3(0, 0.09 * long, -0.05 * long), Vector3(0, 0.17 * long, 0.08 * long), Vector3(0, 0.08 * long, 0.18 * long)],
	]
	for f in fins:
		st.add_vertex(f[0])
		st.add_vertex(f[1])
		st.add_vertex(f[2])
		st.add_vertex(f[0])
		st.add_vertex(f[2])
		st.add_vertex(f[1])
	st.generate_normals()
	var m := MeshInstance3D.new()
	m.mesh = st.commit()
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled;
uniform float long = 0.35;
uniform float beat = 0.0;
varying vec3 p;
void vertex() {
	p = VERTEX;
	float t = clamp(VERTEX.z / long + 0.5, 0.0, 1.5);
	VERTEX.x += sin(TIME * (6.0 + 10.0 * beat) - t * 4.0) * (0.03 + 0.07 * beat) * long * t * t;
}
void fragment() {
	float up = p.y / (0.11 * long);
	vec3 back = vec3(0.10, 0.16, 0.10);
	vec3 side = vec3(0.55, 0.60, 0.50);
	vec3 belly = vec3(0.85, 0.83, 0.74);
	vec3 c = mix(side, back, smoothstep(0.1, 0.8, up));
	c = mix(c, belly, smoothstep(-0.2, -0.8, up));
	// Dark spots along the flanks.
	vec2 q = vec2(p.z * 40.0 / long, p.y * 60.0 / long);
	float spot = smoothstep(0.32, 0.22, length(fract(q * 0.5) - 0.5));
	c = mix(c, vec3(0.08, 0.10, 0.07), spot * smoothstep(0.6, -0.1, abs(up - 0.25)) * 0.6);
	ALBEDO = c;
	ROUGHNESS = 0.35;
	SPECULAR = 0.6;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("long", long)
	m.material_override = mat
	return m


# --- The rod ----------------------------------------------------------------------------------

func _make_rod() -> void:
	var cork := StandardMaterial3D.new()
	cork.albedo_color = Color(0.62, 0.48, 0.32)
	cork.roughness = 0.9
	var blank := StandardMaterial3D.new()
	blank.albedo_color = Color(0.08, 0.09, 0.10)
	blank.metallic = 0.3
	blank.roughness = 0.35
	for i in ROD_SEGMENTS:
		var m := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		var t0 := float(i) / ROD_SEGMENTS
		var t1 := float(i + 1) / ROD_SEGMENTS
		cm.bottom_radius = lerpf(0.012, 0.0018, t0)
		cm.top_radius = lerpf(0.012, 0.0018, t1)
		cm.height = ROD / ROD_SEGMENTS
		cm.radial_segments = 8
		cm.rings = 1
		m.mesh = cm
		m.material_override = cork if i < 2 else blank
		add_child(m)
		_rod_parts.append(m)
	_tip = Node3D.new()
	add_child(_tip)
	var reel := MeshInstance3D.new()
	var rm := CylinderMesh.new()
	rm.top_radius = 0.035
	rm.bottom_radius = 0.035
	rm.height = 0.03
	reel.mesh = rm
	var reel_look := StandardMaterial3D.new()
	reel_look.albedo_color = Color(0.25, 0.27, 0.3)
	reel_look.metallic = 0.8
	reel.material_override = reel_look
	reel.name = "Reel"
	add_child(reel)


## Lay the rod out from the angler's hands, at its pitch, bent toward the line by the pull on it:
## the tip bends most. Its tip is where the line is made fast.
func _place_rod() -> void:
	var dir := Vector3(0, sin(deg_to_rad(_pitch)), -cos(deg_to_rad(_pitch)))
	var pull := Vector3.DOWN
	if _main and is_instance_valid(_main) and _main.body and is_instance_valid(_main.body):
		var e: Array = _main.ends()
		pull = (e[1] - e[0]).normalized()
	var total := 0.0
	for i in ROD_SEGMENTS:
		total += pow(i + 1, 2)
	var p := HAND
	var d := dir
	var room := d.angle_to(pull)
	var bend := minf(_bend, room)
	var axis := d.cross(pull)
	if axis.length() < 1e-5:
		axis = Vector3.RIGHT
	axis = axis.normalized()
	var piece := ROD / ROD_SEGMENTS
	for i in ROD_SEGMENTS:
		d = d.rotated(axis, bend * pow(i + 1, 2) / total)
		var m: MeshInstance3D = _rod_parts[i]
		var mid := p + d * (0.5 * piece)
		var x := Vector3.UP.cross(d) if absf(d.y) < 0.99 else Vector3.RIGHT
		x = x.normalized()
		m.global_transform = Transform3D(Basis(x, d, x.cross(d)).orthonormalized(), mid)
		p += d * piece
	_tip.global_position = p
	var reel: Node3D = get_node("Reel")
	reel.global_position = HAND + dir * 0.35 + Vector3(0, -0.06, 0)
	reel.global_rotation = Vector3(0, 0, PI * 0.5)


# --- Playing ----------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and not event.echo:
		if event.keycode == KEY_SPACE:
			if event.pressed and not _cast_out and not _in_flight:
				_casting = true
				_power = 0.0
			elif not event.pressed and _casting:
				_cast()
		elif event.pressed and event.keycode == KEY_E:
			_strike()
		elif event.pressed and (event.keycode == KEY_PLUS or event.keycode == KEY_EQUAL or event.keycode == KEY_KP_ADD):
			_drag = minf(_drag + 2.0, 40.0)
			_main.slip_tension = _drag
		elif event.pressed and (event.keycode == KEY_MINUS or event.keycode == KEY_KP_SUBTRACT):
			_drag = maxf(_drag - 2.0, 2.0)
			_main.slip_tension = _drag
		elif event.pressed and event.keycode == KEY_A:
			_auto = not _auto
			_say("The angler fishes by itself." if _auto else "Over to you.", 2.0)
		elif event.pressed and event.keycode == KEY_C:
			_view = (_view + 1) % VIEWS
		elif event.pressed and event.keycode == KEY_R:
			_reset()
		elif event.pressed and event.keycode == KEY_TAB:
			get_tree().change_scene_to_file(NEXT_SCENE)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_strike()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_reel(-0.15)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_reel(0.15)


## Cast: the rod comes forward and the float and its shot fly out, the line running off the reel.
func _cast() -> void:
	_casting = false
	if _main.broken:
		return
	var speed := lerpf(6.0, 15.0, _power)
	var aim := Vector3(_rng.randf_range(-0.12, 0.12), 0.55, -1.0).normalized()
	_float.linear_velocity = aim * speed
	_hook.linear_velocity = aim * speed * 0.97
	_pitch = 15.0
	_pitch_to = REST_PITCH
	_in_flight = true


## Strike: sweep the rod back, which snatches the line tight.
func _strike() -> void:
	if not _cast_out or _main.broken:
		return
	_pitch_to = STRIKE_PITCH
	get_tree().create_timer(0.6, false, true).timeout.connect(func() -> void:
		_pitch_to = REST_PITCH + (20.0 if _on else 0.0))


func _reel(metres: float) -> void:
	if _cast_out and not _main.broken:
		_main.length = maxf(_main.length + metres, 1.0)


func _physics_process(dt: float) -> void:
	if _casting:
		_power = minf(_power + dt, 1.0)
		_pitch_to = REST_PITCH + 45.0 * _power
	_pitch = move_toward(_pitch, _pitch_to, (300.0 if _pitch_to > _pitch else 260.0) * dt)
	# The rod bends with the pull on it, and springs back.
	var want := minf((_main.tension if is_instance_valid(_main) else 0.0) / ROD_STIFF, 1.4)
	_bend = lerpf(_bend, want, 1.0 - exp(-dt / 0.06))
	_place_rod()
	if not is_instance_valid(_main) or not is_instance_valid(_float):
		return
	var e: Array = _main.ends()
	var span: float = (e[1] - e[0]).length()
	if _in_flight:
		# The bail is open: line runs off the reel as fast as the float pulls it.
		_main.length = maxf(_main.length, span + 2.0)
		if _float.submerged_volume > 0.0:
			_in_flight = false
			_cast_out = true
			_main.length = span + 0.3
	elif _cast_out and not _main.broken:
		if Input.is_key_pressed(KEY_W):
			_main.length = maxf(_main.length - REEL_SPEED * dt, 1.0)
		elif Input.is_key_pressed(KEY_S):
			_main.length += REEL_SPEED * dt
		# Reeled right in: the float is back at the rod, ready to cast again.
		if _main.length <= 1.05 and not _on:
			_cast_out = false
	if _main.broken and _on == null:
		_cast_out = false
	_land()
	if _auto:
		_angle(dt)
	_hud_update(dt)


## A hooked fish brought to the jetty, tired and near the surface, is landed (with a net on a pole).
func _land() -> void:
	if _on == null or not is_instance_valid(_on):
		_on = null
		return
	var fp: Vector3 = _on.global_position
	var near := Vector2(fp.x - HAND.x, fp.z - HAND.z).length()
	if near < 4.2 and fp.y > -0.8 and _on.state == FISH.State.TIRED:
		var kg: float = _on.own_mass
		_caught += 1
		_caught_kg += kg
		_say("Landed! %.2f kg. Hold Space to cast again." % kg, 5.0)
		_auto_wait = 4.0
		var f := _on
		_on = null
		_fish.erase(f)
		f.queue_free()
		_add_fish()
		_new_tackle()


## New tackle, hanging from the rod.
func _new_tackle() -> void:
	_tackle_gen += 1
	_pitch_to = REST_PITCH
	for n in [_float, _hook, _main]:
		if n and is_instance_valid(n):
			n.queue_free()
	_cast_out = false
	_in_flight = false
	_make_tackle.call_deferred()


## The angler fishing by itself: cast, watch, strike when the float goes under, play the fish on a
## tight line and reel in as it tires.
func _angle(dt: float) -> void:
	_auto_wait -= dt
	if not _cast_out and not _in_flight and not _casting and _auto_wait <= 0.0:
		_casting = true
		_power = 0.0
		_auto_wait = 1.0
		get_tree().create_timer(0.8, false, true).timeout.connect(func() -> void:
			if _casting:
				_cast())
		return
	if not _cast_out:
		_idle = 0.0
		return
	if _on == null:
		_idle += dt
		for f in _fish:
			if is_instance_valid(f) and f.state == FISH.State.TAKE and f._timer < f.take_time - 0.4 and _pitch_to == REST_PITCH:
				_strike()
				_idle = 0.0
		# Nothing for a long while, or the float drifted in: reel in and cast again.
		var fp := _float.global_position
		if _idle > 60.0 or Vector2(fp.x - HAND.x, fp.z - HAND.z).length() < 4.0:
			_main.length = maxf(_main.length - 2.0 * REEL_SPEED * dt, 1.0)
		return
	# Playing the fish: keep the line tight while it runs (the drag gives it line), reel when it tires.
	if _on.state == FISH.State.TIRED or _main.tension < 0.2 * _drag:
		_main.length = maxf(_main.length - REEL_SPEED * dt, 1.0)


# --- The view and the words --------------------------------------------------------------------

func _process(dt: float) -> void:
	# The fish beat their tails as hard as they swim.
	for f in _fish:
		if is_instance_valid(f):
			f.get_meta(&"look").set_shader_parameter("beat", f.effort)
	if not is_instance_valid(_float):
		return
	var target: Vector3 = _float.global_position
	if _on and is_instance_valid(_on):
		target = _on.global_position.lerp(_float.global_position, 0.4)
	elif not _cast_out:
		target = Vector3(0, 0, -12)
	_look_at = _look_at.lerp(target, 1.0 - exp(-dt / 0.8))
	var under := false
	var waiting := _cast_out and _on == null and not _in_flight
	if _view == 0 and waiting:
		# Close to the float, from the jetty's side, to see it dip.
		var fp: Vector3 = _float.global_position
		var back := Vector3(fp.x - HAND.x, 0.0, fp.z - HAND.z).normalized()
		var from := fp - back * 1.9 + Vector3(0.5, 0.45, 0.0)
		_cam.global_position = _cam.global_position.lerp(from, 1.0 - exp(-dt / 0.6))
		_cam.look_at(fp + Vector3(0, 0.05, 0), Vector3.UP)
	elif _view <= 1:
		var from := Vector3(-0.5, 2.6, 2.6)
		_cam.global_position = _cam.global_position.lerp(from, 1.0 - exp(-dt / 0.3)) if _view == 0 else from
		_cam.look_at(_look_at.lerp(Vector3(_look_at.x, 0.0, _look_at.z), 0.5), Vector3.UP)
	else:
		# Under the water, a little way from the hook, looking at it.
		var h: Vector3 = (_hook.global_position if is_instance_valid(_hook) else _look_at)
		if _on and is_instance_valid(_on):
			h = _on.global_position
		var from := h + Vector3(1.4, 0.15, 1.2)
		from.y = minf(from.y, -0.25)
		_cam.global_position = _cam.global_position.lerp(from, 1.0 - exp(-dt / 0.5))
		_cam.look_at(h, Vector3.UP)
		under = true
	# Under the water: the light is green and the far side lost in it.
	under = under and _cam.global_position.y < _water.height_at(_cam.global_position)
	_env.fog_density = 0.2 if under else _sky_fog
	_env.fog_sky_affect = 1.0 if under else 0.0
	_env.fog_aerial_perspective = 0.0 if under else 0.4
	_env.fog_light_color = Color(0.12, 0.26, 0.22) if under else Color(0.70, 0.78, 0.82)


func _say(text: String, seconds: float) -> void:
	_message = text
	_message_time = seconds


func _hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "Float fishing: cast, wait for a bite, strike, play the fish and land it"
	title.position = Vector2(24, 14)
	_outline(title, Color(1, 1, 1))
	title.add_theme_font_size_override("font_size", 20)
	layer.add_child(title)
	_status = Label.new()
	_status.position = Vector2(24, 44)
	_outline(_status, Color(1.0, 0.92, 0.6))
	_status.add_theme_font_size_override("font_size", 18)
	layer.add_child(_status)
	_info = Label.new()
	_info.position = Vector2(24, 72)
	_outline(_info, Color(0.93, 0.95, 0.98))
	_info.add_theme_font_size_override("font_size", 15)
	layer.add_child(_info)
	_bar = ProgressBar.new()
	_bar.position = Vector2(24, 100)
	_bar.size = Vector2(260, 12)
	_bar.max_value = BREAKS
	_bar.show_percentage = false
	layer.add_child(_bar)
	_drag_mark = ColorRect.new()
	_drag_mark.size = Vector2(3, 18)
	_drag_mark.color = Color(1, 0.85, 0.3)
	layer.add_child(_drag_mark)
	var keys := Label.new()
	keys.text = "Space: hold and let go to cast     E: strike     W/S: reel in / give line     +/-: drag     A: fish by itself     C: camera     R: start again     Tab: next scene"
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 24
	keys.offset_top = -38
	_outline(keys, Color(0.9, 0.94, 1.0))
	keys.add_theme_font_size_override("font_size", 15)
	layer.add_child(keys)


func _hud_update(dt: float) -> void:
	_message_time -= dt
	_status.text = _message if _message_time > 0.0 else ("Winding up... %d%%" % roundi(_power * 100.0) if _casting else "")
	var t: float = _main.tension if is_instance_valid(_main) else 0.0
	_bar.value = t
	_drag_mark.position = Vector2(24 + 260.0 * _drag / BREAKS - 1.0, 97)
	var fish_text := ""
	if _on and is_instance_valid(_on):
		fish_text = "     fish: %s, strength %d%%" % ["running" if _on.state == FISH.State.HOOKED else "tired", roundi(_on.stamina * 100.0)]
	_info.text = "Pull on the line %4.1f N (breaks at %d N), drag %d N     line out %.1f m%s     caught %d (%.2f kg)" % [t, int(BREAKS), int(_drag), _main.length if is_instance_valid(_main) else 0.0, fish_text, _caught, _caught_kg]


func _outline(label: Label, colour: Color) -> void:
	label.add_theme_color_override("font_color", colour)
	label.add_theme_color_override("font_outline_color", Color(0.05, 0.08, 0.12, 0.85))
	label.add_theme_constant_override("outline_size", 5)


# --- The lake and its shore -------------------------------------------------------------------

func _scenery() -> void:
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.45, 0.34, 0.24)
	wood.roughness = 0.95
	var old_wood := StandardMaterial3D.new()
	old_wood.albedo_color = Color(0.30, 0.24, 0.18)
	old_wood.roughness = 1.0
	# The jetty: planks across, on posts.
	for i in 40:
		var plank := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(2.4, 0.05, 0.28)
		plank.mesh = bm
		plank.material_override = wood if i % 3 else old_wood
		plank.position = Vector3(0, DECK, 0.6 - i * 0.3)
		plank.position.z = -0.8 + i * 0.3
		plank.rotation.y = _rng.randf_range(-0.015, 0.015)
		add_child(plank)
	for z in [-0.8, 2.2, 5.2, 8.2, 11.2]:
		for x in [-1.1, 1.1]:
			var post := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.09
			cm.bottom_radius = 0.1
			cm.height = 4.0
			post.mesh = cm
			post.material_override = old_wood
			post.position = Vector3(x, DECK - 2.0 + 0.3, z)
			add_child(post)
	# The shore behind, and the far shore: grass, low hills, trees.
	var grass := StandardMaterial3D.new()
	grass.albedo_color = Color(0.26, 0.38, 0.18)
	grass.roughness = 1.0
	var bank := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 200)
	bank.mesh = pm
	bank.material_override = grass
	bank.position = Vector3(0, 0.25, 112)
	add_child(bank)
	var tree_look := StandardMaterial3D.new()
	tree_look.albedo_color = Color(0.13, 0.24, 0.12)
	tree_look.roughness = 1.0
	var hill_look := StandardMaterial3D.new()
	hill_look.albedo_color = Color(0.22, 0.32, 0.18)
	hill_look.roughness = 1.0
	for i in 26:
		var a := lerpf(-1.2, 1.2, i / 25.0)
		var hill := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = _rng.randf_range(30, 55)
		sm.height = sm.radius * 2.0
		hill.mesh = sm
		hill.material_override = hill_look
		hill.position = Vector3(sin(a) * 190.0, -sm.radius * 0.72, -cos(a) * 190.0)
		add_child(hill)
	for i in 160:
		var a := _rng.randf_range(-1.3, 1.3)
		var r := _rng.randf_range(150.0, 185.0)
		var tree := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		var h := _rng.randf_range(8.0, 16.0)
		cm.top_radius = 0.0
		cm.bottom_radius = h * 0.28
		cm.height = h
		cm.radial_segments = 7
		tree.mesh = cm
		tree.material_override = tree_look
		tree.position = Vector3(sin(a) * r, h * 0.5 + _rng.randf_range(-1.0, 6.0), -cos(a) * r)
		add_child(tree)
	# Reeds by the near bank.
	var reed_look := StandardMaterial3D.new()
	reed_look.albedo_color = Color(0.42, 0.48, 0.22)
	for i in 140:
		var reed := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.004
		cm.bottom_radius = 0.012
		cm.height = _rng.randf_range(1.0, 2.0)
		cm.radial_segments = 4
		reed.mesh = cm
		reed.material_override = reed_look
		var x := _rng.randf_range(2.0, 14.0) * (1.0 if _rng.randf() < 0.5 else -1.0)
		reed.position = Vector3(x, cm.height * 0.5 - 0.3, _rng.randf_range(6.0, 12.0))
		reed.rotation = Vector3(_rng.randf_range(-0.12, 0.12), 0, _rng.randf_range(-0.12, 0.12))
		add_child(reed)
	# The lake bed, and weed on it.
	var bed := MeshInstance3D.new()
	var bp := PlaneMesh.new()
	bp.size = Vector2(120, 120)
	bed.mesh = bp
	var mud := StandardMaterial3D.new()
	mud.albedo_color = Color(0.25, 0.23, 0.15)
	bed.material_override = mud
	bed.position = Vector3(0, -4.5, -20)
	add_child(bed)
	var weed_look := StandardMaterial3D.new()
	weed_look.albedo_color = Color(0.15, 0.30, 0.12)
	for i in 120:
		var weed := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.01
		cm.bottom_radius = 0.03
		cm.height = _rng.randf_range(0.6, 2.4)
		cm.radial_segments = 4
		weed.mesh = cm
		weed.material_override = weed_look
		weed.position = Vector3(_rng.randf_range(-16, 16), -4.5 + cm.height * 0.5, _rng.randf_range(-30, -3))
		weed.rotation = Vector3(_rng.randf_range(-0.2, 0.2), 0, _rng.randf_range(-0.2, 0.2))
		add_child(weed)
