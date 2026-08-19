Describe 'Full run (non-Windows smoke)' {
    It 'runs end-to-end, exits 0, and writes a report with Skipped and Benchmark sections' {
        $scriptPath = Join-Path $PSScriptRoot '..' 'Diagnose-DevMachine.ps1'
        $outDir = Join-Path ([System.IO.Path]::GetTempPath()) "diagsmoke-$PID"
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        try {
            Push-Location $outDir
            # Run in a child pwsh: the script ends with `exit 0`, which would
            # terminate the Pester host if dot-run in-process.
            $pwshPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            & $pwshPath -NoProfile -File $scriptPath -BenchFileCount 100 -BenchSpawnCount 5 | Out-Null
            $LASTEXITCODE | Should -Be 0
            $report = @(Get-ChildItem -Path $outDir -Filter 'DevMachineDiag-*.md')
            $report.Count | Should -Be 1
            $content = Get-Content -Raw $report[0].FullName
            $content | Should -Match '## Skipped'
            $content | Should -Match 'Small-file I/O benchmark'
            $content | Should -Match 'Process-spawn benchmark'
        } finally {
            Pop-Location
            Remove-Item -Path $outDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
