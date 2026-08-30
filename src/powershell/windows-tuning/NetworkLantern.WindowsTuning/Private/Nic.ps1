function Get-NetworkTuningPhysicalUpAdapter {
  [CmdletBinding()]
  [OutputType([Microsoft.PowerShell.Cmdletization.GeneratedTypes.NetAdapter.NetAdapter[]])]
  param()

  Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
}

function Set-NetworkTuningNicAdvancedPropertyIfSupported {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$DisplayName,

    [Parameter(Mandatory)]
    [string]$Value,

    [Parameter()]
    [switch]$DryRun
  )

  # Prefer standardized RegistryKeywords over localized DisplayNames
  $keyword = if ($script:NetworkTuningNicKeywordMap.ContainsKey($DisplayName)) { $script:NetworkTuningNicKeywordMap[$DisplayName] } else { $null }

  $property = if ($keyword) {
    Get-NetAdapterAdvancedProperty -Name $Name -RegistryKeyword $keyword -ErrorAction SilentlyContinue
  } else {
    Get-NetAdapterAdvancedProperty -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $DisplayName }
  }

  if (-not $property) {
    Write-Verbose -Message ("{0}: property '{1}' (keyword={2}) not found or not supported." -f $Name, $DisplayName, $keyword)
    return $true
  }

  if ($DryRun) {
    $keywordLabel = if ($keyword) { $keyword } else { 'no-keyword' }
    Write-NetworkTuningInformation -Message ("[DryRun] {0}: {1} ({2}) => {3}" -f $Name, $DisplayName, $keywordLabel, $Value)
    return $true
  }

  $targetHint = if ($keyword) { "Keyword: $keyword" } else { "DisplayName: $DisplayName" }
  if (-not $PSCmdlet.ShouldProcess(("{0}: {1}" -f $Name, $DisplayName), ("Set to '{0}' via {1}" -f $Value, $targetHint))) {
    return $true
  }

  try {
    if ($keyword) {
      Set-NetAdapterAdvancedProperty -Name $Name -RegistryKeyword $keyword -RegistryValue $Value -NoRestart -ErrorAction Stop | Out-Null
    } else {
      Set-NetAdapterAdvancedProperty -Name $Name -DisplayName $DisplayName -DisplayValue $Value -NoRestart -ErrorAction Stop | Out-Null
    }
    return $true
  } catch {
    Write-Warning -Message ("Network adapter '{0}': could not change '{1}'. Your adapter or driver may not support this setting. ({2})" -f $Name, $DisplayName, $_.Exception.Message)
    return $false
  }
}

function Set-NetworkTuningNicConfiguration {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
  [OutputType([bool])]
  param(
    [Parameter()]
    [switch]$DryRun
  )

  $keywords = [System.Collections.Generic.List[string]]::new()
  $keywords.AddRange([string[]]$script:NetworkTuningNicKeywordsTier1)

  try {
    $adapters = @(Get-NetworkTuningPhysicalUpAdapter)
  } catch {
    Write-Warning -Message ("Could not detect your network adapters. Make sure you have an active Ethernet connection. ({0})" -f $_.Exception.Message)
    return $false
  }

  if ($adapters.Count -eq 0) {
    Write-Warning -Message 'No active physical network adapter was found.'
    return $false
  }

  $allSucceeded = $true
  foreach ($nic in $adapters) {
    Write-NetworkTuningInformation -Message ("NIC: {0}" -f $nic.Name)

    foreach ($keyword in $keywords) {
      $displayName = if ($script:NetworkTuningNicKeywordReverseMap.ContainsKey($keyword)) { $script:NetworkTuningNicKeywordReverseMap[$keyword] } else { $keyword }
      $value = 'Disabled'
      $propertySucceeded = Set-NetworkTuningNicAdvancedPropertyIfSupported -Name $nic.Name -DisplayName $displayName -Value $value -DryRun:$DryRun
      if ($false -eq $propertySucceeded) { $allSucceeded = $false }
    }

  }

  return $allSucceeded
}
