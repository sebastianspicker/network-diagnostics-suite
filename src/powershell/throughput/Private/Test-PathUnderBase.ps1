function Test-PathUnderBase {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$BasePath,
    [Parameter(Mandatory)]
    [string]$CandidatePath
  )
  $baseFull = [System.IO.Path]::GetFullPath($BasePath)
  $candidateFull = [System.IO.Path]::GetFullPath($CandidatePath)
  $separators = @([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $baseWithSeparator = $baseFull.TrimEnd($separators) + [System.IO.Path]::DirectorySeparatorChar
  $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  return $candidateFull.Equals($baseFull, $comparison) -or $candidateFull.StartsWith($baseWithSeparator, $comparison)
}

function Assert-RelativePathHasNoReparsePoint {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$BasePath,
    [Parameter(Mandatory)]
    [string]$CandidatePath,
    [Parameter(Mandatory)]
    [string]$PathDescription
  )

  $baseFull = [System.IO.Path]::GetFullPath($BasePath)
  $candidateFull = [System.IO.Path]::GetFullPath($CandidatePath)
  if (-not (Test-PathUnderBase -BasePath $baseFull -CandidatePath $candidateFull)) {
    Write-Iperf3Error -Message "$PathDescription must be under the current directory. Resolved: $candidateFull" -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $candidateFull
  }

  # GetFullPath does not dereference symlinks. Validate every existing path
  # component below the requested base so a relative destination cannot leave
  # that base through a symlink or Windows reparse point. A missing component
  # means all later components are necessarily absent and can be created.
  $relativePath = [System.IO.Path]::GetRelativePath($baseFull, $candidateFull)
  $currentPath = $baseFull
  foreach ($component in @($relativePath -split '[\\/]' | Where-Object { $_ -and $_ -ne '.' })) {
    $currentPath = Join-Path -Path $currentPath -ChildPath $component
    try {
      $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
      break
    }
    catch {
      Write-Iperf3Error -Message "$PathDescription could not validate path component '$currentPath': $($_.Exception.Message)" -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $currentPath
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      Write-Iperf3Error -Message "$PathDescription must not traverse a symbolic link or reparse point: $currentPath" -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $currentPath
    }
  }
  return $candidateFull
}
