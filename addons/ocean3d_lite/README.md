# Ocean3D Lite

The free core of **Ocean3D: Water, Waves & Buoyancy for Godot 4**,
MIT licensed.

What you see is what bodies feel: one Gerstner wave function drives
both the visual surface and the physics, so floating objects ride
exactly the water you render.

## Included (Lite)

- `Ocean` autoload: exact water height and surface velocity at any
  world point. Deterministic.
- `OceanSurface`: drop-in endless ocean (camera-following detail
  tile + horizon skirt, no seams), storm styling.
- `OceanWaveProfile` resources; calm and lively presets.
- `FloatingBody`: multi-probe buoyancy with per-probe weights and
  surface-relative damping.
- `Ocean.storm_scale`: one variable swells the sea for physics and
  visuals together.

## Quickstart

1. Enable the plugin (registers the `Ocean` autoload).
2. Add an **OceanSurface** node to a 3D scene, pick a wave profile.
3. Add a **FloatingBody** with a collision shape, a mesh, and four
   corner probe points.
4. Press play. Sea level is world y = 0.

## The full version adds

- Wake: waterline foam ring, churn trail that follows the boat's
  actual path through turns, entry foam, speed- and wave-driven bow
  spray.
- Whitecaps on breaking crests, wind streaks on raging seas.
- Storm and swell presets built for storm scaling.
- Editor gizmos for probe placement.
- Three demo scenes, a WASD demo boat, and the full manual.

Get it: [link to the Ocean3D store page goes here]

Remove Lite before installing the full version (they provide the
same classes and the same autoload).
