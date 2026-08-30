function Invoke-PingRaw {
  <#
  .SYNOPSIS
    Execute a native ping command and capture raw output.
  .PARAMETER Protocol
    IPv4 or IPv6.
  .PARAMETER HostName
    Target host.
  .PARAMETER Count
    Number of echo requests.
  .PARAMETER ArgBuilder4
    Scriptblock that builds the ping argument list for IPv4.
  .PARAMETER ArgBuilder6
    Scriptblock that builds the ping argument list for IPv6.
  .OUTPUTS
    [pscustomobject] with Raw (string[]) and ExitCode (int) properties.
  #>
  param(
    [Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')]$Protocol,
    [Parameter(Mandatory)][string]$HostName,
    [Parameter(Mandatory)][int]$Count,
    [Parameter(Mandatory)][scriptblock]$ArgBuilder4,
    [Parameter(Mandatory)][scriptblock]$ArgBuilder6
  )

  $toolArgs = if ($Protocol -eq 'IPv6') { & $ArgBuilder6 $HostName $Count } else { & $ArgBuilder4 $HostName $Count }
  if ($toolArgs -isnot [System.Array]) { $toolArgs = @($toolArgs) }
  $raw = ping @toolArgs
  return [pscustomobject]@{ Raw = $raw; ExitCode = $LASTEXITCODE }
}
