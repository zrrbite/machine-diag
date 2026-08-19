<#
.SYNOPSIS
    Diagnoses common causes of slow builds/dev work on corporate Windows machines.
.DESCRIPTION
    Read-only diagnostic: collects configuration evidence and runs compile-shaped
    micro-benchmarks, then writes a ranked Markdown report for IT.
    Changes NOTHING on the machine. See RISK-ASSESSMENT.md.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Diagnose-DevMachine.ps1
#>
[CmdletBinding()]
param(
    [switch]$DefenderTrace,
    [switch]$LibraryMode,
    [int]$BenchFileCount = 2000,
    [int]$BenchSpawnCount = 100
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
        [string]$Recommendation = ''
    )
    [pscustomobject]@{
        Name           = $Name
        Category       = $Category
        Severity       = $Severity
        Evidence       = $Evidence
        Recommendation = $Recommendation
    }
}

function Invoke-DiagCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    try {
        & $Body
    } catch {
        New-DiagResult -Name $Name -Category $Category -Severity 'Skipped' `
            -Evidence @("Check failed: $($_.Exception.Message)")
    }
}

function Format-DiagReport {
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][datetime]$Timestamp
    )
    $sorted = $Results | Sort-Object { $script:SeverityOrder[$_.Severity] }, Category
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
        "**Summary:** $counts"
    )
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
        New-DiagResult -Name 'Small-file I/O benchmark' -Category 'Benchmark' -Severity 'Problem' -Evidence $evidence `
            -Recommendation 'Small-file writes are far below healthy SSD rates - the signature of per-file security scanning. Request AV/EDR exclusions for build directories and toolchain processes.'
    } elseif ($perFileWriteMs -gt 2) {
        New-DiagResult -Name 'Small-file I/O benchmark' -Category 'Benchmark' -Severity 'Warning' -Evidence $evidence `
            -Recommendation 'Small-file writes are slower than a healthy SSD; likely scanning overhead. Compare against the Defender/agent findings above.'
    } else {
        New-DiagResult -Name 'Small-file I/O benchmark' -Category 'Benchmark' -Severity 'OK' -Evidence $evidence
    }
}

function Get-SpawnBenchVerdict {
    param([Parameter(Mandatory)]$Bench)
    $evidence = @(
        "Spawned $($Bench.SpawnCount) short-lived processes in $($Bench.TotalMs) ms ($($Bench.PerSpawnMs) ms/spawn)"
        'Heuristic reference: healthy < 30 ms/spawn; EDR process-hooking overhead commonly shows 100-300 ms/spawn'
    )
    if ($Bench.PerSpawnMs -gt 100) {
        New-DiagResult -Name 'Process-spawn benchmark' -Category 'Benchmark' -Severity 'Problem' -Evidence $evidence `
            -Recommendation 'Process creation is heavily taxed - typical of EDR hooking every process. Builds spawn thousands of compiler processes; request toolchain process exclusions.'
    } elseif ($Bench.PerSpawnMs -gt 30) {
        New-DiagResult -Name 'Process-spawn benchmark' -Category 'Benchmark' -Severity 'Warning' -Evidence $evidence `
            -Recommendation 'Process creation is slower than expected; likely agent overhead.'
    } else {
        New-DiagResult -Name 'Process-spawn benchmark' -Category 'Benchmark' -Severity 'OK' -Evidence $evidence
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
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $uptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
    $evidence = @(
        "OS: $($os.Caption) build $($os.BuildNumber)"
        "CPU: $($cpu.Name) ($($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads)"
        "RAM: $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB"
        "Uptime: $uptimeDays days"
    )
    foreach ($disk in (Get-PhysicalDisk)) {
        $evidence += "Disk: $($disk.FriendlyName) - $($disk.MediaType), $([math]::Round($disk.Size / 1GB)) GB"
    }
    $results = @(New-DiagResult -Name 'Machine inventory' -Category 'Inventory' -Severity 'Info' -Evidence $evidence)
    if ($uptimeDays -gt 30) {
        $results += New-DiagResult -Name 'Long uptime' -Category 'OS' -Severity 'Warning' `
            -Evidence @("Machine has not rebooted for $uptimeDays days") `
            -Recommendation 'Reboot; long uptimes accumulate leaked resources and stalled updates.'
    }
    foreach ($vol in (Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' })) {
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
    $devRoots = @($script:DevRootCandidates | Where-Object { Test-Path $_ })
    $gaps = Get-DefenderExclusionGaps `
        -ExclusionPaths @($prefs.ExclusionPath) `
        -ExclusionProcesses @($prefs.ExclusionProcess) `
        -DevRoots $devRoots `
        -ToolchainProcesses $script:ToolchainProcesses
    $evidence = @(
        "Real-time protection: ON"
        "Path exclusions configured: $(@($prefs.ExclusionPath).Count)"
        "Process exclusions configured: $(@($prefs.ExclusionProcess).Count)"
        "Dev directories present but NOT excluded: $($gaps.UncoveredRoots -join ', ')"
        "Toolchain processes NOT excluded: $($gaps.UncoveredProcesses -join ', ')"
    )
    if (@($gaps.UncoveredRoots).Count -gt 0 -or @($gaps.UncoveredProcesses).Count -gt 3) {
        New-DiagResult -Name 'Defender exclusion gaps' -Category 'Security' -Severity 'Problem' -Evidence $evidence `
            -Recommendation 'Ask IT to add Defender exclusions for the dev/build directories and toolchain processes listed above. Microsoft documents this for dev machines: https://learn.microsoft.com/en-us/defender-endpoint/configure-exclusions-microsoft-defender-antivirus'
    } else {
        New-DiagResult -Name 'Defender exclusions' -Category 'Security' -Severity 'OK' -Evidence $evidence
    }
}

function Get-SecurityAgentResults {
    $services = @(Get-Service | Select-Object Name, DisplayName)
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
    $planName = 'unknown'
    if ($planLine -match '\((?<name>[^)]+)\)') { $planName = $Matches['name'] }
    $since = (Get-Date).AddDays(-7)
    $throttleEvents = @(Get-WinEvent -ErrorAction SilentlyContinue -FilterHashtable @{
        LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37; StartTime = $since
    })
    Get-PowerPlanVerdict -PlanName $planName -ThrottleEventCount $throttleEvents.Count
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
    Get-MemoryVerdict -TotalMB ($os.TotalVisibleMemorySize / 1KB) `
        -FreeMB ($os.FreePhysicalMemory / 1KB) -TopConsumers $top
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

# ---------- Entry point ----------

function Invoke-Main {
    $hostName = [System.Environment]::MachineName
    Write-Host "Diagnose-DevMachine on $hostName - read-only diagnostic, ~2 minutes." -ForegroundColor Cyan
    if (-not (Test-IsElevated)) {
        Write-Host 'Not running elevated: Defender, BitLocker and event-log checks will be skipped.' -ForegroundColor Yellow
    }
    $results = @()
    $results += Invoke-DiagCheck -Name 'Machine inventory' -Category 'Inventory' -Body { Get-InventoryResults }
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
    if ($DefenderTrace) {
        $results += Invoke-DiagCheck -Name 'Defender performance trace' -Category 'Security' -Body { Get-DefenderTraceResults }
    }
    Write-Host ''
    Write-ConsoleSummary -Results $results
    $timestamp = Get-Date
    $reportPath = Join-Path (Get-Location) "DevMachineDiag-$hostName-$($timestamp.ToString('yyyyMMdd-HHmm')).md"
    Format-DiagReport -Results $results -ComputerName $hostName -Timestamp $timestamp |
        Set-Content -Path $reportPath -Encoding UTF8
    Write-Host ''
    Write-Host "Report written to $reportPath - share it with IT." -ForegroundColor Cyan
    exit 0
}

if (-not $LibraryMode) { Invoke-Main }
