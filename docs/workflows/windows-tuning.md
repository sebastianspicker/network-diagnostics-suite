# Windows tuning

Windows tuning is optional. Path and throughput diagnostics do not depend on
it. Use verification and dry-run planning before considering a state change.

## Actions

| Action | Behavior | Elevation |
| --- | --- | --- |
| `Verify` | Reads local QoS enablement and requested managed port policies | No |
| `Backup` | Exports supported registry, QoS, NIC, RSC, and power-plan state | Yes, except `-DryRun` |
| `Apply` | Backs up current state, verifies the backup, then applies the selected profile | Yes, except `-DryRun` |
| `Restore` | Validates and restores a prior backup | Yes, except `-DryRun` |

The CLI exits 0 when its structured result reports success and 1 otherwise.
Add `-PassThru` to return the structured result to the pipeline.

## Profiles

| Profile | Apply behavior |
| --- | --- |
| `Safe` | Enables local QoS marking and creates requested UDP port or application DSCP policies |
| `Measured` | Applies `Safe`, disables supported NIC power-saving properties, and selects the High Performance power plan by default |

The profile names describe two comparison sets. They do not guarantee a
latency or throughput improvement. See the
[tuning evidence matrix](../evidence/tuning-matrix.md) for the exact included
and excluded settings.

## Preview

Preview `Safe` with one UDP port policy:

```powershell
pwsh -NoProfile -File .\apps\windows-tuning\Invoke-NetworkPathTuning.ps1 `
  -Action Apply -TuningProfile Safe -UdpPorts 5201 -DryRun -PassThru
```

`-DryRun` validates inputs and prints planned operations. It does not require
elevation or write a backup, registry value, QoS policy, NIC property, or power
plan.

A `Measured` preview attempts to enumerate active physical adapters. If that
enumeration is unavailable, the command can return `Success = True` while
reporting `NicPowerSaving` as `Skipped`. Inspect `Components`, `Warnings`, and
the warning stream.

## Verify

Check local QoS enablement and the managed policy for UDP port 5201:

```powershell
pwsh -NoProfile -File .\apps\windows-tuning\Invoke-NetworkPathTuning.ps1 `
  -Action Verify -UdpPorts 5201 -PassThru
```

`Verify` requires Windows and `Get-NetQosPolicy`. It reports failure when local
QoS marking is absent, a requested managed port policy is missing, or QoS state
cannot be enumerated. It does not verify NIC or power-plan state.

## Backup and apply

The default backup folder is `%ProgramData%\NetworkLantern`. Use
`-BackupFolder` to choose another trusted path.

On first use, the module validates the existing `%ProgramData%` ancestor for
SYSTEM ownership, safe ACL semantics, and reparse-point takeover before it
creates the `NetworkLantern` child with an exact Administrators/SYSTEM-only
ACL. Custom folders still require an already trusted private parent.

Back up the supported state:

```powershell
pwsh -NoProfile -File .\apps\windows-tuning\Invoke-NetworkPathTuning.ps1 `
  -Action Backup -BackupFolder 'C:\ProgramData\NetworkLantern' -PassThru
```

Apply `Safe` after reviewing a dry run:

```powershell
pwsh -NoProfile -File .\apps\windows-tuning\Invoke-NetworkPathTuning.ps1 `
  -Action Apply -TuningProfile Safe -UdpPorts 5201 `
  -BackupFolder 'C:\ProgramData\NetworkLantern' -PassThru
```

Apply creates the backup before mutation. The command refuses to continue if
the backup status, manifest, expected artifacts, digests, or path-trust checks
fail.

Backup folders classified as sensitive system paths are rejected.
`-AllowUnsafeBackupFolder` bypasses that location check only. It does not
bypass elevation, manifest validation, artifact validation, or restore trust
checks.

## Application policies

Application DSCP policies require both `-IncludeAppPolicies` and one or more
`-AppPaths` values:

```powershell
pwsh -NoProfile -File .\apps\windows-tuning\Invoke-NetworkPathTuning.ps1 `
  -Action Apply -TuningProfile Safe -IncludeAppPolicies `
  -AppPaths 'C:\Program Files\Example\example.exe' -DryRun -PassThru
```

The orchestrator exposes both CLI parameters. Its JSON workflow profile accepts
`appPaths`, but it has no profile key for `IncludeAppPolicies`; pass the switch
explicitly when application policies are required.

## Restore

Validate a backup without changing state:

```powershell
pwsh -NoProfile -File .\apps\windows-tuning\Invoke-NetworkPathTuning.ps1 `
  -Action Restore -BackupFolder 'C:\ProgramData\NetworkLantern' `
  -DryRun -PassThru
```

Run restore only after inspecting the preview and confirming an independent
recovery method:

```powershell
pwsh -NoProfile -File .\apps\windows-tuning\Invoke-NetworkPathTuning.ps1 `
  -Action Restore -BackupFolder 'C:\ProgramData\NetworkLantern' -PassThru
```

Restore rejects missing, malformed, duplicate-key, incompatible-newer, or
untrusted manifests. It also rejects missing required artifacts, digest
mismatches, reparse-point backup paths, replaced staging directories, and
registry, QoS, NIC, RSC, or power-plan content outside the module's managed
schemas and scope. Approved artifacts are copied to protected staging and
checked again before each restore component.

Digests provide bundle integrity, not authenticated provenance. Restore only a
locally created backup retained under trusted access control. An imported or
transferred bundle requires an independent provenance check before use.

When no explicit backup folder is supplied, Restore can use the previous
default backup location if the current default has no manifest and the previous
location does. Current validation still applies. The exact compatibility path
is documented in the
[migration guide](../migration/from-network-diagnostics-suite.md).

The elevated apply and restore cycle has not been completed on a disposable
Windows VM for this revision. Automated tests cover dry runs, backup refusal,
manifest and digest validation, path trust, staging replacement, and scoped
restore behavior.

## Troubleshooting

- Run `Verify` on Windows with the NetQosPolicy cmdlets available.
- Use `-DryRun` to check input and plan construction without elevation.
- A successful dry run does not prove that every adapter-specific setting can
  be changed on the target hardware.
- Do not edit a rejected manifest or backup artifact to force restore. Create a
  new backup or investigate the reported validation error.
- Use real mutation only on a host with a tested recovery path.
