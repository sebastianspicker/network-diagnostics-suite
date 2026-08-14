[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The helper updates transient Windows Forms controls only.')]
param()

function Get-ParamHashFromRunTab {
  param([System.Windows.Forms.Form]$Form)
  $target = $Form.Controls.Find('txtTarget', $true) | Select-Object -First 1
  $port = $Form.Controls.Find('numPort', $true) | Select-Object -First 1
  $outDir = $Form.Controls.Find('txtOutDir', $true) | Select-Object -First 1
  $duration = $Form.Controls.Find('numDuration', $true) | Select-Object -First 1
  $protocol = $Form.Controls.Find('comboProtocol', $true) | Select-Object -First 1
  $ipVersion = $Form.Controls.Find('comboIpVersion', $true) | Select-Object -First 1
  $chkProgress = $Form.Controls.Find('chkProgress', $true) | Select-Object -First 1
  $chkSkipReach = $Form.Controls.Find('chkSkipReach', $true) | Select-Object -First 1
  $chkDisableMtu = $Form.Controls.Find('chkDisableMtu', $true) | Select-Object -First 1
  $chkSingleTest = $Form.Controls.Find('chkSingleTest', $true) | Select-Object -First 1
  $chkForce = $Form.Controls.Find('chkForce', $true) | Select-Object -First 1
  $chkStrict = $Form.Controls.Find('chkStrict', $true) | Select-Object -First 1
  $profilesFile = $Form.Controls.Find('txtProfilesFile', $true) | Select-Object -First 1

  $omit = $Form.Controls.Find('numOmit', $true) | Select-Object -First 1
  $retryCount = $Form.Controls.Find('numRetryCount', $true) | Select-Object -First 1
  $dscpClasses = $Form.Controls.Find('txtDscpClasses', $true) | Select-Object -First 1
  $tcpWindows = $Form.Controls.Find('txtTcpWindows', $true) | Select-Object -First 1
  $threshMinTput = $Form.Controls.Find('numThresholdMinTput', $true) | Select-Object -First 1
  $threshMaxLoss = $Form.Controls.Find('numThresholdMaxLoss', $true) | Select-Object -First 1
  $threshMaxJitter = $Form.Controls.Find('numThresholdMaxJitter', $true) | Select-Object -First 1
  $tcpStreamsCtrl = $Form.Controls.Find('txtTcpStreams', $true) | Select-Object -First 1
  $udpStart = $Form.Controls.Find('txtUdpStart', $true) | Select-Object -First 1
  $udpMax = $Form.Controls.Find('txtUdpMax', $true) | Select-Object -First 1
  $udpStep = $Form.Controls.Find('txtUdpStep', $true) | Select-Object -First 1
  $udpLossThreshold = $Form.Controls.Find('numUdpLossThreshold', $true) | Select-Object -First 1

  $hash = @{
    Target                = $target.Text.Trim()
    Port                  = [int]$port.Value
    OutDir                = $outDir.Text.Trim()
    Duration              = [int]$duration.Value
    Omit                  = [int]$omit.Value
    Protocol              = $protocol.SelectedItem.ToString()
    IpVersion             = $ipVersion.SelectedItem.ToString()
    Progress              = $chkProgress.Checked
    SkipReachabilityCheck = $chkSkipReach.Checked
    DisableMtuProbe       = $chkDisableMtu.Checked
    SingleTest            = $chkSingleTest.Checked
    Force                 = $chkForce.Checked
    StrictConfiguration   = $chkStrict.Checked
    ProfilesFile          = $profilesFile.Text.Trim()
    RetryCount            = [int]$retryCount.Value
    DscpClasses           = @($dscpClasses.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    TcpWindows            = @($tcpWindows.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    TcpStreams             = @($tcpStreamsCtrl.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { [int]$_ })
    UdpStart              = $udpStart.Text.Trim()
    UdpMax                = $udpMax.Text.Trim()
    UdpStep               = $udpStep.Text.Trim()
    UdpLossThreshold      = [double]$udpLossThreshold.Value
    Quiet                 = $false
  }
  if ([double]$threshMinTput.Value -gt 0) { $hash['ThresholdMinThroughputMbps'] = [double]$threshMinTput.Value }
  if ([double]$threshMaxLoss.Value -ge 0) { $hash['ThresholdMaxLossPct'] = [double]$threshMaxLoss.Value }
  if ([double]$threshMaxJitter.Value -ge 0) { $hash['ThresholdMaxJitterMs'] = [double]$threshMaxJitter.Value }
  return $hash
}

function Update-UiBusyState {
  param(
    [System.Windows.Forms.Form]$Form,
    [bool]$Busy
  )
  $btnRun = $Form.Controls.Find('btnRun', $true) | Select-Object -First 1
  $btnWhatIf = $Form.Controls.Find('btnWhatIf', $true) | Select-Object -First 1
  $btnCancel = $Form.Controls.Find('btnCancel', $true) | Select-Object -First 1
  $btnSaveProfile = $Form.Controls.Find('btnSaveProfile', $true) | Select-Object -First 1
  $btnLoadProfile = $Form.Controls.Find('btnLoadProfile', $true) | Select-Object -First 1
  $btnDeleteProfile = $Form.Controls.Find('btnDeleteProfile', $true) | Select-Object -First 1
  $btnRefreshProfiles = $Form.Controls.Find('btnRefreshProfiles', $true) | Select-Object -First 1

  foreach ($b in @($btnRun, $btnWhatIf, $btnSaveProfile, $btnLoadProfile, $btnDeleteProfile, $btnRefreshProfiles)) {
    if ($b) { $b.Enabled = -not $Busy }
  }
  if ($btnCancel) { $btnCancel.Enabled = $Busy }
}

function Test-RunFormValid {
  param(
    [System.Windows.Forms.Form]$Form,
    [System.Windows.Forms.ErrorProvider]$ErrorProvider
  )
  $target = $Form.Controls.Find('txtTarget', $true) | Select-Object -First 1
  $outDir = $Form.Controls.Find('txtOutDir', $true) | Select-Object -First 1
  $profilesFile = $Form.Controls.Find('txtProfilesFile', $true) | Select-Object -First 1
  $ok = $true
  $ErrorProvider.SetError($target, '')
  $ErrorProvider.SetError($outDir, '')
  if ($profilesFile) { $ErrorProvider.SetError($profilesFile, '') }
  if (-not $target.Text.Trim()) {
    $ErrorProvider.SetError($target, 'Target is required.')
    $ok = $false
  }
  elseif (-not (Test-ValidHostnameOrIP -Name $target.Text.Trim())) {
    $ErrorProvider.SetError($target, 'Invalid hostname or IP address.')
    $ok = $false
  }
  if (-not $outDir.Text.Trim()) {
    $ErrorProvider.SetError($outDir, 'Output directory is required.')
    $ok = $false
  }
  if ($profilesFile) {
    try {
      $null = Get-ProfilesFileFromForm -Form $Form
    }
    catch {
      $ErrorProvider.SetError($profilesFile, $_.Exception.Message)
      $ok = $false
    }
  }
  return $ok
}
