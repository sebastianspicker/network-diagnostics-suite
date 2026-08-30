function Get-RoundDefinitions {
  <#
  .SYNOPSIS
    Return the built-in test round definitions (Standard, MTU1400_DF, TTL64_Timeout5s).
  .OUTPUTS
    [hashtable[]] Each entry has Name, PingArgs4, PingArgs6, TracertArgs, PathpingArgs scriptblocks.
  #>
  param(
    [Parameter(Mandatory)][int]$TraceMaxHops,
    [Parameter(Mandatory)][int]$TraceTimeoutMs,
    [Parameter(Mandatory)][int]$PathpingProbes,
    [Parameter(Mandatory)][int]$PathpingTimeoutMs
  )

  # Keep explicit references so static analysis recognizes these values as intentionally
  # captured by the round-definition scriptblocks below.
  $null = $TraceMaxHops, $TraceTimeoutMs, $PathpingProbes, $PathpingTimeoutMs

  return @(
    @{
      Name = 'Standard'
      PingArgs4 = { param($h, $n) @('-4', '-n', "$n", $h) }
      PingArgs6 = { param($h, $n) @('-6', '-n', "$n", $h) }
      TracertArgs = { param($ipVer, $h) @($ipVer, '-d', '-h', "$TraceMaxHops", '-w', "$TraceTimeoutMs", $h) }
      PathpingArgs = { param($ipVer, $h) @($ipVer, '/q', "$PathpingProbes", '/w', "$PathpingTimeoutMs", $h) }
    }
    @{
      Name = 'MTU1400_DF'
      PingArgs4 = { param($h, $n) @('-4', '-f', '-l', '1400', '-n', "$n", $h) }
      PingArgs6 = { param($h, $n) @('-6', '-l', '1400', '-n', "$n", $h) }
      TracertArgs = { param($ipVer, $h) @($ipVer, '-d', '-h', "$TraceMaxHops", '-w', "$TraceTimeoutMs", $h) }
      PathpingArgs = { param($ipVer, $h) @($ipVer, '/q', "$PathpingProbes", '/w', "$PathpingTimeoutMs", $h) }
    }
    @{
      Name = 'TTL64_Timeout5s'
      PingArgs4 = { param($h, $n) @('-4', '-i', '64', '-w', '5000', '-n', "$n", $h) }
      PingArgs6 = { param($h, $n) @('-6', '-i', '64', '-w', '5000', '-n', "$n", $h) }
      TracertArgs = { param($ipVer, $h) @($ipVer, '-d', '-h', '64', '-w', '5000', $h) }
      PathpingArgs = { param($ipVer, $h) @($ipVer, '/q', "$PathpingProbes", '/w', '5000', $h) }
    }
  )
}
