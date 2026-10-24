# Precompiled HIP GPU Modules (RDNA4 / gfx1200)

The RX 9060 series' build of the same 40 modules as `../modules` (gfx1201), from the same `../hip` sources and
recipe (`hip/build-modules.ps1 -Targets gfx1200`, the driver's `amd_comgr_3.dll`). Packaged as `lmxxf-modules-gfx1200`
beside `lmxxf-modules`; `LmxxfNrRuntime.dll` asks HIP for the GPU's architecture and loads these on gfx1200.

- **Upstream Repository**: https://github.com/lmxxf/dlss5-on-amd-9070xt-porting
- **Commit Base**: `8181b5f2ffd2c085ad2e05d4309a0c8d06b672cc` (0.45)
- **License**: MIT, Copyright (c) 2026 Kien (`../LICENSE`)
