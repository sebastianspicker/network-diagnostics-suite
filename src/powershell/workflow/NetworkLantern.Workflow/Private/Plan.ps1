function New-NetworkLanternWorkflowStep {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateSet('Path', 'Throughput', 'WindowsTuning')][string]$Capability,
    [Parameter(Mandatory)][hashtable]$Parameters
  )

  return [pscustomobject]@{
    Capability = $Capability
    Parameters = $Parameters
  }
}

function Get-NetworkLanternArtifactLocations {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ArtifactRoot)

  return @{
    Path       = (Join-Path $ArtifactRoot 'path')
    Throughput = (Join-Path $ArtifactRoot 'throughput')
  }
}

function New-NetworkLanternPathStep {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Configuration,
    [Parameter(Mandatory)][hashtable]$Artifacts
  )

  $parameters = @{ LogDirectory = $Artifacts.Path }
  if ($Configuration.HostsIPv4.Count -gt 0) { $parameters['HostsIPv4'] = $Configuration.HostsIPv4 }
  if ($Configuration.HostsIPv6.Count -gt 0) { $parameters['HostsIPv6'] = $Configuration.HostsIPv6 }
  if ($Configuration.Protocols.Count -gt 0) { $parameters['Protocols'] = $Configuration.Protocols }
  if ($Configuration.Rounds.Count -gt 0) { $parameters['Rounds'] = $Configuration.Rounds }
  if ($Configuration.SkipPathping) { $parameters['SkipPathping'] = $true }
  if ($Configuration.DryRun) { $parameters['DryRun'] = $true }
  if ($Configuration.Quiet) { $parameters['Quiet'] = $true }

  return New-NetworkLanternWorkflowStep -Capability 'Path' -Parameters $parameters
}

function New-NetworkLanternThroughputStep {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Configuration,
    [Parameter(Mandatory)][hashtable]$Artifacts
  )

  if ([string]::IsNullOrWhiteSpace($Configuration.IperfTarget)) {
    throw 'IperfTarget is required for Throughput or Baseline workflows.'
  }

  $parameters = @{
    Target   = $Configuration.IperfTarget
    Port     = $Configuration.IperfPort
    Protocol = $Configuration.ThroughputProtocol
    OutDir   = $Artifacts.Throughput
  }
  if ($Configuration.Workflow -eq 'Baseline') { $parameters['SingleTest'] = $true }
  if ($Configuration.DryRun) { $parameters['WhatIf'] = $true }
  if ($Configuration.Quiet) { $parameters['Quiet'] = $true }

  return New-NetworkLanternWorkflowStep -Capability 'Throughput' -Parameters $parameters
}

function New-NetworkLanternTuningStep {
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Configuration)

  $parameters = @{
    Action        = $Configuration.TuningAction
    TuningProfile = $Configuration.TuningProfile
  }
  if ($Configuration.UdpPorts.Count -gt 0) { $parameters['UdpPorts'] = $Configuration.UdpPorts }
  if ($Configuration.IncludeAppPolicies) { $parameters['IncludeAppPolicies'] = $true }
  if ($Configuration.AppPaths.Count -gt 0) { $parameters['AppPaths'] = $Configuration.AppPaths }
  if ($Configuration.DryRun) { $parameters['DryRun'] = $true }

  return New-NetworkLanternWorkflowStep -Capability 'WindowsTuning' -Parameters $parameters
}
