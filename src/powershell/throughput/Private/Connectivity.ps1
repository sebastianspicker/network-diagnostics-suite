# Reachability, TCP port, MTU probe, and test-suite connectivity (private to NetworkLantern.Throughput)

function Test-Reachability {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$ComputerName,
    [Parameter(Mandatory)]
    [ValidateSet('Auto', 'IPv4', 'IPv6')]
    [string]$Mode
  )
  if (-not $IsWindows) {
    throw "Test-Reachability is currently only supported on Windows due to dependency on ping.exe or Test-Connection behaviors."
  }
  $stacksToTry = switch ($Mode) {
    'IPv4' { @('IPv4') }
    'IPv6' { @('IPv6') }
    default { @('IPv4', 'IPv6') }
  }
  if (-not (Test-ValidHostnameOrIP -Name $ComputerName)) {
    throw "Invalid ComputerName: '$ComputerName'. Must be a valid hostname or IP address."
  }
  foreach ($stack in $stacksToTry) {
    try {
      if ($stack -eq 'IPv4' -and (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -IPv4 -ErrorAction Stop)) { return 'IPv4' }
      if ($stack -eq 'IPv6' -and (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -IPv6 -ErrorAction Stop)) { return 'IPv6' }
    }
    catch {
      try {
        $pingArgs = Get-PingArgumentsForStack -Stack $stack -ComputerName $ComputerName
        $null = & ping.exe @pingArgs 2>$null
        if ($LASTEXITCODE -eq 0) { return $stack }
      }
      catch { Write-Verbose "ping.exe failed for $stack; continuing to next stack." }
    }
  }
  return 'None'
}

function Test-Iperf3TcpConnection {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [string]$ComputerName,
    [Parameter(Mandatory)]
    [ValidateRange(1, 65535)]
    [int]$Port,
    [ValidateRange(1, 300000)]
    [int]$TimeoutMs = 10000,
    [scriptblock]$ConnectAsync
  )
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $task = if ($ConnectAsync) {
      & $ConnectAsync $client $ComputerName $Port
    }
    else {
      $client.ConnectAsync($ComputerName, $Port)
    }
    $connected = [bool]$task.Wait($TimeoutMs)
    if ($task.IsFaulted) { $null = $task.Exception }
    $remoteAddress = $ComputerName
    $remoteAddressFamily = $null
    if ($connected -and $client.Connected -and $client.Client.RemoteEndPoint -is [System.Net.IPEndPoint]) {
      $remoteAddress = [string]$client.Client.RemoteEndPoint.Address
      $remoteAddressFamily = [string]$client.Client.RemoteEndPoint.AddressFamily
    }
    return [pscustomobject]@{
      TcpTestSucceeded  = ($connected -and $client.Connected)
      RemoteAddress     = $remoteAddress
      RemoteAddressFamily = $remoteAddressFamily
      PingSucceeded     = $null
    }
  }
  catch {
    Write-Warning "TCP port $Port check on '$ComputerName' failed: $($_.Exception.Message)"
    return [pscustomobject]@{
      TcpTestSucceeded = $false
      RemoteAddress = $ComputerName
      RemoteAddressFamily = $null
      PingSucceeded = $null
    }
  }
  finally {
    if ($client) { $client.Dispose() }
  }
}

function Invoke-Iperf3TraceRoute {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [string]$ComputerName,
    [ValidateRange(1, 30)]
    [int]$Hops = $script:DefaultTraceHops,
    [ValidateRange(1, 300000)]
    [int]$TimeoutMs = 10000,
    [scriptblock]$TraceScript
  )
  try {
    $payload = [ordered]@{
      ComputerName = $ComputerName
      Hops         = $Hops
      TraceScript  = if ($TraceScript) { $TraceScript.ToString() } else { $null }
    }
    $payloadJson = $payload | ConvertTo-Json -Compress
    $payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadJson))
    $workerScript = @"
`$ErrorActionPreference = 'Stop'
`$payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payloadBase64'))
`$payload = `$payloadJson | ConvertFrom-Json
if (`$payload.TraceScript) {
  `$traceBlock = [scriptblock]::Create([string]`$payload.TraceScript)
  `$traceResult = & `$traceBlock ([string]`$payload.ComputerName) ([int]`$payload.Hops)
}
else {
  `$rawTrace = Test-NetConnection -ComputerName ([string]`$payload.ComputerName) -TraceRoute -Hops ([int]`$payload.Hops) -InformationLevel Detailed -ErrorAction Stop
  `$traceResult = [pscustomobject]@{
    ComputerName  = [string]`$rawTrace.ComputerName
    RemoteAddress = [string]`$rawTrace.RemoteAddress
    TraceRoute    = @(`$rawTrace.TraceRoute | ForEach-Object { [string]`$_ })
  }
}
`$traceResult | ConvertTo-Json -Depth 8 -Compress
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerScript))
    $pwshPath = (Get-Process -Id $PID).Path
    # After worker startup, the hard wall bound is execution timeout plus the
    # finite tree-termination and redirected-stream drain budgets below. The
    # child process is a killable root boundary; detached/reparented descendants
    # remain explicitly unverified.
    $native = Invoke-Iperf3NativeProcess -FilePath $pwshPath `
      -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand) `
      -TimeoutMs $TimeoutMs -TerminationGracePeriodMs 500 -StreamDrainTimeoutMs 250
    if ($native.Cancelled) {
      throw (New-Iperf3CancellationException -NativeProcess $native -RunId $native.CancellationRunId)
    }
    if ($native.TimedOut) {
      $cleanupDetail = if ($native.TerminationSucceeded -and $native.StreamsCompleted) {
        'tracked child cleanup verified'
      }
      else {
        "child cleanup unverified: $($native.TerminationError) $($native.StreamReadError)"
      }
      Write-Verbose "Traceroute exceeded its ${TimeoutMs}ms execution deadline ($cleanupDetail); TCP result remains valid."
      return $null
    }
    if ($native.ExitCode -ne 0 -or -not $native.StreamsCompleted) {
      Write-Verbose "Traceroute worker failed; TCP result remains valid: exit=$($native.ExitCode) $($native.StdErr) $($native.StreamReadError)"
      return $null
    }
    $traceJson = Get-JsonSubstringOrNull -Text $native.StdOut
    if (-not $traceJson) { throw 'Traceroute worker did not return JSON.' }
    return ($traceJson | ConvertFrom-Json -ErrorAction Stop)
  }
  catch {
    if ($_.Exception.Data -and $_.Exception.Data['NetworkLantern.CleanupRecordVersion'] -eq 1) { throw }
    Write-Verbose "Traceroute failed (e.g. ICMP filtered); TCP result still valid: $($_.Exception.Message)"
    return $null
  }
}

function Test-TcpPortAndTrace {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [string]$ComputerName,
    [Parameter(Mandatory)]
    [ValidateRange(1, 65535)]
    [int]$Port,
    [ValidateRange(1, 30)]
    [int]$Hops = $script:DefaultTraceHops,
    [ValidateRange(1000, 300000)]
    [int]$TimeoutMs = 10000,
    [ValidateRange(1, 300000)]
    [int]$TraceTimeoutMs = 10000
  )
  $tcp = Test-Iperf3TcpConnection -ComputerName $ComputerName -Port $Port -TimeoutMs $TimeoutMs
  $trace = $null
  if ($IsWindows -and $tcp.TcpTestSucceeded) {
    $trace = Invoke-Iperf3TraceRoute -ComputerName $ComputerName -Hops $Hops -TimeoutMs $TraceTimeoutMs
  }
  elseif (-not $IsWindows) {
    Write-Verbose "Traceroute not available on non-Windows platforms."
  }
  [pscustomobject]@{ Tcp = $tcp; Trace = $trace }
}

function Get-Iperf3StackFromTcpResult {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [object]$Tcp
  )

  if ($Tcp.PSObject.Properties.Name -contains 'RemoteAddressFamily') {
    switch ([string]$Tcp.RemoteAddressFamily) {
      'InterNetworkV6' { return 'IPv6' }
      'InterNetwork' { return 'IPv4' }
    }
  }

  $remoteAddress = if ($Tcp.PSObject.Properties.Name -contains 'RemoteAddress') { [string]$Tcp.RemoteAddress } else { '' }
  if ($remoteAddress -match ':') {
    return 'IPv6'
  }
  return 'IPv4'
}

function Test-MtuPayload {
  [CmdletBinding()]
  [OutputType([int[]])]
  param(
    [Parameter(Mandatory)]
    [string]$ComputerName,
    [Parameter(Mandatory)]
    [ValidateSet('IPv4', 'IPv6')]
    [string]$Stack,
    [Parameter(Mandatory)]
    [int[]]$Sizes
  )
  if (-not $IsWindows) {
    throw "Test-MtuPayload is currently only supported on Windows due to dependency on ping.exe."
  }
  if (-not (Test-ValidHostnameOrIP -Name $ComputerName)) {
    throw "Invalid ComputerName: '$ComputerName'. Must be a valid hostname or IP address."
  }
  $fails = New-Object System.Collections.Generic.List[int]
  foreach ($sz in $Sizes) {
    $pingArgs = Get-PingArgumentsForStack -Stack $Stack -ComputerName $ComputerName -MtuPayloadSize $sz
    $null = & ping.exe @pingArgs 2>$null
    if ($LASTEXITCODE -ne 0) { [void]$fails.Add($sz) }
  }
  return $fails.ToArray()
}

function Test-NetworkThroughputPrerequisites {
  [CmdletBinding()]
  [OutputType([void])]
  param(
    [switch]$SkipReachabilityCheck,
    [switch]$DisableMtuProbe
  )
  $null = Get-Command iperf3 -ErrorAction Stop
  $null = Get-Command ConvertFrom-Json -ErrorAction Stop
  if ((-not ($SkipReachabilityCheck -and $DisableMtuProbe)) -and $IsWindows) {
    $pingCmd = Get-Command ping.exe -ErrorAction SilentlyContinue
    if (-not $pingCmd) {
      throw "ping.exe is required for reachability check or MTU probe but was not found. Use -SkipReachabilityCheck and -DisableMtuProbe to run without it (Windows only)."
    }
  }
  if (-not $IsWindows -and -not ($SkipReachabilityCheck -and $DisableMtuProbe)) {
    throw "Reachability check and MTU probe require Windows (ping.exe, Test-NetConnection). Use -SkipReachabilityCheck -DisableMtuProbe to run on Linux/macOS."
  }
}

function Get-TestSuiteConnectivity {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [string]$Target,
    [Parameter(Mandatory)]
    [int]$Port,
    [Parameter(Mandatory)]
    [string]$IpVersion,
    [switch]$SkipReachabilityCheck,
    [switch]$DisableMtuProbe,
    [Parameter(Mandatory)]
    [int[]]$MtuSizes,
    [int]$ConnectTimeoutMs = 10000
  )
  $stack = 'None'
  if ($SkipReachabilityCheck) {
    Write-Verbose "Reachability check skipped (-SkipReachabilityCheck); proceeding with TCP port check only."
  }
  else {
    $stack = Test-Reachability -ComputerName $Target -Mode $IpVersion
    if ($stack -eq 'None') {
      throw "ICMP reachability to '$Target' failed; aborting. Use -SkipReachabilityCheck to proceed when only TCP is reachable."
    }
  }
  $net = Test-TcpPortAndTrace -ComputerName $Target -Port $Port -Hops $script:DefaultTraceHops -TimeoutMs $ConnectTimeoutMs
  if (-not $net -or -not $net.Tcp -or -not $net.Tcp.TcpTestSucceeded) {
    throw "TCP port $Port on '$Target' not reachable. Verify the iperf3 server is running (iperf3 -s -p $Port) and the port is not blocked by a firewall."
  }
  if ($stack -eq 'None') {
    $stack = Get-Iperf3StackFromTcpResult -Tcp $net.Tcp
    Write-Verbose "Using stack $stack from TCP connection."
  }
  $mtuFails = @()
  if (-not $DisableMtuProbe) {
    $mtuFails = Test-MtuPayload -ComputerName $Target -Stack $stack -Sizes $MtuSizes
  }
  return [pscustomobject]@{ Stack = $stack; Net = $net; MtuFails = $mtuFails }
}
