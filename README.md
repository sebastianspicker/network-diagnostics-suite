# Network Lantern

Network Lantern is a source-based toolkit for network diagnostics. It contains:

- Windows path diagnostics using `ping`, `tracert`, `pathping`, and
  `Test-NetConnection`
- Bash path diagnostics using `mtr`
- TCP and UDP throughput measurements using `iperf3`
- optional Windows QoS, NIC power-saving, and power-plan configuration
- a PowerShell entrypoint that composes the path, throughput, and tuning tools

## Static workflow demo

The [GitHub Pages demo](https://sebastianspicker.github.io/network-lantern/) is
a static, click-through simulation of workflow planning. It uses sanitized
fixture values and never runs diagnostics, contacts targets, writes files, or
changes settings. Use a source checkout and the commands in this README for
real, authorized diagnostic work.

Serve the same tracked artifact locally from the repository root:

```bash
python3 -m http.server 8000 --bind 127.0.0.1 --directory site
```

Then open <http://127.0.0.1:8000/>. This repository does not contain a GitHub
Pages deployment workflow, so the hosted page is a visual reference rather
than proof that the current worktree has been deployed.

The tools run locally and write files for later inspection. The repository does
not provide a service, remote API, installer, container image, or package.

## Status and scope

`VERSION` currently contains `0.1.0-alpha.1`. There is no release tag in this
repository. Public parameters, profile formats, output schemas, module exports,
and paths may change before a stable release.

| Area | Implementation |
| --- | --- |
| PowerShell path diagnostics | Windows-only live runs; JSON and CSV output |
| Bash path diagnostics | Bash 4+ and `mtr`; JSON-object stream and text summary output |
| Throughput CLI | PowerShell module and script for TCP or UDP `iperf3` runs, DSCP matrices, thresholds, profiles, and summary comparison |
| Throughput GUI | Windows Forms client for the throughput module |
| Orchestration | `Triage`, `Path`, `Throughput`, `Baseline`, and `WindowsTuning` workflows |
| Windows tuning | Read-only verification, dry-run planning, backup, apply, and restore |

Current limitations:

- The PowerShell path implementation requires Windows for live runs. On other
  platforms it supports `-DryRun` only.
- The Bash and PowerShell path tools use different test matrices and output
  schemas.
- Direct live throughput runs on Linux and macOS require
  `-SkipReachabilityCheck -DisableMtuProbe`. The orchestrator does not expose
  these switches, so its live throughput workflows currently require Windows.
- A default full throughput matrix can plan 1,110 tests when `iperf3` supports
  bidirectional mode. Use `-WhatIf` before a live matrix run.
- The throughput GUI has automated helper and cancellation tests, but no
  automated visual or end-to-end live-run coverage.
- `apps/windows-tuning/Invoke-NetworkPathTuning-GUI.ps1` is a text-only
  compatibility entrypoint. It does not open a GUI.
- Real Windows `Apply`, `Backup`, and `Restore` operations change system state.
  Their validation logic is tested, but an elevated apply and restore cycle has
  not been verified on a disposable Windows VM for this revision.

## Requirements

PowerShell entrypoints require PowerShell 7.

| Task | Additional requirements |
| --- | --- |
| PowerShell path live run | Windows with `ping`, `tracert`, `pathping`, and `Test-NetConnection` |
| Bash path live run | Bash 4+, `mtr`, and `jq`; `column` unless `--no-summary` is used |
| Throughput live run | `iperf3` 3.7 or newer and a reachable `iperf3` server |
| Throughput GUI | Windows Forms on Windows |
| Windows tuning verification | Windows networking cmdlets, including `Get-NetQosPolicy` |
| Windows tuning mutation | Windows and an elevated PowerShell session |

The full development gate also requires Git, ShellCheck, Bats, `jq`,
PSScriptAnalyzer 1.24.0, and Pester 5.7.1.

## Installation

Obtain a source checkout and keep its directory layout intact. Entrypoints load
modules and helpers by paths relative to the repository root.

Check development prerequisites without installing packages:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\Test-Prerequisites.ps1
```

Add `-IncludeIperf3` when preparing a live throughput run. This check confirms
that `iperf3` is on `PATH`; the live command performs the version check.

## Configuration

### Path targets

`config/hosts.conf` defines the default IPv4 and IPv6 targets for both path
entrypoints. Its format is one `ipv4=<hostname>` or `ipv6=<hostname>` entry per
line. The checked-in file targets public third-party services. Review it or use
explicit host arguments before a live run.

### Orchestrator profile

`Invoke-NetworkLantern.ps1 -ProfilePath` accepts a JSON object with these
sections and keys:

```json
{
  "path": {
    "hostsIPv4": ["8.8.8.8"],
    "hostsIPv6": [],
    "protocols": ["IPv4"],
    "rounds": ["Standard"]
  },
  "throughput": {
    "target": "iperf3.example.net",
    "port": 5201,
    "protocol": "Both"
  },
  "windowsTuning": {
    "action": "Verify",
    "profile": "Safe",
    "udpPorts": [5201],
    "appPaths": []
  }
}
```

The tracked example is `profiles/example-office.json`. Profiles larger than
1 MB are rejected. Unknown sections and keys produce warnings and are ignored.
Explicit command-line arguments take precedence over profile values.

### Throughput configuration and profiles

The direct throughput command accepts a JSON configuration file through
`-ConfigurationPath`. It also manages named profiles in
`.iperf3/profiles.json` by default. Relative profile paths are resolved from the
current directory. Use `-StrictConfiguration` to reject unknown or invalid
configuration values instead of warning and ignoring them.

Profile save and delete operations modify the profile store. `-SaveProfile
-WhatIf` still saves a profile, and `-DeleteProfile` is not changed by
`-WhatIf`.

The Bash path command supports two environment variables:

- `LOG_DIR` changes its default output directory from `~/logs`.
- `MTR_TIMEOUT_SECONDS` sets the positive integer timeout for each `mtr` run.
  The default is 360 seconds.

`NETWORK_LANTERN_INSTALL_MISSING_MODULES=1` allows `scripts/ci-local.sh` to
install missing pinned PowerShell modules during its PowerShell phase.

## Usage

Run these examples from the repository root.

Preview the PowerShell path plan:

```powershell
pwsh -NoProfile -File .\apps\path\Test-NetworkPath.ps1 `
  -HostsIPv4 example.com -Protocols IPv4 -Rounds Standard -DryRun
```

Preview the Bash path plan:

```bash
./apps/path/test-network-path.sh \
  --hosts4 example.com --types ICMP4,TCP4 --rounds Standard --dry-run
```

Preview one throughput test:

```powershell
pwsh -NoProfile -File .\apps\throughput\Measure-NetworkThroughput.ps1 `
  -Target iperf3.example.net -SingleTest -WhatIf
```

`iperf3.example.net` is a reserved example hostname. Replace it with a trusted
or operator-controlled server for a live run.

Preview the umbrella triage workflow:

```powershell
pwsh -NoProfile -File .\Invoke-NetworkLantern.ps1 `
  -Workflow Triage -IperfTarget iperf3.example.net -DryRun
```

`Triage` always runs Path and adds Throughput when `-IperfTarget` is set.
`Baseline` runs Path followed by one throughput test and requires
`-IperfTarget`.

Preview Windows tuning without elevation:

```powershell
pwsh -NoProfile -File .\apps\windows-tuning\Invoke-NetworkPathTuning.ps1 `
  -Action Apply -TuningProfile Safe -UdpPorts 5201 -DryRun -PassThru
```

Detailed commands are in the [path](docs/workflows/diagnose-path.md),
[throughput](docs/workflows/diagnose-throughput.md), and
[Windows tuning](docs/workflows/windows-tuning.md) guides.

## Output and local state

| Command | Default location |
| --- | --- |
| Direct PowerShell or Bash path command | `~/logs` |
| Direct throughput command | `./logs` |
| Orchestrated path and throughput commands | `artifacts/path` and `artifacts/throughput`, or the same children under `-OutRoot` |
| Direct throughput profile store | `.iperf3/profiles.json` |
| Orchestrated throughput profile store | `profiles/throughput-profiles.local.json` |
| Windows tuning backup | `%ProgramData%\NetworkLantern`, or `-BackupFolder` |

Path, throughput, and tuning previews do not create result or backup
directories. The throughput profile-management exceptions are described in
[Configuration](#throughput-configuration-and-profiles).

## Repository structure

```text
.github/                         Issue templates, pull request template, and CI
apps/path/                       Path diagnostic entrypoints
apps/throughput/                 Throughput CLI and Windows Forms entrypoints
apps/windows-tuning/             Windows tuning CLI and compatibility stub
config/                          Shared default path targets
docs/                            Architecture, workflow, verification, and migration guides
profiles/                        Orchestrator profile example
scripts/                         Test, lint, prerequisite, and wrapper scripts
src/bash/path/lib/               Bash path implementation
src/powershell/path/lib-ps/      PowerShell path implementation
src/powershell/throughput/       NetworkLantern.Throughput module
src/powershell/windows-tuning/   NetworkLantern.WindowsTuning module
tests/                           Bats and Pester suites
Invoke-NetworkLantern.ps1        PowerShell workflow orchestrator
Makefile                         Local lint and test shortcuts
PSScriptAnalyzerSettings.psd1    PowerShell analysis settings
VERSION                          Repository version candidate
```

## Development workflow

Use a topic branch based on `main`. Keep operator entrypoints in `apps/`,
shared implementation in `src/`, and tests in `tests/`. Update the relevant
workflow guide when behavior, configuration, or output changes.

Run the complete local gate from Bash, Git Bash, or WSL:

```bash
./scripts/ci-local.sh
```

Run the PowerShell-only gate without installing dependencies:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\ci.ps1 -NoInstall
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for branch, test, and documentation
requirements.

## Testing

The complete gate runs ShellCheck, Bats, a repository secret-pattern scan,
the project identity check, PSScriptAnalyzer, and Pester. Tests use mocks and
dry-run paths for network and Windows tuning behavior. They do not run live
network probes or real Windows tuning changes.

GitHub Actions runs the cross-shell gate on Ubuntu and the PowerShell gate on
Ubuntu and Windows for pushes and pull requests targeting `main`.

See [docs/verification.md](docs/verification.md) for exact dependencies,
focused test commands, and current verification gaps.

## Deployment and operation

There is no deployment step. Run the selected entrypoint from a source
checkout on the host being diagnosed. For repeatable collection, use explicit
targets, protocols, rounds, output paths, and throughput parameters. Preserve
the generated files together when comparing runs.

Run diagnostics only against systems and services you are authorized to test.
The default path configuration contacts public services. Throughput tests can
consume substantial bandwidth, and the default matrix can run for a long time.

## Troubleshooting

- If the prerequisite check reports missing ShellCheck, Bats, or `jq`, install
  them in the same Bash environment used for `scripts/ci-local.sh`.
- If `scripts/ci.ps1 -NoInstall` reports missing PowerShell modules, run it
  once without `-NoInstall` to install the pinned versions for the current
  user.
- Use the Bash path command for live path diagnostics on non-Windows systems.
- On Linux or macOS, add `-SkipReachabilityCheck -DisableMtuProbe` to a direct
  live throughput command. The TCP port check still runs.
- A Windows tuning `Apply`, `Backup`, or `Restore` fails without elevation.
  `Verify` and `-DryRun` do not require elevation.
- If a Bash summary fails because `column` is missing, rerun with
  `--no-summary`.
- Keep Bash and Bats files LF-normalized. When staging a new Bash entrypoint
  from Windows, record executable mode `100755`.

## Security considerations

Diagnostic output can contain internal hostnames, IP addresses, routes, local
paths, usernames, and machine details. Throughput profiles and tuning backups
can also contain sensitive operational data. Git ignores the documented local
output paths, but ignored files still require review before sharing.

Windows tuning writes registry values, QoS policies, NIC properties, and the
active power plan. Preview the action first, keep a verified backup outside a
sensitive system directory, and use real mutation only on a system with a
tested recovery path.

Report vulnerabilities according to [SECURITY.md](SECURITY.md). Do not put
credentials, exploit details, or unsanitized diagnostics in a public issue.

## Contributing

Before opening a pull request, run the complete gate, inspect
`git status --short`, and review every file that would be published. Follow
[CONTRIBUTING.md](CONTRIBUTING.md) for focused tests, code boundaries, and
documentation updates.

Network Lantern is licensed under the [MIT License](LICENSE).
