[CmdletBinding()]
param(
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$legacyIdentityPattern = '(?i)(network-diagnostics-suite|NetworkDiagnosticsSuite|Invoke-NetworkDiagnostics|NetPathSuite|mtr-test-suite|iPerf3Test(?:-GUI)?\.ps1|Iperf3TestSuite|Optimize-NetworkPath|WindowsUdpJitterOptimization|Get-Nds|(?-i:\bNDS(?:[._-])))'
$allowedFilePattern = '^(CHANGELOG\.md|docs/(archive|migration)/.*|scripts/Test-BrandIdentity\.ps1|tests/windows-tuning/NetworkLantern\.WindowsTuning\.Tests\.ps1|apps/windows-tuning/Invoke-NetworkPathTuning\.ps1|src/powershell/windows-tuning/NetworkLantern\.WindowsTuning/(Private/(Actions\.BackupRestore|Constants)\.ps1|Public/Invoke-NetworkPathTuning\.ps1))$'
$allowedMigrationLinkPattern = '(docs/)?migration/from-(network-diagnostics-suite|mtr-test-suite|iperf3-test-suite|windows-udp-jitter-optimization)\.md'
$textFilePattern = '(?i)(^Makefile$|\.(bash|json|md|ps1|psd1|psm1|sh|ya?ml)$)'
$protectedPathPattern = '(?i)((^|/)\.env($|\.)|\.(key|p12|pem|pfx)$|(^|/)id_(ed25519|rsa)(\.pub)?$)'
$generatedMetadataPathPattern = '^(\.repowise)(/|$)'

$relativePaths = @(
  & git -C $RepoRoot ls-files --cached --others --exclude-standard |
    Sort-Object -Unique
)
if ($LASTEXITCODE -ne 0) {
  throw 'Could not enumerate repository files for the brand-identity check.'
}

$findings = [System.Collections.Generic.List[string]]::new()
foreach ($relativePath in $relativePaths) {
  $normalizedPath = $relativePath.Replace('\', '/')
  if ($normalizedPath -notmatch $textFilePattern -or $normalizedPath -match $protectedPathPattern) { continue }
  if ($normalizedPath -match $generatedMetadataPathPattern) { continue }
  if ($normalizedPath -match $allowedFilePattern) { continue }

  $fullPath = Join-Path -Path $RepoRoot -ChildPath $relativePath
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }

  $lineNumber = 0
  foreach ($line in [System.IO.File]::ReadLines($fullPath)) {
    $lineNumber++
    if ($line -notmatch $legacyIdentityPattern) { continue }
    if ($line -match $allowedMigrationLinkPattern) { continue }
    $findings.Add("${normalizedPath}:${lineNumber}: $($line.Trim())") | Out-Null
  }
}

if ($findings.Count -gt 0) {
  $findings | ForEach-Object { Write-Output $_ }
  throw "Found $($findings.Count) legacy brand identity occurrence(s) outside the compatibility allow-list."
}

Write-Information 'Network Lantern brand identity check passed.' -InformationAction Continue
