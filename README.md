# Dev machine slowness diagnostic

Your build machine feels slow? Run this, send the report to IT.

## Usage

Open an elevated PowerShell (right-click - Run as administrator), then:

    powershell -ExecutionPolicy Bypass -File .\Diagnose-DevMachine.ps1

Takes about two minutes; moderate disk/CPU load while the benchmarks run.
The result is `DevMachineDiag-<machine>-<timestamp>.md` next to the script
(timestamp down to the second, e.g. `DevMachineDiag-BUILD01-20260819-153045.md`)
- findings ranked by severity with the evidence and a recommended fix where
one applies. Treat the report as internal (it contains machine name and paths)
and share it with IT.

You don't have to run it elevated - it still works. Without elevation,
BitLocker status comes back "Skipped" and some Defender policy details
may be hidden; the report always shows whether the run was elevated.

Optional deeper evidence (adds ~30 s, records which files Defender
spends scan time on):

    powershell -ExecutionPolicy Bypass -File .\Diagnose-DevMachine.ps1 -DefenderTrace

## Measuring real compilation (`-CompileBench`)

The default benchmarks measure compile-*shaped* work: small-file I/O and
process spawning. That misses what actually dominates a build - headers read
over and over, executable output, and the weight of a real compiler process.
`-CompileBench` generates a small C++ project in `%TEMP%`, compiles it three
times and links it:

    powershell -ExecutionPolicy Bypass -File .\Diagnose-DevMachine.ps1 -CompileBench

Adds roughly 30-45 s of heavy CPU load. It uses a compiler the machine
already has - `cl` (if you are in a VS developer prompt), else `clang-cl`,
`clang++`, `clang` or `g++`, else Visual Studio located via `vswhere`. Point
it at a specific one with `-CompileBenchCompiler <path>`. With no compiler
available the check is simply reported as Skipped.

The number to look at is **"Scan time attributable to the build"**, and
getting it needs both flags plus an elevated shell:

    powershell -ExecutionPolicy Bypass -File .\Diagnose-DevMachine.ps1 -CompileBench -DefenderTrace

That records what Defender actually spent scanning on behalf of the compiler
and reports it as a share of compile wall time. Under 5% means scanning is
not your bottleneck; above 20% means exclusions would pay for themselves.
It is a direct measurement, which is exactly why it is worth the elevation -
the timing-only numbers cannot separate scanning cost from ordinary compiler
work, and an earlier version of this tool got that wrong. See the amendment
in `docs/superpowers/specs/2026-09-09-compile-benchmark-design.md`.

Without `-DefenderTrace` you still get compile throughput, parallel scaling
and link time, which are enough to spot a badly misbehaving machine.

## What the numbers should look like

Every report opens with a **Measurements** table, so comparing two machines is
a matter of putting the tables side by side. A full example report is in
[`docs/example-report.md`](docs/example-report.md).

These are the measured numbers from that run - a fast desktop with Defender on,
no exclusions, and no third-party EDR:

| Measurement | Desktop, i7-12700K (12c/20t), NVMe |
| --- | --- |
| Compile throughput | 440 ms/TU (clang-cl) |
| Parallel compile scaling | 6.52x across 8 jobs (efficiency 0.82) |
| Small-file I/O | 0.59 ms/file write |
| Process spawn | 23 ms/spawn |
| Link | 31 objects in 134 ms |
| Scan time attributable to the build | 1.7% |

### What to expect on different machines

**These rows are estimates, not measurements.** Only the desktop row above has
been measured. The rest are extrapolated from it using sustained clocks, core
counts and the known cost of security agents, and they are here so a first-time
reader has *some* idea whether their number is bad. Treat them as a starting
point and please open an issue with real figures - a table of measured machines
would be far more useful than this one.

| | Compile (ms/TU) | Parallel eff. | Small-file I/O | Spawn | Scan share |
| --- | --- | --- | --- | --- | --- |
| Desktop, 8+ P-cores, NVMe *(measured)* | ~440 | 0.75-0.85 | ~0.6 ms | ~23 ms | 1-3% |
| Laptop, H-series 45-65 W | 500-700 | 0.55-0.75 | 0.6-1.5 ms | 25-40 ms | 2-5% |
| Laptop, thin-and-light 15-28 W | 700-1200 | 0.35-0.55 | 0.8-2.5 ms | 30-60 ms | 3-8% |
| Any of the above, plus a corporate EDR agent | +30-100% | 0.30-0.60 | 5-30 ms | 100-300 ms | 15-40% |

The bottom row is the one that matters. Hardware moves these numbers by a
factor of two or three; an EDR agent scanning every file read and hooking every
process creation moves them by an order of magnitude. If your laptop is slow
and the top three rows do not explain it, the agent almost certainly does - and
the scan-share figure is how you demonstrate that rather than assert it.

**A caveat on parallel efficiency.** Efficiency is speedup divided by job
count, and the job count is `min(logical processors, 8)`. On a machine whose
job count exceeds its *physical* cores - any 4-core laptop with hyperthreading -
the ceiling is structurally around 0.5 to 0.65, because eight jobs are sharing
four real cores. A laptop scoring 0.55 is not necessarily contended; a desktop
scoring 0.55 probably is. The 0.40 Warning threshold was set from desktop
measurements and may want normalising by physical core count.

## Running the tests

    pwsh -File .\Invoke-Tests.ps1

The suite needs Pester 5 or newer. Windows ships Pester 3.4, which imports
cleanly and then rejects the syntax, so the failure is more confusing than it
should be. `Invoke-Tests.ps1` checks for a usable Pester, and if there is not
one, saves a copy into the git-ignored `.tools/` directory and uses it for that
run only - nothing outside the repository is touched. If Pester 5+ is already
installed, it is used and nothing is downloaded.

    pwsh -File .\Invoke-Tests.ps1 -Path .\tests\CompileBench.Tests.ps1 -Output Detailed
    pwsh -File .\Invoke-Tests.ps1 -Reinstall

The first step needs access to the PowerShell Gallery. Behind a proxy that
blocks it, install Pester 5+ by hand and re-run; the script will find it.

## Safety

The tool changes no machine state - it reads configuration, writes only its
own `%TEMP%` scratch folders and the report, and makes no network
connections. With `-CompileBench` it additionally runs an already-installed
compiler over source it generated itself; the executable that produces is
never run. IT/security reviewers: see RISK-ASSESSMENT.md.
