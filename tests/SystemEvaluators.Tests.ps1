BeforeAll {
    . $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode
}

Describe 'Resolve-PowerPlanName' {
    It 'resolves a known GUID to its canonical English name even with a localized display name' {
        $line = 'Aktiv strømstyringsplan efter GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Afbalanceret)'
        Resolve-PowerPlanName -SchemeLine $line | Should -Be 'Balanced'
    }
    It 'falls back to the parenthesised display name for an unknown GUID' {
        $line = 'Active Power Scheme GUID: 00000000-0000-0000-0000-000000000000  (Custom Plan)'
        Resolve-PowerPlanName -SchemeLine $line | Should -Be 'Custom Plan'
    }
    It 'preserves nested parens in the display name via a greedy match' {
        $line = 'Active Power Scheme GUID: 00000000-0000-0000-0000-000000000000  (HP Optimized (recommended))'
        Resolve-PowerPlanName -SchemeLine $line | Should -Be 'HP Optimized (recommended)'
    }
    It 'returns unknown when there is no GUID and no parens' {
        Resolve-PowerPlanName -SchemeLine 'no useful data here' | Should -Be 'unknown'
    }
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
