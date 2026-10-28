@echo off
rem Build MochizukiNrRuntime.dll and its dlssnr-amd\shaders from third_party\mochizuki.
rem Run from an MSVC developer prompt. Needs the Vulkan SDK 1.4.357 or newer (VULKAN_SDK) and Python;
rem glslang 16.5.0, the version the upstream shaders are pinned to, is downloaded on first use.
setlocal
cd /d "%~dp0.."
set "OUT=%~1"
if not defined OUT set "OUT=exports\mochizuki-runtime"
set "UP=third_party\mochizuki"
set "OBJ=%OUT%\obj"
if not exist "%OBJ%" mkdir "%OBJ%"

where cl.exe >nul 2>&1
if errorlevel 1 (
  echo FAIL: cl.exe not found; run from an MSVC developer prompt
  exit /b 1
)
if not defined VULKAN_SDK (
  echo FAIL: VULKAN_SDK is not set; install the Vulkan SDK 1.4.357 or newer
  exit /b 1
)

rem The network's constants, from %UP%\windows\build\arch\rdna4.sh. The shaders are built with the same ones.
rem %UP%\linux\build\arch\rdna3.sh has the same ones and NR_ARCH_RDNA3=1, which this DLL decides at run time instead
rem (RuntimeConfig::rdna3), so one DLL runs either network.
set "NR_DEFINES=/DNR_GEMM_WIDE_MT=64 /DNR_GEMM_WIDE_NT=256 /DNR_GEMM_PROJ_MT=32 /DNR_GEMM_PROJ_NT=128 /DNR_PROJW_MIN_TOKENS=768 /DNR_GEMM_REMAP_HOST=1 /DNR_FFWD_WGW=4 /DNR_FFWD_GMAJOR=1 /DNR_UPSVIEW_VEC=1 /DNR_REPACK_VEC=1 /DNR_WIDE_UPS_MASK=7 /DNR_PERSIST_DF=1 /DNR_DS_FUSE=15 /DNR_DECUPS_VEC=16 /DNR_DECQ_SMALL=1 /DNR_PERSIST_DS_MASK=7 /DNR_PERSIST_UPS_MASK=7 /DNR_REPACK_FOLD=1 /DNR_STRAG_PCT=25 /DNR_PERSIST_ONE_MASK=6 /DNR_NOISE_FIELD=1 /DNR_FFWD_FM2_MIN_TOKENS=2560 /DNR_POST_ALPHA=1 /DNR_TCHAIN_TILES=1"
set "CFLAGS=/nologo /std:c++20 /O2 /EHsc /MT /utf-8 /bigobj /W3 /wd4244 /wd4267 /wd4305 /wd4018 /DNOMINMAX /D_CRT_SECURE_NO_WARNINGS /DNDEBUG /DNR_INT4=1"
set "INCLUDES=/I "%VULKAN_SDK%\Include" /I "%UP%\windows\src\core" /I "OptiScaler\dlssnr\backend\mochizuki_runtime\compat" /I "OptiScaler\dlssnr\backend\lmxxf_runtime""

rem The core's pipeline creation goes through mz_interpose.cpp (the parallel prewarm and its manifest): these six
rem entry points are renamed for nr_runtime.cpp alone, which calls them directly, never through vkGetDeviceProcAddr.
set "MZI=/DvkCreateComputePipelines=mzi_vkCreateComputePipelines /DvkCreateShaderModule=mzi_vkCreateShaderModule /DvkCreateDescriptorSetLayout=mzi_vkCreateDescriptorSetLayout /DvkCreatePipelineLayout=mzi_vkCreatePipelineLayout /DvkCreatePipelineCache=mzi_vkCreatePipelineCache /DvkDestroyPipelineCache=mzi_vkDestroyPipelineCache"

set "GLSLANG=%UP%\toolchain\glslang"
if not exist "%GLSLANG%\bin\glslang.exe" (
  if not exist "%UP%\toolchain" mkdir "%UP%\toolchain"
  python -c "import hashlib,io,urllib.request,zipfile; b=urllib.request.urlopen('https://github.com/KhronosGroup/glslang/releases/download/16.5.0/glslang-16.5.0-windows-x86_64-release.zip').read(); assert hashlib.sha256(b).hexdigest()=='06b71298b750268c127f2ee7ae0ef7525e2068120c6c8a3a08b2f58ca6f325ce', 'glslang checksum mismatch'; zipfile.ZipFile(io.BytesIO(b)).extractall(r'%GLSLANG%')" || goto fail
)
rem The RDNA3 network's layout probes (mz_rdna3.cpp), embedded as SPIR-V arrays.
set "PROBE=OptiScaler\dlssnr\backend\mochizuki_runtime\rdna3_probe"
if not exist "%OBJ%\rdna3_probe" mkdir "%OBJ%\rdna3_probe"
for %%s in (acc32 acc16 fraga fragb halves kswap) do "%GLSLANG%\bin\glslang.exe" --target-env vulkan1.3 --vn mzr3_probe_%%s -o "%OBJ%\rdna3_probe\%%s.h" "%PROBE%\%%s.comp" >nul || goto fail
rem MZ_STAGE_DUMP's statistics shader (a diagnostic, nr_runtime.cpp StageDump), embedded as a SPIR-V array.
"%GLSLANG%\bin\glslang.exe" --target-env vulkan1.3 --vn mz_stage_stats -o "%OBJ%\stage_stats.h" "%UP%\windows\src\core\stage_stats.comp" >nul || goto fail
rem MZ_SEQ's and NR_RDNA3_SYNC=zero's scrub (nr_runtime.cpp, local patch 21), embedded likewise.
"%GLSLANG%\bin\glslang.exe" --target-env vulkan1.3 --vn mz_seq_scrub -o "%OBJ%\seq_scrub.h" "%UP%\windows\src\core\seq_scrub.comp" >nul || goto fail
cl %CFLAGS% %NR_DEFINES% %MZI% %INCLUDES% /I "%OBJ%" /c "%UP%\windows\src\core\nr_runtime.cpp" /Fo"%OBJ%\nr_runtime.obj" || goto fail
cl %CFLAGS% %INCLUDES% /c "%UP%\windows\src\core\nr_native_plan.cpp" /Fo"%OBJ%\nr_native_plan.obj" || goto fail
rem Upstream's RenoDX stage, which the network always runs in: RenoDX's encode and composition around it.
cl %CFLAGS% %INCLUDES% /c "%UP%\windows\src\core\nr_renodx.cpp" /Fo"%OBJ%\nr_renodx.obj" || goto fail
cl %CFLAGS% %INCLUDES% /c "OptiScaler\dlssnr\backend\mochizuki_runtime\mz_interpose.cpp" /Fo"%OBJ%\mz_interpose.obj" || goto fail
cl %CFLAGS% %INCLUDES% /DLMXXF_NR_RUNTIME_EXPORTS /c "OptiScaler\dlssnr\backend\mochizuki_runtime\MochizukiNrRuntime.cpp" /Fo"%OBJ%\MochizukiNrRuntime.obj" || goto fail
cl %CFLAGS% %INCLUDES% /I "%OBJ%\rdna3_probe" /c "OptiScaler\dlssnr\backend\mochizuki_runtime\mz_rdna3.cpp" /Fo"%OBJ%\mz_rdna3.obj" || goto fail
link /nologo /DLL /OUT:"%OUT%\MochizukiNrRuntime.dll" "%OBJ%\MochizukiNrRuntime.obj" "%OBJ%\mz_interpose.obj" "%OBJ%\mz_rdna3.obj" "%OBJ%\nr_runtime.obj" "%OBJ%\nr_native_plan.obj" "%OBJ%\nr_renodx.obj" "%VULKAN_SDK%\Lib\vulkan-1.lib" d3d12.lib shell32.lib || goto fail

python "%UP%\windows\build\build_network.py" rdna4 --out "%OUT%\dlssnr-amd\shaders" || goto fail
rem The RDNA3 network (RX 7000, no FP8) in shaders-rdna3\: mauri870/DLSSNR-RDNA3's linux\shaders\rdna3, unrolled for
rem LLPC as the Windows network is (it crashes on their rolled loops), without the four-wide quantisation.
python "%UP%\windows\build\build_network.py" rdna3 --tree linux --no-quad --out "%OUT%\dlssnr-amd\shaders-rdna3" || goto fail
rem The RenoDX stage's shaders in shaders\renodx\ (Slang 2026.19 is downloaded into toolchain\ on first use).
python tools\build-mochizuki-renodx.py "%UP%" "%OUT%\dlssnr-amd\shaders\renodx" "%OBJ%\renodx" "%GLSLANG%\bin\glslang.exe" || goto fail
rem ACO's network (LMXXF_NR_CREATE_FLAG_ACO): the Linux network's SPIR-V, which ACO's records were made from (each
rem record is named by the hash of its SPIR-V, so these must build byte for byte as upstream's), and the records.
python "%UP%\linux\build\build_network.py" rdna4 --out "%OUT%\dlssnr-amd\aco\shaders" || goto fail
if not exist "%OUT%\dlssnr-amd\aco\records" mkdir "%OUT%\dlssnr-amd\aco\records"
copy /y "%UP%\windows\data\aco\records\*.nrp" "%OUT%\dlssnr-amd\aco\records\" >nul || goto fail
copy /y "%UP%\windows\data\aco\shell-aliases.txt" "%OUT%\dlssnr-amd\aco\" >nul || goto fail

rem int4 mixed (LMXXF_NR_FRAME_FLAG_INT4), which runs as ACO's machine code only: the Linux int4 network and its
rem records in aco\int4\, its aliases merged into aco\shell-aliases.txt (read once, at the ACO setup), and in int4\
rem the same SPIR-V with the quantisation tables and settings.
python "%UP%\linux\build\build_network.py" rdna4 --int4 --out "%OUT%\dlssnr-amd\aco\int4\shaders" || goto fail
if not exist "%OUT%\dlssnr-amd\aco\int4\records" mkdir "%OUT%\dlssnr-amd\aco\int4\records"
copy /y "%UP%\windows\data\aco\int4\records\*.nrp" "%OUT%\dlssnr-amd\aco\int4\records\" >nul || goto fail
copy /y "%UP%\windows\data\aco\int4\shell-aliases.txt" "%OUT%\dlssnr-amd\aco\int4\" >nul || goto fail
python -c "import sys,pathlib;a={};[a.setdefault(n,s)==s or sys.exit('conflicting ACO alias '+n) for f in sys.argv[1:] for n,s in (l.split() for l in pathlib.Path(f).read_text().splitlines() if l.strip())];pathlib.Path(sys.argv[1]).write_text(''.join(k+' '+v+chr(10) for k,v in sorted(a.items())))" "%OUT%\dlssnr-amd\aco\shell-aliases.txt" "%OUT%\dlssnr-amd\aco\int4\shell-aliases.txt" || goto fail
if exist "%OUT%\dlssnr-amd\int4" rmdir /s /q "%OUT%\dlssnr-amd\int4"
xcopy /e /i /q /y "%UP%\linux\data\int4\rdna4\vit" "%OUT%\dlssnr-amd\int4\vit" >nul || goto fail
xcopy /e /i /q /y "%UP%\linux\data\int4\rdna4\swin" "%OUT%\dlssnr-amd\int4\swin" >nul || goto fail
copy /y "%UP%\linux\data\int4\rdna4\settings.txt" "%OUT%\dlssnr-amd\int4\" >nul || goto fail
xcopy /e /i /q /y "%OUT%\dlssnr-amd\aco\int4\shaders" "%OUT%\dlssnr-amd\int4\shaders" >nul || goto fail

rem The int4 weights are made from the model (never in this tree): dlssnr-int4-weights.exe runs the graph builder's
rem own decoder on dlssnr.bin and the tables above. With MZ_MODEL set to a dlssnr.bin, this writes
rem dlssnr-amd\dlssnr-int4.bin and checks it against upstream's hash.
cl %CFLAGS% %NR_DEFINES% %INCLUDES% /c "%UP%\windows\src\tools\nr_int4_weights.cpp" /Fo"%OBJ%\nr_int4_weights.obj" || goto fail
link /nologo /OUT:"%OBJ%\dlssnr-int4-weights.exe" "%OBJ%\nr_int4_weights.obj" "%OBJ%\nr_native_plan.obj" "%VULKAN_SDK%\Lib\vulkan-1.lib" || goto fail
if defined MZ_MODEL (
  "%OBJ%\dlssnr-int4-weights.exe" "%MZ_MODEL%" "%OUT%\dlssnr-amd\int4" "%OUT%\dlssnr-amd\dlssnr-int4.bin" || goto fail
  python -c "import hashlib,sys;h=hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest();w=open(sys.argv[2]).read().split()[0];sys.exit(0 if h==w else 'dlssnr-int4.bin is '+h+', upstream '+w)" "%OUT%\dlssnr-amd\dlssnr-int4.bin" "%UP%\linux\data\int4\rdna4\dlssnr-int4.sha256" || goto fail
)

echo BUILD_OK %OUT%\MochizukiNrRuntime.dll
exit /b 0

:fail
echo FAIL: MochizukiNrRuntime build failed
exit /b 1
