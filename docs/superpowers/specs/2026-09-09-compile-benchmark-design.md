# Compile benchmark (`-CompileBench`) — design

**Date:** 2026-09-09
**Status:** Approved, amended 2026-09-09 after first measurement (see Amendment)

## Problem

The Phase-3 benchmarks measure compile-*shaped* work, not compilation. The
small-file benchmark writes inert 4 KB blobs whose first bytes are stamped
per-file specifically to defeat AV scan-result caching, and the spawn
benchmark launches `cmd /c exit`. Both are useful, but they miss the
mechanisms that dominate a real build:

- **Header re-reads.** A build reads the same headers hundreds or thousands
  of times. That exercises scan-result *caching* — exactly what the
  small-file benchmark is engineered to defeat. Today we measure the
  pessimistic case and report it as if it characterised builds.
- **Executable output.** Defender inspects PE files far more deeply than
  `.c`/`.o` data. Nothing currently produces a PE, so the deepest scan path
  is never exercised.
- **Real process weight.** `cmd.exe` is a tiny, already-cached image. A
  compiler front-end maps hundreds of megabytes and loads many DLLs, and
  per-process AV/EDR overhead scales with image size and page-fault count.
  A healthy 22 ms/spawn for `cmd.exe` can coexist with a badly punished
  `cl.exe`.

Observed on ZRRBITE-PC 2026-09-09: both existing benchmarks reported OK
while Defender ran with no exclusions for `C:\dev` or any of twenty
toolchain executables. The tool could not say what that costs per build.

## Goal

Turn the "Defender exclusion gaps" finding from a recommendation into a
number: seconds of build time attributable to scanning.

## Constraints

- Preserves the tool's core promise: reads system state, writes only its own
  temp directory and the report. No configuration changes, no network.
- Must degrade cleanly on machines with no compiler — a corporate laptop
  running the diagnostic is not guaranteed to have a toolchain.
- Zero-install: no package downloads, no vendored source. The benchmark
  project is generated at runtime.
- Bounded runtime. Target under 45 s added.

## Approach (chosen)

An opt-in `-CompileBench` phase, structured like the existing
`-DefenderTrace` phase: off by default, its own collector function, all
artefacts under `%TEMP%\DevMachineDiag-compile-$PID`, removed in a
`finally` block.

Opt-in rather than default because it requires a toolchain, adds runtime,
and its absolute numbers are compiler-dependent in a way the existing
benchmarks' are not.

Rejected alternatives:

- **Building a real open-source project.** Requires a download; violates
  zero-install and makes the measurement dependent on network conditions.
- **Making it default-on with graceful skip.** Most runs are on machines
  where the developer already knows their build is slow; the flag costs one
  word and keeps the default run at ~2 minutes.
- **Timing the developer's actual build.** Ideal evidence, but the tool
  cannot know how to invoke an arbitrary build, and a partial build gives
  non-comparable numbers between runs.

## Toolchain selection

Resolved by `Resolve-CompileToolchain`, in order:

1. `cl.exe` already on `PATH` — the developer ran from a VS developer
   prompt, so MSVC is what their real builds use.
2. `clang-cl.exe`, then `clang.exe`, then `g++.exe` on `PATH`.
3. MSVC discovered via `vswhere.exe` at its fixed Program Files (x86)
   location, importing the environment from `VsDevCmd.bat -arch=x64` (run
   under `cmd /c ... && set`, parsed back into the phase's environment
   only — never persisted).

If none resolves, the check returns `Skipped` with the search order in the
evidence. `-CompileBenchCompiler <path>` overrides the search entirely.

The selected compiler and how it was found are always recorded in the
evidence. Timings without that context are meaningless.

## Benchmark project

Generated deterministically by `New-CompileBenchProject`:

- `$TuCount` translation units (default 30), `.cpp`.
- A shared set of `$HeaderCount` headers (default 8) that every TU includes,
  each carrying enough template and inline content to give the front-end
  real work rather than measuring process startup alone.
- Each TU defines a uniquely named symbol so the objects link.
- One `main.cpp` providing an entry point.

C++ rather than C: templates and header depth are what actually cost time,
and all four candidate compilers handle it.

The linked executable is produced but **never executed**. Stated explicitly
because "the diagnostic compiles and runs generated code" would be a
materially different security claim than "compiles it".

## Measurements

Four timings, from `Invoke-CompileBenchmark`:

| Measure | What it isolates |
| --- | --- |
| **Cold compile** | Sequential compile of all TUs to objects, fresh directory. Baseline ms/TU. |
| **Warm recompile** | Immediate repeat, same sources. Headers now in FS cache and AV scan cache. |
| **Parallel compile** | Same TUs across `min(cores, 8)` concurrent jobs. Scaling under contention. |
| **Link** | Objects into one executable, timed separately. The PE-inspection path. |

~~The **cold/warm ratio** is the primary signal.~~ **Superseded — see
Amendment.** The primary signal is the scan share measured under
`-DefenderTrace`; the cold/warm ratio is reported as context only.

## Verdicts

`Get-CompileBenchVerdict`, `Get-LinkBenchVerdict` and
`Get-BuildScanShareVerdict`, pure functions over the timing object,
following the existing evaluator pattern.

Thresholds — **heuristics**, annotated as such in the report exactly as the
existing benchmark references are:

- Scan share (Defender scan time on behalf of the compiler ÷ compile wall
  time): `Problem` above 20%, `Warning` above 5%, otherwise `OK`. Available
  only with `-DefenderTrace`, because there is no proxy for it.
- Cold ms/TU: `Warning` above 900, `Problem` above 1800. Compiler- and
  CPU-dependent; reported alongside the compiler name, and not yet
  calibrated across a range of machines.
- Repeat-pass speedup: reported as `Info`, never a verdict.
- Parallel efficiency (speedup ÷ job count): `Warning` below 0.40.
- Link: `Warning` above 1500 ms, `Problem` above 4000 ms for the generated
  project size.

## Interaction with `-DefenderTrace`

When both flags are given, the Defender recording is taken over the
**compile** benchmark instead of the file benchmark. Attributing scan time
to `cl.exe`, `.obj` and real header paths is far stronger evidence for an
exclusions request than attributing it to synthetic `.c` blobs. The traced
compile's own wall time is returned from the background job, which is what
makes the scan-share measurement possible.

## Output

Results join the existing report under a `Benchmark` category, with the
compiler identity in the evidence. No change to report structure or the
severity ranking.

## Risk assessment

`RISK-ASSESSMENT.md` gains a section for this phase. The new class of
activity is *executing a large third-party binary* (the compiler) rather
than only reading state, and generating source files. Both are confined to
the temp directory; the produced executable is never run.

## Testing

New `tests/CompileBench.Tests.ps1`, following the existing style
(`. $PSScriptRoot/../Diagnose-DevMachine.ps1 -LibraryMode`):

- `New-CompileBenchProject` — generates the requested counts, every TU
  includes the shared headers, symbol names are unique.
- `Get-CompileBenchVerdict` / `Get-LinkBenchVerdict` — threshold boundaries
  in both directions, evidence strings contain the measured numbers.
- `Resolve-CompileToolchain` — override path honoured; unresolvable search
  reports the order it tried.
- `Invoke-CompileBenchmark` — smoke test, skipped when no compiler is
  present so the suite still passes on the macOS dev machine.

## Amendment, 2026-09-09: the cold/warm ratio was the wrong signal

First measurement on ZRRBITE-PC (i7-12700K, clang-cl, Defender on with no
exclusions) reported a repeat-pass speedup of **1.00x**, which the original
thresholds called a `Problem`. Running the same workload under
`-DefenderTrace` showed why that verdict was wrong:

```
Extension .exe - 353 ms over 1 scans     (clang-cl.exe itself, once)
Extension .tmp - 244 ms over 31 scans    (the .obj files)
Extension .cpp -  17 ms over 31 scans
```

Defender spent roughly 260 ms on build files during a compile pass of
13,683 ms — about **1.9%**. Headers do not appear in the top files or
extensions at all. Parallel efficiency was 0.72, also ruling out scanning
contention.

The ratio was therefore measuring the wrong thing. A full recompile is
CPU-bound on **parsing**, not I/O: every TU re-parses every header
regardless of what is cached, so a repeat pass has almost no I/O to save
even on a machine with no scanning whatsoever. A ratio near 1.00x is the
expected healthy result, not a fault. The claim in Measurements above that
"absolute ms/TU varies with compiler, machine and project; the ratio does
not" was asserted without evidence and is false.

The 400 ms/TU Warning threshold was wrong for the same reason: 441 ms/TU
was the *no-interference* figure on this hardware.

Changes made:

1. Repeat-pass speedup demoted to `Info` under the name "Compile
   repeat-pass timing", with evidence explicitly telling the reader not to
   read interference into it.
2. New `Get-BuildScanShareVerdict`: scan time attributed to the compiler
   process, as a share of the traced compile's wall time. Measured, not
   inferred. This is what the ratio was trying and failing to approximate,
   and it requires `-DefenderTrace`.
3. Cold ms/TU thresholds raised to 900 (Warning) and 1800 (Problem), and
   labelled in-report as not yet calibrated across machines.

The general lesson for future thresholds here: a ratio between two runs of
the same CPU-bound workload cannot isolate an I/O-side cost. Prefer a
direct measurement, even when it costs a flag and elevation to obtain.

## Out of scope (YAGNI)

- Comparing against a known-good baseline machine or historical runs.
- Building the developer's real project.
- Incremental-build simulation beyond the warm recompile.
- Detecting or recommending `ccache`/`sccache`.
- Measuring IDE responsiveness or IntelliSense.
