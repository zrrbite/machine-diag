BeforeAll {
    . $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode
}

Describe 'Select-RealExclusions' {
    It 'drops the placeholder Windows returns to an unelevated caller' {
        # Regression: unelevated, Get-MpPreference returns this string rather
        # than failing, and it was being counted as a configured exclusion -
        # overstating coverage and suppressing the "may not be real" note.
        (Select-RealExclusions -Values @('N/A: Must be an administrator to view exclusions')).Count | Should -Be 0
    }
    It 'drops nulls and empties without dropping real paths' {
        $kept = Select-RealExclusions -Values @($null, '', 'C:\dev', 'C:\src')
        $kept | Should -Be @('C:\dev', 'C:\src')
    }
    It 'returns a countable array even when everything is filtered out' {
        # Without the comma operator an empty result unrolls to $null, and
        # StrictMode turns the caller's .Count into a terminating error.
        $empty = Select-RealExclusions -Values @()
        $empty -is [array] | Should -BeTrue
        $empty.Count | Should -Be 0
    }
}

Describe 'Test-ExclusionsWithheld' {
    It 'detects the unelevated placeholder' {
        Test-ExclusionsWithheld -Values @('N/A: Must be an administrator to view exclusions') | Should -BeTrue
    }
    It 'is false for a genuinely empty list and for real exclusions' {
        Test-ExclusionsWithheld -Values @() | Should -BeFalse
        Test-ExclusionsWithheld -Values @('C:\dev') | Should -BeFalse
    }
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
    It 'handles forward-slash paths in process exclusions' {
        $gaps = Get-DefenderExclusionGaps -ExclusionPaths @() `
            -ExclusionProcesses @('C:/tools/bin/cl.exe') -DevRoots @() -ToolchainProcesses @('cl.exe')
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
