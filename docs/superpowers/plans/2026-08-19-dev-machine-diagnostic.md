# Windows Dev-Machine Slowness Diagnostic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single-file PowerShell diagnostic that devs run elevated on slow corporate Windows machines, producing a ranked evidence report for IT, plus a risk-assessment doc.

**Architecture:** One script, `Diagnose-DevMachine.ps1`, internally split into *collectors* (thin wrappers over Windows cmdlets, untestable on macOS) and *evaluators* (pure functions: data in → `DiagResult` out, fully Pester-tested locally). A `-LibraryMode` switch lets tests dot-source the script without running it. Development happens on macOS using a repo-local PowerShell 7 in `.tools/` (git-ignored).

**Tech Stack:** PowerShell (script must stay Windows PowerShell 5.1-compatible), Pester 5, PSScriptAnalyzer.

## Global Constraints

- Script must run on stock **Windows PowerShell 5.1** — no `?:` ternary, no `??`, no `$IsWindows` assumption (define `$script:OnWindows` guard).
- **Read-only**: never modify system config, never toggle AV; only writes are the benchmark temp folder (deleted afterwards) and the report file.
- **No network access** anywhere in the script.
- Every check wrapped so failure → `Skipped` result, never an aborted run.
- All local test/verification commands use the repo-local `./.tools/pwsh/pwsh`.
- Spec: `docs/superpowers/specs/2026-08-19-dev-machine-diagnostic-design.md`.

---

### Task 1: Local PowerShell toolchain + repo scaffolding

**Files:**
- Create: `.gitignore`
- Create: `.tools/` (git-ignored, holds pwsh)

**Interfaces:**
- Produces: `./.tools/pwsh/pwsh` executable; Pester + PSScriptAnalyzer available to it. All later tasks run tests through it.

- [ ] **Step 1: Write `.gitignore`**

```gitignore
.tools/
DevMachineDiag-*.md
*.etl
```

- [ ] **Step 2: Download PowerShell 7 into `.tools/` (no sudo)**

```bash
cd ~/Development/machine-diag
mkdir -p .tools/pwsh
curl -L -o .tools/pwsh.tar.gz https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-osx-arm64.tar.gz
tar -xzf .tools/pwsh.tar.gz -C .tools/pwsh
chmod +x .tools/pwsh/pwsh
rm .tools/pwsh.tar.gz
```

If v7.4.6 404s, resolve the current release with
`curl -s https://api.github.com/repos/PowerShell/PowerShell/releases/latest | grep -o 'https://[^"]*osx-arm64.tar.gz'` and use that URL.

- [ ] **Step 3: Verify pwsh runs**

Run: `./.tools/pwsh/pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'`
Expected: `7.4.6` (or the resolved version)

- [ ] **Step 4: Install Pester 5 and PSScriptAnalyzer (CurrentUser scope, outside repo)**

```bash
./.tools/pwsh/pwsh -NoProfile -Command "Install-Module Pester -MinimumVersion 5.0 -Force -Scope CurrentUser; Install-Module PSScriptAnalyzer -Force -Scope CurrentUser"
```

- [ ] **Step 5: Verify both modules load**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "(Get-Module -ListAvailable Pester)[0].Version.ToString(); (Get-Module -ListAvailable PSScriptAnalyzer)[0].Version.ToString()"`
Expected: a 5.x version and any PSScriptAnalyzer version, no errors.

- [ ] **Step 6: Commit**

```bash
git add .gitignore
git commit -m "Add gitignore; local pwsh toolchain lives untracked in .tools/"
```

---

### Task 2: Script skeleton + core framework (result objects, check runner, report renderer)

**Files:**
- Create: `Diagnose-DevMachine.ps1`
- Create: `tests/Framework.Tests.ps1`

**Interfaces:**
- Produces:
  - `New-DiagResult -Name <string> -Category <string> -Severity Problem|Warning|Info|OK|Skipped [-Evidence <string[]>] [-Recommendation <string>]` → `[pscustomobject]` with exactly those five properties.
  - `Invoke-DiagCheck -Name <string> -Category <string> -Body <scriptblock>` → the Body's DiagResult(s), or a `Skipped` DiagResult if Body throws.
  - `Format-DiagReport -Results <object[]> -ComputerName <string> -Timestamp <datetime>` → Markdown string.
  - `Write-ConsoleSummary -Results <object[]>` → colored console output.
  - `$script:SeverityOrder` hashtable (Problem=0 … Skipped=4).
  - Script params: `-DefenderTrace`, `-LibraryMode`, `-BenchFileCount` (default 2000), `-BenchSpawnCount` (default 100).
  - Dot-source pattern used by all tests: `. $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode`

- [ ] **Step 1: Write the failing tests**

`tests/Framework.Tests.ps1`:

```powershell
BeforeAll {
    . $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode
}

Describe 'New-DiagResult' {
    It 'creates a result with all five properties' {
        $r = New-DiagResult -Name 'X' -Category 'Cat' -Severity 'Warning' -Evidence @('e1') -Recommendation 'do y'
        $r.Name | Should -Be 'X'
        $r.Category | Should -Be 'Cat'
        $r.Severity | Should -Be 'Warning'
        $r.Evidence | Should -Be @('e1')
        $r.Recommendation | Should -Be 'do y'
    }
    It 'rejects unknown severities' {
        { New-DiagResult -Name 'X' -Category 'C' -Severity 'Catastrophic' } | Should -Throw
    }
}

Describe 'Invoke-DiagCheck' {
    It 'returns the body result on success' {
        $r = Invoke-DiagCheck -Name 'ok' -Category 'C' -Body { New-DiagResult -Name 'ok' -Category 'C' -Severity 'OK' }
        $r.Severity | Should -Be 'OK'
    }
    It 'converts an exception into a Skipped result carrying the reason' {
        $r = Invoke-DiagCheck -Name 'boom' -Category 'C' -Body { throw 'no such cmdlet' }
        $r.Severity | Should -Be 'Skipped'
        $r.Evidence[0] | Should -Match 'no such cmdlet'
    }
}

Describe 'Format-DiagReport' {
    BeforeAll {
        $script:sample = @(
            (New-DiagResult -Name 'Fine thing' -Category 'Inventory' -Severity 'OK' -Evidence @('all good'))
            (New-DiagResult -Name 'Bad thing' -Category 'Security' -Severity 'Problem' -Evidence @('42 ms/file') -Recommendation 'Add exclusions')
        )
    }
    It 'orders Problem before OK regardless of input order' {
        $md = Format-DiagReport -Results $script:sample -ComputerName 'TESTBOX' -Timestamp ([datetime]'2026-08-19')
        $md.IndexOf('Bad thing') | Should -BeLessThan $md.IndexOf('Fine thing')
    }
    It 'includes hostname, evidence, and recommendation' {
        $md = Format-DiagReport -Results $script:sample -ComputerName 'TESTBOX' -Timestamp ([datetime]'2026-08-19')
        $md | Should -Match 'TESTBOX'
        $md | Should -Match '42 ms/file'
        $md | Should -Match 'Add exclusions'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests/Framework.Tests.ps1 -Output Detailed"`
Expected: FAIL — the script file doesn't exist yet, dot-source error.

- [ ] **Step 3: Write the skeleton with the framework**

`Diagnose-DevMachine.ps1`:

```powershell
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

# ---------- Entry point ----------

function Invoke-Main {
    Write-Host 'Diagnose-DevMachine: collectors not implemented yet.' -ForegroundColor Yellow
}

if (-not $LibraryMode) { Invoke-Main }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests/Framework.Tests.ps1 -Output Detailed"`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Diagnose-DevMachine.ps1 tests/Framework.Tests.ps1
git commit -m "Add script skeleton with result/check/report framework"
```

---

### Task 3: Security evaluators (Defender exclusion gaps, agent catalog)

**Files:**
- Modify: `Diagnose-DevMachine.ps1` (add functions below the framework section, before `Invoke-Main`)
- Create: `tests/SecurityEvaluators.Tests.ps1`

**Interfaces:**
- Consumes: `New-DiagResult` from Task 2.
- Produces:
  - `Get-DefenderExclusionGaps -ExclusionPaths <string[]> -ExclusionProcesses <string[]> -DevRoots <string[]> -ToolchainProcesses <string[]>` → `[pscustomobject]` with `UncoveredRoots <string[]>`, `UncoveredProcesses <string[]>`.
  - `Find-SecurityAgents -Services <object[]>` (objects with `Name`,`DisplayName`) → array of `[pscustomobject]` with `Product <string>`, `Services <string[]>`.
  - `$script:ToolchainProcesses` (string[] of compiler/build exe names), `$script:DevRootCandidates` (string[] of path patterns).

- [ ] **Step 1: Write the failing tests**

`tests/SecurityEvaluators.Tests.ps1`:

```powershell
BeforeAll {
    . $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode
}

Describe 'Get-DefenderExclusionGaps' {
    It 'flags dev roots and toolchain processes with no covering exclusion' {
        $gaps = Get-DefenderExclusionGaps -ExclusionPaths @('C:\other') -ExclusionProcesses @() `
            -DevRoots @('C:\dev') -ToolchainProcesses @('cl.exe')
        $gaps.UncoveredRoots | Should -Be @('C:\dev')
        $gaps.UncoveredProcesses | Should -Be @('cl.exe')
    }
    It 'treats a parent-directory exclusion as covering, case-insensitively' {
        $gaps = Get-DefenderExclusionGaps -ExclusionPaths @('C:\Dev\') -ExclusionProcesses @('CL.EXE') `
            -DevRoots @('c:\dev\proj') -ToolchainProcesses @('cl.exe')
        @($gaps.UncoveredRoots).Count | Should -Be 0
        @($gaps.UncoveredProcesses).Count | Should -Be 0
    }
    It 'matches process exclusions given as full paths' {
        $gaps = Get-DefenderExclusionGaps -ExclusionPaths @() `
            -ExclusionProcesses @('C:\tools\bin\cl.exe') -DevRoots @() -ToolchainProcesses @('cl.exe')
        @($gaps.UncoveredProcesses).Count | Should -Be 0
    }
    It 'handles empty exclusion lists' {
        $gaps = Get-DefenderExclusionGaps -ExclusionPaths @() -ExclusionProcesses @() `
            -DevRoots @('C:\src') -ToolchainProcesses @('make.exe')
        $gaps.UncoveredRoots | Should -Be @('C:\src')
    }
}

Describe 'Find-SecurityAgents' {
    It 'identifies known agents from service names and display names' {
        $services = @(
            [pscustomobject]@{ Name = 'CSFalconService'; DisplayName = 'CrowdStrike Falcon Sensor Service' }
            [pscustomobject]@{ Name = 'stAgentSvc'; DisplayName = 'Netskope Client Service' }
            [pscustomobject]@{ Name = 'Spooler'; DisplayName = 'Print Spooler' }
        )
        $found = @(Find-SecurityAgents -Services $services)
        $found.Count | Should -Be 2
        ($found | ForEach-Object Product) | Should -Contain 'CrowdStrike Falcon'
        ($found | ForEach-Object Product) | Should -Contain 'Netskope Client'
    }
    It 'reports each product once even when several services match' {
        $services = @(
            [pscustomobject]@{ Name = 'SentinelAgent'; DisplayName = 'SentinelOne Agent' }
            [pscustomobject]@{ Name = 'SentinelHelperService'; DisplayName = 'SentinelOne Helper' }
        )
        $found = @(Find-SecurityAgents -Services $services)
        $found.Count | Should -Be 1
        $found[0].Services.Count | Should -Be 2
    }
    It 'returns empty for a clean service list' {
        @(Find-SecurityAgents -Services @([pscustomobject]@{ Name = 'W32Time'; DisplayName = 'Windows Time' })).Count |
            Should -Be 0
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests/SecurityEvaluators.Tests.ps1 -Output Detailed"`
Expected: FAIL with "Get-DefenderExclusionGaps is not recognized".

- [ ] **Step 3: Implement**

Add to `Diagnose-DevMachine.ps1` after the framework section:

```powershell
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
        [System.IO.Path]::GetFileName($_).ToLowerInvariant()
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests/SecurityEvaluators.Tests.ps1 -Output Detailed"`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Diagnose-DevMachine.ps1 tests/SecurityEvaluators.Tests.ps1
git commit -m "Add Defender exclusion-gap and security-agent evaluators"
```

---

### Task 4: System evaluators (power, pending reboot, memory, disk space) + benchmark verdicts

**Files:**
- Modify: `Diagnose-DevMachine.ps1` (add below security evaluators)
- Create: `tests/SystemEvaluators.Tests.ps1`

**Interfaces:**
- Consumes: `New-DiagResult` from Task 2.
- Produces:
  - `Get-PowerPlanVerdict -PlanName <string> -ThrottleEventCount <int>` → one or two DiagResults (plan verdict; throttle verdict when count > 0).
  - `Get-PendingRebootVerdict -Indicators <string[]>` → DiagResult.
  - `Get-MemoryVerdict -TotalMB <double> -FreeMB <double> -TopConsumers <string[]>` → DiagResult.
  - `Get-DiskSpaceVerdict -DriveLetter <string> -FreeGB <double> -TotalGB <double>` → DiagResult.
  - `Get-FileBenchVerdict -Bench <pscustomobject>` (with `FileCount`,`WriteMs`,`ReadMs`,`DeleteMs`) → DiagResult.
  - `Get-SpawnBenchVerdict -Bench <pscustomobject>` (with `SpawnCount`,`TotalMs`,`PerSpawnMs`) → DiagResult.

- [ ] **Step 1: Write the failing tests**

`tests/SystemEvaluators.Tests.ps1`:

```powershell
BeforeAll {
    . $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode
}

Describe 'Get-PowerPlanVerdict' {
    It 'flags Power saver as a Problem' {
        $r = @(Get-PowerPlanVerdict -PlanName 'Power saver' -ThrottleEventCount 0)
        $r[0].Severity | Should -Be 'Problem'
    }
    It 'accepts High performance as OK' {
        $r = @(Get-PowerPlanVerdict -PlanName 'High performance' -ThrottleEventCount 0)
        $r[0].Severity | Should -Be 'OK'
    }
    It 'adds a throttle Warning when throttle events were seen' {
        $r = @(Get-PowerPlanVerdict -PlanName 'Balanced' -ThrottleEventCount 12)
        $r.Count | Should -Be 2
        $r[1].Severity | Should -Be 'Warning'
        $r[1].Evidence[0] | Should -Match '12'
    }
}

Describe 'Get-PendingRebootVerdict' {
    It 'is OK with no indicators' {
        (Get-PendingRebootVerdict -Indicators @()).Severity | Should -Be 'OK'
    }
    It 'warns when indicators exist' {
        $r = Get-PendingRebootVerdict -Indicators @('Component Based Servicing: RebootPending')
        $r.Severity | Should -Be 'Warning'
        $r.Evidence | Should -Contain 'Component Based Servicing: RebootPending'
    }
}

Describe 'Get-MemoryVerdict' {
    It 'flags <10% free as Problem' {
        (Get-MemoryVerdict -TotalMB 16384 -FreeMB 1000 -TopConsumers @()).Severity | Should -Be 'Problem'
    }
    It 'flags <20% free as Warning' {
        (Get-MemoryVerdict -TotalMB 16384 -FreeMB 2500 -TopConsumers @()).Severity | Should -Be 'Warning'
    }
    It 'is OK above 20% free' {
        (Get-MemoryVerdict -TotalMB 16384 -FreeMB 8000 -TopConsumers @()).Severity | Should -Be 'OK'
    }
}

Describe 'Get-DiskSpaceVerdict' {
    It 'flags under 10 GB free as Problem' {
        (Get-DiskSpaceVerdict -DriveLetter 'C' -FreeGB 4 -TotalGB 256).Severity | Should -Be 'Problem'
    }
    It 'flags under 15% free as Warning' {
        (Get-DiskSpaceVerdict -DriveLetter 'C' -FreeGB 30 -TotalGB 512).Severity | Should -Be 'Warning'
    }
    It 'is OK otherwise' {
        (Get-DiskSpaceVerdict -DriveLetter 'C' -FreeGB 100 -TotalGB 256).Severity | Should -Be 'OK'
    }
}

Describe 'Get-FileBenchVerdict' {
    It 'rates >8 ms/file write as Problem' {
        $bench = [pscustomobject]@{ FileCount = 1000; WriteMs = 12000; ReadMs = 3000; DeleteMs = 2000 }
        $r = Get-FileBenchVerdict -Bench $bench
        $r.Severity | Should -Be 'Problem'
        $r.Recommendation | Should -Match 'exclusion'
    }
    It 'rates 2-8 ms/file write as Warning' {
        $bench = [pscustomobject]@{ FileCount = 1000; WriteMs = 4000; ReadMs = 1000; DeleteMs = 500 }
        (Get-FileBenchVerdict -Bench $bench).Severity | Should -Be 'Warning'
    }
    It 'rates <2 ms/file write as OK' {
        $bench = [pscustomobject]@{ FileCount = 1000; WriteMs = 900; ReadMs = 400; DeleteMs = 200 }
        (Get-FileBenchVerdict -Bench $bench).Severity | Should -Be 'OK'
    }
}

Describe 'Get-SpawnBenchVerdict' {
    It 'rates >100 ms/spawn as Problem' {
        $bench = [pscustomobject]@{ SpawnCount = 100; TotalMs = 15000; PerSpawnMs = 150 }
        (Get-SpawnBenchVerdict -Bench $bench).Severity | Should -Be 'Problem'
    }
    It 'rates 30-100 ms/spawn as Warning' {
        $bench = [pscustomobject]@{ SpawnCount = 100; TotalMs = 5000; PerSpawnMs = 50 }
        (Get-SpawnBenchVerdict -Bench $bench).Severity | Should -Be 'Warning'
    }
    It 'rates <30 ms/spawn as OK' {
        $bench = [pscustomobject]@{ SpawnCount = 100; TotalMs = 1500; PerSpawnMs = 15 }
        (Get-SpawnBenchVerdict -Bench $bench).Severity | Should -Be 'OK'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests/SystemEvaluators.Tests.ps1 -Output Detailed"`
Expected: FAIL with "not recognized" errors.

- [ ] **Step 3: Implement**

Add to `Diagnose-DevMachine.ps1`:

```powershell
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests/SystemEvaluators.Tests.ps1 -Output Detailed"`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Diagnose-DevMachine.ps1 tests/SystemEvaluators.Tests.ps1
git commit -m "Add system and benchmark verdict evaluators"
```

---

### Task 5: Benchmark engines (small-file I/O, process spawn)

**Files:**
- Modify: `Diagnose-DevMachine.ps1`
- Create: `tests/Benchmarks.Tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks (engines return raw data; Task 4's verdict functions consume it).
- Produces:
  - `Invoke-SmallFileBenchmark -WorkDir <string> [-FileCount <int>] [-FileSizeBytes <int>] [-DirFanout <int>]` → `[pscustomobject]` with `FileCount`,`WriteMs`,`ReadMs`,`DeleteMs`. Creates and fully removes its files under `$WorkDir`.
  - `Invoke-ProcessSpawnBenchmark [-SpawnCount <int>] [-Command <string>] [-Arguments <string>]` → `[pscustomobject]` with `SpawnCount`,`TotalMs`,`PerSpawnMs`. Defaults target Windows (`cmd.exe` / `/c exit`); tests pass `/bin/sh` + `-c "exit 0"`.

These run for real on any OS, so the tests are small integration tests.

- [ ] **Step 1: Write the failing tests**

`tests/Benchmarks.Tests.ps1`:

```powershell
BeforeAll {
    . $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode
}

Describe 'Invoke-SmallFileBenchmark' {
    It 'creates, reads, deletes the requested files and reports timings' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "diagbench-$PID"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            $bench = Invoke-SmallFileBenchmark -WorkDir $dir -FileCount 50 -FileSizeBytes 1024 -DirFanout 5
            $bench.FileCount | Should -Be 50
            $bench.WriteMs | Should -BeGreaterOrEqual 0
            $bench.ReadMs | Should -BeGreaterOrEqual 0
            $bench.DeleteMs | Should -BeGreaterOrEqual 0
            @(Get-ChildItem -Path $dir -Recurse -File).Count | Should -Be 0
        } finally {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-ProcessSpawnBenchmark' {
    It 'spawns processes and reports per-spawn time' {
        $bench = Invoke-ProcessSpawnBenchmark -SpawnCount 5 -Command '/bin/sh' -Arguments '-c "exit 0"'
        $bench.SpawnCount | Should -Be 5
        $bench.TotalMs | Should -BeGreaterThan 0
        $bench.PerSpawnMs | Should -BeGreaterThan 0
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests/Benchmarks.Tests.ps1 -Output Detailed"`
Expected: FAIL with "not recognized".

- [ ] **Step 3: Implement**

Add to `Diagnose-DevMachine.ps1`:

```powershell
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
        $sub = Join-Path $WorkDir ('d{0:D3}' -f ($i % $DirFanout))
        $ext = $extensions[$i % $extensions.Count]
        [System.IO.File]::WriteAllBytes((Join-Path $sub "f$i$ext"), $payload)
    }
    $writeMs = $sw.ElapsedMilliseconds
    $sw.Restart()
    foreach ($f in (Get-ChildItem -Path $WorkDir -Recurse -File)) {
        [void][System.IO.File]::ReadAllBytes($f.FullName)
    }
    $readMs = $sw.ElapsedMilliseconds
    $sw.Restart()
    for ($d = 0; $d -lt $DirFanout; $d++) {
        Remove-Item -Path (Join-Path $WorkDir ('d{0:D3}' -f $d)) -Recurse -Force
    }
    $deleteMs = $sw.ElapsedMilliseconds
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
    $totalMs = $sw.ElapsedMilliseconds
    [pscustomobject]@{
        SpawnCount = $SpawnCount
        TotalMs    = $totalMs
        PerSpawnMs = [math]::Round($totalMs / [double]$SpawnCount, 1)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests/Benchmarks.Tests.ps1 -Output Detailed"`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Diagnose-DevMachine.ps1 tests/Benchmarks.Tests.ps1
git commit -m "Add small-file I/O and process-spawn benchmark engines"
```

---

### Task 6: Windows collectors + main orchestration + report writing

**Files:**
- Modify: `Diagnose-DevMachine.ps1` (add collectors section; replace the stub `Invoke-Main`)
- Create: `tests/MainSmoke.Tests.ps1`

**Interfaces:**
- Consumes: everything from Tasks 2-5 (exact names as defined there).
- Produces: a runnable script. Collectors (each returns DiagResult(s), each called through `Invoke-DiagCheck` so failures become `Skipped`): `Get-InventoryResults`, `Get-DefenderResults`, `Get-SecurityAgentResults`, `Get-PowerResults`, `Get-BitLockerResults`, `Get-SearchIndexerResults`, `Get-VbsResults`, `Get-MemoryResults`, `Get-PendingRebootResults`, `Get-BenchmarkResults`, plus `Test-IsElevated` and `Invoke-Main`.

Collectors call Windows-only cmdlets and are exercised for real only on Windows. The macOS smoke test verifies the *framework* handles their failures: a full run on macOS must exit 0, produce a report where Windows-only checks appear as Skipped and benchmarks appear with real numbers.

- [ ] **Step 1: Write the failing smoke test**

`tests/MainSmoke.Tests.ps1`:

```powershell
Describe 'Full run (non-Windows smoke)' {
    It 'runs end-to-end, exits 0, and writes a report with Skipped and Benchmark sections' {
        $scriptPath = Join-Path $PSScriptRoot '..' 'Diagnose-DevMachine.ps1'
        $outDir = Join-Path ([System.IO.Path]::GetTempPath()) "diagsmoke-$PID"
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        try {
            Push-Location $outDir
            # Run in a child pwsh: the script ends with `exit 0`, which would
            # terminate the Pester host if dot-run in-process.
            $pwshPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            & $pwshPath -NoProfile -File $scriptPath -BenchFileCount 100 -BenchSpawnCount 5 | Out-Null
            $LASTEXITCODE | Should -Be 0
            $report = @(Get-ChildItem -Path $outDir -Filter 'DevMachineDiag-*.md')
            $report.Count | Should -Be 1
            $content = Get-Content -Raw $report[0].FullName
            $content | Should -Match '## Skipped'
            $content | Should -Match 'Small-file I/O benchmark'
            $content | Should -Match 'Process-spawn benchmark'
        } finally {
            Pop-Location
            Remove-Item -Path $outDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests/MainSmoke.Tests.ps1 -Output Detailed"`
Expected: FAIL — stub `Invoke-Main` writes no report.

- [ ] **Step 3: Implement collectors and main**

Replace the stub `Invoke-Main` block in `Diagnose-DevMachine.ps1` with:

```powershell
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
```

Note: `Get-DefenderTraceResults` is referenced behind the `-DefenderTrace` flag and implemented in Task 7; until then a missing function simply produces a Skipped result via `Invoke-DiagCheck`, which is exercised nowhere by default.

- [ ] **Step 4: Run the smoke test to verify it passes**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests/MainSmoke.Tests.ps1 -Output Detailed"`
Expected: PASS — on macOS the Windows collectors all land in Skipped, benchmarks report real numbers.

- [ ] **Step 5: Run the whole suite**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests -Output Detailed"`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add Diagnose-DevMachine.ps1 tests/MainSmoke.Tests.ps1
git commit -m "Add Windows collectors and main orchestration with report output"
```

---

### Task 7: Optional Defender performance trace (`-DefenderTrace`)

**Files:**
- Modify: `Diagnose-DevMachine.ps1` (add before the Entry point section)
- Create: `tests/DefenderTrace.Tests.ps1`

**Interfaces:**
- Consumes: `New-DiagResult`, `Invoke-SmallFileBenchmark`, `$BenchFileCount`.
- Produces:
  - `Format-DefenderTraceEvidence -TopFiles <object[]> -TopProcesses <object[]> -TopExtensions <object[]>` → `string[]` (pure, unit-tested). Input objects have `Path`/`ProcessPath`/`Extension` and `TotalDurationMs` properties, mirroring `Get-MpPerformanceReport` output.
  - `Get-DefenderTraceResults` → DiagResult (Windows-only collector: records while re-running the file benchmark).

- [ ] **Step 1: Write the failing test**

`tests/DefenderTrace.Tests.ps1`:

```powershell
BeforeAll {
    . $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode
}

Describe 'Format-DefenderTraceEvidence' {
    It 'renders top files, processes, and extensions with durations' {
        $evidence = Format-DefenderTraceEvidence `
            -TopFiles @([pscustomobject]@{ Path = 'C:\dev\a.obj'; TotalDurationMs = 812.5 }) `
            -TopProcesses @([pscustomobject]@{ ProcessPath = 'C:\tools\cl.exe'; TotalDurationMs = 4123.0 }) `
            -TopExtensions @([pscustomobject]@{ Extension = '.obj'; TotalDurationMs = 9001.2 })
        ($evidence -join "`n") | Should -Match 'C:\\dev\\a\.obj.*812'
        ($evidence -join "`n") | Should -Match 'cl\.exe.*4123'
        ($evidence -join "`n") | Should -Match '\.obj.*9001'
    }
    It 'returns a no-data line when everything is empty' {
        $evidence = Format-DefenderTraceEvidence -TopFiles @() -TopProcesses @() -TopExtensions @()
        $evidence[0] | Should -Match 'no scan activity'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests/DefenderTrace.Tests.ps1 -Output Detailed"`
Expected: FAIL with "not recognized".

- [ ] **Step 3: Implement**

Add to `Diagnose-DevMachine.ps1` before the Entry point section:

```powershell
# ---------- Defender performance trace (optional, -DefenderTrace) ----------

function Format-DefenderTraceEvidence {
    param([object[]]$TopFiles = @(), [object[]]$TopProcesses = @(), [object[]]$TopExtensions = @())
    if (@($TopFiles).Count -eq 0 -and @($TopProcesses).Count -eq 0 -and @($TopExtensions).Count -eq 0) {
        return @('Defender recorded no scan activity during the benchmark window.')
    }
    $evidence = @()
    foreach ($f in $TopFiles) {
        $evidence += "Scanned file: $($f.Path) - $([math]::Round($f.TotalDurationMs)) ms total scan time"
    }
    foreach ($p in $TopProcesses) {
        $evidence += "Scanned on behalf of process: $($p.ProcessPath) - $([math]::Round($p.TotalDurationMs)) ms"
    }
    foreach ($e in $TopExtensions) {
        $evidence += "Extension $($e.Extension) - $([math]::Round($e.TotalDurationMs)) ms"
    }
    $evidence
}

function Get-DefenderTraceResults {
    if (-not (Get-Command New-MpPerformanceRecording -ErrorAction SilentlyContinue)) {
        throw 'New-MpPerformanceRecording not available (needs Windows 10 2004+ with Defender)'
    }
    $etl = Join-Path ([System.IO.Path]::GetTempPath()) "DevMachineDiag-defender-$PID.etl"
    $benchRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DevMachineDiag-trace-bench-$PID"
    New-Item -ItemType Directory -Path $benchRoot -Force | Out-Null
    try {
        Write-Host 'Recording Defender activity for 30 s while re-running the file benchmark...' -ForegroundColor Cyan
        $job = Start-Job -ScriptBlock {
            param($ScriptPath, $Dir, $Count)
            . $ScriptPath -LibraryMode
            Invoke-SmallFileBenchmark -WorkDir $Dir -FileCount $Count | Out-Null
        } -ArgumentList $PSCommandPath, $benchRoot, $BenchFileCount
        New-MpPerformanceRecording -RecordTo $etl -Seconds 30
        Wait-Job $job -Timeout 60 | Out-Null
        Remove-Job $job -Force
        $report = Get-MpPerformanceReport -Path $etl -TopFiles 5 -TopProcesses 5 -TopExtensions 5
        $evidence = Format-DefenderTraceEvidence `
            -TopFiles @($report.TopFiles) `
            -TopProcesses @($report.TopProcesses) `
            -TopExtensions @($report.TopExtensions)
        New-DiagResult -Name 'Defender performance trace' -Category 'Security' -Severity 'Info' `
            -Evidence $evidence `
            -Recommendation 'This is first-party Microsoft data on what Defender spent scan time on. If build files/toolchain dominate, it directly justifies the exclusion request.'
    } finally {
        Remove-Item -Path $etl -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $benchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests/DefenderTrace.Tests.ps1 -Output Detailed"`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Diagnose-DevMachine.ps1 tests/DefenderTrace.Tests.ps1
git commit -m "Add optional Defender performance trace phase"
```

---

### Task 8: README + risk assessment

**Files:**
- Create: `README.md`
- Create: `RISK-ASSESSMENT.md`

**Interfaces:**
- Consumes: the final behavior of `Diagnose-DevMachine.ps1` (flags, output, phases). Verify claims against the script as written — every statement in RISK-ASSESSMENT.md must be true of the actual code.

- [ ] **Step 1: Write `README.md`**

```markdown
# Dev machine slowness diagnostic

Your build machine feels slow? Run this, send the report to IT.

## Usage

Open an elevated PowerShell (right-click - Run as administrator), then:

    powershell -ExecutionPolicy Bypass -File .\Diagnose-DevMachine.ps1

Takes about two minutes; moderate disk/CPU load while the benchmarks run.
The result is `DevMachineDiag-<machine>-<date>.md` next to the script -
findings ranked by severity with the evidence and a recommended fix for
each. Treat the report as internal (it contains machine name and paths)
and share it with IT.

Optional deeper evidence (adds ~30 s, records which files Defender
spends scan time on):

    powershell -ExecutionPolicy Bypass -File .\Diagnose-DevMachine.ps1 -DefenderTrace

The tool is strictly read-only - it changes nothing on the machine.
IT/security reviewers: see RISK-ASSESSMENT.md.
```

- [ ] **Step 2: Write `RISK-ASSESSMENT.md`**

```markdown
# Risk assessment: Diagnose-DevMachine.ps1

Audience: IT / security reviewers deciding whether developers may run
this script elevated. The script is a single plaintext PowerShell file
(~600 lines, no obfuscation, no embedded binaries, nothing downloaded),
so every claim below is verifiable by reading it.

## Purpose

Developers report slow builds. The script collects configuration
evidence and runs two micro-benchmarks to identify likely causes
(security-software scanning overhead, power management, disk issues),
producing a Markdown report the developer hands to IT. It recommends
fixes; it applies none.

## What it reads

- Microsoft Defender status and preferences (`Get-MpComputerStatus`,
  `Get-MpPreference`) - real-time protection state, exclusion lists.
- Installed service names/display names (`Get-Service`) - matched against
  a built-in catalog of known security/management products.
- Active power scheme (`powercfg /getactivescheme`) and
  Kernel-Processor-Power events (Id 37) from the System event log.
- BitLocker volume status (`Get-BitLockerVolume`).
- CIM classes: `Win32_OperatingSystem`, `Win32_Processor`,
  `Win32_DeviceGuard`; `Get-PhysicalDisk`, `Get-Volume`.
- Three registry keys indicating a pending reboot (read-only `Test-Path`
  / `Get-ItemProperty`).
- Process list (`Get-Process`) for the top-5 memory consumers.
- Existence (`Test-Path`) of common development directory locations.

## What it writes

1. A temporary benchmark folder under `%TEMP%` (a few thousand 4 KB
   files of random bytes), deleted in a `finally` block.
2. The report file `DevMachineDiag-<host>-<date>.md` in the current
   directory.
3. With `-DefenderTrace` only: a Defender performance recording `.etl`
   under `%TEMP%`, deleted in a `finally` block.

There are no other writes. In particular the script never calls any
`Set-`, `New-Item` outside those folders, registry writes, or service
control operations.

## What it never does

- No configuration changes of any kind; antivirus is never toggled,
  paused, or reconfigured.
- No network access - no web requests, no DNS lookups, no uploads. The
  report stays on the machine until the developer shares it.
- No reading of user documents or file contents outside its own
  temporary benchmark files.
- No persistence: nothing installed, no scheduled tasks, no services,
  nothing left behind except the report the user asked for.
- No credential or token access.

## Why elevation is requested

`Get-MpPreference` (exclusion lists), `Get-BitLockerVolume`, and System
event-log queries require administrator rights. Without elevation the
script still runs; those checks are reported as "Skipped" and the
benchmarks still work.

## Resource impact

Roughly one to two minutes of moderate disk and CPU usage from the
benchmarks (small-file I/O in `%TEMP%`, ~100 short-lived `cmd /c exit`
processes). `-DefenderTrace` adds a ~30-second Defender performance
recording (first-party Microsoft tooling, `New-MpPerformanceRecording`).

## Data sensitivity of the report

The report contains the hostname, hardware summary, service names,
Defender exclusion paths, and development directory paths - paths may
embed usernames. It contains no file contents, no credentials. Treat it
as internal; share only with IT.

## Failure behavior

Every check runs inside a try/catch; a failing or unavailable check is
recorded as "Skipped" with the reason and the run continues. The script
cannot leave the system in a modified state because it never modifies
the system.
```

- [ ] **Step 3: Verify claims against the code**

Re-read `Diagnose-DevMachine.ps1` and confirm: no `Set-Mp*`/`Set-Item*`/`Start-Service`/`Stop-Service`/`Invoke-WebRequest`/`Invoke-RestMethod` anywhere; the only `New-Item` calls target the benchmark temp dirs; the only `Set-Content` targets the report. Fix the doc (or the code) if any claim is off.

Run: `grep -nE 'Set-Mp|Invoke-WebRequest|Invoke-RestMethod|Stop-Service|Start-Service|Set-Item' Diagnose-DevMachine.ps1`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add README.md RISK-ASSESSMENT.md
git commit -m "Add README and IT-facing risk assessment"
```

---

### Task 9: Final validation, lint, publish to GitHub

**Files:**
- Modify: none (validation + publishing only)

- [ ] **Step 1: Full test suite**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-Pester tests -Output Detailed"`
Expected: all PASS, zero failures.

- [ ] **Step 2: Lint with PSScriptAnalyzer**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path Diagnose-DevMachine.ps1 -Severity Warning,Error"`
Expected: no Error-severity findings. Fix or consciously suppress anything reported; `PSAvoidUsingWriteHost` is acceptable to suppress (console UX is the point) via `-ExcludeRule PSAvoidUsingWriteHost`.

- [ ] **Step 3: Syntax-check for Windows PowerShell 5.1 compatibility**

Run: `./.tools/pwsh/pwsh -NoProfile -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw Diagnose-DevMachine.ps1), [ref]\$null) | Out-Null; 'parse ok'"`
Expected: `parse ok`. Also grep for 7-only syntax:
`grep -nE '\?\?|\?\s*:|&&|\|\|' Diagnose-DevMachine.ps1` — review any hits (PowerShell 5.1 has none of these operators; `&&`/`||` inside strings are fine).

- [ ] **Step 4: Create the private GitHub repo and push**

```bash
cd ~/Development/machine-diag
gh repo create zrrbite/machine-diag --private --source . --push
```

Expected: repo created, `main` pushed. Verify with `gh repo view zrrbite/machine-diag --json url`.

- [ ] **Step 5: Confirm working tree is clean**

Run: `git status --porcelain`
Expected: empty output.

---

## Follow-up (outside this plan)

- A colleague runs the script on an actual work Windows machine (elevated, then again with `-DefenderTrace`) and sanity-checks the report; thresholds may need tuning against real numbers. Log this in `~/Development/todo` per global conventions.
```
