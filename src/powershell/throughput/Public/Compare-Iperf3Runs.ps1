function Compare-Iperf3Runs {
  <#
  .SYNOPSIS
  Compares two iperf3 run summary JSON files and outputs a delta object.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [string]$BaselinePath,
    [Parameter(Mandatory)]
    [string]$CurrentPath
  )
  try { $baseline = Read-Iperf3BoundedTextFile -Path $BaselinePath -MaxBytes $script:Iperf3SummaryFileMaxBytes -ArtifactDescription 'Baseline summary file' | ConvertFrom-Json }
  catch {
    if ($_.Exception -is [System.IO.FileNotFoundException] -or $_.Exception -is [System.IO.DirectoryNotFoundException] -or
        $_.Exception.InnerException -is [System.IO.FileNotFoundException] -or $_.Exception.InnerException -is [System.IO.DirectoryNotFoundException]) {
      throw "Baseline summary file not found: $BaselinePath"
    }
    throw
  }
  try { $current = Read-Iperf3BoundedTextFile -Path $CurrentPath -MaxBytes $script:Iperf3SummaryFileMaxBytes -ArtifactDescription 'Current summary file' | ConvertFrom-Json }
  catch {
    if ($_.Exception -is [System.IO.FileNotFoundException] -or $_.Exception -is [System.IO.DirectoryNotFoundException] -or
        $_.Exception.InnerException -is [System.IO.FileNotFoundException] -or $_.Exception.InnerException -is [System.IO.DirectoryNotFoundException]) {
      throw "Current summary file not found: $CurrentPath"
    }
    throw
  }

  $requiredProps = @('Status', 'Counts', 'Timestamp')
  foreach ($prop in $requiredProps) {
    if ($baseline.PSObject.Properties.Name -notcontains $prop) {
      throw "Baseline summary file is missing required property '$prop': $BaselinePath"
    }
    if ($current.PSObject.Properties.Name -notcontains $prop) {
      throw "Current summary file is missing required property '$prop': $CurrentPath"
    }
  }

  return [pscustomobject]@{
    BaselineTimestamp = $baseline.Timestamp
    CurrentTimestamp  = $current.Timestamp
    BaselineStatus    = $baseline.Status
    CurrentStatus     = $current.Status
    StatusChanged     = $baseline.Status -ne $current.Status
    BaselineCounts    = $baseline.Counts
    CurrentCounts     = $current.Counts
    FailedDelta       = ([int]$current.Counts.Failed) - ([int]$baseline.Counts.Failed)
    TotalDelta        = ([int]$current.Counts.Total) - ([int]$baseline.Counts.Total)
    BaselineElapsed   = $baseline.ElapsedSeconds
    CurrentElapsed    = $current.ElapsedSeconds
  }
}
