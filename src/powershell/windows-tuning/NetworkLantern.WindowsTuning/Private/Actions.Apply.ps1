function Enable-NetworkTuningLocalQosMarking {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([bool])]
  param([switch]$DryRun)
  if ($DryRun) { Write-NetworkTuningInformation -Message '[DryRun] Enable local QoS marking (Do not use NLA).'; return }
  $qos = $script:NetworkTuningRegistryPathQos
  if (-not $PSCmdlet.ShouldProcess($qos, 'Enable local QoS marking (Do not use NLA)')) { return }
  Set-NetworkTuningRegistryValue -Key $qos -Name 'Do not use NLA' -Type String -Value '1' -Confirm:$false
}

function Set-NetworkTuningPowerPlan {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
  [OutputType([bool])]
  param([Parameter(Mandatory)][ValidateSet('HighPerformance')][string]$PowerPlan, [switch]$DryRun)
  $guid = $script:NetworkTuningPowerPlanGuidHighPerformance
  if ($DryRun) { Write-NetworkTuningInformation -Message ("[DryRun] powercfg /S {0}" -f $guid); return $true }
  if (-not $PSCmdlet.ShouldProcess($PowerPlan, 'Set active power plan')) { return $true }
  $null = & powercfg /S $guid 2>&1
  if ($LASTEXITCODE -ne 0) { Write-Warning -Message ("Could not switch your power plan. The selected plan may not be available on this PC (error code {0})." -f $LASTEXITCODE); return $false }
  return $true
}
