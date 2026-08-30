Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PathModuleVersion = '1.1.0'
$script:PathQuiet = $false
$script:RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path

$privateDir = Join-Path -Path $PSScriptRoot -ChildPath 'Private'
$privateLoadOrder = @(
  'Resolve-HomePath.ps1',
  'Get-DefaultLogDirectory.ps1',
  'Test-HostNameSafe.ps1',
  'Test-PathSafe.ps1',
  'Get-HostsFromConfig.ps1',
  'Get-RoundDefinitions.ps1',
  'Get-DiagnosticPlan.ps1',
  'Get-ToolIpSwitch.ps1',
  'Get-HostAddressesWithTimeout.ps1',
  'Test-TcpPort.ps1',
  'Invoke-PingRaw.ps1',
  'Invoke-TracertRaw.ps1',
  'Invoke-PathpingRaw.ps1',
  'Write-Status.ps1',
  'Invoke-HostDiagnostics.ps1',
  'Invoke-DiagnosticsMatrix.ps1',
  'Save-DiagnosticResults.ps1'
)
foreach ($fileName in $privateLoadOrder) {
  $filePath = Join-Path -Path $privateDir -ChildPath $fileName
  if (-not (Test-Path -LiteralPath $filePath)) {
    throw "NetworkLantern.Path: Required private module file missing: $filePath"
  }
  . $filePath
}

$publicDir = Join-Path -Path $PSScriptRoot -ChildPath 'Public'
$publicLoadOrder = @('Invoke-NetworkPathDiagnostics.ps1')
foreach ($fileName in $publicLoadOrder) {
  $filePath = Join-Path -Path $publicDir -ChildPath $fileName
  if (-not (Test-Path -LiteralPath $filePath)) {
    throw "NetworkLantern.Path: Required public module file missing: $filePath"
  }
  . $filePath
}

Export-ModuleMember -Function 'Invoke-NetworkPathDiagnostics'
