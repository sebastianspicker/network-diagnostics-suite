# Architecture

Network Lantern is a source-run toolkit, not a service or installable package. It exposes stable operator scripts over four independent execution capabilities:

| Capability | Stable adapter | Implementation boundary | Primary effects |
| --- | --- | --- | --- |
| Windows path diagnostics | `apps/path/Test-NetworkPath.ps1` | `NetworkLantern.Path` | network probes; JSON and CSV artifacts |
| MTR path diagnostics | `apps/path/test-network-path.sh` | `src/bash/path/` | `mtr` processes; JSON-object stream and text log |
| Throughput measurement | `apps/throughput/Measure-NetworkThroughput.ps1` and GUI | `NetworkLantern.Throughput` | `iperf3` processes, profiles, reports, run index |
| Windows tuning | `apps/windows-tuning/Invoke-NetworkPathTuning.ps1` | `NetworkLantern.WindowsTuning` | verification, backup, optional system mutation and restore |

`Invoke-NetworkLantern.ps1` is the stable multi-capability adapter. `NetworkLantern.Workflow` exports `New-NetworkLanternWorkflowPlan`, which builds profile-resolved, ordered capability plans only. The root application layer maps those capabilities to trusted adapters and executes isolated children. The static `site/` planner only generates preview commands; it is not part of the execution runtime.

## Dependency direction

```text
operator input
    |
    v
apps/ or root adapter       parameter binding and exit-code translation
    |
    v
capability module/package   validation, planning, orchestration, result policy
    |
    v
OS and tool boundary        ping, tracert, pathping, mtr, iperf3, Windows APIs
    |
    v
local artifacts/state       reports, profiles, locks, cancellation, backups
```

Adapters import module manifests or the Bash `load.sh` composition point. They do not import module-private files. Product code does not depend on `scripts/`, which is reserved for development and verification. PowerShell module root files keep complete explicit private and public loader inventories; every manifest export must resolve to a function physically defined under `Public/`. `src/bash/path/load.sh` is the only Bash composition root; libraries do not source one another.

The Windows and MTR path tools intentionally remain separate implementations. They share the target configuration format, but their probes, plans, platform requirements, and result schemas differ. A common path abstraction would hide meaningful operational differences without creating a reusable contract.

## Capability boundaries

### Windows path

`NetworkLantern.Path` owns host and output validation, round and protocol planning, Windows probe invocation, status aggregation, and JSON/CSV persistence. `Invoke-NetworkPathDiagnostics` is its only exported command. The adapter handles the historical CLI surface and converts the returned run result to a process status.

### MTR path

The Bash package is composed by `load.sh`. `main.sh` owns CLI parsing and the run lifecycle; `lib/` owns focused target configuration, validation, MTR argument construction, planning, reporting, and bounded execution. Its JSON log remains a stream of individual objects rather than an array.

### Throughput

`NetworkLantern.Throughput.psm1` is an ordered loader. Exported commands live under `Public/`; `Private/` owns validation, iperf3 process control, test planning, profile persistence, reporting, and error classification. The CLI and GUI share app-local adapters for module calls and file opening. Neither reaches into module-private paths.

Profile files and run indexes use sidecar locks and atomic replacement. GUI cancellation uses a nonce-bound signal file. These are behavioral boundaries, not incidental implementation details.

### Windows tuning

`NetworkLantern.WindowsTuning` remains optional and Windows-specific. Read-only verification is distinct from mutation. Apply creates and validates a backup before any configuration write. Restore validates manifest shape, compatibility, expected artifacts, digests, path trust, protected staging, and staging integrity before each consumer runs.

Legacy backup names and schemas remain accepted at this boundary because they protect recoverability for existing operator state. They are not shared naming conventions for new code.

### Workflow

`NetworkLantern.Workflow` parses profiles and returns ordered capability steps with resolved parameters. It has no repository-path knowledge and performs no process execution. The root application layer validates every step against one trusted capability descriptor table, maps the capability to its repository adapter, and invokes it in an isolated PowerShell child. Isolation prevents one script's module state or terminating behavior from contaminating another workflow step. The child reads at most the 1 MiB envelope limit plus one byte from standard input, validates the same descriptor and parameter allowlist, then resolves its adapter path from the trusted map. The envelope never carries an executable path. The root adapter is the only layer allowed to terminate the parent process.

## Configuration and state ownership

- `config/hosts.conf` is shared target input for both path tools.
- `profiles/example-office.json` documents the workflow profile schema.
- Direct throughput profiles default to `.iperf3/profiles.json`; orchestrated profiles use `profiles/throughput-profiles.local.json`.
- Path and throughput artifacts belong to their selected output roots.
- Windows tuning backups belong to the tuning module and are independent of workflow artifact roots.
- Preview modes may read configuration and validate inputs, but must not create result or tuning state. Throughput profile save and delete are explicit exceptions.

## Enforcement

`tests/architecture/RepositoryArchitecture.Tests.ps1` enforces stable adapters, complete module loader inventories, manifest/export agreement, public export placement, dependency direction, retired-path removal, the single Bash loader, executable modes, and the static planner boundary. Mutation fixtures keep the path-reference scanners honest. ShellCheck, PSScriptAnalyzer, Bats, and capability-focused Pester suites verify the language and behavior contracts. The complete local gate is `./scripts/ci-local.sh`.

Put new behavior in the capability that owns its inputs, effects, and artifacts. Add shared code only when there is a real cross-capability concept with the same semantics; similar-looking command lines are not sufficient justification.
