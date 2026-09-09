BeforeAll {
    . $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode
}

Describe 'Invoke-SmallFileBenchmark' {
    It 'creates, reads, deletes the requested files and reports timings' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "diagbench-$PID"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            $bench = Invoke-SmallFileBenchmark -WorkDir $dir -FileCount 50 -FileSizeBytes 1024 -DirFanout 5
            $bench.FileCount | Should -Be 50
            $bench.WriteMs | Should -BeGreaterOrEqual 0
            $bench.ReadMs | Should -BeGreaterOrEqual 0
            $bench.DeleteMs | Should -BeGreaterOrEqual 0
            @(Get-ChildItem -Path $dir -Recurse -File).Count | Should -Be 0
        } finally {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-ProcessSpawnBenchmark' {
    It 'spawns processes and reports per-spawn time' {
        # The function defaults to cmd.exe; callers pass the POSIX command
        # explicitly, so the test has to branch the same way Get-BenchmarkResults does.
        $bench = if ($script:OnWindows) {
            Invoke-ProcessSpawnBenchmark -SpawnCount 5
        } else {
            Invoke-ProcessSpawnBenchmark -SpawnCount 5 -Command '/bin/sh' -Arguments '-c "exit 0"'
        }
        $bench.SpawnCount | Should -Be 5
        $bench.TotalMs | Should -BeGreaterThan 0
        $bench.PerSpawnMs | Should -BeGreaterThan 0
    }
}
