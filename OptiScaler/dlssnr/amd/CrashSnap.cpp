//向量异常处理器：仅当异常 PC (或 RA) 落在此模块内时才触发一次 FullMemory 微型转储，以便
//后续崩溃可以配合 OptiScaler.pdb 进行符号化。其余操作通过 EXCEPTION_CONTINUE_SEARCH 传递。
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dbghelp.h>
#include <Shlobj.h>
#include <psapi.h>
#include <cstdio>
#include <cstdint>

extern "C" IMAGE_DOS_HEADER __ImageBase;

namespace dlssnr
{
namespace crashsnap
{
static PVOID s_handle = nullptr;
static volatile long s_taken = 0;
static wchar_t s_dir[512] {};

static HMODULE ThisModule()
{
    return reinterpret_cast<HMODULE>(&__ImageBase);
}

static bool InThisModule(std::uintptr_t pc)
{
    HMODULE m = ThisModule();
    MODULEINFO mi {};
    if (!GetModuleInformation(GetCurrentProcess(), m, &mi, sizeof(mi)))
        return false;
    const auto base = reinterpret_cast<std::uintptr_t>(mi.lpBaseOfDll);
    return pc >= base && pc < base + mi.SizeOfImage;
}

static bool InAnyModule(std::uintptr_t address, HMODULE* module = nullptr)
{
    HMODULE m = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            reinterpret_cast<LPCWSTR>(address), &m))
        return false;
    if (module)
        *module = m;
    return true;
}

static bool ReadStack(std::uintptr_t address, std::uintptr_t& value)
{
    __try
    {
        value = *reinterpret_cast<const std::uintptr_t*>(address);
        return true;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return false;
    }
}

// A call through a null or stale pointer faults outside every module, so the dump alone names no code: the caller's
// return address is on top of the stack. Writes it, and the stack's other return-address candidates, as module+offset
// to %TEMP%\opti_crash_stack.txt.
static void WriteStackText(EXCEPTION_POINTERS* ptrs)
{
    wchar_t tmp[MAX_PATH] {}, path[MAX_PATH * 2] {};
    if (!GetTempPathW(MAX_PATH, tmp))
        return;
    _snwprintf_s(path, _TRUNCATE, L"%sopti_crash_stack.txt", tmp);
    FILE* f = nullptr;
    if (_wfopen_s(&f, path, L"w") != 0 || !f)
        return;
    const auto* record = ptrs->ExceptionRecord;
    fprintf(f, "code %08lx at %p\n", record ? record->ExceptionCode : 0, record ? record->ExceptionAddress : nullptr);
    const std::uintptr_t rsp = ptrs->ContextRecord ? ptrs->ContextRecord->Rsp : 0;
    for (int i = 0, found = 0; rsp && i < 512 && found < 24; ++i)
    {
        std::uintptr_t value = 0;
        if (!ReadStack(rsp + i * sizeof(std::uintptr_t), value))
            break;
        HMODULE m = nullptr;
        if (!InAnyModule(value, &m))
            continue;
        wchar_t name[MAX_PATH] {};
        GetModuleFileNameW(m, name, MAX_PATH);
        const wchar_t* file = wcsrchr(name, L'\\');
        fprintf(f, "[rsp+%03x] %ls+0x%llx\n", i * 8, file ? file + 1 : name,
                static_cast<unsigned long long>(value - reinterpret_cast<std::uintptr_t>(m)));
        ++found;
    }
    fclose(f);
}

static void WriteDump(EXCEPTION_POINTERS* ptrs)
{
    // Dumps 旁边的游戏（bin\x64）或者，当名称已知时，则写入 fork 的 dumps 文件夹。
    wchar_t path[MAX_PATH * 2] {};

    // 1) 优先选择 %TEMP%\opencode\（先前创建好了临时目录）。
    wchar_t tmp[MAX_PATH] {};
    if (GetTempPathW(MAX_PATH, tmp))
    {
        _snwprintf_s(path, _TRUNCATE, L"%scp2077_opti_crash.dmp", tmp);
    }
    if (auto fh = ::CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr); fh != INVALID_HANDLE_VALUE)
    {
        MINIDUMP_EXCEPTION_INFORMATION mei {};
        mei.ThreadId = ::GetCurrentThreadId();
        mei.ExceptionPointers = const_cast<EXCEPTION_POINTERS*>(ptrs);
        mei.ClientPointers = FALSE;
        MINIDUMP_TYPE type = static_cast<MINIDUMP_TYPE>(MiniDumpNormal | MiniDumpWithUnloadedModules);
        ::MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), fh, type, &mei, nullptr, nullptr);
        ::CloseHandle(fh);
    }
}

static LONG WINAPI OnException(EXCEPTION_POINTERS* ptrs)
{
    DWORD code = ptrs->ExceptionRecord ? ptrs->ExceptionRecord->ExceptionCode : 0;
    // 这些是真正的崩溃/abort，而非 SEH 的控制流量辅助（如 C++ EH 等）。
    if (code != 0xC0000005 && code != 0xC0000409 && code != 0xC0000417 && code != 0x80000003)
        return EXCEPTION_CONTINUE_SEARCH;
    std::uintptr_t pc = ptrs->ExceptionRecord
                            ? reinterpret_cast<std::uintptr_t>(ptrs->ExceptionRecord->ExceptionAddress)
                            : 0;
    // Faults in this module, and calls through a null or stale pointer (the PC in no module at all).
    const bool strayCall = code == 0xC0000005 && !InAnyModule(pc);
    if (!strayCall && (!pc || !InThisModule(pc)))
        return EXCEPTION_CONTINUE_SEARCH;
    if (_InterlockedCompareExchange(&s_taken, 1, 0) != 0)
        return EXCEPTION_CONTINUE_SEARCH;
    WriteStackText(ptrs);
    WriteDump(ptrs);
    return EXCEPTION_CONTINUE_SEARCH;
}

static void LoadDumpDir()
{
    wchar_t tmp[MAX_PATH] {};
    ::GetTempPathW(MAX_PATH, tmp);
    _snwprintf_s(s_dir, _TRUNCATE, L"%s", tmp);
}

void EnableCrashSnap()
{
    if (s_handle)
        return;
    LoadDumpDir();
    s_handle = ::AddVectoredExceptionHandler(1, (PVECTORED_EXCEPTION_HANDLER) OnException);
}
} // namespace crashsnap
} // namespace dlssnr
