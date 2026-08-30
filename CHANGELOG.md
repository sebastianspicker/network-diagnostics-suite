# Changelog

## Unreleased

### Architecture reconstruction

- Add explicit `NetworkLantern.Path` and `NetworkLantern.Workflow` modules and
  reduce their public scripts to parameter and exit-status adapters.
- Make the Bash MTR feature load through one composition root and move CLI
  orchestration out of the public shell entrypoint.
- Split throughput exports into `Public/`, keep implementation in `Private/`,
  and remove runtime dependencies on development scripts and private paths.
- Replace the compact cross-capability test file with capability-owned behavior
  suites and mechanical dependency-boundary checks.
- Preserve supported execution entrypoints, module exports, profile/report
  formats, exit codes, locking, cancellation, and Windows restore compatibility.

### Alpha release preparation

- Define `0.1.0-alpha.1` as the first unified repository release candidate.
- Document the alpha compatibility boundary, platform limits, runtime
  requirements, configuration precedence, local state, and troubleshooting.
- Distinguish normal throughput run previews from explicit profile save and
  delete operations, which modify the selected profile store.
- Align contribution, security, verification, issue, and pull request guidance
  with the current validation commands.

### Public interface rename

- Rename the project to Network Lantern and use `network-lantern` as the
  intended repository slug.
- Rename active operator commands to `Invoke-NetworkLantern.ps1`,
  `Test-NetworkPath.ps1`, `test-network-path.sh`,
  `Measure-NetworkThroughput.ps1`, `Measure-NetworkThroughput-GUI.ps1`, and
  `Invoke-NetworkPathTuning.ps1`.
- Remove the obsolete tuning GUI guidance stub; the tuning CLI is the sole
  supported tuning entrypoint.
- Rename the throughput and Windows tuning modules to
  `NetworkLantern.Throughput` and `NetworkLantern.WindowsTuning`.
- Rename exported tuning helpers to `Get-NetworkLanternDefaultBackupFolder`
  and `Test-NetworkTuningAdministrator`.

### Windows safety and recovery

- Make tuning `-DryRun` non-mutating and non-elevated for Apply, Backup, and
  Restore previews. Real Apply, Backup, and Restore remain elevation-gated.
- Remove the public administrator-check bypass from the tuning command and
  exported function.
- Require a complete, verified backup before Apply reaches any tuning mutation.
- Advance backup manifests to schema 3 with artifact digests, backup path trust
  checks, protected restore staging, and revalidation before restore consumers.
- Isolate Windows restore fixtures with trusted disposable access controls.
- Replace host `netsh` execution in the reset-scope test with a test double that
  verifies the intended calls.

### Verification and portability

- Load exactly PSScriptAnalyzer 1.24.0 and Pester 5.7.1 in local and CI gates.
- Fail full and filtered Pester gates when no tests are selected or executed.
- Replace the Bash test suite's Python JSON dependency with `jq`.
- Normalize text files to LF through `.gitattributes`.
- Add a read-only prerequisite report and document the cross-shell and
  PowerShell-only verification paths.

### Repository hygiene

- Keep mutable throughput profiles in ignored local state instead of a tracked
  JSON store.
- Keep machine-local state, operational output, packet captures, and tuning
  exports outside version control.
- Make the local secret scan inspect tracked and non-ignored untracked files.
- Align maintained documentation with `main` as the integration branch and the
  current source layout.

### Implementation structure

- Split throughput native-process, invocation, metric, and test-execution
  helpers into responsibility-specific private files with explicit load order.
- Split Windows backup, manifest validation, restore staging, component
  restore, and action orchestration into responsibility-specific private files.
- Split throughput implementation responsibilities behind an explicit module
  load order.

## Pre-alpha development snapshot (2026-04-18)

This snapshot was previously labeled `v1.0.0`, but no corresponding local or
remote Git tag exists. The entries are retained as development history and do
not describe a published stable release.

### Added

- Added isolated child-process orchestration with serialized array arguments.
- Added direct regression tests for Triage, Path, and Baseline workflows.
- Added per-stage path status fields and a derived overall status for each
  result row.
- Added failed-stage reporting and made path process status reflect any planned
  stage failure.
- Distinguished skipped pathping work from successful pathping work.
- Removed ambient caller-scope dependencies from path round and diagnostic
  helpers.
- Changed the Bash default to the bounded
  `ICMP4,ICMP6,TCP4,TCP6` by `Standard` matrix.
- Rejected empty Bash type, round, and host selections.
- Added structured throughput CLI exit handling for initialization failures.
- Moved throughput defaults into the module and kept CLI forwarding limited to
  explicitly supplied or configured values.
- Replaced permissive IPv6 validation with `IPAddress.TryParse` and rejected
  scope identifiers.
- Made Windows tuning verification report unavailable QoS enumeration as an
  unknown component and a failed verification.
- Added Windows backup schema validation, metadata, and scope-bounded reset
  behavior.

### Changed

- Removed legacy Windows tuning helpers from the exported module surface.
- Changed the legacy tuning GUI entrypoint from an error to an informational
  CLI redirect.
- Narrowed `Compare-Iperf3Runs` documentation to the fields it compares.
- Corrected path and QoS error messages.

### Source consolidation

- Consolidated code from the prior Network Diagnostics Suite, MTR path,
  `iperf3` throughput, and Windows UDP jitter workspaces.
- Replaced the earlier Windows tuning surface with an optional CLI workflow.
- Added umbrella orchestration, workflow documentation, migration notes, and a
  unified CI configuration.
