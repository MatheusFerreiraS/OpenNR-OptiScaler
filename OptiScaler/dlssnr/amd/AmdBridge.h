#pragma once
#include <d3d12.h>
#include <nvsdk_ngx.h>
#include <filesystem>
#include <string>
class Config;
namespace AmdPreSr
{
struct Settings;
}
namespace DlssNr::AmdBridge
{
AmdPreSr::Settings SettingsFromConfig(const Config& cfg, float modelScale);
bool HasFiles();
// NeuralHub 0.8.0 serves DLSS Frame Generation: its host module sits in dlssnr_amd_host\ beside this DLL and an
// nvngx_dlssg.dll beside the host or the game. Only files are checked, so it answers before the host loads (slInit,
// the INI); a game that ships nvngx_dlssg.dll without the host is not taken for one. Never with the host kept on HIP.
bool NeuralHubFgInstalled();
// The same with OptiScaler's library folder and HostComputeBackend given: Config's own load asks this way, since
// LibraryFolder() reads Config and would construct it again from inside its constructor.
bool NeuralHubFgInstalled(const std::filesystem::path& library, const std::string& backend);
// The armed host found an nvngx_dlssg.dll, or NeuralHubFgInstalled(): DLSS-FG is offered on AMD.
bool NeuralHubFgServed();
// [DlssNr] HostComputeBackend=HIP: the 0.8.0 host stays on HIP for danielblnc's NR, and its DLSS-FG (D3D12 only) is off.
bool HostKeptOnHip();
// OptiScaler's library folder ([Libraries] OptiDllPath, OptiScaler\ beside this DLL by default). NVIDIA's
// nvngx_dlss(.d/.g).dll placed there feed NeuralHub ahead of the game's own copies.
std::filesystem::path LibraryFolder();
// Install submission expansion before the first wrapped list is exposed. No runtime/HIP initialization.
bool EnsureSubmissionHook(ID3D12CommandQueue*);
bool EnsureNgxHost(ID3D12Device*, ID3D12CommandQueue* = nullptr);
bool Before(ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, ID3D12CommandQueue*);
// Post-upscale placement: runs the model over the frame the upscaler (or Ray Reconstruction) has
// already finished, and hands its answer back instead of substituting the upscaler's input. The
// caller owns writing it into the frame, because only it knows that surface's format and state.
// Returns true when the backend owns this frame (result may still be null on a skipped frame).
bool After(ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, ID3D12CommandQueue*, ID3D12Resource** outResult);
void Restore(NVSDK_NGX_Parameter*);
bool HasReplacement(NVSDK_NGX_Parameter*);
void InvalidateHistory();
// Person protection's state and its worker's (model loaded, CPU time of the last mask), for the menu.
std::string PersonStatus();
void TraceContextRelease(unsigned int handle, bool after);
std::string Status();
// When the stall watch (StallWatch.h) tripped: NR goes off for this session (the INI keeps it), the note below says
// why and the watch is cleared, so NR switched on again retries. Otherwise the note is cleared. True when it stood
// NR down. The upscaler path and NR without upscaling both ask before each frame.
bool StandDownIfTripped();
// Set when the stall watch switched NR off, cleared once NR runs again; what the menu shows next to Enabled.
std::string StandDownNote();
// The runtime's own status line (for mochizuki: network size and time, or the build in progress), refreshed by
// the render thread at most twice a second; empty until a session runs. Never waits on a frame being recorded.
std::string RuntimeStatus();
// True once the process-exit hook has run. Everything after it passes the original colour through.
bool Exiting();
// Smoothed GPU time the neural work takes on the game's queue per frame, all passes; 0 before the
// first reading.
float NeuralMs();
// The last frame's reading, unsmoothed; 0 when no model has run in the last second (off, refused,
// or another path). What the FPS overlay draws.
float NeuralMsLast();
// A reading the final image took itself (PresentExperimental.h), into the same menu line, overlay line and graph.
void ReportNeuralMs(float ms);
// "danielblnc 0.5.1", "mochizuki" or "lmxxf": the runtime the backend was built for; empty before.
std::string NeuralRuntime();
// Dynamic NR resolution: the scale in use and the rendered frame rate, or empty while it is off.
std::string DynamicStatus();
bool GraphicsRestartNeeded(UINT activePasses);
// pass1 SHA name ("0.3.0" / "0.3.1" / "0.4.0" / "0.4.1" / …) or nullptr if missing/unknown.
// Cached for menu display until the DLL path, size, or write time changes.
const char* RuntimeName();
void UpdateConfirmedRenderQueue(ID3D12CommandQueue* q);
} // namespace DlssNr::AmdBridge
