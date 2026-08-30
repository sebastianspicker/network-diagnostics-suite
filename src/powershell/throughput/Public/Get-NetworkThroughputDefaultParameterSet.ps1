function Get-NetworkThroughputDefaultParameterSet {
  <#
  .SYNOPSIS
  Returns the default parameter set for Measure-NetworkThroughput.
  .OUTPUTS
  [hashtable]
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()
  $src = $script:DefaultNetworkThroughputParams
  $h = @{}
  foreach ($key in $src.Keys) {
    $val = $src[$key]
    if ($null -eq $val) { $h[$key] = $null }
    elseif ($val -is [array]) { $h[$key] = @($val) }
    else { $h[$key] = $val }
  }
  if (-not $h['OutDir']) { $h['OutDir'] = Join-Path (Get-Location) 'logs' }
  if (-not $h['ProfilesFile']) { $h['ProfilesFile'] = Get-DefaultProfilesFilePath }
  return $h
}
