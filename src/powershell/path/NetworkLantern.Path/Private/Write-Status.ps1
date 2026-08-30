function Write-Status {
  <#
  .SYNOPSIS
    Emit a timestamped, level-tagged status line to the console.
  .PARAMETER Level
    Severity tag (INFO, PLAN, OK, WARN, FAIL, ERROR, SUMMARY).
  .PARAMETER Message
    The message text to display.
  #>
  param(
    [Parameter(Mandatory)][ValidateSet('INFO', 'PLAN', 'OK', 'WARN', 'FAIL', 'ERROR', 'SUMMARY')][string]$Level,
    [Parameter(Mandatory)][string]$Message
  )

  if ($script:PathQuiet -and $Level -notin @('WARN', 'FAIL', 'ERROR', 'SUMMARY')) {
    return
  }

  $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-Output "[$timestamp] [$Level] $Message"
}
