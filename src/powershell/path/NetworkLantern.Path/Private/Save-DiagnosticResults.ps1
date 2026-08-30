function Protect-DiagnosticCsvValue {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Value
  )

  if ([string]::IsNullOrEmpty($Value)) { return $Value }
  if ($Value[0] -in @('=', '+', '-', '@')) { return "'$Value" }
  return $Value
}

function Save-DiagnosticResults {
  <#
  .SYNOPSIS
    Persist diagnostic results to JSON and CSV files (UTF-8 no BOM).
  .PARAMETER Results
    Array of diagnostic result objects to serialize.
  .PARAMETER JsonPath
    Output path for the JSON file.
  .PARAMETER CsvPath
    Output path for the CSV summary file.
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
    [Parameter(Mandatory)][string]$JsonPath,
    [Parameter(Mandatory)][string]$CsvPath
  )

  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  $jsonContent = ConvertTo-Json -InputObject @($Results) -Depth 6
  [System.IO.File]::WriteAllText($JsonPath, $jsonContent, $utf8NoBom)

  $csvLines = $Results | Select-Object Timestamp, Round, Protocol, @{ Name = 'Host'; Expression = { Protect-DiagnosticCsvValue $_.Host } }, PingStatus, TracertStatus, PathpingStatus, Tcp443Status, PortsStatus, OverallStatus, PingOk, TracertOk, PathpingOk, Tcp443OK | ConvertTo-Csv -NoTypeInformation
  $csvContent = $csvLines -join [Environment]::NewLine
  [System.IO.File]::WriteAllText($CsvPath, $csvContent, $utf8NoBom)

  Write-Status -Level SUMMARY -Message "JSON: $JsonPath"
  Write-Status -Level SUMMARY -Message "CSV : $CsvPath"
}
