#pragma once

// Logging for the checks a game makes before it offers DLSS ([Spoofing] GateDiagnostics=true)

#include <Config.h>
#include <Util.h>

#include <format>
#include <intrin.h>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

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

inline bool SafeWrite(void* target, const void* source, size_t size)
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

// Image sections of the exe that hold data, read-only or writable, as [start, end)
inline std::vector<std::pair<uint8_t*, uint8_t*>> ExeSections(bool writable)
{
    std::vector<std::pair<uint8_t*, uint8_t*>> sections;
    auto base = (uint8_t*) GetModuleHandleW(nullptr);
    auto dos = (IMAGE_DOS_HEADER*) base;
    auto nt = (IMAGE_NT_HEADERS*) (base + dos->e_lfanew);
    auto section = IMAGE_FIRST_SECTION(nt);

    for (WORD i = 0; i < nt->FileHeader.NumberOfSections; i++, section++)
    {
        const auto flags = section->Characteristics;
        if (flags & IMAGE_SCN_MEM_EXECUTE)
            continue;
        if (((flags & IMAGE_SCN_MEM_WRITE) != 0) != writable)
            continue;

        auto start = base + section->VirtualAddress;
        sections.push_back({ start, start + section->Misc.VirtualSize });
    }

    return sections;
}

// The name as a whole string (zero on both sides) in [start, end)
inline const char* FindNameUnsafe(const uint8_t* start, const uint8_t* end, const char* name, size_t length)
{
    for (auto p = start + 1; p + length < end; p++)
    {
        p = (const uint8_t*) memchr(p, name[0], end - length - p);
        if (p == nullptr)
            return nullptr;
        if (p[-1] == 0 && p[length] == 0 && memcmp(p, name, length) == 0)
            return (const char*) p;
    }

    return nullptr;
}

inline const char* FindName(const uint8_t* start, const uint8_t* end, const char* name, size_t length)
{
    __try
    {
        return FindNameUnsafe(start, end, name, length);
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return nullptr;
    }
}

// 8-aligned slots in [start, end) that hold value, at most max of them
inline size_t FindPointer(const uint8_t* start, const uint8_t* end, uint64_t value, uint8_t** hits, size_t max)
{
    size_t found = 0;
    __try
    {
        auto p = (const uint64_t*) (((uintptr_t) start + 7) & ~(uintptr_t) 7);
        for (; (const uint8_t*) (p + 1) <= end && found < max; p++)
        {
            if (*p == value)
                hits[found++] = (uint8_t*) p;
        }
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
    }

    return found;
}

inline bool ReadString(uint64_t address, char* buffer, size_t size)
{
    memset(buffer, 0, size);
    return address != 0 && SafeRead((const void*) address, buffer, size - 1);
}

inline bool IsWritable(const void* address)
{
    MEMORY_BASIC_INFORMATION info {};
    if (VirtualQuery(address, &info, sizeof(info)) == 0 || info.State != MEM_COMMIT)
        return false;

    return (info.Protect & (PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) != 0;
}

// list: exe names split by , ; or |
inline bool ExeListed(const std::string& list)
{
    char path[MAX_PATH] {};
    GetModuleFileNameA(nullptr, path, MAX_PATH);
    const char* exe = strrchr(path, 0x5C);
    exe = exe != nullptr ? exe + 1 : path;

    std::string name;
    for (char ch : list + ",")
    {
        if (ch == ',' || ch == ';' || ch == '|')
        {
            while (!name.empty() && name.back() == ' ')
                name.pop_back();
            if (!name.empty() && _stricmp(name.c_str(), exe) == 0)
                return true;
            name.clear();
        }
        else if (ch != ' ' || !name.empty())
        {
            name += ch;
        }
    }

    return false;
}

// id Tech cvar: the object's first qword points at its data (the object's own copy at +8 until the cvar system
// takes it over); the data holds the value string at +0, the int at +8, the float at +0xC and the name at +0x28
struct IdCvar
{
    uint8_t* object = nullptr;
};

// Cvar objects named name: a pointer to the name's string in a writable section 0x30 into the object, whose
// data names it as well and holds a number as its value string
inline std::vector<IdCvar> FindIdCvar(const char* name, std::string& why)
{
    std::vector<IdCvar> cvars;
    const size_t length = strlen(name);

    const char* text = nullptr;
    for (const auto& [start, end] : ExeSections(false))
    {
        if ((text = FindName(start, end, name, length)) != nullptr)
            break;
    }

    if (text == nullptr)
    {
        why = "name not in the exe";
        return cvars;
    }

    for (const auto& [start, end] : ExeSections(true))
    {
        uint8_t* hits[16] {};
        const auto count = FindPointer(start, end, (uint64_t) text, hits, 16);

        for (size_t i = 0; i < count; i++)
        {
            auto object = hits[i] - 0x30;
            uint64_t data = 0;
            if (object < start || !SafeRead(object, &data, 8) || data == 0)
                continue;

            uint64_t namePointer = 0;
            uint64_t valuePointer = 0;
            int32_t value = -1;
            float floatValue = -1.0f;
            char dataName[64] {};
            char valueText[16] {};
            if (!SafeRead((const void*) (data + 0x28), &namePointer, 8) ||
                !ReadString(namePointer, dataName, sizeof(dataName)) || strcmp(dataName, name) != 0)
                continue;
            if (!SafeRead((const void*) data, &valuePointer, 8) ||
                !ReadString(valuePointer, valueText, sizeof(valueText)) ||
                !SafeRead((const void*) (data + 8), &value, 4) || !SafeRead((const void*) (data + 0xC), &floatValue, 4))
                continue;
            // Before the cvar system parses it the int and float are still 0 next to the default string
            char* parsedEnd = nullptr;
            const long parsed = strtol(valueText, &parsedEnd, 10);
            if (valueText[0] == 0 || (*parsedEnd != 0 && *parsedEnd != '.') || (value != 0 && value != parsed) ||
                (floatValue != 0.0f && (int32_t) floatValue != value))
                continue;

            cvars.push_back({ object });
        }
    }

    if (cvars.empty())
        why = std::format("name at exe+0x{:X}, no cvar object with the expected layout",
                          (uintptr_t) text - (uintptr_t) GetModuleHandleW(nullptr));

    return cvars;
}

// [Spoofing] DoomStreamlineAnyVendor: id Tech 8 drops Streamline on a non-NVIDIA driverID while
// r_streamlineRestrictVendors is 1, and the command line and config set it too late. The cvar is looked up by
// name at run time and set to 0 before the vendor check; nothing is written unless its layout checks out.
inline void DoomStreamlineAnyVendor()
{
    auto* config = Config::Instance();
    if (!config->DoomStreamlineAnyVendor.value_or_default() ||
        !ExeListed(config->StreamlineAnyVendorExes.value_or_default()))
        return;

    static std::mutex mutex;
    static bool searched = false;
    static std::vector<IdCvar> cvars;

    std::scoped_lock lock(mutex);

    if (!searched)
    {
        searched = true;
        std::string why;
        cvars = FindIdCvar("r_streamlineRestrictVendors", why);

        if (cvars.empty())
            LOG_WARN("DoomStreamlineAnyVendor: r_streamlineRestrictVendors not found ({}), nothing changed", why);
        else
            LOG_INFO("DoomStreamlineAnyVendor: r_streamlineRestrictVendors found, {} object(s), first at exe+0x{:X}",
                     cvars.size(), (uintptr_t) cvars[0].object - (uintptr_t) GetModuleHandleW(nullptr));
    }

    for (const auto& cvar : cvars)
    {
        // Read the data pointer again, the cvar system may have moved it since the search
        uint64_t data = 0;
        int32_t value = 0;
        if (!SafeRead(cvar.object, &data, 8) || data == 0 || !SafeRead((const void*) (data + 8), &value, 4) ||
            value == 0)
            continue;

        if (value != 1)
        {
            static bool warned = false;
            if (!warned)
                LOG_WARN("DoomStreamlineAnyVendor: r_streamlineRestrictVendors reads {}, left alone", value);
            warned = true;
            continue;
        }

        const int32_t zero = 0;
        const float zeroFloat = 0.0f;
        const bool written =
            SafeWrite((void*) (data + 8), &zero, 4) && SafeWrite((void*) (data + 0xC), &zeroFloat, 4);

        // The value string too, when it's the engine's own writable "1"
        uint64_t valuePointer = 0;
        char valueText[4] {};
        if (written && SafeRead((const void*) data, &valuePointer, 8) &&
            ReadString(valuePointer, valueText, sizeof(valueText)) && strcmp(valueText, "1") == 0 &&
            IsWritable((const void*) valuePointer))
        {
            const char zeroText = '0';
            SafeWrite((void*) valuePointer, &zeroText, 1);
        }

        LOG_INFO("DoomStreamlineAnyVendor: r_streamlineRestrictVendors 1 -> 0 {}", written ? "written" : "failed");
    }
}

// The cvar's int value; false when its data can't be read
inline bool ReadIdCvar(const IdCvar& cvar, int32_t& value)
{
    uint64_t data = 0;
    return SafeRead(cvar.object, &data, 8) && data != 0 && SafeRead((const void*) (data + 8), &value, 4);
}

// What the engine's own setter leaves behind for a single-digit value: int, float, the value string when it's
// a writable single digit, and the modified flag (0x80000 in the flags at +0x40)
inline bool WriteIdCvarDigit(const IdCvar& cvar, int32_t value)
{
    uint64_t data = 0;
    if (value < 0 || value > 9 || !SafeRead(cvar.object, &data, 8) || data == 0)
        return false;

    const float floatValue = (float) value;
    if (!SafeWrite((void*) (data + 8), &value, 4) || !SafeWrite((void*) (data + 0xC), &floatValue, 4))
        return false;

    uint64_t valuePointer = 0;
    char valueText[4] {};
    if (SafeRead((const void*) data, &valuePointer, 8) && ReadString(valuePointer, valueText, sizeof(valueText)) &&
        valueText[0] >= '0' && valueText[0] <= '9' && valueText[1] == 0 && IsWritable((const void*) valuePointer))
    {
        const char digit = (char) ('0' + value);
        SafeWrite((void*) valuePointer, &digit, 1);
    }

    uint32_t flags = 0;
    if (SafeRead((const void*) (data + 0x40), &flags, 4))
    {
        flags |= 0x80000;
        SafeWrite((void*) (data + 0x40), &flags, 4);
    }

    return true;
}

// [Spoofing] DoomKeepDlssRR: the video menu has no DLSS entry on AMD, so keep r_antialiasing on DLSS (2) when the
// game puts it on off/TAA, and with path tracing on keep its denoiser on DLSS-RR (2). FSR (3) and XeSS (4) picked
// in the menu are left alone. Checked at every present, written only when the game changed the value.
inline void DoomKeepDlssRR()
{
    auto* config = Config::Instance();
    if (!config->DoomKeepDlssRR.value_or_default() ||
        !ExeListed(config->StreamlineAnyVendorExes.value_or_default()))
        return;

    static std::mutex mutex;
    static bool searched = false;
    static bool usable = false;
    static IdCvar antialiasing;
    static IdCvar pathtracing;
    static IdCvar denoiser;
    static int overrides = 0;

    std::scoped_lock lock(mutex);

    if (!searched)
    {
        searched = true;
        std::string why;
        std::string missing;
        const auto find = [&](const char* name, IdCvar& out)
        {
            auto found = FindIdCvar(name, why);
            if (found.empty())
                missing += std::format(" {} ({})", name, why);
            else
                out = found[0];
        };

        find("r_antialiasing", antialiasing);
        find("r_pathtracingEnabled", pathtracing);
        find("r_pathtracingDenoiserMode", denoiser);

        usable = antialiasing.object != nullptr;
        if (!missing.empty())
            LOG_WARN("DoomKeepDlssRR: not found:{}{}", missing, usable ? "" : ", nothing changed");
        else
            LOG_INFO("DoomKeepDlssRR: r_antialiasing, r_pathtracingEnabled and r_pathtracingDenoiserMode found");
    }

    if (!usable)
        return;

    const auto log = [&](const char* name, int32_t from, int32_t to)
    {
        if (++overrides <= 50)
            LOG_INFO("DoomKeepDlssRR: {} {} -> {}{}", name, from, to, overrides == 50 ? " (no more of these lines)" : "");
    };

    int32_t value = 0;
    if (!ReadIdCvar(antialiasing, value))
        return;

    if ((value == 0 || value == 1) && WriteIdCvarDigit(antialiasing, 2))
    {
        log("r_antialiasing", value, 2);
        value = 2;
    }

    int32_t pathtracingOn = 0;
    int32_t denoiserMode = 0;
    if (value == 2 && pathtracing.object != nullptr && denoiser.object != nullptr &&
        ReadIdCvar(pathtracing, pathtracingOn) && pathtracingOn == 1 && ReadIdCvar(denoiser, denoiserMode) &&
        denoiserMode != 2 && WriteIdCvarDigit(denoiser, 2))
        log("r_pathtracingDenoiserMode", denoiserMode, 2);
}

// GateDiagnostics: logs when one of these id Tech cvars changes, checked at every present
inline void WatchCvars()
{
    if (!On() || !ExeListed(Config::Instance()->StreamlineAnyVendorExes.value_or_default()))
        return;

    struct Watched
    {
        const char* name;
        std::vector<IdCvar> cvars;
        int32_t last = INT32_MIN;
    };

    static std::mutex mutex;
    static bool searched = false;
    static Watched watched[] = { { "r_antialiasing" },
                                 { "r_dlssQuality" },
                                 { "r_pathtracingEnabled" },
                                 { "r_pathtracingDenoiserMode" },
                                 { "r_streamlineDLSS" },
                                 { "r_streamlineRestrictVendors" } };

    std::scoped_lock lock(mutex);

    if (!searched)
    {
        searched = true;
        for (auto& entry : watched)
        {
            std::string why;
            entry.cvars = FindIdCvar(entry.name, why);
            if (entry.cvars.empty())
                LOG_INFO("GateDiag cvar {} not found ({})", entry.name, why);
        }
    }

    for (auto& entry : watched)
    {
        if (entry.cvars.empty())
            continue;

        uint64_t data = 0;
        int32_t value = 0;
        if (!SafeRead(entry.cvars[0].object, &data, 8) || data == 0 || !SafeRead((const void*) (data + 8), &value, 4))
            continue;

        if (value != entry.last)
        {
            LOG_INFO("GateDiag cvar {}: {} -> {}", entry.name, entry.last == INT32_MIN ? std::string("?") :
                     std::to_string(entry.last), value);
            entry.last = value;
        }
    }
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
