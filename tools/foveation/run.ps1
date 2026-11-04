# run.ps1 -Name <tag> [-Fov 0..3] [-Size 1920x1080] [-Pan 0] [-Frames 40] [-Dump 1] [-Image test.png] [-Params ...] [-Format rgba8]
# Runs mz_fov in exports\foveation\run under the shared GPU lock (E:\Projetos\opti_rr_dlss5\gpu-timing.lock).
param([string]$Name, [int]$Fov = 0, [string]$Size = '1920x1080', [int]$Pan = 0, [int]$Frames = 40, [int]$Dump = 1,
      [string]$Image = 'test.png', [string]$Params = '', [string]$Align = '', [string]$Format = '')
$ErrorActionPreference = 'Stop'
$dir = Join-Path $PSScriptRoot '..\..\exports\foveation\run'
$lock = 'E:\Projetos\opti_rr_dlss5\gpu-timing.lock'
$stream = $null
for ($i = 0; -not $stream; ++$i) {
    try { $stream = [System.IO.File]::Open($lock, 'CreateNew', 'Write', 'None') }
    catch { if ($i -gt 360) { throw "GPU lock held too long: $(Get-Content $lock -ErrorAction SilentlyContinue)" }; Start-Sleep 5 }
}
$w = New-Object System.IO.StreamWriter($stream)
$w.WriteLine("foveated-nr agent (mz_fov $Name) $(Get-Date -Format s)")
$w.Close()
try {
    $x, $y = $Size.Split('x')
    $env:E2E_W = $x; $env:E2E_H = $y; $env:FOV = "$Fov"; $env:E2E_PAN = "$Pan"; $env:E2E_DUMP = "$Dump"
    if ($Params) { $env:FOV_PARAMS = $Params } else { Remove-Item Env:FOV_PARAMS -ErrorAction SilentlyContinue }
    if ($Format) { $env:E2E_FORMAT = $Format } else { Remove-Item Env:E2E_FORMAT -ErrorAction SilentlyContinue }
    if ($Align) { $env:FOV_ALIGN = $Align } else { Remove-Item Env:FOV_ALIGN -ErrorAction SilentlyContinue }
    Push-Location $dir
    New-Item -ItemType Directory -Force out | Out-Null
    Remove-Item mochizuki_nr.log -ErrorAction SilentlyContinue
    cmd /c "..\mz_fov.exe .\MochizukiNrRuntime.dll . $Image out\$Name $Frames > out\$Name.txt 2>&1"
    if (Test-Path mochizuki_nr.log) { Copy-Item mochizuki_nr.log "out\$Name.log" }
    Get-Content "out\$Name.txt" | Select-String 'grid|status|frame ms|FAIL'
}
finally {
    Pop-Location
    Remove-Item $lock -ErrorAction SilentlyContinue
    Remove-Item Env:E2E_W, Env:E2E_H, Env:FOV, Env:E2E_PAN, Env:E2E_DUMP, Env:FOV_PARAMS, Env:FOV_ALIGN, Env:E2E_FORMAT -ErrorAction SilentlyContinue
}
