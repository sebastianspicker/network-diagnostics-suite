function Resolve-HomePath {
  <#
  .SYNOPSIS
    Return the current user's home directory, falling back to the working directory.
  .OUTPUTS
    [string] Absolute path to the home directory.
  #>
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    return $env:USERPROFILE
  }
  if (-not [string]::IsNullOrWhiteSpace($HOME)) {
    return $HOME
  }
  return (Get-Location).Path
}
