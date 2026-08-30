function Invoke-HostDiagnostics {
  <#
  .SYNOPSIS
    Run the full diagnostic suite (ping, tracert, pathping, and TCP 443) for one plan item.
  .PARAMETER PlanItem
    A single plan entry from Get-DiagnosticPlan.
  .OUTPUTS
    [pscustomobject] Consolidated result with ping/tracert/pathping/TCP findings.
  #>
  param(
    [Parameter(Mandatory)][object]$PlanItem,
    [Parameter(Mandatory)][object]$Settings
  )

  $round = $PlanItem.RoundDef
  $proto = $PlanItem.Protocol
  $h = $PlanItem.Host

  $pingResult = Invoke-PingRaw -Protocol $proto -HostName $h -Count $Settings.PingCount -ArgBuilder4 $round.PingArgs4 -ArgBuilder6 $round.PingArgs6
  $trResult = Invoke-TracertRaw -Protocol $proto -HostName $h -ArgBuilder $round.TracertArgs

  $ppResult = if ($Settings.SkipPathping) {
    [pscustomobject]@{ Raw = @('Pathping skipped'); ExitCode = $null }
  } else {
    Invoke-PathpingRaw -Protocol $proto -HostName $h -ArgBuilder $round.PathpingArgs
  }

  $tnc = Test-TcpPort -HostName $h -Port 443 -Protocol $proto

  $pingOk = ($pingResult.ExitCode -eq 0)
  $tracertOk = ($trResult.ExitCode -eq 0)
  $pathpingOk = if ($Settings.SkipPathping) { $null } else { ($ppResult.ExitCode -eq 0) }
  $tcp443Ok = [bool]$tnc.TcpTestSucceeded
  $failedStages = New-Object System.Collections.Generic.List[string]
  if (-not $pingOk) { $failedStages.Add('Ping') | Out-Null }
  if (-not $tracertOk) { $failedStages.Add('Tracert') | Out-Null }
  if ($null -ne $pathpingOk -and -not $pathpingOk) { $failedStages.Add('Pathping') | Out-Null }
  if (-not $tcp443Ok) { $failedStages.Add('Tcp443') | Out-Null }
  $overallStatus = if ($failedStages.Count -gt 0) { 'Fail' } else { 'OK' }

  return [pscustomobject]@{
    Timestamp = (Get-Date).ToString('o')
    Round = $round.Name
    Protocol = $proto
    Host = $h
    PingRaw = $pingResult.Raw
    PingOk = $pingOk
    PingStatus = if ($pingOk) { 'OK' } else { 'Fail' }
    TracertRaw = $trResult.Raw
    TracertOk = $tracertOk
    TracertStatus = if ($tracertOk) { 'OK' } else { 'Fail' }
    PathpingRaw = $ppResult.Raw
    PathpingOk = $pathpingOk
    PathpingStatus = if ($Settings.SkipPathping) { 'Skipped' } elseif ($pathpingOk) { 'OK' } else { 'Fail' }
    Tcp443OK = $tcp443Ok
    Tcp443Status = if ($tcp443Ok) { 'OK' } else { 'Fail' }
    TraceRoute = $trResult.Raw
    Ports = @()
    PortsStatus = 'Skipped'
    FailedStages = $failedStages.ToArray()
    OverallStatus = $overallStatus
  }
}
