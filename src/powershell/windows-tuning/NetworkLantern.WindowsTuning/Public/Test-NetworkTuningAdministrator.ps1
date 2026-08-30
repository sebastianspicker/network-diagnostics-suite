function Test-NetworkTuningAdministrator {
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  try {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    Write-Verbose -Message 'Admin check failed (non-Windows or restricted platform).'
    return $false
  }
}
