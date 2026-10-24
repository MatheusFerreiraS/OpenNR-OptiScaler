# Upstream merge, 2026-10-24

Upstream OptiScaler master (`539c9a1ec`, 293 commits since the last merge base `65a5f6f9c`) merged into
OpenNR `dlss-neural-rendering` (`8098b8e71`, release 0.5.7-opennr).

- Worktree: `E:\Projetos\opti_rr_dlss5\wt-upstream-merge`
- Branch: `upstream-merge-2026-10` (local only, not pushed)
- Merge commit: `c5a836c8a` (parents `8098b8e71` ours, `539c9a1ec` upstream)
- The build and test fixes are part of the merge commit; the commit after it only adds this file
- The main checkout (`opti\`) was not touched. Its two uncommitted files (`RuntimeHostLoad.h`,
  `LmxxfBackend.cpp`) are not in this branch.
- Version stays `0.5.7` / `-opennr` (`OptiScaler/resource.h:32`); bump it when this becomes a release.

## How it was done

`git merge refs/upstream-ro/master` with zdiff3 markers: 75 files conflicted (about 290 hunks once split).
Many conflicts came from our 2026-09-22 fork import (`11d11d41f`, burak113's FSR-RR fork and TheAutomatic's
bridge), which carried an older copy of upstream code: where our side was only that older upstream code, I took
upstream's file (Hudfix_Dx11, HudCopy_Vk, Magnifier_Common.h, VulkanwDx12_Hooks, IFeature_VkwDx12 body,
Vulkan_Spoofing, DLSSFeature_Dx11On12, the Streamline plugin hooks). Where our side had NR or OpenNR logic, the
upstream version is the base and our additions were ported onto it.

Submodules: `external/vulkan` moved to `8864cdc` upstream. The worktree has its own shallow clones
(`git submodule update --init --depth 1`; opti's module stores are shallow, so `--reference` could not be used).

## Conflicts and how each was resolved

| File | Resolution |
|---|---|
| `misc/Quirks.h` | Upstream moved the exe table to `misc/GameConfigs.cpp` and turned config-type quirks into `.defaults`. Took upstream's enum, added ours: `UnlockPathTracingMenu`, `MochizukiGameExposureFeed`, `HideFsr4FromGame`, `DisableXeSSInputs`, `MochizukiPreprocessOn` (Quirks.h:34-38). |
| `misc/GameConfigs.cpp` | Our entries added: BeamNG `HideFsr4FromGame` (:146), RE9/RE9 demo `MochizukiGameExposureFeed` (:289, separate entry after upstream's MH Wilds/RE9/Onimusha group), 007 First Light `UnlockPathTracingMenu` (:404), Crimson Desert `DisableXeSSInputs` + `MochizukiPreprocessOn` (:571), eFootball `SkipD3D11FeatureLevelElevation` (:789), Stellar Blade `OnNonNvidia(RestoreComputeSignature)` + `ExtendedStateRestore` (:795, this one came from burak's fork, not upstream). Granblue, Onimusha (full game), pal7, ROTTR, NMS, DD2 were already upstream. |
| `dllmain.cpp` | Upstream's `ApplyGameConfigs`; our `DisableXeSSInputs` -> `EnableXeSSInputs=false` (:1468) and the mochizuki quirk defaults (:1475) run right after it. printQuirks has both sets. CEF `--type=` passthru kept (:1595). |
| `Config.h/.cpp`, `OptiScaler.ini` | Both key sets kept. Our XeFG DMFG keys dropped in favour of upstream's identical ones (upstream adds `TargetAsCapDMFG`, `OverrideInterpolationCount`); our `UnlockMFG`, `MaxInterpolatedFrames`, `ExtraPacing`, `DisableReflexSync`, menu `Width/Height/Anchor/SectionOrder` kept; upstream's `DisableOTA`, `Fsr4GpuSupport`, `Fsr4Model` etc. added. `value_as_chosen()` intact (Config.h:128). `OverlayMenu` is upstream's SoftDefault. |
| `proxies/FfxApi_Proxy.h` | Kept our (burak's) proxy - it carries the FSR-RR denoiser routing (`DenoiserApiGenerationDx12`, `VersionImplemented_RR`, effect-ID version query) - and applied upstream's 6 commits onto it: FSR4 driver provider routing in Create/Destroy/Configure/Dispatch, the Query split (`D3D12_QueryUpscalerVersions`, `D3D12_QuerySdk`), `IsUpscalerModule`/`UpscalerModule`, `FSR4Presets`/`FSR4Models` hooks replacing `FSR4ModelSelection`, upstream's InitFfxVk (539c9a1ec, hooked side like Dx12, pinning, `amd_fidelityfx_upscaler_vk.dll`). Our BeamNG/Crimson fix that also hooks the game's own loader is kept (:427). |
| `inputs/FfxApi_Dx12.cpp`, `inputs/XeSS_Common.cpp`, `proxies/XeSS_Proxy.h` | No conflicts; `QueryVersionsWithoutFsr4` (FfxApi_Dx12.cpp:401) now sits on top of upstream's version list (driver FSR4 names start with 4 and are filtered too). `hk_xessSetMaxResponsiveMaskValue` intact (XeSS_Proxy.h:479, XeSS_Common.cpp:163). |
| `fsr4/` | We had no local changes there; upstream's FSR4DriverProvider/FSR4Models/FSR4Presets replace FSR4ModelSelection/FSR4Upgrade. `Fsr4ForceModel` is migrated to `Fsr4GpuSupport` by upstream's Config code. |
| `hooks/D3D12_Hooks.cpp` | Upstream rewrote root-state tracking (per-list `CommandListState`, templated restore). Took upstream's file and ported every OpenNR addition onto it: includes, the AMD graphics tracker hooks (RS/IA/OM/predication/ClearState/Draw/RenderPass/Bundle/ExecuteIndirect/queries/Release/CreateCommandList(1)/CreateCommandSignature), tracker reports in every early hook, in the three late hooks and in the restore path, `AmdGraphicsTrackerWanted()` (:341) widening the attach conditions, the lmxxf `ArmCreate` + early-list proxy block (:3052), `NoteDeviceCaller`, the OpenGL driver passthrough, exposure scan on committed/placed resources (:2589), `IsRootSignatureTrackingEnabled`/`NativeDrawHookTarget`/`IsAmdGraphicsTrackerArmed` (:1890-1892). Change: our separate Reset detour is gone; upstream's `hkReset` now also reports `OnReset` and is attached when the tracker is wanted (two detours on one target in one transaction was a risk). |
| `hooks/Vulkan_Hooks.cpp` | Upstream added Vulkan FG (swapchain hooks, FG feature on device create, low latency 2, surface->window). Ported ours onto it: `IsForeignCreate` passthrough (:407/:517), NR device extensions (:678), `_nrGraphicsFamily` capture, `AmdVkPresent::Created/Destroyed` (:1160/:1179), the transfer-usage `requested` create info is now the start of upstream's create-info chain, OverlayMenu gating of the menu. |
| `hooks/Streamline_Hooks.cpp/.h`, `proxies/Streamline_Proxy.h` | Upstream rewrote plugin hooking into per-copy slots; took upstream's plugin section and re-added our `externalFrameGeneration` guards (Streamline_Hooks.cpp:3168...) and `isSetConstantsHooked`. Our RR tag diagnostics, `RecordGameDlssgOptions`, `GameRequestedInterpolationCount`, MFG unlock, local sl.dlss_g spoof logging kept. `dummy_slDLSSGGetState` forwards to the real Streamline (NeuralHub) first, then upstream's `FillDlssgInputState`. Our sl.dlss_g preload for NeuralHub kept (Streamline_Proxy.h:106). Removed our `applyMenuDlssgInterlock`: upstream fixed the same Vulkan menu/DLSSG deadlock by drawing on the presenting queue (01195e9bf). |
| `framegen/xefg/*`, `framegen/dlssg/*` | Upstream's Dynamic MFG (same lineage as our TheAutomatic port, newer) replaces ours: `XeFG_DynamicCount.h` and the inline count logic are upstream's. Kept ours: game-requested count via raw NGX and the NR-without-upscaling default of 2 generated frames when the count is auto and not following the game (XeFG_Dx12.cpp:775), D3D9 presenter handling, NeuralHub DMFG guard moved into upstream's `DLSSG_Common::SetOptions` (DLSSG_Common.cpp:110). |
| `NVNGX_Parameter.cpp` | Our XeFG/NeuralHub `MultiFrameCountMax` chain plus upstream's fallback to the real driver table. |
| `nvapi/NvApiHooks.cpp`, `low_latency/*`, fakenvapi | Upstream "lobotomised" fakenvapi (low latency moved to `InputCommon`); our sleep timing for Dynamic MFG is upstream's `take_sleep_ms` now. `DisableReflexSync` keeps precedence over upstream's ReflexSync hook (NvApiHooks.cpp:211). Our stalled-markers AntiLag 2 fix combined with upstream's `interpolated` flag (ll_antilag2.cpp:199). |
| `menu/menu_common.cpp/.h` | Our side-bar layout (NR/UP/FG/IMG/UI/ADV, docking, pills, NR badge, graphs, bottom bar, Neural page at :10934) kept as the skeleton. Upstream's new section functions are called from it: Output Scaling, Shader times, Init Flags, V-Sync, Status. Settings functions are upstream's where ours only moved code (image/ratio/output scaling/init flags); RenderActiveUpscalerSettings is upstream's plus our FSR-RR block and DLSSD->FSR-RR switching (:3273); FG selection/runtime are upstream's plus our external-FG box, NeuralHub DLSS-FG, child-window XeFG on Vulkan/OpenGL, D3D9 route, NR-without-upscaling output rules, RTX 40 MFG unlock, Extra Pacing, Only FG, RTSS warning; the FPS overlay is upstream's line model plus our NR runtime/time line (:2923); theme is upstream's swatches plus our docking combo. `ShowHelpMarker` restored (upstream removed it, our NR menu uses it). Upstream's card/Custom-tab layout functions compile but are not reachable from our layout. |
| `menu/menu_overlay_vk.cpp`, `_dx.cpp` | Upstream's menu blur and present-queue selection + ours: screenshot copies, vkd3d-proton DX overlay ownership (now via `IdentifyGpu::gameUsesVkd3dProton/Dxvk`), objects-usable guard, final-image menu hold. |
| `resource_tracking/ResTrack_dx12.*` | Upstream reworked tracking (release notifications instead of a Release hook, binding shards). Took upstream's file plus our exposure scan hook (:692). The FSR-RR resource inspector (burak's debug view) did not survive: its API is stubbed (:2873), the menu and FSRD compile and report nothing. |
| `upscalers/*` | NR seams intact: NVNGX_DLSS_Dx12.cpp:1287/1315/1332/1362, NVNGX_DLSS_Vk.cpp:1056/1135, IFeature_Dx11wDx12.cpp:496, IFeature_VkwDx12.cpp:2201. Upstream's per-feature D3D11 bridge resource cache adopted. Upstream's `DLSSFeatureDx11On12` and `DLSSFeatureVkOnDx12` replace our two DLSS-on-12 variants (ours removed); `NeuralHubArmOk` still lets DLSS through on AMD (FeatureProvider_Dx11/Vk/Dx12). `FSR31Feature_Dx12` (base of FSR-RR) moved to `state.ffxUpscalerVersionsDx12`. |
| `shaders/Shader_Dx11.cpp` | Kept ours: the destructor does not release `_currentOutResource` (InitializeUAV never AddRefs it; upstream's release is an over-release, caught by `tests/shader_dx11_ownership.cpp`). |
| `shaders/Shader_Dx12.cpp` | Upstream's `translateTypeless` plus our depth-plane SRV exception. |
| `with_dx12/*`, `wrapped/wrapped_swapchain.cpp`, `hooks/FG_Hooks.cpp`, `hooks/DxgiFactory_Hooks.cpp` | Union: upstream's XeFG present/resize synchronisation + our final-image resize hold, present fallback, D3D9 queue fallback, window-sized swapchain resolve, NeuralHub present hooks, colour-space log. Upstream commented out the XeFG back-buffer release loops in ResizeBuffers; followed it. |
| `OptiScaler.vcxproj(.filters)`, `.sln` | Union, then removed duplicates and entries for files that no longer exist. |
| `.github/workflows/build.yml` | Stays deleted (we removed the workflows). |

Double insertions found after the merge (both sides added the same block, git kept both) and removed:
FSRFG_Dx12.cpp callback-device block, `IFGFeature::_generationOff`, `State::lastFGPresentMs`, two menu
declarations, menu local redeclarations.

## What upstream brings

- FSR 4: driver DLL provider (amdxcffx64 / amdvkffx64) with live model switching from the menu, FSR 4 models
  FP8 / INT8 / INT8 RDNA2 / INT8 Lite (`[FSR] Fsr4Model`, `Fsr4GpuSupport` override), 4.1.2 model selection,
  FSR 4 upscaling and FSR 4 FG on Vulkan, GPU detection for FSR 4 availability (d8aebe45b, 65ee5d64c), live
  watermark toggle, its own auto exposure (0958d8e18).
- Vulkan frame generation: OptiFG (upscaler input), FSR FG output, DLSSG input and output, Vulkan hudfix,
  reprojection (WIP, needs DLSSG via Streamline), Vulkan GPU times per shader, Vulkan reflex/low latency.
- XeFG input (game's own XeSS-FG), Dynamic MFG for XeFG with "use target as cap", DLSSG follows the game's
  multiplier by default, FG mode slider.
- `misc/GameConfigs.cpp` per-game defaults, DRS init flag and passthrough, AMD flip-meter status and toggle,
  menu blur, card menu, menu height, DLSS Dx11 w/Dx12 and DLSS Vk w/Dx12, DeferredRelease, BeamNG quirk
  (6fd357379), DA sharpness crash fix (18d4d2e48), Enshrouded MVs, many crash fixes.

## INI keys for the installer template

`tools\PACKAGE_RELEASE.ps1` copies `OptiScaler.ini` whole and rewrites a few keys plus the `[DlssNr]` block, so
the new keys ship as `auto` without changes. Keys worth a decision:

- `[FSR] Fsr4Model` (0 FP8, 1 INT8, 2 INT8 RDNA2, 3 INT8 Lite) and `Fsr4GpuSupport` (0 none, 1 FP8, 2 INT8,
  3 INT8-2, 4 INT8 Lite). `Fsr4ForceModel` is gone (read once as `Fsr4GpuSupport`, then deleted on save).
  Leave auto for RX 9000; the installer's RX 7000/6000 paths could set `Fsr4GpuSupport=2`/`3` if we want FSR 4
  INT8 there.
- `[FSRFG] DisableFlipMetering`, `[Menu] Blur`, `BlurStrength`, `Height`, `FpsOverlayShowRatio`,
  `[OptiFG] HUDFixUITexture`, `HUDFixUIUnblend`, `HUDFixPersistentBindings`, `[NvApi] DisableOTA`,
  `[InitFlags] DynamicResolution`, `[XeFG] TargetAsCapDMFG`, `OverrideInterpolationCount`,
  `[fakenvapi] LowLatencyInput/LowLatencyOutput`: auto is fine.
- Our `[Menu] Width/Height/Anchor/SectionOrder` stay ours; upstream's `Height` comment was dropped in favour of
  ours (pixels, not unscaled).
- Payload check: FSR 4 on Vulkan through the driver needs a signed FFX SDK Vulkan DLL loaded
  (`amd_fidelityfx_loader_vk.dll`, `amd_fidelityfx_upscaler_vk.dll` or `amd_fidelityfx_framegeneration_vk.dll`,
  FSR4DriverProviderVk.cpp:300). The 0.5.7 package only has `amd_fidelityfx_vk.dll`. Add the SDK 2.x Vulkan DLLs
  to `OptiScaler\` in the payload if Vulkan FSR 4 is wanted.

## Build and tests

- `tools\build-optiscaler-fast.cmd`: BUILD_OK (`exports\release-local\OptiScaler.dll`, 28.6 MB). No new
  warnings beyond C4250 on FSR31/FSRD. Runtimes were not rebuilt: nothing under `OptiScaler/dlssnr` or the
  runtime sources changed in the merge.
- Headless, all PASS: `test-proxy-link` (against the 0.4.9 baseline), `test-amd-host-contracts`,
  `test-shader-compatibility` (after adding `DeferredRelease.cpp` to `tests/shader_dx12_srv.cpp`, which upstream's
  Shader_Dx12 now needs), `test-lmxxf-list-split`, `-create-execute`, `-evaluate-cut`, `-interposer-wrap`,
  `-list1-wrap`, `-same-frame-boundary`, `-color-probe`, `test-person`.
- On the RX 9070 XT, built DLL against the 0.5.7 release DLL (same staging, `exports\` of the worktree only):
  - `dx12_final_image_smoke nr` (danielblnc): all NR/present checks pass; "Model scale changed from the menu"
    fails, and fails the same way with the 0.5.7 DLL (the test's click position is stale). A first run also
    had 2 runtime timeouts and NR missing frames in two phases; the rerun was clean.
  - `dx12_final_image_smoke fg` (danielblnc + XeFG 3X): everything passes except the same model-scale click.
  - `dx12_final_image_smoke nr --set DlssNr/NrBackend=mochizuki`: same results as 0.5.7 (the "NR changed
    every probed frame" threshold is danielblnc's; 0.5.7 fails 4 checks, merged 3).
  - `test-dx11-final-image ... nr`: PASS on the second run (first run: NR skipped frames on the menu's
    Frame Gen page once, with a 142 ms hitch; not reproduced).
  - `test-vulkan-present`: core checks pass (NR through the shared D3D12 image, XeFG 3X, keys, menu over XeFG,
    real frame rate kept); 5 failures vs 11 for the 0.5.7 DLL in the same session, all click/focus checks,
    with "the test window cannot take the foreground (locked or busy desktop)" in both.
- Not run: anything writing to game folders, `tools\uishot`, D3D9/GL/x86 smoke tests.
- Not done: clang-format 20 (only 22 is installed here); a CI format check may want a pass on the edited files.

## Risks

1. D3D12_Hooks port: the tracker reports now sit in upstream's new hooks; `Reset` is one detour (`hkReset`) for
   both root-state recording and the tracker. danielblnc NR in real D3D12 games is the first thing to test.
   lmxxf/mochizuki same-frame path (`ArmCreate`, early proxies) was moved verbatim.
2. Vulkan: upstream's own FG hooks the swapchain now. Our final-image path (AmdVkPresent) and child-window XeFG
   have not met upstream's Vulkan FG in a game. The FG output rules: OpenGL keeps XeFG only through NR without
   upscaling; Vulkan allows upstream's OptiFG/FSR FG/DLSSG outputs, and the child-window XeFG when NR without
   upscaling runs (DLSSG then disabled).
3. Menu: upstream's card/Custom tab layout is not reachable; the MFG menu is upstream's slider, so there is no
   "Auto"/"Custom..." entry for the XeFG count any more (the INI's `auto` still works, including the
   NR-without-upscaling default of 3X).
4. FSR-RR resource inspector is stubbed (debug view only; FSR-RR itself is untouched).
5. FfxApi proxy keeps burak's structure with upstream's FSR 4 driver provider grafted in. The FSR 4 driver
   versions now appear in the game's FFX version list (`WhenNewestUpscaler`), filtered for BeamNG by
   `HideFsr4FromGame`.
6. Dynamic MFG is upstream's implementation (no XeFG 3 version gate; no automatic fallback when
   `SetNumInterpolatedFrames` fails).
7. Removed menu/DLSSG interlock: relies on upstream's presenting-queue fix for DLSSG on Vulkan.
8. ResTrack: hudless candidates take upstream's `CheckResource` info (our view-format override for typed views
   of typeless resources is gone).

## In-game test list

1. Cyberpunk 2077 (DX12): NR before SR with FSR 3.1/FSR 4 (FFX) on danielblnc, lmxxf and mochizuki; FSR-RR
   with NR between denoise and upscale; XeFG and FSR FG on top; menu Neural page; PresentWithoutUpscaler on;
   RE frame rate and stalls with AmdGraphicsWait=1 (tracker) and with lmxxf (submission hooks); check the log
   for "AMD graphics tracker hooks attached" or "lmxxf ArmCreate ok".
2. Cyberpunk: FSR 4 model switching in the menu (FP8/INT8) on the RX 9070 XT, driver FSR 4 (amdxcffx64) entry
   in the FFX upscaler list, watermark toggle.
3. BeamNG.drive (DX12 and Vulkan): graphics options page draws (HideFsr4FromGame), FSR 3/FSR 4 inputs reach
   OptiScaler (log "Hooked the game's own FFX module too" on DX12), XeSS selection does not crash
   (xessSetMaxResponsiveMaskValue), menu input, CEF children in passthru (one OptiScaler.log).
4. Crimson Desert: FSR 4.1 input with NR, XeSS inputs off by default (quirk), mochizuki pre-process on.
5. Resident Evil Requiem: mochizuki exposure steady in dark scenes (game exposure feed), RestoreComputeSignature.
6. A Vulkan game (e.g. Doom: The Dark Ages / No Man's Sky / Detroit) on the RX 9070 XT: FSR 4 upscaling through
   the driver (needs the Vulkan SDK DLLs, see above), upstream's OptiFG/FSR FG on Vulkan, mochizuki/danielblnc
   final image with child-window XeFG, menu over FG output.
7. WrongGPU with the fork: DLSS 4/4.5 SR on AMD; check DXGI spoofing keeps `neuralhub_host.dll`/`dlssnr_amd_*`
   unspoofed (Dxgi_Spoofing.cpp:33) and FidelityFX override paths load beside the DLL.
8. NeuralHub 0.8.0 host: DLSS-SR/RR on AMD, DLSS-FG through OptiScaler's Streamline, Dynamic MFG request falls
   back to a fixed multiplier.
9. A D3D11 game (Assetto Corsa or a Unity title) with NR on the D3D11 bridge and DLSS on12; Witcher 3 DRS
   (upstream's XeFGCameraMotionFill quirk is new there).
