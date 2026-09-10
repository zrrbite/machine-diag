BeforeAll {
    . $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode

    function Get-VerdictByName {
        param([object[]]$Results, [string]$Name)
        @($Results | Where-Object { $_.Name -eq $Name })[0]
    }

    # A machine where everything works, so each test can vary one fact.
    function Get-CleanPreFlight {
        param([hashtable]$Override = @{})
        $args = @{
            LanguageMode = 'FullLanguage'; MachinePolicy = 'Undefined'; UserPolicy = 'Undefined'
            Elevated = $true; AmRunningMode = 'Normal'; TraceCmdletPresent = $true
            CompilerName = 'clang-cl'; PSVersion = '5.1.26100.9168'
        }
        foreach ($k in $Override.Keys) { $args[$k] = $Override[$k] }
        @(Get-PreFlightVerdicts @args)
    }
}

Describe 'Get-PreFlightVerdicts' {
    It 'clears a machine where everything is available' {
        $r = Get-CleanPreFlight
        @($r | Where-Object { $_.Severity -eq 'Problem' }).Count | Should -Be 0
        @($r | Where-Object { $_.Severity -eq 'Warning' }).Count | Should -Be 0
    }

    Context 'blockers' {
        It 'treats Constrained Language Mode as a Problem and says elevation will not help' {
            $v = Get-VerdictByName -Results (Get-CleanPreFlight @{ LanguageMode = 'ConstrainedLanguage' }) `
                -Name 'PowerShell language mode'
            $v.Severity | Should -Be 'Problem'
            ($v.Evidence -join ' ') | Should -Match 'running elevated does not lift it'
        }

        It 'treats an AllSigned MachinePolicy as a Problem' {
            $v = Get-VerdictByName -Results (Get-CleanPreFlight @{ MachinePolicy = 'AllSigned' }) -Name 'Execution policy'
            $v.Severity | Should -Be 'Problem'
            $v.Headline | Should -Be 'MachinePolicy=AllSigned'
        }

        It 'treats a Restricted UserPolicy as a Problem too' {
            $v = Get-VerdictByName -Results (Get-CleanPreFlight @{ UserPolicy = 'Restricted' }) -Name 'Execution policy'
            $v.Severity | Should -Be 'Problem'
        }

        It 'does not object to RemoteSigned or Bypass policy scopes' {
            foreach ($p in 'RemoteSigned', 'Bypass', 'Unrestricted', 'Undefined') {
                $v = Get-VerdictByName -Results (Get-CleanPreFlight @{ MachinePolicy = $p }) -Name 'Execution policy'
                $v.Severity | Should -Be 'OK' -Because "$p does not block execution"
            }
        }
    }

    Context 'degraded but runnable' {
        It 'warns rather than blocks when not elevated' {
            $r = Get-CleanPreFlight @{ Elevated = $false }
            (Get-VerdictByName -Results $r -Name 'Elevation').Severity | Should -Be 'Warning'
            @($r | Where-Object { $_.Severity -eq 'Problem' }).Count | Should -Be 0
        }

        It 'warns that scan share is unmeasurable when Defender is passive' {
            $r = Get-CleanPreFlight @{ AmRunningMode = 'Passive Mode' }
            $v = Get-VerdictByName -Results $r -Name 'Defender running mode'
            $v.Severity | Should -Be 'Warning'
            ($v.Evidence -join ' ') | Should -Match 'no equivalent for third-party agents'
            (Get-VerdictByName -Results $r -Name '-DefenderTrace').Severity | Should -Be 'Warning'
        }

        It 'reports an unknown Defender mode as Info rather than a fault' {
            $v = Get-VerdictByName -Results (Get-CleanPreFlight @{ AmRunningMode = '' }) -Name 'Defender running mode'
            $v.Severity | Should -Be 'Info'
        }

        It 'warns that -CompileBench will be skipped with no compiler' {
            $v = Get-VerdictByName -Results (Get-CleanPreFlight @{ CompilerName = '' }) -Name '-CompileBench'
            $v.Severity | Should -Be 'Warning'
            ($v.Evidence -join ' ') | Should -Match 'Every other check still runs'
        }
    }

    Context '-DefenderTrace availability' {
        It 'lists every reason it is unavailable at once' {
            $v = Get-VerdictByName -Results (Get-CleanPreFlight @{
                Elevated = $false; TraceCmdletPresent = $false; AmRunningMode = 'Passive Mode'
            }) -Name '-DefenderTrace'
            $v.Severity | Should -Be 'Warning'
            ($v.Evidence -join ' ') | Should -Match 'New-MpPerformanceRecording not present'
            ($v.Evidence -join ' ') | Should -Match 'not elevated'
            ($v.Evidence -join ' ') | Should -Match 'Passive Mode'
        }

        It 'is available only when the cmdlet, elevation and Normal mode all hold' {
            (Get-VerdictByName -Results (Get-CleanPreFlight) -Name '-DefenderTrace').Severity | Should -Be 'OK'
        }
    }
}

Describe 'Get-PreFlightResults' {
    It 'runs against the real machine and returns a verdict for every check' {
        $r = @(Get-PreFlightResults)
        $r.Count | Should -BeGreaterThan 4
        foreach ($name in 'PowerShell language mode', 'Execution policy', 'Elevation', '-CompileBench') {
            (Get-VerdictByName -Results $r -Name $name) | Should -Not -BeNullOrEmpty
        }
    }
    It 'measures nothing and writes nothing' {
        # The point of the switch: it must be cheap and side-effect free.
        $before = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'DevMachineDiag-*' -ErrorAction SilentlyContinue).Count
        $elapsed = Measure-Command { Get-PreFlightResults | Out-Null }
        $after = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'DevMachineDiag-*' -ErrorAction SilentlyContinue).Count
        $after | Should -Be $before
        $elapsed.TotalSeconds | Should -BeLessThan 20
    }
}
