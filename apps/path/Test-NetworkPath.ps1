<#
.SYNOPSIS
  Run or preview Network Lantern Windows path diagnostics.
.DESCRIPTION
  This compatibility entry point forwards its parameters to the
  NetworkLantern.Path module and converts its final run status to a process
  exit code. Use -DryRun on non-Windows hosts.
#>
[CmdletBinding()]
param(
  [string[]]$HostsIPv4,
  [string[]]$HostsIPv6,
  [string]$LogDirectory = '',
  [int]$PingCount = 5,
  [int]$TraceMaxHops = 30,
  [int]$TraceTimeoutMs = 5000,
  [int]$PathpingProbes = 50,
  [int]$PathpingTimeoutMs = 3000,
  [ValidateSet('IPv4', 'IPv6')]
  [string[]]$Protocols = @('IPv4', 'IPv6'),
  [string[]]$Rounds = @('Standard'),
  [switch]$SkipPathping,
  [switch]$DryRun,
  [switch]$Quiet,
  [switch]$Version,
  [switch]$ListRounds,
  [switch]$ListProtocols
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$manifestPath = Join-Path $repoRoot 'src/powershell/path/NetworkLantern.Path/NetworkLantern.Path.psd1'
Import-Module -Name $manifestPath -Force -ErrorAction Stop

$runResults = New-Object System.Collections.Generic.List[object]
Invoke-NetworkPathDiagnostics @PSBoundParameters | ForEach-Object {
  if ($_.PSTypeNames -contains 'NetworkLantern.Path.RunResult') {
    $runResults.Add($_) | Out-Null
  } else {
    Write-Output $_
  }
}
if ($runResults.Count -ne 1) {
  throw 'NetworkLantern.Path did not return a run result.'
}

exit [int]$runResults[0].ExitCode
