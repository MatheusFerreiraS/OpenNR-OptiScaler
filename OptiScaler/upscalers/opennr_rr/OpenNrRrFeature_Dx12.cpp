#include "pch.h"
#include "OpenNrRrFeature_Dx12.h"

#include <Config.h>
#include <Util.h>
#include <NVNGX_Parameter.h>
#include <nvsdk_ngx_defs_dlssd.h>
#include <misc/IdentifyGpu.h>
#include <imgui/ImGuiNotify.hpp>
#include <dlssnr/backend/LmxxfEvaluateCut.h>

#include <atomic>
#include <cmath>
#include <filesystem>
#include <format>
#include <mutex>

namespace LmxxfCut = DlssNr::Backend::LmxxfCut;

namespace
{
std::mutex s_mutex;
HMODULE s_module = nullptr;
OnrRrApi s_api {};
bool s_loadTried = false;
bool s_checked = false;
bool s_usable = false;
LUID s_luid {};
std::string s_reason;
std::string s_blocked;
std::wstring s_dlssdPath;
void* s_infoContext = nullptr;

// Set by the between slot, read on the next evaluate.
std::atomic<int32_t> s_enqueueRc { ONR_RR_OK };

// NGX publishes the depth type only on a creation that carries DLSSD create params; a recreation keeps it.
bool s_ngxDepthTypeSeen = false;
bool s_ngxReportedHWDepth = false;

std::string RuntimeError()
{
    char text[256] {};
    if (s_api.GetLastError)
        s_api.GetLastError(text, sizeof text);
    return text;
}

int32_t EnqueueThunk(void* context, void* job, void* queue)
{
    const int32_t rc = s_api.Enqueue(context, job, queue);
    if (rc != ONR_RR_OK)
        s_enqueueRc.store(rc, std::memory_order_release);
    return rc;
}

// Caller holds s_mutex.
bool Load()
{
    if (s_loadTried)
        return s_module != nullptr;

    s_loadTried = true;

    const auto path = Util::DllPath().parent_path() / L"OpenNrRrRuntime.dll";
    std::error_code ec;

    if (!std::filesystem::exists(path, ec))
    {
        s_reason = "OpenNrRrRuntime.dll is not in OptiScaler's folder";
        LOG_INFO("OpenNR RR: {} ({})", s_reason, wstring_to_string(path.wstring()));
        return false;
    }

    HMODULE module = LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);

    if (module == nullptr)
    {
        s_reason = std::format("OpenNrRrRuntime.dll did not load (error {})", GetLastError());
        LOG_ERROR("OpenNR RR: {} ({})", s_reason, wstring_to_string(path.wstring()));
        return false;
    }

    auto getApi = reinterpret_cast<PFN_OnrRrGetApi>(GetProcAddress(module, "OnrRrGetApi"));
    OnrRrApi api {};
    const int32_t rc = getApi != nullptr ? getApi(ONR_RR_ABI_VERSION, &api) : ONR_RR_FAILED;

    if (rc != ONR_RR_OK || api.abi_version != ONR_RR_ABI_VERSION || !api.Check || !api.Create || !api.Destroy ||
        !api.SetMode || !api.RecordInputs || !api.Enqueue || !api.RecordOutput || !api.Cancel || !api.GetInfo ||
        !api.GetLastError)
    {
        s_reason = std::format("OpenNrRrRuntime.dll does not offer ABI {} (rc {}, abi {})", ONR_RR_ABI_VERSION, rc,
                               api.abi_version);
        LOG_ERROR("OpenNR RR: {}", s_reason);
        FreeLibrary(module);
        return false;
    }

    s_module = module;
    s_api = api;
    LOG_INFO("OpenNR RR: runtime loaded from {}", wstring_to_string(path.wstring()));
    return true;
}

// The nvngx_dlssd.dll the weights are built from: OptiScaler's own lookup first, then the one the game loaded, then
// one beside the game's exe.
std::wstring FindDlssd(const char** source)
{
    if (const auto& known = State::Instance().NVNGX_DLSSD_Path; known.has_value())
    {
        *source = "OptiScaler's nvngx_dlssd.dll path";
        return known.value();
    }

    if (HMODULE loaded = GetModuleHandleW(L"nvngx_dlssd.dll"); loaded != nullptr)
    {
        wchar_t path[MAX_PATH] {};
        if (GetModuleFileNameW(loaded, path, MAX_PATH) != 0)
        {
            *source = "loaded by the game";
            return path;
        }
    }

    if (auto found = Util::FindFilePath(Util::ExePath().remove_filename(), "nvngx_dlssd.dll"); found.has_value())
    {
        *source = "beside the game's exe";
        return found->wstring();
    }

    *source = "not found";
    return {};
}

enum class DepthKind
{
    Unknown,
    Hardware,
    GameWritten,
};

// Same reading as FSR-RR: a depth-stencil resource cannot hold a linear distance, a render target or UAV the game
// filled may.
DepthKind ClassifyDepth(ID3D12Resource* depth)
{
    if (depth == nullptr)
        return DepthKind::Unknown;

    const D3D12_RESOURCE_DESC desc = depth->GetDesc();

    if ((desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL) != 0)
        return DepthKind::Hardware;

    switch (desc.Format)
    {
    case DXGI_FORMAT_D32_FLOAT:
    case DXGI_FORMAT_D32_FLOAT_S8X24_UINT:
    case DXGI_FORMAT_D24_UNORM_S8_UINT:
    case DXGI_FORMAT_D16_UNORM:
    case DXGI_FORMAT_R32G8X24_TYPELESS:
    case DXGI_FORMAT_R32_FLOAT_X8X24_TYPELESS:
    case DXGI_FORMAT_R24G8_TYPELESS:
    case DXGI_FORMAT_R24_UNORM_X8_TYPELESS:
        return DepthKind::Hardware;
    default:
        break;
    }

    if ((desc.Flags & (D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET | D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS)) != 0)
        return DepthKind::GameWritten;

    return DepthKind::Unknown;
}

// The matrix exactly as the game passed it; all zero when absent or not finite.
void ReadMatrix(const NVSDK_NGX_Parameter& params, const char* key, float (&out)[16])
{
    float* matrix = nullptr;

    if (params.Get(key, reinterpret_cast<void**>(&matrix)) != NVSDK_NGX_Result_Success || matrix == nullptr)
        return;

    for (int i = 0; i < 16; i++)
    {
        if (!std::isfinite(matrix[i]))
            return;
    }

    memcpy(out, matrix, sizeof(out));
}

uint32_t ModeFromConfig()
{
    const auto mode = Config::Instance()->OpenNrRrMode.value_or_default();
    return _stricmp(mode.c_str(), "faithful") == 0 ? ONR_RR_MODE_FAITHFUL : ONR_RR_MODE_FAST;
}

const char* ModeName(uint32_t mode) { return mode == ONR_RR_MODE_FAITHFUL ? "faithful" : "fast"; }

const char* StateName(uint32_t state)
{
    switch (state)
    {
    case ONR_RR_STATE_BUILDING:
        return "building";
    case ONR_RR_STATE_READY:
        return "ready";
    case ONR_RR_STATE_FAILED:
        return "failed";
    default:
        return "unknown";
    }
}
} // namespace

namespace OpenNrRr
{
bool Usable(LUID adapter)
{
    std::lock_guard lock(s_mutex);

    if (!s_blocked.empty())
        return false;

    if (s_checked && IsEqualLUID(adapter, s_luid))
        return s_usable;

    s_checked = true;
    s_luid = adapter;
    s_usable = false;

    if (IdentifyGpu::getPrimaryGpu().vendorId != VendorId::AMD)
    {
        s_reason = "needs an AMD RDNA4 GPU";
        return false;
    }

    if (!Load())
        return false;

    const char* source = nullptr;
    s_dlssdPath = FindDlssd(&source);
    LOG_INFO("OpenNR RR: nvngx_dlssd.dll {} ({})", source, wstring_to_string(s_dlssdPath));

    int32_t rc;
    {
        ScopedSkipVulkanHooks skipVulkanHooks {};
        ScopedCreatingD3DDevice creatingDevice {};
        ScopedSkipSpoofingGlobal skipSpoofing {};
        rc = s_api.Check(&adapter, s_dlssdPath.empty() ? nullptr : s_dlssdPath.c_str());
    }

    if (rc != ONR_RR_OK)
    {
        s_reason = RuntimeError();
        if (s_reason.empty())
            s_reason = std::format("not supported here (rc {})", rc);
        LOG_INFO("OpenNR RR: Check rc={}: {}", rc, s_reason);
        return false;
    }

    if (s_dlssdPath.empty())
    {
        s_reason = "nvngx_dlssd.dll not found, the weights are built from it";
        LOG_INFO("OpenNR RR: {}", s_reason);
        return false;
    }

    s_reason.clear();
    s_usable = true;
    LOG_INFO("OpenNR RR: Check passed on adapter {:08X}:{:08X}", (uint32_t) adapter.HighPart, adapter.LowPart);
    return true;
}

bool Checked()
{
    std::lock_guard lock(s_mutex);
    return s_checked || !s_blocked.empty();
}

std::string Reason()
{
    std::lock_guard lock(s_mutex);
    return s_blocked.empty() ? s_reason : s_blocked;
}

void Block(const std::string& why)
{
    std::lock_guard lock(s_mutex);
    if (s_blocked.empty())
        s_blocked = "stopped this session: " + why;
    s_usable = false;
}

bool Info(OnrRrInfo& info)
{
    std::lock_guard lock(s_mutex);

    if (s_infoContext == nullptr)
        return false;

    info = {};
    info.size = sizeof(info);
    return s_api.GetInfo(s_infoContext, &info) == ONR_RR_OK;
}

bool SplitReady()
{
    return DlssNr::Backend::SubmissionHooksWanted() && DlssNr::Submission::Hooks::IsArmed() &&
           DlssNr::Submission::Hooks::ProxyWrapEnabled();
}
} // namespace OpenNrRr

OpenNrRrFeatureDx12::OpenNrRrFeatureDx12(unsigned int InHandleId, NVSDK_NGX_Parameter* InParameters)
    : IFeature(InHandleId, InParameters), IFeature_Dx12(InHandleId, InParameters)
{
    // The network writes the display-size frame itself, so the dual-feature split never applies to it.
    MarkEnlargementStage();

    std::lock_guard lock(s_mutex);
    _moduleLoaded = Load();
}

OpenNrRrFeatureDx12::~OpenNrRrFeatureDx12()
{
    if (State::Instance().isShuttingDown || _context == nullptr)
        return;

    DropStaleJob();

    {
        std::lock_guard lock(s_mutex);
        if (s_infoContext == _context)
            s_infoContext = nullptr;
    }

    s_api.Destroy(_context);
    _context = nullptr;
}

bool OpenNrRrFeatureDx12::InitInternal(ID3D12GraphicsCommandList* InCommandList, NVSDK_NGX_Parameter* InParameters)
{
    if (IsInited())
        return true;

    if (!ModuleLoaded() || Device == nullptr)
        return false;

    _initParameters = SetInitParameters(InParameters);

    if (!_initParameters)
        return false;

    if (!OpenNrRr::Usable(Device->GetAdapterLuid()))
    {
        LOG_ERROR("OpenNR RR: not usable: {}", OpenNrRr::Reason());
        return false;
    }

    if (int value; InParameters->Get(NVSDK_NGX_Parameter_Use_HW_Depth, &value) == NVSDK_NGX_Result_Success)
    {
        _hasNGXDepthType = true;
        _ngxHWDepth = value == NVSDK_NGX_DLSS_Depth_Type_HW;
        s_ngxDepthTypeSeen = true;
        s_ngxReportedHWDepth = _ngxHWDepth;
    }
    else if (s_ngxDepthTypeSeen)
    {
        _hasNGXDepthType = true;
        _ngxHWDepth = s_ngxReportedHWDepth;
    }

    if (int value; InParameters->Get(NVSDK_NGX_Parameter_DLSS_Roughness_Mode, &value) == NVSDK_NGX_Result_Success)
    {
        if (value == NVSDK_NGX_DLSS_Roughness_Mode_Packed)
            _roughnessPacked = 1;
        else if (value == NVSDK_NGX_DLSS_Roughness_Mode_Unpacked)
            _roughnessPacked = 0;
    }

    _maxRenderWidth = RenderWidth();
    _maxRenderHeight = RenderHeight();
    _mode = ModeFromConfig();

    const auto dataDir = (Util::DllPath().parent_path() / L"opennr-rr").wstring();
    std::wstring dlssd;
    {
        std::lock_guard lock(s_mutex);
        dlssd = s_dlssdPath;
    }

    OnrRrCreateInfo info {};
    info.size = sizeof(info);
    info.mode = _mode;
    info.d3d12_device = Device;
    info.max_render_width = _maxRenderWidth;
    info.max_render_height = _maxRenderHeight;
    info.output_width = DisplayWidth();
    info.output_height = DisplayHeight();
    info.dlssd_path = dlssd.c_str();
    info.data_dir = dataDir.c_str();

    int32_t rc;
    {
        ScopedSkipVulkanHooks skipVulkanHooks {};
        ScopedCreatingD3DDevice creatingDevice {};
        ScopedSkipSpoofingGlobal skipSpoofing {};
        rc = s_api.Create(&info, &_context);
    }

    if (rc != ONR_RR_OK || _context == nullptr)
    {
        const auto error = RuntimeError();
        LOG_ERROR("OpenNR RR: Create rc={}: {}", rc, error);
        OpenNrRr::Block(std::format("Create failed ({})", error));
        _context = nullptr;
        return false;
    }

    {
        std::lock_guard lock(s_mutex);
        s_infoContext = _context;
    }

    LOG_INFO("OpenNR RR: created, render {}x{} -> output {}x{}, mode {}, weights from {}", _maxRenderWidth,
             _maxRenderHeight, DisplayWidth(), DisplayHeight(), ModeName(_mode), wstring_to_string(dlssd));

    if (!LowResMV())
        LOG_WARN("OpenNR RR: the game declares display-size motion vectors; the runtime reads them at render size");

    SetInit(true);
    return true;
}

// The previous frame's job is still armed when its list was reset, released or not yet executed. It can no longer be
// enqueued, so the runtime drops it. A job the between slot already took is left alone.
void OpenNrRrFeatureDx12::DropStaleJob()
{
    if (_job == nullptr)
        return;

    bool stillArmed = false;
    {
        auto& pending = LmxxfCut::Pending();
        std::lock_guard lock(pending.mutex);
        if (pending.job == _job && pending.session == _context && pending.targetList == _jobList)
        {
            stillArmed = true;
            pending.session = nullptr;
            pending.job = nullptr;
            pending.enqueueHip = nullptr;
            pending.getLastError = nullptr;
            pending.targetList = nullptr;
            pending.expectedQueue = nullptr;
        }
    }

    if (stillArmed)
    {
        s_api.Cancel(_context, _job);

        static uint32_t dropped = 0;
        if (++dropped <= 10 || dropped % 300 == 0)
            LOG_WARN("OpenNR RR: the list of the previous frame never ran its between slot; job cancelled (#{})",
                     dropped);
    }

    _job = nullptr;
    _jobList = nullptr;
}

void OpenNrRrFeatureDx12::FallBack(const std::string& why)
{
    if (_fellBack)
        return;

    _fellBack = true;
    LOG_ERROR("OpenNR RR: {}; switching Ray Reconstruction back to the previous provider", why);
    ImGui::InsertNotification(
        { ImGuiToastType::Warning, 10000, "OpenNR RR stopped, Ray Reconstruction goes back to FSR-RR (see the log)" });

    OpenNrRr::Block(why);

    auto& state = State::Instance();
    state.newBackend = Upscaler::FSR_RR;
    state.changeBackend[Handle()->Id] = true;
}

bool OpenNrRrFeatureDx12::FillFrame(const NVSDK_NGX_Parameter& params, OnrRrFrame& frame)
{
    const auto& cfg = *Config::Instance();
    const auto& state = State::Instance();

    frame = {};
    frame.size = sizeof(frame);

    unsigned int width = 0;
    unsigned int height = 0;
    GetRenderResolution(&params, &width, &height);
    frame.render_width = std::min<uint32_t>(width, _maxRenderWidth);
    frame.render_height = std::min<uint32_t>(height, _maxRenderHeight);

    params.Get(NVSDK_NGX_Parameter_Jitter_Offset_X, &frame.jitter_x);
    params.Get(NVSDK_NGX_Parameter_Jitter_Offset_Y, &frame.jitter_y);
    if (!std::isfinite(frame.jitter_x))
        frame.jitter_x = 0.0f;
    if (!std::isfinite(frame.jitter_y))
        frame.jitter_y = 0.0f;

    // A missing, non-finite or zero component counts as one, as NGX does; a negative one is the game's axis.
    if (params.Get(NVSDK_NGX_Parameter_MV_Scale_X, &frame.mv_scale_x) != NVSDK_NGX_Result_Success ||
        !std::isfinite(frame.mv_scale_x) || frame.mv_scale_x == 0.0f)
        frame.mv_scale_x = 1.0f;
    if (params.Get(NVSDK_NGX_Parameter_MV_Scale_Y, &frame.mv_scale_y) != NVSDK_NGX_Result_Success ||
        !std::isfinite(frame.mv_scale_y) || frame.mv_scale_y == 0.0f)
        frame.mv_scale_y = 1.0f;

    ReadMatrix(params, NVSDK_NGX_Parameter_DLSS_WORLD_TO_VIEW_MATRIX, frame.world_to_view);
    ReadMatrix(params, NVSDK_NGX_Parameter_DLSS_VIEW_TO_CLIP_MATRIX, frame.view_to_clip);

    // The states FSR-RR assumes: shader readable inputs and a UAV output, or the barrier overrides from the config.
    const bool unreal =
        state.NVNGX_Engine == NVSDK_NGX_ENGINE_TYPE_UNREAL || state.gameQuirks & GameQuirk::ForceUnrealEngine;
    const uint32_t read = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    const uint32_t colorState = cfg.ColorResourceBarrier.value_or(unreal ? D3D12_RESOURCE_STATE_RENDER_TARGET : read);
    const uint32_t motionState = cfg.MVResourceBarrier.value_or(unreal ? D3D12_RESOURCE_STATE_UNORDERED_ACCESS : read);
    const uint32_t depthState = cfg.DepthResourceBarrier.value_or(read);
    const uint32_t outputState = cfg.OutputResourceBarrier.value_or(D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

    const auto texture = [&params](const char* key, const char* baseX, const char* baseY, uint32_t textureState)
    {
        OnrRrTexture t {};
        ID3D12Resource* resource = nullptr;

        if (TryGetNGXVoidPointer(params, key, resource))
        {
            t.resource = resource;
            t.state = textureState;

            if (baseX != nullptr)
            {
                params.Get(baseX, &t.x);
                params.Get(baseY, &t.y);
            }
        }

        return t;
    };

    frame.color = texture(NVSDK_NGX_Parameter_Color, NVSDK_NGX_Parameter_DLSS_Input_Color_Subrect_Base_X,
                          NVSDK_NGX_Parameter_DLSS_Input_Color_Subrect_Base_Y, colorState);
    frame.diffuse_albedo =
        texture(NVSDK_NGX_Parameter_DiffuseAlbedo, NVSDK_NGX_Parameter_DLSS_Input_DiffuseAlbedo_Subrect_Base_X,
                NVSDK_NGX_Parameter_DLSS_Input_DiffuseAlbedo_Subrect_Base_Y, read);
    frame.specular_albedo =
        texture(NVSDK_NGX_Parameter_SpecularAlbedo, NVSDK_NGX_Parameter_DLSS_Input_SpecularAlbedo_Subrect_Base_X,
                NVSDK_NGX_Parameter_DLSS_Input_SpecularAlbedo_Subrect_Base_Y, read);
    frame.normals = texture(NVSDK_NGX_Parameter_GBuffer_Normals, NVSDK_NGX_Parameter_DLSS_Input_Normals_Subrect_Base_X,
                            NVSDK_NGX_Parameter_DLSS_Input_Normals_Subrect_Base_Y, read);
    frame.roughness =
        texture(NVSDK_NGX_Parameter_GBuffer_Roughness, NVSDK_NGX_Parameter_DLSS_Input_Roughness_Subrect_Base_X,
                NVSDK_NGX_Parameter_DLSS_Input_Roughness_Subrect_Base_Y, read);
    frame.depth = texture(NVSDK_NGX_Parameter_Depth, NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_X,
                          NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_Y, depthState);
    frame.motion = texture(NVSDK_NGX_Parameter_MotionVectors, NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_X,
                           NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_Y, motionState);
    frame.specular_hit_distance = texture(NVSDK_NGX_Parameter_DLSSD_SpecularHitDistance,
                                          NVSDK_NGX_Parameter_DLSSD_SpecularHitDistance_Subrect_Base_X,
                                          NVSDK_NGX_Parameter_DLSSD_SpecularHitDistance_Subrect_Base_Y, read);
    frame.specular_ray_direction_hit_distance =
        texture(NVSDK_NGX_Parameter_DLSSD_SpecularRayDirectionHitDistance,
                NVSDK_NGX_Parameter_DLSSD_SpecularRayDirectionHitDistance_Subrect_Base_X,
                NVSDK_NGX_Parameter_DLSSD_SpecularRayDirectionHitDistance_Subrect_Base_Y, read);
    // Output may be OptiScaler's own buffer ahead of RCAS or output scaling, so it is written from its origin.
    frame.output = texture(NVSDK_NGX_Parameter_Output, nullptr, nullptr, outputState);

    if (frame.color.resource == nullptr || frame.depth.resource == nullptr || frame.motion.resource == nullptr ||
        frame.output.resource == nullptr)
    {
        FallBack(std::format("the game gave no {}", frame.color.resource == nullptr    ? "colour"
                                                    : frame.depth.resource == nullptr  ? "depth"
                                                    : frame.motion.resource == nullptr ? "motion vectors"
                                                                                       : "output"));
        return false;
    }

    static bool guidesLogged = false;
    if (!guidesLogged)
    {
        guidesLogged = true;
        LOG_INFO("OpenNR RR: guides diffuse albedo {}, specular albedo {}, normals {}, roughness {}, specular hit "
                 "distance {}, ray direction + hit distance {}",
                 frame.diffuse_albedo.resource != nullptr, frame.specular_albedo.resource != nullptr,
                 frame.normals.resource != nullptr, frame.roughness.resource != nullptr,
                 frame.specular_hit_distance.resource != nullptr,
                 frame.specular_ray_direction_hit_distance.resource != nullptr);
    }

    // Without the create-time mode, the first frame settles it: no roughness texture means it rides in normals.w.
    if (_roughnessPacked < 0)
    {
        _roughnessPacked = frame.roughness.resource == nullptr ? 1 : 0;
        LOG_INFO("OpenNR RR: roughness mode not declared, using {}", _roughnessPacked ? "packed" : "separate");
    }

    // Hardware or linear depth, decided as FSR-RR does: its HardwareDepth override, then a depth-stencil resource,
    // then the NGX declaration, then a game-written target as linear, otherwise hardware.
    bool hardwareDepth;
    const DepthKind kind = ClassifyDepth(static_cast<ID3D12Resource*>(frame.depth.resource));

    if (cfg.FfxDenoiserHardwareDepth.has_value())
        hardwareDepth = cfg.FfxDenoiserHardwareDepth.value();
    else if (kind == DepthKind::Hardware)
        hardwareDepth = true;
    else if (_hasNGXDepthType)
        hardwareDepth = _ngxHWDepth;
    else
        hardwareDepth = kind != DepthKind::GameWritten;

    if (static_cast<int>(hardwareDepth) != _loggedHWDepth)
    {
        _loggedHWDepth = hardwareDepth;
        LOG_INFO("OpenNR RR: depth is {} ({}), {}", hardwareDepth ? "hardware" : "linear",
                 _hasNGXDepthType ? (_ngxHWDepth ? "NGX says hardware" : "NGX says linear") : "NGX says nothing",
                 DepthInverted() ? "reversed Z" : "standard Z");
    }

    if (uint32_t reset = 0; params.Get(NVSDK_NGX_Parameter_Reset, &reset) == NVSDK_NGX_Result_Success && reset == 1)
        frame.flags |= ONR_RR_FRAME_RESET;
    if (hardwareDepth)
        frame.flags |= ONR_RR_FRAME_HW_DEPTH;
    if (DepthInverted())
        frame.flags |= ONR_RR_FRAME_DEPTH_INVERTED;
    if (JitteredMV())
        frame.flags |= ONR_RR_FRAME_MV_JITTERED;
    if (_roughnessPacked == 1)
        frame.flags |= ONR_RR_FRAME_ROUGHNESS_PACKED;

    return true;
}

bool OpenNrRrFeatureDx12::EvaluateInternal(ID3D12GraphicsCommandList* InCommandList, NVSDK_NGX_Parameter* InParameters)
{
    if (!IsInited() || _context == nullptr || _fellBack)
        return false;

    DropStaleJob();

    if (const int32_t rc = s_enqueueRc.exchange(ONR_RR_OK, std::memory_order_acq_rel); rc != ONR_RR_OK)
    {
        FallBack(std::format("Enqueue rc={}: {}", rc, LmxxfCut::LastEnqueueDiagnostic().error.data()));
        return false;
    }

    if (const uint32_t mode = ModeFromConfig(); mode != _mode)
    {
        const int32_t rc = s_api.SetMode(_context, mode);
        LOG_INFO("OpenNR RR: mode {} -> {} (rc {})", ModeName(_mode), ModeName(mode), rc);
        _mode = mode;
    }

    if (_frameCount % 30 == 0)
    {
        OnrRrInfo info {};
        info.size = sizeof(info);

        if (s_api.GetInfo(_context, &info) == ONR_RR_OK)
        {
            if (_frameCount % 300 == 0)
                LOG_INFO("OpenNR RR: {} ({}), {} network frames, GPU {:.2f} ms (avg {:.2f}), {}x{} -> {}x{}, mode {}",
                         StateName(info.state), info.message, info.frames, info.gpu_ms_last, info.gpu_ms_average,
                         info.render_width, info.render_height, info.output_width, info.output_height,
                         ModeName(info.mode));

            if (info.state == ONR_RR_STATE_FAILED)
            {
                FallBack(std::format("the runtime failed: {}", info.message));
                return false;
            }
        }
    }

    // The proxy under any layer that wraps the game's list (ReShade as dxgi.dll): the split and the between slot
    // know only that one.
    DlssNr::Submission::ILogicalCommandList* logical = nullptr;

    if (FAILED(InCommandList->QueryInterface(__uuidof(DlssNr::Submission::ILogicalCommandList),
                                             reinterpret_cast<void**>(&logical))) ||
        logical == nullptr)
    {
        FallBack("the game's command list is not one OptiScaler can split (the submission proxies are off)");
        return false;
    }

    ID3D12GraphicsCommandList* list = nullptr;
    logical->QueryInterface(IID_PPV_ARGS(&list));

    if (list != nullptr)
        list->Release(); // the game holds the list for this evaluate

    if (list == nullptr || logical->IsSplitIneligible())
    {
        FallBack(std::format("the command list cannot be split here ({})", logical->SplitRejectionReason()));
        logical->Release();
        return false;
    }

    OnrRrFrame frame {};

    if (!FillFrame(*InParameters, frame))
    {
        logical->Release();
        return false;
    }

    void* job = nullptr;

    if (const int32_t rc = s_api.RecordInputs(_context, &frame, list, &job); rc != ONR_RR_OK || job == nullptr)
    {
        FallBack(std::format("RecordInputs rc={}: {}", rc, RuntimeError()));
        logical->Release();
        return false;
    }

    if (const HRESULT hr = LmxxfCut::TrySplitAtEvaluate(list); FAILED(hr) || hr == S_FALSE)
    {
        s_api.Cancel(_context, job);
        FallBack(std::format("the split was refused (hr {:#x}, {})", (uint32_t) hr, logical->SplitRejectionReason()));
        logical->Release();
        return false;
    }

    logical->Release();

    if (const int32_t rc = s_api.RecordOutput(_context, job, list); rc != ONR_RR_OK)
    {
        s_api.Cancel(_context, job);
        FallBack(std::format("RecordOutput rc={}: {}", rc, RuntimeError()));
        return false;
    }

    LmxxfCut::SetPendingEnqueue(_context, job, &EnqueueThunk, s_api.GetLastError, list);
    LmxxfCut::ArmBetweenSlot();
    _job = job;
    _jobList = list;

    _hasColor = true;
    _hasDepth = true;
    _hasMV = true;
    _hasOutput = true;
    _frameCount++;
    return true;
}
