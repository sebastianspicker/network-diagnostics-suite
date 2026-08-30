function Write-NetworkTuningInformation {
  [CmdletBinding()]
  [OutputType([void])]
  param(
    [Parameter(Mandatory)]
    [string]$Message
  )

  Write-Information -MessageData $Message -InformationAction Continue
}
