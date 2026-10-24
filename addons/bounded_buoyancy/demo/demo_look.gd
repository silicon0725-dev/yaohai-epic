extends RefCounted
## The look the demo's sea scenes share: a sky with clouds and the sun in it, sunlight with shadows,
## haze toward the horizon, and a camera's response to light. For show only.

const SKY_SHADER := """
shader_type sky;
uniform vec3 top : source_color = vec3(0.20, 0.40, 0.70);
uniform vec3 horizon : source_color = vec3(0.68, 0.77, 0.86);
uniform vec3 sea : source_color = vec3(0.08, 0.17, 0.25);
uniform float cloudiness = 0.45;
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 6; i++) {
		s += a * noise(p);
		p = p * 2.03 + vec2(1.7, 9.2);
		a *= 0.5;
	}
	return s;
}
void sky() {
	vec3 d = EYEDIR;
	float up = d.y;
	vec3 col = mix(horizon, top, pow(clamp(up, 0.0, 1.0), 0.55));
	if (up < 0.0) {
		col = mix(horizon, sea, clamp(-up * 4.0, 0.0, 1.0));
	}
	float sun = 0.0;
	if (LIGHT0_ENABLED) {
		float c = max(dot(LIGHT0_DIRECTION, d), 0.0);
		sun = c;
		col += LIGHT0_COLOR * (pow(c, 1500.0) * 30.0 + pow(c, 60.0) * 0.35 + pow(c, 6.0) * 0.08);
	}
	if (up > 0.0) {
		// Clouds on a dome overhead, thinning toward the horizon; lit on the side toward the sun.
		vec2 uv = d.xz / (up + 0.1) * 0.9;
		float n = fbm(uv * 1.6);
		float cover = smoothstep(1.0 - cloudiness, 1.0 - cloudiness + 0.3, n) * smoothstep(0.0, 0.2, up);
		float dense = smoothstep(0.45, 0.85, fbm(uv * 3.1 + 4.0));
		vec3 cloud = mix(vec3(1.0, 0.99, 0.97), vec3(0.70, 0.74, 0.80), dense * 0.8);
		cloud += vec3(1.0, 0.9, 0.75) * pow(sun, 8.0) * 0.4;
		col = mix(col, cloud, cover * 0.92);
	}
	COLOR = col;
}
"""


## Give `root` the sky, the sun and the haze; returns the sun. `sun_degrees` is its pitch and yaw.
static func sea_and_sky(root: Node, sun_degrees := Vector2(-28.0, -35.0), haze := 0.0016) -> DirectionalLight3D:
	var sky_material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SKY_SHADER
	sky_material.shader = shader
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.9
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_white = 5.0
	e.fog_enabled = true
	e.fog_light_color = Color(0.68, 0.77, 0.86)
	e.fog_density = haze
	e.fog_sky_affect = 0.0
	e.fog_aerial_perspective = 0.4
	e.glow_enabled = true
	e.glow_intensity = 0.25
	e.glow_bloom = 0.03
	e.ssao_enabled = true
	e.ssao_radius = 1.5
	e.ssao_intensity = 1.2
	var world := WorldEnvironment.new()
	world.environment = e
	root.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(sun_degrees.x, sun_degrees.y, 0.0)
	sun.light_color = Color(1.0, 0.95, 0.87)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 220.0
	sun.shadow_blur = 1.5
	root.add_child(sun)
	return sun


static var _puff: Texture2D
static var _quad: QuadMesh
static var _materials := {}


## A soft, cloudy round puff, white, for smoke and spray.
static func puff() -> Texture2D:
	if _puff == null:
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		noise.frequency = 0.06
		noise.fractal_octaves = 4
		var n := 96
		var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
		for y in n:
			for x in n:
				var dx := (x + 0.5) / n * 2.0 - 1.0
				var dy := (y + 0.5) / n * 2.0 - 1.0
				var r := sqrt(dx * dx + dy * dy)
				var base := pow(1.0 - smoothstep(0.0, 1.0, r), 1.6)
				var cloud := 0.6 + 0.4 * noise.get_noise_2d(x, y)
				img.set_pixel(x, y, Color(1, 1, 1, clampf(base * cloud, 0.0, 1.0)))
		_puff = ImageTexture.create_from_image(img)
	return _puff


## A material for soft particles of `colour`, facing the camera, drawn over the water.
static func soft(colour: Color, glow := 0.0) -> StandardMaterial3D:
	var key := [colour, glow]
	if not _materials.has(key):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.billboard_keep_scale = true
		m.albedo_texture = puff()
		m.albedo_color = colour
		m.vertex_color_use_as_albedo = true
		m.proximity_fade_enabled = true
		m.proximity_fade_distance = 0.6
		m.render_priority = 10
		if glow > 0.0:
			m.emission_enabled = true
			m.emission = colour
			m.emission_energy_multiplier = glow
		_materials[key] = m
	return _materials[key]


static func _particles(parent: Node, at: Vector3, colour: Color, life: float, glow := 0.0) -> CPUParticles3D:
	if _quad == null:
		_quad = QuadMesh.new()
	var p := CPUParticles3D.new()
	p.mesh = _quad
	p.material_override = soft(colour, glow)
	p.one_shot = true
	p.lifetime = life
	p.local_coords = false
	p.angle_min = -180.0
	p.angle_max = 180.0
	p.position = at
	parent.add_child(p)
	p.emitting = true
	parent.get_tree().create_timer(life + 0.5, false, true).timeout.connect(p.queue_free)
	return p


static func _ramp(points: Array) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(points.map(func(q: Array) -> float: return q[0]))
	g.colors = PackedColorArray(points.map(func(q: Array) -> Color: return Color(1, 1, 1, q[1])))
	return g


static func _growth(from: float, to: float) -> Curve:
	var c := Curve.new()
	c.min_value = 0.0
	c.max_value = maxf(from, to)
	c.add_point(Vector2(0, from), 0, 0)
	c.add_point(Vector2(1, to), 0, 0)
	return c


## Gun smoke from a muzzle at `at`, blown out along `dir`: a thick white cloud that spreads, rises a
## little and thins away. For show.
static func smoke(parent: Node, at: Vector3, dir: Vector3) -> void:
	var p := _particles(parent, at, Color(0.88, 0.88, 0.9), 8.0)
	p.amount = 48
	p.explosiveness = 0.92
	p.direction = dir
	p.spread = 14.0
	p.initial_velocity_min = 1.0
	p.initial_velocity_max = 9.0
	p.damping_min = 4.0
	p.damping_max = 7.0
	p.gravity = Vector3(0, 0.2, 0)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.4
	p.scale_amount_min = 4.0
	p.scale_amount_max = 7.0
	p.scale_amount_curve = _growth(0.3, 2.0)
	p.color_ramp = _ramp([[0.0, 0.0], [0.03, 1.0], [0.35, 0.7], [1.0, 0.0]])
	# The flash: a moment of fire at the muzzle.
	var f := _particles(parent, at + dir * 0.6, Color(1.0, 0.72, 0.32), 0.12, 6.0)
	f.amount = 4
	f.explosiveness = 1.0
	f.direction = dir
	f.spread = 10.0
	f.initial_velocity_min = 2.0
	f.initial_velocity_max = 6.0
	f.gravity = Vector3.ZERO
	f.scale_amount_min = 1.0
	f.scale_amount_max = 1.8
	f.color_ramp = _ramp([[0.0, 1.0], [1.0, 0.0]])
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.72, 0.4)
	light.light_energy = 8.0
	light.omni_range = 8.0
	light.position = at
	parent.add_child(light)
	parent.get_tree().create_timer(0.08, false, true).timeout.connect(light.queue_free)


## A column of spray where shot meets the water at `speed`: droplets thrown up and falling back, and
## mist that hangs and thins. For show.
static func plume(parent: Node, at: Vector3, speed: float) -> void:
	var up := clampf(0.04 * speed, 3.0, 14.0)
	var g := -float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	var p := _particles(parent, at, Color(0.95, 0.97, 1.0), 1.8)
	p.amount = 90
	p.explosiveness = 0.9
	p.direction = Vector3.UP
	p.spread = 11.0
	p.initial_velocity_min = 0.35 * up
	p.initial_velocity_max = up
	p.gravity = Vector3(0, g, 0)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.25
	p.scale_amount_min = 0.4
	p.scale_amount_max = 1.1
	p.color_ramp = _ramp([[0.0, 0.95], [0.7, 0.7], [1.0, 0.0]])
	var m := _particles(parent, at, Color(0.92, 0.95, 0.98), 2.6)
	m.amount = 10
	m.explosiveness = 0.8
	m.direction = Vector3.UP
	m.spread = 25.0
	m.initial_velocity_min = 0.2 * up
	m.initial_velocity_max = 0.45 * up
	m.damping_min = 1.5
	m.damping_max = 3.0
	m.gravity = Vector3(0, -1.0, 0)
	m.scale_amount_min = 2.0
	m.scale_amount_max = 4.0
	m.scale_amount_curve = _growth(0.5, 1.6)
	m.color_ramp = _ramp([[0.0, 0.0], [0.1, 0.55], [1.0, 0.0]])


## A puff of wood dust where shot strikes planking at `at`, along `out`. For show.
static func dust(parent: Node, at: Vector3, out: Vector3) -> void:
	var p := _particles(parent, at, Color(0.55, 0.45, 0.35), 1.6)
	p.amount = 14
	p.explosiveness = 0.95
	p.direction = out
	p.spread = 35.0
	p.initial_velocity_min = 1.0
	p.initial_velocity_max = 5.0
	p.damping_min = 2.0
	p.damping_max = 4.0
	p.gravity = Vector3(0, -0.5, 0)
	p.scale_amount_min = 0.3
	p.scale_amount_max = 0.9
	p.scale_amount_curve = _growth(0.5, 1.8)
	p.color_ramp = _ramp([[0.0, 0.8], [1.0, 0.0]])
