$ErrorActionPreference = 'Stop'

BeforeAll {
  . (Join-Path (Get-Item $PSScriptRoot).Parent.Parent.FullName 'scripts/Get-RepoRoot.ps1')
  $repoRoot = Get-RepoRoot
  $script:RepoRoot = $repoRoot
  $modulePath = Join-Path $repoRoot 'src/powershell/throughput/NetworkLantern.Throughput.psd1'
  Import-Module $modulePath -Force
  $script:TestCapability = [pscustomobject]@{ VersionText = 'iperf3 3.9'; Major = 3; Minor = 9; BidirSupported = $true }
  $global:NetworkThroughput_TestCapability = $script:TestCapability
  try {
    $global:IsWindows = $true
  } catch {
    Write-Verbose 'On some hosts (e.g. macOS) $IsWindows is read-only; Windows-only tests may fail or be skipped.'
  }
}

Describe 'Network Lantern throughput helpers' {

  Context 'Profiles' {
    It 'saves, lists, and loads profile parameters' {
      InModuleScope 'NetworkLantern.Throughput' {
        $profilesFile = Join-Path $TestDrive 'profiles.json'
        $save = Save-Iperf3Profile -ProfileName 'lab' -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local'; Port = 5201; Protocol = 'TCP' } -StrictConfiguration
        $save.ProfileName | Should -Be 'lab'
        $names = Get-Iperf3ProfileNames -ProfilesFile $profilesFile -StrictConfiguration
        $names | Should -Contain 'lab'
        $loaded = Get-Iperf3ProfileParameters -ProfileName 'lab' -ProfilesFile $profilesFile -StrictConfiguration
        $loaded.Target | Should -Be 'example.local'
        $loaded.Port | Should -Be 5201
        $loaded.Protocol | Should -Be 'TCP'
      }
    }

    It 'removes a saved profile' {
      InModuleScope 'NetworkLantern.Throughput' {
        $profilesFile = Join-Path $TestDrive 'profiles-remove.json'
        $null = Save-Iperf3Profile -ProfileName 'to-remove' -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local' }
        $removed = Remove-Iperf3Profile -ProfileName 'to-remove' -ProfilesFile $profilesFile
        $removed | Should -Be $true
        $names = Get-Iperf3ProfileNames -ProfilesFile $profilesFile
        $names | Should -Not -Contain 'to-remove'
      }
    }

    It 'does not change a profile store under WhatIf' {
      InModuleScope 'NetworkLantern.Throughput' {
        $profilesFile = Join-Path $TestDrive 'profiles-remove-whatif.json'
        $null = Save-Iperf3Profile -ProfileName 'keep' -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local' }
        $before = Get-Content -LiteralPath $profilesFile -Raw

        $removed = Remove-Iperf3Profile -ProfileName 'keep' -ProfilesFile $profilesFile -WhatIf 6>$null

        $removed | Should -BeFalse
        (Get-Content -LiteralPath $profilesFile -Raw) | Should -Be $before
        (Get-Iperf3ProfileNames -ProfilesFile $profilesFile) | Should -Contain 'keep'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.profiles-remove-whatif.json.*.tmp').Count | Should -Be 0
      }
    }

    It 'creates a backup when profiles file is corrupt in non-strict mode' {
      InModuleScope 'NetworkLantern.Throughput' {
        $profilesFile = Join-Path $TestDrive 'profiles-corrupt.json'
        Set-Content -LiteralPath $profilesFile -Encoding UTF8 -Value '{not-json'
        $names = Get-Iperf3ProfileNames -ProfilesFile $profilesFile
        @($names).Count | Should -Be 0
        $backups = @(Get-ChildItem -LiteralPath $TestDrive -Filter 'profiles-corrupt.json.corrupt.*.bak')
        $backups.Count | Should -Be 1
      }
    }

    It 'backs up a corrupt store before a profile mutation replaces it' {
      InModuleScope 'NetworkLantern.Throughput' {
        $profilesFile = Join-Path $TestDrive 'profiles-corrupt-mutation.json'
        Set-Content -LiteralPath $profilesFile -Encoding UTF8 -Value '{not-json'

        $null = Save-Iperf3Profile -ProfileName 'lab' -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local' }

        $backups = @(Get-ChildItem -LiteralPath $TestDrive -Filter 'profiles-corrupt-mutation.json.corrupt.*.bak')
        $backups.Count | Should -Be 1
        (Get-Content -LiteralPath $backups[0].FullName -Raw) | Should -Match '^\{not-json'
        (Get-Iperf3ProfileNames -ProfilesFile $profilesFile) | Should -Contain 'lab'
      }
    }

    It 'rejects an oversized store before a profile mutation' {
      InModuleScope 'NetworkLantern.Throughput' {
        $profilesFile = Join-Path $TestDrive 'profiles-oversized-mutation.json'
        $oversized = '{"version":1,"profiles":{},"padding":"' + ('x' * 1MB) + '"}'
        Set-Content -LiteralPath $profilesFile -Encoding UTF8 -Value $oversized -NoNewline

        { Save-Iperf3Profile -ProfileName 'lab' -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local' } } |
          Should -Throw '*exceeds maximum size*'
        (Get-Item -LiteralPath $profilesFile).Length | Should -BeGreaterThan 1MB
      }
    }

    It 'rejects a mutation whose serialized profile store would exceed 1 MB' {
      InModuleScope 'NetworkLantern.Throughput' {
        $profilesFile = Join-Path $TestDrive 'profiles-self-oversized.json'
        $hugeTarget = 'x' * 1MB

        { Save-Iperf3Profile -ProfileName 'too-large' -ProfilesFile $profilesFile -Parameters @{ Target = $hugeTarget } } |
          Should -Throw '*would exceed maximum size*'

        (Test-Path -LiteralPath $profilesFile) | Should -BeFalse
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.profiles-self-oversized.json.*.tmp').Count | Should -Be 0
      }
    }

    It 'serializes concurrent profile saves and removals and releases the lock' {
      $profilesFile = Join-Path $TestDrive 'profiles-concurrent.json'
      foreach ($number in 1..4) {
        $null = Save-Iperf3Profile -ProfileName "remove-$number" -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local' }
      }
      $readyDir = Join-Path $TestDrive 'profiles-concurrent-ready'
      $gatePath = Join-Path $TestDrive 'profiles-concurrent.gate'
      $modulePathForJobs = Join-Path $script:RepoRoot 'src/powershell/throughput/NetworkLantern.Throughput.psd1'
      $null = New-Item -ItemType Directory -Path $readyDir -Force
      $worker = {
        param($modulePath, $storePath, $action, $number, $readyPath, $gate)
        $ErrorActionPreference = 'Stop'
        Import-Module $modulePath -Force
        Set-Content -LiteralPath $readyPath -Value 'ready' -NoNewline
        while (-not (Test-Path -LiteralPath $gate -PathType Leaf)) {
          Start-Sleep -Milliseconds 5
        }
        $startTicks = [long](Get-Content -LiteralPath $gate -Raw)
        while ([datetime]::UtcNow.Ticks -lt $startTicks) {
          Start-Sleep -Milliseconds 2
        }
        if ($action -eq 'save') {
          $null = Save-Iperf3Profile -ProfileName "saved-$number" -ProfilesFile $storePath -Parameters @{ Target = "host-$number.example" }
        }
        else {
          $null = Remove-Iperf3Profile -ProfileName "remove-$number" -ProfilesFile $storePath
        }
      }
      $jobs = @()
      try {
        foreach ($number in 1..4) {
          $jobs += Start-Job -ScriptBlock $worker -ArgumentList @(
            $modulePathForJobs, $profilesFile, 'save', $number,
            (Join-Path $readyDir "save-$number.ready"), $gatePath
          )
          $jobs += Start-Job -ScriptBlock $worker -ArgumentList @(
            $modulePathForJobs, $profilesFile, 'remove', $number,
            (Join-Path $readyDir "remove-$number.ready"), $gatePath
          )
        }

        $readyWait = [System.Diagnostics.Stopwatch]::StartNew()
        while (@(Get-ChildItem -LiteralPath $readyDir -Filter '*.ready' -ErrorAction SilentlyContinue).Count -lt 8) {
          if ($readyWait.Elapsed.TotalSeconds -gt 20) { throw 'Concurrent profile workers did not become ready.' }
          Start-Sleep -Milliseconds 20
        }
        Set-Content -LiteralPath $gatePath -Value ([datetime]::UtcNow.AddMilliseconds(500).Ticks) -NoNewline
        $null = $jobs | Wait-Job -Timeout 20
        foreach ($job in $jobs) {
          $receiveErrors = @()
          $null = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable receiveErrors
          $failureDetail = @($job.ChildJobs[0].JobStateInfo.Reason) + @($receiveErrors)
          $job.State | Should -Be 'Completed' -Because ($failureDetail | Out-String)
          $receiveErrors | Should -BeNullOrEmpty
        }
      }
      finally {
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
      }

      $names = @(Get-Iperf3ProfileNames -ProfilesFile $profilesFile)
      foreach ($number in 1..4) {
        $names | Should -Contain "saved-$number"
        $names | Should -Not -Contain "remove-$number"
      }
      $lockStream = [System.IO.File]::Open(
        "$profilesFile.lock",
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
      )
      try { $lockStream | Should -Not -BeNullOrEmpty }
      finally { $lockStream.Dispose() }
    }

    It 'blocks profiles path traversal via relative path' {
      InModuleScope 'NetworkLantern.Throughput' {
        Push-Location $TestDrive
        try {
          { Save-Iperf3Profile -ProfileName 'x' -ProfilesFile '../profiles.json' -Parameters @{ Target = 'example.local' } -StrictConfiguration } | Should -Throw '*must be under the current directory*'
        }
        finally {
          Pop-Location
        }
      }
    }

    It 'lists profiles via Measure-NetworkThroughput passthru mode' {
      InModuleScope 'NetworkLantern.Throughput' {
        $profilesFile = Join-Path $TestDrive 'profiles-list.json'
        $null = Save-Iperf3Profile -ProfileName 'a' -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local' }
        $res = Measure-NetworkThroughput -ListProfiles -ProfilesFile $profilesFile -PassThru -Quiet
        $res.Mode | Should -Be 'ListProfiles'
        @($res.Profiles) | Should -Contain 'a'
      }
    }
  }

  Context 'CLI exit code mapping' {
    It 'returns 11 for unknown profile name' {
      $scriptPath = Join-Path $script:RepoRoot 'apps/throughput/Measure-NetworkThroughput.ps1'
      & pwsh -NoLogo -NoProfile -File $scriptPath -ProfileName '__does_not_exist__' -WhatIf *> $null
      $LASTEXITCODE | Should -Be 11
    }

    It 'deletes an existing profile via CLI DeleteProfile' {
      $scriptPath = Join-Path $script:RepoRoot 'apps/throughput/Measure-NetworkThroughput.ps1'
      $profilesFile = Join-Path $TestDrive 'cli-delete-profiles.json'

      & pwsh -NoLogo -NoProfile -File $scriptPath -Target 'example.local' -ProfilesFile $profilesFile -ProfileName 'cli-temp' -SaveProfile -WhatIf -Quiet *> $null
      $LASTEXITCODE | Should -Be 0

      & pwsh -NoLogo -NoProfile -File $scriptPath -ProfilesFile $profilesFile -DeleteProfile 'cli-temp' -Quiet *> $null
      $LASTEXITCODE | Should -Be 0

      $names = @(Get-Iperf3ProfileNames -ProfilesFile $profilesFile)
      $names | Should -Not -Contain 'cli-temp'
    }

    It 'returns 11 when deleting a non-existing profile via CLI DeleteProfile' {
      $scriptPath = Join-Path $script:RepoRoot 'apps/throughput/Measure-NetworkThroughput.ps1'
      $profilesFile = Join-Path $TestDrive 'cli-delete-missing.json'
      & pwsh -NoLogo -NoProfile -File $scriptPath -ProfilesFile $profilesFile -DeleteProfile '__missing__' -Quiet *> $null
      $LASTEXITCODE | Should -Be 11
    }

    It 'returns 12 when wrapper bootstrap fails during import' {
      $scriptPath = Join-Path $script:RepoRoot 'apps/throughput/Measure-NetworkThroughput.ps1'
      $command = @"
function Import-Module { throw 'simulated import failure' }
& '$scriptPath' -Target 'example.local' -WhatIf -Quiet *> `$null
exit `$LASTEXITCODE
"@

      & pwsh -NoLogo -NoProfile -Command $command *> $null
      $LASTEXITCODE | Should -Be 12
    }
  }

  Context 'CLI precedence' {
    It 'loads saved profile values through the CLI wrapper' {
      $scriptPath = Join-Path $script:RepoRoot 'apps/throughput/Measure-NetworkThroughput.ps1'
      $profilesFile = Join-Path $TestDrive 'cli-profiles.json'
      $null = Save-Iperf3Profile -ProfileName 'lab' -ProfilesFile $profilesFile -Parameters @{ Target = 'profile.example'; Port = 5300; Protocol = 'UDP' }

      $command = @"
`$result = & '$scriptPath' -ProfileName 'lab' -ProfilesFile '$profilesFile' -WhatIf -Quiet -PassThru
`$result | ConvertTo-Json -Compress -Depth 8
"@
      $json = & pwsh -NoLogo -NoProfile -Command $command
      $result = $json | ConvertFrom-Json

      $result.EffectiveParameters.Target | Should -Be 'profile.example'
      $result.EffectiveParameters.Port | Should -Be 5300
      $result.EffectiveParameters.Protocol | Should -Be 'UDP'
    }

    It 'lets explicit CLI args override saved profile values' {
      $scriptPath = Join-Path $script:RepoRoot 'apps/throughput/Measure-NetworkThroughput.ps1'
      $profilesFile = Join-Path $TestDrive 'cli-profiles-override.json'
      $null = Save-Iperf3Profile -ProfileName 'lab' -ProfilesFile $profilesFile -Parameters @{ Target = 'profile.example'; Port = 5300; Protocol = 'UDP' }

      $command = @"
`$result = & '$scriptPath' -ProfileName 'lab' -ProfilesFile '$profilesFile' -Target 'cli.example' -Port 5400 -Protocol TCP -WhatIf -Quiet -PassThru
`$result | ConvertTo-Json -Compress -Depth 8
"@
      $json = & pwsh -NoLogo -NoProfile -Command $command
      $result = $json | ConvertFrom-Json

      $result.EffectiveParameters.Target | Should -Be 'cli.example'
      $result.EffectiveParameters.Port | Should -Be 5400
      $result.EffectiveParameters.Protocol | Should -Be 'TCP'
    }

    It 'lets config override defaults but not explicit CLI args' {
      $scriptPath = Join-Path $script:RepoRoot 'apps/throughput/Measure-NetworkThroughput.ps1'
      $configPath = Join-Path $TestDrive 'cli-config.json'
      @{
        Target = 'config.example'
        Port = 5500
        Protocol = 'UDP'
      } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

      $command = @"
`$result = & '$scriptPath' -ConfigurationPath '$configPath' -Target 'cli.example' -WhatIf -Quiet -PassThru
`$result | ConvertTo-Json -Compress -Depth 8
"@
      $json = & pwsh -NoLogo -NoProfile -Command $command
      $result = $json | ConvertFrom-Json

      $result.EffectiveParameters.Target | Should -Be 'cli.example'
      $result.EffectiveParameters.Port | Should -Be 5500
      $result.EffectiveParameters.Protocol | Should -Be 'UDP'
      $result.EffectiveParameters.Duration | Should -Be 10
    }
  }

  Context 'Open-FolderOrFile' {
    It 'passes an absolute path to platform openers' {
      . (Join-Path $script:RepoRoot 'scripts/PathHelpers.ps1')
      $relativePath = 'relative-output'
      $expectedPath = [System.IO.Path]::GetFullPath($relativePath)

      Mock -CommandName Get-Command { [pscustomobject]@{ Name = 'xdg-open' } }
      Mock -CommandName Invoke-PathOpenerProcess {}

      Open-FolderOrFile -Path $relativePath

      Should -Invoke Invoke-PathOpenerProcess -Times 1 -Exactly -ParameterFilter {
        $Path -eq $expectedPath
      }
    }
  }

  Context 'WhatIf PassThru mode' {
    It 'returns WhatIf mode object without running tests' {
      InModuleScope 'NetworkLantern.Throughput' {
        $result = Measure-NetworkThroughput -Target 'example.local' -WhatIf -PassThru -Quiet
        $result.Mode | Should -Be 'WhatIf'
        $result.TotalApprox | Should -BeGreaterThan 0
        $result.PSObject.Properties.Name | Should -Contain 'CsvPath'
        $result.PSObject.Properties.Name | Should -Contain 'JsonPath'
      }
    }
  }
}
