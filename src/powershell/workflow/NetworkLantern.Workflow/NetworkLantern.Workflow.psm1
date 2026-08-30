Set-StrictMode -Version Latest

$privateRoot = Join-Path $PSScriptRoot 'Private'
$publicRoot = Join-Path $PSScriptRoot 'Public'

$privateLoadOrder = @(
  'Profiles.ps1'
  'Plan.ps1'
)
$publicLoadOrder = @('New-NetworkLanternWorkflowPlan.ps1')

foreach ($fileName in $privateLoadOrder) {
  $filePath = Join-Path $privateRoot $fileName
  if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
    throw "NetworkLantern.Workflow: Required private module file missing: $filePath"
  }
  . $filePath
}

foreach ($fileName in $publicLoadOrder) {
  $filePath = Join-Path $publicRoot $fileName
  if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
    throw "NetworkLantern.Workflow: Required public module file missing: $filePath"
  }
  . $filePath
}

Export-ModuleMember -Function @('New-NetworkLanternWorkflowPlan')
