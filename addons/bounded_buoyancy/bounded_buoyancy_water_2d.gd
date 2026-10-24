@tool
@icon("res://addons/bounded_buoyancy/icon_water.svg")
class_name BoundedBuoyancyWater2D
extends Node2D
## A body of water for BoundedBuoyancyBody2D, with optional waves, a current and splashes.
##
## Place the node where the middle of the surface should be; the water fills a rectangle of `size`
## below it (y points down). Keep the node unrotated and unscaled: set the size instead. Once a scene has any BoundedBuoyancyWater2D, bodies float only inside
## one. Waves move the surface; a current makes the water flow and carries bodies along.

## Width and depth of the water, in pixels.
@export var size: Vector2 = Vector2(1200.0, 300.0):
	set(value):
		size = value.max(Vector2(1.0, 1.0))
		queue_redraw()
## Density of the water: 1000 kg/m³ fresh, about 1025 sea.
@export_range(1.0, 20000.0, 1.0, "or_greater", "suffix:kg/m³") var density: float = 1000.0

@export_group("Waves")
## Height of the largest wave above the mean surface, in pixels. 0 for still water.
@export_range(0.0, 500.0, 0.1, "or_greater", "suffix:px") var wave_height: float = 0.0:
	set(value):
		wave_height = value
		_update_waves()
## Distance from one crest to the next, in pixels.
@export_range(1.0, 100000.0, 0.1, "or_greater", "suffix:px") var wave_length: float = 400.0:
	set(value):
		wave_length = maxf(value, 0.01)
		_update_waves()

@export_group("Current")
## Velocity of the flowing water, in pixels per second (positive x flows right).
@export var current: Vector2 = Vector2.ZERO

@export_group("Splashes")
## Throw up droplets when a body hits the water fast enough.
@export var splashes: bool = true
## Slowest impact that throws up a splash, in pixels per second.
@export_range(0.0, 5000.0, 1.0, "or_greater", "suffix:px/s") var splash_min_speed: float = 150.0
## Colour of the droplets.
@export var splash_color: Color = Color(0.95, 0.98, 1.0, 0.9)

@export_group("Look")
## Draw the water. Turn off to draw your own.
@export var show_water: bool = true:
	set(value):
		show_water = value
		queue_redraw()
## Colour and opacity of the water.
@export var water_color: Color = Color(0.22, 0.52, 0.82, 0.55):
	set(value):
		water_color = value
		queue_redraw()

## Wave clock in seconds, advanced with the physics step.
var time: float = 0.0

## Every BoundedBuoyancyWater2D in the scene tree.
static var instances: Array[Node2D] = []
## The world this water is in; bodies only use water in their own world.
var world: World2D

const SECOND_LENGTH := 0.63
const SECOND_HEIGHT := 0.4
var _k1 := 0.0
var _k2 := 0.0
var _w1 := 0.0
var _w2 := 0.0
var _splashes: Array = []    # [CPUParticles2D, age]
var _droplet: Texture2D


func _enter_tree() -> void:
	world = get_world_2d()
	process_physics_priority = -1000
	if not instances.has(self):
		instances.append(self)
	_update_waves()


func _exit_tree() -> void:
	instances.erase(self)


func _physics_process(dt: float) -> void:
	if not Engine.is_editor_hint():
		time += dt


func _process(dt: float) -> void:
	if wave_height > 0.0 and show_water:
		queue_redraw()
	var i := 0
	while i < _splashes.size():
		var e: Array = _splashes[i]
		e[1] += dt
		if e[1] > e[0].lifetime + 0.2:
			e[0].queue_free()
			_splashes.remove_at(i)
		else:
			i += 1


## Height (global y) of the surface above the global x position `x`.
func height_at(x: float) -> float:
	var y := global_position.y
	if wave_height <= 0.0:
		return y
	var lx := x - global_position.x
	return y + wave_height * (sin(_k1 * lx - _w1 * time) + SECOND_HEIGHT * sin(_k2 * lx - _w2 * time + 1.3))


## Acceleration of the water in the waves at the point `p`, along +y (downwards, px/s²), as
## BoundedBuoyancyWater.vertical_acceleration_at (with y pointing down here); with `across` (px),
## averaged over that width centred on p (two Gauss points).
func vertical_acceleration_at(p: Vector2, across := 0.0) -> float:
	if wave_height <= 0.0:
		return 0.0
	var lx := p.x - global_position.x
	var h := across / (2.0 * sqrt(3.0))
	# The waves' parts as heights upwards: the surface is pushed down (+y) where the sines are positive.
	var h1 := -wave_height * sin(_k1 * lx - _w1 * time)
	var h2 := -wave_height * SECOND_HEIGHT * sin(_k2 * lx - _w2 * time + 1.3)
	var z := mean_height(global_position.y - p.y, h1, _k1, h2, _k2)
	# Upward acceleration -(ω² h ...); downward is its negative.
	return _w1 * _w1 * h1 * cos(_k1 * h) * exp(_k1 * z) + _w2 * _w2 * h2 * cos(_k2 * h) * exp(_k2 * z)


## The average height z (no more than 0, upwards) of the water that is `y` above the average level
## now, as BoundedBuoyancyWater.mean_height.
static func mean_height(y: float, h1: float, k1: float, h2: float, k2: float) -> float:
	var z := minf(y - h1 - h2, 0.0)
	for i in 2:   # two steps of Newton's method: well under a millimetre for waves that do not break
		var e1 := h1 * exp(k1 * z)
		var e2 := h2 * exp(k2 * z)
		z = minf(z - (z - y + e1 + e2) / maxf(1.0 + k1 * e1 + k2 * e2, 0.2), 0.0)
	return z


## The most the surface rises or falls from its mean height.
func max_wave() -> float:
	return wave_height * (1.0 + SECOND_HEIGHT)


## Whether the global point `p` lies over or in the water: inside it across, and above its floor.
func contains(p: Vector2) -> bool:
	var l := p - global_position
	return absf(l.x) <= 0.5 * size.x and l.y <= size.y


## Velocity of the water at the global point `p`, in px/s.
func current_at(_p: Vector2) -> Vector2:
	return current


## Throw up a splash at the global point `at` for a body `size_px` across hitting at `speed` px/s.
func splash(at: Vector2, speed: float, size_px: float) -> void:
	if not splashes or speed < splash_min_speed or not is_inside_tree() or Engine.is_editor_hint():
		return
	if _splashes.size() >= 32:
		var old: Array = _splashes.pop_front()
		old[0].queue_free()
	if _droplet == null:
		var grad := Gradient.new()
		grad.set_color(0, Color(1, 1, 1, 1))
		grad.set_color(1, Color(1, 1, 1, 0))
		var tex := GradientTexture2D.new()
		tex.gradient = grad
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(1.0, 0.5)
		tex.width = 16
		tex.height = 16
		_droplet = tex
	var g := float(ProjectSettings.get_setting("physics/2d/default_gravity"))
	var p := CPUParticles2D.new()
	p.texture = _droplet
	p.color = splash_color
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = clampi(int(0.08 * speed * sqrt(maxf(size_px, 1.0) / 50.0)), 12, 80)
	p.lifetime = clampf(0.0025 * speed, 0.5, 1.4)
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(0.4 * size_px, 2.0)
	p.direction = Vector2(0, -1)
	p.spread = 30.0
	p.initial_velocity_min = 0.25 * minf(speed, 1500.0)
	p.initial_velocity_max = 0.5 * minf(speed, 1500.0)
	p.gravity = Vector2(0, g)
	p.scale_amount_min = 0.3 + size_px / 400.0
	p.scale_amount_max = 0.7 + size_px / 200.0
	p.position = at - global_position
	add_child(p, false, Node.INTERNAL_MODE_BACK)
	p.emitting = true
	_splashes.append([p, 0.0])


func _update_waves() -> void:
	var g := float(ProjectSettings.get_setting("physics/2d/default_gravity"))
	_k1 = TAU / wave_length
	_k2 = TAU / (wave_length * SECOND_LENGTH)
	_w1 = sqrt(g * _k1)   # deep-water waves, in pixel units
	_w2 = sqrt(g * _k2)
	queue_redraw()


func _draw() -> void:
	if not show_water:
		return
	var half := 0.5 * size.x
	var steps := clampi(int(size.x / 8.0), 2, 1000) if wave_height > 0.0 else 1
	var pts := PackedVector2Array()
	for i in steps + 1:
		var x := -half + size.x * i / steps
		pts.append(Vector2(x, height_at(global_position.x + x) - global_position.y))
	var outline := pts.duplicate()
	pts.append(Vector2(half, size.y))
	pts.append(Vector2(-half, size.y))
	draw_colored_polygon(pts, water_color)
	draw_polyline(outline, water_color.darkened(0.25), 2.0)
