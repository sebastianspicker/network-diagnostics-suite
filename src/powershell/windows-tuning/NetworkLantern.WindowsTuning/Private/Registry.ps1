function Get-NetworkTuningRegistryBackupContract {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [ValidateSet('SystemProfile', 'AfdParameters')]
    [string]$Name
  )

  if ($Name -eq 'SystemProfile') {
    $audioPath = '{0}\Tasks\Audio' -f $script:NetworkTuningRegistryPathSystemProfile.TrimEnd('\')
    return [pscustomobject]@{
      Name = 'SystemProfile'
      RegistryPath = $script:NetworkTuningRegistryPathSystemProfile
      ArtifactName = $script:NetworkTuningBackupFileSystemProfile
      Sections = @(
        [pscustomobject]@{
          RegistryPath = $script:NetworkTuningRegistryPathSystemProfile
          RegPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
          Values = [ordered]@{
            SystemResponsiveness = 'DWord'
            NetworkThrottlingIndex = 'DWord'
          }
        },
        [pscustomobject]@{
          RegistryPath = $audioPath
          RegPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Audio'
          Values = [ordered]@{
            Priority = 'DWord'
            BackgroundOnly = 'DWord'
            'Clock Rate' = 'DWord'
            SchedulingCategory = 'String'
            SFIOPriority = 'String'
          }
        }
      )
    }
  }

  return [pscustomobject]@{
    Name = 'AfdParameters'
    RegistryPath = $script:NetworkTuningRegistryPathAfdParameters
    ArtifactName = $script:NetworkTuningBackupFileAfdParameters
    Sections = @(
      [pscustomobject]@{
        RegistryPath = $script:NetworkTuningRegistryPathAfdParameters
        RegPath = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\AFD\Parameters'
        Values = [ordered]@{
          FastSendDatagramThreshold = 'DWord'
        }
      }
    )
  }
}

function Get-NetworkTuningRegistryBackupContractForPath {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [string]$RegistryPath
  )

  foreach ($contractName in @('SystemProfile', 'AfdParameters')) {
    $contract = Get-NetworkTuningRegistryBackupContract -Name $contractName
    if ($contract.RegistryPath -ieq $RegistryPath) {
      return $contract
    }
  }

  return $null
}

function ConvertTo-NetworkTuningRegStringData {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Value
  )

  if ($Value.IndexOfAny([char[]]@("`0", "`r", "`n")) -ge 0) {
    throw 'Registry string values containing NUL or newline characters are not supported by the strict backup format.'
  }

  return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Test-NetworkTuningRegStringData {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Data
  )

  return $Data -cmatch '^"(?:[^"\\]|\\["\\])*"$'
}

function Test-NetworkTuningRegistryBackupFile {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [string]$InFile,

    [Parameter(Mandatory)]
    [ValidateSet('SystemProfile', 'AfdParameters')]
    [string]$ContractName
  )

  if (-not (Test-Path -LiteralPath $InFile -PathType Leaf)) {
    return [pscustomobject]@{ IsApproved = $false; Message = "Registry backup file not found: $InFile" }
  }

  try {
    $content = Read-NetworkTuningBoundedTextFile -Path $InFile -MaximumBytes $script:NetworkTuningMaxRegistryBackupBytes
  } catch {
    return [pscustomobject]@{ IsApproved = $false; Message = "Could not read registry backup file: $InFile" }
  }

  $contract = Get-NetworkTuningRegistryBackupContract -Name $ContractName
  $sectionsByPath = @{}
  $expectedEntries = @{}
  foreach ($section in $contract.Sections) {
    $sectionsByPath[[string]$section.RegPath] = $section
    foreach ($valueName in $section.Values.Keys) {
      $expectedEntries[("{0}`n{1}" -f $section.RegPath, $valueName)] = [string]$section.Values[$valueName]
    }
  }

  $seenEntries = @{}
  $currentSection = $null
  $headerSeen = $false
  foreach ($rawLine in ($content -split "`r?`n")) {
    $line = $rawLine.Trim()
    if (-not $headerSeen) {
      $line = $line.TrimStart([char]0xFEFF)
    }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    if (-not $headerSeen) {
      if ($line -cne 'Windows Registry Editor Version 5.00') {
        return [pscustomobject]@{ IsApproved = $false; Message = 'Registry backup has an invalid header.' }
      }
      $headerSeen = $true
      continue
    }

    if ($line -match '^\[([^\]]+)\]$') {
      $sectionPath = [string]$Matches[1]
      if (-not $sectionsByPath.ContainsKey($sectionPath)) {
        return [pscustomobject]@{ IsApproved = $false; Message = "Registry backup contains an unapproved key: $sectionPath" }
      }
      $currentSection = $sectionsByPath[$sectionPath]
      continue
    }

    if ($null -eq $currentSection -or $line -notmatch '^"([^"]+)"=(.+)$') {
      return [pscustomobject]@{ IsApproved = $false; Message = 'Registry backup contains an unsupported or malformed entry.' }
    }

    $valueName = [string]$Matches[1]
    $valueData = [string]$Matches[2]
    if (-not $currentSection.Values.Contains($valueName)) {
      return [pscustomobject]@{ IsApproved = $false; Message = "Registry backup contains an unapproved value: $valueName" }
    }

    $entryKey = "{0}`n{1}" -f $currentSection.RegPath, $valueName
    if ($seenEntries.ContainsKey($entryKey)) {
      return [pscustomobject]@{ IsApproved = $false; Message = "Registry backup contains a duplicate value: $valueName" }
    }

    $expectedType = [string]$currentSection.Values[$valueName]
    $dataIsValid = $valueData -ceq '-'
    if (-not $dataIsValid -and $expectedType -eq 'DWord') {
      $dataIsValid = $valueData -cmatch '^dword:[0-9a-f]{8}$'
    } elseif (-not $dataIsValid -and $expectedType -eq 'String') {
      $dataIsValid = Test-NetworkTuningRegStringData -Data $valueData
    }

    if (-not $dataIsValid) {
      return [pscustomobject]@{ IsApproved = $false; Message = "Registry backup has invalid data for value: $valueName" }
    }

    $seenEntries[$entryKey] = $true
  }

  if (-not $headerSeen) {
    return [pscustomobject]@{ IsApproved = $false; Message = 'Registry backup has no header.' }
  }

  foreach ($entryKey in $expectedEntries.Keys) {
    if (-not $seenEntries.ContainsKey($entryKey)) {
      $missingValue = ($entryKey -split "`n", 2)[1]
      return [pscustomobject]@{ IsApproved = $false; Message = "Registry backup is missing required value state: $missingValue" }
    }
  }

  return [pscustomobject]@{ IsApproved = $true; Message = '' }
}

function Export-NetworkTuningRegistryKey {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$RegistryPath,

    [Parameter(Mandatory)]
    [string]$OutFile
  )

  try {
    $contract = Get-NetworkTuningRegistryBackupContractForPath -RegistryPath $RegistryPath
    if ($null -eq $contract) {
      throw "Registry path is not part of the approved backup contract: $RegistryPath"
    }

    $outDir = Split-Path -LiteralPath $OutFile -Parent
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
      [System.IO.Directory]::CreateDirectory($outDir) | Out-Null
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Windows Registry Editor Version 5.00') | Out-Null
    $lines.Add('') | Out-Null

    foreach ($section in $contract.Sections) {
      $lines.Add(("[{0}]" -f $section.RegPath)) | Out-Null
      $registryKey = $null
      if (Test-Path -LiteralPath $section.RegistryPath) {
        $registryKey = Get-Item -LiteralPath $section.RegistryPath -ErrorAction Stop
      }

      foreach ($valueName in $section.Values.Keys) {
        $serializedValue = '-'
        if ($null -ne $registryKey -and $valueName -in @($registryKey.GetValueNames())) {
          $expectedType = [string]$section.Values[$valueName]
          $actualKind = [string]$registryKey.GetValueKind($valueName)
          $value = $registryKey.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
          if ($expectedType -eq 'DWord' -and $actualKind -eq 'DWord') {
            $unsignedValue = [uint32]([int64]$value -band 0xffffffffL)
            $serializedValue = 'dword:{0:x8}' -f $unsignedValue
          } elseif ($expectedType -eq 'String' -and $actualKind -eq 'String') {
            $serializedValue = ConvertTo-NetworkTuningRegStringData -Value ([string]$value)
          } else {
            throw "Registry value '$valueName' has unsupported type '$actualKind'."
          }
        }
        $lines.Add(('"{0}"={1}' -f $valueName, $serializedValue)) | Out-Null
      }
      $lines.Add('') | Out-Null
    }

    Set-Content -LiteralPath $OutFile -Value $lines -Encoding Unicode
    $validation = Test-NetworkTuningRegistryBackupFile -InFile $OutFile -ContractName $contract.Name
    if (-not $validation.IsApproved) {
      throw $validation.Message
    }
    return $true
  } catch {
    Write-Warning -Message ("Could not back up registry key '{0}': {1}" -f $RegistryPath, $_.Exception.Message)
    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    return $false
  }
}

function Import-NetworkTuningRegistryFile {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$InFile,

    [Parameter(Mandatory)]
    [ValidateSet('SystemProfile', 'AfdParameters')]
    [string]$ContractName
  )

  if (-not (Test-Path -LiteralPath $InFile -PathType Leaf)) {
    Write-Warning -Message ("Could not restore registry settings: backup file not found at '{0}'. If you haven't run a backup yet, run Backup first." -f $InFile)
    return $false
  }

  $validation = Test-NetworkTuningRegistryBackupFile -InFile $InFile -ContractName $ContractName
  if (-not $validation.IsApproved) {
    Write-Warning -Message ("Refusing to import unapproved registry backup '{0}': {1}" -f $InFile, $validation.Message)
    return $false
  }

  try {
    $null = & reg.exe import $InFile 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Warning -Message ("Could not restore registry settings from '{0}'. The backup file may be corrupted or from a different PC (error code {1})." -f $InFile, $LASTEXITCODE)
      return $false
    }
    return $true
  } catch {
    Write-Warning -Message ("Could not restore registry settings from '{0}': {1}" -f $InFile, $_.Exception.Message)
    return $false
  }
}

function Set-NetworkTuningRegistryValue {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([void])]
  param(
    [Parameter(Mandatory)]
    [string]$Key,

    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [ValidateSet('DWord', 'String')]
    [string]$Type,

    [Parameter(Mandatory)]
    [AllowNull()]
    $Value
  )

  if (-not (Test-Path -Path $Key)) {
    if ($PSCmdlet.ShouldProcess($Key, 'Create registry key')) {
      New-Item -Path $Key -Force | Out-Null
    }
  }

  if (-not $PSCmdlet.ShouldProcess((Join-Path -Path $Key -ChildPath $Name), ("Set registry value ({0})" -f $Type))) {
    return
  }

  if ($Type -eq 'DWord') {
    New-ItemProperty -Path $Key -Name $Name -PropertyType DWord -Value ([int]$Value) -Force | Out-Null
    return
  }

  New-ItemProperty -Path $Key -Name $Name -PropertyType String -Value ([string]$Value) -Force | Out-Null
}
