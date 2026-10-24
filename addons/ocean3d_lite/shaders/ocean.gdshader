shader_type spatial;
render_mode cull_disabled;

// Ocean3D LITE surface shader. Must mirror ocean.gd exactly;
// OceanSurface pushes the wave table and time into these uniforms so
// physics and visuals stay in sync.
// waves[i] = (direction_degrees, steepness, wavelength_meters)
// Array size must match OceanWaveProfile.MAX_WAVES.
//
// The full version of Ocean3D adds on top of this file: hull wake
// (waterline ring, path-following churn trail, entry foam),
// whitecaps on breaking crests, and wind streaks on raging seas.
uniform vec3 waves[4];
uniform float t = 0.0;

// Storm amplitude multiplier, mirrors Ocean.storm_scale (see ocean.gd).
uniform float storm_scale = 1.0;

uniform vec3 deep_color : source_color = vec3(0.012, 0.09, 0.16);
uniform vec3 shallow_color : source_color = vec3(0.10, 0.38, 0.44);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.08;
uniform float specular_value : hint_range(0.0, 1.0) = 0.6;

// Visual LOD only, physics never fades: displacement ramps to zero
// between these camera distances so the detail tile's edge is dead
// flat and meets the flat horizon skirt without a seam.
uniform float disp_scale : hint_range(0.0, 1.0) = 1.0;
uniform float disp_fade_start = 90.0;
uniform float disp_fade_end = 126.0;

// Horizon skirt only (0 = off): drop fragments within this radius of
// the camera so a submerged camera never sees the skirt as a lid.
uniform float hole_radius = 0.0;

varying vec2 world_xz;

const float G = 9.8;

vec3 gerstner(vec2 xz) {
	vec3 p = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		float ang = radians(waves[i].x);
		vec2 dir = vec2(cos(ang), sin(ang));
		float steepness = waves[i].y;
		float k = 6.28318530718 / waves[i].z;
		float c = sqrt(G / k);
		float a = steepness * storm_scale / k;
		float f = k * (dot(dir, xz) - c * t);
		p.x += dir.x * a * cos(f);
		p.y += a * sin(f);
		p.z += dir.y * a * cos(f);
	}
	return p;
}

void vertex() {
	// The tiles follow the camera: translated every frame, never
	// rotated or scaled. Waves evaluate at WORLD xz, so the mesh
	// slides under a world-fixed wave field and vertices never swim.
	vec2 xz = VERTEX.xz + MODEL_MATRIX[3].xz;
	world_xz = xz;
	float fade = disp_scale
		* (1.0 - smoothstep(disp_fade_start, disp_fade_end,
			distance(xz, CAMERA_POSITION_WORLD.xz)));
	VERTEX += gerstner(xz) * fade;
}

void fragment() {
	if (hole_radius > 0.0
			&& distance(world_xz, CAMERA_POSITION_WORLD.xz) < hole_radius) {
		discard;
	}
	// Normals from finite differences on the wave field, per fragment
	// and at FULL amplitude on both tiles, independent of the
	// displacement fade, so shading stays continuous across the
	// detail tile's flat rim and the horizon skirt. The step widens
	// with distance, low-passing wave detail that has gone sub-pixel.
	float e = 0.6 + distance(world_xz, CAMERA_POSITION_WORLD.xz) * 0.012;
	vec3 dc = gerstner(world_xz);
	vec3 tx = vec3(e, 0.0, 0.0) + gerstner(world_xz + vec2(e, 0.0)) - dc;
	vec3 tz = vec3(0.0, 0.0, e) + gerstner(world_xz + vec2(0.0, e)) - dc;
	vec3 n_world = normalize(cross(tz, tx));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = mix(deep_color, shallow_color, fres);
	ROUGHNESS = roughness_value;
	METALLIC = 0.0;
	SPECULAR = specular_value;
}
