// SPDX-License-Identifier: MIT
// OpenNR RR runtime (OpenNrRrRuntime.dll): C interface for a host that intercepts a game's Ray Reconstruction
// (NGX DLSS-D) evaluate on D3D12. The network runs on a Vulkan device of its own on the game's adapter; the game's
// textures reach it through shared D3D12 buffers and a shared fence.
//
// Per frame, on the game's command list:
//   RecordInputs(ctx, frame, list, &job)   copies the guides into the shared buffers (the textures go to
//                                          COPY_SOURCE and back to the state given in the frame)
//   the host splits the list in two and, between the halves, on the queue that runs them, calls
//   Enqueue(ctx, job, queue)               signals the shared fence, submits the network on Vulkan behind it and
//                                          makes the queue wait for the network
//   RecordOutput(ctx, job, list)           on the second half: copies the result into frame.output
// Cancel(ctx, job) drops a job whose list will not run (reset or released unexecuted).
//
// Create returns at once; the weights and the kernels are built on a background thread. Until they are ready
// (and after a failure) frames still go through Enqueue/RecordOutput and the output is the colour, scaled
// bilinearly. GetInfo says which state the runtime is in and why.
#pragma once
#include <stdint.h>
#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ONR_RR_ABI_VERSION 1

enum OnrRrResult {
    ONR_RR_OK = 0,
    ONR_RR_INVALID_ARGUMENT = -1,
    ONR_RR_UNSUPPORTED = -2,   // GPU or nvngx_dlssd.dll not supported; GetLastError says why
    ONR_RR_FAILED = -3,
    ONR_RR_DEVICE_LOST = -4,
};

enum OnrRrMode {
    ONR_RR_MODE_FAST = 0,      // fp32 accumulation (kernels *_f), the default
    ONR_RR_MODE_FAITHFUL = 1,  // fp16 accumulation every 8 K as the reference GPU (k8 kernels)
};

enum OnrRrState {
    ONR_RR_STATE_BUILDING = 0, // weights / kernels being built: frames get the scaled colour
    ONR_RR_STATE_READY = 1,
    ONR_RR_STATE_FAILED = 2,   // frames get the scaled colour; message says why
};

enum OnrRrFrameFlags {
    ONR_RR_FRAME_RESET = 1u << 0,          // drop the history (camera cut)
    ONR_RR_FRAME_HW_DEPTH = 1u << 1,       // depth is the hardware (NDC) depth, not linear view depth
    ONR_RR_FRAME_DEPTH_INVERTED = 1u << 2, // with HW_DEPTH: reversed Z (near = 1)
    ONR_RR_FRAME_MV_JITTERED = 1u << 3,    // motion vectors include the jitter difference
    ONR_RR_FRAME_ROUGHNESS_PACKED = 1u << 4, // roughness is normals.w (roughness texture ignored)
    ONR_RR_FRAME_NORMALS_UNPACK = 1u << 5, // normals are stored as n * 0.5 + 0.5 (the runtime also assumes it for
                                           // UNORM formats)
};

// A texture of the frame: null resource = absent. state = the D3D12_RESOURCE_STATES it is in when the frame is
// recorded; it is left in that state. (x, y) = top-left of the subrect the frame uses.
typedef struct OnrRrTexture {
    void* resource;   // ID3D12Resource*
    uint32_t state;
    uint32_t x, y;
} OnrRrTexture;

typedef struct OnrRrCreateInfo {
    uint32_t size;                 // sizeof(OnrRrCreateInfo)
    uint32_t mode;                 // OnrRrMode
    void* d3d12_device;            // ID3D12Device* of the game
    uint32_t max_render_width, max_render_height;
    uint32_t output_width, output_height;
    const wchar_t* dlssd_path;     // nvngx_dlssd.dll the weights are built from (read only, never loaded)
    const wchar_t* cache_dir;      // built weights and pipeline cache; null: %LOCALAPPDATA%\OpenNR\rr
    const wchar_t* data_dir;       // folder holding shaders\; null: <runtime DLL folder>\opennr-rr
    const wchar_t* log_path;       // null: <runtime DLL folder>\opennr_rr.log
} OnrRrCreateInfo;

typedef struct OnrRrFrame {
    uint32_t size;                 // sizeof(OnrRrFrame)
    uint32_t flags;                // OnrRrFrameFlags
    uint32_t render_width, render_height;   // this frame's input extent (<= the create maximum)
    float jitter_x, jitter_y;      // render pixels, as NGX takes them
    float mv_scale_x, mv_scale_y;  // multiplies the motion vectors into render pixels
    float world_to_view[16];       // the NGX matrices as the game passes them (row-major, row vectors);
    float view_to_clip[16];        // all zero when the game gives none
    OnrRrTexture color;            // noisy radiance, render extent
    OnrRrTexture diffuse_albedo;
    OnrRrTexture specular_albedo;
    OnrRrTexture normals;          // world space; .w = roughness with ONR_RR_FRAME_ROUGHNESS_PACKED
    OnrRrTexture roughness;
    OnrRrTexture depth;
    OnrRrTexture motion;           // current -> previous
    OnrRrTexture specular_hit_distance;
    OnrRrTexture specular_ray_direction_hit_distance;   // .w used when specular_hit_distance is absent
    OnrRrTexture output;           // output extent, written by RecordOutput
} OnrRrFrame;

typedef struct OnrRrInfo {
    uint32_t size;                 // sizeof(OnrRrInfo)
    uint32_t state;                // OnrRrState
    uint32_t mode;                 // OnrRrMode in use
    uint32_t frames;               // frames the network ran
    float gpu_ms_last;             // network + post GPU time of the last measured frame (Vulkan timestamps)
    float gpu_ms_average;          // over the last 64 measured frames
    uint32_t render_width, render_height, output_width, output_height;
    char weights_source[260];      // UTF-8 path of the nvngx_dlssd.dll the weights came from
    char message[256];             // UTF-8: what it is doing or why it failed
} OnrRrInfo;

typedef struct OnrRrApi {
    uint32_t abi_version;
    // Without a context: whether this adapter (LUID) and nvngx_dlssd.dll can run the network; 0 = yes, otherwise
    // ONR_RR_UNSUPPORTED and the reason in GetLastError. dlssd_path may be null (only the GPU is checked).
    int32_t (*Check)(const void* adapter_luid, const wchar_t* dlssd_path);
    int32_t (*Create)(const OnrRrCreateInfo* info, void** context);
    int32_t (*Destroy)(void* context);
    int32_t (*SetMode)(void* context, uint32_t mode);   // applies when the kernels of that mode are built
    int32_t (*RecordInputs)(void* context, const OnrRrFrame* frame, void* command_list, void** job);
    int32_t (*Enqueue)(void* context, void* job, void* command_queue);
    int32_t (*RecordOutput)(void* context, void* job, void* command_list);
    int32_t (*Cancel)(void* context, void* job);
    int32_t (*GetInfo)(void* context, OnrRrInfo* info);
    int32_t (*GetLastError)(char* buffer, uint32_t chars);   // this thread's last error, UTF-8
} OnrRrApi;

typedef int32_t (*PFN_OnrRrGetApi)(uint32_t abi_version, OnrRrApi* api);
// exported by OpenNrRrRuntime.dll
#ifdef ONR_RR_BUILDING
__declspec(dllexport)
#endif
int32_t OnrRrGetApi(uint32_t abi_version, OnrRrApi* api);

#ifdef __cplusplus
}
#endif
