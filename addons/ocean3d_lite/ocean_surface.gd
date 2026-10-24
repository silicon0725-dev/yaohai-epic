class_name OceanSurface
extends Node3D

# The drop-in visual ocean. Builds two camera-following tiles and
# pushes the Ocean autoload's wave state into their shader every
# frame, so the surface you see is exactly the surface FloatingBody
# probes feel:
#
#   near tile: dense grid, full Gerstner displacement, the sea you
#     float on. Displacement fades to zero between disp_fade_start
#     and disp_fade_end so its edge is dead flat.
#   horizon skirt: huge coarse grid, displacement forced off
#     (disp_scale 0), riding far_drop below sea level so wave troughs
#     inside the near tile never poke through it. A camera-centered
#     hole is discarded in fragment so a submerged camera never sees
#     the skirt as a lid overhead.
#
# Both tiles chase the active camera, translation only. The shader
# evaluates waves at WORLD xz, so the meshes slide under a world-fixed
# wave field and vertices never swim. Sea level is world y = 0 (the
# same zero Ocean.get_height oscillates around); this node's own
# transform is deliberately ignored.
#
# One OceanSurface per scene. Anything that paints on the water (the
# WakeEmitter's hull_* uniforms) reaches the shader through `material`.
# Tile geometry knobs are read once at _ready; the fade distances,
# profile, and storm styling are live.

const _SHADER := preload("shaders/ocean.gdshader")

# Assigned to Ocean.profile on ready when set. Leave null to keep
# whatever profile the Ocean autoload already has (default: calm).
@export var wave_profile: OceanWaveProfile

@export_group("Detail tile")
@export var tile_size := 260.0
@export var tile_subdiv := 190
# Displaced vertices can leave the mesh AABB and get culled at glancing
# angles; the custom AABB pads vertically to prevent pop-out. Size it
# past your tallest expected crest (storm_scale included).
@export var aabb_pad := 8.0
# Visual LOD only, physics never fades: displacement ramps to zero
# between these camera distances so the tile edge is dead flat and
# meets the skirt without a seam. Keep disp_fade_end inside
# tile_size / 2, or the fade rim leaves the mesh.
@export var disp_fade_start := 90.0
@export var disp_fade_end := 126.0

@export_group("Horizon skirt")
@export var far_size := 9000.0
@export var far_subdiv := 15
@export var far_drop := 0.5

@export_group("Storm styling")
# When on, sea color, roughness, and specular lerp from the fair set
# to the storm set as Ocean.storm_scale climbs from 1.0 toward the
# profile's storm_scale_max: a calm near-mirror sea that throws sharp
# glints goes rough, matte, and slate at full rage. Turn off to grade
# the sea yourself through `material`.
@export var storm_styling := true
@export var fair_deep_color := Color(0.012, 0.09, 0.16)
@export var fair_shallow_color := Color(0.10, 0.38, 0.44)
@export_range(0.0, 1.0) var fair_roughness := 0.08
@export_range(0.0, 1.0) var fair_specular := 0.6
@export var storm_deep_color := Color(0.020, 0.045, 0.060)
@export var storm_shallow_color := Color(0.075, 0.115, 0.135)
@export_range(0.0, 1.0) var storm_roughness := 0.58
@export_range(0.0, 1.0) var storm_specular := 0.28

# The near tile's ShaderMaterial. WakeEmitter and custom grading talk
# to this. The skirt uses `far_material`, a duplicate with
# displacement off; color pushes go to both so the two tiles never
# split at the horizon seam.
var material: ShaderMaterial
var far_material: ShaderMaterial

var _near: MeshInstance3D
var _far: MeshInstance3D


func _ready() -> void:
	# WakeEmitter (and future kit pieces) find the surface through this
	# group when not wired explicitly.
	add_to_group("ocean3d_surface")
	if wave_profile != null:
		Ocean.profile = wave_profile

	var plane := PlaneMesh.new()
	plane.size = Vector2(tile_size, tile_size)
	plane.subdivide_width = tile_subdiv
	plane.subdivide_depth = tile_subdiv

	material = ShaderMaterial.new()
	material.shader = _SHADER

	_near = MeshInstance3D.new()
	_near.name = "OceanNear"
	_near.mesh = plane
	_near.material_override = material
	_near.custom_aabb = AABB(
		Vector3(-tile_size / 2.0, -aabb_pad, -tile_size / 2.0),
		Vector3(tile_size, aabb_pad * 2.0, tile_size)
	)
	# The surface must not cast a shadow: it would put the entire
	# underwater world in the dark.
	_near.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_near.top_level = true
	add_child(_near)

	var far_plane := PlaneMesh.new()
	far_plane.size = Vector2(far_size, far_size)
	# The skirt never displaces; it only needs enough vertices to
	# survive frustum culling math.
	far_plane.subdivide_width = far_subdiv
	far_plane.subdivide_depth = far_subdiv

	far_material = material.duplicate()
	far_material.set_shader_parameter("disp_scale", 0.0)
	# Just inside the near tile's half-size, so the skirt still
	# overlaps the tile edge but never renders beneath a submerged
	# camera.
	far_material.set_shader_parameter("hole_radius", tile_size * 0.5 - 2.0)

	_far = MeshInstance3D.new()
	_far.name = "OceanHorizon"
	_far.mesh = far_plane
	_far.material_override = far_material
	_far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_far.top_level = true
	add_child(_far)

	_push_wave_state()


func _process(_delta: float) -> void:
	_push_wave_state()
	_follow_camera()
	if storm_styling:
		_apply_storm_styling()


# Wave table, time, and storm scale go to BOTH tiles every frame. The
# skirt never displaces, but its per-fragment normals evaluate the
# same wave field; matching time and amplitude keep shading continuous
# across the tile boundary. Per-frame push (4 vec3s) is cheap and
# makes live profile edits in the inspector show up instantly.
func _push_wave_state() -> void:
	var waves := Ocean.waves_for_shader()
	for m in [material, far_material]:
		m.set_shader_parameter("waves", waves)
		m.set_shader_parameter("t", Ocean.time)
		m.set_shader_parameter("storm_scale", Ocean.storm_scale)
	material.set_shader_parameter("disp_fade_start", disp_fade_start)
	material.set_shader_parameter("disp_fade_end", disp_fade_end)


# The tiles chase the active camera so the water never ends.
# Translation only: the shader reads world xz, so the wave field stays
# put while the mesh slides under it.
func _follow_camera() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var eye := cam.global_position
	_near.global_position = Vector3(eye.x, 0.0, eye.z)
	_far.global_position = Vector3(eye.x, -far_drop, eye.z)


# Rage 0.0 at calm (storm_scale 1.0), 1.0 when storm_scale reaches the
# profile's storm_scale_max. A profile capped at 1.0 never rages by
# scale; drive the look yourself through `material` if you want a
# grim-but-flat sea.
func _apply_storm_styling() -> void:
	var cap: float = maxf(Ocean.profile.storm_scale_max, 1.001)
	var rage: float = clampf((Ocean.storm_scale - 1.0) / (cap - 1.0), 0.0, 1.0)
	var deep := fair_deep_color.lerp(storm_deep_color, rage)
	var shallow := fair_shallow_color.lerp(storm_shallow_color, rage)
	var rough := lerpf(fair_roughness, storm_roughness, rage)
	var spec := lerpf(fair_specular, storm_specular, rage)
	for m in [material, far_material]:
		m.set_shader_parameter("deep_color", deep)
		m.set_shader_parameter("shallow_color", shallow)
		m.set_shader_parameter("roughness_value", rough)
		m.set_shader_parameter("specular_value", spec)
