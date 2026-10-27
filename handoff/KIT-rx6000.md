# RX 6000 test kit (mochizuki RDNA2 network, 2026-10-27)

Worktree `wt-rdna2`, branch `mochizuki-rdna2`, local commit only (nothing pushed, uploaded or posted, no game folders
touched). Plan section 9 item 6. Clean room kept: the GPL RDNA2 port was not opened, searched or fetched; the kit is
built from this branch's own export and the RX 7000 kits' tools.

Package: `E:\Projetos\opti_rr_dlss5\rx6000-test-kit\OpenNR-RX6000-test.zip`, 24,577,928 bytes (23.4 MB, 136 files,
models not included), SHA-256 `A3DAFDB86A3BCC862D358E58E787C1F5E70DB84776C48F48AD99C48D21248F9D` (also in
`rx6000-test-kit\SHA256.txt`). One `run-test.bat`, one result zip `OpenNR-RX6000-result-<date>.zip`.

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
   graphics activity >= 50%). Then `NR_STEP_TIMES=20` (30 frames) at small 720p and 1080p: `steps_<case>.txt` with
   the full per-pipeline table.
6. **Native against emulated** (layer A on real hardware): `files\emulated\` holds the emulated SPIR-V of the 21
   native pipelines the small model dispatches at 720p. `pipecheck` compiles them smallest first (150 s each, nothing
   new after 300 s; skipped below 12 GB RAM, one emulated compile took ~5.6 GB on the null device); every one that
   compiles replaces its native file in a private copy (`files\mixed`, deleted after), one clean small 720p run with
   `MZ_RDNA2_CHECK=0`, 9 min limit; its hash must equal the native run's. Native and emulated are byte-identical per
   kernel (phases 3-4), so any mix must give the same bytes. The ones that do not compile in time are listed.
7. `SUMMARY.txt` (IN SHORT block, then every line), `console.txt`, logs, two pictures (diff x16 PNG, output JPG) a
   quality case; zipped next to `run-test.bat`.

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
`gemmprojw`, `gemmnores`) still take 236-256 VGPRs and 2.6-3.6 KB scratch (speed only; not ported).

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
- `EMULATED ... IDENTICAL`: native == emulated on real hardware for the listed kernels; DIFFERS names a native kernel
  whose arithmetic differs on gfx103x (swap kernels in `files\emulated` one at a time to find it).
- SPEED vs the estimates above, with the GPU clock (a low clock means power/thermal limits, not the kernels).
- `steps_*.txt`: per-pipeline ms on the card, to compare with the phase-4 table (the 9070 XT forced column).

## Uncertain

- No RX 6000 here: the vkprobe pick logic, ADL sensor indices (graphics clock 1, activity 19, memory clock 2,
  temperature 8, power 23; power reads -1 on the 9070 XT) and the RDNA2 compile times are unverified on gfx103x.
- Navi 24 (RX 6400/6500, gfx1034) and the APUs: in the id list, never probed (phase 0 did gfx1030-1032 only).
- The emulated stage's budget means the big emulated Swin kernels are probably never reached on an RX 6000 (they did
  not compile at all on .342); the check covers the GEMM/attention/C=32 kernels.
- References are the 9070 XT's FP8 network; the threshold (40 dB) leaves ~7 dB of margin over what forced RDNA2 gets.

## Files

- `tools/rx6000-kit/`: `kit.ps1`, `cases.ps1`, `make-refs.ps1`, `build-kit.ps1`, `pack-kit.ps1`, `build-tools.cmd`,
  `gpuclock.cpp` (new), `compare.cpp` (from the RX 7000 diagnostic kit), `run-test.bat`, `README.txt`.
- `tools/rx7000-kit/vkprobe.cpp`: RDNA2 facts and pick rule, `--report`. `tools/rx7000-kit/pipecheck.cpp`: matrix
  extension only when offered (`PIPECHECK_COOP=0` to leave it out), recursive folders, `PIPECHECK_BUDGET_S`, NOTRUN.
  The RX 7000 kits' behaviour on RX 7000 is unchanged (they offer the matrix extension).
- Outside git, `exports/rx6000-kit/`: `tools\` (built exes), `refwork\` (reference runs), `reference\` (img_*.jxr,
  refs.txt), `emulated-set\` (full layer-A build: `build_network.py rdna2 --tree linux --no-quad` with NR_NATIVE
  stripped from a temporary copy of pipelines.json, restored by git checkout), `kit\` (laid-out kit, run logs
  `run1.out`, `run2.out`), `run1-result.zip`, `models\`.

## Rebuild

```
$k = 'E:\Projetos\opti_rr_dlss5\wt-rdna2\exports\rx6000-kit'
tools\rx6000-kit\make-refs.ps1 $k\refwork $k\reference                     # FP8 refs + forced RDNA2 scores
tools\rx6000-kit\build-kit.ps1 exports\mochizuki-rdna2 $k\emulated-set $k\reference $k\kit
tools\rx6000-kit\pack-kit.ps1 $k\kit E:\Projetos\opti_rr_dlss5\rx6000-test-kit\OpenNR-RX6000-test.zip
```
A new shaders-rdna2 needs a new emulated set and references only if the network's arithmetic changed (the
references are the FP8 network's).
