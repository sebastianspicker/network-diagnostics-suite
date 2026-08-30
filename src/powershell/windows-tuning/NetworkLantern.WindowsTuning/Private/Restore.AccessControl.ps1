function Get-NetworkTuningTrustedStagingSidValue {
  [CmdletBinding()]
  [OutputType([string[]])]
  param()

  return @(
    'S-1-5-18',
    'S-1-5-32-544',
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
  )
}

function Test-NetworkTuningWindowsStagingAncestorChain {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$Path
  )

  $trustedSids = @(Get-NetworkTuningTrustedStagingSidValue)
  $takeoverRights = [System.Security.AccessControl.FileSystemRights]::Delete -bor
    [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [System.Security.AccessControl.FileSystemRights]::TakeOwnership

  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [pscustomobject]@{ IsTrusted = $false; Message = "Restore staging ancestor is a reparse point: $($item.FullName)" }
      }

      $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
      $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
      if ($ownerSid -notin $trustedSids) {
        return [pscustomobject]@{ IsTrusted = $false; Message = "Restore staging ancestor owner is not administrative: $($item.FullName)" }
      }

      $accessRules = $acl.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]
      )
      foreach ($rule in $accessRules) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
            ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) {
          continue
        }

        $identitySid = $rule.IdentityReference.Value
        if ($identitySid -notin $trustedSids -and (($rule.FileSystemRights -band $takeoverRights) -ne 0)) {
          return [pscustomobject]@{ IsTrusted = $false; Message = "Restore staging ancestor grants delete or ACL-takeover rights to an untrusted identity: $($item.FullName)" }
        }
      }

      $item = if ($item.PSIsContainer) { $item.Parent } else { $item.Directory }
    }
  } catch {
    return [pscustomobject]@{ IsTrusted = $false; Message = "Could not validate restore staging ancestors for '$Path': $($_.Exception.Message)" }
  }

  return [pscustomobject]@{ IsTrusted = $true; Message = '' }
}

function Test-NetworkTuningWindowsAdminOnlyPath {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$Path
  )

  $ancestorCheck = Test-NetworkTuningWindowsStagingAncestorChain -Path $Path
  if (-not $ancestorCheck.IsTrusted) { return $ancestorCheck }

  $requiredSids = @('S-1-5-18', 'S-1-5-32-544')

  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if (-not $acl.AreAccessRulesProtected) {
      return [pscustomobject]@{ IsTrusted = $false; Message = "Restore staging path inherits access rules instead of using a protected admin-only DACL: $Path" }
    }

    $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    $groupSid = $acl.GetGroup([System.Security.Principal.SecurityIdentifier]).Value
    $trustedSids = @(Get-NetworkTuningTrustedStagingSidValue)
    if ($ownerSid -notin $trustedSids -or $groupSid -notin $trustedSids) {
      return [pscustomobject]@{ IsTrusted = $false; Message = "Restore staging path owner or group is not administrative: $Path" }
    }

    $accessRules = @($acl.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]
      ))
    if ($accessRules.Count -ne $requiredSids.Count) {
      return [pscustomobject]@{ IsTrusted = $false; Message = "Restore staging path does not have the exact admin-only DACL: $Path" }
    }

    $seenSids = @{}
    $expectedInheritance = if ($item.PSIsContainer) {
      [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
      [System.Security.AccessControl.InheritanceFlags]::None
    }
    foreach ($rule in $accessRules) {
      $identitySid = $rule.IdentityReference.Value
      if ($rule.IsInherited -or
          $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
          $identitySid -notin $requiredSids -or
          $rule.InheritanceFlags -ne $expectedInheritance -or
          $rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None -or
          ($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne [System.Security.AccessControl.FileSystemRights]::FullControl) {
        return [pscustomobject]@{ IsTrusted = $false; Message = "Restore staging path has a non-admin or non-full-control access rule: $Path" }
      }
      if ($seenSids.ContainsKey($identitySid)) {
        return [pscustomobject]@{ IsTrusted = $false; Message = "Restore staging path has duplicate administrative access rules: $Path" }
      }
      $seenSids[$identitySid] = $true
    }

    foreach ($requiredSid in $requiredSids) {
      if (-not $seenSids.ContainsKey($requiredSid)) {
        return [pscustomobject]@{ IsTrusted = $false; Message = "Restore staging path is missing a required administrative access rule: $Path" }
      }
    }
  } catch {
    return [pscustomobject]@{ IsTrusted = $false; Message = "Could not validate restore staging ACL for '$Path': $($_.Exception.Message)" }
  }

  return [pscustomobject]@{ IsTrusted = $true; Message = '' }
}

function Get-NetworkTuningAdminOnlyDirectorySecurity {
  [CmdletBinding()]
  [OutputType([System.Security.AccessControl.DirectorySecurity])]
  param()

  $acl = [System.Security.AccessControl.DirectorySecurity]::new()
  $acl.SetAccessRuleProtection($true, $false)
  $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
  $administratorsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
  $acl.SetOwner($administratorsSid)
  $acl.SetGroup($administratorsSid)
  foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {
    $sid = [System.Security.Principal.SecurityIdentifier]::new($sidValue)
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
      $sid,
      [System.Security.AccessControl.FileSystemRights]::FullControl,
      $inheritance,
      [System.Security.AccessControl.PropagationFlags]::None,
      [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule) | Out-Null
  }
  return $acl
}

function Initialize-NetworkTuningAdminOnlyDirectory {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Path
  )

  if (-not $PSCmdlet.ShouldProcess($Path, 'Create an Administrators-and-SYSTEM-only directory')) {
    throw 'Restore staging directory creation was declined.'
  }

  $directoryInfo = [System.IO.DirectoryInfo]::new($Path)
  $directorySecurity = Get-NetworkTuningAdminOnlyDirectorySecurity
  [System.IO.FileSystemAclExtensions]::Create($directoryInfo, $directorySecurity)

  $pathCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $Path
  if (-not $pathCheck.IsTrusted) { throw $pathCheck.Message }
  return (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName
}

function Protect-NetworkTuningAdminOnlyFile {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([void])]
  param(
    [Parameter(Mandatory)][string]$Path
  )

  if (-not $PSCmdlet.ShouldProcess($Path, 'Restrict file to Administrators and SYSTEM')) { return }

  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Restore staging path is not a regular file: $Path"
  }

  $acl = [System.Security.AccessControl.FileSecurity]::new()
  $acl.SetAccessRuleProtection($true, $false)
  $administratorsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
  $acl.SetOwner($administratorsSid)
  $acl.SetGroup($administratorsSid)
  foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {
    $sid = [System.Security.Principal.SecurityIdentifier]::new($sidValue)
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
      $sid,
      [System.Security.AccessControl.FileSystemRights]::FullControl,
      [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule) | Out-Null
  }
  Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Get-NetworkTuningWindowsRestoreStagingRoot {
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $commonData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonApplicationData)
  if ([string]::IsNullOrWhiteSpace($commonData) -or -not [System.IO.Path]::IsPathFullyQualified($commonData)) {
    throw 'Could not resolve a fully qualified Windows common application-data directory.'
  }
  if ($commonData.StartsWith('\\', [System.StringComparison]::Ordinal)) {
    throw 'Windows restore staging requires a local common application-data directory, not a UNC or device path.'
  }

  $baseCheck = Test-NetworkTuningWindowsStagingAncestorChain -Path $commonData
  if (-not $baseCheck.IsTrusted) { throw $baseCheck.Message }

  $currentPath = $commonData
  foreach ($childName in @('NetworkLantern-Privileged', 'RestoreStaging')) {
    $currentPath = Join-Path -Path $currentPath -ChildPath $childName
    $currentPath = Initialize-NetworkTuningAdminOnlyDirectory -Path $currentPath -Confirm:$false
  }

  return $currentPath
}

