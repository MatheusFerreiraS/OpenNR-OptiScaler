# build-kit.ps1 <runtime dir> <emulated dir> <reference dir> <kit dir>
# Lays the kit out in <kit dir>\OpenNR-RX6000-test: the runtime (<runtime dir>: MochizukiNrRuntime.dll and
# dlssnr-amd\shaders-rdna2 + shaders\renodx, as tools\build-mochizuki-runtime.cmd exports them), the emulated kernels
# of the pipelines the small model dispatches at 720p (<emulated dir>: build_network.py rdna2 --tree linux --no-quad
# with NR_NATIVE taken out of rdna2\pipelines.json; only the files that differ from the native set), the references
# (make-refs.ps1) and the tools (build-tools.cmd).
param([string]$runtime, [string]$emulated, [string]$reference, [string]$kitRoot)
$ErrorActionPreference = 'Stop'
$kit = Join-Path $kitRoot 'OpenNR-RX6000-test'
$f = Join-Path $kit 'files'
if (Test-Path -LiteralPath $kit) { Remove-Item -LiteralPath $kit -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$f\dlssnr-amd\shaders", "$f\emulated\temporal", "$f\reference" | Out-Null
Copy-Item "$runtime\MochizukiNrRuntime.dll" "$f\"
Copy-Item -Recurse "$runtime\dlssnr-amd\shaders-rdna2" "$f\dlssnr-amd\shaders-rdna2"
Copy-Item -Recurse "$runtime\dlssnr-amd\shaders\renodx" "$f\dlssnr-amd\shaders\renodx"
Copy-Item 'E:\Projetos\opti_rr_dlss5\wt-rdna3-diag\exports\rel058\main\dlssnr-amd\LICENSE-DLSSNR-AMD.txt' "$f\dlssnr-amd\"
$used = 'g_attn', 'g_ffwd3', 'g_fswin128', 'g_fswin256', 'g_fswin32nh', 'g_fswin64', 'g_fswindsp128', 'g_fswindsp256',
        'g_fswindsp32nh', 'g_fswindsp64', 'g_fswinfusedup128', 'g_fswinfusedup256', 'g_fswinfusedup32', 'g_fswinfusedup64',
        'g_gemmproj', 'g_gemmprojc', 'g_gemmvact', 'g_gemmvqkvnorms', 'g_vitattn', 'temporal\temporal_post_fp32',
        'temporal\temporal_pre_fp32nh'
foreach ($u in $used) {
    $a = "$emulated\$u.spv"; $n = "$runtime\dlssnr-amd\shaders-rdna2\$u.spv"
    if ((Get-FileHash $a).Hash -eq (Get-FileHash $n).Hash) { throw "$u is the same in both sets: not an emulated set?" }
    Copy-Item $a "$f\emulated\$u.spv"
}
Copy-Item "$reference\img_*.jxr", "$reference\refs.txt" "$f\reference\"
& cmd /c "`"$PSScriptRoot\build-tools.cmd`" `"$f`"" | Select-Object -Last 1
if ($LASTEXITCODE) { throw 'tools build failed' }
Copy-Item "$PSScriptRoot\kit.ps1", "$PSScriptRoot\cases.ps1" "$f\"
Copy-Item 'E:\Projetos\opti_rr_dlss5\arrumar_cor\original_sem_nr.png' "$f\test.png"
Copy-Item "$PSScriptRoot\run-test.bat", "$PSScriptRoot\README.txt" "$kit\"
'kit laid out in ' + $kit
