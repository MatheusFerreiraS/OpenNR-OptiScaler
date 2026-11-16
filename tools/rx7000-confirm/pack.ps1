# pack.ps1 <RX 7000 speed kit laid out (...\OpenNR-RX7000-speed\files)> <runtime build dir> <large refs dir> <out dir>
# Lays the RX 7000 confirmation kit out in <out dir>\OpenNR-RX7000-confirm and zips it. From the speed kit: mz_e2e,
# compare, vkprobe, test.png and the RX 9070 XT references (small model). <large refs dir>: img_large_1280x720_* and
# img_large_1920x1080_* (the 310.8 model on the RX 9070 XT, same harness and frames). From the build:
# MochizukiNrRuntime.dll (k\), dlssnr-amd\shaders and shaders-rdna3, and aco-gfx11 (put in place only for the ACO runs).
param([string]$speed, [string]$build, [string]$refs, [string]$out)
$ErrorActionPreference = 'Stop'
$kit = Join-Path $out 'OpenNR-RX7000-confirm'
$f = Join-Path $kit 'files'
if (Test-Path -LiteralPath $kit) { Remove-Item -LiteralPath $kit -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$f\k", "$f\reference", "$f\dlssnr-amd" | Out-Null
Copy-Item "$build\MochizukiNrRuntime.dll" "$f\k\"
foreach ($s in 'shaders', 'shaders-rdna3') { Copy-Item -Recurse "$build\dlssnr-amd\$s" "$f\dlssnr-amd\$s" }
Copy-Item -Recurse "$build\dlssnr-amd\aco-gfx11" "$f\aco-gfx11"
foreach ($s in 'records', 'shaders') {
    New-Item -ItemType Directory -Force -Path "$f\dlssnr-amd\aco\$s" | Out-Null
    Set-Content -LiteralPath "$f\dlssnr-amd\aco\$s\README.txt" -Value 'Empty on purpose: the RX 7000 network uses dlssnr-amd\aco-gfx11.'
}
Copy-Item "$speed\mz_e2e.exe", "$speed\compare.exe", "$speed\vkprobe.exe", "$speed\test.png" "$f\"
Copy-Item "$speed\reference\*.jxr", "$refs\img_large_*.jxr" "$f\reference\"
Copy-Item "$PSScriptRoot\kit.ps1" "$f\"
Copy-Item "$PSScriptRoot\run-test.bat", "$PSScriptRoot\README.txt" "$kit\"
$zip = Join-Path $out 'OpenNR-RX7000-confirm.zip'
Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue
Compress-Archive -Path $kit -DestinationPath $zip -CompressionLevel Optimal
$h = (Get-FileHash -Algorithm SHA256 $zip).Hash
Set-Content -LiteralPath "$zip.sha256.txt" -Value "$h  OpenNR-RX7000-confirm.zip"
"$zip $((Get-Item $zip).Length) $h"
