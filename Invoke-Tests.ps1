<#
.SYNOPSIS
    Runs the test suite, installing a usable Pester into .tools/ first if the
    machine does not already have one.

.DESCRIPTION
    The suite is written for Pester 5+. Windows ships Pester 3.4, which cannot
    run it - the failure is confusing rather than obvious, because the module
    imports fine and then rejects the syntax.

    Rather than ask contributors to change what is installed system-wide, this
    saves a modern Pester into the git-ignored .tools/ directory and puts that
    directory on PSModulePath for this process only. Nothing outside the repo
    is modified. If the machine already has Pester 5+, that copy is used and
    nothing is downloaded.

.PARAMETER Path
    Test path to run. Defaults to the tests/ directory.

.PARAMETER Output
    Pester output verbosity. Normal by default; Detailed lists every test.

.PARAMETER Reinstall
    Discard the copy in .tools/ and fetch it again.

.EXAMPLE
    pwsh -File .\Invoke-Tests.ps1

.EXAMPLE
    pwsh -File .\Invoke-Tests.ps1 -Path .\tests\CompileBench.Tests.ps1 -Output Detailed
#>
[CmdletBinding()]
param(
    [string]$Path = '',
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')][string]$Output = 'Normal',
    [switch]$Reinstall
)

$ErrorActionPreference = 'Stop'

$MinimumPester = [version]'5.0.0'
$repoRoot = Split-Path -Parent $PSCommandPath
$toolsDir = Join-Path $repoRoot '.tools'
if (-not $Path) { $Path = Join-Path $repoRoot 'tests' }

function Find-UsablePester {
    Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -ge $MinimumPester } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

if ($Reinstall) {
    Remove-Item -Path (Join-Path $toolsDir 'Pester') -Recurse -Force -ErrorAction SilentlyContinue
}

# Prepend so a copy already saved in .tools/ wins over an old system-wide one.
$sep = [System.IO.Path]::PathSeparator
if (($env:PSModulePath -split [regex]::Escape($sep)) -notcontains $toolsDir) {
    $env:PSModulePath = $toolsDir + $sep + $env:PSModulePath
}

$pester = Find-UsablePester
if (-not $pester) {
    Write-Host "Pester $MinimumPester or newer not found. Saving a local copy into .tools/ ..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    try {
        # Save-PSResource on newer PowerShell, Save-Module on Windows PowerShell 5.1.
        if (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
            Save-PSResource -Name Pester -Version "[$MinimumPester,)" -Path $toolsDir -TrustRepository -ErrorAction Stop
        } else {
            Save-Module -Name Pester -MinimumVersion $MinimumPester -Path $toolsDir `
                -Repository PSGallery -Force -ErrorAction Stop
        }
    } catch {
        throw ("Could not install Pester into $toolsDir : $($_.Exception.Message)`n" +
               'This step needs access to the PowerShell Gallery. If this machine is offline ' +
               'or behind a proxy that blocks it, install Pester 5+ by hand and re-run.')
    }
    $pester = Find-UsablePester
    if (-not $pester) {
        throw "Pester was saved into $toolsDir but still cannot be found on PSModulePath."
    }
}

Import-Module -Name $pester.Path -Force
Write-Host "Using Pester $($pester.Version) from $($pester.ModuleBase)" -ForegroundColor DarkGray

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.PassThru = $true
$config.Output.Verbosity = $Output

$result = Invoke-Pester -Configuration $config

Write-Host ''
if ($result.FailedCount -gt 0) {
    Write-Host "$($result.FailedCount) test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All $($result.PassedCount) tests passed." -ForegroundColor Green
exit 0
