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

    It 'renders the TimeSpan shape that Get-MpPerformanceReport actually returns' {
        # Regression: the formatter assumed a TotalDurationMs number. The real
        # cmdlet returns TotalDuration as a TimeSpan, which failed the whole run
        # under StrictMode after the 30-second recording had already been taken.
        $evidence = Format-DefenderTraceEvidence `
            -TopFiles @([pscustomobject]@{ Path = 'C:\dev\a.obj'; TotalDuration = [timespan]::FromMilliseconds(812.5); Count = 4 }) `
            -TopProcesses @([pscustomobject]@{ ProcessPath = 'C:\tools\cl.exe'; TotalDuration = [timespan]::FromMilliseconds(4123.0) }) `
            -TopExtensions @([pscustomobject]@{ Extension = '.obj'; TotalDuration = [timespan]::FromMilliseconds(9001.2) })
        ($evidence -join "`n") | Should -Match 'C:\\dev\\a\.obj.*812'
        ($evidence -join "`n") | Should -Match 'over 4 scans'
        ($evidence -join "`n") | Should -Match 'cl\.exe.*4123'
        ($evidence -join "`n") | Should -Match '\.obj.*9001'
    }

    It 'does not throw on an entry with no recognisable duration property' {
        $evidence = Format-DefenderTraceEvidence -TopFiles @([pscustomobject]@{ Path = 'C:\x.obj' })
        ($evidence -join "`n") | Should -Match 'C:\\x\.obj.*0 ms'
    }
}

Describe 'Get-TraceDurationMs' {
    It 'reads a TimeSpan TotalDuration' {
        Get-TraceDurationMs -Entry ([pscustomobject]@{ TotalDuration = [timespan]::FromSeconds(2) }) | Should -Be 2000
    }
    It 'reads a plain TotalDurationMs number' {
        Get-TraceDurationMs -Entry ([pscustomobject]@{ TotalDurationMs = 1500 }) | Should -Be 1500
    }
    It 'returns zero for an entry with neither, and for null' {
        Get-TraceDurationMs -Entry ([pscustomobject]@{ Path = 'x' }) | Should -Be 0
        Get-TraceDurationMs -Entry $null | Should -Be 0
    }
}
