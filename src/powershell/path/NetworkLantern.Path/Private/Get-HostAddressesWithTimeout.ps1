function Get-HostAddressesWithTimeout {
  <#
  .SYNOPSIS
    Resolve a hostname to IP addresses with a configurable timeout.
  .PARAMETER HostName
    The hostname to resolve.
  .PARAMETER TimeoutMs
    Maximum milliseconds to wait for DNS resolution (default 5000).
  .OUTPUTS
    Two-element array: ([IPAddress[]] addresses, [string] error).
    On success error is $null; on failure addresses is $null.
  #>
  param(
    [Parameter(Mandatory)][string]$HostName,
    [int]$TimeoutMs = 5000
  )

  $task = $null
  try {
    $task = [System.Net.Dns]::GetHostAddressesAsync($HostName)
    if (-not $task.Wait($TimeoutMs)) {
      return $null, "DNS resolution timed out after ${TimeoutMs}ms"
    }
    return $task.Result, $null
  } catch {
    return $null, "DNS resolution failed: $($_.Exception.Message)"
  } finally {
    if ($task -is [System.IDisposable] -and $task.IsCompleted) { $task.Dispose() }
  }
}
