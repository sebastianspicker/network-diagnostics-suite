function Test-PathSafe {
  <#
  .SYNOPSIS
    Validate that a file path is non-empty and free of dangerous patterns.
  .PARAMETER Path
    The path string to check (rejects control chars, pipe, leading dash, path traversal).
  .OUTPUTS
    [bool] $true if safe, $false otherwise.
  #>
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $trimmed = $Path.Trim()
  if ($trimmed.StartsWith('-')) { return $false }
  if ($trimmed.Contains('|')) { return $false }
  if ($trimmed -match '[\x00-\x1F\x7F]') { return $false }
  if ($trimmed -match '[\\/]\.\.([\\/]|$)' -or $trimmed -match '^\.\.([\\/]|$)') { return $false }
  return $true
}
