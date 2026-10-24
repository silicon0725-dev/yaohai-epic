extends Node

# Ocean singleton (autoload "Ocean", registered by the Ocean3D plugin).
# The single source of truth for wave state.
#
# The same Gerstner wave sum is evaluated in two places:
#   1. Here in GDScript, for physics (FloatingBody probes sample get_height).
#   2. In shaders/ocean.gdshader, for visuals (vertex displacement).
# The OceanSurface node pushes the active wave table and time to the
# shader as uniforms every frame, so both always agree. If you change
# the math here, change the shader too.
#
# One DELIBERATE visual-only divergence: the shader fades displacement
# to zero far from the camera (disp_fade uniforms) so the ocean tiles
# can follow the camera and meet a flat horizon skirt. Physics height
# here never fades; nothing physical should read the surface out there.

const GRAVITY := 9.8

# The active wave table. Assign a different OceanWaveProfile for weather
# changes; see wave_profile.gd for the stability rule. Ships with three
# presets in addons/ocean3d/profiles/: calm, lively, storm.
var profile: OceanWaveProfile = preload("profiles/calm.tres"):
	set(value):
		profile = value
		_warn_if_unstable()

# Storm amplitude multiplier on every wave (1.0 calm up to the profile's
# storm_scale_max at full rage). Drive this from your weather system;
# OceanSurface pushes the same value into the shader's storm_scale
# uniform, so physics and visuals grow the sea together. Scales
# amplitude a = steepness/k linearly; the fold-over guard is
# steepness_sum() * storm_scale staying under about 0.9.
var storm_scale := 1.0:
	set(value):
		storm_scale = value
		_warn_if_unstable()

var time := 0.0

var _stability_warned := false


func _physics_process(delta: float) -> void:
	time += delta


# Raw Gerstner displacement of the resting-plane point (x, z) at the
# current time. Returns the full 3D offset (horizontal shift plus height).
func get_displacement(x: float, z: float) -> Vector3:
	return get_displacement_at(x, z, time)


# Same sum evaluated at an arbitrary time. The wave math here is the
# shader-mirrored math; only the time parameterization is physics-side.
func get_displacement_at(x: float, z: float, at_time: float) -> Vector3:
	var p := Vector3.ZERO
	# Cap at MAX_WAVES: the shader's uniform array is fixed at that
	# size, and physics must never feel a wave the eye cannot see.
	for i in mini(profile.waves.size(), OceanWaveProfile.MAX_WAVES):
		var w := profile.waves[i]
		var dir := Vector2.RIGHT.rotated(deg_to_rad(w.x))
		var steepness: float = w.y
		var k: float = TAU / w.z
		var c: float = sqrt(GRAVITY / k)
		var a: float = steepness * storm_scale / k
		var f: float = k * (dir.dot(Vector2(x, z)) - c * at_time)
		p.x += dir.x * a * cos(f)
		p.y += a * sin(f)
		p.z += dir.y * a * cos(f)
	return p


# Water surface height at a fixed world (x, z).
# Gerstner waves displace points horizontally, so the point that ends up
# above (x, z) started somewhere else. A few fixed-point iterations invert
# that horizontal shift. Three passes is plenty at stable steepness.
func get_height(x: float, z: float) -> float:
	return get_height_at(x, z, time)


func get_height_at(x: float, z: float, at_time: float) -> float:
	var px := x
	var pz := z
	for i in 3:
		var d := get_displacement_at(px, pz, at_time)
		px = x - d.x
		pz = z - d.z
	return get_displacement_at(px, pz, at_time).y


# Vertical velocity of the water surface at (x, z), by finite difference.
# Buoyant bodies damp against this, not against world rest, so they ride
# the surface instead of getting washed over by it. NOTE: FloatingBody
# does its own per-probe height differencing instead of calling this
# (one height sample per probe per tick beats three extra Gerstner
# inversions each); this is the convenience form for one-off queries.
func get_surface_velocity_y(x: float, z: float) -> float:
	const DT := 1.0 / 30.0
	return (get_height_at(x, z, time) - get_height_at(x, z, time - DT)) / DT


# Wave table formatted for the shader uniform.
func waves_for_shader() -> PackedVector3Array:
	return profile.for_shader()


func _warn_if_unstable() -> void:
	if profile == null or profile.is_stable_at(storm_scale):
		_stability_warned = false
		return
	if _stability_warned:
		return
	_stability_warned = true
	push_warning(
		"Ocean3D: steepness_sum (%.2f) * storm_scale (%.2f) >= 0.9; "
		% [profile.steepness_sum(), storm_scale]
		+ "wave crests will fold over and buoyancy sampling gets unstable. "
		+ "Lower the profile's steepness values or the storm scale."
	)
