extends Node2D
## The 2D version: a side view of water with waves and a gusty wind. Boats with sails run before the
## wind, crates, barrels and logs float, balloons drift above, and anything dropped in splashes.
## Click to drop something in. Keys: Space = run again, Left / Right = turn the wind round,
## Tab = next scene.

const BB2 := preload("res://addons/bounded_buoyancy/bounded_buoyancy_body_2d.gd")
const BW2 := preload("res://addons/bounded_buoyancy/bounded_buoyancy_water_2d.gd")
const BWIND2 := preload("res://addons/bounded_buoyancy/bounded_buoyancy_wind_2d.gd")
const NEXT_SCENE := "res://addons/bounded_buoyancy/demo/demo.tscn"
const INK := Color(0.12, 0.14, 0.18)
const TEAL := Color(0.16, 0.62, 0.56)
const ORANGE := Color(0.93, 0.5, 0.15)
const WOOD := Color(0.62, 0.45, 0.28)
const BLUE := Color(0.2, 0.42, 0.62)
const HALF_WIDTH := 700.0

var _water: Node2D
var _wind: Node2D
var _bodies: Array = []
var _rng := RandomNumberGenerator.new()
var _wind_label: Label


func _ready() -> void:
	_build_world()
	_reset()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_reset()
		elif event.keycode == KEY_TAB:
			get_tree().change_scene_to_file(NEXT_SCENE)
		elif event.keycode == KEY_LEFT or event.keycode == KEY_RIGHT:
			_wind.velocity.x = -_wind.velocity.x
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_drop_random(get_global_mouse_position())


func _physics_process(_dt: float) -> void:
	for b in _bodies:
		var p: Vector2 = b.global_position
		if absf(p.x) > HALF_WIDTH:
			b.global_position = Vector2(-signf(p.x) * (HALF_WIDTH - 10.0), p.y)
	var w: Vector2 = _wind.velocity_at(Vector2.ZERO)
	_wind_label.text = "Wind now %.1f m/s towards the %s (gusting)" % [w.length() / 100.0, "right" if w.x > 0.0 else "left"]


func _reset() -> void:
	for b in _bodies:
		b.queue_free()
	_bodies.clear()
	_rng.seed = 5
	_add(_boat(), 300.0, Vector2(-420, -40), 0.0, true)
	_add(_boat(), 300.0, Vector2(-150, -40), 0.0, true)
	for i in 3:
		_add(_rect(Vector2(50, 50), WOOD), 500.0, Vector2(80 + 90 * i, -150 - 60 * i), 15.0 * i, false)
	for i in 2:
		_add(_circle(26, BLUE), 650.0, Vector2(380 + 80 * i, -200), 0.0, false)
	_add(_capsule(16, 140, WOOD.darkened(0.15)), 650.0, Vector2(-300, -260), 80.0, false)
	_add(_circle(22, ORANGE), 150.0, Vector2(560, -300), 0.0, false)
	for i in 3:
		var b := _add(_circle(24, TEAL), 0.6, Vector2([-560.0, -80.0, 420.0][i], -330), 0.0, false)
		b.air_half_height = 260.0
		var string := Line2D.new()
		string.points = PackedVector2Array([Vector2(0, 24), Vector2(0, 80)])
		string.width = 1.5
		string.default_color = INK.lightened(0.3)
		b.add_child(string)


## Drop a random body at `at` (click).
func _drop_random(at: Vector2) -> void:
	match _rng.randi() % 4:
		0:
			_add(_rect(Vector2(_rng.randf_range(30, 70), _rng.randf_range(30, 60)), WOOD), 500.0, at, _rng.randf_range(0, 90), false)
		1:
			_add(_circle(_rng.randf_range(15, 30), BLUE), 650.0, at, 0.0, false)
		2:
			_add(_capsule(14, _rng.randf_range(80, 150), WOOD.darkened(0.15)), 650.0, at, _rng.randf_range(0, 180), false)
		_:
			_add(_circle(_rng.randf_range(12, 24), ORANGE), 2700.0, at, 0.0, false)


func _add(parts: Array, dens: float, at: Vector2, rot_deg: float, sail: bool) -> RigidBody2D:
	var b := BB2.new()
	b.add_child(parts[0])
	b.add_child(parts[1])
	b.density = dens
	b.position = at
	b.rotation_degrees = rot_deg
	if sail:
		b.center_of_mass_mode = RigidBody2D.CENTER_OF_MASS_MODE_CUSTOM
		b.center_of_mass = Vector2(0, 10)
		b.sail_size = 70.0
		b.sail_centre = Vector2(0, -60)
		var mast := Line2D.new()
		mast.points = PackedVector2Array([Vector2(0, -15), Vector2(0, -110)])
		mast.width = 3.0
		mast.default_color = INK.lightened(0.2)
		b.add_child(mast)
		var cloth := Polygon2D.new()
		cloth.polygon = PackedVector2Array([Vector2(4, -105), Vector2(4, -25), Vector2(55, -25)])
		cloth.color = Color(0.97, 0.96, 0.92)
		b.add_child(cloth)
	add_child(b)
	_bodies.append(b)
	return b


func _shape_and_look(shape: Shape2D, outline: PackedVector2Array, color: Color) -> Array:
	var cs := CollisionShape2D.new()
	cs.shape = shape
	var look := Polygon2D.new()
	look.polygon = outline
	look.color = color
	return [cs, look]


func _rect(size: Vector2, color: Color) -> Array:
	var s := RectangleShape2D.new()
	s.size = size
	var h := size * 0.5
	return _shape_and_look(s, PackedVector2Array([Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)]), color)


func _circle(r: float, color: Color) -> Array:
	var s := CircleShape2D.new()
	s.radius = r
	var pts := PackedVector2Array()
	for i in 24:
		pts.append(Vector2.from_angle(TAU * i / 24.0) * r)
	return _shape_and_look(s, pts, color)


func _capsule(r: float, h: float, color: Color) -> Array:
	var s := CapsuleShape2D.new()
	s.radius = r
	s.height = h
	var half := 0.5 * h - r
	var pts := PackedVector2Array()
	for i in 13:
		pts.append(Vector2(0, -half) + Vector2.from_angle(PI + PI * i / 12.0) * r)
	for i in 13:
		pts.append(Vector2(0, half) + Vector2.from_angle(PI * i / 12.0) * r)
	return _shape_and_look(s, pts, color)


func _boat() -> Array:
	var s := ConvexPolygonShape2D.new()
	var pts := PackedVector2Array([Vector2(-70, -15), Vector2(80, -15), Vector2(50, 18), Vector2(-55, 18)])
	s.points = pts
	return _shape_and_look(s, pts, TEAL)


func _build_world() -> void:
	RenderingServer.set_default_clear_color(Color(0.84, 0.91, 0.97))
	var cam := Camera2D.new()
	cam.position = Vector2(0, -80)
	add_child(cam)
	_water = BW2.new()
	_water.size = Vector2(2 * HALF_WIDTH + 200, 360)
	_water.wave_height = 6.0
	_water.wave_length = 320.0
	_water.water_color = Color(0.25, 0.55, 0.85, 0.6)
	add_child(_water)
	_wind = BWIND2.new()
	_wind.velocity = Vector2(220, 0)
	_wind.gust_strength = 0.4
	_wind.gust_period = 4.0
	add_child(_wind)
	# A floor under the water, so dense bodies come to rest on it.
	var floor_body := StaticBody2D.new()
	var fs := CollisionShape2D.new()
	var fr := RectangleShape2D.new()
	fr.size = Vector2(2 * HALF_WIDTH + 400, 40)
	fs.shape = fr
	floor_body.add_child(fs)
	var fl := Polygon2D.new()
	fl.polygon = PackedVector2Array([Vector2(-HALF_WIDTH - 200, -20), Vector2(HALF_WIDTH + 200, -20), Vector2(HALF_WIDTH + 200, 20), Vector2(-HALF_WIDTH - 200, 20)])
	fl.color = Color(0.45, 0.4, 0.32)
	floor_body.add_child(fl)
	floor_body.position = Vector2(0, 380)
	add_child(floor_body)
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "The 2D version: waves, gusty wind, sails, balloons and splashes. Click to drop something in."
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
	keys.text = "Click: drop something     Space: run again     Left / Right: turn the wind round     Tab: next scene"
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 24
	keys.offset_top = -38
	keys.add_theme_color_override("font_color", INK.lightened(0.35))
	keys.add_theme_font_size_override("font_size", 16)
	layer.add_child(keys)
