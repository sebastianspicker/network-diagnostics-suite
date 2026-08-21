[CmdletBinding()]
param(
  [switch]$NoInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

Write-Information "PowerShell version: $($PSVersionTable.PSVersion)" -InformationAction Continue
Write-Information "PSModulePath: $env:PSModulePath" -InformationAction Continue

# Keep module version pins in sync with the cache-key comment in .github/workflows/ci.yml.
# Update both files when bumping either version.
$requiredModules = @{
  PSScriptAnalyzer = '1.24.0'
  Pester           = '5.7.1'
}

function Test-ExactModuleInstalled {
  param(
    [string]$Name,
    [string]$Version
  )

  return [bool](Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -eq [version]$Version } | Select-Object -First 1)
}

$missingModules = @(
  $requiredModules.GetEnumerator() | Where-Object { -not (Test-ExactModuleInstalled -Name $_.Key -Version $_.Value) }
)

if ($NoInstall -and $missingModules.Count -gt 0) {
  [Console]::Error.WriteLine("Missing required PowerShell module(s): $($missingModules.Key -join ', '). Re-run without -NoInstall to install them, or install them manually.")
  exit 1
}

if ($missingModules.Count -eq 0) {
  Write-Information 'Required PowerShell modules already available; skipping installation.' -InformationAction Continue
} elseif (Get-Command -Name Install-PSResource -ErrorAction SilentlyContinue) {
  $repo = Get-PSResourceRepository -Name PSGallery -ErrorAction SilentlyContinue
  if (-not $repo) {
    Register-PSResourceRepository -PSGallery
    $repo = Get-PSResourceRepository -Name PSGallery -ErrorAction Stop
  }

  $restoreTrust = $false
  if (-not $repo.Trusted) {
    Set-PSResourceRepository -Name PSGallery -Trusted
    $restoreTrust = $true
  }

  try {
    foreach ($entry in $missingModules) {
      $name = $entry.Key
      $version = $entry.Value
      Write-Information "Installing $name $version via PSResourceGet..." -InformationAction Continue
      Install-PSResource -Name $name -Version $version -Scope CurrentUser -Repository PSGallery -TrustRepository -ErrorAction Stop
    }
  } finally {
    if ($restoreTrust) {
      Set-PSResourceRepository -Name PSGallery -Trusted:$false
    }
  }
} else {
  $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
  if (-not $repo) {
    Register-PSRepository -Default
    $repo = Get-PSRepository -Name PSGallery -ErrorAction Stop
  }

  $restorePolicy = $false
  if ($repo.InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    $restorePolicy = $true
  }

  try {
    try {
      Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
    } catch {
      Write-Warning "Install-PackageProvider failed: $($_.Exception.Message)"
    }

    foreach ($entry in $missingModules) {
      $name = $entry.Key
      $version = [version]$entry.Value
      Write-Information "Installing $name $version via PowerShellGet..." -InformationAction Continue
      Install-Module -Name $name -RequiredVersion $version -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
    }
  } finally {
    if ($restorePolicy) {
      Set-PSRepository -Name PSGallery -InstallationPolicy $repo.InstallationPolicy
    }
  }
}

foreach ($entry in $requiredModules.GetEnumerator()) {
  $name = [string]$entry.Key
  $version = [version]$entry.Value
  Get-Module -Name $name | Remove-Module -Force -ErrorAction SilentlyContinue
  Import-Module -Name $name -RequiredVersion $version -Force -ErrorAction Stop

  $loadedModule = Get-Module -Name $name |
    Where-Object { $_.Version -eq $version } |
    Select-Object -First 1
  if (-not $loadedModule) {
    throw "Failed to load required PowerShell module $name $version."
  }
  Write-Information "Loaded $name $version from $($loadedModule.Path)." -InformationAction Continue
}

$pathsToAnalyze = @(
  (Join-Path $repoRoot 'apps')
  (Join-Path $repoRoot 'src')
  (Join-Path $repoRoot 'scripts')
  (Join-Path $repoRoot 'tests')
  (Join-Path $repoRoot 'Invoke-NetworkLantern.ps1')
)

& (Join-Path $repoRoot 'scripts/Test-BrandIdentity.ps1') -RepoRoot $repoRoot

$settingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
$scriptAnalyzerResults = foreach ($path in $pathsToAnalyze) {
  Invoke-ScriptAnalyzer -Path $path -Recurse -Settings $settingsPath
}
if ($scriptAnalyzerResults) {
  $scriptAnalyzerResults | Sort-Object ScriptName, Line | Format-Table -AutoSize | Out-String | Write-Output
  throw "PSScriptAnalyzer found $(@($scriptAnalyzerResults).Count) issue(s)."
}

$pesterConfiguration = [PesterConfiguration]::Default
$pesterConfiguration.Run.Path = Join-Path $repoRoot 'tests'
$pesterConfiguration.Run.Exit = $false
$pesterConfiguration.Run.PassThru = $true
$pesterConfiguration.Output.Verbosity = 'Detailed'
$pesterConfiguration.Should.ErrorAction = 'Stop'

$pesterResult = Invoke-Pester -Configuration $pesterConfiguration
if (-not $pesterResult) {
  throw 'Pester did not return a result object.'
}
if (($pesterResult.TotalCount - $pesterResult.NotRunCount) -eq 0) {
  throw 'Pester did not discover any tests.'
}
if ($pesterResult.Result -ne 'Passed') {
  throw "Pester result was '$($pesterResult.Result)' with $($pesterResult.FailedCount) failed test(s)."
}
