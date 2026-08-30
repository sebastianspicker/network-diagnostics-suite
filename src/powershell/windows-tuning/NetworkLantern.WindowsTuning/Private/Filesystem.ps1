function New-NetworkTuningDirectory {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([void])]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw 'Path must not be null or empty.'
  }

  # This helper is used only for backup destinations. Recheck immediately
  # before creating a directory so an elevation boundary cannot turn a
  # path that was replaced after caller validation into an elevated write.
  $pathTrust = Test-NetworkTuningBackupWritePathTrust -BackupFolder $Path
  if (-not $pathTrust.IsTrusted) {
    throw "Backup directory is not trusted for creation: $($pathTrust.Message)"
  }

  $isWindowsRuntime = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
  if (Test-Path -LiteralPath $Path) {
    if ($isWindowsRuntime) {
      $existingPathCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $Path
      if (-not $existingPathCheck.IsTrusted) { throw $existingPathCheck.Message }
    }
    return
  }

  if ($PSCmdlet.ShouldProcess($Path, 'Create directory')) {
    if ($isWindowsRuntime) {
      $parentPath = [System.IO.Directory]::GetParent([System.IO.Path]::GetFullPath($Path)).FullName
      $isFreshDefault = [System.IO.Path]::GetFullPath($Path).Equals([System.IO.Path]::GetFullPath($script:NetworkTuningDefaultBackupFolder), [System.StringComparison]::OrdinalIgnoreCase)
      $parentCheck = if ($isFreshDefault) {
        Test-NetworkTuningWindowsDefaultBackupParent -Path $parentPath
      } else {
        Test-NetworkTuningWindowsAdminOnlyPath -Path $parentPath
      }
      if (-not $parentCheck.IsTrusted) { throw $parentCheck.Message }
      [System.IO.FileSystemAclExtensions]::Create(
        [System.IO.DirectoryInfo]::new($Path),
        (Get-NetworkTuningAdminOnlyDirectorySecurity)
      )
      $createdPathCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $Path
      if (-not $createdPathCheck.IsTrusted) { throw $createdPathCheck.Message }
    } else {
      [System.IO.Directory]::CreateDirectory($Path) | Out-Null
    }
  }
}

function Read-NetworkTuningBoundedTextFile {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][long]$MaximumBytes
  )

  $bytes = Read-NetworkTuningBoundedFileBytes -Path $Path -MaximumBytes $MaximumBytes
  $encoding = [System.Text.UTF8Encoding]::new($false, $true); $offset = 0
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
  elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true); $offset = 2 }
  elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $encoding = [System.Text.UnicodeEncoding]::new($true, $true, $true); $offset = 2 }
  return $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
}

function Invoke-NetworkTuningBoundedFileStream {
  [CmdletBinding()]
  [OutputType([long])]
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][long]$MaximumBytes, [scriptblock]$OnChunk)
  if ($MaximumBytes -lt 0) { throw 'MaximumBytes must not be negative.' }
  $stream = $null
  try {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $buffer = [byte[]]::new(81920); $total = 0L; $limitPlusOne = $MaximumBytes + 1L
    while ($true) {
      $remaining = $limitPlusOne - $total
      if ($remaining -le 0) { throw "Backup artifact exceeds the $MaximumBytes byte limit: $Path" }
      $read = $stream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
      if ($read -eq 0) { break }
      $total += $read
      if ($total -gt $MaximumBytes) { throw "Backup artifact exceeds the $MaximumBytes byte limit: $Path" }
      if ($null -ne $OnChunk) { & $OnChunk $buffer $read }
    }
    return $total
  } finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Read-NetworkTuningBoundedFileBytes {
  [CmdletBinding()]
  [OutputType([byte[]])]
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][long]$MaximumBytes)
  $memory = [System.IO.MemoryStream]::new()
  try {
    Invoke-NetworkTuningBoundedFileStream -Path $Path -MaximumBytes $MaximumBytes -OnChunk { param($buffer, $count) $memory.Write($buffer, 0, $count) } | Out-Null
    return $memory.ToArray()
  } finally { $memory.Dispose() }
}

function Read-NetworkTuningBoundedCliXml {
  [CmdletBinding()]
  [OutputType([object])]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][long]$MaximumBytes
  )

  # Deserialize bytes acquired through the bounded, non-sharing handle above.
  # Import-CliXml would reopen the path after its size check.
  $content = Read-NetworkTuningBoundedTextFile -Path $Path -MaximumBytes $MaximumBytes
  return [System.Management.Automation.PSSerializer]::Deserialize($content)
}

function Assert-NetworkTuningBackupWriteNamespace {
  [CmdletBinding()]
  [OutputType([void])]
  param(
    [Parameter(Mandatory)][string]$BackupFolder
  )

  # Do this immediately before artifact publication, rather than relying on a
  # path check performed before elevation or directory creation.  On Windows
  # the check requires a protected Administrators/SYSTEM namespace, so a
  # medium-integrity token cannot replace a path in the interval.
  $pathTrust = Test-NetworkTuningBackupWritePathTrust -BackupFolder $BackupFolder
  if (-not $pathTrust.IsTrusted) {
    throw "Backup directory is not trusted for artifact creation: $($pathTrust.Message)"
  }

  foreach ($artifactName in (@($script:NetworkTuningBackupFileManifest) + @(Get-NetworkTuningKnownBackupArtifactNames))) {
    $artifactPath = Join-Path -Path $BackupFolder -ChildPath $artifactName
    if (-not (Test-Path -LiteralPath $artifactPath)) { continue }
    $artifactCheck = Test-NetworkTuningBackupPathEntryIsRegular -Path $artifactPath
    if (-not $artifactCheck.IsTrusted) { throw $artifactCheck.Message }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
      $aclCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $artifactPath
      if (-not $aclCheck.IsTrusted) { throw $aclCheck.Message }
    }
  }
}

function Test-NetworkTuningRollbackArtifactTrust {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][bool]$WindowsRuntime)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]@{ IsTrusted = $false; Message = 'rollback artifact is missing' }
  }
  $regularCheck = Test-NetworkTuningBackupPathEntryIsRegular -Path $Path
  if (-not $regularCheck.IsTrusted) { return $regularCheck }
  if ($WindowsRuntime) {
    $aclCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $Path
    if (-not $aclCheck.IsTrusted) { return $aclCheck }
  }
  return [pscustomobject]@{ IsTrusted = $true; Message = '' }
}

function Invoke-NetworkTuningAtomicFileReplace {
  [CmdletBinding()]
  [OutputType([void])]
  param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$DestinationPath, [Parameter(Mandatory)][string]$BackupPath)
  [System.IO.File]::Replace($SourcePath, $DestinationPath, $BackupPath, $true)
}

function Remove-NetworkTuningPublicationPath {
  [CmdletBinding()]
  [OutputType([void])]
  param([Parameter(Mandatory)][string]$Path)
  Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function Move-NetworkTuningPublicationPathToQuarantine {
  [CmdletBinding()]
  [OutputType([void])]
  param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$DestinationPath)
  Move-Item -LiteralPath $SourcePath -Destination $DestinationPath -ErrorAction Stop
}

function Invoke-NetworkTuningBackupArtifactPublication {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][string]$BackupFolder,
    [Parameter(Mandatory)][string]$FileName,
    [Parameter(Mandatory)][scriptblock]$WriteTemporary,
    [Parameter()][switch]$ForceWindowsAcl
  )

  $isWindowsRuntime = $ForceWindowsAcl -or [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
  Assert-NetworkTuningBackupWriteNamespace -BackupFolder $BackupFolder
  if ($FileName -notin (@($script:NetworkTuningBackupFileManifest) + @(Get-NetworkTuningKnownBackupArtifactNames))) {
    throw "Backup artifact name is not approved: $FileName"
  }
  $destinationPath = Join-Path -Path $BackupFolder -ChildPath $FileName
  if (Test-Path -LiteralPath $destinationPath) {
    $destinationCheck = Test-NetworkTuningBackupPathEntryIsRegular -Path $destinationPath
    if (-not $destinationCheck.IsTrusted) { throw $destinationCheck.Message }
    if ($isWindowsRuntime) {
      $destinationAclCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $destinationPath
      if (-not $destinationAclCheck.IsTrusted) { throw $destinationAclCheck.Message }
    }
  }

  # A random, pre-created sibling cannot be redirected through a pre-planted
  # artifact. The writer receives only this already-created regular file.
  $temporaryPath = Join-Path -Path $BackupFolder -ChildPath ('.{0}.{1}.tmp' -f $FileName, [guid]::NewGuid().ToString('N'))
  $rollbackPath = Join-Path -Path $BackupFolder -ChildPath ('.{0}.{1}.rollback' -f $FileName, [guid]::NewGuid().ToString('N'))
  $destinationExisted = $false
  $published = $false
  $preserveRollback = $false
  $stream = $null
  try {
    $stream = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $stream.Flush($true)
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }

  try {
    $writerOutput = @(& $WriteTemporary $temporaryPath)
    if ($writerOutput -contains $false) { return $false }
    $temporaryCheck = Test-NetworkTuningBackupPathEntryIsRegular -Path $temporaryPath
    if (-not $temporaryCheck.IsTrusted) { throw $temporaryCheck.Message }
    # The delegated command has closed its handle by now. Reopen and flush the
    # exact temporary file before publishing it.
    $stream = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    try { $stream.Flush($true) } finally { $stream.Dispose(); $stream = $null }
    if ($isWindowsRuntime) {
      # The temporary artifact must already be protected before it acquires the
      # well-known final name. A crash after Move therefore cannot publish an
      # inherited or writable final artifact.
      Protect-NetworkTuningAdminOnlyFile -Path $temporaryPath -Confirm:$false
      $temporaryAclCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $temporaryPath
      if (-not $temporaryAclCheck.IsTrusted) { throw $temporaryAclCheck.Message }
    }
    Assert-NetworkTuningBackupWriteNamespace -BackupFolder $BackupFolder
    $destinationExisted = Test-Path -LiteralPath $destinationPath
    if ($destinationExisted) {
      $destinationCheck = Test-NetworkTuningBackupPathEntryIsRegular -Path $destinationPath
      if (-not $destinationCheck.IsTrusted) { throw $destinationCheck.Message }
      if ($isWindowsRuntime) {
        $destinationAclCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $destinationPath
        if (-not $destinationAclCheck.IsTrusted) { throw $destinationAclCheck.Message }
      }
    }
    if ($destinationExisted) {
      # File.Replace preserves the old trusted destination as a rollback file
      # while atomically making the already-protected temporary file final.
      Invoke-NetworkTuningAtomicFileReplace -SourcePath $temporaryPath -DestinationPath $destinationPath -BackupPath $rollbackPath
    } else {
      [System.IO.File]::Move($temporaryPath, $destinationPath)
    }
    $published = $true
    if ($isWindowsRuntime) {
      $destinationAclCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $destinationPath
      if (-not $destinationAclCheck.IsTrusted) { throw $destinationAclCheck.Message }
    }
    if (Test-Path -LiteralPath $rollbackPath) {
      Remove-Item -LiteralPath $rollbackPath -Force -ErrorAction Stop
    }
    return $true
  } catch {
    $publicationFailure = $_.Exception
    if ($published) {
      try {
        if ($destinationExisted) {
          $rollbackCheck = Test-NetworkTuningRollbackArtifactTrust -Path $rollbackPath -WindowsRuntime $isWindowsRuntime
          if (-not $rollbackCheck.IsTrusted) { throw "Prior destination could not be recovered because $($rollbackCheck.Message)." }
          $discardPath = Join-Path -Path $BackupFolder -ChildPath ('.{0}.{1}.discard' -f $FileName, [guid]::NewGuid().ToString('N'))
          try {
            Invoke-NetworkTuningAtomicFileReplace -SourcePath $rollbackPath -DestinationPath $destinationPath -BackupPath $discardPath
          } finally {
            if (Test-Path -LiteralPath $discardPath) {
              Remove-Item -LiteralPath $discardPath -Force -ErrorAction SilentlyContinue
            }
          }
        } elseif (Test-Path -LiteralPath $destinationPath) {
          Remove-NetworkTuningPublicationPath -Path $destinationPath
        }
      } catch {
        $recoveryFailure = $_.Exception.Message
        $rollbackRetained = $false
        if ($destinationExisted) {
          $rollbackCheck = Test-NetworkTuningRollbackArtifactTrust -Path $rollbackPath -WindowsRuntime $isWindowsRuntime
          $rollbackRetained = [bool]$rollbackCheck.IsTrusted
          $preserveRollback = $rollbackRetained
        }
        $quarantinePath = Join-Path -Path $BackupFolder -ChildPath ('.{0}.{1}.quarantine' -f $FileName, [guid]::NewGuid().ToString('N'))
        $quarantineSucceeded = $false
        try {
          if (Test-Path -LiteralPath $destinationPath) {
            Move-NetworkTuningPublicationPathToQuarantine -SourcePath $destinationPath -DestinationPath $quarantinePath
          }
          if (Test-Path -LiteralPath $destinationPath) { throw 'The unvalidated well-known destination still exists after evacuation.' }
          $quarantineSucceeded = $true
        } catch {
          $rollbackMessage = if ($rollbackRetained) { 'A trusted rollback artifact was retained.' } elseif ($destinationExisted) { 'The prior destination could not be recovered because no trusted rollback artifact is available.' } else { 'No prior destination existed.' }
          throw "SEVERE: backup publication rollback and quarantine failed; the well-known path may contain an unvalidated artifact. $rollbackMessage $($_.Exception.Message)"
        }
        if ($quarantineSucceeded -and $rollbackRetained) {
          throw "SEVERE: backup publication rollback could not complete. The unvalidated artifact was quarantined, the well-known path is absent, and a trusted rollback artifact was retained for recovery: $recoveryFailure"
        }
        if ($quarantineSucceeded -and $destinationExisted) {
          throw "SEVERE: backup publication rollback could not complete. The unvalidated artifact was quarantined and the well-known path is absent, but the prior destination could not be recovered because no trusted rollback artifact is available: $recoveryFailure"
        }
        throw "SEVERE: backup publication cleanup could not complete. The unvalidated artifact was quarantined and the well-known path is absent; no prior destination existed: $recoveryFailure"
      }
    }
    throw $publicationFailure
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
    if (Test-Path -LiteralPath $temporaryPath) {
      Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
    if (-not $preserveRollback -and (Test-Path -LiteralPath $rollbackPath)) {
      Remove-Item -LiteralPath $rollbackPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Write-NetworkTuningBackupTextArtifact {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][string]$BackupFolder,
    [Parameter(Mandatory)][string]$FileName,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Content
  )

  $capturedContent = $Content
  return Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $BackupFolder -FileName $FileName -WriteTemporary {
    param($temporaryPath)
    [System.IO.File]::WriteAllText($temporaryPath, $capturedContent, [System.Text.UTF8Encoding]::new($false))
  }
}

function Test-NetworkTuningUnsafeBackupFolder {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }

  $canonicalRaw = $Path.Replace('/', '\').TrimEnd('\')

  $canonicalFull = $canonicalRaw
  try {
    $canonicalFull = [System.IO.Path]::GetFullPath($Path).Replace('/', '\').TrimEnd('\')
  } catch {
    # Keep original canonical input when full path resolution is not possible.
    Write-Verbose -Message ("Path resolution failed for '{0}': {1}" -f $Path, $_.Exception.Message)
  }

  $windirSystem32 = $null
  if (-not [string]::IsNullOrWhiteSpace($env:windir)) {
    $windirSystem32 = Join-Path -Path $env:windir -ChildPath 'System32'
  }

  $sensitiveRoots = [System.Collections.Generic.List[string]]::new()
  foreach ($root in @(
      $env:windir,
      $windirSystem32,
      $env:ProgramFiles,
      ${env:ProgramFiles(x86)},
      'C:\Windows',
      'C:\Windows\System32',
      'C:\Program Files',
      'C:\Program Files (x86)'
    )) {
    if (-not [string]::IsNullOrWhiteSpace($root)) {
      $sensitiveRoots.Add($root.Replace('/', '\').TrimEnd('\')) | Out-Null
    }
  }

  $pathCandidates = [System.Collections.Generic.List[string]]::new()
  if (-not [string]::IsNullOrWhiteSpace($canonicalFull)) { $pathCandidates.Add($canonicalFull) | Out-Null }
  if (-not [string]::IsNullOrWhiteSpace($canonicalRaw)) { $pathCandidates.Add($canonicalRaw) | Out-Null }

  foreach ($candidate in $pathCandidates) {
    foreach ($root in $sensitiveRoots) {
      if ($candidate.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -or
          $candidate.StartsWith(($root + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
    }
  }

  if ($canonicalRaw -match '(^|\\)windows(\\|$)' -or
      $canonicalRaw -match '(^|\\)windows\\system32(\\|$)' -or
      $canonicalRaw -match '(^|\\)program files( \(x86\))?(\\|$)') {
    return $true
  }

  return $false
}
