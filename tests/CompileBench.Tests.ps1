BeforeAll {
    . $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode

    function New-TestBench {
        param(
            [double]$ColdMs = 6000, [double]$WarmMs = 3000, [double]$ParallelMs = 1200,
            [int]$JobCount = 8, [double]$LinkMs = 400, [int]$TuCount = 30, [int]$ObjectCount = 30
        )
        [pscustomobject]@{
            CompilerName = 'cl'; CompilerPath = 'C:\tools\cl.exe'; ToolchainSource = 'test fixture'
            TuCount = $TuCount; ColdMs = $ColdMs; WarmMs = $WarmMs; ParallelMs = $ParallelMs
            JobCount = $JobCount; LinkMs = $LinkMs; ObjectCount = $ObjectCount
        }
    }

    function Get-VerdictByName {
        param([object[]]$Results, [string]$Name)
        @($Results | Where-Object { $_.Name -eq $Name })[0]
    }
}

# Probed at discovery time as well, so -Skip below can be resolved before the
# run phase. The integration test needs a real toolchain; the pure-logic tests
# do not, and must still pass on the macOS dev machine.
. $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode
try { $script:BenchToolchain = Resolve-CompileToolchain } catch { $script:BenchToolchain = $null }
$script:NoCompiler = ($null -eq $script:BenchToolchain)

Describe 'New-CompileBenchProject' {
    BeforeEach {
        $script:GenRoot = Join-Path ([System.IO.Path]::GetTempPath()) "diagcompile-gen-$PID"
    }
    AfterEach {
        Remove-Item -Path $script:GenRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'generates the requested headers plus one TU per unit and a main' {
        $p = New-CompileBenchProject -Root $script:GenRoot -TuCount 4 -HeaderCount 3
        $p.HeaderCount | Should -Be 3
        $p.TuCount | Should -Be 5
        @(Get-ChildItem -Path $p.IncludeDir -Filter '*.h').Count | Should -Be 3
        @(Get-ChildItem -Path $p.SourceDir -Filter '*.cpp').Count | Should -Be 5
        Test-Path $p.MainSource | Should -BeTrue
    }

    It 'has every translation unit include every shared header' {
        $p = New-CompileBenchProject -Root $script:GenRoot -TuCount 3 -HeaderCount 4
        foreach ($src in ($p.Sources | Where-Object { $_ -notmatch 'main\.cpp$' })) {
            $text = Get-Content -Path $src -Raw
            foreach ($h in 0..3) {
                $text | Should -Match ([regex]::Escape("#include `"bench$h.h`""))
            }
        }
    }

    It 'gives each translation unit a unique entry symbol so the objects link' {
        $p = New-CompileBenchProject -Root $script:GenRoot -TuCount 5 -HeaderCount 2
        $symbols = @()
        foreach ($src in ($p.Sources | Where-Object { $_ -notmatch 'main\.cpp$' })) {
            $text = Get-Content -Path $src -Raw
            if ($text -match 'int (tu_\d+_entry)\(\)') { $symbols += $Matches[1] }
        }
        $symbols.Count | Should -Be 5
        @($symbols | Sort-Object -Unique).Count | Should -Be 5
    }

    It 'references every entry symbol from main' {
        $p = New-CompileBenchProject -Root $script:GenRoot -TuCount 3 -HeaderCount 2
        $main = Get-Content -Path $p.MainSource -Raw
        foreach ($t in 0..2) { $main | Should -Match "tu_${t}_entry\(\)" }
    }
}

Describe 'Resolve-CompileToolchain' {
    BeforeEach {
        $script:FakeDir = Join-Path ([System.IO.Path]::GetTempPath()) "diagcompile-fake-$PID"
        New-Item -ItemType Directory -Path $script:FakeDir -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:FakeDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'treats an explicit clang-cl override as MSVC style' {
        $fake = Join-Path $script:FakeDir 'clang-cl.exe'
        Set-Content -Path $fake -Value 'stub'
        $tc = Resolve-CompileToolchain -Override $fake
        $tc.Style | Should -Be 'MSVC'
        $tc.Source | Should -Match 'explicit'
    }

    It 'treats an explicit g++ override as GNU style with no driver-mode flag' {
        $fake = Join-Path $script:FakeDir 'g++.exe'
        Set-Content -Path $fake -Value 'stub'
        $tc = Resolve-CompileToolchain -Override $fake
        $tc.Style | Should -Be 'GNU'
        $tc.DriverMode | Should -BeNullOrEmpty
    }

    It 'puts plain clang into g++ driver mode' {
        $fake = Join-Path $script:FakeDir 'clang.exe'
        Set-Content -Path $fake -Value 'stub'
        $tc = Resolve-CompileToolchain -Override $fake
        $tc.DriverMode | Should -Be '--driver-mode=g++'
    }

    It 'throws with the offending path when the override does not exist' {
        { Resolve-CompileToolchain -Override 'X:\no\such\compiler.exe' } |
            Should -Throw -ExpectedMessage '*no\such\compiler.exe*'
    }
}

Describe 'Get-CompileCommandLine' {
    It 'emits MSVC switches and quotes the output path' {
        $tc = [pscustomobject]@{ Name = 'cl'; Path = 'cl.exe'; Style = 'MSVC'; DriverMode = ''; Source = 'test' }
        $line = Get-CompileCommandLine -Toolchain $tc -Source 'C:\src\tu0.cpp' -ObjPath 'C:\obj dir\tu0.obj' -IncludeDir 'C:\inc'
        $line | Should -Match '/c'
        $line | Should -Match '/nologo'
        $line | Should -Match ([regex]::Escape('/Fo"C:\obj dir\tu0.obj"'))
    }

    It 'emits GNU switches including the driver mode when set' {
        $tc = [pscustomobject]@{ Name = 'clang'; Path = 'clang.exe'; Style = 'GNU'; DriverMode = '--driver-mode=g++'; Source = 'test' }
        $line = Get-CompileCommandLine -Toolchain $tc -Source '/src/tu0.cpp' -ObjPath '/obj/tu0.obj' -IncludeDir '/inc'
        $line | Should -Match '--driver-mode=g\+\+'
        $line | Should -Match '-c'
        $line | Should -Match ([regex]::Escape('-o "/obj/tu0.obj"'))
    }
}

Describe 'Get-CompileBenchVerdict' {
    It 'reports OK across the board for a healthy machine' {
        $r = @(Get-CompileBenchVerdict -Bench (New-TestBench))
        (Get-VerdictByName -Results $r -Name 'Compile throughput').Severity | Should -Be 'OK'
        (Get-VerdictByName -Results $r -Name 'Parallel compile scaling').Severity | Should -Be 'OK'
    }

    It 'flags throughput above 1800 ms/TU as a Problem' {
        $r = @(Get-CompileBenchVerdict -Bench (New-TestBench -ColdMs 60000 -WarmMs 30000))
        (Get-VerdictByName -Results $r -Name 'Compile throughput').Severity | Should -Be 'Problem'
    }

    It 'flags throughput between 900 and 1800 ms/TU as a Warning' {
        $r = @(Get-CompileBenchVerdict -Bench (New-TestBench -ColdMs 36000 -WarmMs 18000))
        (Get-VerdictByName -Results $r -Name 'Compile throughput').Severity | Should -Be 'Warning'
    }

    It 'accepts 441 ms/TU, the measured no-interference figure for clang-cl on a 12700K' {
        # Regression: the original 400 ms Warning threshold flagged a machine
        # whose Defender trace showed under 2% of build time spent scanning.
        $r = @(Get-CompileBenchVerdict -Bench (New-TestBench -ColdMs 13683 -TuCount 31))
        (Get-VerdictByName -Results $r -Name 'Compile throughput').Severity | Should -Be 'OK'
    }

    It 'reports the repeat-pass ratio as Info and never as a verdict' {
        # A rebuild is parse-bound, so a 1.00x ratio is expected on a healthy
        # machine. The ratio cannot separate parse cost from scan cost.
        foreach ($warm in 6000, 5000, 3000) {
            $r = @(Get-CompileBenchVerdict -Bench (New-TestBench -ColdMs 6000 -WarmMs $warm))
            $v = Get-VerdictByName -Results $r -Name 'Compile repeat-pass timing'
            $v.Severity | Should -Be 'Info'
            $v.Recommendation | Should -BeNullOrEmpty
        }
    }

    It 'warns the reader off reading interference into the repeat-pass ratio' {
        $r = @(Get-CompileBenchVerdict -Bench (New-TestBench -ColdMs 6000 -WarmMs 6000))
        $v = Get-VerdictByName -Results $r -Name 'Compile repeat-pass timing'
        ($v.Evidence -join ' ') | Should -Match 'does NOT by itself indicate antivirus interference'
        ($v.Evidence -join ' ') | Should -Match '-DefenderTrace'
    }

    It 'warns when parallel efficiency falls below 0.40' {
        $r = @(Get-CompileBenchVerdict -Bench (New-TestBench -ColdMs 6000 -ParallelMs 5500 -JobCount 8))
        (Get-VerdictByName -Results $r -Name 'Parallel compile scaling').Severity | Should -Be 'Warning'
    }

    It 'records the compiler identity in the throughput evidence' {
        $r = @(Get-CompileBenchVerdict -Bench (New-TestBench))
        $v = Get-VerdictByName -Results $r -Name 'Compile throughput'
        ($v.Evidence -join ' ') | Should -Match 'cl'
        ($v.Evidence -join ' ') | Should -Match 'test fixture'
    }
}

Describe 'Get-BuildScanMs' {
    It 'sums scan time attributed to the compiler, by full path or leaf name' {
        $top = @(
            [pscustomobject]@{ ProcessPath = 'C:\tools\clang-cl.exe'; TotalDuration = [timespan]::FromMilliseconds(244) }
            [pscustomobject]@{ ProcessPath = 'C:\Windows\explorer.exe'; TotalDuration = [timespan]::FromMilliseconds(900) }
        )
        Get-BuildScanMs -TopProcesses $top -CompilerPath 'C:\tools\clang-cl.exe' | Should -Be 244
        Get-BuildScanMs -TopProcesses $top -CompilerPath 'D:\other\clang-cl.exe' | Should -Be 244
    }
    It 'returns zero when the compiler did not appear in the trace' {
        $top = @([pscustomobject]@{ ProcessPath = 'C:\Windows\explorer.exe'; TotalDuration = [timespan]::FromMilliseconds(900) })
        Get-BuildScanMs -TopProcesses $top -CompilerPath 'C:\tools\cl.exe' | Should -Be 0
    }
    It 'ignores entries with no ProcessPath at all' {
        $top = @([pscustomobject]@{ TotalDuration = [timespan]::FromMilliseconds(353) })
        Get-BuildScanMs -TopProcesses $top -CompilerPath 'C:\tools\cl.exe' | Should -Be 0
    }
}

Describe 'Get-BuildScanShareVerdict' {
    It 'is OK when scanning is under 5% of build time' {
        $v = Get-BuildScanShareVerdict -ScanMs 244 -CompileMs 13683 -CompilerName 'clang-cl'
        $v.Severity | Should -Be 'OK'
        $v.Headline | Should -Match '1\.8% of compile time'
    }
    It 'warns between 5% and 20%' {
        (Get-BuildScanShareVerdict -ScanMs 1500 -CompileMs 10000).Severity | Should -Be 'Warning'
    }
    It 'flags above 20% as a Problem and recommends exclusions' {
        $v = Get-BuildScanShareVerdict -ScanMs 3000 -CompileMs 10000
        $v.Severity | Should -Be 'Problem'
        $v.Recommendation | Should -Match 'exclusions'
    }
    It 'skips rather than dividing by zero when the compile reported no time' {
        (Get-BuildScanShareVerdict -ScanMs 100 -CompileMs 0).Severity | Should -Be 'Skipped'
    }
}

Describe 'Get-LinkBenchVerdict' {
    It 'accepts a fast link' {
        (Get-LinkBenchVerdict -Bench (New-TestBench -LinkMs 400)).Severity | Should -Be 'OK'
    }
    It 'warns above 1500 ms' {
        (Get-LinkBenchVerdict -Bench (New-TestBench -LinkMs 2000)).Severity | Should -Be 'Warning'
    }
    It 'flags above 4000 ms as a Problem' {
        (Get-LinkBenchVerdict -Bench (New-TestBench -LinkMs 5000)).Severity | Should -Be 'Problem'
    }
    It 'reports the object count it linked' {
        $v = Get-LinkBenchVerdict -Bench (New-TestBench -ObjectCount 31)
        ($v.Evidence -join ' ') | Should -Match '31 objects'
    }
}

Describe 'Compile benchmark integration' -Skip:$script:NoCompiler {
    It 'compiles a small project, links it, and reports positive timings' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "diagcompile-int-$PID"
        try {
            $tc = Resolve-CompileToolchain
            $project = New-CompileBenchProject -Root $root -TuCount 2 -HeaderCount 2
            Test-CompileToolchain -Toolchain $tc -Project $project -ObjDir (Join-Path $root 'preflight')
            $pass = Invoke-CompilePass -Toolchain $tc -Project $project -ObjDir (Join-Path $root 'obj') -JobCount 2
            $pass.ElapsedMs | Should -BeGreaterThan 0
            @(Get-ChildItem -Path $pass.ObjDir -Filter '*.obj').Count | Should -Be 3
            $link = Invoke-LinkBenchmark -Toolchain $tc -ObjDir $pass.ObjDir -ExePath (Join-Path $root 'out.exe')
            $link.ObjectCount | Should -Be 3
            $link.ElapsedMs | Should -BeGreaterThan 0
        } finally {
            Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
