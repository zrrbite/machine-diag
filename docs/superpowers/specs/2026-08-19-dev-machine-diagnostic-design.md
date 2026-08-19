# Windows dev-machine slowness diagnostic — design

**Date:** 2026-08-19
**Status:** Approved

## Problem

Work Windows machines have become slow, most noticeably for builds and other
dev work (compiles, IDE, git). Developers need a tool they can run themselves
that identifies the likely causes and produces an evidence report they can
hand to IT to justify fixes (e.g., antivirus exclusions).

## Constraints

- Target: corporate Windows 10/11 machines. Developers have local admin.
- Zero-install distribution: colleagues get one file, run it, done.
- Must be demonstrably safe — IT/security will want to vet it before letting
  people run an elevated script. A risk assessment document ships with it.
- Strictly read-only against system state. It never changes settings,
  never toggles or disables AV, makes no network connections.

## Deliverables

Repository `machine-diag` containing:

1. `Diagnose-DevMachine.ps1` — single-file PowerShell diagnostic.
2. `RISK-ASSESSMENT.md` — safety/security review aimed at IT.
3. `README.md` — brief usage instructions for colleagues.

## Approach (chosen)

Single self-contained PowerShell script, run elevated:

```
powershell -ExecutionPolicy Bypass -File .\Diagnose-DevMachine.ps1
```

Rejected alternatives: a PowerShell module (distribution friction outweighs
code-structure benefits) and a compiled Go/C# tool (unsigned executables are
exactly what corporate EDR blocks; far more maintenance for a
run-occasionally diagnostic).

## Script behavior

Four phases. Every individual check is wrapped in try/catch; a failure is
recorded in the report as "skipped: <reason>" and the run continues. If not
elevated, the script warns, marks admin-only checks as skipped, and still
runs everything it can.

### Phase 1 — Inventory

CPU model and core count, total RAM, physical disk type (SSD/HDD via
`Get-PhysicalDisk` MediaType) and free space per volume, OS version/build,
uptime, pending-reboot indicators.

### Phase 2 — Configuration checks

- **Defender:** real-time protection state, scan settings, and the exclusion
  lists (paths, processes, extensions). Flag when common dev locations and
  toolchain processes are unexcluded.
- **Other security/management agents:** detect by known service/process
  names (CrowdStrike Falcon, SentinelOne, Cortex XDR, Carbon Black,
  Netskope, Zscaler, Tanium, Ivanti, Qualys, etc.). Presence is reported as
  context — the tool cannot see their per-file cost directly, but the
  benchmarks below measure the aggregate effect.
- **Power:** active power plan, processor min/max state, and
  Kernel-Processor-Power throttle events from the System event log.
- **Disk/storage:** BitLocker status per volume, low-free-space warnings.
- **Windows Search:** whether the indexer's scope covers source/build trees.
- **VBS/HVCI:** memory-integrity state (measurable overhead on some
  workloads).
- **Memory pressure:** committed vs. available, top memory consumers.

### Phase 3 — Benchmarks

Compile-shaped micro-benchmarks in a dedicated temp folder (deleted
afterwards), timed with reference ranges annotated as heuristics:

- **Small-file I/O:** create a few thousand ~4 KB files across nested
  directories, read them back, delete them. This is what a compiler does,
  and it is the workload real-time AV scanning punishes hardest.
- **Process spawn:** launch ~100 short-lived processes (`cmd /c exit`).
  EDR hooks process creation; slow spawn times point at agent overhead.

Slow benchmark numbers combined with Phase-2 config gaps (e.g., no
exclusions + multiple agents) form the report's core evidence.

### Phase 4 — Optional Defender trace (`-DefenderTrace`)

With the flag set, record a `New-MpPerformanceRecording` trace while
re-running the file benchmark, and include the top scan-time offenders
(files/processes/extensions Defender spent the most time on) in the report.
This is first-party Microsoft tooling and the strongest evidence for an
exclusions request. Off by default because it takes longer and records
file-path data.

## Output

- Colored console summary as checks run.
- `DevMachineDiag-<hostname>-<yyyyMMdd-HHmm>.md` written next to the script:
  findings ranked by severity (problem / warning / info / ok), each with the
  measured evidence and a concrete recommended IT action. Skipped checks
  listed at the end with reasons.

## Risk assessment document

`RISK-ASSESSMENT.md`, written for an IT/security reviewer:

- Purpose and scope of the tool.
- Exactly what it reads (config queried, event logs, WMI/CIM classes).
- Exactly what it writes (its temp benchmark folder, the report file) and
  that both are the only writes.
- What it never does: no configuration changes, no AV toggling, no network
  access, no reading of user documents, no persistence, nothing installed.
- Why elevation is requested (Defender config, BitLocker, event-log access)
  and what degrades without it.
- Resource impact: roughly 1–2 minutes of moderate disk and CPU load from
  the benchmarks; Defender trace adds recording overhead while active.
- Data sensitivity: the report contains hostname, hardware info,
  service/process names, and file paths that may embed usernames — treat
  the report as internal, share only with IT.
- Reviewability: plaintext script, no obfuscation, no downloaded content.

## Testing

Development happens on macOS, so:

- Pure logic (threshold evaluation, severity ranking, report rendering) is
  isolated in functions and smoke-tested under `pwsh` where possible.
- The full script gets a parse/syntax validation locally.
- Final validation is a real run on a work Windows machine — tracked as a
  follow-up task for Martin.

## Out of scope (YAGNI)

- Fleet-wide deployment/aggregation and machine-readable (JSON) output.
- Network/VPN throughput diagnosis.
- Any remediation — the tool diagnoses and recommends; IT applies fixes.
