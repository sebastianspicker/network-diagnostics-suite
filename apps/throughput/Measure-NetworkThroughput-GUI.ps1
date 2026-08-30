<#
.SYNOPSIS
  Graphical UI for Network Lantern Throughput (Windows Forms).
.DESCRIPTION
  Launches a Windows Forms GUI to configure and run Measure-NetworkThroughput.
  Requires Windows and PowerShell 7+. Run with: pwsh -File .\Measure-NetworkThroughput-GUI.ps1
#>
#Requires -Version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'Start-Job receives arguments via -ArgumentList, not outer scope')]
param()

if (-not $IsWindows) {
  Write-Error 'GUI is only supported on Windows (System.Windows.Forms).'
  exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:ModulePath = Join-Path $script:RepoRoot 'src/powershell/throughput/NetworkLantern.Throughput.psd1'
Import-Module $script:ModulePath -Force

$script:RunJob = $null
$script:RunJobCancellationContext = $null
$script:RunJobStartedRecords = @()
$script:RunJobTerminalRecords = @()
$script:RunCancellationRequested = $false
$script:DeferredRunJobs = @()
$script:LastRunSummary = $null
$script:RunStartTime = $null

$privateDirectory = Join-Path $PSScriptRoot 'Private'
. (Join-Path $privateDirectory 'GuiFormHelpers.ps1')
. (Join-Path $privateDirectory 'GuiRunLifecycle.ps1')
. (Join-Path $privateDirectory 'GuiProfiles.ps1')
. (Join-Path $privateDirectory 'GuiUiConstruction.ps1')
. (Join-Path $privateDirectory 'ThroughputModuleAdapter.ps1')
. (Join-Path $privateDirectory 'PathOpening.ps1')

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 350
$timer.Add_Tick({
  Update-DeferredRunJobs
  if ($timer.Tag) {
    $done = Update-LogAndStateFromJob -Form $form -Job $timer.Tag -LogBox $txtLog -ProgressBar $progressBar -StatusLabel $statusLabel -Timer $timer
    if ($done) { $timer.Tag = $null }
  }
  elseif (@($script:DeferredRunJobs).Count -eq 0) {
    $timer.Stop()
  }
})

$btnRun.Add_Click({
  Start-RunFromUi -Form $form -ErrorProvider $errorProvider -ProgressBar $progressBar -StatusLabel $statusLabel -LogBox $txtLog -Timer $timer
})

$btnWhatIf.Add_Click({
  Start-RunFromUi -Form $form -ErrorProvider $errorProvider -ProgressBar $progressBar -StatusLabel $statusLabel -LogBox $txtLog -Timer $timer -WhatIf
})

$btnCancel.Add_Click({
  $released = Stop-CurrentRunJob -Timer $timer -StatusLabel $statusLabel
  if ($released) {
    $progressBar.Value = 0
    Update-UiBusyState -Form $form -Busy $false
  }
  else {
    Update-UiBusyState -Form $form -Busy $true
  }
})

$btnRefreshProfiles.Add_Click({ Update-ProfilesList -Form $form })
$btnLoadProfile.Add_Click({ Set-RunFormFromSelectedProfile -Form $form })
$btnSaveProfile.Add_Click({ Save-ProfileFromForm -Form $form })
$btnDeleteProfile.Add_Click({ Remove-SelectedProfile -Form $form })

$listProfiles.Add_SelectedIndexChanged({
  if ($listProfiles.SelectedItem) {
    $txtProfileName.Text = [string]$listProfiles.SelectedItem
  }
})

$form.Add_FormClosing({
  param($formSender, $formEventArgs)
  $null = $formSender
  $released = Stop-CurrentRunJob -Timer $timer -StatusLabel $statusLabel
  if (-not $released) {
    $formEventArgs.Cancel = $true
    Update-UiBusyState -Form $form -Busy $true
    return
  }
  Update-UiBusyState -Form $form -Busy $false
})

Update-ProfilesList -Form $form
[void]$form.ShowDialog()

if ($script:RunJob) {
  $null = Stop-CurrentRunJob -Timer $timer -StatusLabel $statusLabel
}
if (-not $script:RunJob) {
  Clear-RunCancellationContext
  if ($timer) { $timer.Stop() }
}
