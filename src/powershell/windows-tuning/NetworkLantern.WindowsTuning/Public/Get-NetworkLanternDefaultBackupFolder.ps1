function Get-NetworkLanternDefaultBackupFolder {
  <#
  .SYNOPSIS
    Returns the default backup folder path used by the Network Lantern tuning module.
  .OUTPUTS
    [string]
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  return $script:NetworkTuningDefaultBackupFolder
}
