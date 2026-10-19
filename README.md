# OptiScaler AMD: neural rendering and FSR ray reconstruction

An OptiScaler fork for AMD graphics cards. Games that ask for DLSS get DLSS 5 neural rendering
(DLSS-NR) through AMD runtimes, or AMD's own FidelityFX denoiser as Ray Reconstruction.
Super Resolution stays FSR.

This README covers only what this fork changes. For OptiScaler itself (upscalers, frame
generation, spoofing, the full ini), see [optiscaler/OptiScaler](https://github.com/optiscaler/OptiScaler).

## What it adds

**AMD neural rendering, three runtimes.** Pick one with **NR runtime** in the menu (applies on the
next launch) or `NrBackend` in `OptiScaler.ini`.

| | danielblnc | lmxxf | mochizuki (experimental) |
|---|---|---|---|
| Runtime | [DLSS-NR-on-AMD](https://github.com/danielblnc/DLSS-NR-on-AMD) 0.5.1 (recommended; public since 2026-10-01), 0.5.0, 0.4.3, 0.4.2, 0.4.1, 0.4.0, 0.3.1 or 0.3.0, or the 0.6.0 build danielblnc gives his supporters, as `dlssnr_amd_pass1-3.dll` | [lmxxf's open-source HIP port](https://github.com/lmxxf/dlss5-on-amd-9070xt-porting), `LmxxfNrRuntime.dll` built here | [mochizuki0323's Vulkan port](https://github.com/mochizuki0323/DLSSNR-AMD), `MochizukiNrRuntime.dll` built here, not in the package |
| Weights | `dlssnr_on_amd_weights.bin` | `native-game-tiled-assets\` | `dlssnr-amd\dlssnr.bin`, made from your own `nvngx_dlssnr.dll` 310.8.0 |
| GPUs | RDNA3 and RDNA4 with HIP 7 (0.6.0 adds RDNA2, with the HIP SDK 7.2 runtime) | RDNA4: RX 9070 series (`lmxxf-modules`) and RX 9060 series (`lmxxf-modules-gfx1200`) | RDNA4 (Vulkan FP8) |
| Where it runs | Before Super Resolution, or on the finished frame (the only choice for Ray Reconstruction titles) | Before Super Resolution, render resolution up to 1080p | Before Super Resolution, on a Vulkan device of its own beside the game's DirectX 12, or on the finished frame |
| Controls | Passes 1-3, NR slots, wait mode, encoding (Linear default), style, NR resolution with dynamic scaling, effect strength, lighting and structure | Passes 1-3, style, temporal history and smoothing, detail and colour strength, reuse on still scenes, compact 1080 tier, debug view | Passes 1-3, NR resolution, dynamic resolution, temporal history, detail and colour strength, style, intensity, tone, structure, skin, highlight guard |

No runtime's weights are included; all three are derived from NVIDIA's model.

**mochizuki is experimental.** This package has only its OptiScaler side: `NrBackend=mochizuki`, the
`Mochizuki*` keys and its section in the Neural tab. The runtime (`MochizukiNrRuntime.dll` and its
`dlssnr-amd\` folder) is not in it, and neither is the model, `dlssnr.bin`. The OpenNR installer
sets up both. To do it by hand, build the runtime with `tools\build-mochizuki-runtime.cmd` and make
the model as `third_party/mochizuki/UPSTREAM.md` ("The model") describes. On an RX 9070 XT the
network takes about 8.5 ms per frame at 1080p. The first start in each game compiles its pipelines,
and frames pass through without NR until it is done. With a prewarm manifest
(`dlssnr-amd\prewarm\manifest.txt`) they compile in parallel. The build above does not make one:
without it they compile one after another (about 22 s in the test harness), and the runtime then
writes it.

**On danielblnc and lmxxf:** a neural pass meter (GPU milliseconds per frame and the fps the model
alone could reach), shown on the FPS overlay too, and a menu with its sections down the left. On danielblnc the **Style**
option (Standard, Natural, Cinematic) is the network's own style input, as in his overlay.

**FSR-RR.** AMD's FidelityFX denoiser as the Ray Reconstruction provider, with its own
signal and responsivity controls. Set `Dx12Upscaler=fsr-rr` under `[Upscalers]`. The two denoising
routes are alternatives: pick one per game.

**XeSS multi frame generation.** Intel's XeFG generates up to 7 frames per rendered one (8X) on
AMD cards too. Intel only allows it with its own driver build, so `libxess_fg.dll` and
`libxell.dll` are patched in memory; the files on disk stay as shipped. Set `FGOutput=xefg`, and
`FGInput=dlssg` in games with DLSS frame generation. The **MFG** combo in the XeFG section follows
the game's multiplier (**Auto**) or takes 2X to 8X. Above 4X, turn on VSync or cap the frame rate.
Close RivaTuner Statistics Server (RTSS, also started by MSI Afterburner) while frame generation runs:
its present hook holds XeFG back, which shows as stutter and a lower base frame rate (the menu warns
when it is loaded), and OptiScaler's FPS limit goes through RTSS and counts the generated frames.
Without FreeSync, if 2X stays at half the refresh rate, turn off "AMD Optimized" in the game's
Adrenalin profile.
When a game ships an older `libxell.dll` of its own (Cyberpunk 2077 does), XeFG is pointed at
OptiScaler's copy.

## Installing

1. Extract the release next to the game's executable (for Cyberpunk 2077, `bin\x64`).
2. For danielblnc, put its `version.dll` or `dlssnr_on_amd_setup.exe` next to `Setup.bat`, plus
   `dlssnr_on_amd_weights.bin` if you have it. Setup takes `version.dll` out of the setup without
   running it, and runs the setup only to make the weights. 0.4.x uses the same weights as 0.3.x.
   To update from an older runtime, drop the 0.5.1 setup next to `Setup.bat` and run Setup again: when more
   than one known runtime is found, the newest is installed and its version is printed.
   danielblnc's 0.6.0 supporter build is not in any package; if you have it, put its
   setup next to `Setup.bat`, or replace `dlssnr_amd_pass1.dll` in the game folder with its
   `version.dll` (and delete that `version.dll` from the game folder if its own setup put it there).
   Passes 2 and 3 are copied from pass 1 when they are missing or hold another runtime.
   For lmxxf, put `native-game-tiled-assets\` next to `Setup.bat` or in the game folder; the
   runtime, modules and shaders ship in the package. For
   mochizuki, copy `MochizukiNrRuntime.dll` and its `dlssnr-amd\` folder (`shaders\`, your
   `dlssnr.bin`, and `prewarm\manifest.txt` if you have one) into the game folder after Setup,
   and set `NrBackend=mochizuki`.
3. Close the game and run `Setup.bat`. Choose the game folder and a proxy name (`dxgi.dll` is the
   usual one). `Uninstall_OptiScaler_NR.bat` in the game folder removes it again.
4. In game, press **Ins**, open the **Neural** tab and turn on **Enable NR**. In a game that uses
   Ray Reconstruction, set **Processing point** to **After the finished frame** (danielblnc only).

The [OpenNR Installer](https://github.com/zmodelerlover/OpenNR-Installer) (v0.5.0
or later) does all of this in one step for DirectX 12 games, lmxxf weights included, and lets you
pick which release goes in. It does not set up mochizuki yet.

**32-bit games.** `OptiScaler.dll` is 64-bit only. The package's `x86\` folder has a 32-bit proxy per
API and `OptiScalerDx9Host.exe`, a 64-bit host that runs OptiScaler (NR without upscaling, XeFG, the
menu) on the game's frames from an `OptiScaler64\` folder beside the proxy
([tools/dx9-x86/README.md](tools/dx9-x86/README.md)):

| Game | Proxy beside the executable |
|---|---|
| D3D9 | `d3d9.dll` |
| D3D10, D3D11 | `dxgi.dll` |
| OpenGL | `opengl32.dll` |

## Settings

All in `OptiScaler.ini`, section `[DlssNr]`, and in the **Neural** tab of the overlay.

| Key | What it does |
|---|---|
| `NrBackend` | `daniel`, `lmxxf`, `mochizuki`, `off` or `auto` (danielblnc when both danielblnc and lmxxf are present; never mochizuki) |
| `ApplyAfterRR` | Run on the finished frame instead of before Super Resolution (danielblnc; lmxxf and mochizuki always run before) |
| `AmdEncoding` | 1 Linear (default), 2 sRGB, 3 Gamma 2.2 |
| `AmdEffectStrength` | Share of the network's effect, 0 to 1 (danielblnc 0.3.1 and later) |
| `AmdStyle` | danielblnc Style: 0 standard, 1 natural, 2 cinematic |
| `AmdQuality` | "DLSS 5 mode": 0 fast (default, about 13% faster on RX 9000), 1 quality (NVIDIA's own arithmetic). danielblnc 0.4.2 and later |
| `AmdToneCurve` | The display curve the network sees the frame through: 0 Reinhard (default), 1 ACES. danielblnc 0.4.0 and later |
| `AmdSlots`, `AmdGraphicsWait` | Frames in flight and wait mode (danielblnc) |
| `AmdDynamicScale`, `AmdDynamicTargetFps` | Lower the NR resolution while under the target frame rate |
| `LmxxfFitLarge` | Let lmxxf take a render resolution above 1080p (can hitch; off by default) |
| `LmxxfTemporal` | Each lmxxf pass reads its own result from the previous frame, moved by the game's motion vectors (on by default) |
| `LmxxfSmoothStrength`, `LmxxfSmoothThreshold` | With temporal history, blend the result toward the previous frame's where they differ by less than the threshold (in 1/255): 0.8 and 10 by default, strength 0 is off |
| `LmxxfPassEstimate`, `LmxxfSkinProtect` | With three lmxxf passes, run two and extrapolate the third from them (upstream's multi-pass predict): 1080p 30 to 21 ms, close to a real third pass; on by default. With two or three, skin-coloured areas keep pass 1's result so faces do not take the extra passes (it goes by colour: brown and orange surfaces are protected too); off by default |
| `LmxxfOriginalModel` | lmxxf's 71-block model instead of the Small one of NVIDIA's 310.9.16 DLL (lmxxf 0.44's 0.5x mode, `native-game-tiled-assets\small\`), which runs by default with one pass when it is installed: 1080p 10.3 to 6.5 ms a frame on an RX 9070 XT, a lighter edit. Two or three passes run the 71-block model anyway. Off by default; a change rebuilds the network |
| `LmxxfAutoExposure` | Give lmxxf a white point measured from the frame's mean brightness instead of a fixed one, for games that hand very dark linear colour (KCD2 at night) where the model shows grain or a green tint; off by default |
| `MochizukiReno*` | mochizuki's network always runs inside upstream's RenoDX stage, and these are its settings, RenoDX's own with its defaults: the model (`RenoStyle`, `RenoIntensity`, `RenoLocalTone`, `RenoLocalStructure`, `RenoSkinStructure`, `RenoAutoMask`, `RenoSkinIndependent`), the pass stack (`RenoPasses` 1 to 4, 30 with `RenoUnlockPasses`, `RenoChainedHistory`, and `RenoPass2*` to `RenoPass4*` for each later pass), the composition (`RenoTransferStrength`, `RenoColorStrength`, `RenoChromaClamp`, `RenoStyleHighlightGuard`, black restore and pedestal, codec), the resolution (`RenoResolutionScale` 0.33 to 1, `RenoFollowInputRes`, `RenoLookUpsample`), the look (`RenoLookMode` and the `RenoLook*` sliders), the encoding (`RenoSourceEncoding`, `RenoPaperWhiteScale`, `RenoFeedMode` and the divisor's governor) and the motion vectors' scale. `RenoPasses`, `RenoResolutionScale` and `RenoSourceEncoding` rebuild the network. With mochizuki, `RenoComposition` is not used |
| `MochizukiTemporal`, `MochizukiHistoryStrength` | mochizuki's history from the previous frame, moved by the game's motion vectors, and how much of it is blended in (0 to 1). On and 1 by default; without the key, `LmxxfTemporal` decides |
| `MochizukiAco` | Run the network as machine code made in advance by ACO (the Linux driver's compiler), from `dlssnr-amd\aco\`, instead of compiling it with AMD's Windows compiler: about a fifth faster (RX 9070 XT 1080p 14 to 10.5 ms), the same picture. On by default; its author tested it on AMD Software 26.9.2 only. Takes effect when the game starts again; without the driver's pipeline binaries or that folder, the driver compiles as before |
| `MochizukiInt4` | With ACO, the int4 mixed network: part of it in 4-bit integers, made from the model into `dlssnr-amd\dlssnr-int4.bin`, about a tenth faster again (1080p 10.1 to 9.2 ms), the picture close to the default network's but not the same (about 40 dB from it). Off by default. A change rebuilds the network in a few seconds while the frames keep the current one; no restart, and only one network stays in video memory |
| `MochizukiOriginalModel` | The 310.8 model (`dlssnr-amd\dlssnr.bin`) instead of the new model of NVIDIA's 310.9.16 DLL (`dlssnr-amd\dlssnr-small.bin`), which runs by default when it is installed: about a third faster (1080p 9.8 to 6.3 ms, 4K 36 to 23 ms), a slightly lighter edit. int4 mixed exists for the 310.8 model only and turns this on by itself. Off by default; a change rebuilds the network |
| `MochizukiApplyModel` | `false` runs the network at full cost but shows the original frame (on by default) |
| `MochizukiDynamicResolution` | For games that change their render resolution as they run: `auto` (default) keeps one network, built for the largest resolution seen, once the render resolution drops below the colour buffer, and the frame moves inside it; `exact` rebuilds the network for every resolution (a second or two without NR each time); `always` is `auto` from the first frame, also across buffer reallocations |
| `MochizukiPreprocess*` | mochizuki0323's Preprocess: the picture the network is shown, changed before it runs and taken back out of its answer; its auto or fixed exposure replaces the RenoDX stage's divisor, and its curve the stage's. Off by default |
| `MochizukiNoiseEveryFrame`, `MochizukiLayerMode` | Frames without motion vectors move the network's noise seed every frame, as NVIDIA's DLL does (off by default). `LayerMode` is read and ignored, as in TheAutomatic's fork |
| `MochizukiStyleGrade` | Natural and Cinematic (`MochizukiRenoStyle` 1 and 2) graded after the network as NVIDIA's DLL does (mochizuki0323's 0.0.7), so the two look apart; `false` gives the earlier picture. Standard is not graded. On by default, no rebuild |
| `NrPersonPartition` | Person protection, lmxxf and mochizuki before SR (TheAutomatic's): a person mask made on the CPU by `person-worker.exe`, from `person-model\` beside OptiScaler, keeps the first pass's result on people with two or more passes (mochizuki: `MochizukiRenoPasses`, the RenoDX stage's pass 1), the last pass's elsewhere. Off by default |
| `NrPersonModel`, `NrFaceInputSize` | The mask's model: 0 PP-HumanSeg (default), 1 YOLO11n-seg, 2 YuNet (faces only, its input 320 by default, or 384, 416, 448) |
| `NrPersonStrength`, `NrPersonDetailGain`, `NrPersonDebugMask` | How much of NR's change, and of its fine detail, reaches people (0 to 1, 1 by default; below 1 they act in single pass too); the mask tinted green, with a log line every two seconds (off) |

mochizuki's tuning comes only from its own `Mochizuki*` keys, so it and the other runtimes' stay apart.
One leftover: without `MochizukiTemporal`, `LmxxfTemporal` decides.

Multi frame generation reads `[XeFG]`: `InterpolationCount` (`auto` follows the game, 1 to 7 is
2X to 8X), `UnlockMFG`, `MaxInterpolatedFrames` (default 7) and `ExtraPacing`.

### Keys and screenshots

| Key (`[Menu]`) | Default | What it does |
|---|---|---|
| `ShortcutKey` | Insert | Menu |
| `FpsShortcutKey`, `FpsCycleShortcutKey` | Page Up, Page Down | FPS overlay on and off, its layout |
| `FGShortcutKey` | End | Frame generation on and off |
| `ScreenshotKey` | F6 | Saves the presented frame, NR included, without OptiScaler's overlays: `<exe> <date> <time>.png` in `ScreenshotPath` (default `<Pictures>\OptiScaler\<exe name>\`, also set from the menu with Change folder...); HDR games also get a `.jxr` with the HDR data, the `.png` mapped to SDR. With the menu open and `ScreenshotWithMenu` (default true), a second `... (menu).png` of the same frame with the menu on it |
| `[DlssNr] ToggleKey` | Numpad 5 | NR on and off |

Any of them takes a combination with Ctrl, Shift, Alt or Tab: bind it in the menu's Keybinds section or
write `Ctrl+Shift+Home` in the INI. A key fires only with exactly its modifiers held.

## Building

Visual Studio with the v143 toolset, `Release|x64`, after `git submodule update --init`. Keep
`tools/` beside the solution: a pre-build step runs from it. `tools\build-lmxxf-runtime.cmd
exports\lmxxf-runtime` builds the lmxxf runtime, `tools\build-mochizuki-runtime.cmd
exports\mochizuki-runtime` the mochizuki one (from an MSVC prompt, with the Vulkan SDK 1.4.357 or
newer and Python), `tools\build-person-worker.cmd` the person protection worker into
`exports\release-local\person-model`, and `tools/PACKAGE_RELEASE.ps1` makes the release zip. CI checks formatting with
clang-format 20 under `OptiScaler/`.

## Credits

- [OptiScaler](https://github.com/optiscaler/OptiScaler) by cdozdil and contributors, the base of
  everything here. This project uses [FreeType](https://gitlab.freedesktop.org/freetype/freetype)
  under the [FTL](https://gitlab.freedesktop.org/freetype/freetype/-/blob/master/docs/FTL.TXT).
- [Dagherbou/OptiScaler_DLSSNR](https://github.com/Dagherbou/OptiScaler_DLSSNR), which first put
  DLSS-NR into OptiScaler, and
  [wilsjo2/OptiScaler-DLSSNR-PreSR-Multipass](https://github.com/wilsjo2/OptiScaler-DLSSNR-PreSR-Multipass),
  which added the pre-SR multipass pipeline.
- [MatheusGViana/dlss-5-amd-project](https://github.com/MatheusGViana/dlss-5-amd-project) and
  [TheAutomatic/dlss-5-amd-project](https://github.com/TheAutomatic/dlss-5-amd-project): the AMD
  bridge into the runtime, multi-slot scheduling, the D3D12 state freeze and restore, the lmxxf
  integration and its same-frame submission layer.
- [burak113/OptiScaler](https://github.com/burak113/OptiScaler/tree/ffx-denoise-experimental): FSR-RR.
- [Coldwood1026/OptiScalerDp4aUnlock](https://github.com/Coldwood1026/OptiScalerDp4aUnlock): the
  XeFG multi frame generation unlock, its frame pacing, the `libxell` ceiling patch and the
  multiplier that follows the game. YiBoF contributed its Intel Arc support.
- [danielblnc/DLSS-NR-on-AMD](https://github.com/danielblnc/DLSS-NR-on-AMD): the AMD neural runtime
  this bridges into. It is not reimplemented here.
- [lmxxf/dlss5-on-amd-9070xt-porting](https://github.com/lmxxf/dlss5-on-amd-9070xt-porting) (MIT):
  the open-source HIP port, vendored under `third_party/lmxxf`.
- [mochizuki0323/DLSSNR-AMD](https://github.com/mochizuki0323/DLSSNR-AMD) (MIT): the Vulkan port,
  vendored under `third_party/mochizuki`.
- [RenoDX](https://github.com/clshortfuse/renodx) by clshortfuse: the colour composition in
  `dlssnr.hlsl`.
- [TheAutomatic/dlss-5-amd-project](https://github.com/TheAutomatic/dlss-5-amd-project): person
  protection (`OptiScaler/dlssnr/person/`). Its models are PP-HumanSeg (Apache-2.0) and YuNet (MIT)
  from the OpenCV Zoo and Ultralytics YOLO11n-seg (AGPL-3.0), run by Microsoft ONNX Runtime (MIT);
  the installer ships them, see `third_party/onnxruntime/README.md`.

NVIDIA's DLSS binaries and model weights are not redistributed. FidelityFX, XeSS and the DirectX
Agility SDK keep their own licences, in `Licenses/`.

## License

GPL-3.0, as OptiScaler. See `LICENSE`.
