# Migrating from windows-udp-jitter-optimization

Windows tuning is now the optional `NetworkLantern.WindowsTuning` module.

| Previous surface | Current surface |
| --- | --- |
| `WindowsUdpJitterOptimization` | `NetworkLantern.WindowsTuning` |
| `Optimize-NetworkPath.ps1` | `apps/windows-tuning/Invoke-NetworkPathTuning.ps1` |
| `Optimize-NetworkPath-GUI.ps1` | No GUI replacement; use `apps/windows-tuning/Invoke-NetworkPathTuning.ps1` |
| `Get-NdsDefaultBackupFolder` | `Get-NetworkLanternDefaultBackupFolder` |
| `Test-UjIsAdministrator` | `Test-NetworkTuningAdministrator` |

The current public Apply profiles include local QoS marking, requested DSCP
policies, selected NIC power-saving settings, and optional power-plan
selection. They do not include game presets, broad registry bundles,
interrupt-moderation changes, or offload defaults.

Real `Apply`, `Backup`, and `Restore` require elevation. Older backups are
accepted only when they pass the current manifest, component, artifact, digest,
registry-content, and path-trust checks. Preview a restore with `-DryRun` before
changing state.
