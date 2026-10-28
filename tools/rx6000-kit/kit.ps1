# OpenNR RX 6000 test kit: run by run-test.bat. Everything goes into ..\result, zipped beside run-test.bat.
# Our own testing only: KIT_FORCE_RDNA2=1 runs the RDNA2 network on any card (MZ_FORCE_RDNA2=1), KIT_QUIET=1 opens
# no Explorer at the end.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$files = $PSScriptRoot
$kit = Split-Path $files -Parent
$result = Join-Path $kit 'result'
$work = Join-Path $files 'work'
$stamp = Get-Date -Format 'yyyy-MM-dd-HHmm'
Set-Location -LiteralPath $files
. (Join-Path $files 'cases.ps1')
foreach ($d in $result, $work) {
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    New-Item -ItemType Directory -Path $d | Out-Null
}
Get-ChildItem -LiteralPath $files -Recurse -Include *.exe, *.dll | Unblock-File -ErrorAction SilentlyContinue
Start-Transcript -LiteralPath (Join-Path $result 'console.txt') | Out-Null
$summary = New-Object System.Collections.Generic.List[string]
$short = New-Object System.Collections.Generic.List[string]
$t0 = Get-Date
function Line($s) { $summary.Add($s); Write-Host "  $s" }
$forced = $env:KIT_FORCE_RDNA2 -eq '1'

# Runs a tool with its output in a file. Returns the exit code, or 'TIMEOUT' / 'NOSTART'.
function Run($exe, $arguments, $out, $minutes) {
    try {
        $p = Start-Process -FilePath (Join-Path $files $exe) -ArgumentList $arguments -WorkingDirectory $files -NoNewWindow `
            -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err" -ErrorAction Stop
    } catch {
        Set-Content -LiteralPath $out -Value "$exe did not start: $($_.Exception.Message)"
        return 'NOSTART'
    }
    $null = $p.Handle
    if (-not $p.WaitForExit([int]($minutes * 60000))) {
        # The harness's own children (the runtime's pipeline check in rundll32) go with it.
        & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null
        try { $p.Kill() } catch {}
        return 'TIMEOUT'
    }
    $p.WaitForExit()
    $err = "$out.err"
    if ((Test-Path -LiteralPath $err) -and (Get-Item -LiteralPath $err).Length -gt 0) {
        Add-Content -LiteralPath $out -Value "`n--- stderr ---"
        Get-Content -LiteralPath $err | Add-Content -LiteralPath $out
    }
    Remove-Item -LiteralPath $err -ErrorAction SilentlyContinue
    return $p.ExitCode
}
function Sha256($path) {
    $s = [IO.File]::OpenRead($path)
    try { -join ([Security.Cryptography.SHA256]::Create().ComputeHash($s) | ForEach-Object { $_.ToString('x2') }) }
    finally { $s.Dispose() }
}
function Hex($code) { if ($code -is [int]) { '0x{0:X8}' -f $code } else { "$code" } }
function First($path, $pattern) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    Get-Content -LiteralPath $path | Where-Object { $_ -match $pattern } | Select-Object -First 1
}
function SetEnv($vars) { foreach ($k in $vars.Keys) { Set-Item -Path "Env:$k" -Value $vars[$k] } }
function ClearEnv($vars) { foreach ($k in $vars.Keys) { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue } }
function Minutes() { [int]((Get-Date) - $t0).TotalMinutes }

Write-Host ''
Write-Host 'OpenNR RX 6000 test. This takes about 10 to 20 minutes. Please do not close this window.'
Write-Host ''

# 1. System and Vulkan.
Write-Host '[1/6] System and Vulkan...'
$sys = Join-Path $result 'system.txt'
$code = Run 'vkprobe.exe' '--report' $sys 3
$sysText = @(if (Test-Path -LiteralPath $sys) { Get-Content -LiteralPath $sys })
$sysText | Where-Object { $_ -match '^(windows:|amd software:|cpu threads)' } | ForEach-Object { Line "INFO $_" }
if ($code -ne 0) { Line "FAIL vkprobe exit $(Hex $code)" }
# The first AMD Vulkan device's block.
$dev = @(); $in = $false
foreach ($l in $sysText) {
    if ($l -match '^vulkan device \d+: ') { if ($dev.Count) { break }; $in = $l -match 'vendor 1002' }
    if ($in) { $dev += $l }
}
$pick = ''
if (-not $dev.Count) { Line 'FAIL no AMD Vulkan device' }
else {
    Line "INFO $($dev[0])"
    foreach ($pat in '^\s+api ', '^\s+subgroup size', '^\s+subgroup operations', '^\s+max shared memory', '^\s+float16 controls',
                     '^\s+integer dot product', '^\s+VK_KHR_cooperative_matrix', '^\s+VK_EXT_shader_float8',
                     '^\s+cooperative matrix configurations', '^\s+runtime would pick') {
        $l = $dev | Where-Object { $_ -match $pat } | Select-Object -First 1
        if ($l) { Line ("INFO   " + $l.Trim()) }
    }
    $sdot = $dev | Where-Object { $_ -match 'shaderIntegerDotProduct (\d)' } | Select-Object -First 1
    if ($sdot -match 'shaderFloat16 (\d), shaderInt8 (\d).*shaderIntegerDotProduct (\d)') {
        Line "INFO   shaderFloat16 $($Matches[1]), shaderInt8 $($Matches[2]), shaderIntegerDotProduct $($Matches[3])"
    }
    $p = $dev | Where-Object { $_ -match 'runtime would pick: (.*)$' } | Select-Object -First 1
    if ($p -match 'runtime would pick: (.*)$') { $pick = $Matches[1] }
}
$notRdna2 = -not $forced -and $pick -notmatch '^RDNA2 network'
if ($forced) { Line 'INFO KIT_FORCE_RDNA2=1: the RDNA2 network is forced on this card (MZ_FORCE_RDNA2=1)' }
elseif ($notRdna2) { Line "SKIPPED the network tests: this card would not get the RX 6000 network ($pick)" }

# 2. The models, from the same place the OpenNR installer takes them.
$have = @{}
$modelFile = @{ small = 'dlssnr-small.bin'; large = 'dlssnr.bin' }
if (-not $notRdna2) {
    Write-Host '[2/6] Downloading the models (about 250 MB, once)...'
    $downloads = @(
        @{ name = 'dlssnr-small.bin'; size = 113917248; sha = '7e966e2639dbec6596aa0bac3b8761137d2c40ca8cb4aca30df7ca10043c6e33';
           url = 'https://huggingface.co/datasets/zmodelerlover/amd-nr/resolve/main/mochizuki/model-small-1/dlssnr-small.bin' },
        @{ name = 'dlssnr.bin'; size = 147756560; sha = '2b41c888cf4155b8958c665ba64018ab0bd25c85fc71a2b6db86d0d04d1f7fbd';
           url = 'https://huggingface.co/datasets/zmodelerlover/amd-nr/resolve/main/mochizuki/model-1/dlssnr.bin' })
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    foreach ($m in $downloads) {
        $dst = Join-Path $files "dlssnr-amd\$($m.name)"
        $verified = $false
        for ($try = 0; $try -lt 3 -and -not $verified; ++$try) {
            if (-not (Test-Path -LiteralPath $dst) -or (Get-Item -LiteralPath $dst).Length -ne $m.size) {
                Remove-Item -LiteralPath $dst -ErrorAction SilentlyContinue
                $part = "$dst.part"
                Remove-Item -LiteralPath $part -ErrorAction SilentlyContinue
                try {
                    if ($try -lt 2) { Invoke-WebRequest -Uri $m.url -OutFile $part -UseBasicParsing -TimeoutSec 600 }
                    else { Start-BitsTransfer -Source $m.url -Destination $part -ErrorAction Stop }
                    Move-Item -LiteralPath $part -Destination $dst -Force
                } catch { Write-Host "    download of $($m.name) failed: $($_.Exception.Message)" }
            }
            if (Test-Path -LiteralPath $dst) {
                if ((Sha256 $dst) -eq $m.sha) { $verified = $true } else { Remove-Item -LiteralPath $dst -Force }
            }
        }
        $have[$m.name] = $verified
        if ($verified) { Line "PASS model $($m.name): SHA-256 verified" }
        else { Line "FAIL model $($m.name): could not be downloaded and verified" }
    }
}

$baseEnv = @{}
if ($forced) { $baseEnv['MZ_FORCE_RDNA2'] = '1' }
Remove-Item Env:MZ_FORCE_RDNA2, Env:MZ_FORCE_RDNA3, Env:MZ_RDNA2_CHECK, Env:MZ_RDNA3_CHECK, Env:DLSSNR_MODEL, Env:E2E_FLAGS, `
    Env:E2E_PAN, Env:NR_STEP_TIMES, Env:NR_DIAG_SEED0, Env:NR_DIAG_TGATE0, Env:NR_TCHAIN, Env:E2E_WAIT_MIN -ErrorAction SilentlyContinue
foreach ($f in 'pipeline-rdna2.cache', 'pipeline.cache', 'prewarm', 'build.pending', 'build.failed', 'rdna2-check.txt', 'rdna2-check') {
    Remove-Item -LiteralPath (Join-Path $files "dlssnr-amd\$f") -Recurse -Force -ErrorAction SilentlyContinue
}

# Parses pipecheck output into one row a file: @{ file; state; ms; text }.
function PipeRows($path) {
    $rows = @()
    foreach ($l in @(if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path })) {
        if ($l -notmatch '^PIPE (\S+) (OK|FAIL|CRASH|TIMEOUT|NOTRUN)\s*(.*)$') { continue }
        $file = $Matches[1]; $state = $Matches[2]; $rest = $Matches[3]
        $ms = if ($rest -match '^(\d+) ms') { [int]$Matches[1] } elseif ($rest -match 'after (\d+) ms') { [int]$Matches[1] } `
              elseif ($rest -match 'after (\d+) s') { 1000 * [int]$Matches[1] } else { 0 }
        $rows += @{ file = ($file -replace '^.*dlssnr-amd\\', ''); state = $state; ms = $ms; text = $rest }
    }
    $rows
}

# 3. Every RDNA2 pipeline compiled once, each in its own process with a time limit.
$pipesOk = $false
if (-not $notRdna2) {
    Write-Host '[3/6] Compiling every shader once (each in its own process; the first time takes a few minutes)...'
    $env:PIPECHECK_COOP = '0'; $env:PIPECHECK_TIMEOUT_S = '300'; $env:PIPECHECK_BUDGET_S = '900'
    $pc = Join-Path $result 'pipecheck.txt'
    $all = @(Get-ChildItem -LiteralPath (Join-Path $files 'dlssnr-amd\shaders-rdna2'), (Join-Path $files 'dlssnr-amd\shaders\renodx') `
        -Recurse -Filter *.spv | Sort-Object FullName)
    $list = ($all | ForEach-Object { '"' + $_.FullName.Substring($files.Length + 1) + '"' }) -join ' '
    $code = Run 'pipecheck.exe' $list $pc 22
    Remove-Item Env:PIPECHECK_COOP, Env:PIPECHECK_TIMEOUT_S, Env:PIPECHECK_BUDGET_S -ErrorAction SilentlyContinue
    $rows = @(PipeRows $pc)
    $okRows = @($rows | Where-Object { $_.state -eq 'OK' })
    $badRows = @($rows | Where-Object { $_.state -ne 'OK' })
    $total = ($rows | ForEach-Object { $_.ms } | Measure-Object -Sum).Sum
    $table = @('pipeline  state  ms') + @($rows | Sort-Object { -$_.ms } | ForEach-Object { '{0}  {1}  {2}  {3}' -f $_.file, $_.state, $_.ms, $_.text })
    Set-Content -LiteralPath (Join-Path $result 'pipelines-by-time.txt') -Value $table
    $slow = ($okRows | Sort-Object { -$_.ms } | Select-Object -First 5 | ForEach-Object { '{0} {1:N1} s' -f $_.file, ($_.ms / 1000) }) -join ', '
    if ($code -eq 'TIMEOUT') { Line 'FAIL pipelines: the compile stage ran out of its 22 minutes' }
    if ($rows.Count -and -not $badRows.Count) {
        $pipesOk = $true
        Line ('PASS pipelines: {0} of {0} compiled, {1:N0} s in all; slowest {2}' -f $rows.Count, ($total / 1000), $slow)
    } else {
        Line ('FAIL pipelines: {0} of {1} compiled ({2:N0} s); slowest {3}' -f $okRows.Count, $rows.Count, ($total / 1000), $slow)
        foreach ($b in $badRows) { Line "     $($b.state) $($b.file) $($b.text)" }
        if (-not $rows.Count) { Line "     pipecheck exit $(Hex $code); see pipecheck.txt" }
        Line 'SKIPPED the network tests: a shader did not compile, so the network would stay off'
    }
}
$run = $pipesOk -and $have['dlssnr-small.bin']

# One harness run: the network on test.png. $c a case of cases.ps1, $dll the folder of MochizukiNrRuntime.dll (its
# dlssnr-amd beside it if it has one, else files\dlssnr-amd), $vars extra environment. Leaves work\<tag>.bin.
$script:first = $true
$script:netSeen = ''
function E2E($tag, $c, $frames, $vars, $dir, $dll = '.', $minutes = 6) {
    $r = @{ ok = $false; why = ''; net = '?'; ms = ''; median = ''; build = ''; check = ''; vram = ''; menu = ''; sha = ''; bin = "work\$tag.bin" }
    if (-not $have[$modelFile[$c.model]]) { $r.why = "no $($modelFile[$c.model])"; return $r }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $data = if (Test-Path -LiteralPath (Join-Path $files "$dll\dlssnr-amd")) { $dll } else { '.' }
    $log = Join-Path $files "$data\mochizuki_nr.log"
    Remove-Item -LiteralPath $log, (Join-Path $files $r.bin) -ErrorAction SilentlyContinue
    $all = @{ E2E_W = "$($c.w)"; E2E_H = "$($c.h)"; E2E_FLAGS = $(if ($c.model -eq 'large') { '8192' } else { '0' }) }
    foreach ($k in $baseEnv.Keys) { $all[$k] = $baseEnv[$k] }
    foreach ($k in $vars.Keys) { $all[$k] = $vars[$k] }
    if ($script:first) { $minutes = 20; $all['E2E_WAIT_MIN'] = '18' } elseif (-not $all.ContainsKey('E2E_WAIT_MIN')) { $all['E2E_WAIT_MIN'] = "$([Math]::Max(1, $minutes - 1))" }
    SetEnv $all
    $out = Join-Path $dir "harness_$tag.txt"
    $code = Run 'mz_e2e.exe' ".\$dll\MochizukiNrRuntime.dll $data test.png $($r.bin) $frames 1" $out $minutes
    ClearEnv $all
    $script:first = $false
    if (Test-Path -LiteralPath $log) { Copy-Item -LiteralPath $log -Destination (Join-Path $dir "log_$tag.txt") }
    $lt = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log })
    $net = $lt | Where-Object { $_ -match '\[mochizuki\] the (RDNA2|RDNA3|FP8) network' } | Select-Object -First 1
    if ($net -match 'the (RDNA2|RDNA3|FP8) network') { $r.net = $Matches[1]; $script:netSeen = $Matches[1] }
    $chk = $lt | Where-Object { $_ -match 'RDNA2 pipeline check (passed|failed|could not run)' } | Select-Object -Last 1
    if ($chk -match '\] (RDNA2 pipeline check.*)$') { $r.check = $Matches[1] }
    elseif ($lt | Where-Object { $_ -match 'RDNA2 pipeline check: \d+ pipelines' }) { $r.check = 'RDNA2 pipeline check started, never finished' }
    $vr = $lt | Where-Object { $_ -match 'VRAM: the network at' } | Select-Object -Last 1
    if ($vr -match 'estimated at (\d+) MB; this process grew by (\d+) MB') { $r.vram = "VRAM estimated $($Matches[1]) MB, grew $($Matches[2]) MB" }
    $status = First $out '^status: '
    if ($status -match 'network ([\d.]+) ms \(p95 ([\d.]+)\)') { $r.ms = "network $($Matches[1]) ms (p95 $($Matches[2]))"; $r.netms = [double]$Matches[1] }
    $fm = First $out '^frame ms: '
    if ($fm -match 'median=([\d.]+)') { $r.median = "frame median $($Matches[1]) ms" }
    $ready = First $out '^ready after '
    if ($ready -match 'ready after ([\d.]+) s') { $r.build = "ready in $($Matches[1]) s" }
    $menu = First $out '^network \d+, menu: '
    if ($menu) { $r.menu = $menu }
    if ($code -ne 0) {
        $why = First $out 'FAIL'
        if ($code -eq 'TIMEOUT') { $why = "timed out after $minutes min" } elseif (-not $why) { $why = "exit $(Hex $code)" }
        $off = $lt | Where-Object { $_ -match 'network off|crash|build failed|unsupported' } | Select-Object -Last 1
        $r.why = "$why$(if ($off) { " | $($off -replace '^\S+ ', '')" })"
        return $r
    }
    $r.ok = $true
    if (Test-Path -LiteralPath (Join-Path $files $r.bin)) { $r.sha = (Sha256 (Join-Path $files $r.bin)).Substring(0, 16) }
    return $r
}
function Score($bin, $c, $out, $pictures) {
    $a = "$bin $($c.w) $($c.h) reference\img_$($c.name)"
    if ($pictures) { $a += " ..\result\$pictures\diff_x16.png ..\result\$pictures\output.jpg" }
    $null = Run 'compare.exe' $a $out 3
    $l = First $out '^COMPARE '
    if ($l -match 'psnr (\S+) dB \(worst area (\S+)\), nan/inf (\d+)') {
        return @{ psnr = $(if ($Matches[1] -eq 'inf') { 999.0 } else { [double]$Matches[1] }); text = "$($Matches[1]) dB"; bad = [int]$Matches[3] }
    }
    return @{ psnr = -1.0; text = 'no comparison'; bad = 0 }
}
function RunsDiff($a, $b, $c, $out) {
    $null = Run 'compare.exe' "--bins $a $b $($c.w) $($c.h)" $out 3
    $l = First $out '^RUNS '
    if ($l -match '^RUNS identical') { return 'identical' }
    if ($l -match 'psnr (\S+) dB') { return "differ ($($Matches[1]) dB)" }
    return 'not compared'
}

# 4. Quality: clean runs against the RX 9070 XT, three a case.
$pass = @(); $fail = @(); $vary = @(); $hash = @{}
$stop = -not $run
if ($run) {
    Write-Host "[4/6] Picture check: $($Quality.Count) cases x $QualityRuns runs (the first one builds the network, a few minutes)..."
    foreach ($c in $Quality) {
        if ($stop) { break }
        if (-not $have[$modelFile[$c.model]]) { Line "SKIPPED $($c.name): $($modelFile[$c.model]) missing"; continue }
        Write-Host "    $($c.name) ..."
        $dir = Join-Path $result "quality\$($c.name)"
        $scores = @(); $fails = @(); $info = $null
        for ($k = 1; $k -le $QualityRuns; ++$k) {
            $wasFirst = $script:first
            $r = E2E "$($c.name).r$k" $c $QualityFrames $Clean $dir
            if ($wasFirst) {
                Line "INFO first network build: $(if ($r.build) { $r.build } else { 'not ready' }); $(if ($r.check) { $r.check } else { 'no RDNA2 pipeline check line in the log' })"
                if ($r.menu) { Line "INFO $($r.menu)" }
            }
            if ($r.net -ne '?' -and $r.net -ne 'RDNA2') {
                Line "SKIPPED the network tests: the runtime picked the $($r.net) network on this card, not the RX 6000 one"
                $stop = $true; break
            }
            if (-not $r.ok -and $wasFirst -and $r.check -match 'check failed|never finished' -and -not $baseEnv.ContainsKey('MZ_RDNA2_CHECK')) {
                # The runtime's own check refused a pipeline (in a game the network stays off): once more without it.
                Line "WARN the runtime's pipeline check keeps the network off: $($r.check); the runs below skip it (MZ_RDNA2_CHECK=0)"
                $script:checkBad = $true
                $baseEnv['MZ_RDNA2_CHECK'] = '0'
                $script:first = $true
                $wasFirst = $true
                $r = E2E "$($c.name).r$k" $c $QualityFrames $Clean $dir
                Line "INFO first network build without the check: $(if ($r.build) { $r.build } else { 'not ready' })"
            }
            if (-not $r.ok) {
                $fails += "run $k failed: $($r.why)"
                if ($wasFirst) { $stop = $true }
                break
            }
            if (-not $info) { $info = $r; $hash[$c.name] = $r.sha }
            $pic = if ($k -eq 1) { "quality\$($c.name)" } else { $null }
            $scores += Score $r.bin $c (Join-Path $dir "compare_r$k.txt") $pic
        }
        $diffs = @()
        for ($k = 2; $k -le $QualityRuns; ++$k) {
            $a = "work\$($c.name).r1.bin"; $b = "work\$($c.name).r$k.bin"
            if ((Test-Path -LiteralPath (Join-Path $files $a)) -and (Test-Path -LiteralPath (Join-Path $files $b))) {
                $diffs += "r1-r${k} " + (RunsDiff $a $b $c (Join-Path $dir "runs_r1_r$k.txt"))
            }
        }
        Remove-Item -Path (Join-Path $files "work\$($c.name).r*.bin") -ErrorAction SilentlyContinue
        $varies = @($diffs | Where-Object { $_ -notmatch 'identical$' }).Count -gt 0
        $okAll = $scores.Count -eq $QualityRuns -and @($scores | Where-Object { $_.psnr -lt $PassDb -or $_.bad -gt 0 }).Count -eq 0
        $verdict = if ($fails.Count -or -not $okAll) { 'FAIL' } else { 'PASS' }
        if ($verdict -eq 'PASS') { $pass += $c.name } else { $fail += $c.name }
        if ($varies) { $vary += $c.name }
        $ps = ($scores | ForEach-Object { $_.text }) -join ' / '
        Line ("{0} {1}: PSNR vs RX 9070 XT {2}; {3}; sha {4}" -f $verdict, $c.name, $(if ($ps) { $ps } else { '-' }),
              $(if ($diffs.Count) { $diffs -join ', ' } else { 'runs not compared' }), $(if ($info) { $info.sha } else { '-' }))
        foreach ($f in $fails) { Line "     $f" }
    }
}

# 5. Speed: normal runs with the GPU clock sampled alongside, then the per-pipeline times.
$speedRows = @()
if ($run -and -not $stop) {
    Write-Host "[5/6] Speed: $($Speed.Count) cases, then the time of each shader..."
    foreach ($c in $Speed) {
        if (-not $have[$modelFile[$c.model]]) { continue }
        Write-Host "    $($c.name) ..."
        $dir = Join-Path $result "speed\$($c.name)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $flag = Join-Path $work 'clock.stop'
        Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue
        $clockOut = Join-Path $dir 'gpuclock.txt'
        $clock = $null
        try {
            $clock = Start-Process -FilePath (Join-Path $files 'gpuclock.exe') -ArgumentList "400 `"$flag`"" -WorkingDirectory $files `
                -NoNewWindow -PassThru -RedirectStandardOutput $clockOut -RedirectStandardError "$clockOut.err" -ErrorAction Stop
        } catch {}
        $r = E2E "$($c.name).speed" $c $SpeedFrames @{} $dir
        Set-Content -LiteralPath $flag -Value 'stop'
        if ($clock -and -not $clock.WaitForExit(10000)) { try { $clock.Kill() } catch {} }
        Remove-Item -LiteralPath "$clockOut.err", (Join-Path $files $r.bin), (Join-Path $files "$($r.bin).prev") -ErrorAction SilentlyContinue
        $ck = First $clockOut '^CLOCK '
        $ck = if ($ck) { $ck -replace '^CLOCK ', '' } else { 'no clock reading' }
        if ($r.ok) {
            Line "SPEED $($c.name): $($r.ms), $($r.median); $($r.vram); GPU $ck"
            $speedRows += "$($c.name) $($r.netms)"
        } else { Line "FAIL speed $($c.name): $($r.why)" }
    }
    foreach ($n in $Steps) {
        $c = $Speed | Where-Object { $_.name -eq $n } | Select-Object -First 1
        if (-not $c -or -not $have[$modelFile[$c.model]]) { continue }
        Write-Host "    $n, per shader ..."
        $dir = Join-Path $result "speed\$n"
        $r = E2E "$n.steps" $c $StepFrames @{ NR_STEP_TIMES = "$StepCount" } $dir
        Remove-Item -LiteralPath (Join-Path $files $r.bin), (Join-Path $files "$($r.bin).prev") -ErrorAction SilentlyContinue
        $lt = @(Get-Content -LiteralPath (Join-Path $dir "log_$n.steps.txt") -ErrorAction SilentlyContinue)
        $i = -1
        for ($j = 0; $j -lt $lt.Count; ++$j) { if ($lt[$j] -match 'NR_STEP_TIMES: \d+ frames') { $i = $j } }
        if (-not $r.ok -or $i -lt 0) { Line "FAIL steps ${n}: $(if ($r.why) { $r.why } else { 'no NR_STEP_TIMES table in the log' })"; continue }
        $tab = @($lt[$i] -replace '^.*NR_STEP_TIMES: ', '')
        for ($j = $i + 1; $j -lt $lt.Count -and $lt[$j] -match '\[nr\]\s+\S+\.spv\s'; ++$j) { $tab += ($lt[$j] -replace '^.*\[nr\]\s+', '') }
        Set-Content -LiteralPath (Join-Path $result "steps_$n.txt") -Value $tab
        $top = ($tab | Select-Object -Skip 1 -First 6 | ForEach-Object { if ($_ -match '^(\S+)\.spv\s+(\d+) x\s+([\d.]+) ms') { "$($Matches[1]) $($Matches[3])" } }) -join ', '
        Line "STEPS ${n}: $($tab[0]); top: $top"
    }
}

# 6. Summary and the zip.
Write-Host '[6/6] Writing the result...'
$card = if ($dev.Count) { $dev[0] -replace '^vulkan device \d+: ', '' } else { 'no AMD Vulkan device' }
$short.Add("Card: $card")
if ($notRdna2) { $short.Add('This card would not use the RX 6000 network, so the network was not tested. Please tell us which card this is.') }
else {
    $short.Add("Shaders compile: $(if ($pipesOk) { 'yes, all' } else { 'NO (see the pipelines lines)' })")
    if ($script:checkBad) { $short.Add('The runtime''s own shader check failed (see WARN): in a game the network would stay off') }
    if ($run) {
        $short.Add("Picture right (40 dB or more against an RX 9070 XT): $(if ($pass.Count) { $pass -join ', ' } else { 'none' })")
        $short.Add("Picture wrong or failed: $(if ($fail.Count) { $fail -join ', ' } else { 'none' })")
        $short.Add("Picture changes from run to run: $(if ($vary.Count) { $vary -join ', ' } else { 'none' })")
        if ($speedRows.Count) { $short.Add("Network time per frame, ms: $($speedRows -join '; ')") }
    }
}
$head = @("OpenNR RX 6000 test kit (mochizuki RDNA2 network), $((Get-Date).ToString('yyyy-MM-dd HH:mm')), $(Minutes) min", '',
          'IN SHORT') + ($short | ForEach-Object { "  $_" }) + @('', 'DETAILS')
$tail = @('', "How to read this: PASS = every run within $PassDb dB PSNR of the RX 9070 XT reference, FAIL = not, or the run failed.",
          '"identical" means the same picture every run. SPEED is the network alone (status line), with the GPU clock while busy.',
          'STEPS: the per-shader times (NR_STEP_TIMES; the timestamps make the sum about 20% more than SPEED).',
          'Raw files: system.txt, pipecheck.txt, pipelines-by-time.txt, runtime-rdna2-check-*.txt, quality\, speed\, steps_*.txt, console.txt.')
Set-Content -LiteralPath (Join-Path $result 'SUMMARY.txt') -Value ($head + $summary + $tail)
foreach ($f in 'rdna2-check.txt', 'rdna2-check\pipelines.txt', 'rdna2-check\pipelines.log') {
    $p = Join-Path $files "dlssnr-amd\$f"
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $result ('runtime-' + ($f -replace '\\', '-'))) }
}
Stop-Transcript | Out-Null
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
$zip = Join-Path $kit "OpenNR-RX6000-result-$stamp.zip"
Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue
try {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $za = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in Get-ChildItem -LiteralPath $result -Recurse -File) {
            $rel = $f.FullName.Substring($result.Length + 1).Replace('\', '/')
            $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $f.FullName, $rel, [IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $za.Dispose() }
} catch { Write-Host "zip: $($_.Exception.Message)"; Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue }
Write-Host ''
if (Test-Path -LiteralPath $zip) {
    Write-Host 'Done. Please send this file:' -ForegroundColor Green
    Write-Host "  $zip" -ForegroundColor Green
    if (-not $env:KIT_QUIET) { Start-Process explorer.exe -ArgumentList "/select,`"$zip`"" }
} else {
    Write-Host 'Done, but the zip could not be made. Please zip and send the folder:' -ForegroundColor Yellow
    Write-Host "  $result" -ForegroundColor Yellow
}
