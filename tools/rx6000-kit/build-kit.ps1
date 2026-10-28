# build-kit.ps1 <runtime dir> <reference dir> <kit dir>
# Lays the kit out in <kit dir>\OpenNR-RX6000-test: the runtime (<runtime dir>: MochizukiNrRuntime.dll and
# dlssnr-amd\shaders-rdna2 + shaders\renodx, as tools\build-mochizuki-runtime.cmd exports them), the references
# (make-refs.ps1) and the tools (build-tools.cmd).
param([string]$runtime, [string]$reference, [string]$kitRoot)
$ErrorActionPreference = 'Stop'
$kit = Join-Path $kitRoot 'OpenNR-RX6000-test'
$f = Join-Path $kit 'files'
if (Test-Path -LiteralPath $kit) { Remove-Item -LiteralPath $kit -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$f\dlssnr-amd\shaders", "$f\reference" | Out-Null
Copy-Item "$runtime\MochizukiNrRuntime.dll" "$f\"
Copy-Item -Recurse "$runtime\dlssnr-amd\shaders-rdna2" "$f\dlssnr-amd\shaders-rdna2"
Copy-Item -Recurse "$runtime\dlssnr-amd\shaders\renodx" "$f\dlssnr-amd\shaders\renodx"
Copy-Item 'E:\Projetos\opti_rr_dlss5\wt-rdna3-diag\exports\rel058\main\dlssnr-amd\LICENSE-DLSSNR-AMD.txt' "$f\dlssnr-amd\"
Copy-Item "$reference\img_*.jxr", "$reference\refs.txt" "$f\reference\"
& cmd /c "`"$PSScriptRoot\build-tools.cmd`" `"$f`"" | Select-Object -Last 1
if ($LASTEXITCODE) { throw 'tools build failed' }
Copy-Item "$PSScriptRoot\kit.ps1", "$PSScriptRoot\cases.ps1" "$f\"
Copy-Item 'E:\Projetos\opti_rr_dlss5\arrumar_cor\original_sem_nr.png' "$f\test.png"
Copy-Item "$PSScriptRoot\run-test.bat", "$PSScriptRoot\README.txt" "$kit\"
'kit laid out in ' + $kit
