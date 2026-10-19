# mochizuki0323/DLSSNR-AMD

The Vulkan network behind `MochizukiNrRuntime.dll` (`NrBackend=mochizuki`).

- Source: https://github.com/mochizuki0323/DLSSNR-AMD
- Pinned commit: `8a70f7f4` (2026-10-14, tag v0.0.5-win-preview): `windows/` as upstream has it, apart from the local
  patches below; plus upstream's hotfix `f35f00f` (2026-10-15, `nr_pal_binary.hpp`: ACO accepts gfx1200, the RX 9060
  series, as well as gfx1201), and `windows/src/core/` from `ab00d2b` (2026-10-17, v0.0.6-win-preview-alpha: the new
  model of `nvngx_dlssnr.dll` 310.9.16, see The model); no shader changed
- `linux/package/model-tools/` is still from `791b046` (v0.0.1); the model it makes has not changed
- Licence: MIT, `LICENSE` beside this file

## What is here

Only what the runtime build reads, at the upstream paths:

| Path | Use |
|---|---|
| `windows/src/core/` | the network runtime (`nr::Runtime`), compiled into the DLL |
| `windows/shaders/` | the network and the passes around it, GLSL |
| `windows/build/build_network.py`, `unroll_glsl.py`, `quad_quant_glsl.py` | GLSL to SPIR-V, the upstream way |
| `windows/build/arch/rdna4.sh` | the constants host and shaders share; `tools/build-mochizuki-runtime.cmd` repeats them |
| `linux/package/model-tools/` | makes `dlssnr.bin` from a user's `nvngx_dlssnr.dll` 310.8.0 |
| `linux/shaders/rdna3/`, `linux/build/arch/rdna3.sh`, `LICENSE-rdna3` | the RDNA3 network, from mauri870/DLSSNR-RDNA3 (see RDNA3) |

Since v0.0.5 `windows/src/core/` also holds upstream's RenoDX stage (`nr_renodx.*`, `renodx/`), int4 mixed
(`nr_ini_int4.hpp`, `NR_INT4`) and ACO pipeline binaries (`nr_pipeline_binary.hpp`, `nr_pal_binary.hpp`). All three
are built and run as the sections below say (ACO, int4 mixed, RenoDX); `nr_renodx_keys.hpp` (upstream's INI names) is
not compiled, since OptiScaler's `[DlssNr]` keys set the stage.

Upstream's `windows/src/pe/` (its own NGX and ReShade hosts, which need the game to run on vkd3d-proton),
`windows/package/` and `windows/vulkan-loader/` are not used. `OptiScaler/dlssnr/backend/mochizuki_runtime/
MochizukiNrRuntime.cpp` hosts the runtime instead, on a Vulkan device of its own, behind the lmxxf C ABI.

## Local patches

1. `windows/src/core/nr_runtime.hpp` and `nr_graph.cpp`: a host's stop flag for a network build. `nr::build_cancel`
   is a thread-local pointer to an `std::atomic<bool>`, set around the `Runtime` constructor with
   `nr::BuildCancelScope`; the graph build's pipeline loop checks it before each pipeline and, once set, writes the
   pipeline cache it has so far and throws `NR build cancelled`. `MochizukiNrRuntime.dll`'s `Destroy` during a cold
   build then returns in under a second instead of waiting out the compile, and the next start keeps what was
   compiled. Null by default.
2. `windows/shaders/rdna4/pipelines.json`: `NR_EDGE_BODIES=0` on the eight pipelines upstream builds with 1
   (`fswin32` and the six folded persistent runs, `fswinp256`). An edge body is a copy of the window body for the
   windows at the image's edge; LLPC compiles each copy, and the folded runs' SPIR-V grows 5 to 7 times.
   - Output byte-identical with and without (1080p runtime dumps).
   - Cold network build with no prewarm list and no driver cache (a fresh exe name): 109 s with them, 23.4 s
     without (164 s the first time ever, before the AMD driver had any of it). With the prewarm list: 49 s and 6.1 s.
   - Network time, three interleaved runs each (runtime's own GPU time): 1080p 8.48-8.52 ms with them,
     8.51-8.70 ms without; 1440p 14.95-15.01 and 14.91-15.15 ms. Within the noise.
3. `windows/src/core/nr_runtime.cpp`: `NR_GRAPH_ARGS` (diagnostic), more graph options after the runtime's own.
4. (0.5.3) `nr_runtime.cpp` `resolve_frame_pass`: Intensity above 1 extrapolates on the frame's last pass only; the
   passes before stop at 1 (it compounded to about ratio^8 over three passes).
5. (0.5.3) `shaders/passes/cascade_blur.comp` (windows and linux, the ACO build reads linux/): the detail-only
   cascade's low-pass is edge-aware, weighted by the first pass's input in log luminance, binding 2 = `shown_keep`.
   The box blur left a band of its radius (`mh/60`) around thin edges.
6. (0.5.3) `Controls::anti_halo` and `anti_halo_margin`: `shaders/passes/runtime_dehalo.comp` after the last pass
   holds the answer's luminance inside the first pass's 3x3 range (the first answer is kept in `first_answer`).
7. (0.5.3) `Controls::pass3_estimate`: with three passes the third is `runtime_predict_gain.comp` and
   `runtime_predict_apply.comp`, after lmxxf's `multi_pass_predict.hip`; its timestamps still bracket it.
8. (0.5.4) `nr_runtime.cpp`: `RuntimeConfig::max_passes` up to 30 (upstream refuses above 16), and the timing read's stamp
   array sized for it, after TheAutomatic/dlss-5-amd-project's `08-thirty-layer-mode.patch` (GPL-3.0), for the host's
   `MochizukiUnlockPasses`. 1 to 16 passes run as before (byte-identical at 1 and 3).
9. (0.5.4) `nr_runtime.hpp`/`.cpp`: `RuntimeConfig::first_pass_output`, after TheAutomatic/dlss-5-amd-project's
   `04-first-pass-output.patch` (GPL-3.0), for the host's person protection (`NrPersonPartition`): after pass 1 the
   transfer runs once more into a frame-sized RGBA32F `first_full` (`first_pass_output()`), skipped with the
   preprocess on or the model not applied (`first_pass_written()`). Off, nothing is made or recorded.
10. (0.5.4) `nr_renodx.hpp`/`.cpp`: `StageConfig::first_format` and `StageFrame::first`, the same first pass for the RenoDX
    stage: before pass 2 runs, pass 1's result in the frame's encoding (HDR: the pedestal reduce and the commit, as
    the stack's end makes them, into a `first_out` of the result's format; SDR: the pass's own image) is blitted into
    the host's image; with NR off, the frame as it goes out (`exports_first()`, `first_written()`). Without it set,
    nothing is made or recorded: output byte-identical at 1 and 3 passes, and pass 1 equal to a one-pass run's.
11. (0.5.4) `windows/shaders/renodx/v6_common.hlsli` `ResolvePixel`, the display codec (`Curve == 1`): upstream lerps the
    whole bounded gain by `ColorStrength` and never reads `TransferStrength` there, so colour 0 turned the network
    off. The gain is now `exp2(trust * (TransferStrength * luma + ColorStrength * chroma))`, the split the divisor
    family already makes; at 1 and 1 the same gain as before. `nr_renodx.cpp` `chain_active` follows: a Display
    frame changes the image when either strength is above 0 (upstream: colour, or transfer with pedestal removal).

The new passes are in both `build_network.py` `RUNTIME` lists.

### Sync to v0.0.5 (2026-10-14)

Upstream took in both driver 32.0.32015 fixes of 2026-10-04 (the unrolled `ffwd3_t`, `attn` and `vit_attn`, and
`vit_attn`'s padding tile, now killed after the load rather than chosen before it), so they are no longer local.
`NR_TCHAIN_TILES=1` joined `rdna4.sh` and the build script. Every pipeline now carries a
`VkPipelineRobustnessCreateInfoEXT` with robust access off where the driver has the extension; the prewarm
(`mz_interpose.cpp`) records and replays it, and its manifest is version 2 (a version 1 list is refused and made again).

The runtime's own GPU time, RX 9070 XT, driver 32.0.32015, against the 0.5.1 release (same harness, pan of 8 px a
frame): 1080p 13.9 / 13.9 ms, 2 / 3 passes 28.0 / 27.4 and 41.6 / 40.3, 1707x961 11.6 / 11.4, 1280x720 7.9 / 7.6,
3840x2160 51.7 / 50.9. Output byte-identical at 1080p (1, 2 and 3 passes, R10G10B10A2), 1707x961, 1280x720,
1129x635, 4K and without motion vectors; 53-56 dB from it with an RGBA32F frame and with the preprocess on.
Not taken: `forget_history`/`drop_history`, which the host does not call yet. Upstream's enlargement below 100% model
scale (`Controls::transfer`, `classic_scaler`) and `noise_every_frame` are the host's `MochizukiEnlargeMode`,
`MochizukiClassicScaler` and `MochizukiNoiseEveryFrame` since 2026-10-17.

Host side (not in this tree): `MochizukiNrRuntime.cpp` enables `bufferDeviceAddress` when the driver offers it and
sets `HostDevice::buffer_device_address`; marks its colour and motion images `SAMPLED`
(`ColourFrame::usage`), so the core reads them in place; and sets `RuntimeConfig::preprocess_unknee` on the linear
path. `nr_runtime.cpp` is compiled with the defines of `rdna4.sh`.

### Dropped on 2026-10-02

The previous pin was `791b046` (v0.0.1) with sixteen patches, most of them parts of upstream's `linux/` tree
ported by hand and tuned for LLPC. Upstream's `windows/` now carries all of it, rebuilt for the AMD Windows driver
(228d3a6, b1419b0) and with the motion and history work of d1185d2:
- the history ping-pong, the preprocess, the colour formats and the post block's 0.7397 weight (old 12, 16) are
  upstream's own;
- the frame kept in its own format and read in place (old 13) is upstream's `ColourFrame::usage` path;
- the alpha pass skipped where it changes nothing (old 14) is upstream's `NR_POST_ALPHA`;
- the pre block's round-to-nearest colour input (old 15) is upstream's `NR_HALF_RTE`, which on LLPC gives the same
  bytes as ours did (RGBA32F frames with values between two halves, compared byte for byte);
- word-wide e4m3 reads, quad quantisation, the V tiles in rows and the work-split knobs (old 2 to 4, 7 to 11) have
  upstream equivalents (`NR_WLOAD_U32`, `NR_WPAIR_U32`, `quad_quant_glsl.py`, `NR_V_LDS_ROW`), tuned by upstream;
- the MSVC cast (old 1) is fixed upstream.

Measured against the previous build (RX 9070 XT, driver of 2026-08-18, the runtime's own GPU time):

| Case | Previous | Now |
|---|---|---|
| 1080p, 1 pass | 9.18-9.34 ms | 8.45-8.52 ms |
| 1080p, 2 / 3 passes | 29.0 / 42.3 ms | 25.8 / 38.3 ms |
| 1707x961 / 1280x720 | 12.7 / 8.6 ms | 11.0 / 7.6 ms |
| 3840x2160 | 55.6 ms | 48.1 ms |
| Cold build with the prewarm list | 7.6 s | 6.1 s |

The output is 49-56 dB from the previous build at 1080p and above (upstream's per-frame noise and the changes
above). A pan with exact motion vectors at 1707x961 and 1280x720 is about ten times steadier frame to frame than
before (mean |out_n - shift(out_n-1)| 0.0007 against 0.0102 and 0.0075), the motion-vector work of d1185d2.

## ACO (OptiScaler's `MochizukiAco`)

Upstream's [Network] ACO Mode: the network as machine code made in advance with Mesa's ACO, loaded through
`VK_KHR_pipeline_binary` instead of compiled by the AMD driver. Vendored for it: `linux/build/build_network.py`,
`linux/shaders/rdna4/` and `linux/shaders/passes/` (the Linux network, which the records were made from), and
`windows/data/aco/records/` and `shell-aliases.txt` (58 records; int4's are not taken). The build script writes
`dlssnr-amd/aco/` beside the shaders: `shaders/` built from the Linux sources, `records/`, `shell-aliases.txt`.
Each record is named by the FNV-1a hash of its SPIR-V, so the Linux network must build byte for byte as upstream's
(glslang 16.5.0): all 58 match.

The host (`MochizukiNrRuntime.cpp`) takes `LMXXF_NR_CREATE_FLAG_ACO`: once a process, before its Vulkan device,
`nr::binary::configure` with the bundle, the shell folders (`aco/shell`, our `shaders`, `shaders/temporal`) and
`dlssnr-amd/aco-cache/` for the imports; the device gets pipeline binaries and maintenance5 through
`nr::binary::Features` when the driver offers them, else the core falls back to the driver's compiler. Our
`NR_EDGE_BODIES=0` shaders serve only as templates for the code's container, so the patch stays. The native prewarm
list is skipped with ACO on (the imports are cached instead).

Measured with the harness (RX 9070 XT, AMD Software 26.9.2, pan 8 px a frame), the runtime's own GPU time, driver
compiler / ACO: 1080p 13.9 / 10.5 ms, 2 passes 27.4 / 20.2, 1707x961 11.4 / 8.9, 1280x720 7.6 / 6.0, 3840x2160
50.9 / 38.5. Picture 54-57 dB from the driver-compiled one. First start 22.5 s (the imports), then 1.5 s.

## int4 mixed (OptiScaler's `MochizukiInt4`)

Upstream's second network, part of it in 4-bit integers, built only as ACO's machine code. Vendored for it:
`linux/data/int4/rdna4/` (the quantisation tables `vit/` and `swin/`, `settings.txt`, the weights' hash),
`linux/shaders/rdna4/pipelines-int4.json`, `windows/data/aco/int4/` (71 records and their aliases) and
`windows/src/tools/nr_int4_weights.cpp`. The core is compiled with `NR_INT4=1` (every unit: `RuntimeConfig` holds
`int4_mixed` under it). The build writes `dlssnr-amd/aco/int4/` (the Linux int4 network and its records, the aliases
merged into `aco/shell-aliases.txt`) and `dlssnr-amd/int4/` (the tables, settings and the same SPIR-V); with
`MZ_MODEL` set to a `dlssnr.bin` it also runs `dlssnr-int4-weights.exe` and writes `dlssnr-amd/dlssnr-int4.bin`
(53 MB, 8 s), checked against `dlssnr-int4.sha256`: the model the payload pins gives upstream's hash exactly. All 71
records match the SPIR-V built here.

The host asks for it a frame at a time (`LMXXF_NR_FRAME_FLAG_INT4`, part of the network key): a change rebuilds the
network while the frames keep the current one where VRAM allows, then frees it; one network stays resident (no
upstream KeepBoth). Without ACO or the files the core logs why and builds the default network.

Harness (as above, ACO on), default / int4: 1080p 10.1 / 9.2 ms, 1280x720 5.9 / 5.2, 3840x2160 38.5 / 34.9. The
picture is 39-41 dB from the default network's, 0.6-0.8% darker on average. A switch in a running session: the int4
network ready in 4.5 s, the frames on the old one meanwhile. First int4 build 23 s (the imports), then 4.7 s.

## RenoDX (always on in OptiScaler)

Upstream's RenoDX stage (`windows/src/core/nr_renodx.*`, `renodx/codec_gain.hpp`; RenoDX DLSS5 add-on v8.5.0-rc10,
MIT, `renodx/LICENSE`) is compiled into the DLL as it is, with its shaders: `windows/shaders/renodx/` built with Slang
2026.19 (`RENODX_VULKAN`) and `windows/shaders/renodx-prep/` with glslang, into `dlssnr-amd/shaders/renodx/`
(`tools/build-mochizuki-renodx.py`, which also checks `prep_math.glsl` against `runtime_prep.comp` as upstream does).
No core patch: the stage only uses the core's `record_engine` with a target and a feature per pass, and, for a frame
without motion vectors, `record` in place on a copy of the proxy. The stage itself carries local patch 10.

The host side is TheAutomatic/dlss-5-amd-project's integration (GPL-3.0): with `MochizukiNrControls::renodx` the
network is built for the stage's extent (`working_resolution`), RGBA16F, one pass, `native_compose`, and
`ProductRuntime` holds the stage; each frame the stage encodes the frame, calls the network once per pass of its
stack (1-4, 1-30 unlocked; feature pass + 1, passes 5 and later with pass 4's controls), and composes back into the
frame's image. The game's exposure (`MochizukiNrSetExposure`) is RenoDX's feed, else its content meter. The game's
depth is not passed (it is at the frame's extent). OptiScaler's own composition (`RenoComposition`) stays for
danielblnc and lmxxf and is skipped with mochizuki. Its ~85 `MochizukiReno*` keys and defaults are theirs, RenoDX's
own. Since 2026-10-17 the stage is always on (`MochizukiNrControls::renodx` defaults to 1 and OptiScaler always sends
1), and the host's own model, pass, scale, strength, white point and enlargement keys are gone in favour of the
stage's; the runtime still runs the network on its own for a host that sends 0.

Harness, RX 9070 XT, 1080p RGBA16F, ACO, pan 8 px a frame, wall time a frame with a full wait (not GPU time): off
31.4 ms, RenoDX 1 / 2 / 6 passes 31.8 / 36.2 / 61.3 ms; the SDR path (R10G10B10A2, legacy codec) runs too.

## RDNA3 (RX 7000, no FP8)

The same network on gfx11, from mauri870/DLSSNR-RDNA3 (branch `rdna3`, a fork of upstream at `939b607`):

- Source: https://github.com/mauri870/DLSSNR-RDNA3
- Pinned commit: `aa392284` (2026-10-16)
- Licence: MIT, `LICENSE-rdna3` beside this file (the fork's own file; the notice is upstream's)

Every e4m3 value is held as FP16 and multiplied in the FP16 x FP16 -> FP32 16x16x16 WMMA, the e4m3 rounding done in
ALU (the fork's `README-RDNA3.md`). Its kernels assume the gfx11 fragment layout the fork measured on RADV: an
accumulator component `c` of lane `l` is element `(2c + l/16, l % 16)`, an A or B fragment holds sixteen components a
lane, and the WMMA computes row `m` from lane half `m % 2` alone (`kswap` below).

Taken: `linux/shaders/rdna3/` (without `pipelines-int4.json`) and `linux/build/arch/rdna3.sh`, as the fork has them
but for local patch 12; and the fork's host changes to `linux/src/core` (7c6361d, 767911f, eecb894, 612b0ba), ported
into `windows/src/core` as local patch 13:
- `nrvk.hpp`: the FP16 matrix configuration instead of FP8, no float8 features on `adopt`; an FP16 twin of the
  activation and weight arenas (`Context::fp16_twin`), bound by `Kernel::create` to every binding whose block holds
  e4m3 data (found by block name, `e4m3_view_bindings`); alias bindings `16 + k` get the arena itself (raw 32-bit
  views: tile counters, sync words, scales); the runner zeroes the activation twin with the arena.
- `nr_graph.cpp`: the twins allocated beside the arenas, the weight twin uploaded as FP16 decodes of the e4m3 bytes;
  the grouped FFN tiles packed in pairs but plain `[row][k]` (`plain_tiles`); the fused Swin weight tiles left plain,
  with the odd rows of the tiles that meet register-built operands k-pair swapped (`kswap` in
  `shader-constants.txt`, also accepted by `nr_shader_manifest.hpp`).
- `nr_runtime.cpp` `kernel_set`: a second descriptor set binds twins and aliases as `create` does.

Left out: the fork's int4 mixed for gfx11 (its pipelines, the `iu4` rewrite of `v_wmma_i32_16x16x16_iu4` through
RADV's pipeline binaries), temporal reuse (`runtime_reuse_*`, `Controls::reuse_every`), the edit gain below 100% model
scale in `runtime_transfer.comp` (32f3b1c, it changes the RDNA4 picture), `--value-stats`, `linux/test/`,
`linux/src/pe/`, packaging and docs. `nr_device_features.hpp` (the Vulkan layer's) is not in the DLL.

Local patches:

12. `linux/shaders/rdna3/pipelines.json`: `NR_EDGE_BODIES=0` on its seven persistent runs (`fswinp256`, `fswinpds*`,
    `fswinpup*`), as local patch 2 does for RDNA4. With the edge bodies LLPC (AMD Software 26.9.2) crashes on
    `fswinp256`.
13. One DLL for both networks: the fork's compile-time `NR_ARCH_RDNA3` is `RuntimeConfig::rdna3` and
    `Context::rdna3` (set before `adopt`, and on the arena probe's session). With it the core reads
    `dlssnr-amd/shaders-rdna3/` and `pipeline-rdna3.cache`, turns ACO off, and the graph build takes the Linux
    network's kernel set (`linux_network()`, as ACO's: tile counters on the ViT, decoder and encoder kernels,
    `gemmprojc`, `fswin32` as the frame tick, the N-pair attention weights). The Linux network's push blocks have no
    arena address, so `gemm*` and `vitattn` push the Windows block without it (`aco_push_gap`, as ACO int4 does).
    The twins are destroyed with the arenas (the fork's runtime never frees them). The defines of `rdna3.sh` are
    `rdna4.sh`'s and `NR_ARCH_RDNA3=1`, so the core is compiled once, with `rdna4.sh`'s. Without `rdna3` every new
    branch is off: the RDNA4 network's SPIR-V is byte-identical and so is its output (harness, 720p, 1080p, 4K).
14. The build: `windows/build/build_network.py rdna3 --tree linux --no-quad` (new `--tree`), the Windows build's
    preprocessing and unroll applied to `linux/shaders/rdna3`; LLPC crashes on the fork's rolled loops (most fswin,
    ffwd3, attn and temporal post pipelines, as it does on the Linux RDNA4 network). `unroll_glsl.py` drops
    `[[dont_unroll]]` (`NR_EXPAND_HLOOP`, `NR_EXPAND_KLOOP`, kept rolled for RADV's register count), on which LLPC
    crashes too; no RDNA4 source has one. Its `.length()` = 8 is right here: only accumulators ask. No four-wide
    quantisation (`quad_quant_glsl.py` is written for the FP8 pair loops). So the SPIR-V is not the fork's; built
    plainly (`linux/build/build_network.py rdna3`, the same script, glslang and defines as the fork's
    `build_network.py rdna3`) it would be, and that build crashes LLPC.

The host (`MochizukiNrRuntime.cpp`) takes the RDNA3 network on an AMD device (as AMD's driver reports it, through
OptiScaler's GPU spoofing) without VK_EXT_shader_float8 or its features, when the FP16 configuration is reported;
VK_EXT_shader_float8 and its features are then neither required nor enabled. A device 0x75xx (RX 9000) without FP8 is
refused as before. A device with FP8 is preferred over one without on the same adapter. `MZ_FORCE_RDNA3=1` takes the
RDNA3 network on any card. ACO and int4 mixed are off with it. The prewarm uses `shaders-rdna3`,
`pipeline-rdna3.cache` and `prewarm\manifest-rdna3.txt`. The log says which network and why:
`[mochizuki] the RDNA3 network, on FP16 matrices: <reason>` or `[mochizuki] the FP8 network (VK_EXT_shader_float8)`.
The VRAM check adds the twins (336 MB and 384 bytes a model pixel).

On an RX 9070 XT with `MZ_FORCE_RDNA3=1` (driver 26.9.2) every pipeline compiles, the network builds (16 s cold at
1080p) and runs at 720p, 1080p and 4K without errors; the picture is wrong, as gfx12's fragment layout is not gfx11's.
Nothing has run on an RX 7000 yet.

## Build

`tools\build-mochizuki-runtime.cmd [out]` from an MSVC developer prompt, with the Vulkan SDK 1.4.357 or newer
(`VULKAN_SDK`) and Python. It downloads glslang 16.5.0, the version the upstream SPIR-V is pinned to, and Slang
2026.19 (SHA-256 checked, for the RenoDX shaders) into `toolchain\` here, and writes `MochizukiNrRuntime.dll` and
`dlssnr-amd\shaders\` (with `renodx\`) and `dlssnr-amd\shaders-rdna3\` (52 network, 8 temporal, 15 runtime) to
`out` (default `exports\mochizuki-runtime`).

The shader folder has 54 network, 5 temporal and 11 runtime pipelines (v0.0.5; `runtime\FidelityFX-FSR1-LICENSE.txt`
beside the FSR 1 EASU in `runtime_upscale`). The prewarm list (`dlssnr-amd\prewarm\manifest.txt`) must be made again
whenever the shaders change: run the runtime once at 720p, 1080p, 1440p and 3840x2160 (the larger ones add `ffwd3w`)
and take the list it writes.

## The model

Never shipped with the code. `dlssnr-amd\dlssnr.bin` beside the DLL is made from `nvngx_dlssnr.dll` 310.8.0
(SHA-256 `e16bcf15…6e1fc8e`) by the scripts in `linux/package/model-tools/`: `inspect_nr.py --extract`, the
five `unpack_*.py`, then `pack_model.py --verify model-files.sha256`, as `extract_model.sh` runs them. The result
is 599 entries, 147,756,560 bytes.

`nvngx_dlssnr.dll` 310.9.16 (SHA-256 `2bc19bc0…40e28789f`) holds that model (its preset 1, byte-identical
`dlssnr.bin`) and a new one, its default: `dlssnr-amd\dlssnr-small.bin`, 255 entries, 113,917,248 bytes (SHA-256
`7e966e26…10043c6e33`). Upstream's `windows/package/model-tools/dlssnr_extract_model.cpp` makes both in two seconds
(`cl /std:c++17 /O2 /EHsc`, standard library only; every entry checked against the tested model). Same shaders, a
shorter plan (`nr_native_plan_data_small.hpp`, its ViT blocks are 11..18), 1080 rows padded to 1152 as NVIDIA's DLL
does. The host asks for it with `RuntimeConfig::network = 1` unless the frame carries
`LMXXF_NR_FRAME_FLAG_ORIGINAL_MODEL` (OptiScaler's `MochizukiOriginalModel`, or int4 mixed, which has the 310.8 model
only); without `dlssnr-small.bin` the core runs the 310.8 model and logs why. Harness, RX 9070 XT, ACO, one pass:
720p 5.65 -> 3.39 ms, 1080p 9.78 -> 6.29, 1440p 16.9 -> 10.6, 4K 36.3 -> 23.0, three passes at 1080p 27.9 -> 18.2;
36 dB from the 310.8 model's picture; the 310.8 model byte-identical to the build before.

## Updating

Copy the paths above from a newer upstream commit, reapply the patches, rebuild, and run the runtime against a
D3D12 frame before shipping it.
