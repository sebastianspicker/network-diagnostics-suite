# Desktop-shell integration belongs to the throughput application, not the
# reusable module. Keep the process launch isolated for GUI/CLI adapters.
function Invoke-ThroughputPathOpenerProcess {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Command,
    [Parameter(Mandatory)]
    [string]$Path
  )

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Command
  $startInfo.UseShellExecute = $false
  $startInfo.ArgumentList.Add($Path)
  [System.Diagnostics.Process]::Start($startInfo) | Out-Null
}

function Open-ThroughputFolderOrFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  $openerPath = [System.IO.Path]::GetFullPath($Path)
  $openerCommand = if ($IsWindows) { 'explorer.exe' } elseif ($IsMacOS) { 'open' } else {
    $xdgOpen = Get-Command 'xdg-open' -ErrorAction SilentlyContinue
    if ($xdgOpen) { $xdgOpen.Source } else { $null }
  }
  if (-not $openerCommand) {
    Write-Warning "No file opener found. Path: $openerPath"
    return
  }
  Invoke-ThroughputPathOpenerProcess -Command $openerCommand -Path $openerPath
}
