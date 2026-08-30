function Assert-NetworkTuningAdministrator {
  [CmdletBinding()]
  [OutputType([void])]
  param()

  if (-not (Test-NetworkTuningAdministrator)) {
    throw 'Please run as Administrator.'
  }
}

function Get-NetworkTuningGuidFromText {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Text
  )

  if ($Text -match '\{([0-9a-fA-F-]+)\}') {
    return $Matches[0]
  }

  if ($Text -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
    return '{' + $Matches[1] + '}'
  }

  return $null
}
