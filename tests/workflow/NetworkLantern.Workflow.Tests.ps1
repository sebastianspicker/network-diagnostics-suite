Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $script:ModulePath = Join-Path $script:RepoRoot 'src/powershell/workflow/NetworkLantern.Workflow/NetworkLantern.Workflow.psd1'
  $script:WorkflowModule = Import-Module -Name $script:ModulePath -Force -PassThru
  $script:InvokeChildBootstrapEnvelope = {
    param([string]$EncodedBootstrap, [string]$Envelope)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-EncodedCommand', $EncodedBootstrap)) {
      $null = $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
      $process.StandardInput.Write($Envelope)
      $process.StandardInput.Close()
      $stdout = $process.StandardOutput.ReadToEnd()
      $stderr = $process.StandardError.ReadToEnd()
      $process.WaitForExit()
      return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout + $stderr }
    } finally {
      $process.Dispose()
    }
  }
  $script:NewSizedChildEnvelope = {
    param([int]$ByteLength)

    $baseEnvelope = [ordered]@{ Capability = 'Unsupported'; Parameters = [ordered]@{ Padding = '' } }
    $baseJson = ConvertTo-Json -InputObject $baseEnvelope -Compress
    $paddingLength = $ByteLength - [System.Text.Encoding]::UTF8.GetByteCount($baseJson)
    $paddingLength | Should -BeGreaterOrEqual 0
    $envelope = [ordered]@{ Capability = 'Unsupported'; Parameters = [ordered]@{ Padding = ('x' * $paddingLength) } }
    $json = ConvertTo-Json -InputObject $envelope -Compress
    [System.Text.Encoding]::UTF8.GetByteCount($json) | Should -Be $ByteLength
    return $json
  }
  $script:WriteUtf8File = {
    param([string]$Path, [string]$Content)

    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
  }
  $script:NewSizedWorkflowProfile = {
    param([int]$ByteLength)

    $prefix = '{"path":{"hostsIPv4":["exact.example"],"padding":"'
    $suffix = '"}}'
    $paddingLength = $ByteLength - [System.Text.Encoding]::UTF8.GetByteCount($prefix + $suffix)
    $paddingLength | Should -BeGreaterOrEqual 0
    $json = $prefix + ('x' * $paddingLength) + $suffix
    [System.Text.Encoding]::UTF8.GetByteCount($json) | Should -Be $ByteLength
    return $json
  }
}

Describe 'Network Lantern workflow module' {
  It 'uses explicit values ahead of profile values and warns for ignored keys' {
    $profilePath = Join-Path $TestDrive 'workflow.json'
    Set-Content -LiteralPath $profilePath -Encoding utf8 -Value @'
{
  "path": { "hostsIPv4": ["profile.example"], "unknown": true },
  "unknownSection": { "value": 1 }
}
'@

    $result = & $script:WorkflowModule {
      param($path)
      $workflowProfile = Import-NetworkLanternWorkflowProfile -ProfilePath $path
      $warnings = @(Write-NetworkLanternWorkflowProfileWarnings -ProfileMap $workflowProfile 3>&1)
      $section = Get-NetworkLanternProfileSection -ProfileMap $workflowProfile -Name 'path'
      $effective = @(Resolve-NetworkLanternEffectiveValue -ExplicitValue @('explicit.example') -ExplicitValueWasProvided $true -Section $section -Key 'hostsIPv4' -Fallback @())
      [pscustomobject]@{ Warnings = $warnings; Effective = $effective }
    } $profilePath

    $result.Effective | Should -Be @('explicit.example')
    ($result.Warnings | Out-String) | Should -Match 'path.unknown'
    ($result.Warnings | Out-String) | Should -Match 'unknownSection'
  }

  It 'accepts a workflow profile at the exact 1 MiB byte limit' {
    $profilePath = Join-Path $TestDrive 'exact-limit.json'
    & $script:WriteUtf8File -Path $profilePath -Content (& $script:NewSizedWorkflowProfile -ByteLength 1MB)

    $workflowProfile = & $script:WorkflowModule {
      param($path)
      Import-NetworkLanternWorkflowProfile -ProfilePath $path
    } $profilePath

    @($workflowProfile.path.hostsIPv4) | Should -Be @('exact.example')
  }

  It 'rejects a workflow profile at 1 MiB plus one byte before parsing' {
    $profilePath = Join-Path $TestDrive 'over-limit.json'
    & $script:WriteUtf8File -Path $profilePath -Content (& $script:NewSizedWorkflowProfile -ByteLength ((1MB) + 1))

    {
      & $script:WorkflowModule {
        param($path)
        Import-NetworkLanternWorkflowProfile -ProfilePath $path
      } $profilePath
    } | Should -Throw '*ProfilePath exceeds maximum size*'
  }

  It 'reads an opened workflow profile even after its path is replaced' {
    $profilePath = Join-Path $TestDrive 'replaced-profile.json'
    $replacementPath = Join-Path $TestDrive 'replacement-profile.json'
    $originalProfile = '{"path":{"hostsIPv4":["original.example"]}}'
    $replacementProfile = '{"path":{"hostsIPv4":["replacement.example"]}}'
    & $script:WriteUtf8File -Path $profilePath -Content $originalProfile
    & $script:WriteUtf8File -Path $replacementPath -Content $replacementProfile

    $stream = [System.IO.File]::Open(
      $profilePath,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    )
    try {
      Move-Item -LiteralPath $replacementPath -Destination $profilePath -Force
      $profileText = & $script:WorkflowModule {
        param($inputStream)
        Read-NetworkLanternWorkflowProfileText -Stream $inputStream
      } $stream
    } finally {
      $stream.Dispose()
    }

    $profileText | Should -Be $originalProfile
    [System.IO.File]::ReadAllText($profilePath) | Should -Be $replacementProfile
  }

  It 'rejects a profile that grows past the limit after its handle is opened' {
    $profilePath = Join-Path $TestDrive 'growing-profile.json'
    & $script:WriteUtf8File -Path $profilePath -Content (& $script:NewSizedWorkflowProfile -ByteLength 1MB)

    $stream = [System.IO.File]::Open(
      $profilePath,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    )
    try {
      [System.IO.File]::AppendAllText($profilePath, 'x', [System.Text.UTF8Encoding]::new($false))
      {
        & $script:WorkflowModule {
          param($inputStream)
          Read-NetworkLanternWorkflowProfileText -Stream $inputStream
        } $stream
      } | Should -Throw '*ProfilePath exceeds maximum size*'
    } finally {
      $stream.Dispose()
    }
  }

  It 'rejects malformed and overly nested workflow profile JSON' {
    $malformedPath = Join-Path $TestDrive 'malformed-profile.json'
    $nestedPath = Join-Path $TestDrive 'nested-profile.json'
    & $script:WriteUtf8File -Path $malformedPath -Content '{"path":'

    $nestedJson = '"value"'
    for ($index = 0; $index -lt 17; $index++) {
      $nestedJson = '{"level":' + $nestedJson + '}'
    }
    & $script:WriteUtf8File -Path $nestedPath -Content $nestedJson

    {
      & $script:WorkflowModule {
        param($path)
        Import-NetworkLanternWorkflowProfile -ProfilePath $path
      } $malformedPath
    } | Should -Throw
    {
      & $script:WorkflowModule {
        param($path)
        Import-NetworkLanternWorkflowProfile -ProfilePath $path
      } $nestedPath
    } | Should -Throw
  }

  It 'builds an ordered, non-executing baseline plan' {
    $plan = New-NetworkLanternWorkflowPlan -Workflow Baseline -IperfTarget iperf3.example.net -DryRun `
      -OutRoot (Join-Path $TestDrive 'plan-artifacts') `
      -ExplicitParameters @{ Workflow = 'Baseline'; IperfTarget = 'iperf3.example.net'; DryRun = $true }

    $plan.Workflow | Should -Be 'Baseline'
    @($plan.Steps.Capability) | Should -Be @('Path', 'Throughput')
    $plan.Steps[0].Parameters.LogDirectory | Should -Be (Join-Path $TestDrive 'plan-artifacts/path')
    $plan.Steps[0].Parameters.DryRun | Should -BeTrue
    $plan.Steps[1].Parameters.WhatIf | Should -BeTrue
    (Test-Path -LiteralPath (Join-Path $TestDrive 'plan-artifacts')) | Should -BeFalse
  }

  It 'applies profile precedence through the stable adapter' {
    $profilePath = Join-Path $TestDrive 'adapter-workflow.json'
    Set-Content -LiteralPath $profilePath -Encoding utf8 -Value @'
{
  "path": {
    "hostsIPv4": ["profile.example"],
    "protocols": ["IPv4"],
    "rounds": ["Standard"],
    "unknown": true
  }
}
'@

    $output = & pwsh -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot 'Invoke-NetworkLantern.ps1') `
      -Workflow Path -ProfilePath $profilePath -HostsIPv4 explicit.example -DryRun -OutRoot (Join-Path $TestDrive 'adapter-artifacts') 2>&1

    $LASTEXITCODE | Should -Be 0
    ($output | Out-String) | Should -Match 'Unknown workflow profile key.*path.unknown'
    ($output | Out-String) | Should -Match 'IPv4 hosts: explicit.example'
  }

  It 'keeps workflow dry-run previews side-effect free' {
    $outRoot = Join-Path $TestDrive 'artifacts'
    $output = & pwsh -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot 'Invoke-NetworkLantern.ps1') `
      -Workflow Path -HostsIPv4 example.com -Protocols IPv4 -Rounds Standard -DryRun -Quiet -OutRoot $outRoot 2>&1

    $LASTEXITCODE | Should -Be 0
    ($output | Out-String) | Should -Match 'Dry-run only'
    (Test-Path -LiteralPath $outRoot) | Should -BeFalse
  }

  It 'accepts every planner step through the canonical capability descriptors' {
    . (Join-Path $script:RepoRoot 'apps/workflow/Private/WorkflowApplication.ps1')
    $descriptors = Get-NetworkLanternWorkflowCapabilityDescriptors
    @($descriptors.Keys) | Should -Be @('Path', 'Throughput', 'WindowsTuning')
    $trustedAdapters = Get-NetworkLanternTrustedCapabilityAdapters -RepositoryRoot $script:RepoRoot

    foreach ($capability in @($descriptors.Keys)) {
      $trustedAdapters[$capability] | Should -Be (Join-Path $script:RepoRoot $descriptors[$capability].AdapterRelativePath)
    }

    foreach ($workflow in @('Triage', 'Path', 'Throughput', 'Baseline', 'WindowsTuning')) {
      $plan = New-NetworkLanternWorkflowPlan -Workflow $workflow -IperfTarget 'iperf3.example.net' -OutRoot $TestDrive `
        -ExplicitParameters @{ Workflow = $workflow; IperfTarget = 'iperf3.example.net' }
      foreach ($step in @($plan.Steps)) {
        $descriptor = Test-NetworkLanternWorkflowCapabilityStep -Step $step
        $descriptors.Contains($step.Capability) | Should -BeTrue
        @($step.Parameters.Keys | Where-Object { $_ -notin @($descriptor.AllowedParameters) }) | Should -BeNullOrEmpty
      }
    }
  }

  It 'rejects a planner step with a parameter outside its canonical descriptor before process creation' {
    . (Join-Path $script:RepoRoot 'apps/workflow/Private/WorkflowApplication.ps1')
    $step = [pscustomobject]@{ Capability = 'Path'; Parameters = @{ ScriptPath = 'not-allowed.ps1' } }

    { Invoke-NetworkLanternCapabilityChild -Step $step -RepositoryRoot $script:RepoRoot } |
      Should -Throw '*Unsupported parameter*'
  }

  It 'reads an exactly maximum-sized child envelope before capability validation' {
    . (Join-Path $script:RepoRoot 'apps/workflow/Private/WorkflowApplication.ps1')
    $encodedBootstrap = New-NetworkLanternCapabilityChildBootstrap -RepositoryRoot $script:RepoRoot
    $envelope = & $script:NewSizedChildEnvelope -ByteLength 1MB
    $result = & $script:InvokeChildBootstrapEnvelope -EncodedBootstrap $encodedBootstrap -Envelope $envelope

    $result.ExitCode | Should -Not -Be 0
    $result.Output | Should -Match "Unsupported workflow capability 'Unsupported'"
    $result.Output | Should -Not -Match 'envelope exceeds maximum size'
  }

  It 'rejects a child envelope at maximum plus one byte without consuming an unbounded stream' {
    . (Join-Path $script:RepoRoot 'apps/workflow/Private/WorkflowApplication.ps1')
    $encodedBootstrap = New-NetworkLanternCapabilityChildBootstrap -RepositoryRoot $script:RepoRoot
    $envelope = & $script:NewSizedChildEnvelope -ByteLength ((1MB) + 1)
    $result = & $script:InvokeChildBootstrapEnvelope -EncodedBootstrap $encodedBootstrap -Envelope $envelope

    $result.ExitCode | Should -Not -Be 0
    $result.Output | Should -Match 'Workflow child envelope exceeds maximum size'
  }

  It 'rejects an oversized child envelope before starting a process' {
    . (Join-Path $script:RepoRoot 'apps/workflow/Private/WorkflowApplication.ps1')
    $step = [pscustomobject]@{
      Capability = 'Path'
      Parameters = @{ HostsIPv4 = @('x' * 1MB) }
    }

    { Invoke-NetworkLanternCapabilityChild -Step $step -RepositoryRoot $script:RepoRoot } |
      Should -Throw '*envelope exceeds maximum size*'
  }

  It 'forwards the isolated child failure status through the stable adapter' {
    $output = & pwsh -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot 'Invoke-NetworkLantern.ps1') `
      -Workflow WindowsTuning -TuningAction Verify 2>&1

    $LASTEXITCODE | Should -Be 1
    ($output | Out-String) | Should -Not -BeNullOrEmpty
  }
}
