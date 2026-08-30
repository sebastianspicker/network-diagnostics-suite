function Get-HostsFromConfig {
  <#
  .SYNOPSIS
    Parse a hosts.conf file and return IPv4/IPv6 host lists.
  .PARAMETER Path
    Absolute path to the hosts.conf file (key=value, keys: ipv4, ipv6).
  .OUTPUTS
    [hashtable] With keys IPv4 and IPv6, each containing a string array.
  #>
  param([Parameter(Mandatory)][string]$Path)

  $result = @{
    IPv4 = @()
    IPv6 = @()
  }

  if (-not (Test-Path -LiteralPath $Path)) {
    return $result
  }

  Get-Content -LiteralPath $Path | ForEach-Object {
    $line = $_.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    if ($line.StartsWith('#')) { return }
    if ($line -notmatch '=') { return }

    $parts = $line.Split('=', 2)
    $key = $parts[0].Trim().ToLowerInvariant()
    $value = $parts[1].Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return }

    switch ($key) {
      'ipv4' { $result.IPv4 += $value }
      'ipv6' { $result.IPv6 += $value }
    }
  }

  return $result
}
