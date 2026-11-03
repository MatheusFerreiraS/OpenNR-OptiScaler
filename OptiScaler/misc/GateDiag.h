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
} // namespace GateDiag
