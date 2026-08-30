Set-StrictMode -Version Latest

# Default parameter set for Measure-NetworkThroughput.  Public adapters use
# Get-NetworkThroughputDefaultParameterSet rather than duplicating these values.
$script:DefaultNetworkThroughputParams = @{
  Target = $null; Port = 5201; Duration = 10; Omit = 1; OutDir = $null
  Quiet = $false; Progress = $false; Summary = $false; DisableMtuProbe = $false
  SkipReachabilityCheck = $false; Force = $false; WhatIf = $false; Protocol = 'Both'
  SingleTest = $false; MtuSizes = @(1400, 1472, 1600); ConnectTimeoutMs = 60000
  UdpStart = '1M'; UdpMax = '1G'; UdpStep = '10M'; UdpLossThreshold = 5.0
  TcpStreams = @(1, 4, 8); TcpWindows = @('default', '128K', '256K')
  DscpClasses = @('CS0', 'AF11', 'CS5', 'EF', 'AF41'); IpVersion = 'Auto'
  ProfileName = $null; ProfilesFile = $null; SaveProfile = $false; ListProfiles = $false
  StrictConfiguration = $false; PassThru = $false; RetryCount = 0
  ThresholdMinThroughputMbps = $null; ThresholdMaxLossPct = $null; ThresholdMaxJitterMs = $null
}

# The loader intentionally defines dependency order and the complete public
# contract.  Implementations live in capability-owned scripts.
$privateDir = Join-Path $PSScriptRoot 'Private'
$publicDir = Join-Path $PSScriptRoot 'Public'
$privateScripts = @(
  'Test-PathUnderBase.ps1', 'Common.ps1', 'Validation.ps1',
  'Conversion.ps1', 'JsonParsing.ps1', 'ConfigValidation.ps1', 'ErrorClassification.ps1',
  'NativeProcess.ps1', 'Connectivity.ps1', 'Results.ps1', 'Profiles.ps1', 'Reporting.ps1',
  'Iperf3Invocation.ps1', 'Iperf3TestExecution.ps1', 'Orchestration.ps1'
)
$publicScripts = @(
  'Get-NetworkThroughputDefaultParameterSet.ps1', 'Measure-NetworkThroughput.ps1',
  'Compare-Iperf3Runs.ps1', 'Iperf3Profiles.ps1'
)
foreach ($scriptFile in $privateScripts) {
  $path = Join-Path $privateDir $scriptFile
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "NetworkLantern.Throughput: Missing private script: $scriptFile. Path: $privateDir"
  }
  . $path
}
foreach ($scriptFile in $publicScripts) {
  $path = Join-Path $publicDir $scriptFile
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "NetworkLantern.Throughput: Missing public script: $scriptFile. Path: $publicDir"
  }
  . $path
}

Export-ModuleMember -Function @(
  'Measure-NetworkThroughput',
  'Get-NetworkThroughputDefaultParameterSet',
  'Get-Iperf3ProfileNames',
  'Get-Iperf3ProfileParameters',
  'Save-Iperf3Profile',
  'Remove-Iperf3Profile',
  'Compare-Iperf3Runs'
)
