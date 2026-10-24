extends MeshInstance3D
## An example of another water system: an ocean drawn by its own shader, as an ocean add-on or a
## shader of your own would be. Bounded Buoyancy knows nothing about it except get_height(), which
## works out the same waves on the CPU from the same numbers the shader uses.
##
## To float bodies on your own ocean: give it a function like get_height() below that returns the
## height of its surface at a world point, add a BoundedBuoyancyWater over it, and set the water's
## surface_source to your ocean's node and surface_method to the function's name. If you can, give
## it get_vertical_acceleration() too and set surface_acceleration_method to its name, so the water's
## motion in the waves pushes the bodies as well.

## The waves, each as (height in m, length crest to crest in m, direction in degrees, phase).
@export var waves: Array[Vector4] = [
	Vector4(0.045, 3.1, 10.0, 0.0),
	Vector4(0.030, 1.9, -35.0, 1.7),
	Vector4(0.018, 1.1, 60.0, 4.1),
	Vector4(0.010, 0.7, 150.0, 2.3),
]
## All the wave heights times this: 1 for a moderate sea, 2 for a rough one.
@export_range(0.0, 3.0, 0.01) var roughness: float = 1.0:
	set(value):
		roughness = value
		_send_waves()
## Size of the drawn sea, in metres.
@export var extent := Vector2(24.0, 24.0)

## Wave clock in seconds, advanced with the physics step.
var time := 0.0

var _k: Array[Vector2] = []     # wave vector of each wave (direction x 2 pi / length)
var _w: Array[float] = []       # frequency of each wave
var _a: Array[float] = []       # height of each wave
var _p: Array[float] = []       # phase of each wave
var _material: ShaderMaterial
var _lifts := PackedFloat64Array()   # each wave's lift at the point asked about

const SHADER := """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, specular_schlick_ggx;
uniform vec4 deep : source_color = vec4(0.05, 0.27, 0.42, 0.92);
uniform vec4 crest : source_color = vec4(0.62, 0.82, 0.88, 0.92);
uniform vec4 k_and_w[4];   // wave vector (x, z), frequency, phase
uniform float amp[4];
uniform float t;
uniform float top;
varying float lift;
float h(vec2 p) {
	float s = 0.0;
	for (int i = 0; i < 4; i++) {
		s += amp[i] * sin(dot(k_and_w[i].xy, p) - k_and_w[i].z * t + k_and_w[i].w);
	}
	return s;
}
void vertex() {
	vec2 p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	lift = h(p);
	VERTEX.y += lift;
	float e = 0.03;
	vec3 dx = vec3(2.0 * e, h(p + vec2(e, 0.0)) - h(p - vec2(e, 0.0)), 0.0);
	vec3 dz = vec3(0.0, h(p + vec2(0.0, e)) - h(p - vec2(0.0, e)), 2.0 * e);
	NORMAL = normalize(cross(dz, dx));
}
void fragment() {
	float c = smoothstep(0.35, 1.0, lift / max(top, 1e-4));
	vec4 col = mix(deep, crest, c);
	ALBEDO = col.rgb;
	ALPHA = col.a;
	ROUGHNESS = 0.08;
	SPECULAR = 0.6;
}
"""


func _ready() -> void:
	# Move the waves before the bodies measure them in each physics step.
	process_physics_priority = -1000
	var plane := PlaneMesh.new()
	plane.size = extent
	plane.subdivide_width = int(extent.x * 8.0)
	plane.subdivide_depth = int(extent.y * 8.0)
	mesh = plane
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SHADER
	_material.shader = sh
	material_override = _material
	_send_waves()


func _physics_process(dt: float) -> void:
	time += dt


func _process(_dt: float) -> void:
	if _material:
		_material.set_shader_parameter("t", time)


## Height (world Y) of this ocean's surface at the world point `p`: the same sum of waves as the
## shader draws. This is the function Bounded Buoyancy asks.
func get_height(p: Vector3) -> float:
	var s := 0.0
	var xz := Vector2(p.x, p.z)
	for i in _k.size():
		s += _a[i] * sin(_k[i].dot(xz) - _w[i] * time + _p[i])
	return global_position.y + s


## Upward acceleration (m/s²) of the water at the world point `p`: for each wave, -height x
## frequency² x the sine of its phase, dying away as exp(k z) with z the average height of the water
## now at `p` (below a crest the water is lifted, so z is p's height less that lift). Bounded Buoyancy
## asks this too (surface_acceleration_method), so bodies are pushed by the water's motion.
func get_vertical_acceleration(p: Vector3) -> float:
	var xz := Vector2(p.x, p.z)
	_lifts.resize(_k.size())
	for i in _k.size():
		_lifts[i] = _a[i] * sin(_k[i].dot(xz) - _w[i] * time + _p[i])
	# z solves z = y - (sum of lift x exp(k z)): a few steps of Newton's method.
	var y := p.y - global_position.y
	var z := y
	for lift in _lifts:
		z -= lift
	z = minf(z, 0.0)
	for n in 4:
		var f := z - y
		var slope := 1.0
		for i in _k.size():
			var e: float = _lifts[i] * exp(_k[i].length() * z)
			f += e
			slope += _k[i].length() * e
		z = minf(z - f / maxf(slope, 0.2), 0.0)
	var s := 0.0
	for i in _k.size():
		s -= _w[i] * _w[i] * _lifts[i] * exp(_k[i].length() * z)
	return s


## The most the surface rises above (or falls below) its average height.
func max_wave() -> float:
	var s := 0.0
	for a in _a:
		s += a
	return s


func _send_waves() -> void:
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	_k.clear()
	_w.clear()
	_a.clear()
	_p.clear()
	var kw := PackedVector4Array()
	var amps := PackedFloat32Array()
	for v in waves.slice(0, 4):
		var n := TAU / maxf(v.y, 0.01)
		var dir := Vector2(cos(deg_to_rad(v.z)), sin(deg_to_rad(v.z)))
		_k.append(dir * n)
		_w.append(sqrt(g * n))   # deep-water waves: frequency = sqrt(g x wave number)
		_a.append(v.x * roughness)
		_p.append(v.w)
		kw.append(Vector4(dir.x * n, dir.y * n, sqrt(g * n), v.w))
		amps.append(v.x * roughness)
	while kw.size() < 4:
		kw.append(Vector4.ZERO)
		amps.append(0.0)
	if _material:
		_material.set_shader_parameter("k_and_w", kw)
		_material.set_shader_parameter("amp", amps)
		_material.set_shader_parameter("top", max_wave())
