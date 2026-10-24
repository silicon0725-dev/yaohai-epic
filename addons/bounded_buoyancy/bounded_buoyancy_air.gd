@tool
@icon("res://addons/bounded_buoyancy/icon_air.svg")
class_name BoundedBuoyancyAir
extends Node3D
## The air of a world: the real atmosphere, for every BoundedBuoyancyBody in it.
##
## Place the node at sea level and set the day's weather at sea level: its temperature, pressure and
## humidity. The air's density at every height then follows the standard atmosphere (the US
## Standard Atmosphere, 1976, the same as the International Standard Atmosphere to 32 km): its
## temperature falls 6.5 °C for each kilometre up to 11 km and stays the same above, and its
## pressure falls with the weight of the air above. Damp air is less dense than dry, as water
## vapour is lighter than the air it replaces. Warm and cold places in the air (BoundedBuoyancyThermal)
## change its temperature there, and so its density.
##
## Without one, bodies use the standard atmosphere at 15 °C and 1013.25 hPa, dry, with sea level at
## height 0. A body whose Air Density is set uses that instead (Fixed Air).

## Temperature of the air at sea level, °C.
@export_range(-60.0, 60.0, 0.1, "suffix:°C") var temperature: float = 15.0
## Pressure of the air at sea level, hPa: 1013.25 on an average day, about 980 in a deep low and 1040
## in a strong high.
@export_range(800.0, 1100.0, 0.01, "suffix:hPa") var pressure: float = 1013.25
## Relative humidity of the air, %: 0 for dry air, as the standard atmosphere is.
@export_range(0.0, 100.0, 0.1, "suffix:%") var humidity: float = 0.0

## Every BoundedBuoyancyAir in the scene tree.
static var instances: Array[Node3D] = []
## The world this air is in.
var world: World3D

const LAPSE := 0.0065          # K/m, the fall in temperature with height to 11 km
const TROPOPAUSE := 11000.0    # m (geopotential), above which the temperature stays the same
const EARTH := 6356766.0       # m, the radius the standard atmosphere's heights are worked with
const G0 := 9.80665
const MOLAR := 0.0289644       # kg/mol, dry air
const R_GAS := 8.3144598       # J/(mol K)
const R_DRY := 287.058         # J/(kg K)
const R_VAPOUR := 461.495      # J/(kg K)


func _enter_tree() -> void:
	world = get_world_3d()
	if not instances.has(self):
		instances.append(self)


func _exit_tree() -> void:
	instances.erase(self)


## Density of the air at the world point `p`, kg/m³.
func density_at(p: Vector3) -> float:
	var warmer := 0.0
	for t in BoundedBuoyancyThermal.instances:
		if t.world == world:
			warmer += t.warming_at(p)
	return standard_density(p.y - global_position.y, temperature, pressure, humidity, warmer)


## Temperature of the air at the world point `p`, °C.
func temperature_at(p: Vector3) -> float:
	var warmer := 0.0
	for t in BoundedBuoyancyThermal.instances:
		if t.world == world:
			warmer += t.warming_at(p)
	return standard_air(p.y - global_position.y, temperature, pressure).x - 273.15 + warmer


## Temperature (K) and pressure (Pa) of the standard atmosphere `height` metres above sea level, with
## `sea_temperature` °C and `sea_pressure` hPa at sea level.
static func standard_air(height: float, sea_temperature: float, sea_pressure: float) -> Vector2:
	var h := EARTH * height / (EARTH + height)   # geopotential height
	var t0 := sea_temperature + 273.15
	var power := G0 * MOLAR / (R_GAS * LAPSE)
	var p0 := sea_pressure * 100.0
	if h <= TROPOPAUSE:
		var t := t0 - LAPSE * h
		return Vector2(t, p0 * pow(t / t0, power))
	var t11 := t0 - LAPSE * TROPOPAUSE
	return Vector2(t11, p0 * pow(t11 / t0, power) * exp(-G0 * MOLAR * (h - TROPOPAUSE) / (R_GAS * t11)))


## Density of the air `height` metres above sea level, kg/m³, in the standard atmosphere with
## `sea_temperature` °C and `sea_pressure` hPa at sea level, at `humidity` % relative humidity, and
## `warmer` °C warmer than the air around (at the same pressure).
static func standard_density(height: float, sea_temperature := 15.0, sea_pressure := 1013.25, humidity := 0.0, warmer := 0.0) -> float:
	var tp := standard_air(height, sea_temperature, sea_pressure)
	var t: float = maxf(tp.x + warmer, 1.0)
	var vapour := 0.0
	if humidity > 0.0:
		# Saturation pressure of water vapour (Magnus' formula, Alduchov and Eskridge, 1996), Pa.
		var c := t - 273.15
		vapour = humidity * 0.01 * 610.94 * exp(17.625 * c / (c + 243.04))
	return (tp.y - vapour) / (R_DRY * t) + vapour / (R_VAPOUR * t)


## Density of the air at the world point `p` in `w`: its BoundedBuoyancyAir's, or the standard
## atmosphere's with sea level at height 0 (and any warm and cold places).
static func density_in(w: World3D, p: Vector3) -> float:
	for a in instances:
		if a.world == w:
			return a.density_at(p)
	var warmer := 0.0
	for t in BoundedBuoyancyThermal.instances:
		if t.world == w:
			warmer += t.warming_at(p)
	return standard_density(p.y, 15.0, 1013.25, 0.0, warmer)


## Speed of sound in the air at the world point `p` in `w`, m/s: √(γ R T), from the air's temperature
## there (dry air, γ = 1.4).
static func sound_speed_in(w: World3D, p: Vector3) -> float:
	var t := 288.15
	var found := false
	for a in instances:
		if a.world == w:
			t = a.temperature_at(p) + 273.15
			found = true
			break
	if not found:
		var warmer := 0.0
		for th in BoundedBuoyancyThermal.instances:
			if th.world == w:
				warmer += th.warming_at(p)
		t = standard_air(p.y, 15.0, 1013.25).x + warmer
	return sqrt(1.4 * R_DRY * maxf(t, 1.0))
