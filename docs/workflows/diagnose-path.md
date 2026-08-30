# Path diagnostics

Network Lantern provides two path diagnostic implementations. Use the
PowerShell entrypoint for Windows built-in tools or the Bash entrypoint for
`mtr`.

## PowerShell entrypoint

List the available rounds and protocols:

```powershell
pwsh -NoProfile -File .\apps\path\Test-NetworkPath.ps1 -ListRounds
pwsh -NoProfile -File .\apps\path\Test-NetworkPath.ps1 -ListProtocols
```

The implemented rounds are `Standard`, `MTU1400_DF`, and
`TTL64_Timeout5s`. Protocols are `IPv4` and `IPv6`.

Preview one IPv4 run:

```powershell
pwsh -NoProfile -File .\apps\path\Test-NetworkPath.ps1 `
  -HostsIPv4 example.com -Protocols IPv4 -Rounds Standard -DryRun
```

Run the same selection without `pathping`:

```powershell
pwsh -NoProfile -File .\apps\path\Test-NetworkPath.ps1 `
  -HostsIPv4 example.com -Protocols IPv4 -Rounds Standard -SkipPathping
```

A live run requires Windows. For every selected round, protocol, and host, the
script runs `ping`, `tracert`, optional `pathping`, and a TCP 443 check through
`Test-NetConnection`.

The default output directory is `~/logs`. Use `-LogDirectory` to change it.
Each run creates:

- `net_results_<timestamp>_<pid>.json`
- `net_summary_<timestamp>_<pid>.csv`

Result records include `PingStatus`, `TracertStatus`, `PathpingStatus`,
`Tcp443Status`, `PortsStatus`, and `OverallStatus`. `PathpingStatus` is
`Skipped` when `-SkipPathping` is supplied. `Ports` is always an empty array
and `PortsStatus` is `Skipped`; these retained fields preserve the result
schema for existing consumers.

The process exits 1 if any planned run has `OverallStatus` equal to `Fail`.
Validation and execution errors also return a nonzero status. If execution is
interrupted after at least one result is collected, the script attempts to
write partial results.

## Bash entrypoint

List test types and rounds:

```bash
./apps/path/test-network-path.sh --list-types
./apps/path/test-network-path.sh --list-rounds
```

Test types are `ICMP4`, `ICMP6`, `UDP4`, `UDP6`, `TCP4`, `TCP6`, `MPLS4`,
`MPLS6`, `AS4`, and `AS6`. Rounds are `Standard`, `MTU1400`, `TOS_CS5`,
`TOS_AF11`, `TTL10`, `TTL64`, `FirstTTL3`, and `Timeout5`.

Preview a selected matrix:

```bash
./apps/path/test-network-path.sh \
  --hosts4 example.com --types ICMP4,TCP4 \
  --rounds Standard,TTL64 --dry-run
```

Run it:

```bash
./apps/path/test-network-path.sh \
  --hosts4 example.com --types ICMP4,TCP4 \
  --rounds Standard,TTL64
```

A live run requires Bash 4+, `mtr`, and `jq`. The default summary also requires
`column`; pass `--no-summary` when it is unavailable. Each native `mtr` command
requests 300 report cycles. Commands run sequentially and have a default
360-second timeout. Set `MTR_TIMEOUT_SECONDS` to another positive integer to
change that timeout.

The default matrix is `ICMP4,ICMP6,TCP4,TCP6` by `Standard`. TCP modes use
port 443. Use explicit `--types`, `--rounds`, and host arguments to keep a live
run bounded.

The default output directory is `LOG_DIR` or `~/logs`. The command writes:

- `mtr_results_<timestamp>_<pid>.json.log`
- `mtr_summary_<timestamp>_<pid>.log`

The JSON log contains consecutive JSON objects, one per planned run. It is not
a JSON array. A failed command or invalid native result is written as a
parseable failure object. The process exits 1 when any planned run fails.

## Default targets

Both entrypoints read `config/hosts.conf` unless hosts are supplied explicitly.
The checked-in file currently contains:

- IPv4: `cloudflare.com`, `google.com`, `wikipedia.org`, `amazon.de`
- IPv6: `cloudflare.com`, `google.com`, `wikipedia.org`

These are third-party services. Review or replace them before collecting live
diagnostics.

## Troubleshooting

- Use Bash with a working `mtr` installation for live non-Windows diagnostics.
- Pass `--no-summary` if `column` is missing.
- A no-work plan indicates an incompatible type, protocol, or host selection.
- Use `-Quiet` or `--quiet` to suppress progress while retaining warnings,
  failures, and the final summary.
