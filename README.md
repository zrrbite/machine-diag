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

The tool is strictly read-only - it changes nothing on the machine.
IT/security reviewers: see RISK-ASSESSMENT.md.
