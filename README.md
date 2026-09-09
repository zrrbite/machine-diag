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

## Safety

The tool changes no machine state - it reads configuration, writes only its
own `%TEMP%` scratch folders and the report, and makes no network
connections. With `-CompileBench` it additionally runs an already-installed
compiler over source it generated itself; the executable that produces is
never run. IT/security reviewers: see RISK-ASSESSMENT.md.
