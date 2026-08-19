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
