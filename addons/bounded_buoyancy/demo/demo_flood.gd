extends Node3D
## FLOOD: two ships, the same hole. Both are holed on the starboard side below the waterline. The one
## with a single big hold floods right across and goes down; the one divided into six compartments
## floods only the holed one, lists a little toward it, and stays afloat.
##   H       make the hole now (it is made by itself two seconds in)
##   P       pumps on the divided ship: it comes upright again (the hole is patched first)
##   Space   run again
##   Tab     next scene
## Everything here is ordinary Bounded Buoyancy bodies with BoundedBuoyancyCompartment nodes under
## them; the meshes are for show.

const LOOK := preload("res://addons/bounded_buoyancy/demo/demo_look.gd")
const BB := preload("res://addons/bounded_buoyancy/bounded_buoyancy_body.gd")
const BW := preload("res://addons/bounded_buoyancy/bounded_buoyancy_water.gd")
const COMPARTMENT := preload("res://addons/bounded_buoyancy/bounded_buoyancy_compartment.gd")
const NEXT_SCENE := "res://addons/bounded_buoyancy/demo/demo_cannons.tscn"

const INK := Color(0.12, 0.14, 0.18)
const HULL := Color(0.42, 0.27, 0.16)
const DECK := Color(0.78, 0.66, 0.46)
const HOLE_AREA := 0.25           # m², a ragged breach about 55 cm across
const HOLE_AT := Vector3(1.0, -0.5, 0.3)    # in the ships' own coordinates: starboard, low below the waterline

var _ships: Array = []            # [body, compartments, label, name]
var _holed := false
var _t := 0.0
var _status: Label


func _ready() -> void:
	LOOK.sea_and_sky(self, Vector2(-35.0, -25.0))
	var water := BW.new()
	water.size = Vector3(3000.0, 400.0, 3000.0)
	water.surface_color = Color(0.06, 0.22, 0.30, 0.85)
	water.wave_height = 0.03
	water.wave_length = 9.0
	water.wave_direction = 95.0
	add_child(water)
	var cam := Camera3D.new()
	cam.fov = 50.0
	cam.position = Vector3(0.0, 3.4, 12.5)
	cam.rotation_degrees = Vector3(-13, 0, 0)
	add_child(cam)
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "Two ships, the same hole below the waterline on the starboard side"
	title.position = Vector2(24, 14)
	title.add_theme_color_override("font_color", INK)
	title.add_theme_font_size_override("font_size", 20)
	layer.add_child(title)
	_status = Label.new()
	_status.position = Vector2(24, 44)
	_status.add_theme_color_override("font_color", INK.lightened(0.2))
	_status.add_theme_font_size_override("font_size", 16)
	layer.add_child(_status)
	var keys := Label.new()
	keys.text = "H: hole now     P: pumps on the divided ship     Space: run again     Tab: next scene"
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 24
	keys.offset_top = -38
	keys.add_theme_color_override("font_color", INK.lightened(0.35))
	keys.add_theme_font_size_override("font_size", 16)
	layer.add_child(keys)
	_reset()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_reset()
		elif event.keycode == KEY_TAB:
			get_tree().change_scene_to_file(NEXT_SCENE)
		elif event.keycode == KEY_H:
			_hole()
		elif event.keycode == KEY_P and _ships.size() > 1:
			for c in _ships[1][1]:
				c.patch_holes()
				c.pump_rate = 0.25


func _physics_process(dt: float) -> void:
	_t += dt
	if not _holed and _t >= 2.0:
		_hole()
	var lines := PackedStringArray()
	for s in _ships:
		var body: RigidBody3D = s[0]
		var water := 0.0
		for c in s[1]:
			water += c.flood_volume
		var heel := rad_to_deg(asin(clampf(-body.global_transform.basis.x.normalized().y, -1.0, 1.0)))
		var freeboard: float = (body.global_transform * Vector3(0, 0.6, 0)).y
		var state := "afloat"
		if freeboard < -0.05:
			state = "sunk"
		elif absf(heel) > 45.0:
			state = "capsized"
		s[2].text = "%s\n%.1f t of water in, %+.0f° heel, %s" % [s[3], water, heel, state]
		s[2].global_position = Vector3(body.global_position.x, maxf(body.global_position.y + 2.6, 2.0), body.global_position.z)
		s[2].global_rotation = Vector3.ZERO
		lines.append("%s: %.1f t of water in, heel %+.1f°, %s" % [s[3], water, heel, state])
	_status.text = "   ".join(lines)


func _reset() -> void:
	for s in _ships:
		s[0].queue_free()
		s[2].queue_free()
	_ships.clear()
	_holed = false
	_t = 0.0
	_ships.append(_ship(Vector3(-4.2, 0.0, 0), "One big hold", [[Vector3(0, 0, -0.1), Vector3(1.75, 1.15, 5.3)]]))
	var six := []
	for side in [-0.44, 0.44]:
		for end in [-1.85, -0.1, 1.65]:
			six.append([Vector3(side, 0, end), Vector3(0.87, 1.15, 1.75)])
	_ships.append(_ship(Vector3(4.2, 0.0, 0), "Six compartments", six))


## A small ship 6.6 m long and 2.2 m wide, ballasted low, with the compartments given as [centre, size].
func _ship(at: Vector3, caption: String, rooms: Array) -> Array:
	var b := BB.new()
	var hull := ConvexPolygonShape3D.new()
	hull.points = PackedVector3Array([
		Vector3(-1.1, 0.6, -3.0), Vector3(1.1, 0.6, -3.0), Vector3(-1.1, 0.6, 2.8), Vector3(1.1, 0.6, 2.8), Vector3(0, 0.6, 3.6),
		Vector3(-0.9, -0.6, -2.8), Vector3(0.9, -0.6, -2.8), Vector3(-0.9, -0.6, 2.6), Vector3(0.9, -0.6, 2.6), Vector3(0, -0.4, 3.3)])
	var cs := CollisionShape3D.new()
	cs.shape = hull
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = hull.get_debug_mesh()
	var hm := StandardMaterial3D.new()
	hm.albedo_color = HULL
	hm.roughness = 0.9
	mi.material_override = hm
	b.add_child(mi)
	# Deck and a cabin, for show.
	var deck := MeshInstance3D.new()
	var dm := BoxMesh.new()
	dm.size = Vector3(2.15, 0.04, 5.75)
	deck.mesh = dm
	deck.position = Vector3(0, 0.6, -0.1)
	var deck_mat := StandardMaterial3D.new()
	deck_mat.albedo_color = DECK
	deck.material_override = deck_mat
	b.add_child(deck)
	var cabin := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(1.3, 0.8, 1.6)
	cabin.mesh = cm
	cabin.position = Vector3(0, 1.0, -1.6)
	var cabin_mat := StandardMaterial3D.new()
	cabin_mat.albedo_color = Color(0.92, 0.92, 0.88)
	cabin.material_override = cabin_mat
	b.add_child(cabin)
	b.density = 330.0
	b.angular_drag = 2.0
	b.position = at
	add_child(b)
	b.center_of_mass = Vector3(0, -0.3, 0)   # ballast low in the keel
	var comps := []
	for r in rooms:
		var c: Node3D = COMPARTMENT.new()
		c.position = r[0]
		c.size = r[1]
		b.add_child(c)
		comps.append(c)
	var label := Label3D.new()
	label.text = caption
	label.font_size = 64
	label.pixel_size = 0.0065
	label.modulate = INK
	label.outline_size = 8
	label.outline_modulate = Color(1, 1, 1, 0.8)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)
	return [b, comps, label, caption]


## The same hole in both ships: in whichever compartment is at that point.
func _hole() -> void:
	if _holed:
		return
	_holed = true
	for s in _ships:
		var body: RigidBody3D = s[0]
		var at := body.to_global(HOLE_AT)
		var best: Node3D = null
		var best_d := INF
		for c in s[1]:
			var d: float = (c.global_position - at).length()
			if d < best_d:
				best_d = d
				best = c
		best.add_hole(at, HOLE_AREA)
		var mark := MeshInstance3D.new()
		var disc := CylinderMesh.new()
		disc.top_radius = 0.28
		disc.bottom_radius = 0.28
		disc.height = 0.02
		mark.mesh = disc
		var mm := StandardMaterial3D.new()
		mm.albedo_color = Color(0.05, 0.04, 0.03)
		mark.material_override = mm
		mark.position = Vector3(0.92, HOLE_AT.y, HOLE_AT.z)
		mark.rotation_degrees = Vector3(0, 0, 90)
		body.add_child(mark)
