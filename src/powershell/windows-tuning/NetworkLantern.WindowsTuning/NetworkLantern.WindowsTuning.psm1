Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$privateDir = Join-Path -Path $PSScriptRoot -ChildPath 'Private'
$constantsPath = Join-Path -Path $privateDir -ChildPath 'Constants.ps1'
if (-not (Test-Path -LiteralPath $constantsPath)) {
  throw "Required module file missing: $constantsPath"
}
. $constantsPath

$privateLoadOrder = @(
  'Logging.ps1',
  'Filesystem.ps1',
  'Registry.ps1',
  'Platform.ps1',
  'Qos.ps1',
  'Nic.ps1',
  'Restore.Status.ps1',
  'Backup.Artifacts.ps1',
  'Backup.Manifest.ps1',
  'Restore.AccessControl.ps1',
  'Restore.Staging.ps1',
  'Restore.Qos.ps1',
  'Restore.Validation.ps1',
  'Restore.Components.ps1',
  'Actions.Backup.ps1',
  'Actions.Restore.ps1',
  'Actions.Apply.ps1'
)
foreach ($fileName in $privateLoadOrder) {
  $filePath = Join-Path -Path $privateDir -ChildPath $fileName
  if (-not (Test-Path -LiteralPath $filePath)) {
    throw "Required private module file missing: $filePath"
  }
  . $filePath
}

$publicDir = Join-Path -Path $PSScriptRoot -ChildPath 'Public'
$publicLoadOrder = @(
  'Test-NetworkTuningAdministrator.ps1',
  'Get-NetworkLanternDefaultBackupFolder.ps1',
  'Invoke-NetworkPathTuning.ps1'
)
foreach ($fileName in $publicLoadOrder) {
  $filePath = Join-Path -Path $publicDir -ChildPath $fileName
  if (-not (Test-Path -LiteralPath $filePath)) {
    throw "Required public module file missing: $filePath"
  }
  . $filePath
}

Export-ModuleMember -Function 'Invoke-NetworkPathTuning', 'Get-NetworkLanternDefaultBackupFolder', 'Test-NetworkTuningAdministrator'
