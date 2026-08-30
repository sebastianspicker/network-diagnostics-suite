# Public wrappers retain the module contract. Each resolves an operator input
# once, then delegates the operation to the resolution-aware private core.

function Get-Iperf3ProfileNames {
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [string]$ProfilesFile,
    [switch]$StrictConfiguration
  )
  $default = if (-not $PSBoundParameters.ContainsKey('ProfilesFile')) { 'Default' } else { $null }
  $resolution = Resolve-ProfilesFilePath -ProfilesFile $ProfilesFile -Provenance $default
  return Get-Iperf3ProfileNamesCore -Resolution $resolution -StrictConfiguration:$StrictConfiguration
}

function Get-Iperf3ProfileParameters {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][string]$ProfileName,
    [string]$ProfilesFile,
    [switch]$StrictConfiguration
  )
  $default = if (-not $PSBoundParameters.ContainsKey('ProfilesFile')) { 'Default' } else { $null }
  $resolution = Resolve-ProfilesFilePath -ProfilesFile $ProfilesFile -Provenance $default
  return Get-Iperf3ProfileParametersCore -ProfileName $ProfileName -Resolution $resolution -StrictConfiguration:$StrictConfiguration
}

function Save-Iperf3Profile {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$ProfileName,
    [Parameter(Mandatory)][hashtable]$Parameters,
    [string]$ProfilesFile,
    [switch]$StrictConfiguration
  )
  $default = if (-not $PSBoundParameters.ContainsKey('ProfilesFile')) { 'Default' } else { $null }
  $resolution = Resolve-ProfilesFilePath -ProfilesFile $ProfilesFile -Provenance $default
  return Save-Iperf3ProfileCore -ProfileName $ProfileName -Parameters $Parameters -Resolution $resolution -StrictConfiguration:$StrictConfiguration
}

function Remove-Iperf3Profile {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][string]$ProfileName,
    [string]$ProfilesFile,
    [switch]$StrictConfiguration
  )
  $default = if (-not $PSBoundParameters.ContainsKey('ProfilesFile')) { 'Default' } else { $null }
  $resolution = Resolve-ProfilesFilePath -ProfilesFile $ProfilesFile -Provenance $default
  if (-not $PSCmdlet.ShouldProcess($resolution.Path, "Remove iperf3 profile '$ProfileName'")) { return $false }
  return Remove-Iperf3ProfileCore -ProfileName $ProfileName -Resolution $resolution -StrictConfiguration:$StrictConfiguration
}
