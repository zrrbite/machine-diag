BeforeAll {
    . $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode
}

Describe 'New-DiagResult' {
    It 'creates a result with all six properties' {
        $r = New-DiagResult -Name 'X' -Category 'Cat' -Severity 'Warning' -Evidence @('e1') `
            -Recommendation 'do y' -Headline 'the number'
        $r.Name | Should -Be 'X'
        $r.Category | Should -Be 'Cat'
        $r.Severity | Should -Be 'Warning'
        $r.Evidence | Should -Be @('e1')
        $r.Recommendation | Should -Be 'do y'
        $r.Headline | Should -Be 'the number'
    }
    It 'rejects unknown severities' {
        { New-DiagResult -Name 'X' -Category 'C' -Severity 'Catastrophic' } | Should -Throw
    }
}

Describe 'Get-DiagHeadline' {
    It 'prefers an explicit headline' {
        $r = New-DiagResult -Name 'X' -Category 'C' -Severity 'Warning' -Evidence @('first line') -Headline 'the number'
        Get-DiagHeadline -Result $r | Should -Be 'the number'
    }
    It 'falls back to the first evidence line when no headline is set' {
        $r = New-DiagResult -Name 'X' -Category 'C' -Severity 'Warning' -Evidence @('first line', 'second')
        Get-DiagHeadline -Result $r | Should -Be 'first line'
    }
    It 'returns empty when there is no evidence at all' {
        $r = New-DiagResult -Name 'X' -Category 'C' -Severity 'OK'
        Get-DiagHeadline -Result $r | Should -BeNullOrEmpty
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
    It 'drops stray pipeline objects a chatty cmdlet leaks into the results' {
        # Regression: New-MpPerformanceRecording emitted status objects into the
        # success stream, which reached the report and broke rendering at the very
        # end of an otherwise complete run.
        $r = @(Invoke-DiagCheck -Name 'noisy' -Category 'C' -Body {
            'a bare string'
            [pscustomobject]@{ Unrelated = 'object' }
            New-DiagResult -Name 'real' -Category 'C' -Severity 'OK'
        })
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'real'
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
    It 'opens with a summary that states the verdict before any detail' {
        $md = Format-DiagReport -Results $script:sample -ComputerName 'TESTBOX' -Timestamp ([datetime]'2026-08-19')
        $md | Should -Match '## Summary'
        $md.IndexOf('## Summary') | Should -BeLessThan $md.IndexOf('## Problem')
        $md | Should -Match '1 problem on TESTBOX'
        $md | Should -Match '1 checks passed'
    }
    It 'lists problems and warnings in a table with their key measurement' {
        $md = Format-DiagReport -Results $script:sample -ComputerName 'TESTBOX' -Timestamp ([datetime]'2026-08-19')
        $md | Should -Match '\| Severity \| Finding \| Key measurement \|'
        $md | Should -Match '\| Problem \| Bad thing \(Security\) \| 42 ms/file \|'
    }
    It 'uses the headline rather than the first evidence line in the table' {
        $results = @(
            New-DiagResult -Name 'Gaps' -Category 'Security' -Severity 'Problem' `
                -Evidence @('Real-time protection: ON', '3 directories unexcluded') `
                -Headline '3 dev directories not excluded' -Recommendation 'Add exclusions'
        )
        $md = Format-DiagReport -Results $results -ComputerName 'TESTBOX' -Timestamp ([datetime]'2026-08-19')
        $md | Should -Match '\| Problem \| Gaps \(Security\) \| 3 dev directories not excluded \|'
    }
    It 'numbers the recommended actions and does not repeat a shared one' {
        $results = @(
            New-DiagResult -Name 'A' -Category 'C' -Severity 'Problem' -Evidence @('x') -Recommendation 'Same fix'
            New-DiagResult -Name 'B' -Category 'C' -Severity 'Warning' -Evidence @('y') -Recommendation 'Same fix'
            New-DiagResult -Name 'C' -Category 'C' -Severity 'Warning' -Evidence @('z') -Recommendation 'Other fix'
        )
        $md = Format-DiagReport -Results $results -ComputerName 'TESTBOX' -Timestamp ([datetime]'2026-08-19')
        $md | Should -Match '1\. Same fix'
        $md | Should -Match '2\. Other fix'
        ([regex]::Matches($md, 'Same fix')).Count | Should -Be 3
    }
    It 'tabulates every benchmark measurement for comparison' {
        $results = @(
            New-DiagResult -Name 'Small-file I/O benchmark' -Category 'Benchmark' -Severity 'OK' `
                -Evidence @('a long evidence line') -Headline '0.61 ms/file write'
            New-DiagResult -Name 'Compile throughput' -Category 'Benchmark' -Severity 'Warning' `
                -Evidence @('a long evidence line') -Headline '441.4 ms/TU with clang-cl'
            New-DiagResult -Name 'Pending reboot' -Category 'OS' -Severity 'Warning' -Evidence @('x')
        )
        $md = Format-DiagReport -Results $results -ComputerName 'TESTBOX' -Timestamp ([datetime]'2026-09-09')
        $md | Should -Match '## Measurements'
        $md | Should -Match '\| Measurement \| Result \| Verdict \|'
        $md | Should -Match '\| Compile throughput \| 441\.4 ms/TU with clang-cl \| Warning \|'
        $md | Should -Match '\| Small-file I/O benchmark \| 0\.61 ms/file write \| OK \|'
    }
    It 'omits the measurements table when nothing was benchmarked' {
        $results = @(New-DiagResult -Name 'Pending reboot' -Category 'OS' -Severity 'Warning' -Evidence @('x'))
        $md = Format-DiagReport -Results $results -ComputerName 'TESTBOX' -Timestamp ([datetime]'2026-09-09')
        $md | Should -Not -Match '## Measurements'
    }
    It 'names the checks that could not run' {
        $results = @(
            New-DiagResult -Name 'BitLocker' -Category 'Storage' -Severity 'Skipped' -Evidence @('Access denied')
        )
        $md = Format-DiagReport -Results $results -ComputerName 'TESTBOX' -Timestamp ([datetime]'2026-08-19')
        $md | Should -Match 'Could not run: BitLocker'
    }
    It 'says so plainly when there is nothing to fix' {
        $results = @(New-DiagResult -Name 'Fine' -Category 'C' -Severity 'OK' -Evidence @('good'))
        $md = Format-DiagReport -Results $results -ComputerName 'TESTBOX' -Timestamp ([datetime]'2026-08-19')
        $md | Should -Match 'Nothing to fix on TESTBOX'
    }
}
