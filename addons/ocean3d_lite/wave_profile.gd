class_name OceanWaveProfile
extends Resource

# A wave table the Ocean autoload evaluates. Swap profiles at runtime
# for weather changes; the surface reacts instantly, because waves are
# a pure function of position and time, so there is no state to migrate.
#
# One entry per wave: Vector3(direction_degrees, steepness, wavelength_m).
#
# STABILITY RULE: keep steepness_sum() times the highest storm scale you
# plan to reach under about 0.9, or wave crests fold over themselves and
# buoyancy sampling gets unstable. is_stable_at() checks this for you,
# and the Ocean autoload warns if you assign an unstable combination.

# Must match the fixed waves[4] uniform array in shaders/ocean.gdshader;
# the physics loop in ocean.gd caps at the same count, so the
# physics-visual mirror contract holds no matter what a profile holds.
# Entries past MAX_WAVES are ignored EVERYWHERE; for_shader() pads
# short tables with zero-steepness waves (zero contribution on both
# sides, wavelength 1.0 so the shader's k = TAU/wavelength stays
# finite).
const MAX_WAVES := 4

@export var waves: Array[Vector3] = []

# The highest Ocean.storm_scale this profile is designed to reach while
# staying under the fold-over guard. Purely advisory: nothing clamps to
# it, but the stability warning uses it.
@export_range(1.0, 5.0, 0.1) var storm_scale_max := 1.0


func steepness_sum() -> float:
	var s := 0.0
	for i in mini(waves.size(), MAX_WAVES):
		s += waves[i].y
	return s


func is_stable_at(scale: float) -> bool:
	return steepness_sum() * scale < 0.9


# Wave table formatted for the ocean shader uniform: always exactly
# MAX_WAVES entries (truncated or zero-padded, see MAX_WAVES note).
func for_shader() -> PackedVector3Array:
	var arr := PackedVector3Array()
	for i in mini(waves.size(), MAX_WAVES):
		arr.append(waves[i])
	while arr.size() < MAX_WAVES:
		arr.append(Vector3(0.0, 0.0, 1.0))
	return arr
