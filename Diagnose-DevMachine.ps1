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
