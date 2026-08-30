function Get-DiagnosticPlan {
  <#
  .SYNOPSIS
    Build the test matrix: rounds x protocols x hosts, filtering unsafe hostnames.
  .PARAMETER RoundDefinitions
    Array of round definition hashtables (from Get-RoundDefinitions).
  .PARAMETER SelectedProtocols
    Which protocols to include (IPv4, IPv6).
  .PARAMETER ResolvedHostsIPv4
    IPv4 host list.
  .PARAMETER ResolvedHostsIPv6
    IPv6 host list.
  .OUTPUTS
    [System.Collections.Generic.List[object]] Plan items with RoundName, RoundDef, Protocol, Host.
  #>
  param(
    [Parameter(Mandatory)][array]$RoundDefinitions,
    [Parameter(Mandatory)][string[]]$SelectedProtocols,
    [Parameter(Mandatory)][string[]]$ResolvedHostsIPv4,
    [Parameter(Mandatory)][string[]]$ResolvedHostsIPv6
  )

  $plan = New-Object System.Collections.Generic.List[object]

  foreach ($round in $RoundDefinitions) {
    foreach ($proto in $SelectedProtocols) {
      $hosts = if ($proto -eq 'IPv6') { @($ResolvedHostsIPv6) } else { @($ResolvedHostsIPv4) }
      if (@($hosts).Count -eq 0) { continue }

      foreach ($h in $hosts) {
        if (-not (Test-HostNameSafe $h)) { continue }
        $plan.Add([pscustomobject]@{
          RoundName    = $round.Name
          RoundDef     = $round
          Protocol     = $proto
          Host         = $h
        })
      }
    }
  }

  return $plan
}
