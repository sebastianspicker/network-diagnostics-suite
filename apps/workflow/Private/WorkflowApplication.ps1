$script:NetworkLanternWorkflowEnvelopeMaxBytes = 1MB

function Get-NetworkLanternWorkflowCapabilityDescriptors {
  [CmdletBinding()]
  param()

  # Keep executable paths out of the child envelope. This table is embedded in
  # the child bootstrap and is the sole authority for adapter and parameter
  # validation on both sides of the process boundary.
  return [ordered]@{
    Path = @{
      AdapterRelativePath = 'apps/path/Test-NetworkPath.ps1'
      AllowedParameters = @('LogDirectory', 'HostsIPv4', 'HostsIPv6', 'Protocols', 'Rounds', 'SkipPathping', 'DryRun', 'Quiet')
      RepositoryRelativeParameters = @{}
    }
    Throughput = @{
      AdapterRelativePath = 'apps/throughput/Measure-NetworkThroughput.ps1'
      AllowedParameters = @('Target', 'Port', 'Protocol', 'OutDir', 'SingleTest', 'WhatIf', 'Quiet')
      RepositoryRelativeParameters = @{ ProfilesFile = 'profiles/throughput-profiles.local.json' }
    }
    WindowsTuning = @{
      AdapterRelativePath = 'apps/windows-tuning/Invoke-NetworkPathTuning.ps1'
      AllowedParameters = @('Action', 'TuningProfile', 'UdpPorts', 'IncludeAppPolicies', 'AppPaths', 'DryRun')
      RepositoryRelativeParameters = @{}
    }
  }
}

function Get-NetworkLanternTrustedCapabilityAdapters {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$RepositoryRoot)

  $adapters = @{}
  foreach ($entry in (Get-NetworkLanternWorkflowCapabilityDescriptors).GetEnumerator()) {
    $adapters[$entry.Key] = Join-Path $RepositoryRoot $entry.Value.AdapterRelativePath
  }

  return $adapters
}

function Test-NetworkLanternWorkflowCapabilityStep {
  [CmdletBinding()]
  param([Parameter(Mandatory)][pscustomobject]$Step)

  $capability = [string]$Step.Capability
  $descriptors = Get-NetworkLanternWorkflowCapabilityDescriptors
  if (-not $descriptors.Contains($capability)) {
    throw "Unsupported workflow capability '$capability'."
  }
  if ($Step.Parameters -isnot [hashtable]) {
    throw "Workflow capability '$capability' has invalid parameters."
  }

  $descriptor = $descriptors[$capability]
  foreach ($key in @($Step.Parameters.Keys)) {
    if ($key -notin @($descriptor.AllowedParameters)) {
      throw "Unsupported parameter '$key' for workflow capability '$capability'."
    }
  }

  return $descriptor
}

function New-NetworkLanternCapabilityChildBootstrap {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$RepositoryRoot)

  $rootEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($RepositoryRoot))
  $descriptorsJson = ConvertTo-Json -InputObject (Get-NetworkLanternWorkflowCapabilityDescriptors) -Compress -Depth 8
  $descriptorsEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($descriptorsJson))
  $bootstrap = @"
`$trustedRepositoryRoot = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$rootEncoded'))
`$trustedDescriptorsJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$descriptorsEncoded'))
`$trustedDescriptors = ConvertFrom-Json -InputObject `$trustedDescriptorsJson -AsHashtable
`$maximumEnvelopeBytes = 1MB
`$inputStream = [Console]::OpenStandardInput()
`$readBuffer = [byte[]]::new(8192)
`$envelopeBytes = [System.IO.MemoryStream]::new()
try {
  while (`$envelopeBytes.Length -le `$maximumEnvelopeBytes) {
    `$remainingBytes = (`$maximumEnvelopeBytes + 1) - [int]`$envelopeBytes.Length
    `$bytesRead = `$inputStream.Read(`$readBuffer, 0, [Math]::Min(`$readBuffer.Length, `$remainingBytes))
    if (`$bytesRead -eq 0) {
      break
    }
    `$envelopeBytes.Write(`$readBuffer, 0, `$bytesRead)
  }
  if (`$envelopeBytes.Length -gt `$maximumEnvelopeBytes) {
    throw 'Workflow child envelope exceeds maximum size (1 MB).'
  }
  `$envelopeJson = [System.Text.Encoding]::UTF8.GetString(`$envelopeBytes.ToArray())
} finally {
  `$envelopeBytes.Dispose()
  `$inputStream.Dispose()
}

`$envelope = ConvertFrom-Json -InputObject `$envelopeJson -AsHashtable
if (`$null -eq `$envelope -or `$envelope.ContainsKey('ScriptPath') -or `$envelope.ContainsKey('AdapterPath')) {
  throw 'Workflow child envelope is invalid.'
}

`$capability = [string]`$envelope.Capability
if (-not `$trustedDescriptors.ContainsKey(`$capability) -or `$envelope.Parameters -isnot [hashtable]) {
  throw "Unsupported workflow capability '`$capability'."
}

`$descriptor = `$trustedDescriptors[`$capability]
`$parameters = @{}
foreach (`$key in @(`$envelope.Parameters.Keys)) {
  if (`$key -notin @(`$descriptor.AllowedParameters)) {
    throw "Unsupported parameter '`$key' for workflow capability '`$capability'."
  }
  `$value = `$envelope.Parameters[`$key]
  if (`$value -is [System.Collections.IEnumerable] -and -not (`$value -is [string])) {
    `$value = @(`$value)
  }
  `$parameters[`$key] = `$value
}
foreach (`$parameterName in @(`$descriptor.RepositoryRelativeParameters.Keys)) {
  `$parameters[`$parameterName] = Join-Path `$trustedRepositoryRoot `$descriptor.RepositoryRelativeParameters[`$parameterName]
}

`$trustedAdapter = Join-Path `$trustedRepositoryRoot `$descriptor.AdapterRelativePath
& `$trustedAdapter @parameters
exit ([int]`$LASTEXITCODE)
"@

  return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($bootstrap))
}

function Invoke-NetworkLanternCapabilityChild {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][pscustomobject]$Step,
    [Parameter(Mandatory)][string]$RepositoryRoot
  )

  $null = Test-NetworkLanternWorkflowCapabilityStep -Step $Step
  $trustedAdapters = Get-NetworkLanternTrustedCapabilityAdapters -RepositoryRoot $RepositoryRoot
  $capability = [string]$Step.Capability
  if (-not $trustedAdapters.ContainsKey($capability)) {
    throw "Unsupported workflow capability '$capability'."
  }

  $envelope = @{ Capability = $capability; Parameters = $Step.Parameters }
  $envelopeJson = ConvertTo-Json -InputObject $envelope -Compress -Depth 8
  if ([System.Text.Encoding]::UTF8.GetByteCount($envelopeJson) -gt $script:NetworkLanternWorkflowEnvelopeMaxBytes) {
    throw 'Workflow child envelope exceeds maximum size (1 MB).'
  }

  $bootstrap = New-NetworkLanternCapabilityChildBootstrap -RepositoryRoot $RepositoryRoot
  $envelopeJson | & pwsh -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand $bootstrap | Out-Host
  return [int]$LASTEXITCODE
}
