[CmdletBinding()]
param(
  [string]$Filter
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Get-RepoRoot.ps1')
$repoRoot = Get-RepoRoot
$testsDir = Join-Path $repoRoot 'tests'

if (-not $Filter) {
  & (Join-Path $repoRoot 'scripts/ci.ps1')
  exit $LASTEXITCODE
}

Write-Warning 'Invoke-Tests.ps1 -Filter runs a filtered Pester subset only. Use scripts/ci.ps1 or ./scripts/ci-local.sh for the full verification gate.'

$requiredPesterVersion = [version]'5.7.1'
if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -eq $requiredPesterVersion })) {
  Write-Error "Pester $requiredPesterVersion is required. Install with: Install-Module Pester -RequiredVersion $requiredPesterVersion -Scope CurrentUser -Force"
  exit 1
}
Get-Module -Name Pester | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module Pester -RequiredVersion $requiredPesterVersion -Force -ErrorAction Stop

$config = [PesterConfiguration]::Default
$config.Run.Path = $testsDir
$config.Run.Exit = $false
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.Should.ErrorAction = 'Stop'

$config.Filter.FullName = "*$Filter*"

$result = Invoke-Pester -Configuration $config

if (-not $result) {
  Write-Error 'Pester did not return a result object.'
  exit 1
}
if (($result.TotalCount - $result.NotRunCount) -eq 0) {
  Write-Error "No tests matched filter '$Filter'."
  exit 1
}
if ($result.Result -ne 'Passed') {
  exit 1
}

exit 0
