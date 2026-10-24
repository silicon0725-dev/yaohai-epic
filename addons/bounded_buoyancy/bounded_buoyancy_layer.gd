@tool
class_name BoundedBuoyancyLayer
extends Resource
## A layer of a BoundedBuoyancyWater below its top fluid: water under oil, brine on the bottom, the
## colder, saltier water under a thermocline, mud, quicksand. It runs from its depth down to the next
## layer's (or the bottom of the water), level whatever the waves do on the surface.
##
## Bodies feel the weight of what they displace in each layer: a body less dense than a layer floats
## on it, one denser sinks through it, and one between the two settles on the boundary, partly in
## each, as an egg does on brine under fresh water.

## How far below the water's surface the layer starts, in metres (from the node's height, so the
## waves do not move it).
@export_range(0.0, 10000.0, 0.001, "or_greater", "suffix:m") var depth: float = 1.0:
	set(value):
		depth = maxf(value, 0.0)
		emit_changed()
## Its density at its top, in kg/m³: fresh water 1000, sea water 1025, a saturated brine 1200,
## liquid mud 1200 to 1400, quicksand 1600 to 2000.
@export_range(1.0, 20000.0, 1.0, "or_greater", "suffix:kg/m³") var density: float = 1025.0:
	set(value):
		density = maxf(value, 0.001)
		emit_changed()
## How much denser it gets for each metre deeper, in kg/m³ per metre (a halocline, where the salt
## comes in, a few kg/m³ per metre). 0 for the same all through.
@export_range(-1000.0, 1000.0, 0.01, "or_greater", "or_less", "suffix:kg/m³/m") var density_gradient: float = 0.0:
	set(value):
		density_gradient = value
		emit_changed()
## How much harder it is to move through than water, as a multiple of the body's drag: 1 for water,
## 20 to 200 for mud, more for quicksand.
@export_range(0.0, 10000.0, 0.1, "or_greater") var drag: float = 1.0:
	set(value):
		drag = maxf(value, 0.0)
		emit_changed()
## Its colour and how murky it is, when the water draws its layers.
@export var color: Color = Color(0.1, 0.25, 0.35, 0.35):
	set(value):
		color = value
		emit_changed()
