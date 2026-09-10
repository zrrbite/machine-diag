<#
.SYNOPSIS
    Diagnoses common causes of slow builds/dev work on corporate Windows machines.
.DESCRIPTION
    Read-only diagnostic: collects configuration evidence and runs compile-shaped
    micro-benchmarks, then writes a ranked Markdown report for IT.
    Changes NOTHING on the machine. See RISK-ASSESSMENT.md.

    -CompileBench additionally builds a generated C++ project with a compiler the
    machine already has, to measure real compilation rather than compile-shaped
    I/O. The linked executable is never run.
.EXAMPLE
    # Check whether a full run will work here, without measuring anything
    powershell -ExecutionPolicy Bypass -File .\Diagnose-DevMachine.ps1 -PreFlight
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Diagnose-DevMachine.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Diagnose-DevMachine.ps1 -CompileBench -DefenderTrace
#>
[CmdletBinding()]
param(
    [switch]$PreFlight,
    [switch]$DefenderTrace,
    [switch]$CompileBench,
    [switch]$LibraryMode,
    [ValidateRange(1, 100000)][int]$BenchFileCount = 2000,
    [ValidateRange(1, 10000)][int]$BenchSpawnCount = 100,
    [string]$CompileBenchCompiler = '',
    [ValidateRange(1, 2000)][int]$CompileBenchTuCount = 30,
    [ValidateRange(1, 200)][int]$CompileBenchHeaderCount = 8
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:OnWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$script:SeverityOrder = @{ 'Problem' = 0; 'Warning' = 1; 'Info' = 2; 'OK' = 3; 'Skipped' = 4 }

# ---------- Core framework ----------
function New-DiagResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][ValidateSet('Problem','Warning','Info','OK','Skipped')][string]$Severity,
        [string[]]$Evidence = @(),
        [string]$Recommendation = '',
        # The one measurement that makes this finding make sense, for the summary
        # table. Falls back to the first evidence line when not set.
        [string]$Headline = ''
    )
    [pscustomobject]@{
        Name           = $Name
        Category       = $Category
        Severity       = $Severity
        Evidence       = $Evidence
        Recommendation = $Recommendation
        Headline       = $Headline
    }
}

function Invoke-DiagCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    try {
        # Filtered because a collector that calls a chatty cmdlet without
        # suppressing it would otherwise put stray objects into the results
        # array and break report rendering at the very end of the run.
        & $Body | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Severity'] }
    } catch {
        New-DiagResult -Name $Name -Category $Category -Severity 'Skipped' `
            -Evidence @("Check failed: $($_.Exception.Message)")
    }
}

function Get-DiagHeadline {
    param([Parameter(Mandatory)][object]$Result)
    if ($Result.PSObject.Properties['Headline'] -and $Result.Headline) { return $Result.Headline }
    $evidence = @($Result.Evidence)
    if ($evidence.Count -gt 0) { return $evidence[0] }
    ''
}

function Format-DiagSummary {
    param(
        [Parameter(Mandatory)][object[]]$Sorted,
        [Parameter(Mandatory)][string]$ComputerName
    )
    $problems = @($Sorted | Where-Object { $_.Severity -eq 'Problem' })
    $warnings = @($Sorted | Where-Object { $_.Severity -eq 'Warning' })
    $okCount = @($Sorted | Where-Object { $_.Severity -eq 'OK' }).Count
    $skipped = @($Sorted | Where-Object { $_.Severity -eq 'Skipped' })

    $tail = "$okCount checks passed"
    if ($skipped.Count -gt 0) { $tail += ", $($skipped.Count) could not run" }
    $tail += '.'

    $lines = @('## Summary', '')
    if ($problems.Count -eq 0 -and $warnings.Count -eq 0) {
        $lines += "Nothing to fix on $ComputerName. $tail"
    } else {
        $bits = @()
        if ($problems.Count -gt 0) { $bits += "$($problems.Count) problem$(if ($problems.Count -ne 1) { 's' })" }
        if ($warnings.Count -gt 0) { $bits += "$($warnings.Count) warning$(if ($warnings.Count -ne 1) { 's' })" }
        $lines += "$($bits -join ' and ') on $ComputerName. $tail"
        $lines += ''
        $lines += '| Severity | Finding | Key measurement |'
        $lines += '| --- | --- | --- |'
        foreach ($r in ($problems + $warnings)) {
            $headline = (Get-DiagHeadline -Result $r) -replace '\|', '\|'
            $lines += "| $($r.Severity) | $($r.Name) ($($r.Category)) | $headline |"
        }

        $actions = @()
        foreach ($r in ($problems + $warnings)) {
            if ($r.Recommendation -and ($actions -notcontains $r.Recommendation)) {
                $actions += $r.Recommendation
            }
        }
        if ($actions.Count -gt 0) {
            $lines += ''
            $lines += '### Recommended actions, most important first'
            $lines += ''
            for ($i = 0; $i -lt $actions.Count; $i++) {
                $lines += "$($i + 1). $($actions[$i])"
            }
        }
    }
    if ($skipped.Count -gt 0) {
        $lines += ''
        $names = ($skipped | ForEach-Object { $_.Name }) -join ', '
        $lines += "Could not run: $names. See the Skipped section for why."
    }
    $lines += ''
    $lines += 'Full evidence for every check follows.'
    $lines
}

function Format-DiagMeasurements {
    # Every benchmark's headline number in one table. Without this a reader has
    # to hunt through per-check evidence to compare their machine against a
    # known-good one, which is the main thing people want the numbers for.
    param([Parameter(Mandatory)][object[]]$Sorted)
    $bench = @($Sorted | Where-Object { $_.Category -eq 'Benchmark' })
    if ($bench.Count -eq 0) { return @() }
    $lines = @('', '## Measurements', '', '| Measurement | Result | Verdict |', '| --- | --- | --- |')
    foreach ($r in ($bench | Sort-Object Name)) {
        $headline = (Get-DiagHeadline -Result $r) -replace '\|', '\|'
        $lines += "| $($r.Name) | $headline | $($r.Severity) |"
    }
    $lines += ''
    $lines += 'Reference numbers from a known-good machine are in the project README.'
    $lines
}

function Format-DiagReport {
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][datetime]$Timestamp
    )
    $sorted = @($Results | Sort-Object { $script:SeverityOrder[$_.Severity] }, Category)
    $counts = ($Results | Group-Object Severity |
        Sort-Object { $script:SeverityOrder[$_.Name] } |
        ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
    $lines = @(
        "# Dev machine diagnostic - $ComputerName"
        ''
        "Generated $($Timestamp.ToString('yyyy-MM-dd HH:mm')) by Diagnose-DevMachine.ps1."
        'This tool is read-only; see RISK-ASSESSMENT.md. Report may contain machine'
        'names and file paths - treat as internal, share with IT only.'
        ''
        "**Checks:** $counts"
        ''
    )
    $lines += Format-DiagSummary -Sorted $sorted -ComputerName $ComputerName
    $lines += Format-DiagMeasurements -Sorted $sorted
    foreach ($sev in 'Problem','Warning','Info','OK','Skipped') {
        $group = @($sorted | Where-Object { $_.Severity -eq $sev })
        if ($group.Count -eq 0) { continue }
        $lines += ''
        $lines += "## $sev"
        foreach ($r in $group) {
            $lines += ''
            $lines += "### $($r.Name) ($($r.Category))"
            foreach ($e in $r.Evidence) { $lines += "- $e" }
            if ($r.Recommendation) {
                $lines += ''
                $lines += "**Recommended action:** $($r.Recommendation)"
            }
        }
    }
    ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Write-ConsoleSummary {
    param([Parameter(Mandatory)][object[]]$Results)
    $colors = @{ Problem = 'Red'; Warning = 'Yellow'; Info = 'Cyan'; OK = 'Green'; Skipped = 'DarkGray' }
    foreach ($r in ($Results | Sort-Object { $script:SeverityOrder[$_.Severity] }, Category)) {
        Write-Host ('[{0,-7}] {1}: {2}' -f $r.Severity.ToUpper(), $r.Category, $r.Name) `
            -ForegroundColor $colors[$r.Severity]
    }
}

# ---------- Security evaluators (pure logic; unit-tested) ----------

$script:ToolchainProcesses = @(
    'cl.exe','link.exe','lib.exe','msbuild.exe','devenv.exe','cmake.exe','ninja.exe',
    'make.exe','gcc.exe','g++.exe','ld.exe','arm-none-eabi-gcc.exe','arm-none-eabi-g++.exe',
    'armclang.exe','iccarm.exe','iarbuild.exe','git.exe','node.exe','python.exe','Code.exe'
)

$script:DevRootCandidates = @(
    'C:\dev','C:\src','C:\work','C:\projects','C:\repos','C:\git',
    "$env:USERPROFILE\dev","$env:USERPROFILE\src","$env:USERPROFILE\source",
    "$env:USERPROFILE\work","$env:USERPROFILE\git","$env:USERPROFILE\repos",
    "$env:USERPROFILE\Projects","$env:USERPROFILE\Development",
    "$env:USERPROFILE\Documents\GitHub","$env:USERPROFILE\source\repos"
)

function Select-RealExclusions {
    # Run unelevated, Get-MpPreference does not fail - it returns the literal
    # string "N/A: Must be an administrator to view exclusions" in place of each
    # list. Counting that as a configured exclusion overstates coverage and
    # suppresses the "zero exclusions may not be real" note exactly when it is
    # most warranted. Get-MpPreference also returns $null rather than an empty
    # array when nothing is configured, and @($null).Count is 1.
    param([object[]]$Values = @())
    # Comma operator: an empty array would otherwise unroll to $null on return,
    # and StrictMode makes .Count on that a terminating error at the call site.
    , @($Values | Where-Object { $_ -and ($_ -notmatch '^\s*N/A:\s*Must be an administrator') })
}

function Test-ExclusionsWithheld {
    param([object[]]$Values = @())
    @($Values | Where-Object { $_ -match '^\s*N/A:\s*Must be an administrator' }).Count -gt 0
}

function Get-DefenderExclusionGaps {
    param(
        [string[]]$ExclusionPaths = @(),
        [string[]]$ExclusionProcesses = @(),
        [string[]]$DevRoots = @(),
        [string[]]$ToolchainProcesses = @()
    )
    $uncoveredRoots = @()
    foreach ($root in $DevRoots) {
        $covered = $false
        foreach ($ex in $ExclusionPaths) {
            $exNorm = $ex.TrimEnd('\')
            if ($root -eq $exNorm -or $root -like "$exNorm\*") { $covered = $true; break }
        }
        if (-not $covered) { $uncoveredRoots += $root }
    }
    $excludedNames = @($ExclusionProcesses | ForEach-Object {
        # Use split instead of [System.IO.Path]::GetFileName: .NET off-Windows doesn't treat backslash as a path separator, breaking cross-platform tests.
        ($_ -split '[\\/]')[-1].ToLowerInvariant()
    })
    $uncoveredProcs = @($ToolchainProcesses | Where-Object {
        $excludedNames -notcontains $_.ToLowerInvariant()
    })
    [pscustomobject]@{
        UncoveredRoots     = $uncoveredRoots
        UncoveredProcesses = $uncoveredProcs
    }
}

$script:AgentCatalog = @(
    @{ Pattern = 'CrowdStrike|CSFalcon';            Product = 'CrowdStrike Falcon' }
    @{ Pattern = 'SentinelOne|Sentinel(Agent|Helper)'; Product = 'SentinelOne' }
    @{ Pattern = 'Cortex XDR|Cyvera|Traps';         Product = 'Palo Alto Cortex XDR' }
    @{ Pattern = 'Carbon ?Black|CbDefense';         Product = 'Carbon Black' }
    @{ Pattern = 'Netskope|stAgentSvc';             Product = 'Netskope Client' }
    @{ Pattern = 'Zscaler|ZSAService';              Product = 'Zscaler' }
    @{ Pattern = 'Tanium';                          Product = 'Tanium' }
    @{ Pattern = 'Qualys';                          Product = 'Qualys Cloud Agent' }
    @{ Pattern = 'McAfee|Trellix|masvc';            Product = 'McAfee/Trellix' }
    @{ Pattern = 'Symantec|SepMasterService';       Product = 'Symantec Endpoint Protection' }
    @{ Pattern = 'Trend ?Micro|ds_agent|tmlisten';  Product = 'Trend Micro' }
    @{ Pattern = 'Sophos';                          Product = 'Sophos' }
    @{ Pattern = 'ESET|ekrn';                       Product = 'ESET' }
    @{ Pattern = 'FortiClient|FortiEDR';            Product = 'Fortinet' }
    @{ Pattern = 'Cybereason';                      Product = 'Cybereason' }
    @{ Pattern = 'Elastic ?Agent';                  Product = 'Elastic Agent' }
    @{ Pattern = 'Ivanti';                          Product = 'Ivanti' }
)

function Find-SecurityAgents {
    param([object[]]$Services = @())
    $found = @{}
    foreach ($svc in $Services) {
        foreach ($entry in $script:AgentCatalog) {
            if ($svc.Name -match $entry.Pattern -or $svc.DisplayName -match $entry.Pattern) {
                if (-not $found.ContainsKey($entry.Product)) { $found[$entry.Product] = @() }
                $found[$entry.Product] += $svc.Name
                break
            }
        }
    }
    foreach ($product in ($found.Keys | Sort-Object)) {
        [pscustomobject]@{ Product = $product; Services = $found[$product] }
    }
}

# ---------- System evaluators (pure logic; unit-tested) ----------

$script:PowerPlanGuidNames = @{
    'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Power saver'
    '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Balanced'
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'High performance'
    'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'Ultimate Performance'
}

function Resolve-PowerPlanName {
    param([Parameter(Mandatory)][string]$SchemeLine)
    # powercfg output is localized (Danish/German/etc.), so the display name in
    # parens can't be matched directly. The scheme GUID is stable regardless of
    # locale, so resolve well-known GUIDs to their canonical English name first.
    if ($SchemeLine -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $guid = $Matches[1].ToLowerInvariant()
        if ($script:PowerPlanGuidNames.ContainsKey($guid)) {
            return $script:PowerPlanGuidNames[$guid]
        }
    }
    # Unknown GUID (custom/OEM plan): fall back to the parenthesised display
    # name. Greedy match so nested parens, e.g. '(HP Optimized (recommended))',
    # aren't truncated at the first closing paren.
    if ($SchemeLine -match '\((?<name>.+)\)') {
        return $Matches['name']
    }
    'unknown'
}

function Get-PowerPlanVerdict {
    param([string]$PlanName = 'unknown', [int]$ThrottleEventCount = 0)
    $results = @()
    if ($PlanName -match 'Power saver') {
        $results += New-DiagResult -Name 'Power plan' -Category 'Power' -Severity 'Problem' `
            -Evidence @("Active plan: $PlanName") `
            -Recommendation 'Switch to the High performance (or at least Balanced) power plan.'
    } elseif ($PlanName -match 'High performance|Ultimate') {
        $results += New-DiagResult -Name 'Power plan' -Category 'Power' -Severity 'OK' `
            -Evidence @("Active plan: $PlanName")
    } else {
        $results += New-DiagResult -Name 'Power plan' -Category 'Power' -Severity 'Info' `
            -Evidence @("Active plan: $PlanName") `
            -Recommendation 'Consider the High performance plan for build machines.'
    }
    if ($ThrottleEventCount -gt 0) {
        $results += New-DiagResult -Name 'CPU throttling events' -Category 'Power' -Severity 'Warning' `
            -Evidence @("$ThrottleEventCount Kernel-Processor-Power throttle events in the System log (last 7 days)") `
            -Recommendation 'CPU is being thermally or firmware throttled. Check cooling, dock/PSU wattage, and BIOS power settings.'
    }
    $results
}

function Get-ProcessorStateVerdict {
    param(
        [Parameter(Mandatory)][int]$MaxAcPct,
        [Parameter(Mandatory)][int]$MinAcPct
    )
    $evidence = @(
        "Max processor state (AC): $MaxAcPct`%"
        "Min processor state (AC): $MinAcPct`%"
    )
    if ($MaxAcPct -lt 70) {
        New-DiagResult -Name 'Processor power limits' -Category 'Power' -Severity 'Problem' -Evidence $evidence `
            -Recommendation "Processor capped at $MaxAcPct`% - builds run correspondingly slower; ask IT to lift the cap."
    } elseif ($MaxAcPct -lt 100) {
        New-DiagResult -Name 'Processor power limits' -Category 'Power' -Severity 'Warning' -Evidence $evidence `
            -Recommendation "Processor capped at $MaxAcPct`% - ask IT to lift the cap for full build performance."
    } else {
        New-DiagResult -Name 'Processor power limits' -Category 'Power' -Severity 'OK' -Evidence $evidence
    }
}

function Get-PendingRebootVerdict {
    param([string[]]$Indicators = @())
    if (@($Indicators).Count -eq 0) {
        New-DiagResult -Name 'Pending reboot' -Category 'OS' -Severity 'OK' `
            -Evidence @('No pending-reboot indicators found')
    } else {
        New-DiagResult -Name 'Pending reboot' -Category 'OS' -Severity 'Warning' `
            -Evidence $Indicators `
            -Recommendation 'Reboot the machine; a half-applied update can degrade performance.'
    }
}

function Get-MemoryVerdict {
    param(
        [Parameter(Mandatory)][double]$TotalMB,
        [Parameter(Mandatory)][double]$FreeMB,
        [string[]]$TopConsumers = @()
    )
    $freePct = [math]::Round(100.0 * $FreeMB / $TotalMB, 1)
    $evidence = @("$([math]::Round($TotalMB/1024,1)) GB total, $([math]::Round($FreeMB/1024,1)) GB free ($freePct`%)")
    $evidence += $TopConsumers
    if ($freePct -lt 10) {
        New-DiagResult -Name 'Memory pressure' -Category 'Memory' -Severity 'Problem' -Evidence $evidence `
            -Recommendation 'Machine is memory-starved; more RAM or fewer resident agents/apps needed.'
    } elseif ($freePct -lt 20) {
        New-DiagResult -Name 'Memory pressure' -Category 'Memory' -Severity 'Warning' -Evidence $evidence `
            -Recommendation 'Memory is tight under load; consider a RAM upgrade for build machines.'
    } else {
        New-DiagResult -Name 'Memory pressure' -Category 'Memory' -Severity 'OK' -Evidence $evidence
    }
}

function Get-DiskSpaceVerdict {
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][double]$FreeGB,
        [Parameter(Mandatory)][double]$TotalGB
    )
    $freePct = [math]::Round(100.0 * $FreeGB / $TotalGB, 1)
    $evidence = @("$DriveLetter`: $([math]::Round($FreeGB,1)) GB free of $([math]::Round($TotalGB,1)) GB ($freePct`%)")
    if ($FreeGB -lt 10) {
        New-DiagResult -Name "Disk space ($DriveLetter`:)" -Category 'Storage' -Severity 'Problem' -Evidence $evidence `
            -Recommendation 'Under 10 GB free; SSD performance and Windows both degrade. Free up space.'
    } elseif ($freePct -lt 15) {
        New-DiagResult -Name "Disk space ($DriveLetter`:)" -Category 'Storage' -Severity 'Warning' -Evidence $evidence `
            -Recommendation 'Low free space can slow SSD writes; free up space.'
    } else {
        New-DiagResult -Name "Disk space ($DriveLetter`:)" -Category 'Storage' -Severity 'OK' -Evidence $evidence
    }
}

# ---------- Benchmark verdicts (heuristic thresholds; unit-tested) ----------

function Get-FileBenchVerdict {
    param([Parameter(Mandatory)]$Bench)
    $perFileWriteMs = [math]::Round($Bench.WriteMs / [double]$Bench.FileCount, 2)
    $evidence = @(
        "Wrote $($Bench.FileCount) small files in $($Bench.WriteMs) ms ($perFileWriteMs ms/file)"
        "Read back in $($Bench.ReadMs) ms; deleted in $($Bench.DeleteMs) ms"
        'Heuristic reference: healthy SSD < 2 ms/file write; heavy AV/EDR scanning commonly shows 5-30 ms/file'
    )
    if ($perFileWriteMs -gt 8) {
        New-DiagResult -Name 'Small-file I/O benchmark' -Category 'Benchmark' -Severity 'Problem' -Evidence $evidence -Headline "$perFileWriteMs ms/file write" `
            -Recommendation 'Small-file writes are far below healthy SSD rates - the signature of per-file security scanning. Request AV/EDR exclusions for build directories and toolchain processes.'
    } elseif ($perFileWriteMs -gt 2) {
        New-DiagResult -Name 'Small-file I/O benchmark' -Category 'Benchmark' -Severity 'Warning' -Evidence $evidence -Headline "$perFileWriteMs ms/file write" `
            -Recommendation 'Small-file writes are slower than a healthy SSD; likely scanning overhead. Compare against the Defender/agent findings above.'
    } else {
        New-DiagResult -Name 'Small-file I/O benchmark' -Category 'Benchmark' -Severity 'OK' -Evidence $evidence -Headline "$perFileWriteMs ms/file write"
    }
}

function Get-SpawnBenchVerdict {
    param([Parameter(Mandatory)]$Bench)
    $evidence = @(
        "Spawned $($Bench.SpawnCount) short-lived processes in $($Bench.TotalMs) ms ($($Bench.PerSpawnMs) ms/spawn)"
        'Heuristic reference: healthy < 30 ms/spawn; EDR process-hooking overhead commonly shows 100-300 ms/spawn'
    )
    if ($Bench.PerSpawnMs -gt 100) {
        New-DiagResult -Name 'Process-spawn benchmark' -Category 'Benchmark' -Severity 'Problem' -Evidence $evidence -Headline "$($Bench.PerSpawnMs) ms/spawn" `
            -Recommendation 'Process creation is heavily taxed - typical of EDR hooking every process. Builds spawn thousands of compiler processes; request toolchain process exclusions.'
    } elseif ($Bench.PerSpawnMs -gt 30) {
        New-DiagResult -Name 'Process-spawn benchmark' -Category 'Benchmark' -Severity 'Warning' -Evidence $evidence -Headline "$($Bench.PerSpawnMs) ms/spawn" `
            -Recommendation 'Process creation is slower than expected; likely agent overhead.'
    } else {
        New-DiagResult -Name 'Process-spawn benchmark' -Category 'Benchmark' -Severity 'OK' -Evidence $evidence -Headline "$($Bench.PerSpawnMs) ms/spawn"
    }
}

# ---------- Benchmark engines (cross-platform; integration-tested) ----------

function Invoke-SmallFileBenchmark {
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [int]$FileCount = 2000,
        [int]$FileSizeBytes = 4096,
        [int]$DirFanout = 50
    )
    $extensions = @('.c', '.h', '.o', '.obj', '.d')
    $payload = New-Object byte[] $FileSizeBytes
    (New-Object System.Random 42).NextBytes($payload)
    for ($d = 0; $d -lt $DirFanout; $d++) {
        $sub = Join-Path $WorkDir ('d{0:D3}' -f $d)
        if (-not (Test-Path $sub)) { New-Item -ItemType Directory -Path $sub | Out-Null }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $FileCount; $i++) {
        # Stamp file index into first bytes of payload to make content unique;
        # defeats AV scan-result caching so each file is scanned independently.
        [System.BitConverter]::GetBytes($i).CopyTo($payload, 0)
        $sub = Join-Path $WorkDir ('d{0:D3}' -f ($i % $DirFanout))
        $ext = $extensions[$i % $extensions.Count]
        [System.IO.File]::WriteAllBytes((Join-Path $sub "f$i$ext"), $payload)
    }
    $writeMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    $sw.Restart()
    for ($d = 0; $d -lt $DirFanout; $d++) {
        foreach ($f in (Get-ChildItem -Path (Join-Path $WorkDir ('d{0:D3}' -f $d)) -File)) {
            [void][System.IO.File]::ReadAllBytes($f.FullName)
        }
    }
    $readMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    $sw.Restart()
    for ($d = 0; $d -lt $DirFanout; $d++) {
        Remove-Item -Path (Join-Path $WorkDir ('d{0:D3}' -f $d)) -Recurse -Force
    }
    $deleteMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    [pscustomobject]@{
        FileCount = $FileCount
        WriteMs   = $writeMs
        ReadMs    = $readMs
        DeleteMs  = $deleteMs
    }
}

function Invoke-ProcessSpawnBenchmark {
    param(
        [int]$SpawnCount = 100,
        [string]$Command = 'cmd.exe',
        [string]$Arguments = '/c exit'
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $SpawnCount; $i++) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Command
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        $p.Dispose()
    }
    $totalMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    [pscustomobject]@{
        SpawnCount = $SpawnCount
        TotalMs    = $totalMs
        PerSpawnMs = [math]::Round($totalMs / [double]$SpawnCount, 1)
    }
}

# ---------- Windows collectors (thin cmdlet wrappers; validated on Windows) ----------

function Test-IsElevated {
    if (-not $script:OnWindows) { return $false }
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object System.Security.Principal.WindowsPrincipal $id).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-InventoryResults {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    # Sum cores/threads across ALL Win32_Processor instances (dual-socket
    # machines report one instance per physical socket); CPU name comes from
    # the first instance since sockets are normally identical.
    $cpus = @(Get-CimInstance -ClassName Win32_Processor)
    $cpuName = $cpus[0].Name
    $totalCores = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
    $totalThreads = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    $uptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
    $evidence = @(
        "OS: $($os.Caption) build $($os.BuildNumber)"
        "CPU: $cpuName ($totalCores cores / $totalThreads threads)"
        "RAM: $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB"
        "Uptime: $uptimeDays days"
    )
    $results = @(New-DiagResult -Name 'Machine inventory' -Category 'Inventory' -Severity 'Info' -Evidence $evidence)
    if ($uptimeDays -gt 30) {
        $results += New-DiagResult -Name 'Long uptime' -Category 'OS' -Severity 'Warning' `
            -Evidence @("Machine has not rebooted for $uptimeDays days") `
            -Recommendation 'Reboot; long uptimes accumulate leaked resources and stalled updates.'
    }
    $results
}

function Get-StorageResults {
    $results = @()
    $diskEvidence = @()
    foreach ($disk in (Get-PhysicalDisk)) {
        $diskEvidence += "Disk: $($disk.FriendlyName) - $($disk.MediaType), $([math]::Round($disk.Size / 1GB)) GB"
    }
    if ($diskEvidence.Count -gt 0) {
        $results += New-DiagResult -Name 'Physical disks' -Category 'Storage' -Severity 'Info' -Evidence $diskEvidence
    }
    # Skip volumes with a zero Size (e.g. unformatted/recovery partitions):
    # dividing by TotalGB=0 in Get-DiskSpaceVerdict would blow up on a NaN/Inf percentage.
    foreach ($vol in (Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 })) {
        $results += Get-DiskSpaceVerdict -DriveLetter $vol.DriveLetter `
            -FreeGB ($vol.SizeRemaining / 1GB) -TotalGB ($vol.Size / 1GB)
    }
    $results
}

function Get-DefenderResults {
    $status = Get-MpComputerStatus
    $prefs = Get-MpPreference
    if (-not $status.RealTimeProtectionEnabled) {
        return New-DiagResult -Name 'Defender real-time protection' -Category 'Security' -Severity 'Info' `
            -Evidence @('Real-time protection is disabled (another AV product is likely primary)')
    }
    # AMRunningMode isn't present on older builds - probe before reading it.
    # 'Passive Mode'/'EDR Block Mode' mean a third-party AV is the primary
    # scanner and Defender's own exclusion gaps aren't the relevant signal.
    if ($status.PSObject.Properties.Name -contains 'AMRunningMode') {
        if ($status.AMRunningMode -eq 'Passive Mode' -or $status.AMRunningMode -eq 'EDR Block Mode') {
            return New-DiagResult -Name 'Defender running mode' -Category 'Security' -Severity 'Info' `
                -Evidence @("Defender AMRunningMode: $($status.AMRunningMode) - Defender is not the primary scanner (another AV product is); exclusion gaps are not evaluated.")
        }
    }
    $devRoots = @($script:DevRootCandidates | Where-Object { Test-Path $_ })
    # Get-MpPreference returns $null (not an empty array) when no exclusions
    # are configured; @($null).Count is 1, so filter out empty/null entries
    # before counting or handing the lists to the gap analysis.
    $exclusionPaths = Select-RealExclusions -Values @($prefs.ExclusionPath)
    $exclusionProcesses = Select-RealExclusions -Values @($prefs.ExclusionProcess)
    $exclusionExtensions = Select-RealExclusions -Values @($prefs.ExclusionExtension)
    $exclusionsWithheld = (Test-ExclusionsWithheld -Values @($prefs.ExclusionPath)) -or
                          (Test-ExclusionsWithheld -Values @($prefs.ExclusionProcess))
    $gaps = Get-DefenderExclusionGaps `
        -ExclusionPaths $exclusionPaths `
        -ExclusionProcesses $exclusionProcesses `
        -DevRoots $devRoots `
        -ToolchainProcesses $script:ToolchainProcesses
    $rootsText = if (@($gaps.UncoveredRoots).Count -gt 0) { $gaps.UncoveredRoots -join ', ' } else { '(none)' }
    $procsText = if (@($gaps.UncoveredProcesses).Count -gt 0) { $gaps.UncoveredProcesses -join ', ' } else { '(none)' }
    $evidence = @(
        "Real-time protection: ON"
        "Path exclusions configured: $($exclusionPaths.Count)"
        "Process exclusions configured: $($exclusionProcesses.Count)"
        "Extension exclusions configured: $($exclusionExtensions.Count)"
        "Dev directories present but NOT excluded: $rootsText"
        "Toolchain processes NOT excluded: $procsText"
    )
    if ($exclusionsWithheld) {
        $evidence += 'Note: Windows withheld the exclusion lists from this run because it is not elevated. The counts above are 0 because the lists were unreadable, not because no exclusions are configured - re-run elevated for a real answer.'
    } elseif ($exclusionPaths.Count -eq 0 -and $exclusionProcesses.Count -eq 0) {
        $evidence += 'Note: exclusion lists can be hidden from local admins by policy (HideExclusionsFromLocalAdmins) - zero configured exclusions may not be real; confirm with IT.'
    }
    if (@($gaps.UncoveredRoots).Count -gt 0 -or @($gaps.UncoveredProcesses).Count -gt 3) {
        New-DiagResult -Name 'Defender exclusion gaps' -Category 'Security' -Severity 'Problem' -Evidence $evidence -Headline "$(@($gaps.UncoveredRoots).Count) dev directories and $(@($gaps.UncoveredProcesses).Count) toolchain processes not excluded" `
            -Recommendation 'Ask IT to add Defender exclusions for the dev/build directories and toolchain processes listed above. Microsoft documents this for dev machines: https://learn.microsoft.com/en-us/defender-endpoint/configure-exclusions-microsoft-defender-antivirus'
    } else {
        New-DiagResult -Name 'Defender exclusions' -Category 'Security' -Severity 'OK' -Evidence $evidence
    }
}

function Get-SecurityAgentResults {
    # EDR agents can lock down their own service objects; Get-Service throws
    # access-denied on those. This is a read-only detection pass, so skip
    # unreadable services rather than aborting the whole check.
    $services = @(Get-Service -ErrorAction SilentlyContinue | Select-Object Name, DisplayName)
    $agents = @(Find-SecurityAgents -Services $services)
    if ($agents.Count -eq 0) {
        return New-DiagResult -Name 'Third-party security agents' -Category 'Security' -Severity 'OK' `
            -Evidence @('No known third-party security/management agents detected')
    }
    $evidence = @($agents | ForEach-Object { "$($_.Product) (services: $($_.Services -join ', '))" })
    New-DiagResult -Name 'Third-party security agents' -Category 'Security' -Severity 'Warning' `
        -Evidence $evidence `
        -Recommendation 'Each agent adds per-file and per-process overhead. If benchmarks below are slow, these agents plus missing exclusions are the prime suspects - ask IT which of them scan build directories.'
}

function Get-PowerResults {
    $planLine = (powercfg /getactivescheme) -join ' '
    $planName = Resolve-PowerPlanName -SchemeLine $planLine
    $since = (Get-Date).AddDays(-7)
    $throttleEvents = @(Get-WinEvent -ErrorAction SilentlyContinue -FilterHashtable @{
        LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37; StartTime = $since
    })
    $results = @(Get-PowerPlanVerdict -PlanName $planName -ThrottleEventCount $throttleEvents.Count)
    # An IT-forced max-processor-state cap below 100% is otherwise invisible
    # to the user. `powercfg /q` label text is localized, so instead of
    # matching a localized "AC" label we take the first line in each output
    # that contains both 'AC' and '0x', then read the LAST hex value on that
    # line (defends against extra hex-looking tokens earlier on the line).
    # This sub-collection is isolated in its own try/catch: a parsing/locale
    # failure here should not take down the rest of the power check - on
    # failure we simply omit the processor-state result.
    try {
        $maxOutput = powercfg /q SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX
        $minOutput = powercfg /q SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN
        $maxAcLine = @($maxOutput | Where-Object { $_ -match 'AC' -and $_ -match '0x' })[0]
        $minAcLine = @($minOutput | Where-Object { $_ -match 'AC' -and $_ -match '0x' })[0]
        $maxHexMatches = [regex]::Matches($maxAcLine, '0x[0-9a-fA-F]+')
        $minHexMatches = [regex]::Matches($minAcLine, '0x[0-9a-fA-F]+')
        $maxAcPct = [Convert]::ToInt32($maxHexMatches[$maxHexMatches.Count - 1].Value, 16)
        $minAcPct = [Convert]::ToInt32($minHexMatches[$minHexMatches.Count - 1].Value, 16)
        $results += Get-ProcessorStateVerdict -MaxAcPct $maxAcPct -MinAcPct $minAcPct
    } catch {
        # Omit the processor-state result; the rest of the power check stands.
    }
    $results
}

function Get-BitLockerResults {
    $volumes = @(Get-BitLockerVolume | Where-Object { $_.VolumeStatus -ne 'FullyDecrypted' })
    if ($volumes.Count -eq 0) {
        return New-DiagResult -Name 'BitLocker' -Category 'Storage' -Severity 'OK' `
            -Evidence @('No encrypted volumes (or BitLocker not in use)')
    }
    $evidence = @($volumes | ForEach-Object {
        "$($_.MountPoint) $($_.VolumeStatus), $($_.EncryptionPercentage)% encrypted, method $($_.EncryptionMethod)"
    })
    $inProgress = @($volumes | Where-Object { $_.VolumeStatus -eq 'EncryptionInProgress' })
    if ($inProgress.Count -gt 0) {
        New-DiagResult -Name 'BitLocker' -Category 'Storage' -Severity 'Warning' -Evidence $evidence `
            -Recommendation 'Encryption is still in progress and competes for disk bandwidth; expect slowness until it completes.'
    } else {
        New-DiagResult -Name 'BitLocker' -Category 'Storage' -Severity 'Info' -Evidence $evidence
    }
}

function Get-SearchIndexerResults {
    $svc = Get-Service -Name WSearch
    New-DiagResult -Name 'Windows Search indexer' -Category 'OS' -Severity 'Info' `
        -Evidence @("WSearch service: $($svc.Status)") `
        -Recommendation 'If source trees are indexed, exclude them (Indexing Options) - the indexer re-scans every build output.'
}

function Get-VbsResults {
    $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard
    if (-not $dg) {
        throw 'Win32_DeviceGuard returned no instances'
    }
    $hvci = @($dg.SecurityServicesRunning) -contains 2
    if ($hvci) {
        New-DiagResult -Name 'Memory integrity (HVCI)' -Category 'OS' -Severity 'Info' `
            -Evidence @('Virtualization-based security with memory integrity is running') `
            -Recommendation 'HVCI costs a few percent on syscall/process-heavy workloads. Worth knowing, rarely the main culprit.'
    } else {
        New-DiagResult -Name 'Memory integrity (HVCI)' -Category 'OS' -Severity 'OK' `
            -Evidence @('HVCI not running')
    }
}

function Get-MemoryResults {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $top = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
        ForEach-Object { "Top consumer: $($_.ProcessName) $([math]::Round($_.WorkingSet64 / 1MB)) MB" })
    # Win32_OperatingSystem.FreePhysicalMemory excludes standby cache, so a
    # healthy machine can look memory-starved. Prefer the locale-independent
    # perf counter class (AvailableMBytes), which includes reclaimable
    # standby cache; fall back to FreePhysicalMemory if that class/query fails.
    $usedFallback = $false
    try {
        $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        if (-not $perf) { throw 'Win32_PerfFormattedData_PerfOS_Memory returned no instance' }
        $freeMB = $perf.AvailableMBytes
    } catch {
        $freeMB = $os.FreePhysicalMemory / 1KB
        $usedFallback = $true
    }
    $result = Get-MemoryVerdict -TotalMB ($os.TotalVisibleMemorySize / 1KB) `
        -FreeMB $freeMB -TopConsumers $top
    if ($usedFallback) {
        $result.Evidence += 'Free-memory figure excludes standby cache and can understate available memory.'
    }
    $result
}

function Get-PendingRebootResults {
    $indicators = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $indicators += 'Component Based Servicing: RebootPending'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $indicators += 'Windows Update: RebootRequired'
    }
    $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    if ($sm -and ($sm.PSObject.Properties.Name -contains 'PendingFileRenameOperations')) {
        $indicators += 'Session Manager: PendingFileRenameOperations'
    }
    Get-PendingRebootVerdict -Indicators $indicators
}

function Get-BenchmarkResults {
    $benchRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DevMachineDiag-bench-$PID"
    New-Item -ItemType Directory -Path $benchRoot -Force | Out-Null
    try {
        $fileBench = Invoke-SmallFileBenchmark -WorkDir $benchRoot -FileCount $BenchFileCount
        $results = @(Get-FileBenchVerdict -Bench $fileBench)
        if ($script:OnWindows) {
            $spawnBench = Invoke-ProcessSpawnBenchmark -SpawnCount $BenchSpawnCount
        } else {
            $spawnBench = Invoke-ProcessSpawnBenchmark -SpawnCount $BenchSpawnCount -Command '/bin/sh' -Arguments '-c "exit 0"'
        }
        $results += Get-SpawnBenchVerdict -Bench $spawnBench
        $results
    } finally {
        Remove-Item -Path $benchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------- Compile benchmark (optional, -CompileBench) ----------

function Get-QuotedArg {
    param([string]$Value)
    '"' + $Value + '"'
}

function Import-MsvcEnvironment {
    # Last-resort toolchain discovery: Visual Studio is installed but no compiler
    # is on PATH (the usual state outside a developer prompt). Imports VsDevCmd's
    # environment into THIS PowerShell process only - it is gone when the script
    # exits and nothing is written to the machine or user environment.
    $pf86 = [System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not $pf86) { return $null }
    $vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    $installPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null | Select-Object -First 1
    if (-not $installPath) { return $null }
    $devCmd = Join-Path $installPath 'Common7\Tools\VsDevCmd.bat'
    if (-not (Test-Path $devCmd)) { return $null }
    $dump = cmd /c "`"$devCmd`" -arch=x64 -no_logo && set" 2>$null
    foreach ($line in $dump) {
        if ($line -match '^([^=]+)=(.*)$') {
            Set-Item -Path ('env:' + $Matches[1]) -Value $Matches[2] -ErrorAction SilentlyContinue
        }
    }
    $cmd = Get-Command 'cl' -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    [pscustomobject]@{
        Name       = 'cl'
        Path       = $cmd.Source
        Style      = 'MSVC'
        DriverMode = ''
        Source     = "MSVC via vswhere ($installPath)"
    }
}

function Resolve-CompileToolchain {
    param([string]$Override = '')

    if ($Override) {
        if (-not (Test-Path $Override)) {
            throw "Compiler not found at -CompileBenchCompiler path: $Override"
        }
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($Override)
        $style = if (@('cl', 'clang-cl') -contains $leaf) { 'MSVC' } else { 'GNU' }
        $driver = if ($leaf -eq 'clang') { '--driver-mode=g++' } else { '' }
        return [pscustomobject]@{
            Name = $leaf; Path = $Override; Style = $style
            DriverMode = $driver; Source = 'explicit -CompileBenchCompiler'
        }
    }

    # cl.exe first: if it is already on PATH the developer is in a VS prompt, so
    # MSVC is what their real builds actually use.
    $candidates = @(
        [pscustomobject]@{ Name = 'cl';       Style = 'MSVC'; DriverMode = '';                  Source = 'MSVC on PATH (developer prompt)' }
        [pscustomobject]@{ Name = 'clang-cl'; Style = 'MSVC'; DriverMode = '';                  Source = 'clang-cl on PATH' }
        [pscustomobject]@{ Name = 'clang++';  Style = 'GNU';  DriverMode = '';                  Source = 'clang++ on PATH' }
        [pscustomobject]@{ Name = 'clang';    Style = 'GNU';  DriverMode = '--driver-mode=g++'; Source = 'clang on PATH (g++ driver mode)' }
        [pscustomobject]@{ Name = 'g++';      Style = 'GNU';  DriverMode = '';                  Source = 'g++ on PATH' }
    )
    foreach ($c in $candidates) {
        $cmd = Get-Command $c.Name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            return [pscustomobject]@{
                Name = $c.Name; Path = $cmd.Source; Style = $c.Style
                DriverMode = $c.DriverMode; Source = $c.Source
            }
        }
    }

    if ($script:OnWindows) {
        $fromVs = Import-MsvcEnvironment
        if ($fromVs) { return $fromVs }
    }

    $searched = ($candidates | ForEach-Object { $_.Name }) -join ', '
    throw ("No C++ compiler found. Searched PATH for: $searched; then Visual Studio via vswhere. " +
           'Use -CompileBenchCompiler <path> to name one explicitly.')
}

function New-CompileBenchProject {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$TuCount = 30,
        [int]$HeaderCount = 8
    )
    $srcDir = Join-Path $Root 'src'
    $incDir = Join-Path $Root 'include'
    New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
    New-Item -ItemType Directory -Path $incDir -Force | Out-Null

    # Headers pull in real standard-library content and instantiate templates, so
    # the front-end does work proportional to a real TU rather than measuring
    # process startup. Every TU includes every header - that repetition is the
    # point, since it is what exercises scan-result caching.
    for ($h = 0; $h -lt $HeaderCount; $h++) {
        $headerText = @"
#pragma once
#include <vector>
#include <string>
#include <map>
#include <algorithm>
#include <memory>

namespace bench$h {

template <typename T, int N>
struct Matrix {
    T cells[N][N];
    Matrix() {
        for (int r = 0; r < N; ++r)
            for (int c = 0; c < N; ++c)
                cells[r][c] = static_cast<T>(r * N + c);
    }
    T trace() const {
        T sum = T();
        for (int i = 0; i < N; ++i) sum += cells[i][i];
        return sum;
    }
};

template <int N>
struct Fib { static const int value = Fib<N - 1>::value + Fib<N - 2>::value; };
template <> struct Fib<0> { static const int value = 0; };
template <> struct Fib<1> { static const int value = 1; };

inline int summarize(const std::vector<std::string>& names) {
    std::map<std::string, int> counts;
    for (std::size_t i = 0; i < names.size(); ++i) {
        counts[names[i]] += static_cast<int>(names[i].size());
    }
    int total = 0;
    for (std::map<std::string, int>::const_iterator it = counts.begin(); it != counts.end(); ++it) {
        total += it->second;
    }
    return total;
}

inline int workload() {
    Matrix<int, 8> m;
    std::vector<std::string> names;
    names.push_back("bench$h");
    std::sort(names.begin(), names.end());
    return m.trace() + Fib<18>::value + summarize(names);
}

}
"@
        Set-Content -Path (Join-Path $incDir "bench$h.h") -Value $headerText -Encoding UTF8
    }

    $includeLines = (0..($HeaderCount - 1) | ForEach-Object { "#include `"bench$_.h`"" }) -join "`n"
    $calls = (0..($HeaderCount - 1) | ForEach-Object { "bench${_}::workload()" }) -join ' + '

    $sources = @()
    for ($t = 0; $t -lt $TuCount; $t++) {
        $tuText = @"
$includeLines

int tu_${t}_entry() {
    return $calls;
}
"@
        $tuPath = Join-Path $srcDir "tu$t.cpp"
        Set-Content -Path $tuPath -Value $tuText -Encoding UTF8
        $sources += $tuPath
    }

    $externs = (0..($TuCount - 1) | ForEach-Object { "int tu_${_}_entry();" }) -join "`n"
    $sum = (0..($TuCount - 1) | ForEach-Object { "tu_${_}_entry()" }) -join ' + '
    $mainText = @"
$externs

int main() {
    return ($sum) & 1;
}
"@
    $mainPath = Join-Path $srcDir 'main.cpp'
    Set-Content -Path $mainPath -Value $mainText -Encoding UTF8
    $sources += $mainPath

    [pscustomobject]@{
        Root        = $Root
        SourceDir   = $srcDir
        IncludeDir  = $incDir
        Sources     = $sources
        MainSource  = $mainPath
        TuCount     = $sources.Count
        HeaderCount = $HeaderCount
    }
}

function Get-CompileCommandLine {
    param(
        [Parameter(Mandatory)][object]$Toolchain,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$ObjPath,
        [Parameter(Mandatory)][string]$IncludeDir
    )
    if ($Toolchain.Style -eq 'MSVC') {
        @('/c', '/nologo', '/EHsc', '/std:c++17',
          ('/I' + (Get-QuotedArg $IncludeDir)),
          ('/Fo' + (Get-QuotedArg $ObjPath)),
          (Get-QuotedArg $Source)) -join ' '
    } else {
        $parts = @()
        if ($Toolchain.DriverMode) { $parts += $Toolchain.DriverMode }
        $parts += @('-c', '-std=c++17',
                    ('-I' + (Get-QuotedArg $IncludeDir)),
                    '-o', (Get-QuotedArg $ObjPath),
                    (Get-QuotedArg $Source))
        $parts -join ' '
    }
}

function Get-LinkCommandLine {
    param(
        [Parameter(Mandatory)][object]$Toolchain,
        [Parameter(Mandatory)][string[]]$ObjPaths,
        [Parameter(Mandatory)][string]$ExePath
    )
    $objs = ($ObjPaths | ForEach-Object { Get-QuotedArg $_ }) -join ' '
    if ($Toolchain.Style -eq 'MSVC') {
        @('/nologo', ('/Fe' + (Get-QuotedArg $ExePath)), $objs) -join ' '
    } else {
        $parts = @()
        if ($Toolchain.DriverMode) { $parts += $Toolchain.DriverMode }
        $parts += @('-o', (Get-QuotedArg $ExePath), $objs)
        $parts -join ' '
    }
}

function Start-CompileProcess {
    param(
        [Parameter(Mandatory)][object]$Toolchain,
        [Parameter(Mandatory)][string]$Arguments
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Toolchain.Path
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # Redirected so compiler chatter does not pollute the console summary. Output
    # is drained after exit; with /nologo a successful TU emits only its filename,
    # far below the pipe buffer, so draining late cannot stall the child.
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    [System.Diagnostics.Process]::Start($psi)
}

function Test-CompileToolchain {
    # Compile one TU before timing anything. A toolchain that cannot build the
    # generated project (clang-cl with no MSVC headers, say) surfaces here as a
    # Skipped check with the compiler's own error, not as a bogus timing.
    param(
        [Parameter(Mandatory)][object]$Toolchain,
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][string]$ObjDir
    )
    New-Item -ItemType Directory -Path $ObjDir -Force | Out-Null
    $cmdline = Get-CompileCommandLine -Toolchain $Toolchain -Source $Project.Sources[0] `
        -ObjPath (Join-Path $ObjDir 'preflight.obj') -IncludeDir $Project.IncludeDir
    $proc = Start-CompileProcess -Toolchain $Toolchain -Arguments $cmdline
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $code = $proc.ExitCode
    $proc.Dispose()
    if ($code -ne 0) {
        $detail = ((($stderr + "`n" + $stdout).Trim() -split "`r?`n") |
            Where-Object { $_ -ne '' } | Select-Object -First 3) -join '; '
        throw "$($Toolchain.Name) could not compile the generated project (exit $code): $detail"
    }
}

function Invoke-CompilePass {
    param(
        [Parameter(Mandatory)][object]$Toolchain,
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][string]$ObjDir,
        [int]$JobCount = 1
    )
    New-Item -ItemType Directory -Path $ObjDir -Force | Out-Null
    $queue = New-Object System.Collections.Queue
    foreach ($s in $Project.Sources) { $queue.Enqueue($s) | Out-Null }
    $running = New-Object System.Collections.ArrayList
    $failed = 0

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($running.Count -lt $JobCount -and $queue.Count -gt 0) {
            $src = $queue.Dequeue()
            $obj = Join-Path $ObjDir ([System.IO.Path]::GetFileNameWithoutExtension($src) + '.obj')
            $cmdline = Get-CompileCommandLine -Toolchain $Toolchain -Source $src -ObjPath $obj -IncludeDir $Project.IncludeDir
            [void]$running.Add((Start-CompileProcess -Toolchain $Toolchain -Arguments $cmdline))
        }
        if ($running.Count -gt 0) {
            $running[0].WaitForExit()
            for ($i = $running.Count - 1; $i -ge 0; $i--) {
                if ($running[$i].HasExited) {
                    [void]$running[$i].StandardOutput.ReadToEnd()
                    [void]$running[$i].StandardError.ReadToEnd()
                    if ($running[$i].ExitCode -ne 0) { $failed++ }
                    $running[$i].Dispose()
                    $running.RemoveAt($i)
                }
            }
        }
    }
    $sw.Stop()
    if ($failed -gt 0) {
        throw "$failed of $($Project.Sources.Count) compiles failed during the benchmark pass."
    }
    [pscustomobject]@{
        ElapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        ObjDir    = $ObjDir
        JobCount  = $JobCount
    }
}

function Invoke-LinkBenchmark {
    param(
        [Parameter(Mandatory)][object]$Toolchain,
        [Parameter(Mandatory)][string]$ObjDir,
        [Parameter(Mandatory)][string]$ExePath
    )
    $objs = @(Get-ChildItem -Path $ObjDir -Filter '*.obj' -File | ForEach-Object { $_.FullName })
    if ($objs.Count -eq 0) { throw 'No object files were produced to link.' }
    $cmdline = Get-LinkCommandLine -Toolchain $Toolchain -ObjPaths $objs -ExePath $ExePath
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-CompileProcess -Toolchain $Toolchain -Arguments $cmdline
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $sw.Stop()
    $code = $proc.ExitCode
    $proc.Dispose()
    if ($code -ne 0) {
        $detail = ((($stderr + "`n" + $stdout).Trim() -split "`r?`n") |
            Where-Object { $_ -ne '' } | Select-Object -First 3) -join '; '
        throw "Link failed (exit $code): $detail"
    }
    # The executable is produced but never run - see RISK-ASSESSMENT.md.
    [pscustomobject]@{
        ElapsedMs   = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        ObjectCount = $objs.Count
    }
}

function Invoke-CompileTraceWorkload {
    # Compile workload for the -DefenderTrace recording, reconstructed from plain
    # strings because it runs inside a background job.
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$CompilerPath,
        [Parameter(Mandatory)][string]$Style,
        [string]$DriverMode = '',
        [int]$TuCount = 30,
        [int]$HeaderCount = 8
    )
    $toolchain = [pscustomobject]@{
        Name       = [System.IO.Path]::GetFileNameWithoutExtension($CompilerPath)
        Path       = $CompilerPath
        Style      = $Style
        DriverMode = $DriverMode
        Source     = 'Defender trace workload'
    }
    $project = New-CompileBenchProject -Root $Root -TuCount $TuCount -HeaderCount $HeaderCount
    Invoke-CompilePass -Toolchain $toolchain -Project $project -ObjDir (Join-Path $Root 'obj-trace') -JobCount 1
}

function Get-BuildScanMs {
    # Scan time Defender spent on behalf of the compiler process, from the
    # trace's TopProcesses. This is a direct measurement of what scanning costs
    # the build, as opposed to inferring it from a timing ratio.
    param(
        [object[]]$TopProcesses = @(),
        [Parameter(Mandatory)][string]$CompilerPath
    )
    $leaf = [System.IO.Path]::GetFileName($CompilerPath)
    $total = 0.0
    foreach ($p in $TopProcesses) {
        if ($null -eq $p) { continue }
        $props = $p.PSObject.Properties
        if (-not $props['ProcessPath']) { continue }
        $path = $p.ProcessPath
        if (-not $path) { continue }
        if ($path -eq $CompilerPath -or [System.IO.Path]::GetFileName($path) -eq $leaf) {
            $total += (Get-TraceDurationMs -Entry $p)
        }
    }
    [math]::Round($total, 1)
}

function Get-BuildScanShareVerdict {
    # The signal the repeat-pass ratio was meant to be, measured rather than
    # inferred: what fraction of compile wall time Defender spent scanning for
    # the compiler. Requires -DefenderTrace; there is no proxy for it.
    param(
        [Parameter(Mandatory)][double]$ScanMs,
        [Parameter(Mandatory)][double]$CompileMs,
        [string]$CompilerName = 'the compiler'
    )
    if ($CompileMs -le 0) {
        return New-DiagResult -Name 'Scan time attributable to the build' -Category 'Benchmark' -Severity 'Skipped' `
            -Evidence @('The traced compile reported no elapsed time, so a share cannot be computed.')
    }
    $share = [math]::Round(($ScanMs / $CompileMs) * 100, 1)
    $evidence = @(
        "Defender scan time on behalf of ${CompilerName}: $ScanMs ms",
        "Traced compile wall time: $CompileMs ms",
        "Share of build time spent in Defender scanning: $share%",
        'Measured from the Defender trace, not inferred from timings. This is the number an exclusions request should be argued on.',
        'Heuristic reference: under 5% means scanning is not the bottleneck; above 20% means exclusions would pay for themselves'
    )
    $headline = "$share% of compile time in Defender scanning"
    if ($share -gt 20) {
        New-DiagResult -Name 'Scan time attributable to the build' -Category 'Benchmark' -Severity 'Problem' `
            -Evidence $evidence -Headline $headline `
            -Recommendation 'Real-time scanning is taking a substantial share of build time. Request Defender exclusions for the toolchain processes and build directories; this measurement is the evidence.'
    } elseif ($share -gt 5) {
        New-DiagResult -Name 'Scan time attributable to the build' -Category 'Benchmark' -Severity 'Warning' `
            -Evidence $evidence -Headline $headline `
            -Recommendation 'Scanning is a measurable but not dominant share of build time. Exclusions would help modestly; weigh that against the reduction in coverage.'
    } else {
        New-DiagResult -Name 'Scan time attributable to the build' -Category 'Benchmark' -Severity 'OK' `
            -Evidence $evidence -Headline $headline
    }
}

function Get-PhysicalCoreCount {
    # Parallel efficiency has to be judged against real cores, not threads or
    # job count: eight jobs on a four-core laptop cannot exceed roughly 4-5x
    # however healthy the machine is, and dividing by the job count would call
    # that a fault. Falls back to the logical count when the real one is not
    # obtainable, which is the old behaviour.
    if (-not $script:OnWindows) { return [System.Environment]::ProcessorCount }
    try {
        $sum = (Get-CimInstance Win32_Processor -ErrorAction Stop |
            Measure-Object -Property NumberOfCores -Sum).Sum
        if ($sum -and [int]$sum -gt 0) { return [int]$sum }
    } catch {
        # Fall through to the logical count.
    }
    [System.Environment]::ProcessorCount
}

function Get-CompileBenchVerdict {
    param([Parameter(Mandatory)][object]$Bench)

    $perTu = [math]::Round($Bench.ColdMs / [double]$Bench.TuCount, 1)
    $warmSpeedup = if ($Bench.WarmMs -gt 0) { [math]::Round($Bench.ColdMs / [double]$Bench.WarmMs, 2) } else { 0 }
    $parSpeedup  = if ($Bench.ParallelMs -gt 0) { [math]::Round($Bench.ColdMs / [double]$Bench.ParallelMs, 2) } else { 0 }
    # Divide by usable cores, not job count. On a machine whose job count
    # exceeds its physical cores the extra jobs are sharing real cores, so the
    # achievable speedup is bounded by the cores, not by the jobs.
    $physical = if ($Bench.PSObject.Properties['PhysicalCores'] -and $Bench.PhysicalCores -gt 0) {
        [int]$Bench.PhysicalCores
    } else { 0 }
    $usableCores = if ($physical -gt 0) { [math]::Min($Bench.JobCount, $physical) } else { $Bench.JobCount }
    $efficiency  = if ($usableCores -gt 0) { [math]::Round($parSpeedup / [double]$usableCores, 2) } else { 0 }

    $results = @()

    # Thresholds raised after measurement on a 12700K: clang-cl over eight
    # headers that each pull in five standard-library headers runs ~440 ms/TU
    # with no interference at all, which the original 400 ms Warning flagged as
    # a fault. They still want calibration across more machines and compilers.
    $throughput = @(
        "Compiler: $($Bench.CompilerName) - $($Bench.CompilerPath)",
        "Toolchain resolved by: $($Bench.ToolchainSource)",
        "Compiled $($Bench.TuCount) translation units sequentially in $($Bench.ColdMs) ms ($perTu ms/TU, first pass)",
        'Heuristic reference: 400-900 ms/TU is normal for this generated project on a modern desktop CPU; above 1800 ms/TU indicates heavy per-file or per-process interference',
        'These thresholds are compiler- and CPU-dependent and are not yet calibrated across a range of machines - read them alongside the scan-time measurement, not on their own'
    )
    if ($perTu -gt 1800) {
        $results += New-DiagResult -Name 'Compile throughput' -Category 'Benchmark' -Severity 'Problem' `
            -Evidence $throughput -Headline "$perTu ms/TU with $($Bench.CompilerName)" `
            -Recommendation 'Compilation is slow enough to dominate build time. Run again with -DefenderTrace to measure how much of it is scanning before concluding anything.'
    } elseif ($perTu -gt 900) {
        $results += New-DiagResult -Name 'Compile throughput' -Category 'Benchmark' -Severity 'Warning' `
            -Evidence $throughput -Headline "$perTu ms/TU with $($Bench.CompilerName)" `
            -Recommendation 'Compilation is slower than this hardware should manage. Run again with -DefenderTrace to see how much of it is scanning.'
    } else {
        $results += New-DiagResult -Name 'Compile throughput' -Category 'Benchmark' -Severity 'OK' `
            -Evidence $throughput -Headline "$perTu ms/TU with $($Bench.CompilerName)"
    }

    # Reported, never a verdict. A full recompile is CPU-bound on parsing, so a
    # repeat pass has almost no I/O to save even on a machine with no scanning
    # at all - measured at 1.00x on a machine whose trace showed Defender taking
    # under 2% of build time. The ratio cannot separate parse cost from scan
    # cost, so it is evidence for a human, not a threshold.
    $results += New-DiagResult -Name 'Compile repeat-pass timing' -Category 'Benchmark' -Severity 'Info' `
        -Headline "Repeat-pass speedup ${warmSpeedup}x" `
        -Evidence @(
            "First pass: $($Bench.ColdMs) ms; immediate repeat of the same sources: $($Bench.WarmMs) ms",
            "Repeat-pass speedup: ${warmSpeedup}x",
            'Context only. A rebuild is dominated by parsing rather than I/O, so a ratio near 1.00x is expected even on a healthy machine and does NOT by itself indicate antivirus interference.',
            'To measure scanning cost directly, run with -DefenderTrace and read the "Scan time attributable to the build" finding.'
        )

    $coreNote = if ($physical -gt 0) {
        "efficiency $efficiency against $usableCores usable cores ($physical physical)"
    } else {
        "efficiency $efficiency against $usableCores jobs (physical core count unavailable)"
    }
    $parallel = @(
        "Sequential: $($Bench.ColdMs) ms; $($Bench.JobCount) concurrent jobs: $($Bench.ParallelMs) ms",
        "Speedup: ${parSpeedup}x - $coreNote",
        'Efficiency is measured against physical cores rather than job count or threads. Eight jobs on a four-core laptop cannot exceed roughly 4-5x however healthy the machine is, so dividing by the job count would report a fault on hardware that is behaving correctly.',
        'Heuristic reference: efficiency below 0.40 suggests a serialising bottleneck - AV/EDR contention, disk, or thermal throttling. Values near or above 1.0 are normal where hyperthreading is contributing.'
    )
    if ($efficiency -lt 0.40) {
        $results += New-DiagResult -Name 'Parallel compile scaling' -Category 'Benchmark' -Severity 'Warning' -Evidence $parallel -Headline "${parSpeedup}x on $usableCores cores (efficiency $efficiency)" `
            -Recommendation 'Parallel builds are not scaling with core count. Check the power and throttling findings, then AV/EDR contention.'
    } else {
        $results += New-DiagResult -Name 'Parallel compile scaling' -Category 'Benchmark' -Severity 'OK' -Evidence $parallel -Headline "${parSpeedup}x on $usableCores cores (efficiency $efficiency)"
    }

    $results
}

function Get-LinkBenchVerdict {
    param([Parameter(Mandatory)][object]$Bench)

    $evidence = @(
        "Linked $($Bench.ObjectCount) objects into one executable in $($Bench.LinkMs) ms",
        'Link output is a PE file, which real-time AV inspects far more deeply than object or source files.',
        'Heuristic reference: healthy < 1500 ms for a project this size; > 4000 ms points at scan-on-write of the produced binary'
    )
    if ($Bench.LinkMs -gt 4000) {
        New-DiagResult -Name 'Link benchmark' -Category 'Benchmark' -Severity 'Problem' -Evidence $evidence -Headline "$($Bench.ObjectCount) objects in $($Bench.LinkMs) ms" `
            -Recommendation 'Linking is being heavily penalised. Ask for the build output directory to be excluded from real-time scanning.'
    } elseif ($Bench.LinkMs -gt 1500) {
        New-DiagResult -Name 'Link benchmark' -Category 'Benchmark' -Severity 'Warning' -Evidence $evidence -Headline "$($Bench.ObjectCount) objects in $($Bench.LinkMs) ms" `
            -Recommendation 'Link times are elevated; excluding the build output directory should help.'
    } else {
        New-DiagResult -Name 'Link benchmark' -Category 'Benchmark' -Severity 'OK' -Evidence $evidence -Headline "$($Bench.ObjectCount) objects in $($Bench.LinkMs) ms"
    }
}

function Get-CompileBenchResults {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) "DevMachineDiag-compile-$PID"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $toolchain = Resolve-CompileToolchain -Override $CompileBenchCompiler
        Write-Host "Compile benchmark: using $($toolchain.Name) ($($toolchain.Source))..." -ForegroundColor Cyan
        $project = New-CompileBenchProject -Root $root -TuCount $CompileBenchTuCount -HeaderCount $CompileBenchHeaderCount
        Test-CompileToolchain -Toolchain $toolchain -Project $project -ObjDir (Join-Path $root 'preflight')

        $cold = Invoke-CompilePass -Toolchain $toolchain -Project $project -ObjDir (Join-Path $root 'obj-cold') -JobCount 1
        $warm = Invoke-CompilePass -Toolchain $toolchain -Project $project -ObjDir (Join-Path $root 'obj-warm') -JobCount 1
        $jobs = [math]::Min([System.Environment]::ProcessorCount, 8)
        $par  = Invoke-CompilePass -Toolchain $toolchain -Project $project -ObjDir (Join-Path $root 'obj-par') -JobCount $jobs
        $link = Invoke-LinkBenchmark -Toolchain $toolchain -ObjDir $cold.ObjDir -ExePath (Join-Path $root 'benchout.exe')

        $bench = [pscustomobject]@{
            CompilerName    = $toolchain.Name
            CompilerPath    = $toolchain.Path
            ToolchainSource = $toolchain.Source
            TuCount         = $project.TuCount
            ColdMs          = $cold.ElapsedMs
            WarmMs          = $warm.ElapsedMs
            ParallelMs      = $par.ElapsedMs
            JobCount        = $jobs
            PhysicalCores   = Get-PhysicalCoreCount
            LinkMs          = $link.ElapsedMs
            ObjectCount     = $link.ObjectCount
        }
        @(Get-CompileBenchVerdict -Bench $bench) + @(Get-LinkBenchVerdict -Bench $bench)
    } finally {
        Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------- Defender performance trace (optional, -DefenderTrace) ----------

function Get-TraceDurationMs {
    # Get-MpPerformanceReport reports durations as TimeSpan (TotalDuration), not
    # as a millisecond number. Accepts either shape, and a plain number, so the
    # formatter does not depend on one Defender version's property names.
    param([object]$Entry)
    if ($null -eq $Entry) { return 0 }
    $props = $Entry.PSObject.Properties
    foreach ($name in 'TotalDurationMs', 'TotalDuration', 'Duration') {
        if ($props[$name]) {
            $value = $Entry.$name
            if ($null -eq $value) { continue }
            if ($value -is [timespan]) { return $value.TotalMilliseconds }
            return [double]$value
        }
    }
    0
}

function Get-TraceScanCount {
    param([object]$Entry)
    if ($null -eq $Entry) { return 0 }
    $props = $Entry.PSObject.Properties
    foreach ($name in 'Count', 'ScanCount') {
        if ($props[$name] -and $null -ne $Entry.$name) { return [int]$Entry.$name }
    }
    0
}

function Format-DefenderTraceEvidence {
    param([object[]]$TopFiles = @(), [object[]]$TopProcesses = @(), [object[]]$TopExtensions = @())
    if (@($TopFiles).Count -eq 0 -and @($TopProcesses).Count -eq 0 -and @($TopExtensions).Count -eq 0) {
        , @('Defender recorded no scan activity during the benchmark window.')
    } else {
        $evidence = @()
        foreach ($f in $TopFiles) {
            $scans = Get-TraceScanCount -Entry $f
            $suffix = if ($scans -gt 0) { " over $scans scans" } else { '' }
            $evidence += "Scanned file: $($f.Path) - $([math]::Round((Get-TraceDurationMs -Entry $f))) ms total scan time$suffix"
        }
        foreach ($p in $TopProcesses) {
            $scans = Get-TraceScanCount -Entry $p
            $suffix = if ($scans -gt 0) { " over $scans scans" } else { '' }
            $evidence += "Scanned on behalf of process: $($p.ProcessPath) - $([math]::Round((Get-TraceDurationMs -Entry $p))) ms$suffix"
        }
        foreach ($e in $TopExtensions) {
            $scans = Get-TraceScanCount -Entry $e
            $suffix = if ($scans -gt 0) { " over $scans scans" } else { '' }
            $evidence += "Extension $($e.Extension) - $([math]::Round((Get-TraceDurationMs -Entry $e))) ms$suffix"
        }
        $evidence
    }
}

function Get-DefenderTraceResults {
    if (-not (Get-Command New-MpPerformanceRecording -ErrorAction SilentlyContinue)) {
        throw 'New-MpPerformanceRecording not available (needs Windows 10 2004+ with Defender)'
    }
    $etl = Join-Path ([System.IO.Path]::GetTempPath()) "DevMachineDiag-defender-$PID.etl"
    $benchRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DevMachineDiag-trace-bench-$PID"
    New-Item -ItemType Directory -Path $benchRoot -Force | Out-Null
    $job = $null
    try {
        # With -CompileBench, record over the compile workload instead. Attributing
        # scan time to cl.exe, .obj files and real header paths is far stronger
        # evidence for an exclusions request than synthetic blobs are, and it is
        # what makes the scan-share measurement below possible.
        $traceToolchain = $null
        if ($CompileBench) {
            try { $traceToolchain = Resolve-CompileToolchain -Override $CompileBenchCompiler }
            catch { $traceToolchain = $null }
        }
        $workloadName = if ($traceToolchain) { "compile benchmark ($($traceToolchain.Name))" } else { 'file benchmark' }
        Write-Host "Recording Defender activity for 30 s while re-running the $workloadName..." -ForegroundColor Cyan
        $job = Start-Job -ScriptBlock {
            param($ScriptPath, $Dir, $Count, $CompilerPath, $Style, $DriverMode, $TuCount, $HeaderCount)
            . $ScriptPath -LibraryMode
            if ($CompilerPath) {
                Invoke-CompileTraceWorkload -Root $Dir -CompilerPath $CompilerPath -Style $Style `
                    -DriverMode $DriverMode -TuCount $TuCount -HeaderCount $HeaderCount
            } else {
                Invoke-SmallFileBenchmark -WorkDir $Dir -FileCount $Count | Out-Null
            }
        } -ArgumentList $PSCommandPath, $benchRoot, $BenchFileCount,
            $(if ($traceToolchain) { $traceToolchain.Path } else { '' }),
            $(if ($traceToolchain) { $traceToolchain.Style } else { '' }),
            $(if ($traceToolchain) { $traceToolchain.DriverMode } else { '' }),
            $CompileBenchTuCount, $CompileBenchHeaderCount
        New-MpPerformanceRecording -RecordTo $etl -Seconds 30 | Out-Null
        Wait-Job $job -Timeout 60 | Out-Null
        $workloadResult = @(Receive-Job $job -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_ -and $_.PSObject.Properties['ElapsedMs'] }) | Select-Object -First 1

        $report = Get-MpPerformanceReport -Path $etl -TopFiles 5 -TopProcesses 5 -TopExtensions 5
        $evidence = Format-DefenderTraceEvidence `
            -TopFiles @($report.TopFiles) `
            -TopProcesses @($report.TopProcesses) `
            -TopExtensions @($report.TopExtensions)
        $evidence = @("Workload traced: $workloadName") + $evidence

        $results = @(
            New-DiagResult -Name 'Defender performance trace' -Category 'Security' -Severity 'Info' `
                -Evidence $evidence `
                -Recommendation 'This is first-party Microsoft data on what Defender spent scan time on. If build files/toolchain dominate, it directly justifies the exclusion request.'
        )
        if ($traceToolchain -and $workloadResult) {
            $scanMs = Get-BuildScanMs -TopProcesses @($report.TopProcesses) -CompilerPath $traceToolchain.Path
            $results += Get-BuildScanShareVerdict -ScanMs $scanMs `
                -CompileMs ([double]$workloadResult.ElapsedMs) -CompilerName $traceToolchain.Name
        }
        $results
    } finally {
        if ($job) {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -Path $etl -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $benchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------- Pre-flight check (-PreFlight) ----------

function Get-PreFlightVerdicts {
    # Pure: takes the facts, returns verdicts. Answers one question - will a
    # full run work on this machine, and which parts will be missing - without
    # measuring anything. Worth having because the two things most likely to
    # stop the script on a managed machine are policy, not hardware, and
    # neither is fixed by running elevated.
    param(
        [string]$LanguageMode = 'FullLanguage',
        [string]$MachinePolicy = 'Undefined',
        [string]$UserPolicy = 'Undefined',
        [bool]$Elevated = $false,
        [string]$AmRunningMode = '',
        [bool]$TraceCmdletPresent = $false,
        [string]$CompilerName = '',
        [string]$PSVersion = ''
    )
    $results = @()

    if ($LanguageMode -eq 'FullLanguage') {
        $results += New-DiagResult -Name 'PowerShell language mode' -Category 'Pre-flight' -Severity 'OK' `
            -Evidence @("Language mode: $LanguageMode") -Headline $LanguageMode
    } else {
        $results += New-DiagResult -Name 'PowerShell language mode' -Category 'Pre-flight' -Severity 'Problem' `
            -Evidence @(
                "Language mode: $LanguageMode (needs FullLanguage)",
                'WDAC or AppLocker is enforcing Constrained Language Mode. The script uses .NET types and New-Object throughout and will fail almost immediately.',
                'This is a policy setting, not a privilege one - running elevated does not lift it.'
            ) -Headline $LanguageMode `
            -Recommendation 'Ask IT whether this script can be run from an allow-listed path, or have it signed and allow-listed.'
    }

    $blocking = @('AllSigned', 'Restricted')
    $policyEvidence = @("MachinePolicy: $MachinePolicy", "UserPolicy: $UserPolicy")
    if (($blocking -contains $MachinePolicy) -or ($blocking -contains $UserPolicy)) {
        $offender = if ($blocking -contains $MachinePolicy) { "MachinePolicy=$MachinePolicy" } else { "UserPolicy=$UserPolicy" }
        $results += New-DiagResult -Name 'Execution policy' -Category 'Pre-flight' -Severity 'Problem' `
            -Evidence ($policyEvidence + @(
                'A policy scope set by Group Policy outranks -ExecutionPolicy Bypass, and outranks an elevated session too.'
            )) -Headline $offender `
            -Recommendation 'The documented invocation will not run. The script needs signing, or an exception from IT.'
    } else {
        $results += New-DiagResult -Name 'Execution policy' -Category 'Pre-flight' -Severity 'OK' `
            -Evidence $policyEvidence -Headline 'not blocked by policy'
    }

    if ($Elevated) {
        $results += New-DiagResult -Name 'Elevation' -Category 'Pre-flight' -Severity 'OK' `
            -Evidence @('Running elevated: True') -Headline 'elevated'
    } else {
        $results += New-DiagResult -Name 'Elevation' -Category 'Pre-flight' -Severity 'Warning' `
            -Evidence @(
                'Running elevated: False',
                'BitLocker status will be Skipped, the Defender exclusion lists will be unreadable, and -DefenderTrace will not run.'
            ) -Headline 'not elevated' `
            -Recommendation 'Re-run from an elevated PowerShell for the full set of checks.'
    }

    if ($AmRunningMode -eq 'Normal') {
        $results += New-DiagResult -Name 'Defender running mode' -Category 'Pre-flight' -Severity 'OK' `
            -Evidence @('AMRunningMode: Normal - Defender is the primary scanner, so scan time can be measured.') `
            -Headline 'Normal'
    } elseif ($AmRunningMode) {
        $results += New-DiagResult -Name 'Defender running mode' -Category 'Pre-flight' -Severity 'Warning' `
            -Evidence @(
                "AMRunningMode: $AmRunningMode - a third-party agent is the primary scanner.",
                'Scan time attributable to the build cannot be measured: New-MpPerformanceRecording instruments Defender, and Defender is not the one scanning. There is no equivalent for third-party agents.',
                'The comparative benchmarks still work - compare them against the reference numbers in the README.'
            ) -Headline $AmRunningMode
    } else {
        $results += New-DiagResult -Name 'Defender running mode' -Category 'Pre-flight' -Severity 'Info' `
            -Evidence @('Could not determine the Defender running mode on this machine.') -Headline 'unknown'
    }

    $traceUsable = $TraceCmdletPresent -and $Elevated -and ($AmRunningMode -eq 'Normal')
    if ($traceUsable) {
        $results += New-DiagResult -Name '-DefenderTrace' -Category 'Pre-flight' -Severity 'OK' `
            -Evidence @('New-MpPerformanceRecording is available, the session is elevated, and Defender is primary.') `
            -Headline 'available'
    } else {
        $why = @()
        if (-not $TraceCmdletPresent) { $why += 'New-MpPerformanceRecording not present (needs Windows 10 2004+ with a current Defender platform)' }
        if (-not $Elevated) { $why += 'not elevated' }
        if ($AmRunningMode -and $AmRunningMode -ne 'Normal') { $why += "Defender is in $AmRunningMode" }
        if ($why.Count -eq 0) { $why += 'Defender running mode could not be confirmed' }
        $results += New-DiagResult -Name '-DefenderTrace' -Category 'Pre-flight' -Severity 'Warning' `
            -Evidence @("Unavailable: $($why -join '; ')") -Headline 'unavailable'
    }

    if ($CompilerName) {
        $results += New-DiagResult -Name '-CompileBench' -Category 'Pre-flight' -Severity 'OK' `
            -Evidence @("Compiler found: $CompilerName") -Headline $CompilerName
    } else {
        $results += New-DiagResult -Name '-CompileBench' -Category 'Pre-flight' -Severity 'Warning' `
            -Evidence @(
                'No C++ compiler found on PATH, and no Visual Studio installation via vswhere.',
                'The compile benchmark would be reported as Skipped. Every other check still runs.'
            ) -Headline 'no compiler' `
            -Recommendation 'Run from a Visual Studio developer prompt, or pass -CompileBenchCompiler <path>.'
    }

    if ($PSVersion) {
        $results += New-DiagResult -Name 'PowerShell version' -Category 'Pre-flight' -Severity 'Info' `
            -Evidence @("PowerShell $PSVersion") -Headline $PSVersion
    }

    $results
}

function Get-PreFlightResults {
    $languageMode = [string]$ExecutionContext.SessionState.LanguageMode

    $machinePolicy = 'Undefined'
    $userPolicy = 'Undefined'
    try {
        foreach ($p in (Get-ExecutionPolicy -List -ErrorAction Stop)) {
            if ($p.Scope -eq 'MachinePolicy') { $machinePolicy = [string]$p.ExecutionPolicy }
            if ($p.Scope -eq 'UserPolicy') { $userPolicy = [string]$p.ExecutionPolicy }
        }
    } catch {
        # Leave both Undefined; the verdict treats that as not blocking.
    }

    $amMode = ''
    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        if ($status.PSObject.Properties['AMRunningMode'] -and $status.AMRunningMode) {
            $amMode = [string]$status.AMRunningMode
        } elseif ($status.RealTimeProtectionEnabled) {
            $amMode = 'Normal'
        }
    } catch {
        # Not Windows, or Defender absent - reported as unknown.
    }

    $compilerName = ''
    try { $compilerName = (Resolve-CompileToolchain -Override $CompileBenchCompiler).Name } catch { }

    Get-PreFlightVerdicts `
        -LanguageMode $languageMode `
        -MachinePolicy $machinePolicy `
        -UserPolicy $userPolicy `
        -Elevated (Test-IsElevated) `
        -AmRunningMode $amMode `
        -TraceCmdletPresent ([bool](Get-Command New-MpPerformanceRecording -ErrorAction SilentlyContinue)) `
        -CompilerName $compilerName `
        -PSVersion ([string]$PSVersionTable.PSVersion)
}

function Write-PreFlightSummary {
    param([Parameter(Mandatory)][object[]]$Results)
    $colors = @{ Problem = 'Red'; Warning = 'Yellow'; Info = 'Cyan'; OK = 'Green'; Skipped = 'DarkGray' }
    foreach ($r in ($Results | Sort-Object { $script:SeverityOrder[$_.Severity] })) {
        Write-Host ('[{0,-7}] {1}: {2}' -f $r.Severity.ToUpper(), $r.Name, (Get-DiagHeadline -Result $r)) `
            -ForegroundColor $colors[$r.Severity]
        if ($r.Severity -eq 'Problem' -or $r.Severity -eq 'Warning') {
            foreach ($e in $r.Evidence) { Write-Host "          $e" -ForegroundColor DarkGray }
            if ($r.Recommendation) { Write-Host "          -> $($r.Recommendation)" -ForegroundColor DarkGray }
        }
    }
}

# ---------- Entry point ----------

function Invoke-Main {
    $hostName = [System.Environment]::MachineName
    if ($PreFlight) {
        Write-Host "Pre-flight check on $hostName - nothing is measured, nothing is written." -ForegroundColor Cyan
        Write-Host ''
        $preflight = @(Invoke-DiagCheck -Name 'Pre-flight' -Category 'Pre-flight' -Body { Get-PreFlightResults })
        Write-PreFlightSummary -Results $preflight
        Write-Host ''
        $blockers = @($preflight | Where-Object { $_.Severity -eq 'Problem' })
        if ($blockers.Count -gt 0) {
            Write-Host "A full run will NOT work here: $(($blockers | ForEach-Object { $_.Name }) -join ', ')." -ForegroundColor Red
            exit 1
        }
        $degraded = @($preflight | Where-Object { $_.Severity -eq 'Warning' })
        if ($degraded.Count -gt 0) {
            Write-Host "Clear to run, with $($degraded.Count) check(s) degraded - see above." -ForegroundColor Yellow
        } else {
            Write-Host 'Clear to run, with everything available.' -ForegroundColor Green
        }
        exit 0
    }
    Write-Host "Diagnose-DevMachine on $hostName - read-only diagnostic, ~2 minutes." -ForegroundColor Cyan
    $elevated = Test-IsElevated
    if (-not $elevated) {
        Write-Host 'Not running elevated: BitLocker status will be unavailable and some Defender policy details may be hidden.' -ForegroundColor Yellow
    }
    $results = @()
    $results += New-DiagResult -Name 'Elevation' -Category 'OS' -Severity 'Info' `
        -Evidence @("Running elevated: $elevated")
    $results += Invoke-DiagCheck -Name 'Machine inventory' -Category 'Inventory' -Body { Get-InventoryResults }
    $results += Invoke-DiagCheck -Name 'Storage' -Category 'Storage' -Body { Get-StorageResults }
    $results += Invoke-DiagCheck -Name 'Defender exclusions' -Category 'Security' -Body { Get-DefenderResults }
    $results += Invoke-DiagCheck -Name 'Third-party security agents' -Category 'Security' -Body { Get-SecurityAgentResults }
    $results += Invoke-DiagCheck -Name 'Power plan' -Category 'Power' -Body { Get-PowerResults }
    $results += Invoke-DiagCheck -Name 'BitLocker' -Category 'Storage' -Body { Get-BitLockerResults }
    $results += Invoke-DiagCheck -Name 'Windows Search indexer' -Category 'OS' -Body { Get-SearchIndexerResults }
    $results += Invoke-DiagCheck -Name 'Memory integrity (HVCI)' -Category 'OS' -Body { Get-VbsResults }
    $results += Invoke-DiagCheck -Name 'Memory pressure' -Category 'Memory' -Body { Get-MemoryResults }
    $results += Invoke-DiagCheck -Name 'Pending reboot' -Category 'OS' -Body { Get-PendingRebootResults }
    Write-Host 'Running benchmarks (moderate disk/CPU load for a minute or two)...' -ForegroundColor Cyan
    $results += Invoke-DiagCheck -Name 'Benchmarks' -Category 'Benchmark' -Body { Get-BenchmarkResults }
    if ($CompileBench) {
        $results += Invoke-DiagCheck -Name 'Compile benchmark' -Category 'Benchmark' -Body { Get-CompileBenchResults }
    }
    if ($DefenderTrace) {
        $results += Invoke-DiagCheck -Name 'Defender performance trace' -Category 'Security' -Body { Get-DefenderTraceResults }
    }
    Write-Host ''
    Write-ConsoleSummary -Results $results
    $timestamp = Get-Date
    # Write the report next to the script itself, not the current directory:
    # an elevated shell often starts in C:\Windows\system32, and running the
    # script by full path from there would otherwise drop the report there.
    $scriptDir = Split-Path -Parent $PSCommandPath
    $reportPath = Join-Path $scriptDir "DevMachineDiag-$hostName-$($timestamp.ToString('yyyyMMdd-HHmmss')).md"
    Format-DiagReport -Results $results -ComputerName $hostName -Timestamp $timestamp |
        Set-Content -Path $reportPath -Encoding UTF8
    Write-Host ''
    Write-Host "Report written to $reportPath - share it with IT." -ForegroundColor Cyan
    exit 0
}

if (-not $LibraryMode) { Invoke-Main }
