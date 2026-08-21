# Verification

Run all commands from the repository root.

## Dependencies

| Dependency | Pinned or minimum version | Used by |
| --- | --- | --- |
| PowerShell | 7+ | scripts, modules, and Pester |
| PSScriptAnalyzer | 1.24.0 | PowerShell static analysis |
| Pester | 5.7.1 | PowerShell tests |
| Bash | 4+ for the path entrypoint | Bash scripts and tests |
| ShellCheck | not pinned | Bash static analysis |
| Bats | not pinned | Bash tests |
| `jq` | not pinned | Bash JSON tests and live result processing |
| Git | not pinned | repository file enumeration and publication checks |
| `iperf3` | 3.7+ | live throughput only |
| `mtr` | not pinned | live Bash path diagnostics only |
| `column` | not pinned | Bash path summaries unless `--no-summary` is used |

Check the development dependencies:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\Test-Prerequisites.ps1
```

Use `-IncludeIperf3` to check whether `iperf3` is on `PATH`. The prerequisite
script does not validate the Bash major version or the `iperf3` version. Those
checks occur in their live entrypoints.

## Complete local gate

From Bash, Git Bash, or WSL:

```bash
./scripts/ci-local.sh
```

This command runs, in order:

1. ShellCheck over the Bash entrypoints, scripts, and path libraries
2. all Bats tests under `tests/path`
3. `scripts/Invoke-SecretScan.ps1`
4. `scripts/ci.ps1 -NoInstall`

The final PowerShell phase runs the project identity check, PSScriptAnalyzer,
and the compact Pester contract suite without creating test artifacts.

The complete gate does not install system packages. By default it also refuses
to install missing PowerShell modules. In an environment where user-scope
module installation is permitted, set:

```bash
NETWORK_LANTERN_INSTALL_MISSING_MODULES=1 ./scripts/ci-local.sh
```

This changes only the PowerShell module-installation behavior.

## PowerShell gate

Run without dependency installation:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\ci.ps1 -NoInstall
```

Run without `-NoInstall` to install missing PSScriptAnalyzer 1.24.0 or Pester
5.7.1 for the current user before executing the gate:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\ci.ps1
```

The script imports the exact pinned versions even if other versions are
installed. It fails when static analysis reports an issue, Pester discovers no
tests, or Pester reports a result other than `Passed`.

## Focused tests

Run a filtered Pester subset:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\Invoke-Tests.ps1 `
  -Filter 'WindowsTuning'
```

The filter matches Pester full names. A filter that selects no tests fails.

Make targets:

| Target | Command |
| --- | --- |
| `make lint` | ShellCheck only |
| `make test-bash` | Bats only |
| `make test-pwsh` | `scripts/ci.ps1 -NoInstall` |
| `make test` | Bats, then the PowerShell gate |
| `make ci-local` | complete cross-shell gate |

## GitHub Actions

`.github/workflows/ci.yml` runs on pushes to `main`, pull requests targeting
`main`, and manual dispatch.

- `path-lint-test` runs the complete local gate on Ubuntu.
- `powershell-lint-test` runs the secret scan and PowerShell gate on Ubuntu and
  Windows.

The workflow pins third-party actions by commit and caches the two pinned
PowerShell modules.

## Preview checks

These commands validate execution planning without live probes or result-file
writes:

```powershell
pwsh -NoProfile -File .\apps\path\Test-NetworkPath.ps1 `
  -HostsIPv4 example.com -Protocols IPv4 -Rounds Standard -DryRun

pwsh -NoProfile -File .\apps\throughput\Measure-NetworkThroughput.ps1 `
  -Target iperf3.example.net -SingleTest -WhatIf

pwsh -NoProfile -File .\Invoke-NetworkLantern.ps1 `
  -Workflow Triage -IperfTarget iperf3.example.net -DryRun

pwsh -NoProfile -File .\apps\windows-tuning\Invoke-NetworkPathTuning.ps1 `
  -Action Apply -TuningProfile Safe -UdpPorts 5201 -DryRun -PassThru
```

The Bash equivalent is:

```bash
./apps/path/test-network-path.sh \
  --hosts4 example.com --types ICMP4,TCP4 --rounds Standard --dry-run
```

Preview modes still read configuration and validate inputs. A restore dry run
also reads and validates an existing backup. Invalid inputs return a nonzero
status.

Profile save and delete modes are exceptions to throughput preview behavior.
They change the selected profile store even when `-WhatIf` is also present.

## What the automated tests do not verify

The automated suites do not:

- contact the default public path targets
- run a live `iperf3` client against an external server
- visually test the Windows Forms throughput interface
- complete an elevated Windows tuning apply, injected failure, and restore
  cycle on a disposable VM

Tests cover plan construction, validation, output processing, process timeout
and cancellation behavior, exit codes, profile operations, orchestration,
Windows tuning dry runs, backup validation, and restore defenses.

## Troubleshooting

- If `scripts/ci.ps1 -NoInstall` reports a missing pinned module, run
  `scripts/ci.ps1` once where current-user installation is allowed.
- On Windows, make sure Bash dependencies and `pwsh` are visible from the same
  Git Bash or WSL environment that runs `scripts/ci-local.sh`.
- If a focused run selects no tests, use a substring from a Pester `Describe`,
  `Context`, or `It` name.
- Preserve LF line endings and Git mode `100755` for Bash entrypoints.
