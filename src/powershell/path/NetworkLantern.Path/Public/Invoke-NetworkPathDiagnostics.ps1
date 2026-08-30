function Invoke-NetworkPathDiagnostics {
  <#
  .SYNOPSIS
    Run or preview the Network Lantern path diagnostics matrix.
  .DESCRIPTION
    Resolves hosts from CLI values, config/hosts.conf, or built-in defaults;
    plans selected rounds and protocols; and either previews or persists the
    diagnostic results. The final output item is a NetworkLantern.Path.RunResult
    object for adapters that need a process exit status.
  #>
  [CmdletBinding()]
  [OutputType('NetworkLantern.Path.RunResult')]
  param(
    [string[]]$HostsIPv4,
    [string[]]$HostsIPv6,
    [string]$LogDirectory = '',
    [int]$PingCount = 5,
    [int]$TraceMaxHops = 30,
    [int]$TraceTimeoutMs = 5000,
    [int]$PathpingProbes = 50,
    [int]$PathpingTimeoutMs = 3000,
    [ValidateSet('IPv4', 'IPv6')]
    [string[]]$Protocols = @('IPv4', 'IPv6'),
    [string[]]$Rounds = @('Standard'),
    [switch]$SkipPathping,
    [switch]$DryRun,
    [switch]$Quiet,
    [switch]$Version,
    [switch]$ListRounds,
    [switch]$ListProtocols
  )

  $script:PathQuiet = [bool]$Quiet
  $runResult = {
    param([int]$ExitCode)
    [pscustomobject]@{
      PSTypeName = 'NetworkLantern.Path.RunResult'
      ExitCode   = $ExitCode
    }
  }

  if ($Version) {
    Write-Output "Test-NetworkPath.ps1 v$script:PathModuleVersion"
    return (& $runResult 0)
  }

  if ($ListRounds) {
    @(Get-RoundDefinitions -TraceMaxHops $TraceMaxHops -TraceTimeoutMs $TraceTimeoutMs -PathpingProbes $PathpingProbes -PathpingTimeoutMs $PathpingTimeoutMs) |
      ForEach-Object { $_.Name }
    return (& $runResult 0)
  }

  if ($ListProtocols) {
    Write-Output 'IPv4'
    Write-Output 'IPv6'
    return (& $runResult 0)
  }

  $isWindowsRuntime = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
  if (-not $isWindowsRuntime -and -not $DryRun) {
    throw 'Full Network Lantern path diagnostics require Windows built-in tools (ping/tracert/pathping/Test-NetConnection). Use -DryRun on non-Windows hosts.'
  }

  $defaultHostsConfig = Join-Path $script:RepositoryRoot 'config/hosts.conf'
  if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $LogDirectory = Get-DefaultLogDirectory
  }
  if (-not (Test-PathSafe $LogDirectory)) {
    throw "LogDirectory must not be empty, start with '-', contain '|', control chars, or path traversal (..): $LogDirectory"
  }

  $defaultHosts4 = @('netcologne.de', 'google.com', 'wikipedia.org', 'amazon.de')
  $defaultHosts6 = @('netcologne.de', 'google.com', 'wikipedia.org')
  $configHosts = Get-HostsFromConfig -Path $defaultHostsConfig
  if (-not $PSBoundParameters.ContainsKey('HostsIPv4')) {
    $HostsIPv4 = if (@($configHosts.IPv4).Count -gt 0) { @($configHosts.IPv4) } else { @($defaultHosts4) }
  }
  if (-not $PSBoundParameters.ContainsKey('HostsIPv6')) {
    $HostsIPv6 = if (@($configHosts.IPv6).Count -gt 0) { @($configHosts.IPv6) } else { @($defaultHosts6) }
  }

  $badHosts = @(@($HostsIPv4) + @($HostsIPv6) | Where-Object { -not (Test-HostNameSafe $_) })
  if (@($badHosts).Count -gt 0) {
    throw "Host names must not start with '-', contain whitespace, '/', '|', or control characters: $($badHosts -join ', ')"
  }

  $roundDefinitions = @(Get-RoundDefinitions -TraceMaxHops $TraceMaxHops -TraceTimeoutMs $TraceTimeoutMs -PathpingProbes $PathpingProbes -PathpingTimeoutMs $PathpingTimeoutMs)
  $requestedRounds = if ($null -ne $Rounds) { @($Rounds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } else { @() }
  if (@($requestedRounds).Count -gt 0) {
    $selectedRoundDefs = @($roundDefinitions | Where-Object { $_.Name -in $requestedRounds })
    $missingRounds = @($requestedRounds | Where-Object { $_ -notin @($roundDefinitions.Name) })
    if (@($missingRounds).Count -gt 0) {
      throw "Unknown rounds: $($missingRounds -join ', '). Allowed: $($roundDefinitions.Name -join ', ')"
    }
    $roundDefinitions = $selectedRoundDefs
  }

  $selectedProtocols = @($Protocols | Select-Object -Unique)
  $plan = Get-DiagnosticPlan -RoundDefinitions $roundDefinitions -SelectedProtocols $selectedProtocols -ResolvedHostsIPv4 @($HostsIPv4) -ResolvedHostsIPv6 @($HostsIPv6)
  if ($plan.Count -eq 0) {
    throw 'No diagnostic runs planned. Check selected rounds/protocols/hosts.'
  }

  $timestamp = "$(Get-Date -Format 'yyyyMMdd_HHmmss')_$PID"
  $jsonPath = Join-Path $LogDirectory "net_results_$timestamp.json"
  $csvPath = Join-Path $LogDirectory "net_summary_$timestamp.csv"
  Write-Status -Level INFO -Message "Planned runs: $($plan.Count)"
  Write-Status -Level INFO -Message "Protocols: $($selectedProtocols -join ', ')"
  Write-Status -Level INFO -Message "Rounds: $($roundDefinitions.Name -join ', ')"
  Write-Status -Level INFO -Message "IPv4 hosts: $(@($HostsIPv4) -join ', ')"
  Write-Status -Level INFO -Message "IPv6 hosts: $(@($HostsIPv6) -join ', ')"

  if ($DryRun) {
    Write-Status -Level SUMMARY -Message "Dry-run only. Planned runs: $($plan.Count)"
    Write-Status -Level SUMMARY -Message "Would write JSON: $jsonPath"
    Write-Status -Level SUMMARY -Message "Would write CSV : $csvPath"
    if (-not $Quiet) {
      $index = 0
      foreach ($item in $plan) {
        $index++
        Write-Status -Level PLAN -Message "[$index/$($plan.Count)] round=$($item.RoundName) protocol=$($item.Protocol) host=$($item.Host)"
      }
    }
    return (& $runResult 0)
  }

  New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
  $results = New-Object System.Collections.Generic.List[object]
  $completedNormally = $false
  $start = Get-Date
  $executionSettings = [pscustomobject]@{
    PingCount    = $PingCount
    SkipPathping = [bool]$SkipPathping
  }
  Write-Status -Level INFO -Message 'Starting diagnostics'
  try {
    Invoke-DiagnosticsMatrix -Plan $plan -Results $results -Settings $executionSettings
    Save-DiagnosticResults -Results @($results) -JsonPath $jsonPath -CsvPath $csvPath
    $completedNormally = $true
    $elapsed = [int]((Get-Date) - $start).TotalSeconds
    $failedCount = @($results | Where-Object { $_.OverallStatus -eq 'Fail' }).Count
    $okCount = $results.Count - $failedCount
    Write-Status -Level SUMMARY -Message "Diagnostics complete. Passed: $okCount Failed: $failedCount Elapsed: ${elapsed}s"
  }
  finally {
    if ((-not $completedNormally) -and ($results.Count -gt 0)) {
      Write-Status -Level WARN -Message 'Interrupted or error: saving partial results.'
      try {
        Save-DiagnosticResults -Results @($results) -JsonPath $jsonPath -CsvPath $csvPath
      }
      catch {
        Write-Status -Level ERROR -Message "Failed to save partial results: $($_.Exception.Message)"
      }
    }
  }

  $anyFailure = $results | Where-Object { $_.OverallStatus -eq 'Fail' } | Select-Object -First 1
  return (& $runResult $(if ($anyFailure) { 1 } else { 0 }))
}
