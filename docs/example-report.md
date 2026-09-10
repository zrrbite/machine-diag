# Example report

A real, unedited run of `Diagnose-DevMachine.ps1 -CompileBench -DefenderTrace`,
elevated, kept here so you have something to compare your own report against.

**Machine:** desktop workstation, Intel i7-12700K (12 cores / 20 threads),
32 GB RAM, Samsung 980 PRO NVMe, Windows 11 Pro for Workstations build 26200.
Microsoft Defender with real-time protection on and no exclusions configured;
no third-party EDR agent. Compiler: clang-cl 22.1.3.

This is a *fast desktop with a permissive security configuration*. A corporate
laptop running an EDR agent will look considerably worse, and that is the point
of the comparison - see "What to expect on different machines" in the README.

Two things worth noticing in it:

- The one Problem is the Defender exclusion gap, which is a configuration
  finding rather than a measured one.
- "Scan time attributable to the build" is 1.8%. Scanning is genuinely not
  this machine's bottleneck, despite there being no exclusions at all. That
  number is the one to argue an exclusions request on; the timing-only figures
  cannot separate scanning cost from ordinary compiler work.

---

# Dev machine diagnostic - ZRRBITE-PC

Generated 2026-09-10 07:34 by Diagnose-DevMachine.ps1.
This tool is read-only; see RISK-ASSESSMENT.md. Report may contain machine
names and file paths - treat as internal, share with IT only.

**Checks:** 1 Problem, 3 Warning, 7 Info, 12 OK

## Summary

1 problem and 3 warnings on ZRRBITE-PC. 12 checks passed.

| Severity | Finding | Key measurement |
| --- | --- | --- |
| Problem | Defender exclusion gaps (Security) | 3 dev directories and 20 toolchain processes not excluded |
| Warning | Pending reboot (OS) | Session Manager: PendingFileRenameOperations |
| Warning | CPU throttling events (Power) | 12 Kernel-Processor-Power throttle events in the System log (last 7 days) |
| Warning | Disk space (F:) (Storage) | F: 60.9 GB free of 465.7 GB (13.1%) |

### Recommended actions, most important first

1. Ask IT to add Defender exclusions for the dev/build directories and toolchain processes listed above. Microsoft documents this for dev machines: https://learn.microsoft.com/en-us/defender-endpoint/configure-exclusions-microsoft-defender-antivirus
2. Reboot the machine; a half-applied update can degrade performance.
3. CPU is being thermally or firmware throttled. Check cooling, dock/PSU wattage, and BIOS power settings.
4. Low free space can slow SSD writes; free up space.

Full evidence for every check follows.

## Measurements

| Measurement | Result | Verdict |
| --- | --- | --- |
| Compile repeat-pass timing | Repeat-pass speedup 1x | Info |
| Compile throughput | 440.7 ms/TU with clang-cl | OK |
| Link benchmark | 31 objects in 146 ms | OK |
| Parallel compile scaling | 6.19x on 8 cores (efficiency 0.77) | OK |
| Process-spawn benchmark | 22.6 ms/spawn | OK |
| Scan time attributable to the build | 1.8% of compile time in Defender scanning | OK |
| Small-file I/O benchmark | 0.58 ms/file write | OK |

Reference numbers from a known-good machine are in the project README.

## Problem

### Defender exclusion gaps (Security)
- Real-time protection: ON
- Path exclusions configured: 0
- Process exclusions configured: 0
- Extension exclusions configured: 0
- Dev directories present but NOT excluded: C:\dev, C:\Users\kjeld\source, C:\Users\kjeld\source\repos
- Toolchain processes NOT excluded: cl.exe, link.exe, lib.exe, msbuild.exe, devenv.exe, cmake.exe, ninja.exe, make.exe, gcc.exe, g++.exe, ld.exe, arm-none-eabi-gcc.exe, arm-none-eabi-g++.exe, armclang.exe, iccarm.exe, iarbuild.exe, git.exe, node.exe, python.exe, Code.exe
- Note: exclusion lists can be hidden from local admins by policy (HideExclusionsFromLocalAdmins) - zero configured exclusions may not be real; confirm with IT.

**Recommended action:** Ask IT to add Defender exclusions for the dev/build directories and toolchain processes listed above. Microsoft documents this for dev machines: https://learn.microsoft.com/en-us/defender-endpoint/configure-exclusions-microsoft-defender-antivirus

## Warning

### Pending reboot (OS)
- Session Manager: PendingFileRenameOperations

**Recommended action:** Reboot the machine; a half-applied update can degrade performance.

### CPU throttling events (Power)
- 12 Kernel-Processor-Power throttle events in the System log (last 7 days)

**Recommended action:** CPU is being thermally or firmware throttled. Check cooling, dock/PSU wattage, and BIOS power settings.

### Disk space (F:) (Storage)
- F: 60.9 GB free of 465.7 GB (13.1%)

**Recommended action:** Low free space can slow SSD writes; free up space.

## Info

### Compile repeat-pass timing (Benchmark)
- First pass: 13661.1 ms; immediate repeat of the same sources: 13635.7 ms
- Repeat-pass speedup: 1x
- Context only. A rebuild is dominated by parsing rather than I/O, so a ratio near 1.00x is expected even on a healthy machine and does NOT by itself indicate antivirus interference.
- To measure scanning cost directly, run with -DefenderTrace and read the "Scan time attributable to the build" finding.

### Machine inventory (Inventory)
- OS: Microsoft Windows 11 Pro for Workstations build 26200
- CPU: 12th Gen Intel(R) Core(TM) i7-12700K (12 cores / 20 threads)
- RAM: 31.8 GB
- Uptime: 0.5 days

### Windows Search indexer (OS)
- WSearch service: Running

**Recommended action:** If source trees are indexed, exclude them (Indexing Options) - the indexer re-scans every build output.

### Elevation (OS)
- Running elevated: True

### Power plan (Power)
- Active plan: Balanced

**Recommended action:** Consider the High performance plan for build machines.

### Defender performance trace (Security)
- Workload traced: compile benchmark (clang-cl)
- Scanned file: C:\Users\kjeld\AppData\Local\Temp\DevMachineDiag-trace-bench-45508\obj-trace\tu10-6316ec59.obj.tmp - 11 ms total scan time over 1 scans
- Scanned file: C:\Users\kjeld\AppData\Local\Temp\DevMachineDiag-trace-bench-45508\obj-trace\tu15-0c574abb.obj.tmp - 10 ms total scan time over 1 scans
- Scanned file: C:\Users\kjeld\AppData\Local\Temp\DevMachineDiag-trace-bench-45508\obj-trace\tu22-ba563b61.obj.tmp - 10 ms total scan time over 1 scans
- Scanned file: C:\Users\kjeld\AppData\Local\Temp\DevMachineDiag-trace-bench-45508\obj-trace\tu19-8a0f78c6.obj.tmp - 10 ms total scan time over 1 scans
- Scanned file: C:\Users\kjeld\AppData\Local\Temp\DevMachineDiag-trace-bench-45508\obj-trace\tu0-db7edb4d.obj.tmp - 10 ms total scan time over 1 scans
- Scanned on behalf of process: C:\Users\kjeld\scoop\apps\llvm\22.1.3\bin\clang-cl.exe - 240 ms over 31 scans
- Scanned on behalf of process: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe - 18 ms over 33 scans
- Scanned on behalf of process: C:\Program Files (x86)\Dropbox\Client\Dropbox.exe - 9 ms over 1 scans
- Scanned on behalf of process: C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe - 7 ms over 1 scans
- Scanned on behalf of process: C:\Program Files\Intel\SUR\QUEENCREEK\x64\esrv_svc.exe - 5 ms over 1 scans
- Extension .tmp - 240 ms over 31 scans
- Extension .cpp - 17 ms over 31 scans
- Extension .bin - 9 ms over 1 scans
- Extension .dat - 7 ms over 1 scans
- Extension .sdt - 5 ms over 1 scans

**Recommended action:** This is first-party Microsoft data on what Defender spent scan time on. If build files/toolchain dominate, it directly justifies the exclusion request.

### Physical disks (Storage)
- Disk: Samsung SSD 980 PRO 1TB - SSD, 932 GB
- Disk: Samsung SSD 970 EVO Plus 500GB - SSD, 466 GB

## OK

### Compile throughput (Benchmark)
- Compiler: clang-cl - C:\Users\kjeld\scoop\apps\llvm\current\bin\clang-cl.exe
- Toolchain resolved by: clang-cl on PATH
- Compiled 31 translation units sequentially in 13661.1 ms (440.7 ms/TU, first pass)
- Heuristic reference: 400-900 ms/TU is normal for this generated project on a modern desktop CPU; above 1800 ms/TU indicates heavy per-file or per-process interference
- These thresholds are compiler- and CPU-dependent and are not yet calibrated across a range of machines - read them alongside the scan-time measurement, not on their own

### Scan time attributable to the build (Benchmark)
- Defender scan time on behalf of clang-cl: 239.8 ms
- Traced compile wall time: 13630.8 ms
- Share of build time spent in Defender scanning: 1.8%
- Measured from the Defender trace, not inferred from timings. This is the number an exclusions request should be argued on.
- Heuristic reference: under 5% means scanning is not the bottleneck; above 20% means exclusions would pay for themselves

### Link benchmark (Benchmark)
- Linked 31 objects into one executable in 146 ms
- Link output is a PE file, which real-time AV inspects far more deeply than object or source files.
- Heuristic reference: healthy < 1500 ms for a project this size; > 4000 ms points at scan-on-write of the produced binary

### Parallel compile scaling (Benchmark)
- Sequential: 13661.1 ms; 8 concurrent jobs: 2206 ms
- Speedup: 6.19x - efficiency 0.77 against 8 usable cores (12 physical)
- Efficiency is measured against physical cores rather than job count or threads. Eight jobs on a four-core laptop cannot exceed roughly 4-5x however healthy the machine is, so dividing by the job count would report a fault on hardware that is behaving correctly.
- Heuristic reference: efficiency below 0.40 suggests a serialising bottleneck - AV/EDR contention, disk, or thermal throttling. Values near or above 1.0 are normal where hyperthreading is contributing.

### Small-file I/O benchmark (Benchmark)
- Wrote 2000 small files in 1158.5 ms (0.58 ms/file)
- Read back in 185 ms; deleted in 332.4 ms
- Heuristic reference: healthy SSD < 2 ms/file write; heavy AV/EDR scanning commonly shows 5-30 ms/file

### Process-spawn benchmark (Benchmark)
- Spawned 100 short-lived processes in 2256.7 ms (22.6 ms/spawn)
- Heuristic reference: healthy < 30 ms/spawn; EDR process-hooking overhead commonly shows 100-300 ms/spawn

### Memory pressure (Memory)
- 31.8 GB total, 11.6 GB free (36.6%)
- Top consumer: Memory Compression 2098 MB
- Top consumer: chrome 546 MB
- Top consumer: MsMpEng 501 MB
- Top consumer: Dropbox 497 MB
- Top consumer: chrome 482 MB

### Memory integrity (HVCI) (OS)
- HVCI not running

### Processor power limits (Power)
- Max processor state (AC): 100%
- Min processor state (AC): 5%

### Third-party security agents (Security)
- No known third-party security/management agents detected

### Disk space (C:) (Storage)
- C: 237.6 GB free of 930.6 GB (25.5%)

### BitLocker (Storage)
- No encrypted volumes (or BitLocker not in use)

