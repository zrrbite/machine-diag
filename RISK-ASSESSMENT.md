# Risk assessment: Diagnose-DevMachine.ps1

Audience: IT / security reviewers deciding whether developers may run
this script elevated. The script is a single plaintext PowerShell file
(716 lines, no obfuscation, no embedded binaries, nothing downloaded),
so every claim below is verifiable by reading it.

## Purpose

Developers report slow builds. The script collects configuration
evidence and runs two micro-benchmarks to identify likely causes
(security-software scanning overhead, power management, disk issues),
producing a Markdown report the developer hands to IT. It recommends
fixes; it applies none.

## What it reads

- Microsoft Defender status and preferences (`Get-MpComputerStatus`,
  `Get-MpPreference`) - real-time protection state, exclusion lists. The
  script detects Defender running in Passive Mode or EDR Block Mode
  (another product is the primary scanner) and skips the exclusion-gap
  evaluation in that case; when zero exclusions are configured it also
  notes that exclusion lists can be hidden from local admins by policy
  (`HideExclusionsFromLocalAdmins`), so that reading may not be real.
- Installed service names/display names (`Get-Service`) - matched against
  a built-in catalog of known security/management products, plus a direct
  status check of the Windows Search indexer service (`WSearch`).
- Active power scheme (`powercfg /getactivescheme`), resolved by GUID
  against a table of well-known plan GUIDs for the four built-in Windows
  plans; custom or OEM plans fall back to the localized display name. This
  ensures correct identification regardless of OS display language/locale for
  standard plans. Also Kernel-Processor-Power throttle events (Id 37, last 7
  days) from the System event log.
- BitLocker volume status (`Get-BitLockerVolume`).
- CIM classes: `Win32_OperatingSystem`, `Win32_Processor`,
  `Win32_DeviceGuard` (HVCI/memory-integrity status), and
  `Win32_PerfFormattedData_PerfOS_Memory` (`AvailableMBytes`, used for the
  memory-pressure check because it includes reclaimable standby cache;
  falls back to `Win32_OperatingSystem.FreePhysicalMemory` if that class
  is unavailable); `Get-PhysicalDisk`, `Get-Volume`.
- Three registry keys indicating a pending reboot (read-only `Test-Path`
  / `Get-ItemProperty`).
- Process list (`Get-Process`) for the top-5 memory consumers.
- Existence (`Test-Path`) of common development directory locations.

## What it writes

1. A temporary benchmark folder under `%TEMP%`. By default 2,000 files,
   4 KB each; each file's content is unique (its index is stamped into
   the payload) so Defender's scan-result caching can't skip repeat
   files and the benchmark reflects real per-file scan cost. Deleted in
   a `finally` block.
2. The report file `DevMachineDiag-<host>-<yyyyMMdd-HHmmss>.md` in the
   current directory.
3. With `-DefenderTrace` only: a second temporary benchmark folder (the
   file benchmark re-run in a background job while Defender activity is
   recorded) and a Defender performance recording `.etl`, both under
   `%TEMP%` and both deleted in a `finally` block.

There are no other writes. In particular the script never calls any
`Set-*` cmdlet other than `Set-StrictMode` (a script-local interpreter
setting) and `Set-Content` (writing the report file), and the only
`New-Item` calls create the temporary benchmark folders described above.

## What it never does

- No configuration changes of any kind; antivirus is never toggled,
  paused, or reconfigured.
- No network access - no web requests, no DNS lookups, no uploads. The
  report stays on the machine until the developer shares it.
- No reading of user documents or file contents outside its own
  temporary benchmark files.
- No persistence: nothing installed, no scheduled tasks, no services,
  nothing left behind except the report the user asked for.
- No credential or token access.

## Why elevation is requested

`Get-BitLockerVolume` requires administrator rights. The script runs without
elevation too: it prints a warning that BitLocker status will be unavailable,
and every report includes an "Elevation" entry stating whether the run was
elevated. A failed BitLocker check is recorded as "Skipped" with the reason;
the rest of the checks and both benchmarks still run.

## Resource impact

Roughly one to two minutes of moderate disk and CPU usage from the
benchmarks (small-file I/O in `%TEMP%`, 100 short-lived `cmd /c exit`
processes by default). `-DefenderTrace` adds a ~30-second Defender
performance recording (first-party Microsoft tooling,
`New-MpPerformanceRecording`) while the file benchmark runs again in the
background.

## Data sensitivity of the report

The report contains the hostname, hardware summary, service names,
counts of configured Defender exclusions, and the names of common development
directories found on the machine that are not covered by an exclusion - paths
may embed usernames. It contains no file contents, no credentials. Treat it
as internal; share only with IT.

## Failure behavior

Every check runs inside a try/catch (`Invoke-DiagCheck`); a failing or
unavailable check is recorded as "Skipped" with the reason and the run
continues. The script cannot leave the system in a modified state
because it never modifies the system.
