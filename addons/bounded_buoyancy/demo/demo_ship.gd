extends RefCounted
## Sailing ships for the demo, built in code: a brig's hull, rounded at the bilge and drawn in toward
## the rail, sharp at the bow, its deck sweeping up to a raised quarterdeck and a raked stern; planked,
## with a painted band and a gilt moulding, open gun ports with their lids swung up, and round windows
## lit from within along the quarters and across the stern, where a lantern stands; a planked deck; two
## masts with yards and every square sail set, a jib on the bowsprit, shrouds and stays, and a flag.
## The hull's shape is its collision shape, so it floats, heels and sinks as itself. For show: the
## physics needs only the hull.
##
## make() gives a BoundedBuoyancyBody with the ship on it. The bow is toward -Z, starboard toward +X,
## and its origin is on the keel line, LIFT below the deck.

const BB := preload("res://addons/bounded_buoyancy/bounded_buoyancy_body.gd")

const LENGTH := 15.0      # m, stem to stern at the rail
const BEAM := 4.6         # m, broadest
const KEEL := -1.3        # height of the keel amidships (local y)
const MAX_BEAM := 0.7     # height at which the hull is broadest
const DECK := 1.35        # height of the deck amidships
const RAIL := 2.05        # height of the rail amidships
const TUMBLE := 0.12      # how far the sides draw in from the broadest to the rail, as a share
const TUCK := 0.45        # height of the foot of the transom
const STATIONS := 56
const ROWS := 22

## Colours of a ship: its upper sides, the band along its ports, below the waterline, the port lids,
## and its flag; and the height its waterline is painted at.
const NAVY := {wood = Color(0.13, 0.11, 0.09), band = Color(0.80, 0.62, 0.27), bottom = Color(0.62, 0.36, 0.20), ports = Color(0.08, 0.07, 0.06), flag = Color(0.05, 0.05, 0.06), waterline = 0.3}
const MERCHANT := {wood = Color(0.42, 0.28, 0.16), band = Color(0.55, 0.13, 0.10), bottom = Color(0.86, 0.84, 0.78), ports = Color(0.30, 0.10, 0.08), flag = Color(0.62, 0.10, 0.10), waterline = 0.7}

const HULL_SHADER := """
shader_type spatial;
render_mode cull_disabled;
uniform vec3 wood : source_color;
uniform vec3 band : source_color;
uniform vec3 bottom : source_color;
uniform vec3 lids : source_color;
uniform float waterline;
uniform float band_lo;
uniform float band_hi;
uniform float port_z[16];
uniform int ports;
uniform float port_w = 0.55;
uniform float port_lo;
uniform float port_hi;
uniform bool transom;
uniform float rail;
varying vec3 lp;
uniform float half_length = 7.5;
float hash(float n) {
	return fract(sin(n * 91.345) * 47453.13);
}
float noise1(float x) {
	float i = floor(x);
	float f = fract(x);
	return mix(hash(i), hash(i + 1.0), f * f * (3.0 - 2.0 * f));
}
void vertex() {
	lp = VERTEX;
}
void fragment() {
	// Planks run along the hull (UV.y counts across them, from the keel up); their butts are staggered.
	float across = UV.y / 0.28;
	float plank = floor(across);
	float f = fract(across);
	float seam = smoothstep(0.0, 0.14, f) * smoothstep(1.0, 0.88, f);
	float along = UV.x + hash(plank) * 6.0;
	// Dark at the butts, where one plank ends and the next begins (every 6 m, staggered).
	float butt = smoothstep(0.0, 0.03, (0.5 - abs(fract(along / 6.0) - 0.5)) * 6.0);
	float grain = 0.9 + 0.1 * noise1(UV.x * 3.0 + plank * 17.0) + 0.22 * (hash(plank + floor(along / 6.0)) - 0.5);
	float tz = clamp(lp.z / half_length, -1.0, 1.0);
	float rail_here = transom ? rail : rail + 0.45 * tz * tz + 0.85 * smoothstep(0.5, 0.75, tz);
	vec3 c = wood;
	float rough = 0.85;
	float metal = 0.0;
	if (lp.y < waterline) {
		c = bottom;
		rough = 0.55;
	} else if (lp.y > band_lo && lp.y < band_hi) {
		c = band;
	}
	// Black wales above and below the band, and along the rail.
	if (abs(lp.y - band_lo) < 0.07 || abs(lp.y - band_hi) < 0.05 || lp.y > rail_here - 0.06) {
		c = vec3(0.05, 0.045, 0.04);
	}
	if (abs(lp.y - (rail_here - 0.16)) < 0.035) {
		c = vec3(0.78, 0.58, 0.2);
		rough = 0.35;
		metal = 0.8;
	}
	// The gun ports, cut through the band.
	if (!transom && lp.y > port_lo && lp.y < port_hi) {
		for (int i = 0; i < 16; i++) {
			if (i >= ports) {
				break;
			}
			if (abs(lp.z - port_z[i]) < 0.5 * port_w) {
				float frame = min(abs(abs(lp.z - port_z[i]) - 0.5 * port_w), min(lp.y - port_lo, port_hi - lp.y));
				c = frame < 0.05 ? lids : vec3(0.015, 0.012, 0.01);
			}
		}
	}
	vec3 e = vec3(0.0);
	// Round windows with brass rims, lit from within: a row across the transom, and along each quarter
	// under the quarterdeck rail.
	vec2 win = vec2(1e9);
	if (transom && abs(lp.x) < 1.55) {
		win = vec2(fract((lp.x + 5.0) / 0.6) - 0.5, (lp.y - (rail - 0.62)) / 0.6) * 0.6;
	} else if (!transom && lp.z > 4.6 && lp.z < 7.0) {
		win = vec2(fract((lp.z + 0.15) / 0.7) - 0.5, (lp.y - (rail_here - 0.62)) / 0.7) * 0.7;
	}
	float r = length(win);
	if (r < 0.19) {
		c = vec3(0.75, 0.55, 0.22);
		rough = 0.35;
		metal = 0.8;
		if (r < 0.15) {
			c = vec3(0.08, 0.07, 0.05);
			metal = 0.0;
			e = vec3(1.0, 0.72, 0.35) * 0.7;
		}
	}
	ALBEDO = c * mix(0.22, 1.0, seam * butt) * grain;
	ROUGHNESS = rough;
	METALLIC = metal;
	EMISSION = e;
}
"""

const DECK_SHADER := """
shader_type spatial;
varying vec3 lp;
float hash(float n) {
	return fract(sin(n * 91.345) * 47453.13);
}
void vertex() {
	lp = VERTEX;
}
void fragment() {
	float across = (lp.x + 10.0) / 0.2;
	float plank = floor(across);
	float f = fract(across);
	float seam = smoothstep(0.0, 0.07, f) * smoothstep(1.0, 0.93, f);
	float along = lp.z + hash(plank) * 5.0;
	float butt = smoothstep(0.0, 0.03, (0.5 - abs(fract(along / 5.0) - 0.5)) * 5.0);
	vec3 c = vec3(0.66, 0.56, 0.42) * (0.88 + 0.16 * hash(plank + floor(along / 5.0)));
	ALBEDO = c * mix(0.45, 1.0, seam * butt);
	ROUGHNESS = 0.9;
}
"""

const SAIL_SHADER := """
shader_type spatial;
render_mode cull_disabled;
uniform vec3 canvas : source_color = vec3(0.92, 0.88, 0.78);
void fragment() {
	// Cloths sewn side by side, a reef band, and the grime of use toward the foot.
	float cloth = fract(UV.x * 9.0);
	float seam = smoothstep(0.0, 0.04, cloth) * smoothstep(1.0, 0.96, cloth);
	float reef = 1.0 - 0.25 * (1.0 - smoothstep(0.0, 0.012, abs(UV.y - 0.25)));
	vec3 c = canvas * mix(0.82, 1.0, seam) * reef * mix(1.0, 0.86, UV.y);
	ALBEDO = c;
	ROUGHNESS = 0.95;
	BACKLIGHT = vec3(0.45, 0.42, 0.36);
}
"""

const FLAG_SHADER := """
shader_type spatial;
render_mode cull_disabled;
uniform vec3 colour : source_color;
void vertex() {
	float x = UV.x;
	VERTEX.z += 0.12 * x * sin(6.0 * x - TIME * 5.0);
	VERTEX.y += 0.04 * x * sin(4.0 * x - TIME * 4.0);
}
void fragment() {
	ALBEDO = colour * (0.9 + 0.1 * sin(UV.x * 20.0 - TIME * 5.0));
	ROUGHNESS = 0.9;
	BACKLIGHT = colour * 0.5;
}
"""

static var _spar_material: StandardMaterial3D
static var _rope_material: StandardMaterial3D
static var _iron_material: StandardMaterial3D
static var _shaders := {}


## How wide the hull is (half its width) at `t` along it (-1 at the bow, 1 at the stern) and height
## `y`.
static func half_width(t: float, y: float, rail := -1.0) -> float:
	var plan: float
	if t < 0.0:
		plan = pow(maxf(1.0 - pow(-t, 2.3), 0.0), 0.55)
	else:
		# Square at the stern above the tuck, where the transom is; below it the run narrows to the
		# sternpost.
		var above := 1.0 - 0.3 * pow(t, 2.2)
		var below := pow(maxf(1.0 - pow(t, 2.6), 0.0), 0.6)
		plan = lerpf(below, above, smoothstep(TUCK - 0.7, TUCK + 0.15, y))
	var low := MAX_BEAM - keel_at(t)
	var g: float
	if y < MAX_BEAM:
		var u := clampf((MAX_BEAM - y) / maxf(low, 0.05), 0.0, 1.0)
		g = pow(1.0 - pow(u, 2.4), 1.0 / 2.4)
	else:
		var u := clampf((y - MAX_BEAM) / ((rail if rail > 0.0 else rail_at(t)) - MAX_BEAM), 0.0, 1.0)
		g = 1.0 - TUMBLE * u * u
	return maxf(0.5 * BEAM * plan * g, 0.07 * minf(plan * 4.0, 1.0))


## Height of the keel at `t` along the ship: it sweeps up into the stem at the bow.
static func keel_at(t: float) -> float:
	return KEEL + 1.7 * pow(maxf((-t - 0.5) / 0.5, 0.0), 2.0) + 0.35 * pow(maxf((t - 0.8) / 0.2, 0.0), 2.0)


## Height of the rail at `t`: it sweeps up toward both ends, and higher at the stern.
static func rail_at(t: float) -> float:
	return RAIL + 0.45 * t * t + 0.85 * smoothstep(0.5, 0.75, t)


## Height of the deck at `t`.
static func deck_at(t: float) -> float:
	return DECK + 0.25 * t * t + 0.75 * smoothstep(0.5, 0.56, t)


## The rail and the deck as the physics has them: the hull it floats, floods and is struck as, with a
## lower sheer and an upright stern. The raised quarterdeck and the raked stern are drawn above that,
## all of it above the waterline, so they change how she looks, not how she sails.
static func hull_rail_at(t: float) -> float:
	return RAIL + 0.3 * t * t + 0.55 * smoothstep(0.55, 0.85, t)


static func hull_deck_at(t: float) -> float:
	return DECK + 0.25 * t * t + 0.55 * smoothstep(0.55, 0.85, t)


## A ship of `colours` (NAVY or MERCHANT) of `density` at `at`, its ports at `ports` (positions
## along it, z), under `parent`. Returns the body; its "ports" meta has the ports' places, where
## its guns go (local, starboard side).
static func make(parent: Node, at: Vector3, colours: Dictionary, density: float, ports: Array, run_out := true) -> RigidBody3D:
	var b := BB.new()
	b.name = "Ship"
	# The hull, and the same shape to float on and to be struck.
	var hull := _hull_mesh()
	var look := MeshInstance3D.new()
	look.mesh = hull[0]
	var paint := _material(HULL_SHADER)
	paint.set_shader_parameter("wood", colours.wood)
	paint.set_shader_parameter("band", colours.band)
	paint.set_shader_parameter("bottom", colours.bottom)
	paint.set_shader_parameter("lids", colours.ports)
	paint.set_shader_parameter("rail", RAIL)
	var band_lo := DECK + 0.05
	var band_hi := DECK + 0.68
	paint.set_shader_parameter("band_lo", band_lo)
	paint.set_shader_parameter("band_hi", band_hi)
	paint.set_shader_parameter("port_lo", DECK + 0.17)
	paint.set_shader_parameter("port_hi", DECK + 0.6)
	var zs := PackedFloat32Array()
	for z in ports:
		zs.append(z)
	zs.resize(16)
	paint.set_shader_parameter("port_z", zs)
	paint.set_shader_parameter("ports", ports.size())
	paint.set_shader_parameter("waterline", colours.waterline)
	paint.set_shader_parameter("transom", false)
	look.material_override = paint
	b.add_child(look)
	var stern := MeshInstance3D.new()
	stern.mesh = hull[1]
	var stern_paint: ShaderMaterial = paint.duplicate()
	stern_paint.set_shader_parameter("transom", true)
	stern_paint.set_shader_parameter("rail", rail_at(1.0))
	stern.material_override = stern_paint
	b.add_child(stern)
	var deck := MeshInstance3D.new()
	deck.mesh = _deck_mesh()
	deck.material_override = _material(DECK_SHADER)
	b.add_child(deck)
	var cs := CollisionShape3D.new()
	var shape := ConvexPolygonShape3D.new()
	shape.points = hull[2]
	cs.shape = shape
	b.add_child(cs)
	_rig(b, colours)
	b.density = density
	b.angular_drag = 1.5
	b.position = at
	_gun_ports(b, ports, colours.ports, run_out)
	_lantern(b)
	b.set_meta(&"ports", ports.map(func(z: float) -> Vector3: return Vector3(half_width(z / (0.5 * LENGTH), DECK + 0.4), DECK + 0.4, z)))
	parent.add_child(b)
	b.center_of_mass = Vector3(0, KEEL + 1.2, 0)   # ballast low in the hold
	return b


## Compartments in `b`, made from `kind` (BoundedBuoyancyCompartment): between each pair of the
## stations `ends` (z), the hold each side of the middle, from just above the keel to the deck, as a
## box holding as much as the hull does there (a wooden ship's hold is one open space, as the box is,
## though rounded at the bilge where the box is square); and above the deck, the well inside the
## bulwarks, open to the sea over the rail.
static func compartments(b: Node3D, kind: Script, ends: Array) -> void:
	for k in ends.size() - 1:
		var z0: float = ends[k]
		var z1: float = ends[k + 1]
		var lo := -INF
		var deck_y := INF
		var rail_y := INF
		for i in 9:
			var t := lerpf(z0, z1, i / 8.0) / (0.5 * LENGTH)
			lo = maxf(lo, keel_at(t) + 0.2)
			deck_y = minf(deck_y, hull_deck_at(t))
			rail_y = minf(rail_y, hull_rail_at(t))
		# How much the hull holds on one side between lo and the deck, summed in small boxes.
		var held := 0.0
		var n := 24
		for i in n:
			var t := lerpf(z0, z1, (i + 0.5) / n) / (0.5 * LENGTH)
			for j in n:
				var y := lerpf(lo, deck_y, (j + 0.5) / n)
				held += maxf(half_width(t, y, hull_rail_at(t)) - 0.08, 0.0)
		var height := deck_y - lo
		var wide := held / (n * n)
		var well_wide := INF
		for i in 9:
			var t := lerpf(z0, z1, i / 8.0) / (0.5 * LENGTH)
			well_wide = minf(well_wide, half_width(t, rail_y, hull_rail_at(t)) - 0.1)
		for side in [-1.0, 1.0]:
			var room: Node3D = kind.new()
			room.size = Vector3(wide, height, z1 - z0)
			room.position = Vector3(side * 0.5 * wide, 0.5 * (lo + deck_y), 0.5 * (z0 + z1))
			b.add_child(room)
			var well: Node3D = kind.new()
			well.size = Vector3(well_wide, rail_y - deck_y, z1 - z0)
			well.position = Vector3(side * 0.5 * well_wide, 0.5 * (deck_y + rail_y), 0.5 * (z0 + z1))
			# Open over the rail: the sea pours in once the rail goes under.
			var top: Array[Vector4] = [Vector4(0.0, 0.5 * (rail_y - deck_y), 0.0, 0.5 * well_wide * (z1 - z0))]
			well.holes = top
			well.set_meta(&"open", true)
			b.add_child(well)


## A gun at a port: a barrel on a carriage, pointing out of it. Put it under the gun's node.
static func gun_look(gun: Node3D) -> void:
	if _iron_material == null:
		_iron_material = StandardMaterial3D.new()
		_iron_material.albedo_color = Color(0.07, 0.07, 0.08)
		_iron_material.metallic = 0.7
		_iron_material.roughness = 0.45
	var barrel := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.09
	bm.bottom_radius = 0.14
	bm.height = 1.9
	bm.radial_segments = 12
	barrel.mesh = bm
	barrel.material_override = _iron_material
	barrel.rotation_degrees = Vector3(-90, 0, 0)
	barrel.position = Vector3(0, 0, 0.35)
	gun.add_child(barrel)
	var carriage := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.55, 0.32, 0.9)
	carriage.mesh = cm
	carriage.material_override = _spar()
	carriage.position = Vector3(0, -0.3, 0.95)
	gun.add_child(carriage)


static func _material(code: String) -> ShaderMaterial:
	if not _shaders.has(code):
		var sh := Shader.new()
		sh.code = code
		_shaders[code] = sh
	var m := ShaderMaterial.new()
	m.shader = _shaders[code]
	return m


static func _spar() -> StandardMaterial3D:
	if _spar_material == null:
		_spar_material = StandardMaterial3D.new()
		_spar_material.albedo_color = Color(0.30, 0.20, 0.12)
		_spar_material.roughness = 0.8
	return _spar_material


## The hull's sides and bottom, its transom, and points for its collision shape.
static func _hull_mesh() -> Array:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var grid := []   # [station][row] = [Vector3 (starboard), girth]
	var points := PackedVector3Array()
	for i in STATIONS + 1:
		var t := -1.0 + 2.0 * float(i) / STATIONS
		t = clampf(t, -0.995, 1.0)
		var z := t * 0.5 * LENGTH
		var y0 := keel_at(t)
		var y1 := rail_at(t)
		var row := []
		var girth := 0.0
		var prev := Vector3.ZERO
		for j in ROWS + 1:
			var v := float(j) / ROWS
			var y := lerpf(y0, y1, 1.0 - pow(1.0 - v, 1.4))
			var p := Vector3(half_width(t, y), y, z + 0.35 * (y - TUCK) * smoothstep(0.9, 1.0, t))
			if j > 0:
				girth += p.distance_to(prev)
			prev = p
			row.append([p, girth])
			if i % 4 == 0 and j % 3 == 0:
				var hy := lerpf(y0, hull_rail_at(t), 1.0 - pow(1.0 - v, 1.4))
				var h := Vector3(half_width(t, hy, hull_rail_at(t)), hy, z)
				points.append(h)
				points.append(Vector3(-h.x, h.y, h.z))
		grid.append(row)
	for side in [1.0, -1.0]:
		for i in STATIONS:
			for j in ROWS:
				var a: Array = grid[i][j]
				var b: Array = grid[i + 1][j]
				var c: Array = grid[i + 1][j + 1]
				var d: Array = grid[i][j + 1]
				var quad := [a, b, c, a, c, d] if side > 0.0 else [a, c, b, a, d, c]
				for q in quad:
					var p: Vector3 = q[0]
					st.set_uv(Vector2(p.z, q[1]))
					st.add_vertex(Vector3(p.x * side, p.y, p.z))
	# Along the keel, joining the two sides.
	for i in STATIONS:
		var a: Vector3 = grid[i][0][0]
		var b: Vector3 = grid[i + 1][0][0]
		for p in [a, Vector3(-b.x, b.y, b.z), b, a, Vector3(-a.x, a.y, a.z), Vector3(-b.x, b.y, b.z)]:
			st.set_uv(Vector2(p.z, 0.0))
			st.add_vertex(p)
	st.index()
	st.generate_normals()
	var sides := st.commit()
	# The transom: the last station, closed.
	var ts := SurfaceTool.new()
	ts.begin(Mesh.PRIMITIVE_TRIANGLES)
	var last: Array = grid[STATIONS]
	for j in ROWS:
		# Row by row across, from the port side to the starboard side.
		var p: Vector3 = last[j][0]
		var q: Vector3 = last[j + 1][0]
		var pp := Vector3(-p.x, p.y, p.z)
		var qq := Vector3(-q.x, q.y, q.z)
		for v in [pp, q, p, pp, qq, q]:   # wound to face aft
			ts.set_normal(Vector3.BACK)
			ts.set_uv(Vector2(v.x, v.y))
			ts.add_vertex(v)
	var transom := ts.commit()
	return [sides, transom, points]


## The deck: from side to side at deck height, from the bow to the stern.
static func _deck_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 40
	for i in n:
		var t0 := lerpf(-0.93, 1.0, float(i) / n)
		var t1 := lerpf(-0.93, 1.0, float(i + 1) / n)
		var y0 := deck_at(t0)
		var y1 := deck_at(t1)
		var w0 := half_width(t0, y0) - 0.08
		var w1 := half_width(t1, y1) - 0.08
		var z0 := t0 * 0.5 * LENGTH
		var z1 := t1 * 0.5 * LENGTH
		for p in [Vector3(-w0, y0, z0), Vector3(w0, y0, z0), Vector3(w1, y1, z1), Vector3(-w0, y0, z0), Vector3(w1, y1, z1), Vector3(-w1, y1, z1)]:
			st.set_normal(Vector3.UP)
			st.add_vertex(p)
	return st.commit()


## Masts, yards, sails, bowsprit, rigging and a flag.
static func _rig(b: Node3D, colours: Dictionary) -> void:
	var fore := -0.22 * LENGTH
	var main := 0.1 * LENGTH
	var bow := Vector3(0, rail_at(-0.98) - 0.2, -0.49 * LENGTH)
	var sprit_end := bow + Vector3(0, 1.6, -4.6)
	_spar_between(b, bow, sprit_end, 0.13, 0.07)
	var tops := []
	for m in [[fore, 8.0, 5.0], [main, 8.6, 5.4]]:
		var z: float = m[0]
		var base := Vector3(0, deck_at(z / (0.5 * LENGTH)), z)
		var cap := base + Vector3(0, m[1], 0)
		var head := cap + Vector3(0, m[2], 0)
		_spar_between(b, base, cap + Vector3(0, 0.6, 0), 0.19, 0.15)
		_spar_between(b, cap - Vector3(0, 0.5, 0), head, 0.11, 0.07)
		var top := MeshInstance3D.new()
		var tm := BoxMesh.new()
		tm.size = Vector3(1.5, 0.08, 1.0)
		top.mesh = tm
		top.material_override = _spar()
		top.position = cap
		b.add_child(top)
		# The course, furled on its yard; the topsail set between its yards, filled from astern.
		var course_yard := cap - Vector3(0, 1.0, 0)
		var w1 := 3.6
		_spar_between(b, course_yard - Vector3(w1, 0, 0), course_yard + Vector3(w1, 0, 0), 0.08, 0.1, true)
		_sail(b, course_yard + Vector3(0, -0.1, 0.05), Vector3(0, deck_at(z / (0.5 * LENGTH)) + 1.5, z + 0.05), w1 * 0.95, w1 * 1.05)
		var top_yard := head - Vector3(0, 0.7, 0)
		var w2 := 2.7
		_spar_between(b, top_yard - Vector3(w2, 0, 0), top_yard + Vector3(w2, 0, 0), 0.06, 0.08, true)
		_sail(b, top_yard + Vector3(0, -0.1, 0.05), course_yard + Vector3(0, 0.25, 0.05), w2 * 0.95, w1 * 0.95)
		tops.append([cap, head])
		# Shrouds from the top down to the rail, three a side; ratlines are left out.
		for side in [-1.0, 1.0]:
			for k in 3:
				var zz := z + 0.6 * (k - 0.6)
				var t := zz / (0.5 * LENGTH)
				var foot := Vector3(side * (half_width(t, rail_at(t)) + 0.05), rail_at(t), zz)
				_rope(b, cap + Vector3(side * 0.6, 0, 0.1 * k), foot)
			_rope(b, head - Vector3(0, 0.4, 0), Vector3(side * (half_width(z / (0.5 * LENGTH), RAIL) + 0.05), RAIL, z + 2.4))
	# Stays: fore and aft between the mastheads, and to the bowsprit.
	_rope(b, tops[0][0], bow + Vector3(0, 0.1, -0.2))
	_rope(b, tops[0][1], sprit_end)
	_rope(b, tops[1][0], tops[0][0] + Vector3(0, -2.0, 0))
	_rope(b, tops[1][1], tops[0][1])
	_rope(b, tops[1][1], Vector3(0, rail_at(1.0), 0.49 * LENGTH))
	# A jib from the fore topmast to the bowsprit.
	_jib(b, tops[0][1] - Vector3(0, 0.6, 0), sprit_end - Vector3(0, 0.1, 0.3), bow + Vector3(0, 0.25, -0.6))
	# The flag at the main masthead.
	var flag := MeshInstance3D.new()
	var fm := PlaneMesh.new()
	fm.size = Vector2(1.6, 1.0)
	fm.subdivide_width = 12
	fm.orientation = PlaneMesh.FACE_Z
	flag.mesh = fm
	var fmat := _material(FLAG_SHADER)
	fmat.set_shader_parameter("colour", colours.flag)
	flag.material_override = fmat
	flag.position = tops[1][1] + Vector3(0, -0.35, 0.85)
	flag.rotation_degrees = Vector3(0, 90, 0)
	flag.name = "Flag"
	b.add_child(flag)


## A round spar from `a` to `b`, tapering from radius `ra` to `rb` (or from the middle out, if
## `yard`).
static func _spar_between(b: Node3D, a: Vector3, c: Vector3, ra: float, rb: float, yard := false) -> void:
	if yard:
		var mid := 0.5 * (a + c)
		_spar_between(b, mid, a, rb, ra)
		_spar_between(b, mid, c, rb, ra)
		return
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.bottom_radius = ra
	m.top_radius = rb
	m.height = a.distance_to(c)
	m.radial_segments = 10
	m.rings = 1
	mi.mesh = m
	mi.material_override = _spar()
	_along(mi, a, c)
	b.add_child(mi)


## A rope from `a` to `c`.
static func _rope(b: Node3D, a: Vector3, c: Vector3) -> void:
	if _rope_material == null:
		_rope_material = StandardMaterial3D.new()
		_rope_material.albedo_color = Color(0.12, 0.10, 0.08)
		_rope_material.roughness = 0.9
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = 0.025
	m.bottom_radius = 0.025
	m.height = a.distance_to(c)
	m.radial_segments = 4
	m.rings = 1
	mi.mesh = m
	mi.material_override = _rope_material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_along(mi, a, c)
	b.add_child(mi)


## Place a Y-up mesh so that it runs from `a` to `c`.
static func _along(mi: Node3D, a: Vector3, c: Vector3) -> void:
	var d := (c - a).normalized()
	var x := d.cross(Vector3.FORWARD if absf(d.z) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(d).normalized()
	mi.transform = Transform3D(Basis(x, d, z), 0.5 * (a + c))


## A square sail from its head at `head` (half-width `wh`) to its foot at `foot` (half-width
## `wf`), filled by a wind from astern: it bellies forward.
static func _sail(b: Node3D, head: Vector3, foot: Vector3, wh: float, wf: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 10
	var grid := []
	for i in n + 1:
		var row := []
		var v := float(i) / n
		for j in n + 1:
			var u := float(j) / n
			var w := lerpf(wh, wf, v)
			var p := head.lerp(foot, v) + Vector3((u - 0.5) * 2.0 * w, 0, 0)
			p.z -= 0.9 * sin(PI * u) * sin(PI * minf(v * 1.15, 1.0))   # the belly
			row.append([p, Vector2(u, v)])
		grid.append(row)
	for i in n:
		for j in n:
			for q in [grid[i][j], grid[i][j + 1], grid[i + 1][j + 1], grid[i][j], grid[i + 1][j + 1], grid[i + 1][j]]:
				st.set_uv(q[1])
				st.add_vertex(q[0])
	st.index()
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _material(SAIL_SHADER)
	b.add_child(mi)


## A triangular jib between `head`, `tack` and `clew`, bellying out a little to leeward.
static func _jib(b: Node3D, head: Vector3, tack: Vector3, clew: Vector3) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 8
	for i in n:
		for j in n - i:
			var pts := []
			for k in [[i, j], [i + 1, j], [i, j + 1], [i + 1, j], [i + 1, j + 1], [i, j + 1]]:
				pts.append(k)
			var tris := [pts.slice(0, 3)]
			if j < n - i - 1:
				tris.append(pts.slice(3, 6))
			for tri in tris:
				for k in tri:
					var a := float(k[0]) / n
					var c := float(k[1]) / n
					var p := head + (tack - head) * a + (clew - head) * c
					p.x += 0.35 * sin(PI * a) * sin(PI * minf(c * 2.0, 1.0)) * (1.0 - a - c + 0.5)
					st.set_uv(Vector2(c, a))
					st.add_vertex(p)
	st.index()
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _material(SAIL_SHADER)
	b.add_child(mi)


## At each port, both sides: its lid, swung up on its hinges, and (with `run_out`) a gun's muzzle run
## out through it; a ship given guns of her own (BoundedBuoyancyCannon, with gun_look) leaves them out.
static func _gun_ports(b: Node3D, ports: Array, lid_colour: Color, run_out: bool) -> void:
	var lid_look := StandardMaterial3D.new()
	lid_look.albedo_color = lid_colour
	lid_look.roughness = 0.8
	if _iron_material == null:
		_iron_material = StandardMaterial3D.new()
		_iron_material.albedo_color = Color(0.07, 0.07, 0.08)
		_iron_material.metallic = 0.7
		_iron_material.roughness = 0.45
	var lo := DECK + 0.17
	var hi := DECK + 0.6
	for z in ports:
		var t: float = z / (0.5 * LENGTH)
		for side in [-1.0, 1.0]:
			var x: float = side * half_width(t, hi)
			var lid := MeshInstance3D.new()
			var lm := BoxMesh.new()
			lm.size = Vector3(0.05, hi - lo + 0.04, 0.6)
			lid.mesh = lm
			lid.material_override = lid_look
			# Hinged along its top edge, swung out and up 70 degrees.
			var hinge := Node3D.new()
			hinge.position = Vector3(x + side * 0.03, hi + 0.02, z)
			hinge.rotation_degrees = Vector3(0, 0, side * 70.0)
			b.add_child(hinge)
			lid.position = Vector3(0, -0.5 * (hi - lo + 0.04), 0)
			hinge.add_child(lid)
			if not run_out:
				continue
			var barrel := MeshInstance3D.new()
			var bm := CylinderMesh.new()
			bm.top_radius = 0.08
			bm.bottom_radius = 0.11
			bm.height = 1.1
			bm.radial_segments = 12
			barrel.mesh = bm
			barrel.material_override = _iron_material
			barrel.rotation_degrees = Vector3(0, 0, -side * 90.0)
			barrel.position = Vector3(x + side * 0.15, 0.5 * (lo + hi), z)
			b.add_child(barrel)


## A lantern on a post at the top of the stern.
static func _lantern(b: Node3D) -> void:
	var top := Vector3(0, rail_at(1.0), 0.5 * LENGTH + 0.35 * (rail_at(1.0) - TUCK))
	var post := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.04
	pm.bottom_radius = 0.05
	pm.height = 0.9
	post.mesh = pm
	post.material_override = _spar()
	post.position = top + Vector3(0, 0.45, -0.1)
	b.add_child(post)
	var glass := MeshInstance3D.new()
	var gm := CylinderMesh.new()
	gm.top_radius = 0.12
	gm.bottom_radius = 0.2
	gm.height = 0.5
	gm.radial_segments = 8
	glass.mesh = gm
	var lit := StandardMaterial3D.new()
	lit.albedo_color = Color(1.0, 0.8, 0.45)
	lit.emission_enabled = true
	lit.emission = Color(1.0, 0.65, 0.3)
	lit.emission_energy_multiplier = 1.5
	glass.material_override = lit
	glass.position = top + Vector3(0, 1.1, -0.1)
	b.add_child(glass)
	var cap := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.02
	cm.bottom_radius = 0.16
	cm.height = 0.2
	cap.mesh = cm
	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color(0.78, 0.58, 0.2)
	gold.metallic = 0.8
	gold.roughness = 0.35
	cap.material_override = gold
	cap.position = top + Vector3(0, 1.45, -0.1)
	b.add_child(cap)
