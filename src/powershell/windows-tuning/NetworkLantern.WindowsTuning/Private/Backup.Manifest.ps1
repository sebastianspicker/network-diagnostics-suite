function Get-NetworkTuningBackupManifestMetadata {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  $moduleVersion = $null
  try {
    $moduleVersion = (Get-Module -Name NetworkLantern.WindowsTuning -ErrorAction SilentlyContinue | Select-Object -First 1).Version.ToString()
  } catch {
    $moduleVersion = $null
  }

  return @{
    SchemaVersion = $script:NetworkTuningBackupSchemaVersion
    ToolName      = $script:NetworkTuningToolName
    MachineName   = [System.Environment]::MachineName
    Platform      = [System.Environment]::OSVersion.Platform.ToString()
    OsVersion     = [System.Environment]::OSVersion.VersionString
    ModuleVersion = $moduleVersion
  }
}

function Test-NetworkTuningBackupManifestComponentMap {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][hashtable]$Manifest
  )

  if (-not $Manifest.ContainsKey('Components') -or -not ($Manifest['Components'] -is [System.Collections.IDictionary])) {
    return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest Components must be a dictionary.' }
  }

  $components = $Manifest['Components']
  $knownComponents = @((Get-NetworkTuningBackupArtifactFileMap).Keys)
  $componentKeys = @($components.Keys | ForEach-Object { [string]$_ })
  foreach ($componentKey in $componentKeys) {
    $isKnown = @($knownComponents | Where-Object {
        [string]::Equals([string]$_, $componentKey, [System.StringComparison]::Ordinal)
      }).Count -eq 1
    if (-not $isKnown) {
      return [pscustomobject]@{ IsValid = $false; Message = "Backup manifest contains an unknown component: $componentKey" }
    }
  }

  $enabledCount = 0
  foreach ($componentName in $knownComponents) {
    $matchingKeys = @($componentKeys | Where-Object {
        [string]::Equals($_, [string]$componentName, [System.StringComparison]::Ordinal)
      })
    if ($matchingKeys.Count -ne 1) {
      return [pscustomobject]@{ IsValid = $false; Message = "Backup manifest is missing component state: $componentName" }
    }
    $componentValue = $components[$matchingKeys[0]]
    if (-not ($componentValue -is [bool])) {
      return [pscustomobject]@{ IsValid = $false; Message = "Backup manifest component must be boolean: $componentName" }
    }
    if ([bool]$componentValue) {
      $enabledCount++
    }
  }

  if ($enabledCount -eq 0) {
    return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest must enable at least one restorable component.' }
  }

  return [pscustomobject]@{ IsValid = $true; Message = '' }
}

function Test-NetworkTuningBackupManifestJsonShape {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$Json
  )

  $document = $null
  try {
    $document = [System.Text.Json.JsonDocument]::Parse($Json, [System.Text.Json.JsonDocumentOptions]@{ MaxDepth = $script:NetworkTuningMaxBackupJsonDepth })
    $root = $document.RootElement
    if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
      return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest root must be a JSON object.'; SchemaVersion = $null }
    }

    $topLevelNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $allowedTopLevelProperties = @(
      'SchemaVersion', 'ToolName', 'MachineName', 'Platform', 'OsVersion',
      'ModuleVersion', 'Timestamp', 'Components', 'ArtifactDigests'
    )
    $componentElement = $null
    $artifactDigestElement = $null
    $hasComponents = $false
    $hasSchemaVersion = $false
    $hasToolName = $false
    $hasArtifactDigests = $false
    $schemaVersion = $null
    foreach ($property in $root.EnumerateObject()) {
      if (-not $topLevelNames.Add($property.Name)) {
        return [pscustomobject]@{ IsValid = $false; Message = "Backup manifest contains a duplicate property: $($property.Name)"; SchemaVersion = $null }
      }

      if ($property.Name -notin $allowedTopLevelProperties) {
        return [pscustomobject]@{ IsValid = $false; Message = "Backup manifest contains an unknown property: $($property.Name)"; SchemaVersion = $null }
      }
      $canonicalTopLevelName = @($allowedTopLevelProperties | Where-Object {
          [string]::Equals($_, $property.Name, [System.StringComparison]::OrdinalIgnoreCase)
        })
      if ($canonicalTopLevelName.Count -ne 1 -or $property.Name -cne $canonicalTopLevelName[0]) {
        return [pscustomobject]@{ IsValid = $false; Message = "Backup manifest property casing must be exact: $($property.Name)"; SchemaVersion = $null }
      }

      if ([string]::Equals($property.Name, 'Components', [System.StringComparison]::OrdinalIgnoreCase) -and
          -not [string]::Equals($property.Name, 'Components', [System.StringComparison]::Ordinal)) {
        return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest property casing must be exact: Components'; SchemaVersion = $null }
      }
      if ([string]::Equals($property.Name, 'SchemaVersion', [System.StringComparison]::OrdinalIgnoreCase) -and
          -not [string]::Equals($property.Name, 'SchemaVersion', [System.StringComparison]::Ordinal)) {
        return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest property casing must be exact: SchemaVersion'; SchemaVersion = $null }
      }

      if ([string]::Equals($property.Name, 'Components', [System.StringComparison]::Ordinal)) {
        $hasComponents = $true
        $componentElement = $property.Value
      } elseif ([string]::Equals($property.Name, 'SchemaVersion', [System.StringComparison]::Ordinal)) {
        $hasSchemaVersion = $true
        if ($property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Number) {
          return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest SchemaVersion must be an integer.'; SchemaVersion = $null }
        }
        $parsedSchemaVersion = 0
        if (-not $property.Value.TryGetInt32([ref]$parsedSchemaVersion) -or $parsedSchemaVersion -lt 1) {
          return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest SchemaVersion must be a positive integer.'; SchemaVersion = $null }
        }
        $schemaVersion = $parsedSchemaVersion
      } elseif ([string]::Equals($property.Name, 'ToolName', [System.StringComparison]::Ordinal)) {
        $hasToolName = $true
        if ($property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
            [string]::IsNullOrWhiteSpace($property.Value.GetString())) {
          return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest ToolName must be a non-empty string.'; SchemaVersion = $null }
        }
      } elseif ([string]::Equals($property.Name, 'ArtifactDigests', [System.StringComparison]::Ordinal)) {
        $hasArtifactDigests = $true
        $artifactDigestElement = $property.Value
        if ($property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
          return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest ArtifactDigests must be a dictionary.'; SchemaVersion = $null }
        }
      }
    }

    if (-not $hasSchemaVersion) {
      return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest is missing SchemaVersion.'; SchemaVersion = $null }
    }
    if (-not $hasComponents) {
      return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest is missing Components.'; SchemaVersion = $schemaVersion }
    }
    if (-not $hasToolName) {
      return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest is missing ToolName.'; SchemaVersion = $schemaVersion }
    }
    if (-not $hasArtifactDigests) {
      return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest is missing ArtifactDigests.'; SchemaVersion = $schemaVersion }
    }
    if ($componentElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
      return [pscustomobject]@{ IsValid = $false; Message = 'Backup manifest Components must be a dictionary.'; SchemaVersion = $schemaVersion }
    }

    $artifactNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $knownArtifactNames = @(Get-NetworkTuningKnownBackupArtifactNames)
    foreach ($digestProperty in $artifactDigestElement.EnumerateObject()) {
      if (-not $artifactNames.Add($digestProperty.Name)) {
        return [pscustomobject]@{ IsValid = $false; Message = "Backup manifest contains a duplicate artifact digest or case variant: $($digestProperty.Name)"; SchemaVersion = $schemaVersion }
      }
      if ($digestProperty.Name -cnotin $knownArtifactNames -or -not (Test-NetworkTuningSafeBackupArtifactName -Name $digestProperty.Name)) {
        return [pscustomobject]@{ IsValid = $false; Message = "Backup manifest contains an unknown artifact digest: $($digestProperty.Name)"; SchemaVersion = $schemaVersion }
      }
      if ($digestProperty.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
          $digestProperty.Value.GetString() -cnotmatch '^[0-9A-F]{64}$') {
        return [pscustomobject]@{ IsValid = $false; Message = "Backup manifest contains an invalid SHA-256 digest for: $($digestProperty.Name)"; SchemaVersion = $schemaVersion }
      }
    }

    $componentNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $knownComponents = @((Get-NetworkTuningBackupArtifactFileMap).Keys)
    foreach ($componentProperty in $componentElement.EnumerateObject()) {
      if (-not $componentNames.Add($componentProperty.Name)) {
        return [pscustomobject]@{ IsValid = $false; Message = "Backup manifest contains a duplicate component or case variant: $($componentProperty.Name)"; SchemaVersion = $schemaVersion }
      }
      $isExactKnownComponent = @($knownComponents | Where-Object {
          [string]::Equals([string]$_, $componentProperty.Name, [System.StringComparison]::Ordinal)
        }).Count -eq 1
      if (-not $isExactKnownComponent) {
        return [pscustomobject]@{ IsValid = $false; Message = "Backup manifest contains an unknown component or non-exact casing: $($componentProperty.Name)"; SchemaVersion = $schemaVersion }
      }
      if ($componentProperty.Value.ValueKind -notin @(
          [System.Text.Json.JsonValueKind]::True,
          [System.Text.Json.JsonValueKind]::False
        )) {
        return [pscustomobject]@{ IsValid = $false; Message = "Backup manifest component must be boolean: $($componentProperty.Name)"; SchemaVersion = $schemaVersion }
      }
    }

    return [pscustomobject]@{ IsValid = $true; Message = ''; SchemaVersion = $schemaVersion }
  } catch {
    return [pscustomobject]@{ IsValid = $false; Message = 'Could not read the backup summary file.'; SchemaVersion = $null }
  } finally {
    if ($null -ne $document) { $document.Dispose() }
  }
}

function Get-NetworkTuningExistingBackupAncestorPath {
  [CmdletBinding()]
  [OutputType([string[]])]
  param([Parameter(Mandatory)][string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $ancestorPaths = [System.Collections.Generic.List[string]]::new()
  $cursor = [System.IO.DirectoryInfo]::new($fullPath)
  while ($null -ne $cursor) {
    if (Test-Path -LiteralPath $cursor.FullName) {
      $ancestorPaths.Add($cursor.FullName) | Out-Null
    }
    $cursor = $cursor.Parent
  }
  return $ancestorPaths.ToArray()
}

function Test-NetworkTuningBackupPathEntryIsRegular {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter()][switch]$RequireDirectory
  )

  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      return [pscustomobject]@{ IsTrusted = $false; Message = "Backup path must not be a symbolic link or reparse point: $Path" }
    }
    if ($RequireDirectory -and -not $item.PSIsContainer) {
      return [pscustomobject]@{ IsTrusted = $false; Message = "Backup folder is not a directory: $Path" }
    }
    if (-not $RequireDirectory -and $item.PSIsContainer) {
      return [pscustomobject]@{ IsTrusted = $false; Message = "Backup artifact is not a regular file: $Path" }
    }
  } catch {
    return [pscustomobject]@{ IsTrusted = $false; Message = "Could not inspect backup path: $Path" }
  }
  return [pscustomobject]@{ IsTrusted = $true; Message = '' }
}

function Test-NetworkTuningBackupWritePathTrust {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$BackupFolder,
    [Parameter()][switch]$ForceWindowsNamespace
  )

  if ([string]::IsNullOrWhiteSpace($BackupFolder)) {
    return [pscustomobject]@{ IsTrusted = $false; Message = 'Backup folder must not be empty.' }
  }

  try {
    $fullPath = [System.IO.Path]::GetFullPath($BackupFolder)
  } catch {
    return [pscustomobject]@{ IsTrusted = $false; Message = 'Backup folder must resolve to an absolute local path.' }
  }
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows) -and
      ($fullPath.StartsWith('\\', [System.StringComparison]::Ordinal) -or $fullPath.StartsWith('\\?\', [System.StringComparison]::Ordinal))) {
    return [pscustomobject]@{ IsTrusted = $false; Message = 'Backup folder must be a local Windows path, not a UNC or device path.' }
  }

  foreach ($ancestorPath in (Get-NetworkTuningExistingBackupAncestorPath -Path $fullPath)) {
    $ancestorCheck = Test-NetworkTuningBackupPathEntryIsRegular -Path $ancestorPath -RequireDirectory
    if (-not $ancestorCheck.IsTrusted) { return $ancestorCheck }
  }

  $isWindowsRuntime = $ForceWindowsNamespace -or [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
  if ($isWindowsRuntime) {
    if (Test-Path -LiteralPath $fullPath) {
      $namespaceCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $fullPath
    } elseif ($fullPath.Equals([System.IO.Path]::GetFullPath($script:NetworkTuningDefaultBackupFolder), [System.StringComparison]::OrdinalIgnoreCase)) {
      $namespaceCheck = Test-NetworkTuningWindowsDefaultBackupParent -Path ([System.IO.Directory]::GetParent($fullPath).FullName)
    } else {
      $parentPath = [System.IO.Directory]::GetParent($fullPath).FullName
      $namespaceCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $parentPath
    }
    if (-not $namespaceCheck.IsTrusted) { return $namespaceCheck }
  }

  if (Test-Path -LiteralPath $fullPath) {
    $folderCheck = Test-NetworkTuningBackupPathEntryIsRegular -Path $fullPath -RequireDirectory
    if (-not $folderCheck.IsTrusted) { return $folderCheck }
    $allArtifactsManifest = @{ Components = @{} }
    foreach ($componentName in (Get-NetworkTuningBackupArtifactFileMap).Keys) {
      $allArtifactsManifest.Components[$componentName] = $true
    }
    $folderTrust = Test-NetworkTuningBackupPathTrust -BackupFolder $fullPath -Manifest $allArtifactsManifest -ForWrite
    if (-not $folderTrust.IsTrusted) { return $folderTrust }
  }

  foreach ($artifactName in (@($script:NetworkTuningBackupFileManifest) + @(Get-NetworkTuningKnownBackupArtifactNames))) {
    $artifactPath = Join-Path -Path $fullPath -ChildPath $artifactName
    if (Test-Path -LiteralPath $artifactPath) {
      $artifactCheck = Test-NetworkTuningBackupPathEntryIsRegular -Path $artifactPath
      if (-not $artifactCheck.IsTrusted) { return $artifactCheck }
      if ($isWindowsRuntime) {
        $artifactAclCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $artifactPath
        if (-not $artifactAclCheck.IsTrusted) { return $artifactAclCheck }
      }
    }
  }
  return [pscustomobject]@{ IsTrusted = $true; Message = '' }
}

function Test-NetworkTuningWindowsDefaultBackupParent {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][string]$Path)

  $chainCheck = Test-NetworkTuningWindowsStagingAncestorChain -Path $Path
  if (-not $chainCheck.IsTrusted) { return $chainCheck }
  try {
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($ownerSid -ne 'S-1-5-18') {
      return [pscustomobject]@{ IsTrusted = $false; Message = "Default backup parent is not SYSTEM-owned: $Path" }
    }
  } catch {
    return [pscustomobject]@{ IsTrusted = $false; Message = "Could not validate default backup parent: $Path" }
  }
  return [pscustomobject]@{ IsTrusted = $true; Message = '' }
}

function Test-NetworkTuningBackupPathTrust {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$BackupFolder,
    [Parameter(Mandatory)][hashtable]$Manifest,
    [Parameter()][switch]$ForWrite
  )

  $pathsToCheck = [System.Collections.Generic.List[string]]::new()
  foreach ($ancestorPath in (Get-NetworkTuningExistingBackupAncestorPath -Path $BackupFolder)) {
    $ancestorCheck = Test-NetworkTuningBackupPathEntryIsRegular -Path $ancestorPath -RequireDirectory
    if (-not $ancestorCheck.IsTrusted) { return $ancestorCheck }
  }
  $pathsToCheck.Add($BackupFolder) | Out-Null
  $manifestPath = Join-Path -Path $BackupFolder -ChildPath $script:NetworkTuningBackupFileManifest
  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $pathsToCheck.Add($manifestPath) | Out-Null
  }
  foreach ($fileName in (Get-NetworkTuningExpectedBackupArtifactNames -Manifest $Manifest)) {
    $artifactPath = Join-Path -Path $BackupFolder -ChildPath $fileName
    if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
      $pathsToCheck.Add($artifactPath) | Out-Null
    }
  }

  foreach ($path in $pathsToCheck) {
    try {
      $entryCheck = Test-NetworkTuningBackupPathEntryIsRegular -Path $path -RequireDirectory:($path -eq $BackupFolder)
      if (-not $entryCheck.IsTrusted) { return $entryCheck }
    } catch {
      return [pscustomobject]@{ IsTrusted = $false; Message = "Could not inspect backup path: $path" }
    }
  }

  $isWindowsRuntime = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
  if (-not $isWindowsRuntime) {
    return [pscustomobject]@{ IsTrusted = $true; Message = '' }
  }

  $trustedOwnerSids = @(
    'S-1-5-18',
    'S-1-5-32-544',
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
  )
  if (-not $ForWrite) {
    $trustedOwnerSids += [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  }
  $writeRights = [System.Security.AccessControl.FileSystemRights]::Write -bor
    [System.Security.AccessControl.FileSystemRights]::WriteData -bor
    [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor
    [System.Security.AccessControl.FileSystemRights]::AppendData -bor
    [System.Security.AccessControl.FileSystemRights]::Modify -bor
    [System.Security.AccessControl.FileSystemRights]::FullControl -bor
    [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [System.Security.AccessControl.FileSystemRights]::TakeOwnership

  foreach ($path in $pathsToCheck) {
    try {
      $acl = Get-Acl -LiteralPath $path
      $ownerSid = ([System.Security.Principal.NTAccount]$acl.Owner).Translate([System.Security.Principal.SecurityIdentifier]).Value
      if ($ownerSid -notin $trustedOwnerSids) {
        return [pscustomobject]@{ IsTrusted = $false; Message = "Backup path owner is not trusted: $path" }
      }

      foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
          continue
        }
        if (($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) {
          continue
        }

        $identitySid = $null
        try {
          $identitySid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch {
          return [pscustomobject]@{ IsTrusted = $false; Message = "Could not validate an ACL identity on backup path: $path" }
        }

        if ($identitySid -notin $trustedOwnerSids -and (($rule.FileSystemRights -band $writeRights) -ne 0)) {
          return [pscustomobject]@{ IsTrusted = $false; Message = "Backup path is writable by an untrusted identity: $path" }
        }
      }
    } catch {
      return [pscustomobject]@{ IsTrusted = $false; Message = "Could not validate backup path trust: $path" }
    }
  }

  return [pscustomobject]@{ IsTrusted = $true; Message = '' }
}

function Read-NetworkTuningBackupManifest {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$BackupFolder
  )

  $manifestPath = Join-Path -Path $BackupFolder -ChildPath $script:NetworkTuningBackupFileManifest
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    return [pscustomobject]@{ Status = 'Missing'; Message = 'No backup summary file found.'; Manifest = $null }
  }

  try {
    $manifestJson = Read-NetworkTuningBoundedTextFile -Path $manifestPath -MaximumBytes $script:NetworkTuningMaxManifestBytes
    $jsonShape = Test-NetworkTuningBackupManifestJsonShape -Json $manifestJson
    if (-not $jsonShape.IsValid) {
      return [pscustomobject]@{ Status = 'Invalid'; Message = $jsonShape.Message; Manifest = $null }
    }
    $manifest = $manifestJson | ConvertFrom-Json -AsHashtable
  } catch {
    return [pscustomobject]@{ Status = 'Invalid'; Message = 'Could not read the backup summary file.'; Manifest = $null }
  }

  if (-not ($manifest -is [System.Collections.IDictionary])) {
    return [pscustomobject]@{ Status = 'Invalid'; Message = 'Backup manifest root must be a JSON object.'; Manifest = $null }
  }
  if (-not $manifest.ContainsKey('SchemaVersion')) {
    return [pscustomobject]@{ Status = 'Invalid'; Message = 'Backup manifest is missing SchemaVersion.'; Manifest = $manifest }
  }
  if ($null -eq $jsonShape.SchemaVersion) {
    return [pscustomobject]@{ Status = 'Invalid'; Message = 'Backup manifest SchemaVersion must be a positive integer.'; Manifest = $manifest }
  }
  if ([int]$jsonShape.SchemaVersion -gt [int]$script:NetworkTuningBackupSchemaVersion) {
    return [pscustomobject]@{ Status = 'Incompatible'; Message = 'Backup manifest schema is newer than this module supports.'; Manifest = $manifest }
  }
  if (-not $manifest.ContainsKey('ToolName') -or [string]::IsNullOrWhiteSpace([string]$manifest['ToolName'])) {
    return [pscustomobject]@{ Status = 'Invalid'; Message = 'Backup manifest is missing ToolName.'; Manifest = $manifest }
  }
  if ([string]$manifest['ToolName'] -notin $script:NetworkTuningCompatibleToolNames) {
    return [pscustomobject]@{ Status = 'Incompatible'; Message = 'Backup manifest tool name does not match this module.'; Manifest = $manifest }
  }

  $componentCheck = Test-NetworkTuningBackupManifestComponentMap -Manifest $manifest
  if (-not $componentCheck.IsValid) {
    return [pscustomobject]@{ Status = 'Invalid'; Message = $componentCheck.Message; Manifest = $manifest }
  }

  $pathTrust = Test-NetworkTuningBackupPathTrust -BackupFolder $BackupFolder -Manifest $manifest
  if (-not $pathTrust.IsTrusted) {
    return [pscustomobject]@{ Status = 'Invalid'; Message = $pathTrust.Message; Manifest = $manifest }
  }

  $artifactCheck = Test-NetworkTuningBackupArtifactDigests -BackupFolder $BackupFolder -Manifest $manifest
  if (-not $artifactCheck.IsValid) {
    return [pscustomobject]@{ Status = 'Invalid'; Message = $artifactCheck.Message; Manifest = $manifest }
  }

  $authorizationCheck = Test-NetworkTuningRestoreArtifactAuthorization -BackupFolder $BackupFolder -Manifest $manifest
  if (-not $authorizationCheck.IsAuthorized) {
    return [pscustomobject]@{ Status = 'Invalid'; Message = $authorizationCheck.Message; Manifest = $manifest }
  }

  return [pscustomobject]@{ Status = 'OK'; Message = ''; Manifest = $manifest }
}
