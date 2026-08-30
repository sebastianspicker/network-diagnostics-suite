function Measure-NetworkThroughput {
  <#
  .SYNOPSIS
  Runs a TCP/UDP iperf3 test matrix and writes CSV/JSON artifacts.
  .DESCRIPTION
  Executes a DSCP-marked TCP and UDP test suite against an iperf3 server.
  The function produces CSV/JSON results, a summary JSON, and a Markdown report in OutDir.
  Use -PassThru to receive the run summary object on the pipeline.
  Use -WhatIf to preview the test plan without executing any tests.
  #>
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'Custom -WhatIf switch is intentionally passed through for preview behavior without state mutation.')]
  [CmdletBinding()]
  param(
    [string]$Target,
    [ValidateRange(1, 65535)] [int]$Port = 5201,
    [ValidateRange(1, 3600)] [int]$Duration = 10,
    [ValidateRange(0, 60)] [int]$Omit = 1,
    [ValidateNotNullOrEmpty()] [string]$OutDir = (Join-Path (Get-Location) 'logs'),
    [switch]$Quiet,
    [switch]$Progress,
    [switch]$Summary,
    [switch]$DisableMtuProbe,
    [switch]$SkipReachabilityCheck,
    [ValidateNotNullOrEmpty()] [int[]]$MtuSizes = @(1400, 1472, 1600),
    [ValidateRange(1000, 300000)] [int]$ConnectTimeoutMs = 60000,
    [ValidateNotNullOrEmpty()] [string]$UdpStart = '1M',
    [ValidateNotNullOrEmpty()] [string]$UdpMax = '1G',
    [ValidateNotNullOrEmpty()] [string]$UdpStep = '10M',
    [ValidateRange(0, 100)] [double]$UdpLossThreshold = 5.0,
    [ValidateNotNullOrEmpty()] [int[]]$TcpStreams = @(1, 4, 8),
    [ValidateNotNullOrEmpty()] [string[]]$TcpWindows = @('default', '128K', '256K'),
    [ValidateNotNullOrEmpty()] [string[]]$DscpClasses = @('CS0', 'AF11', 'CS5', 'EF', 'AF41'),
    [ValidateSet('IPv4', 'IPv6', 'Auto')] [string]$IpVersion = 'Auto',
    [ValidateSet('TCP', 'UDP', 'Both')] [string]$Protocol = 'Both',
    [switch]$SingleTest,
    [ValidateRange(0, 5)] [int]$RetryCount = 0,
    [switch]$Force,
    [switch]$WhatIf,
    [string]$ProfileName,
    [string]$ProfilesFile,
    [switch]$SaveProfile,
    [switch]$ListProfiles,
    [switch]$StrictConfiguration,
    [switch]$PassThru,
    [ValidateRange(0, [double]::MaxValue)] [nullable[double]]$ThresholdMinThroughputMbps,
    [ValidateRange(0, 100)] [nullable[double]]$ThresholdMaxLossPct,
    [ValidateRange(0, [double]::MaxValue)] [nullable[double]]$ThresholdMaxJitterMs
  )

  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = 'Stop'
  try {
    $effective = Get-NetworkThroughputDefaultParameterSet
    foreach ($k in $PSBoundParameters.Keys) {
      if ($effective.ContainsKey($k)) { $effective[$k] = $PSBoundParameters[$k] }
    }
    $strict = [bool]$effective['StrictConfiguration']
    $allowedKeys = @($script:DefaultNetworkThroughputParams.Keys)
    # Resolve the default as a relative path too, so a pre-existing .iperf3
    # reparse point cannot redirect the default profile store outside cwd.
    $defaultProfile = if (-not $PSBoundParameters.ContainsKey('ProfilesFile')) { 'Default' } else { $null }
    $profileResolution = Resolve-ProfilesFilePath -ProfilesFile $effective['ProfilesFile'] -Provenance $defaultProfile
    $effective['ProfilesFile'] = $profileResolution.Path

    if ($effective['ProfileName'] -and -not $effective['SaveProfile'] -and -not $effective['ListProfiles']) {
      $profileParams = Get-Iperf3ProfileParametersCore -ProfileName $effective['ProfileName'] -Resolution $profileResolution -StrictConfiguration:$strict
      $profileValidation = ConvertTo-Iperf3NormalizedParameterSet -InputParameters $profileParams -AllowedKeys $allowedKeys -StrictConfiguration:$strict
      foreach ($w in $profileValidation.Warnings) { Write-Warning $w }
      foreach ($k in $profileValidation.Parameters.Keys) { $effective[$k] = $profileValidation.Parameters[$k] }
      foreach ($k in $PSBoundParameters.Keys) {
        if ($effective.ContainsKey($k)) { $effective[$k] = $PSBoundParameters[$k] }
      }
    }
    if ($effective['ListProfiles']) {
      $names = Get-Iperf3ProfileNamesCore -Resolution $profileResolution -StrictConfiguration:$strict
      if (-not $effective['Quiet']) {
        Write-Information -InformationAction Continue "Profiles file: $($effective['ProfilesFile'])"
        if ($names.Count -eq 0) { Write-Information -InformationAction Continue 'No profiles found.' }
        else { foreach ($n in $names) { Write-Information -InformationAction Continue "- $n" } }
      }
      if ($effective['PassThru']) { return [pscustomobject]@{ Mode = 'ListProfiles'; Profiles = $names; ProfilesFile = $effective['ProfilesFile'] } }
      return
    }
    if (-not $effective['Target']) { Write-Iperf3Error -Message 'Target is required. Provide -Target ''hostname'' directly or via a saved profile (-ProfileName).' -ErrorId 'NetworkLantern.Throughput.InputValidation' }
    if (-not (Test-ValidHostnameOrIP -Name ([string]$effective['Target']))) { Write-Iperf3Error -Message "Invalid Target: '$($effective['Target'])'. Must be a valid hostname or IP address." -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $effective['Target'] }
    if ($effective['SaveProfile']) {
      if (-not $effective['ProfileName']) { Write-Iperf3Error -Message 'ProfileName is required when using -SaveProfile.' -ErrorId 'NetworkLantern.Throughput.InputValidation' }
      $saveResult = Save-Iperf3ProfileCore -ProfileName $effective['ProfileName'] -Parameters $effective -Resolution $profileResolution -StrictConfiguration:$strict
      if (-not $effective['Quiet']) { Write-Information -InformationAction Continue "Saved profile '$($saveResult.ProfileName)' to '$($saveResult.ProfilesFile)'." }
    }

    $startedUtc = (Get-Date).ToUniversalTime()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $jsonPath = Join-Path -Path $effective['OutDir'] -ChildPath "iperf3_results_$ts.json"
    $csvPath = Join-Path -Path $effective['OutDir'] -ChildPath "iperf3_summary_$ts.csv"
    $caps = $null
    if ([bool]$effective['WhatIf']) {
      try { $caps = Get-Iperf3Capability }
      catch { $caps = [pscustomobject]@{ VersionText = 'unknown (iperf3 not available)'; Major = $null; Minor = $null; BidirSupported = $false } }
    }
    else {
      try {
        Test-NetworkThroughputPrerequisites -SkipReachabilityCheck:([bool]$effective['SkipReachabilityCheck']) -DisableMtuProbe:([bool]$effective['DisableMtuProbe'])
        $caps = Get-Iperf3Capability
        if ($null -ne $caps.Major -and $null -ne $caps.Minor -and ($caps.Major -lt 3 -or ($caps.Major -eq 3 -and $caps.Minor -lt 7))) {
          Write-Iperf3Error -Message "iperf3 3.7 or newer is required (detected: $($caps.VersionText))." -ErrorId 'NetworkLantern.Throughput.Prerequisite' -TargetObject $caps.VersionText
        }
      }
      catch {
        throw (Get-Iperf3ClassifiedErrorRecord -ErrorRecord $_ -DefaultErrorId 'NetworkLantern.Throughput.Prerequisite')
      }
    }
    if ([bool]$effective['SingleTest'] -and @($effective['DscpClasses']).Count -eq 0) { Write-Iperf3Error -Message "At least one DSCP class is required. When using -SingleTest, ensure DscpClasses contains at least one value (e.g. 'CS0')." -ErrorId 'NetworkLantern.Throughput.InputValidation' }
    $plan = Build-TestPlan -SingleTest:([bool]$effective['SingleTest']) -Protocol ([string]$effective['Protocol']) -DscpClasses @($effective['DscpClasses']) -TcpStreams @($effective['TcpStreams']) -TcpWindows @($effective['TcpWindows']) -Caps $caps -UdpStart ([string]$effective['UdpStart']) -UdpMax ([string]$effective['UdpMax']) -UdpStep ([string]$effective['UdpStep'])
    if ([bool]$effective['WhatIf']) {
      if (-not $effective['Quiet']) {
        Write-Information -InformationAction Continue "WhatIf: Would run approximately $($plan.TotalApprox) tests. Target: $($effective['Target']) Port: $($effective['Port']) Protocol: $($effective['Protocol'])."
        Write-Information -InformationAction Continue "CSV  : $csvPath"
        Write-Information -InformationAction Continue "JSON : $jsonPath"
      }
      if ($effective['PassThru']) { return [pscustomobject]@{ Mode = 'WhatIf'; TotalApprox = $plan.TotalApprox; CsvPath = $csvPath; JsonPath = $jsonPath; EffectiveParameters = $effective } }
      return
    }

    $null = New-Item -ItemType Directory -Path $effective['OutDir'] -Force
    try {
      $conn = Get-TestSuiteConnectivity -Target ([string]$effective['Target']) -Port ([int]$effective['Port']) -IpVersion ([string]$effective['IpVersion']) -SkipReachabilityCheck:([bool]$effective['SkipReachabilityCheck']) -DisableMtuProbe:([bool]$effective['DisableMtuProbe']) -MtuSizes @($effective['MtuSizes']) -ConnectTimeoutMs ([int]$effective['ConnectTimeoutMs'])
    }
    catch {
      throw (Get-Iperf3ClassifiedErrorRecord -ErrorRecord $_ -DefaultErrorId 'NetworkLantern.Throughput.Connectivity')
    }
    $stack = $conn.Stack; $net = $conn.Net; $mtuFails = $conn.MtuFails
    if (-not $effective['Quiet']) {
      Write-Information -InformationAction Continue "Target: $($effective['Target']) Port: $($effective['Port']) Stack: $stack (~$($plan.TotalApprox) tests)"
      Write-Information -InformationAction Continue "CSV  : $csvPath"
      Write-Information -InformationAction Continue "JSON : $jsonPath"
    }
    if ((Test-Path -LiteralPath $csvPath) -or (Test-Path -LiteralPath $jsonPath)) { if (-not $effective['Force']) { Write-Iperf3Error -Message 'Output file(s) already exist. Use -Force to overwrite.' -ErrorId 'NetworkLantern.Throughput.InputValidation' } }
    $allResults = New-Object System.Collections.Generic.List[object]
    $csvRows = New-Object System.Collections.Generic.List[object]
    $testNo = 0
    $script:ActiveRetryCount = [int]$effective['RetryCount']
    $sharedParams = @{ AllResultsList = $allResults; CsvRowsList = $csvRows; Stack = $stack; Target = [string]$effective['Target']; Port = [int]$effective['Port']; Duration = [int]$effective['Duration']; Omit = [int]$effective['Omit']; ConnectTimeoutMs = [int]$effective['ConnectTimeoutMs']; Caps = $caps; Progress = [bool]$effective['Progress']; TotalApprox = $plan.TotalApprox }
    foreach ($dscp in $plan.DscpList) {
      $tos = Get-TosFromDscpClass -Class $dscp
      if ($plan.RunTcp) { Invoke-TcpMatrix @sharedParams -TestNoRef ([ref]$testNo) -Dscp $dscp -Tos $tos -DirsTcpList $plan.DirsTcpList -TcpStreamsList $plan.TcpStreamsList -TcpWindowsList $plan.TcpWindowsList }
      if ($plan.RunUdp) { Invoke-UdpMatrix @sharedParams -TestNoRef ([ref]$testNo) -Dscp $dscp -Tos $tos -UdpStart ([string]$effective['UdpStart']) }
      if ($plan.RunSingleUdp) { Invoke-UdpSingleTest @sharedParams -TestNoRef ([ref]$testNo) -Dscp $dscp -Tos $tos -UdpStart ([string]$effective['UdpStart']) }
      if ($plan.RunUdp) { Invoke-UdpSaturationMatrix @sharedParams -TestNoRef ([ref]$testNo) -Dscp $dscp -Tos $tos -UdpLossThreshold ([double]$effective['UdpLossThreshold']) -CurMbps $plan.CurMbps -MaxMbps $plan.MaxMbps -StepMbps $plan.StepMbps }
    }
    $final = [pscustomobject]@{
      Timestamp = $ts; Target = [string]$effective['Target']; Port = [int]$effective['Port']; Stack = $stack; Iperf3Version = $caps.VersionText; BidirSupported = $caps.BidirSupported
      MtuProbe = [pscustomobject]@{ Enabled = (-not [bool]$effective['DisableMtuProbe']); Sizes = @($effective['MtuSizes']); FailedSizes = @($mtuFails) }
      NetConnection = [pscustomobject]@{ TcpTestSucceeded = $net.Tcp.TcpTestSucceeded; RemoteAddress = $net.Tcp.RemoteAddress; PingSucceeded = $net.Tcp.PingSucceeded; TraceRoute = if ($net.Trace) { $net.Trace.TraceRoute } else { $null } }
      Results = $allResults.ToArray()
    }
    $stopwatch.Stop(); $completedUtc = (Get-Date).ToUniversalTime()
    $finalize = Write-FinalOutputs -CsvRowsList $csvRows -AllResultsList $allResults -CsvPath $csvPath -JsonPath $jsonPath -FinalResultObject $final -OutDir ([string]$effective['OutDir']) -Timestamp $ts -StartedUtc $startedUtc.ToString('o') -CompletedUtc $completedUtc.ToString('o') -ElapsedSeconds ([math]::Round($stopwatch.Elapsed.TotalSeconds, 1)) -Iperf3Version $caps.VersionText -ThresholdMinThroughputMbps $effective['ThresholdMinThroughputMbps'] -ThresholdMaxLossPct $effective['ThresholdMaxLossPct'] -ThresholdMaxJitterMs $effective['ThresholdMaxJitterMs']
    $final | Add-Member -MemberType NoteProperty -Name Supplemental -Value ([pscustomobject]@{ SummaryJsonPath = $finalize.SummaryJsonPath; ReportMdPath = $finalize.ReportMdPath; RunIndexPath = $finalize.RunIndexPath }) -Force
    if (-not $effective['Quiet']) {
      Write-Information -InformationAction Continue "CSV  : $csvPath"; Write-Information -InformationAction Continue "JSON : $jsonPath"
      Write-Information -InformationAction Continue "Summary JSON: $($finalize.SummaryJsonPath)"; Write-Information -InformationAction Continue "Report MD  : $($finalize.ReportMdPath)"; Write-Information -InformationAction Continue "Run index  : $($finalize.RunIndexPath)"
      Write-Information -InformationAction Continue "Completed $testNo tests; $($finalize.FailedCount) failed. Elapsed: $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s"
      if ($finalize.ParseErrorCount -gt 0) { Write-Information -InformationAction Continue "$($finalize.ParseErrorCount) test(s) with JSON parse errors." }
      if ($testNo -eq 0 -or $finalize.FailedCount -eq $testNo) { Write-Warning 'No tests completed successfully.' }
      if ($effective['Summary']) { Write-Information -InformationAction Continue "Tests: $testNo total" }
    }
    if ($effective['PassThru']) { return $finalize.RunSummary }
  }
  catch { throw (Get-Iperf3ClassifiedErrorRecord -ErrorRecord $_ -DefaultErrorId 'NetworkLantern.Throughput.Internal') }
  finally { $script:ActiveRetryCount = $null; $ErrorActionPreference = $oldEap }
}
