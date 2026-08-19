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
