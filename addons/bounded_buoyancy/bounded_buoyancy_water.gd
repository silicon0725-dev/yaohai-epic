@tool
@icon("res://addons/bounded_buoyancy/icon_water.svg")
class_name BoundedBuoyancyWater
extends Node3D
## A body of water for BoundedBuoyancyBody, with optional waves.
##
## Place the node where the water's surface should be; the water fills a box of `size` below it.
## Once a scene has any BoundedBuoyancyWater, bodies float only inside one, so ponds, pools and
## tanks can sit at different heights. Scenes without one keep using each body's water_level.
##
## Waves move the surface only: bodies rise, fall and rock with them, and nothing is carried along
## by them. The waves are two travelling sine waves with the speeds of real deep-water waves for
## their length. A current makes the water flow: bodies in it drift with it, as in a river.
##
## Other water systems: set surface_source (or height_function from code) and bodies float on that
## system's waves instead, such as an ocean shader's, with this node's size, density and current.
##
## Splashes: when a body hits the water fast enough the node throws up a splash, and every entry
## leaves rings spreading out over the surface. They are for show only and do not move bodies.

## Width (X), depth (Y) and length (Z) of the water, in metres. The top face is the surface.
@export var size: Vector3 = Vector3(10.0, 3.0, 10.0):
	set(value):
		size = value.max(Vector3(0.01, 0.01, 0.01))
		_update_surface()
## The water's density, kg/m³. By default it is real water's, worked out from its temperature, its
## salt and the pressure at each depth (below); setting a density here fixes it at that instead
## (Fixed Density), as earlier versions did. With layers, it is the top water's, at the surface.
@export_range(1.0, 20000.0, 1.0, "or_greater", "suffix:kg/m³") var density: float = 1000.0:
	get:
		return density if fixed_density else _surface_density
	set(value):
		density = value
		fixed_density = true
## Use Density as it is set, the same all through (apart from Density Gradient and any layers),
## instead of real water's.
@export var fixed_density: bool = false:
	set(value):
		fixed_density = value
		notify_property_list_changed()

@export_group("Real Water")
## Temperature of the water near the surface, °C. Warmer water is less dense.
@export_range(-2.0, 40.0, 0.1, "suffix:°C") var temperature: float = 15.0:
	set(value):
		temperature = value
		_update_density()
## Salt in the water, grams per kilogram: 0 for fresh water, about 35 for the open sea, 38 to 40 for
## the Mediterranean and the Red Sea, up to about 270 for the Dead Sea (beyond the formula's 42: the
## density there is less exact).
@export_range(0.0, 42.0, 0.1, "or_greater", "suffix:g/kg") var salinity: float = 0.0:
	set(value):
		salinity = maxf(value, 0.0)
		_update_density()
## Temperature of the deep water, °C, below the thermocline: about 4 in deep lakes and the deep sea.
@export_range(-2.0, 40.0, 0.1, "suffix:°C") var deep_temperature: float = 4.0
## How much saltier the deep water is than the surface's, g/kg (a halocline): a few tenths in the
## open sea, more where a river runs out over the sea.
@export_range(-42.0, 42.0, 0.01, "suffix:g/kg") var deep_salinity_change: float = 0.0
## Depth of the middle of the thermocline (and halocline), where the water changes from the surface's
## to the deep's, in metres; the change takes about as many metres again. 20 to 50 in lakes in
## summer, 100 to 500 in the open sea.
@export_range(0.1, 5000.0, 0.1, "or_greater", "suffix:m") var thermocline_depth: float = 40.0

@export_group("Layers")
## Only with Fixed Density: how much denser the water gets for each metre deeper, kg/m³ per metre.
## Real water's density changes with depth by itself.
@export_range(-1000.0, 1000.0, 0.001, "or_greater", "or_less", "suffix:kg/m³/m") var density_gradient: float = 0.0
## How much harder the top water is to move through than water, as a multiple of each body's drag:
## 1 for water, more for mud.
@export_range(0.0, 10000.0, 0.1, "or_greater") var drag: float = 1.0
## Layers under the top water, each from its depth down to the next: water under oil, brine on the
## bottom, mud (BoundedBuoyancyLayer). Bodies feel the weight of what they displace in each, so they
## settle where their density matches. The boundaries are level: the waves move only the surface.
@export var layers: Array[BoundedBuoyancyLayer] = []:
	set(value):
		for l in layers:
			if l and l.changed.is_connected(_update_layers):
				l.changed.disconnect(_update_layers)
		layers = value
		for l in layers:
			if l and not l.changed.is_connected(_update_layers):
				l.changed.connect(_update_layers)
		_update_layers()
## Draw each layer, tinted with its colour, under the surface.
@export var show_layers: bool = true:
	set(value):
		show_layers = value
		_update_layers()

@export_group("Waves")
## Height of the largest wave above the mean surface, in metres. 0 for still water.
@export_range(0.0, 5.0, 0.001, "or_greater", "suffix:m") var wave_height: float = 0.0:
	set(value):
		wave_height = value
		_update_surface()
## Distance from one crest to the next, in metres.
@export_range(0.05, 200.0, 0.01, "or_greater", "suffix:m") var wave_length: float = 4.0:
	set(value):
		wave_length = maxf(value, 0.01)
		_update_surface()
## Direction the waves travel, in degrees round the vertical (0 = along +X).
@export_range(-180.0, 180.0, 0.1) var wave_direction: float = 0.0:
	set(value):
		wave_direction = value
		_update_surface()

@export_group("Current")
## Velocity of the flowing water in metres per second, in this node's own frame (so turning the node
## turns the river). Bodies are carried along by drag on their speed through the water.
@export var current: Vector3 = Vector3.ZERO:
	set(value):
		current = value
		_update_surface()
## Width of the slower water along each bank, in metres: across the flow, the current falls to zero
## at the sides of the box over this distance. 0 keeps it the same right up to the sides.
@export_range(0.0, 100.0, 0.01, "or_greater", "suffix:m") var current_edge: float = 0.0

@export_group("Splashes")
## Throw up a splash of droplets when a body hits the water fast enough.
@export var splashes: bool = true
## Leave rings spreading over the surface where bodies go in and come out.
@export var ripples: bool = true
## Slowest impact, in metres per second, that throws up a splash (slower ones only leave rings).
@export_range(0.0, 20.0, 0.01, "or_greater", "suffix:m/s") var splash_min_speed: float = 1.5
## Colour of the droplets and rings.
@export var splash_color: Color = Color(0.95, 0.98, 1.0, 0.85)

@export_group("Look")
## Draw a surface that moves with the waves. Turn off to use your own.
@export var show_surface: bool = true:
	set(value):
		show_surface = value
		_update_surface()
## Colour of the water, and how murky it is: with opacity 0.55, things a metre down are seen through
## about half of it; with 0.9, a tenth. Light from below is seen through it, and the sky in it.
@export var surface_color: Color = Color(0.22, 0.52, 0.82, 0.55):
	set(value):
		surface_color = value
		_update_surface()
## Small ripples drawn on the surface, for the eye only: bodies do not feel them. 0 for none.
@export_range(0.0, 2.0, 0.01) var surface_detail: float = 1.0:
	set(value):
		surface_detail = value
		_update_surface()
## Foam drawn where the water meets things, and on the crests of steep waves. 0 for none.
@export_range(0.0, 1.0, 0.01) var foam: float = 0.6:
	set(value):
		foam = value
		_update_surface()

@export_group("Other Water System")
## Optional: float bodies on the waves of another water system, such as an ocean shader or an
## ocean add-on. Pick its node here. It needs a method, named below, that takes a world point
## (Vector3) and returns the height (world Y) of its surface above or below that point. Bodies then
## use that surface; this node's own waves are not used and its surface is not drawn. Size,
## density, current and splashes still come from this node.
@export var surface_source: Node:
	set(value):
		surface_source = value
		_source_call = Callable()
		_warned_source = false
		_update_surface()
## Name of the method on surface_source that gives the height of its surface.
@export var surface_method: StringName = &"height_at":
	set(value):
		surface_method = value
		_source_call = Callable()
		_warned_source = false
		_update_surface()
## The most the other surface rises or falls from its average height, in metres. Set it at least as
## high as the highest crest: bodies further than twice this from the surface are not measured.
@export_range(0.0, 50.0, 0.01, "or_greater", "suffix:m") var surface_max_wave: float = 2.0
## Optional: name of a method on surface_source that takes a world point (Vector3) in the water and
## returns the water's upward acceleration there in its waves (m/s²). With it, bodies are pushed by
## the water's motion and rise and fall as far as the water does, as on this node's own waves;
## without it they are buoyed by the surface alone, and a small raft rises and falls 5 to 15%
## further than the water. For waves made of sines, each wave's part is
## -height * ω² * sin(phase) * exp(k * z), ω its frequency, k its wave number and z the average
## height of the water now at the point: its height above the average level less how far the waves
## have lifted that water, no more than 0 (see mean_height(); the demo's ocean_example.gd has one).
## Bodies ask for the average over their footprint at four points; a method that also takes
## `across` and `along` (world X and Z, metres) is asked once for that average instead.
@export var surface_acceleration_method: StringName = &""

## Set from code instead of surface_source: a Callable that takes a world point (Vector3) and returns
## the height (world Y) of the surface there. Takes priority over surface_source.
var height_function: Callable:
	set(value):
		height_function = value
		_update_surface()

## Set from code with height_function: a Callable that takes a world point (Vector3) in the water and
## returns the water's upward acceleration there (m/s²), as surface_acceleration_method does.
var acceleration_function: Callable

## Wave clock in seconds, advanced with the physics step.
var time: float = 0.0

## Every BoundedBuoyancyWater in the scene tree, for bodies to search quickly.
static var instances: Array[Node3D] = []
## The world this water is in; bodies only use water in their own world.
var world: World3D

const GROUP := "bounded_buoyancy_water"
const SECOND_LENGTH := 0.63     # second wave: shorter,
const SECOND_TURN := 35.0       # turned this many degrees,
const SECOND_HEIGHT := 0.4      # and this fraction of the height
const SHADER_CODE := """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, specular_schlick_ggx;
uniform vec4 color : source_color;
uniform float amp;
uniform float geo;
uniform vec2 k1;
uniform vec2 k2;
uniform float w1;
uniform float w2;
uniform float t;
uniform vec2 flow;
uniform float detail;
uniform float foam;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear, repeat_disable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
varying vec2 pxz;
float h(vec2 p) {
	return amp * sin(dot(k1, p) - w1 * t) + 0.4 * amp * sin(dot(k2, p) - w2 * t + 1.3);
}
vec2 dh(vec2 p) {
	return amp * k1 * cos(dot(k1, p) - w1 * t) + 0.4 * amp * k2 * cos(dot(k2, p) - w2 * t + 1.3);
}
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
// The slope of small ripples, for the eye only: short waves at spread headings, each travelling as a
// deep-water wave of its length does.
vec2 ripples(vec2 p) {
	vec2 g = vec2(0.0);
	float len = 0.3;
	for (int i = 0; i < 12; i++) {
		float a = float(i) * 2.39996 + 0.5 + 0.3 * sin(float(i) * 7.1);
		vec2 d = vec2(cos(a), sin(a));
		float k = 6.2831853 / len;
		g += d * (0.03 * cos(k * dot(d, p - flow * t) - sqrt(9.81 * k) * t + float(i) * 1.7));
		len *= 1.27;
	}
	// Patchy, as a breeze ruffles the water more in some places than others.
	float patch = 0.45 + 1.1 * noise(p * 0.035 + vec2(t * 0.02, -t * 0.013));
	return g * patch;
}
// How far from the camera what lies behind this pixel is, along the view.
float behind(vec2 uv, mat4 inv_projection) {
	float raw = texture(depth_tex, uv).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(uv, raw) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(uv * 2.0 - 1.0, raw);
#endif
	vec4 v = inv_projection * vec4(ndc, 1.0);
	return -v.z / v.w;
}
void vertex() {
	pxz = VERTEX.xz;
	VERTEX.y += geo * h(VERTEX.xz);
}
void fragment() {
	float far = length(VERTEX);
	vec2 g = dh(pxz) + detail * exp(-far / 70.0) * ripples(pxz);
	vec3 n = normalize(vec3(-g.x, 1.0, -g.y));
	NORMAL = normalize((VIEW_MATRIX * (MODEL_MATRIX * vec4(n, 0.0))).xyz);
	// Seen from under the water, light from above comes through only within Snell's window, 48.6°
	// of straight up (water's refractive index 1.33); further over, the surface is a mirror of the
	// dim water below.
	float window = 1.0;
	if (!FRONT_FACING) {
		float c = clamp(dot(-VIEW, NORMAL), 0.0, 1.0);
		window = 0.9 * smoothstep(0.77, 0.72, sqrt(1.0 - c * c));
		NORMAL = -NORMAL;
	}
	// The water between the surface and what lies behind it: light from there comes through, less the
	// deeper it is, bent a little by the ripples.
	float here = -VERTEX.z;
	float thick = max(behind(SCREEN_UV, INV_PROJECTION_MATRIX) - here, 0.0);
	vec2 uv = SCREEN_UV + g * 0.06 * min(thick, 1.0);
	if (behind(uv, INV_PROJECTION_MATRIX) < here) {
		uv = SCREEN_UV;   // something in front of the water: no bending
	}
	float murk = -log(max(1.0 - color.a, 0.01));
	float through = FRONT_FACING ? exp(-murk * thick) : window;
	vec3 below = textureLod(screen_tex, uv, 0.0).rgb;
	// Foam where the water meets something, and on the crests of steep waves.
	float pattern = 0.6 * noise(pxz * 2.7 + vec2(t * 0.25, 0.0)) + 0.4 * noise(pxz * 6.3 - vec2(0.0, t * 0.2));
	float edge = (1.0 - smoothstep(0.0, 0.45, thick)) * step(0.001, thick);
	float steep = amp * length(k1);
	float crest = smoothstep(0.1, 0.2, steep) * smoothstep(0.7, 1.0, h(pxz) / max(amp, 1e-4));
	float f = foam * max(smoothstep(0.45, 0.75, edge * (0.55 + pattern)), 0.7 * crest * smoothstep(0.55, 0.85, pattern));
	float shade = 0.0;
	float speed = length(flow);
	if (speed > 0.0) {
		// Faint streaks carried downstream, so the flow can be seen.
		vec2 dir = flow / speed;
		float along = dot(pxz - flow * t, dir);
		float across = dot(pxz, vec2(-dir.y, dir.x));
		shade = 0.08 * sin(along * 2.5 + 1.5 * sin(across * 1.3)) * sin(along * 0.6 + across * 0.8);
	}
	vec3 water = color.rgb * (1.0 + shade);
	ALBEDO = mix(water * (1.0 - through), vec3(0.9, 0.93, 0.95), f);
	EMISSION = below * through * (1.0 - f);
	ROUGHNESS = mix(0.03, 0.85, f);
	SPECULAR = 0.5;
	ALPHA = 1.0;
}
"""

var _mesh_instance: MeshInstance3D
var _material: ShaderMaterial
var _k1 := Vector2.ZERO
var _k2 := Vector2.ZERO
var _w1 := 0.0
var _w2 := 0.0
var _inv := Transform3D.IDENTITY
var _kw := Vector4.ZERO                 # wave vectors in world X and Z (first wave x, z, second wave x, z)
var _k1_len := 0.0
var _level := 0.0                       # height of the water's middle (its average level), this frame
var _k2_len := 0.0
var _inv_frame := -1
var _params := PackedFloat64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1.0])
var _params_frame := -1
var _source_call := Callable()
var _warned_source := false
var _splashes: Array = []     # [CPUParticles3D, age]
var _ripples: Array = []      # [MeshInstance3D, ShaderMaterial, age, start radius, strength]
var _droplet_mesh: QuadMesh
var _droplet_material: StandardMaterial3D
var _droplet_fade: Gradient
var _ripple_shader: Shader

const MAX_SPLASHES := 32
const MAX_RIPPLES := 48
const RIPPLE_LIFE := 1.8
const RIPPLE_SPEED := 0.9     # m/s, how fast the rings spread
const RIPPLE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;
uniform vec4 color : source_color;
uniform float radius;
uniform float width;
uniform float strength;
uniform vec2 origin;
uniform float amp;
uniform vec2 k1;
uniform vec2 k2;
uniform float w1;
uniform float w2;
uniform float t;
varying vec2 lp;
float h(vec2 p) {
	return amp * sin(dot(k1, p) - w1 * t) + 0.4 * amp * sin(dot(k2, p) - w2 * t + 1.3);
}
void vertex() {
	lp = VERTEX.xz;
	VERTEX.y += h(origin + VERTEX.xz) + 0.006;
}
void fragment() {
	float d = length(lp);
	float outer = 1.0 - smoothstep(0.0, width, abs(d - radius));
	float inner = 1.0 - smoothstep(0.0, width, abs(d - 0.62 * radius));
	ALBEDO = color.rgb;
	ALPHA = color.a * strength * max(outer, 0.6 * inner);
}
"""


func _enter_tree() -> void:
	add_to_group(GROUP)
	world = get_world_3d()
	# Advance the wave clock before the bodies use it, whatever the order of the scene tree.
	process_physics_priority = -1000
	if not instances.has(self):
		instances.append(self)


func _exit_tree() -> void:
	instances.erase(self)


func _ready() -> void:
	_update_density()
	_update_surface()
	_update_layers()


var _surface_density := seawater_density(0.0, 15.0, 0.0)


func _validate_property(property: Dictionary) -> void:
	# Real water's density is shown but not saved, so that saving a scene does not fix it.
	if property.name == "density" and not fixed_density:
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
	elif property.name == "density_gradient" and not fixed_density:
		property.usage = PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_STORAGE


func _update_density() -> void:
	_surface_density = seawater_density(salinity, temperature, 0.0)


## True when the water's density or drag is not the same all through: real water, layers, a density
## gradient or a drag other than 1. Bodies then ask it for the density where they are.
func is_layered() -> bool:
	return not fixed_density or not layers.is_empty() or density_gradient != 0.0 or drag != 1.0


## Temperature (°C) and salinity (g/kg) of the top water at `depth` metres: the surface's above the
## thermocline, the deep water's below it, changing smoothly across it.
func water_at(depth: float) -> Vector2:
	var d := maxf(depth, 0.0)
	var deep := 0.5 * (1.0 + tanh((d - thermocline_depth) / (0.5 * thermocline_depth)))
	var start := 0.5 * (1.0 + tanh(-2.0))   # the same at the surface, so the surface has exactly its own
	var f := clampf((deep - start) / (1.0 - start), 0.0, 1.0)
	return Vector2(lerpf(temperature, deep_temperature, f), salinity + deep_salinity_change * f)


## Density of sea water (or fresh, salinity 0), kg/m³, at `salinity` g/kg, `temperature` °C and
## `pressure` bar above the air's: the UNESCO equation of state (EOS-80; Millero and Poisson, 1981,
## with the secant bulk modulus of Millero and others, 1980), valid from -2 to 40 °C, 0 to 42 g/kg
## and 0 to 1000 bar.
static func seawater_density(salinity_gkg: float, temperature_c: float, pressure_bar: float) -> float:
	var t := temperature_c
	var sv := salinity_gkg
	var s15 := sv * sqrt(sv)
	var rw := 999.842594 + t * (6.793952e-2 + t * (-9.095290e-3 + t * (1.001685e-4 + t * (-1.120083e-6 + t * 6.536332e-9))))
	var r0 := rw + sv * (0.824493 + t * (-4.0899e-3 + t * (7.6438e-5 + t * (-8.2467e-7 + t * 5.3875e-9)))) \
		+ s15 * (-5.72466e-3 + t * (1.0227e-4 - t * 1.6546e-6)) + 4.8314e-4 * sv * sv
	if pressure_bar <= 0.0:
		return r0
	var kw := 19652.21 + t * (148.4206 + t * (-2.327105 + t * (1.360477e-2 - t * 5.155288e-5)))
	var k0 := kw + sv * (54.6746 + t * (-0.603459 + t * (1.09987e-2 - t * 6.1670e-5))) + s15 * (7.944e-2 + t * (1.6483e-2 - t * 5.3009e-4))
	var a := 3.239908 + t * (1.43713e-3 + t * (1.16092e-4 - t * 5.77905e-7)) + sv * (2.2838e-3 + t * (-1.0981e-5 - t * 1.6078e-6)) + 1.91075e-4 * s15
	var b := 8.50935e-5 + t * (-6.12293e-6 + t * 5.2787e-8) + sv * (-9.9348e-7 + t * (2.0816e-8 + t * 9.1697e-10))
	var p := pressure_bar
	return r0 / (1.0 - p / (k0 + a * p + b * p * p))


## The water from the top down: for the top water and each layer, an Array [height of its top
## (world Y), its density there, its density gradient, its drag], in order of depth. Each runs down
## to the next one's top. The top water's top is the node's height (the mean surface).
func strata() -> Array:
	var top := global_position.y
	var out: Array = [[top, density, density_gradient, drag]]
	var sorted: Array = []
	for l in layers:
		if l:
			sorted.append(l)
	sorted.sort_custom(func(a: BoundedBuoyancyLayer, b: BoundedBuoyancyLayer) -> bool: return a.depth < b.depth)
	for l in sorted:
		out.append([top - minf(l.depth, size.y), l.density, l.density_gradient, l.drag])
	return out


## Density of the water at the world point `p`, kg/m³: real water's at its temperature, salt and
## pressure there, or the layer it is in and how far down that layer it is. Above the surface, the
## top water's at the surface.
func density_at(p: Vector3) -> float:
	if not is_layered():
		return density
	var top := global_position.y
	var depth := maxf(top - p.y, 0.0)
	var s := strata()
	var here: Array = s[0]
	for st in s:
		if p.y <= st[0]:
			here = st
	if here != s[0] or fixed_density:
		return here[1] + here[2] * maxf(here[0] - p.y, 0.0)
	var ts := water_at(depth)
	# The pressure of the water above, in bar; its density for that, the surface's, is near enough.
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	return seawater_density(ts.y, ts.x, _surface_density * g * depth * 1e-5)


var _layer_nodes: Array = []


## Draw the layers as tinted slabs, each from its top to the next one's (or the bottom).
func _update_layers() -> void:
	if not is_inside_tree():
		return
	for n in _layer_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_layer_nodes.clear()
	if not show_layers or layers.is_empty():
		return
	var s := strata()
	var bottom := global_position.y - size.y
	var sorted: Array = []
	for l in layers:
		if l:
			sorted.append(l)
	sorted.sort_custom(func(a: BoundedBuoyancyLayer, b: BoundedBuoyancyLayer) -> bool: return a.depth < b.depth)
	for i in sorted.size():
		var top: float = s[i + 1][0]
		var low: float = s[i + 2][0] if i + 2 < s.size() else bottom
		if top - low < 1e-4:
			continue
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(size.x, top - low, size.z)
		mi.mesh = box
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		m.albedo_color = sorted[i].color
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(0.0, 0.5 * (top + low) - global_position.y, 0.0)
		add_child(mi, false, Node.INTERNAL_MODE_BACK)
		_layer_nodes.append(mi)


func _physics_process(dt: float) -> void:
	if not Engine.is_editor_hint():
		time += dt


func _process(dt: float) -> void:
	if _material:
		_material.set_shader_parameter("t", time)
	_age_effects(dt)


## Height of the water surface (world Y) above or below the world point `p`.
func height_at(p: Vector3) -> float:
	var outside := outside_height()
	if outside.is_valid():
		return float(outside.call(p))
	var y := global_position.y
	if wave_height <= 0.0:
		return y
	var l := _inverse() * p
	var xz := Vector2(l.x, l.z)
	return y + wave_height * (sin(_k1.dot(xz) - _w1 * time) + SECOND_HEIGHT * sin(_k2.dot(xz) - _w2 * time + 1.3))


## Upward acceleration of the water in the waves at the world point `p` (m/s²): from this node's
## waves, or from the other water system if it gives one, else 0. For each wave, minus its height x
## its frequency² x the sine of its phase, dying away with depth as exp(k z), z the average height of
## the water that is at `p` now (mean_height). Water under a crest is slowing as it rises, so it
## accelerates downwards. With `across` and `along` (world X and Z, m), averaged over that footprint
## centred on p, at the four points that average a uniform rectangle exactly for anything varying no
## faster than a cubic (two-point Gauss-Legendre each way); for this node's waves, each wave's part is
## then multiplied by cos(kx hx) cos(kz hz), hx and hz the points' offsets.
func vertical_acceleration_at(p: Vector3, across := 0.0, along := 0.0) -> float:
	var hx := across * 0.28867513459481287   # 1 / (2 sqrt 3)
	var hz := along * 0.28867513459481287
	if (height_function.is_valid() or surface_source != null) and outside_height().is_valid():
		var call := acceleration_function
		if not call.is_valid() and not height_function.is_valid() and surface_acceleration_method != &"" \
				and surface_source != null and is_instance_valid(surface_source) and surface_source.has_method(surface_acceleration_method):
			call = Callable(surface_source, surface_acceleration_method)
		if not call.is_valid():
			return 0.0
		if hx == 0.0 and hz == 0.0:
			return float(call.call(p))
		if call.get_argument_count() >= 3:   # it averages a footprint itself
			return float(call.call(p, across, along))
		return 0.25 * (float(call.call(p + Vector3(-hx, 0.0, -hz))) + float(call.call(p + Vector3(hx, 0.0, -hz)))
			+ float(call.call(p + Vector3(-hx, 0.0, hz))) + float(call.call(p + Vector3(hx, 0.0, hz))))
	if wave_height <= 0.0:
		return 0.0
	var inv := _inverse()
	var l := inv * p
	var h1 := wave_height * sin(_k1.x * l.x + _k1.y * l.z - _w1 * time)
	var h2 := wave_height * SECOND_HEIGHT * sin(_k2.x * l.x + _k2.y * l.z - _w2 * time + 1.3)
	# The average height of the water now at p (mean_height, two steps of Newton's method inline).
	var y := p.y - _level
	var z := minf(y - h1 - h2, 0.0)
	for i in 2:
		var e1 := h1 * exp(_k1_len * z)
		var e2 := h2 * exp(_k2_len * z)
		z = minf(z - (z - y + e1 + e2) / maxf(1.0 + _k1_len * e1 + _k2_len * e2, 0.2), 0.0)
	var a1 := _w1 * _w1 * h1 * exp(_k1_len * z)
	var a2 := _w2 * _w2 * h2 * exp(_k2_len * z)
	if hx != 0.0 or hz != 0.0:
		a1 *= cos(_kw.x * hx) * cos(_kw.y * hz)
		a2 *= cos(_kw.z * hx) * cos(_kw.w * hz)
	return -(a1 + a2)


## The average height z (no more than 0) of the water that is `y` metres above the average level now,
## where the waves have lifted the surface there by h1 + h2 (the two waves' parts; k1 and k2 their
## wave numbers): water at average height z is lifted by h exp(k z), so z solves
## z = y - h1 exp(k1 z) - h2 exp(k2 z), by Newton's method. A body under the water that moves with
## it keeps the same z, so it feels the same strength of wave as the water round it.
static func mean_height(y: float, h1: float, k1: float, h2: float, k2: float) -> float:
	var z := minf(y - h1 - h2, 0.0)
	for i in 2:   # two steps of Newton's method: well under a millimetre for waves that do not break
		var e1 := h1 * exp(k1 * z)
		var e2 := h2 * exp(k2 * z)
		z = minf(z - (z - y + e1 + e2) / maxf(1.0 + k1 * e1 + k2 * e2, 0.2), 0.0)
	return z


## Velocity of the water at the world point `p` (world frame), slowing towards the banks if current_edge is set.
func current_at(p: Vector3) -> Vector3:
	if current == Vector3.ZERO:
		return Vector3.ZERO
	var f := 1.0
	if current_edge > 0.0:
		var flat := Vector2(current.x, current.z)
		if flat.length_squared() > 0.0:
			var across := Vector2(-flat.y, flat.x).normalized()
			var l := _inverse() * p
			var half := 0.5 * (absf(across.x) * size.x + absf(across.y) * size.z)
			f = clampf((half - absf(across.dot(Vector2(l.x, l.z)))) / current_edge, 0.0, 1.0)
	return global_transform.basis * (current * f)


## Throw up a splash and rings at the world point `at`, for a body of size `size` (metres across)
## hitting the water at `speed`. Bodies call this themselves; call it to make a splash of your own.
func splash(at: Vector3, speed: float, size: float) -> void:
	if not is_inside_tree() or Engine.is_editor_hint():
		return
	size = clampf(size, 0.02, 20.0)
	var l := to_local(at)
	if ripples and speed > 0.05:
		_add_ripple(l, size, clampf(speed / 3.0, 0.25, 1.0))
	if splashes and speed >= splash_min_speed:
		_add_splash(l, speed, size)


func _add_splash(l: Vector3, speed: float, size: float) -> void:
	if _splashes.size() >= MAX_SPLASHES:
		var old: Array = _splashes.pop_front()
		old[0].queue_free()
	if _droplet_mesh == null:
		# Soft round droplets that face the camera and fade as they fall.
		_droplet_mesh = QuadMesh.new()
		var dot := GradientTexture2D.new()
		dot.width = 32
		dot.height = 32
		dot.fill = GradientTexture2D.FILL_RADIAL
		dot.fill_from = Vector2(0.5, 0.5)
		dot.fill_to = Vector2(1.0, 0.5)
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.7), Color(1, 1, 1, 0)])
		dot.gradient = g
		_droplet_material = StandardMaterial3D.new()
		_droplet_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_droplet_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_droplet_material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		_droplet_material.billboard_keep_scale = true
		_droplet_material.albedo_texture = dot
		_droplet_material.vertex_color_use_as_albedo = true
		_droplet_material.render_priority = 10
		_droplet_fade = Gradient.new()
		_droplet_fade.offsets = PackedFloat32Array([0.0, 0.7, 1.0])
		_droplet_fade.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.8), Color(1, 1, 1, 0)])
	_droplet_material.albedo_color = splash_color
	var p := CPUParticles3D.new()
	p.mesh = _droplet_mesh
	p.material_override = _droplet_material
	p.color_ramp = _droplet_fade
	p.angle_min = -180.0
	p.angle_max = 180.0
	p.one_shot = true
	p.explosiveness = 0.95
	p.lifetime = clampf(0.25 * sqrt(speed), 0.5, 1.4)
	p.amount = clampi(int(14.0 * speed * sqrt(size)), 16, 120)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	p.emission_ring_axis = Vector3.UP
	p.emission_ring_radius = 0.45 * size
	p.emission_ring_inner_radius = 0.3 * size
	p.emission_ring_height = 0.0
	p.direction = Vector3.UP
	p.spread = 28.0
	var up := minf(0.45 * speed, 7.0)
	p.initial_velocity_min = 0.5 * up
	p.initial_velocity_max = up
	p.gravity = Vector3(0, -float(ProjectSettings.get_setting("physics/3d/default_gravity")), 0)
	var drop := clampf(size, 0.1, 3.0)
	p.scale_amount_min = 0.05 + 0.04 * drop
	p.scale_amount_max = 0.1 + 0.08 * drop
	p.position = Vector3(l.x, l.y + 0.02, l.z)
	add_child(p, false, Node.INTERNAL_MODE_BACK)
	p.emitting = true
	_splashes.append([p, 0.0])


func _add_ripple(l: Vector3, size: float, strength: float) -> void:
	if _ripples.size() >= MAX_RIPPLES:
		var old: Array = _ripples.pop_front()
		old[0].queue_free()
	if _ripple_shader == null:
		_ripple_shader = Shader.new()
		_ripple_shader.code = RIPPLE_SHADER
	var reach := 0.5 * size + RIPPLE_SPEED * RIPPLE_LIFE
	var plane := PlaneMesh.new()
	plane.size = Vector2(2.0 * reach, 2.0 * reach)
	plane.subdivide_width = 12
	plane.subdivide_depth = 12
	var mat := ShaderMaterial.new()
	mat.shader = _ripple_shader
	mat.set_shader_parameter("color", splash_color)
	mat.set_shader_parameter("width", clampf(0.06 * size, 0.02, 0.3))
	mat.set_shader_parameter("origin", Vector2(l.x, l.z))
	var outside := outside_height().is_valid()
	mat.set_shader_parameter("amp", 0.0 if outside else wave_height)
	mat.set_shader_parameter("k1", _k1)
	mat.set_shader_parameter("k2", _k2)
	mat.set_shader_parameter("w1", _w1)
	mat.set_shader_parameter("w2", _w2)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(l.x, 0.0, l.z)
	if outside:
		# Another water system's surface: the rings ride on it at their centre.
		mi.position.y = height_at(to_global(mi.position)) - global_position.y
	add_child(mi, false, Node.INTERNAL_MODE_BACK)
	_ripples.append([mi, mat, 0.0, 0.5 * size, strength])


func _age_effects(dt: float) -> void:
	var i := 0
	while i < _splashes.size():
		var e: Array = _splashes[i]
		e[1] += dt
		if e[1] > e[0].lifetime + 0.2:
			e[0].queue_free()
			_splashes.remove_at(i)
		else:
			i += 1
	i = 0
	var outside := not _ripples.is_empty() and outside_height().is_valid()
	while i < _ripples.size():
		var r: Array = _ripples[i]
		r[2] += dt
		if r[2] >= RIPPLE_LIFE:
			r[0].queue_free()
			_ripples.remove_at(i)
			continue
		var mat: ShaderMaterial = r[1]
		if outside:
			var mi: MeshInstance3D = r[0]
			mi.position.y = height_at(to_global(Vector3(mi.position.x, 0.0, mi.position.z))) - global_position.y
		mat.set_shader_parameter("radius", r[3] + RIPPLE_SPEED * r[2])
		mat.set_shader_parameter("strength", r[4] * (1.0 - r[2] / RIPPLE_LIFE))
		mat.set_shader_parameter("t", time)
		i += 1


## The most the surface rises or falls from its mean height.
func max_wave() -> float:
	if outside_height().is_valid():
		return surface_max_wave
	return wave_height * (1.0 + SECOND_HEIGHT)


## Whether another water system's surface is used (so this node's own surface is not drawn). In the
## editor, whether one is set, since its script may not run there.
func _has_outside_surface() -> bool:
	if not Engine.is_editor_hint():
		return outside_height().is_valid()
	return height_function.is_valid() or (surface_source != null and is_instance_valid(surface_source) and surface_source != self)


## Whether the surface moves: this node's own waves, or another water system's surface.
func is_wavy() -> bool:
	return wave_height > 0.0 or outside_height().is_valid()


## The height function of another water system (height_function, or surface_method on
## surface_source), or an empty Callable when this node's own surface is used.
func outside_height() -> Callable:
	if height_function.is_valid():
		return height_function
	if surface_source == null:
		return Callable()
	if not is_instance_valid(surface_source) or surface_source == self:
		return Callable()
	if not _source_call.is_valid() or _source_call.get_object() != surface_source:
		if not surface_source.has_method(surface_method):
			if not _warned_source and not Engine.is_editor_hint():
				_warned_source = true
				push_warning("BoundedBuoyancyWater '%s': surface_source '%s' has no method '%s'; using this node's own surface." % [name, surface_source.name, surface_method])
			return Callable()
		_source_call = Callable(surface_source, surface_method)
	return _source_call


## Whether the world point `p` lies over or in the water: inside it horizontally and above its floor.
func contains(p: Vector3) -> bool:
	var l := _inverse() * p
	return absf(l.x) <= 0.5 * size.x and absf(l.z) <= 0.5 * size.z and l.y >= -size.y


## The waves as numbers, for the native kernel: [surface height, height, k1 (x, z), k2 (x, z),
## w1, w2, second height, second phase, time], and the map from world points to the water's frame.
func wave_params() -> PackedFloat64Array:
	var frame := Engine.get_physics_frames()
	if frame != _params_frame or _params[10] != time:
		_params = PackedFloat64Array([global_position.y, wave_height, _k1.x, _k1.y, _k2.x, _k2.y, _w1, _w2, SECOND_HEIGHT, 1.3, time])
		_params_frame = frame
	return _params


func inverse_transform() -> Transform3D:
	return _inverse()


func _inverse() -> Transform3D:
	var frame := Engine.get_physics_frames()
	if frame != _inv_frame:
		var xf := global_transform
		_inv = xf.affine_inverse()
		_inv_frame = frame
		_level = xf.origin.y
		# The waves' wave vectors in world X and Z, for averaging over a footprint.
		var b := xf.basis.orthonormalized()
		var kw1 := b * Vector3(_k1.x, 0.0, _k1.y)
		var kw2 := b * Vector3(_k2.x, 0.0, _k2.y)
		_kw = Vector4(kw1.x, kw1.z, kw2.x, kw2.z)
	return _inv


## Wave numbers and frequencies, worked out once whenever a wave setting changes.
func _update_waves() -> void:
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	var a1 := deg_to_rad(wave_direction)
	var a2 := deg_to_rad(wave_direction + SECOND_TURN)
	var n1 := TAU / wave_length
	var n2 := TAU / (wave_length * SECOND_LENGTH)
	_k1 = Vector2(cos(a1), sin(a1)) * n1
	_k2 = Vector2(cos(a2), sin(a2)) * n2
	_k1_len = n1
	_k2_len = n2
	_inv_frame = -1
	_w1 = sqrt(g * n1)   # deep-water waves: frequency = sqrt(g x wave number)
	_w2 = sqrt(g * n2)


func _update_surface() -> void:
	_update_waves()
	if not is_inside_tree():
		return
	if not show_surface or _has_outside_surface():
		if _mesh_instance:
			_mesh_instance.queue_free()
			_mesh_instance = null
			_material = null
		return
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mesh_instance, false, Node.INTERNAL_MODE_BACK)
		_material = ShaderMaterial.new()
		var sh := Shader.new()
		sh.code = SHADER_CODE
		_material.shader = sh
	var plane := PlaneMesh.new()
	plane.size = Vector2(size.x, size.z)
	var cells := 1 if wave_height <= 0.0 else clampi(int(maxf(size.x, size.z) / (wave_length / 16.0)), 1, 256)
	plane.subdivide_width = cells
	plane.subdivide_depth = cells
	plane.material = _material
	_mesh_instance.mesh = plane
	_material.set_shader_parameter("color", surface_color)
	_material.set_shader_parameter("amp", wave_height)
	# The mesh shows the waves only if its cells are short enough; otherwise it stays flat and the
	# light shows them.
	var cell := maxf(size.x, size.z) / float(cells)
	_material.set_shader_parameter("geo", clampf(wave_length / (6.0 * cell) - 0.5, 0.0, 1.0))
	_material.set_shader_parameter("detail", surface_detail)
	_material.set_shader_parameter("foam", foam)
	_material.set_shader_parameter("k1", _k1)
	_material.set_shader_parameter("k2", _k2)
	_material.set_shader_parameter("w1", _w1)
	_material.set_shader_parameter("w2", _w2)
	_material.set_shader_parameter("t", time)
	_material.set_shader_parameter("flow", Vector2(current.x, current.z))
