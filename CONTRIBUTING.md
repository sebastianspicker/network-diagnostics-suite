# Contributing

Changes are accepted through pull requests against `main`. Use the current
Network Lantern names in code, tests, documentation, and issue reports. Legacy
names belong only in migration or compatibility code.

## Development setup

The full local gate requires:

- PowerShell 7
- Git
- Bash 4 or newer
- ShellCheck
- Bats
- `jq`
- PSScriptAnalyzer 1.24.0
- Pester 5.7.1

Check the current environment without installing anything:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\Test-Prerequisites.ps1
```

`scripts/ci.ps1` installs missing pinned PowerShell modules for the current
user unless `-NoInstall` is supplied:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\ci.ps1
```

Use native PowerShell for PowerShell checks on Windows. Run the cross-shell
gate from Git Bash or WSL with `shellcheck`, `bats`, `jq`, and `pwsh` on that
shell's `PATH`.

## Change workflow

1. Create a short-lived topic branch from current `main`.
2. Make one related set of changes.
3. Add or update tests for observable behavior.
4. Update operator and contributor documentation affected by the change.
5. Run focused tests while iterating.
6. Run the complete local gate before opening a pull request.
7. Open the pull request against `main`. Do not push directly to `main`.

## Code boundaries

- Keep operator entrypoints in `apps/` and the repository root thin. They bind
  parameters, import a capability boundary, and translate process status.
- Put PowerShell behavior behind module manifests with explicit Public/Private
  load order. Apps must not import module-private files.
- Compose the Bash path package only through `src/bash/path/load.sh`; libraries
  must not source one another.
- Keep product code independent from `scripts/`, which is development tooling.
- Keep path, throughput, and Windows tuning code separate.
- Do not add an `iperf3` dependency to path diagnostics.
- Keep Windows tuning optional.
- Preserve backup-before-mutation and restore validation for every tuning
  mutation.
- Do not add a tuning setting without documenting its scope in
  `docs/evidence/tuning-matrix.md`.
- Keep normal path, throughput-test, and tuning previews free of network probes,
  result writes, and Windows configuration changes.
- Treat throughput profile save and delete commands as explicit local writes.
  `-SaveProfile -WhatIf` still writes the profile.

## Tests and static analysis

Run the complete gate:

```bash
./scripts/ci-local.sh
```

The gate runs ShellCheck, Bats, the secret-pattern scan, the project identity
check, PSScriptAnalyzer, and Pester. It does not install system packages.
`make ci-local` invokes the same script.

Run the PowerShell-only gate without dependency installation:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\ci.ps1 -NoInstall
```

Run a filtered Pester subset while iterating:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\Invoke-Tests.ps1 `
  -Filter 'Throughput'
```

A filtered run is not a substitute for the complete gate. Both full and
filtered Pester commands fail if no tests are selected or executed.

`make test` runs Bats and the PowerShell gate. It omits ShellCheck and the
secret-pattern scan, so it is not the publication gate.

See [docs/verification.md](docs/verification.md) for the exact gate matrix and
known verification gaps.

## Windows checkouts

`.gitattributes` normalizes text files to LF. Do not convert Bash or Bats files
to CRLF. When adding or renaming a Bash entrypoint from Windows, preserve its
executable Git mode:

```bash
git add --chmod=+x path/to/entrypoint.sh
git ls-files --stage path/to/entrypoint.sh
```

The staged mode should be `100755`.

Do not exercise real Windows tuning changes as part of routine development.
Use `-DryRun` for plan validation. Any elevated apply and restore test belongs
on a disposable Windows VM with a separate recovery method.

## Documentation

Update documentation in the same pull request as behavior changes:

- `README.md` for purpose, installation, configuration, and common commands
- `docs/architecture.md` for component or data-flow changes
- `docs/workflows/` for operator behavior
- `docs/verification.md` for dependencies, tests, or verification scope
- `docs/evidence/tuning-matrix.md` for Windows tuning scope
- `docs/migration/` only for current compatibility mappings
- `CHANGELOG.md` for release-facing changes

Examples must run from the repository root unless the surrounding text says
otherwise. Verify command names, paths, parameters, output names, and links.

## Before opening a pull request

Run:

```bash
./scripts/ci-local.sh
git diff --check
git status --short
pwsh -NoProfile -NonInteractive -File scripts/Invoke-SecretScan.ps1
```

The secret-pattern scan examines tracked files and untracked files that Git
does not ignore. It suppresses matched content from its output. Review the
candidate files yourself because pattern matching is not a substitute for
manual inspection.

Do not include live diagnostic output, throughput profiles, packet captures,
registry exports, tuning backups, credentials, or internal host information in
a pull request unless the data is intentionally sanitized and required for a
test fixture.

## Pull request content

Describe:

- the behavior changed
- the affected platforms and entrypoints
- the commands used for verification
- any tests skipped and the reason
- any remaining operational or security limitations

Keep pull requests scoped so reviewers can connect the implementation, tests,
and documentation.
