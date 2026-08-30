function Invoke-TracertRaw {
  <#
  .SYNOPSIS
    Execute a native tracert command and capture raw output.
  .PARAMETER Protocol
    IPv4 or IPv6.
  .PARAMETER HostName
    Target host.
  .PARAMETER ArgBuilder
    Scriptblock that builds the tracert argument list given (ipSwitch, host).
  .OUTPUTS
    [pscustomobject] with Raw (string[]) and ExitCode (int) properties.
  #>
  param(
    [Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')]$Protocol,
    [Parameter(Mandatory)][string]$HostName,
    [Parameter(Mandatory)][scriptblock]$ArgBuilder
  )

  $sw = Get-ToolIpSwitch -Protocol $Protocol
  $toolArgs = & $ArgBuilder $($sw.Tracert) $HostName
  if ($toolArgs -isnot [System.Array]) { $toolArgs = @($toolArgs) }
  $raw = tracert @toolArgs
  return [pscustomobject]@{ Raw = $raw; ExitCode = $LASTEXITCODE }
}
