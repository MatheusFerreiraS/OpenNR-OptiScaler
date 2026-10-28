# RX 6000 test kit (mochizuki RDNA2 network, 2026-10-27)

Worktree `wt-rdna2`, branch `mochizuki-rdna2`, local commit only (nothing pushed, uploaded or posted, no game folders
touched). Plan section 9 item 6. Clean room kept: the GPL RDNA2 port was not opened, searched or fetched; the kit is
built from this branch's own export and the RX 7000 kits' tools.

Package (rebuilt 2026-10-27 23:3x, kit v3: the cheaper pre and post blocks below):
`E:\Projetos\opti_rr_dlss5\rx6000-test-kit\OpenNR-RX6000-test.zip`, 17,662,812 bytes (16.8 MB, 115 files, models not
included), SHA-256 `D1FF3AF8E43E72A56CB975457B84683ADABF3F26C8232986E6098BAE196F97A1` (also in
`rx6000-test-kit\SHA256.txt`). One `run-test.bat`, one result zip `OpenNR-RX6000-result-<date>.zip`. The zips in
`rx6000-test-kit\send\` are older kits (v2: `OpenNR-RX6000-test-v2.zip`, 7A088A20...CCBFF4, the one the RX 6600 ran).

## Pre and post blocks (2026-10-27 late, kit v3)

Why they cost a quarter of the frame on the RX 6600 (720p 8.50 + 8.19 ms of 68.2): `temporal_pre_fp32nh` and
`temporal_post_fp32` are not image passes but the first and last C=32 Swin blocks of the network, at the full working
resolution (the pre block's 2x2 pool and the post block's upsample put every other C=32 block at half resolution).
That is 4x the tokens of a `g_fswin32nh` (921,600 at 720p), and per token they cost about what `fswin32nh` costs
(RX 6600 9.2 / 8.9 ns against 8.1 ns). Not bandwidth: about 125 B a pixel in and out for the pre block (colour,
noise, depth, motion, history taps; 64 B output + 16 B pooled) and ~140 B for the post block (skip, half-resolution
input, colour, motion, history; two images out), ~0.5-0.6 ms of the RX 6600's 224 GB/s at 720p; on the 9070 XT the
temporal gate closed (`NR_DIAG_TGATE0=1`, no history/motion/depth taps) and the pre block with no image features at all
moved the dispatch by 1-4%. Cutting each one off after a stage (9070 XT forced, 720p): to the MLP 1.37 / 1.26 ms
(fswin32nh 0.33 at 1/4 the tokens), + QKV 0.5, + attention 2.1 (pre) / 1.1 (post), + output 0.2. The 2.1x scaling
with pixels is compute scaling. Two things were extra: the pre block staged the 8x8 group's 16 features a pixel in a
2 KB LDS buffer behind a barrier (LDS 10 KB against 8 KB, 6 workgroups a CU instead of 8 on gfx1030: its attention
was ~1.8x the post block's), and the attention computed its 64 logits and exponents twice (pass 1 for the sum, pass 2
again for the context), as in every native Swin body.

Changes (`include/fswin_native.glsl`, `include/image_input.glsl`; RDNA2 set only; output byte-identical):
1. The pre block computes the 16 features of the lane's own pixel (`nr_pixel_features`, split out of
   `nr_prepare_features`, the same code) instead of staging them in LDS: LDS 10240 -> 8192 B, one barrier less.
2. `NV_PCACHE` (pre and post only): pass 1 keeps the 64 probabilities in registers (32 VGPRs; q is dead after it),
   pass 2 takes them instead of the second logits/exponent pass: per token 1024 of ~9.2k `v_dot2` and 256 of 768
   `ds_read_b128` fewer, 32 exponent pairs fewer. Pass 1 unrolled (constant indices), pass 2 rolled with a uniform
   select. Tried: both unrolled (115 VGPRs, SPIR-V 1.2 -> 2.0 MB, cold compile +20%), a queue shifted through the
   rolled loops (144 VGPRs, 7 waves a SIMD on gfx1030, cold compile -14%), same speed on the 9070 XT within 2%.
3. The post block reads its blend gains as one dword a pair (`wgt_u32`, the host puts them 16-byte aligned):
   64 16-bit vector loads (`buffer_load_short_d16`) became scalar loads; post `vmem_ld` 80 -> 24.

| case (9070 XT forced, NR_STEP_TIMES=20, 2 rounds) | temporal_pre_fp32nh | temporal_post_fp32 | step sum | status line |
|---|---|---|---|---|
| Small 720p | 4.17 -> 3.06 | 3.18 -> 2.68 | 34.4 -> 33.0 | 29.4 -> 28.5 |
| Small 1080p | 7.78 -> 5.77 | 5.76 -> 4.94 | 52.7 -> 50.2 | 46.1 -> 43.4 |
| Small 1440p | 12.37 -> 9.04 | 9.11 -> 7.81 | 77.2 -> 73.1 | 70.7 -> 67.2 |
| 310.8 720p | 3.71 -> 2.66 | 2.69 -> 2.31 | 65.7 -> 64.4 | 59.6 -> 58.4 |

(-27% pre, -14% post; the untouched kernels within +-3% between the runs. The status line includes no step
timestamps, so its gain is what a game would see. RX 6600 estimate, not measured: 720p 8.5 + 8.2 -> ~6.2 + ~7.0 ms.)

gfx1030 (vkisa, null NAVI21, amdvlk 9.2.10.342), all 13 changed modules: pre 110 -> 119 VGPRs, LDS 10240 -> 8192;
post 110 -> 120 VGPRs (hp 119 -> 120), LDS 8192; 0 scratch before and after; static instructions +850-970 (the
unrolled pass 1; fewer executed); SPIR-V 1.22 -> 1.23 MB. Occupancy (wave32, LDS 8 KB a 2-wave workgroup, 120
VGPRs) 8 waves a SIMD for both, the pre block was 6. Cold compile on the null device (SPIR-V generator word changed so
the driver cache misses): pre 7.6 -> 10.6 s, post 7.5 -> 10.8 s on this CPU. That is the cost of option 2's unrolled
pass 1; the queue variant would be 6.4 s at 144 VGPRs. In the kit run below the runtime check took 7.5 s for all 86
on 8 threads (slowest `g_fswinimagepreds32` 3.5 s, cold).

Checks: forced RDNA2, 1 frame, both models at 720p/1080p/1440p: E9F5E89BF57A08BA / D07096C4C35774C0 /
EB2040C4FB5801C2 and D0A1B50ECEE12A7B / A5A0A39437A13D19 / 3AA32BB2BDFB26BF (unchanged); normal mode 40 frames, all six
cases identical to the previous set (FA35B425 / C9A4FB6E / FB987C4B, 188D4AAD / 44C578C4 / 3DD8A4A3), and 30-frame
step runs too (EE1DAB61 / 01900736 / A9180855, 71CF54D1). Only the 13 pre/post modules of `shaders-rdna2` changed
(`g_fswinimagepreds32`, `g_fswinimagepreds32nh`, `g_fswinimagepost32(_grade)`, `temporal_pre_fp32`, `_nh`, `_nhhp`,
`temporal_post_fp32`, `_hp`, `_h16` and their `_grade`); `shaders\`, `shaders-rdna3\` and `aco\shaders\` rebuilt
from this tree are byte-identical to the export, the DLL is unchanged, RDNA4 `ab.ps1` (40 frames): 258FEC01 /
01588CA6 / 2A308F2C / 04A421E7.

Kit run 5 (forced, models pre-copied; `exports\rx6000-kit\run5.out`, `run5-result.zip`): 86 of 86 pipelines (28 s,
cold for the 13), runtime check 86 of 86 in 7.5 s, first build 21.4 s; PASS 47.79 / 52.92 / 49.72 dB with the hashes
of the table below, runs identical; SPEED 27.42 / 43.67 / 57.20 ms (run 4: 27.95 / 45.88 / 59.56); STEPS small 720p
33.4 ms (pre 3.03, post 2.73), small 1080p 50.5 ms (5.64, 4.92), 310.8 720p 63.2 ms.

Same win elsewhere (not done, recommendations): `NV_PCACHE` applies to every native Swin body of the RDNA2 set
(fswin32/32nh, fswindsp32*, fswinfusedup32*, and the C>=64 head loop), where the attention is ~40-50% of the kernel;
the C=32 fused upsample (`NV_UPS32`) reads its gains with the same 16-bit vector loads. RDNA4/RDNA3 run other bodies
(cooperative matrices); whether their pre block's feature staging costs occupancy there was not measured.

## Native GEMMs (2026-10-27 night)

The first RX 6000 result (RX 6600, driver 26.8.1, the older kit with fswinds) had a correct network (49.8-53.3 dB,
deterministic) but a 195.8 s first build: the nine GEMMs still emulated took 22-45 s each to compile on that driver
(`gemmprojt` 44.8, `gemmvqkvs` 44.7, `gemmnores` 23.8, `gemmpool` 23.2, `gemmprojw` 22.7, `gemmvqkvnorm` 22.5,
`gemmvproj` 22.3, `gemmvqkv` 22.2, `gemmvnores` 22.1), against ~3 s for a native one. All nine now take
`include/gemm_native.glsl` (`NR_NATIVE=1` + `NR_NG_TW/CL/WAVES` in `rdna2/pipelines.json`), so every `gemm*` of the
RDNA2 set is native. The body grew: tile-blocked weights (not only N-pair), the `NR_OUT_PERM` 1/2 raster stores, the
2x2 pool (`NR_NG_TW` a multiple of 8) and the plain `[token][N]` FP16 output; same chain order and epilogue rounding,
so the same bytes.

| pipeline | tile, native setting | gfx1030 .342 before: VGPR / scratch / instr | after | 9070 XT forced, ms a frame (before -> after) |
|---|---|---|---|---|
| gemmprojt | 32x128, TW4 CL2 | 256 / 3600 B / 16.7k | 55 / 0 / 1169 | Small 720p 0.180 -> 0.065, 310.8 1080p 0.199 -> 0.096 |
| gemmvqkvs | 32x128, TW4 CL2 | 256 / 3584 B / 15.3k | 55 / 0 / 388 | 0.178 -> 0.033, 0.150 -> 0.052 |
| gemmnores | 64x128, TW8 CL2 | 256 / 2624 B / 9.2k | 53 / 0 / 1444 | 0.127 -> 0.060, 0.154 -> 0.056 |
| gemmpool | 64x128, TW8 CL2 | 256 / 2784 B / 9.4k | 54 / 0 / 1208 | 0.207 -> 0.096, 0.265 -> 0.109 |
| gemmprojw | 64x128, TW8 CL2 | 236 / 2624 B / 8.6k | 51 / 0 / 1303 | Small 1440p 7.31 -> 3.56, 310.8 1440p 7.07 -> 3.40 |
| gemmvqkvnorm | 64x256, TW16 CL2 | 256 / 3264 B / 11.6k | 68 / 0 / 2990 | Small 1440p 9.81 -> 2.48, 310.8 1440p 9.11 -> 2.35 |
| gemmvproj | 64x256, TW16 CL2 | 256 / 3232 B / 9.8k | 70 / 0 / 1691 | not dispatched (`--legacy-boundary` only, which the DLL never passes) |
| gemmvnores | 64x256, TW16 CL2 | 256 / 3216 B / 9.0k | 69 / 0 / 1428 | not dispatched (no host reference) |
| gemmvqkv | 64x256, TW16 CL2 | 256 / 3184 B / 8.0k | 67 / 0 / 1131 | not dispatched (unfused QKV norm / `NR_DECQ_SMALL=0` only) |

All 16 waves (512 threads); at 1440p TW16/CL1 and TW4/CL4 for `gemmprojw`, TW8/CL4 for `gemmvqkvnorm` were slower.
Compile time on the .342 null device is ~0.5 s a process for every one of them, before and after: that driver does
not show the RX 6600's 22-45 s, so the cut from 8-17k instructions with 2.6-3.6 KB scratch to 0.4-3k with none is the
evidence that they should compile like the other native kernels (~3 s there). Unverified until a real RX 6000 runs.
All 66 `shaders-rdna2` modules: compile for gfx1030 (vkisa, .342), 0 scratch, max 163 VGPRs (`attn`), 0-1 s each.

Output: 1 frame and clean 8 frames (`NR_DIAG_SEED0/TGATE0`), forced RDNA2, both models at 720p, 1080p and 1440p
byte-identical to the previous set: E9F5E89BF57A08BA / D07096C4C35774C0 / EB2040C4FB5801C2 (Small),
D0A1B50ECEE12A7B / A5A0A39437A13D19 / 3AA32BB2BDFB26BF (310.8). Normal-mode 30 frames also identical except 310.8 1440p
(36F766D4 -> ED4D24E7): the old set's second frame took 262 ms, over the RenoDX history gap (0.25 s), the new one 177
ms, so only the old one restarts the history; deterministic per set over repeated runs. `shaders\` and
`shaders-rdna3\` rebuilt with `--check`: identical; RDNA4 `ab.ps1` (40 frames): 258FEC01 / 01588CA6 / 2A308F2C /
04A421E7. Whole network, 9070 XT forced, status line (30 frames, step runs): Small 1440p 79.9 -> 70.6 ms, 310.8 1440p
147.9 -> 136.7 ms; at 720p/1080p the nine were < 1 ms a frame together and now about 0.3.

Kit run 4 (forced, warm caches, models pre-copied; `exports\rx6000-kit\run4.out`, `run4-result.zip`): ~2 min, 86 of
86 pipelines (2 s, slowest `g_gemmvqkvnorm` 0.3 s), runtime check 86 of 86 in 0.7 s, first build 2.5 s, PASS 47.79 /
52.92 / 49.72 dB with the hashes above, runs identical; SPEED 27.95 / 45.88 / 59.56 ms; STEPS small 720p 34.3 ms,
small 1080p 61.4 ms (higher than the 52.7 ms of the step runs above; one run, not repeated), 310.8 720p 65.6 ms in 153
dispatches (top: fswin256 13.9, attn 8.3, fswin128 6.4, ffwd3 5.2, fswin64 4.7).

## What it runs (files\kit.ps1, cases in files\cases.ps1)

1. **System and Vulkan** (`vkprobe --report`, no matrix layout checks): Windows, AMD Software version, DXGI adapters,
   per Vulkan device: id, driver version/info, subgroup size and size control, subgroup operations (shuffle) and
   stages, shared memory limit, float16 controls (RTE/RTZ/denorm), integer dot product (feature + accelerated
   properties), float16/int8, `VK_KHR_cooperative_matrix` and every configuration (phase 0: the RDNA2 driver branch
   reports emulated FP16 16x16x16), FP8, and which network the runtime would pick (now the runtime's rule: RDNA2 device
   id first, then FP8 > RDNA3 > RDNA2, with the shuffle/RTE requirements). Not an RDNA2 pick (and not forced): the
   network stages are skipped and the summary asks which card it is.
2. **Models** from Hugging Face (the installer's URLs), size + SHA-256 checked, three tries (the last with BITS).
3. **Pipeline compile**: `pipecheck.exe` on every `shaders-rdna2` and `shaders\renodx` module, each in its own
   child process, wave32, no matrix extension (`PIPECHECK_COOP=0`, as the RDNA2 runtime),
   300 s a module, no new module after 900 s, the stage killed at 22 min. Writes `pipecheck.txt` and
   `pipelines-by-time.txt` (per-pipeline ms, slowest first). Any FAIL/CRASH/TIMEOUT/NOTRUN: network stages skipped.
4. **Quality**: small 720p, small 1080p, 310.8 720p; clean mode (`NR_DIAG_SEED0=1 NR_DIAG_TGATE0=1`), 8 frames,
   3 runs each, scored by `compare.exe` against the RX 9070 XT FP8 references (quarter area 4x4-averaged, bottom 64
   rows, right 64 columns, lossless JXR; worst area counts), PASS at >= 40 dB and no NaN/Inf in all 3 runs; r1 vs r2/r3
   byte comparison for determinism; the output SHA-256 prefix is printed (compare with the table below). The first run
   is the runtime's real first start: its own pipeline check (stage 6, 8 threads, `rdna2-check.txt`, copied to the
   result) and the cold network build, 20 min limit. If that check refuses a pipeline or never finishes, the kit
   records a WARN ("in a game the network would stay off") and retries once with `MZ_RDNA2_CHECK=0`.
5. **Speed**: same three cases, normal mode (as in a game), 40 frames: the status line's network ms and p95, frame
   median, VRAM estimate/growth, and the GPU clock while busy (`gpuclock.exe`, ADL `ADL2_New_QueryPMLogData_Get`,
   read-only, samples every 100 ms, median/min/max graphics clock, memory clock, temperature over samples with
   graphics activity >= 50%). Then `NR_STEP_TIMES=20` (30 frames) at small 720p, small 1080p and 310.8 720p
   (`large_1280x720`, new 2026-10-27): `steps_<case>.txt` with the full per-pipeline table.
6. `SUMMARY.txt` (IN SHORT block, then every line), `console.txt`, logs, two pictures (diff x16 PNG, output JPG) a
   quality case; zipped next to `run-test.bat`.

The earlier stage 6 (native against emulated: the emulated SPIR-V of 21 pipelines swapped in where they compiled
within 300 s) is gone (2026-10-27): on the real RX 6600 it compiled none of them in its budget, so it only cost time;
`files\emulated\` is no longer shipped and `build-kit.ps1` takes no emulated set.

`g_fswinds32/64/128/256` are gone from `shaders-rdna2` (2026-10-27, see "fswinds removed" below): the earlier
kit's `$Unused` list and its note that they could keep the network off in every game no longer apply.

Env for our own runs: `KIT_FORCE_RDNA2=1` (MZ_FORCE_RDNA2=1 on any card), `KIT_QUIET=1` (no Explorer).

## Measured here (RX 9070 XT, `KIT_FORCE_RDNA2=1`, AMD Software 26.10.1 / Vulkan 0x008001A0)

Run 1 (cold kit folder, models downloaded, compile cold for the fswinds and the emulated set): **23 min** in all;
compile stage 641 s (fswinds 528 s of it, native kernels 0-3 s each), first network build 79.9 s, emulated stage
~6 min. Run 2 (the shipped kit.ps1, fswinds left to the runtime's check; driver cache warm, models pre-copied): 7 min,
all PASS with the same hashes, runtime check 90 of 90, emulated stage again 12 of 21 IDENTICAL. Its SPEED lines
(61 / 87 / 121 ms) were taken while another agent's RX 7000 kit (`wt-rdna3-k5`) ran on the same GPU; ignore them,
its STEPS (34.9 / 53.8 ms) ran after that and match run 1. The native-only compile stage is ~2 min cold here.
With the split, a cold RX 9070 XT run is about 17-19 min (estimate: 113 s compile + the runtime's check ~4.5 min
+ 80 s build + ~4 min runs + ~6 min emulated stage). A real RX 6000 compiles differently (driver branch .35x+);
unknown.

| case | PSNR vs FP8 ref (worst area), 3 runs | runs | sha (= phase 1-4 frame-1 hashes) |
|---|---|---|---|
| small 1280x720 | 47.79 dB | identical | E9F5E89BF57A08BA |
| small 1920x1080 | 52.92 dB | identical | D07096C4C35774C0 |
| 310.8 1280x720 | 49.72 dB | identical | D0A1B50ECEE12A7B |

(Whole-frame PSNR in `reference\refs.txt`: 48.46 / 50.92 / 48.50 dB. Clean mode over 8 frames gives the frame-1
bytes exactly, run after run.) FP8 reference hashes: 6A89FDF732E4FF4A / 0D5AFED38A9D6210 / 7DC466CEF92E0A0F.

Speed (status line, 40 frames): small 720p 29.1 ms (p95 44.5), small 1080p 47.5 ms, 310.8 720p 61.7 ms; GPU
3.1-3.2 GHz median while busy. Steps: small 720p 35.2 ms in 77 dispatches, 1080p 53.9 ms (same as phase 4).
Emulated stage: 12 of 21 emulated kernels compiled within the 300 s budget (all GEMMs, attn, ffwd3, vitattn, the
C=32 Swin, the pre/post blocks; `fswin64` timed out at 150 s, the C>=64 ones not reached): output IDENTICAL.

Estimates to compare with (phase 4, Small 720p): RX 6900 XT ~26 ms, RX 6800 ~38 ms, RX 6700 XT ~43 ms.

## fswinds removed (2026-10-27)

The unfused downsample `fswinds<C>` (still emulated: 42-260 s each on the 9070 XT, 128/256 no pipeline on the gfx1030
null device) is no longer built for RDNA2 (`linux/shaders/rdna2/pipelines.json`), so neither the runtime's stage-6
check (it compiles every `.spv` in the folder) nor `create_kernels` (it compiles dispatched kernels only) meets it.
RDNA4 and RDNA3 keep theirs. Why no RDNA2 path needs it (`windows/src/core/nr_graph.cpp`):

- The DS body is `fswinds<C>` only with `host_boundary` (the runtime always passes `--host-boundary`;
  `--legacy-boundary` or `--legacy-ds-quant` give `fswin<C>` + `pool<C>` + `gemmds` instead). It is then replaced by
  `fswindsp<C>` when `NR_DS_FUSE & bit(C)` (the DLL is built with `NR_DS_FUSE=15`: C = 32, 64, 128, 256, every DS level
  of both models), `pg.ds_raster != 1` and not `--legacy-ds-quant`. `ds_raster` is 1 only with `--ds-tok-raster`,
  reachable in a game only through the diagnostic `NR_GRAPH_ARGS`. Size and model (Small, 310.8) do not enter the
  condition; the persistent fold of `fswindsp<C>` is off on RDNA2 anyway.
- That one path now throws on RDNA2 instead of asking for a missing file. Tested with `NR_GRAPH_ARGS=--ds-tok-raster`,
  forced RDNA2: `network build failed at 1280x720: RDNA2 network: no unfused downsample (fswinds32), the fused one
  only (drop --ds-tok-raster)`.

Checks: the rebuilt export against the previous one: every file in `shaders`, `shaders-rdna3`, `aco`, `int4` and the
rest of `shaders-rdna2` byte-identical, only the four `g_fswinds*.spv` gone. RDNA4 `ab.ps1` (40 frames): 258FEC01 /
01588CA6 / 2A308F2C / 04A421E7 (= 0.5.8). vkisa gfx1030 (.342 null device, 3 in parallel) on all 66 remaining
`shaders-rdna2` modules: all compile, slowest 7 s (temporal pre/post variants 6-7 s, the rest 0-5 s). Nine small
emulated GEMMs (`gemmprojt`, `gemmvqkvs`, `gemmvqkvnorm`, `gemmvproj`, `gemmvnores`, `gemmvqkv`, `gemmpool`,
`gemmprojw`, `gemmnores`) still took 236-256 VGPRs and 2.6-3.6 KB scratch (native since: "Native GEMMs" above).

Kit run 3 (forced, driver cache warm, models pre-copied; `exports\rx6000-kit\run3.out`, `run3-result.zip`): 6 min,
pipelines 86 of 86, the runtime's check passed (86 of 86, 0.3 s on 8 threads) with no `MZ_RDNA2_CHECK=0` retry,
first build 1.6 s; hashes E9F5E89BF57A08BA / D07096C4C35774C0 / D0A1B50ECEE12A7B, PSNR 47.79 / 52.92 / 49.72 dB,
runs identical; SPEED 28.3 / 46.9 / 60.6 ms; STEPS 34.8 / 53.6 ms; emulated stage 12 of 21 IDENTICAL (as before).
Compile and check times are warm-cache numbers; cold, the earlier 641 s compile stage loses the fswinds' 528 s.

## How to read a result

- IN SHORT: card, compile yes/no, PASS/FAIL cases, run-to-run changes, network ms.
- `WARN the runtime's pipeline check keeps the network off`: the game path would be off on this driver; the rest of
  the result still measures the network (MZ_RDNA2_CHECK=0).
- `FAIL pipelines` / `CRASH` / `TIMEOUT`: compiler problem on that driver; `pipelines-by-time.txt` names the file.
- sha equal to the table above: the RX 6000 computes the same bytes as the 9070 XT forced (expected only if the
  gfx103x compiler forms `v_dot2` the same way; last-bit differences are possible, phase 0 section 4). PSNR >= 40 dB
  is the bar either way.
- SPEED vs the estimates above, with the GPU clock (a low clock means power/thermal limits, not the kernels).
- `steps_*.txt`: per-pipeline ms on the card, to compare with the phase-4 table (the 9070 XT forced column).

## Uncertain

- No RX 6000 here: the vkprobe pick logic, ADL sensor indices (graphics clock 1, activity 19, memory clock 2,
  temperature 8, power 23; power reads -1 on the 9070 XT) and the RDNA2 compile times are unverified on gfx103x.
- Navi 24 (RX 6400/6500, gfx1034) and the APUs: in the id list, never probed (phase 0 did gfx1030-1032 only).
- Native == emulated is no longer checked on real hardware (stage 6 dropped); the per-kernel byte identity is from
  the 9070 XT forced runs only.
- The nine new native GEMMs' compile time on a real RX 6000 driver: expected ~3 s like the other native kernels, not
  measured (the .342 null device compiles both forms in under a second).
- References are the 9070 XT's FP8 network; the threshold (40 dB) leaves ~7 dB of margin over what forced RDNA2 gets.

## Files

- `tools/rx6000-kit/`: `kit.ps1`, `cases.ps1`, `make-refs.ps1`, `build-kit.ps1`, `pack-kit.ps1`, `build-tools.cmd`,
  `gpuclock.cpp` (new), `compare.cpp` (from the RX 7000 diagnostic kit), `run-test.bat`, `README.txt`.
- `tools/rx7000-kit/vkprobe.cpp`: RDNA2 facts and pick rule, `--report`. `tools/rx7000-kit/pipecheck.cpp`: matrix
  extension only when offered (`PIPECHECK_COOP=0` to leave it out), recursive folders, `PIPECHECK_BUDGET_S`, NOTRUN.
  The RX 7000 kits' behaviour on RX 7000 is unchanged (they offer the matrix extension).
- Outside git, `exports/rx6000-kit/`: `tools\` (built exes), `refwork\` (reference runs), `reference\` (img_*.jxr,
  refs.txt), `emulated-set\` (full layer-A build, no longer shipped), `kit\` (laid-out kit), run logs
  `run1.out`..`run4.out`, `run1-result.zip`..`run4-result.zip`, `run4-steps_large_1280x720.txt`, `models\`.
- Outside git, `exports/rdna2-work/`: `nat5.ps1` (forced-RDNA2 runs on a given `shaders-rdna2` set with the export's
  DLL), `ab\p5_base` (previous set), `ab\p5_new1` (this one), `ab\p5_sw` (setting sweep), `ab\p5_r4` (RDNA4 check),
  `p5\` (step-table logs). Scratch `rdna2-p5\`: `base\`, `new1\` (the two sets), `out\` (gfx1030 ISA + stats,
  `all_new1.txt` for all 66 modules, `base_all.txt`, `ms.txt`), `scripts\` (`mk.sh`, `isa.sh`, `setjson.py`,
  `allisa.sh`), `prev\shaders-rdna2` (the export's previous set).

## Rebuild

```
$k = 'E:\Projetos\opti_rr_dlss5\wt-rdna2\exports\rx6000-kit'
tools\rx6000-kit\make-refs.ps1 $k\refwork $k\reference                     # FP8 refs + forced RDNA2 scores
tools\rx6000-kit\build-kit.ps1 exports\mochizuki-rdna2 $k\reference $k\kit
tools\rx6000-kit\pack-kit.ps1 $k\kit E:\Projetos\opti_rr_dlss5\rx6000-test-kit\OpenNR-RX6000-test.zip
```
A new shaders-rdna2 needs new references only if the network's arithmetic changed (the references are the FP8
network's).
