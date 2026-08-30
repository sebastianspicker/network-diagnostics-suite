function Get-DefaultLogDirectory {
  <#
  .SYNOPSIS
    Return the default log directory path (<home>/logs).
  .OUTPUTS
    [string] Absolute path to the logs directory.
  #>
  return (Join-Path (Resolve-HomePath) 'logs')
}
