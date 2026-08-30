function Test-TcpPort {
  <#
  .SYNOPSIS
    Test TCP connectivity to a host:port with DNS resolution.
  .PARAMETER HostName
    Target host.
  .PARAMETER Port
    TCP port number.
  .PARAMETER Protocol
    IPv4 or IPv6 (default IPv4).
  .PARAMETER DnsTimeoutMs
    DNS resolution timeout in milliseconds (default 5000).
  .OUTPUTS
    [pscustomobject] Test-NetConnection result, or a stub with TcpTestSucceeded=$false on DNS failure.
  #>
  param(
    [Parameter(Mandatory)][string]$HostName,
    [Parameter(Mandatory)][int]$Port,
    [ValidateSet('IPv4', 'IPv6')]
    [string]$Protocol = 'IPv4',
    [int]$DnsTimeoutMs = 5000
  )

  $family = if ($Protocol -eq 'IPv6') { [System.Net.Sockets.AddressFamily]::InterNetworkV6 } else { [System.Net.Sockets.AddressFamily]::InterNetwork }
  $addrs, $dnsError = Get-HostAddressesWithTimeout -HostName $HostName -TimeoutMs $DnsTimeoutMs
  if ($dnsError) {
    return [pscustomobject]@{ TcpTestSucceeded = $false; TraceRoute = $null; DnsError = $dnsError }
  }

  $addr = $addrs | Where-Object { $_.AddressFamily -eq $family } | Select-Object -First 1
  if (-not $addr) {
    return [pscustomobject]@{ TcpTestSucceeded = $false; TraceRoute = $null; DnsError = "No $Protocol address for $HostName" }
  }

  $target = $addr.ToString()
  $tncParams = @{
    ComputerName     = $target
    Port             = $Port
    InformationLevel = 'Detailed'
  }
  return (Test-NetConnection @tncParams)
}
