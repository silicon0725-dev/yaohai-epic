# Bounded Buoyancy native kernel (optional)

This folder is an optional speed-up for the Bounded Buoyancy plugin. It does one job in compiled code: cutting each body's shape at the waterline to find the volume under water and its centre. The plugin finds this folder by itself and gives the same results with or without it; with it, bodies crossing the surface cost many times less, so hundreds of them can float at once.

It ships ready to use on **Windows (64-bit)** and **Linux (64-bit)**.

**On other platforms** (macOS, Linux on ARM, Android, iOS, the web), delete this folder and the plugin runs on GDScript alone, or build the kernel for your platform from the `native/` folder of the repository (instructions there; the repository's GitHub workflow builds Windows, Linux and macOS automatically). If you leave the folder in place on a platform it has no build for, Godot prints errors at start-up saying it found no library for this platform, and the plugin carries on without the kernel.

The Linux build needs a system from about 2021 on (for example Ubuntu 22.04 or Debian 12).

To compare, set `BoundedBuoyancyBody.use_native = false` in a script: everything runs in GDScript.
