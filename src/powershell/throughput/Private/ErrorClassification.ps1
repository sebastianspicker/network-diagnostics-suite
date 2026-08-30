# Stable error identities for the public throughput contract. Callers map these
# identities to documented exit codes; user-facing messages remain independent.

function Get-Iperf3ErrorRecord {
  [CmdletBinding()]
  [OutputType([System.Management.Automation.ErrorRecord])]
  param(
    [Parameter(Mandatory)]
    [System.Exception]$Exception,
    [Parameter(Mandatory)]
    [ValidateSet(
      'NetworkLantern.Throughput.InputValidation',
      'NetworkLantern.Throughput.Prerequisite',
      'NetworkLantern.Throughput.Connectivity',
      'NetworkLantern.Throughput.Internal'
    )]
    [string]$ErrorId,
    [object]$TargetObject
  )

  $category = switch ($ErrorId) {
    'NetworkLantern.Throughput.InputValidation' { [System.Management.Automation.ErrorCategory]::InvalidArgument }
    'NetworkLantern.Throughput.Prerequisite' { [System.Management.Automation.ErrorCategory]::ResourceUnavailable }
    'NetworkLantern.Throughput.Connectivity' { [System.Management.Automation.ErrorCategory]::ConnectionError }
    default { [System.Management.Automation.ErrorCategory]::NotSpecified }
  }
  return [System.Management.Automation.ErrorRecord]::new($Exception, $ErrorId, $category, $TargetObject)
}

function Write-Iperf3Error {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Message,
    [Parameter(Mandatory)]
    [ValidateSet(
      'NetworkLantern.Throughput.InputValidation',
      'NetworkLantern.Throughput.Prerequisite',
      'NetworkLantern.Throughput.Connectivity',
      'NetworkLantern.Throughput.Internal'
    )]
    [string]$ErrorId,
    [object]$TargetObject
  )

  throw (Get-Iperf3ErrorRecord -Exception ([System.Exception]::new($Message)) -ErrorId $ErrorId -TargetObject $TargetObject)
}

function Get-Iperf3ClassifiedErrorRecord {
  [CmdletBinding()]
  [OutputType([System.Management.Automation.ErrorRecord])]
  param(
    [Parameter(Mandatory)]
    [System.Management.Automation.ErrorRecord]$ErrorRecord,
    [ValidateSet(
      'NetworkLantern.Throughput.InputValidation',
      'NetworkLantern.Throughput.Prerequisite',
      'NetworkLantern.Throughput.Connectivity',
      'NetworkLantern.Throughput.Internal'
    )]
    [string]$DefaultErrorId = 'NetworkLantern.Throughput.Internal'
  )

  $existingId = ([string]$ErrorRecord.FullyQualifiedErrorId -split ',')[0]
  if ($existingId -like 'NetworkLantern.Throughput.*') { return $ErrorRecord }
  $exception = [System.Exception]::new($ErrorRecord.Exception.Message, $ErrorRecord.Exception)
  return (Get-Iperf3ErrorRecord -Exception $exception -ErrorId $DefaultErrorId -TargetObject $ErrorRecord.TargetObject)
}
