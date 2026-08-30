function Test-HostNameSafe {
  <#
  .SYNOPSIS
    Validate that a hostname is non-empty and free of shell-unsafe characters.
  .PARAMETER HostName
    The hostname or IP address to check.
  .OUTPUTS
    [bool] $true if safe, $false otherwise.
  #>
  param([string]$HostName)
  if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
  $trimmed = $HostName.Trim()
  if ($trimmed.StartsWith('-')) { return $false }
  if ($trimmed[0] -in @('=', '+', '@')) { return $false }
  if ($trimmed -match '\s') { return $false }
  if ($trimmed.Contains('/')) { return $false }
  if ($trimmed.Contains('|')) { return $false }
  if ($trimmed.Contains(';')) { return $false }
  if ($trimmed.Contains('&')) { return $false }
  if ($trimmed.Contains('`')) { return $false }
  if ($trimmed.Contains('$')) { return $false }
  if ($trimmed -match '[\x00-\x1F\x7F]') { return $false }
  return $true
}
