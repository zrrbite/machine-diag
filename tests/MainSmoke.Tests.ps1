Describe 'Full run (non-Windows smoke)' {
    It 'runs end-to-end, exits 0, and writes a report with Skipped and Benchmark sections' {
        $scriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'Diagnose-DevMachine.ps1'
        $outDir = Join-Path ([System.IO.Path]::GetTempPath()) "diagsmoke-$PID"
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        try {
            # Run a copy of the script from $outDir so the report - now written
            # next to the script itself rather than the current directory -
            # lands in $outDir and the repo stays clean.
            $copyPath = Join-Path $outDir 'Diagnose-DevMachine.ps1'
            Copy-Item -Path $scriptPath -Destination $copyPath
            # Run in a child pwsh: the script ends with `exit 0`, which would
            # terminate the Pester host if dot-run in-process.
            $pwshPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            & $pwshPath -NoProfile -File $copyPath -BenchFileCount 100 -BenchSpawnCount 5 | Out-Null
            $LASTEXITCODE | Should -Be 0
            $report = @(Get-ChildItem -Path $outDir -Filter 'DevMachineDiag-*.md')
            $report.Count | Should -Be 1
            $content = Get-Content -Raw $report[0].FullName
            $content | Should -Match '## Skipped'
            $content | Should -Match 'Small-file I/O benchmark'
            $content | Should -Match 'Process-spawn benchmark'
        } finally {
            Remove-Item -Path $outDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
