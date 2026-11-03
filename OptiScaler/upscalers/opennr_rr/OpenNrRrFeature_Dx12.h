#pragma once
#include <upscalers/IFeature_Dx12.h>
#include "opennr_rr_api.h"

#include <string>

// OpenNrRrRuntime.dll, loaded once from OptiScaler's folder.
namespace OpenNrRr
{
// Loads the runtime and asks it once whether this adapter and nvngx_dlssd.dll can run the network.
bool Usable(LUID adapter);
// Whether Usable has run, and why OpenRR is not offered (empty while it is).
bool Checked();
std::string Reason();
// A failure this session: OpenRR stays off until the game restarts, so the fallback never returns to it.
void Block(const std::string& why);
// The running context's state, for the menu. False without one.
bool Info(OnrRrInfo& info);
// Whether the game's lists are OptiScaler's split proxies, set up at launch when an NR runtime that splits them or
// OpenRR was enabled.
bool SplitReady();
// NrOnDenoised: what mochizuki on the denoised image is doing, or why it is not running. Empty while it is off.
std::string DenoisedNrStatus();
} // namespace OpenNrRr

class OpenNrRrFeatureDx12 : public IFeature_Dx12
{
  public:
    OpenNrRrFeatureDx12(unsigned int InHandleId, NVSDK_NGX_Parameter* InParameters);
    ~OpenNrRrFeatureDx12();

    // OpenRR's release, as the overlay and the menu show it (not the runtime's ABI)
    feature_version Version() override { return { 0, 1, 0 }; }
    Upscaler GetUpscalerType() const override { return Upscaler::OpenNrRr; }
    bool IsWithDx12() final { return false; }

  protected:
    bool InitInternal(ID3D12GraphicsCommandList* InCommandList, NVSDK_NGX_Parameter* InParameters) override;
    bool EvaluateInternal(ID3D12GraphicsCommandList* InCommandList, NVSDK_NGX_Parameter* InParameters) override;

  private:
    void* _context = nullptr;
    // The job armed on a list's between slot, until that list runs.
    void* _job = nullptr;
    ID3D12CommandList* _jobList = nullptr;
    uint32_t _maxRenderWidth = 0;
    uint32_t _maxRenderHeight = 0;
    bool _ngxHWDepth = false;
    bool _hasNGXDepthType = false;
    int _roughnessPacked = -1; // -1 until the create params or the first frame settle it
    int _loggedHWDepth = -1;
    int _loggedSwitches = -1;   // the diagnostic switches last logged
    float _loggedMaskScale = 0.0f;
    bool _fellBack = false;

    void DropStaleJob();
    bool FillFrame(const NVSDK_NGX_Parameter& params, OnrRrFrame& frame);
    void FallBack(const std::string& why);
    // NrOnDenoised: mochizuki's lists for this job, run by the between slot from EnqueueNetwork to EnqueuePost (D3D12:
    // between the halves of the game's list); image: the one Record gave (D3D12), null to ask PrepareDenoised. The
    // DXGI format the lists write back into the image, 0 when none were armed.
    uint32_t RecordDenoisedNr(const NVSDK_NGX_Parameter& params, const OnrRrFrame& frame, void* job, const OnrRrDenoisedImage* image);
    // the hop's GPU timeline of a timed frame of this slot into the log (render thread)
    void LogHopTiming(int slotIndex);
    static int32_t Between(void* feature, void* job, void* queue);
    // D3D12 backend: the frame recorded into the game's list (Record / RecordPost)
    bool EvaluateD3d12(ID3D12GraphicsCommandList* InCommandList, NVSDK_NGX_Parameter* InParameters);
    static int32_t BetweenD3d12(void* feature, void* job, void* queue);
};
