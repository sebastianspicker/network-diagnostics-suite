# Migrating from Network Diagnostics Suite

Network Lantern replaces the previous public command and module names. There
are no command aliases for the old names.

| Previous path or name | Current path or name |
| --- | --- |
| `Invoke-NetworkDiagnostics.ps1` | `Invoke-NetworkLantern.ps1` |
| `apps/path/NetPathSuite.ps1` | `apps/path/Test-NetworkPath.ps1` |
| `apps/path/mtr-test-suite.sh` | `apps/path/test-network-path.sh` |
| `apps/throughput/iPerf3Test.ps1` | `apps/throughput/Measure-NetworkThroughput.ps1` |
| `apps/throughput/iPerf3Test-GUI.ps1` | `apps/throughput/Measure-NetworkThroughput-GUI.ps1` |
| `apps/windows-tuning/Optimize-NetworkPath.ps1` | `apps/windows-tuning/Invoke-NetworkPathTuning.ps1` |
| `apps/windows-tuning/Optimize-NetworkPath-GUI.ps1` | No GUI replacement; use `apps/windows-tuning/Invoke-NetworkPathTuning.ps1` |
| `Iperf3TestSuite` | `NetworkLantern.Throughput` |
| `WindowsUdpJitterOptimization` | `NetworkLantern.WindowsTuning` |
| `Get-NdsDefaultBackupFolder` | `Get-NetworkLanternDefaultBackupFolder` |
| `Test-UjIsAdministrator` | `Test-NetworkTuningAdministrator` |

Update scripts, module imports, runbooks, and saved command examples to the new
names.

Recheck these behaviors during migration:

- `Baseline` requires `-IperfTarget` and runs Path followed by one throughput
  test.
- `Triage` always runs Path and runs Throughput only when `-IperfTarget` is
  supplied.
- The orchestrator returns a nonzero child exit code unchanged.
- Path and tuning previews use `-DryRun`; throughput previews use `-WhatIf`.
- Throughput named profiles are managed through the direct throughput
  entrypoint, not the orchestrator.

For tuning restore compatibility, the module can use
`%ProgramData%\NetworkDiagnosticsSuite` when the current default backup folder
has no manifest. The older backup must still pass current manifest, component,
artifact, digest, registry-content, and path-trust validation.

The module recognizes selected legacy QoS name prefixes so it can manage state
created by previous versions. This compatibility does not extend to unrelated
QoS policies.
