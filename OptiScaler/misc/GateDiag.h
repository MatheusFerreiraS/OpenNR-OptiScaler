#pragma once

// Logging for the checks a game makes before it offers DLSS ([Spoofing] GateDiagnostics=true)

#include <Config.h>
#include <Util.h>

#include <format>
#include <intrin.h>
#include <mutex>
#include <string>
#include <unordered_set>

namespace GateDiag
{
inline bool On() { return Config::Instance()->GateDiagnostics.value_or_default(); }

inline bool FromGame(void* returnAddress)
{
    return Util::GetCallerModule(returnAddress) == GetModuleHandleW(nullptr);
}

// "module.dll+0x1234"
inline std::string Caller(void* returnAddress)
{
    auto module = Util::GetCallerModule(returnAddress);
    if (module == nullptr)
        return std::format("{}", returnAddress);

    char path[MAX_PATH] {};
    GetModuleFileNameA(module, path, MAX_PATH);
    const char* name = strrchr(path, '\\');
    return std::format("{}+0x{:X}", name != nullptr ? name + 1 : path,
                       (uintptr_t) returnAddress - (uintptr_t) module);
}

// Per-frame calls log once per distinct key
inline bool First(const std::string& key)
{
    static std::mutex mutex;
    static std::unordered_set<std::string> seen;

    std::scoped_lock lock(mutex);
    return seen.size() < 5000 && seen.insert(key).second;
}

inline bool SafeRead(const void* source, void* target, size_t size)
{
    __try
    {
        memcpy(target, source, size);
        return true;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return false;
    }
}

// DOOM: The Dark Ages (this exe build only, checked by a cvar name at a known RVA): the engine's Streamline
// flag, its vendor enum (1 NVIDIA, 2 AMD), r_streamlineRestrictVendors and the SL extension lists it checks
inline std::string DoomState()
{
    auto exe = (const uint8_t*) GetModuleHandleW(nullptr);

    char name[28] {};
    if (!SafeRead(exe + 0x3422DB0, name, 27) || strcmp(name, "r_streamlineRestrictVendors") != 0)
        return {};

    uint8_t streamline = 0;
    int32_t vendor = 0;
    uint64_t cvarData = 0;
    int32_t restrictVendors = -1;
    SafeRead(exe + 0x4940EAC, &streamline, 1);
    SafeRead(exe + 0x49412E0, &vendor, 4);
    if (SafeRead(exe + 0x98A0EA0, &cvarData, 8) && cvarData != 0)
        SafeRead((const void*) (cvarData + 8), &restrictVendors, 4);

    // idList<idStr>: data pointer, count; each idStr starts with its char pointer, 0x30 apart
    const auto list = [&](uintptr_t rva)
    {
        uint64_t data = 0;
        int32_t count = 0;
        SafeRead(exe + rva, &data, 8);
        SafeRead(exe + rva + 8, &count, 4);

        auto out = std::format("{}:", count);
        for (int32_t i = 0; i < count && i < 32 && data != 0; i++)
        {
            uint64_t text = 0;
            char buffer[64] {};
            if (SafeRead((const void*) (data + i * 0x30), &text, 8) && text != 0)
                SafeRead((const void*) text, buffer, sizeof(buffer) - 1);
            out += std::format(" {}", buffer);
        }
        return out;
    };

    return std::format("streamline {} vendor {} r_streamlineRestrictVendors {} SL device ext [{}] SL instance ext [{}]",
                       streamline, vendor, restrictVendors, list(0x495EAB8), list(0x495EAA0));
}

inline void LogDoomState(const char* where)
{
    if (!On())
        return;

    auto state = DoomState();
    if (!state.empty() && First(std::format("doom|{}|{}", where, state)))
        LOG_INFO("GateDiag DOOM at {}: {}", where, state);
}
} // namespace GateDiag
