function New-NetworkLanternWorkflowPlan {
  [CmdletBinding()]
  param(
    [ValidateSet('Triage', 'Path', 'Throughput', 'Baseline', 'WindowsTuning')][string]$Workflow = 'Triage',
    [string]$ProfilePath,
    [string[]]$HostsIPv4,
    [string[]]$HostsIPv6,
    [ValidateSet('IPv4', 'IPv6')][string[]]$Protocols,
    [string[]]$Rounds,
    [string]$IperfTarget,
    [ValidateRange(1, 65535)][int]$IperfPort = 5201,
    [ValidateSet('TCP', 'UDP', 'Both')][string]$ThroughputProtocol = 'Both',
    [ValidateSet('Apply', 'Backup', 'Restore', 'Verify')][string]$TuningAction = 'Apply',
    [ValidateSet('Safe', 'Measured')][string]$TuningProfile = 'Safe',
    [uint16[]]$UdpPorts,
    [switch]$IncludeAppPolicies,
    [string[]]$AppPaths,
    [Parameter(Mandatory)][string]$OutRoot,
    [switch]$SkipPathping,
    [switch]$DryRun,
    [switch]$Quiet,
    [Parameter(Mandatory)][hashtable]$ExplicitParameters
  )

  $workflowProfile = Import-NetworkLanternWorkflowProfile -ProfilePath $ProfilePath
  Write-NetworkLanternWorkflowProfileWarnings -ProfileMap $workflowProfile
  $pathProfile = Get-NetworkLanternProfileSection -ProfileMap $workflowProfile -Name 'path'
  $throughputProfile = Get-NetworkLanternProfileSection -ProfileMap $workflowProfile -Name 'throughput'
  $tuningSection = Get-NetworkLanternProfileSection -ProfileMap $workflowProfile -Name 'windowsTuning'
  $artifacts = Get-NetworkLanternArtifactLocations -ArtifactRoot $OutRoot

  $configuration = @{
    Workflow           = $Workflow
    HostsIPv4          = @(Resolve-NetworkLanternEffectiveValue -ExplicitValue $HostsIPv4 -ExplicitValueWasProvided $ExplicitParameters.ContainsKey('HostsIPv4') -Section $pathProfile -Key 'hostsIPv4' -Fallback @())
    HostsIPv6          = @(Resolve-NetworkLanternEffectiveValue -ExplicitValue $HostsIPv6 -ExplicitValueWasProvided $ExplicitParameters.ContainsKey('HostsIPv6') -Section $pathProfile -Key 'hostsIPv6' -Fallback @())
    Protocols          = @(Resolve-NetworkLanternEffectiveValue -ExplicitValue $Protocols -ExplicitValueWasProvided $ExplicitParameters.ContainsKey('Protocols') -Section $pathProfile -Key 'protocols' -Fallback @('IPv4', 'IPv6'))
    Rounds             = @(Resolve-NetworkLanternEffectiveValue -ExplicitValue $Rounds -ExplicitValueWasProvided $ExplicitParameters.ContainsKey('Rounds') -Section $pathProfile -Key 'rounds' -Fallback @())
    IperfTarget        = (Resolve-NetworkLanternEffectiveValue -ExplicitValue $IperfTarget -ExplicitValueWasProvided $ExplicitParameters.ContainsKey('IperfTarget') -Section $throughputProfile -Key 'target')
    IperfPort          = (Resolve-NetworkLanternEffectiveValue -ExplicitValue $IperfPort -ExplicitValueWasProvided $ExplicitParameters.ContainsKey('IperfPort') -Section $throughputProfile -Key 'port' -Fallback 5201)
    ThroughputProtocol = (Resolve-NetworkLanternEffectiveValue -ExplicitValue $ThroughputProtocol -ExplicitValueWasProvided $ExplicitParameters.ContainsKey('ThroughputProtocol') -Section $throughputProfile -Key 'protocol' -Fallback 'Both')
    TuningAction       = (Resolve-NetworkLanternEffectiveValue -ExplicitValue $TuningAction -ExplicitValueWasProvided $ExplicitParameters.ContainsKey('TuningAction') -Section $tuningSection -Key 'action' -Fallback 'Apply')
    TuningProfile      = (Resolve-NetworkLanternEffectiveValue -ExplicitValue $TuningProfile -ExplicitValueWasProvided $ExplicitParameters.ContainsKey('TuningProfile') -Section $tuningSection -Key 'profile' -Fallback 'Safe')
    UdpPorts           = @(Resolve-NetworkLanternEffectiveValue -ExplicitValue $UdpPorts -ExplicitValueWasProvided $ExplicitParameters.ContainsKey('UdpPorts') -Section $tuningSection -Key 'udpPorts' -Fallback @())
    AppPaths           = @(Resolve-NetworkLanternEffectiveValue -ExplicitValue $AppPaths -ExplicitValueWasProvided $ExplicitParameters.ContainsKey('AppPaths') -Section $tuningSection -Key 'appPaths' -Fallback @())
    IncludeAppPolicies = [bool]$IncludeAppPolicies
    SkipPathping       = [bool]$SkipPathping
    DryRun             = [bool]$DryRun
    Quiet              = [bool]$Quiet
  }

  $steps = switch ($Workflow) {
    'Path' { @(New-NetworkLanternPathStep -Configuration $configuration -Artifacts $artifacts) }
    'Throughput' { @(New-NetworkLanternThroughputStep -Configuration $configuration -Artifacts $artifacts) }
    'Baseline' {
      @(
        (New-NetworkLanternPathStep -Configuration $configuration -Artifacts $artifacts)
        (New-NetworkLanternThroughputStep -Configuration $configuration -Artifacts $artifacts)
      )
    }
    'WindowsTuning' { @(New-NetworkLanternTuningStep -Configuration $configuration) }
    'Triage' {
      $triageSteps = @(New-NetworkLanternPathStep -Configuration $configuration -Artifacts $artifacts)
      if ([string]::IsNullOrWhiteSpace($configuration.IperfTarget)) {
        Write-Warning 'Throughput skipped: IperfTarget not provided for Triage workflow.'
      } else {
        $triageSteps += New-NetworkLanternThroughputStep -Configuration $configuration -Artifacts $artifacts
      }
      $triageSteps
    }
  }

  return [pscustomobject]@{
    Workflow = $Workflow
    Steps    = @($steps)
  }
}
