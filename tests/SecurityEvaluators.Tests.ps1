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
