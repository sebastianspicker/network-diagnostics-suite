# Security

Network Lantern runs local diagnostic commands and can modify Windows network
configuration. It does not expose a network service or authentication endpoint.

## Reporting a vulnerability

Use the repository's GitHub Security tab and private vulnerability reporting
flow when available. If private reporting is unavailable, open a public issue
that requests a private contact channel without including vulnerability
details.

Do not publish credentials, exploit details, internal infrastructure, or
unsanitized diagnostic output in an issue or pull request.

## Supported versions

There is no tagged supported release. Security fixes target `main`. Historical
project names, legacy repositories, and arbitrary commits are outside the
support scope.

## Sensitive data

Treat these files and values as sensitive unless they have been reviewed and
sanitized:

- hostnames, IP addresses, DNS results, routes, and packet captures
- raw path and `iperf3` output, run indexes, and saved profiles
- registry exports, QoS policy exports, NIC data, and tuning backups
- local paths, usernames, machine identifiers, logs, and crash output

The default generated-data paths are listed in `README.md` and ignored by Git.
An ignored file is not safe to publish by default.

## Execution boundaries

- Host and path inputs are validated before native tools are invoked.
- Native commands receive argument arrays instead of interpolated shell command
  strings.
- PowerShell path `-DryRun`, Bash path `--dry-run`, and a normal throughput
  `-WhatIf` run do not probe the network or write result files.
- Throughput profile operations are writes. `-SaveProfile -WhatIf` saves the
  profile, and `-DeleteProfile` modifies the selected store.
- Elevated throughput processes refuse the cwd-derived default and relative
  profile-store paths at every read and write boundary. An operator-supplied
  absolute profile path remains supported; the GUI's displayed default is
  treated as the cwd-derived default even though it is shown expanded.
- Throughput summary comparisons, run-index recovery, and cancellation signals
  use bounded reads from the opened handle, rather than a size check followed
  by a second open.
- Windows tuning `-DryRun` does not write backups, registry values, QoS
  policies, NIC settings, or power-plan state.
- Windows tuning `Apply`, `Backup`, and `Restore` require elevation.
- Apply validates the complete backup path and existing artifacts before any
  elevated write, then verifies its manifest, required artifacts, and digests
  before tuning mutation.
- Restore requires a compatible tool identity and strict, scope-bounded schemas
  for registry, QoS, NIC, RSC, and power-plan artifacts. It copies approved
  artifacts to protected staging and revalidates staging before each component.

Artifact hashes detect changes within a backup bundle; they do not authenticate
who created it. Restore only locally created backups kept under trusted access
control. Treat an imported or transferred bundle as untrusted unless its
provenance was authenticated independently.

These checks reduce accidental or malicious input handling risk. They do not
replace operating-system backups, access control, or a tested recovery plan.

## Operator guidance

Run diagnostics only against targets you are authorized to test. Throughput
tests can consume substantial bandwidth and may affect other users of the
network or server.

Use real Windows tuning mutation only on a system with an independent recovery
method. The elevated apply and restore cycle has not been validated on a
disposable Windows VM for the current revision.

Before publishing repository changes, run:

```bash
git status --short
pwsh -NoProfile -NonInteractive -File scripts/Invoke-SecretScan.ps1
```

Review all tracked and untracked publication candidates manually after the
scan.
