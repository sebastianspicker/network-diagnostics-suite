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

  Context 'JSON extraction' {
    It 'extracts the JSON substring when surrounded by text' {
      InModuleScope 'NetworkLantern.Throughput' {
        $s = 'banner {"a":1} trailer'
        Get-JsonSubstringOrNull -Text $s | Should -Be '{"a":1}'
      }
    }

    It 'skips invalid braces and returns the first valid JSON' {
      InModuleScope 'NetworkLantern.Throughput' {
        $s = 'prefix {notjson} mid {"a":1} trailer'
        Get-JsonSubstringOrNull -Text $s | Should -Be '{"a":1}'
      }
    }

    It 'handles braces inside JSON strings' {
      InModuleScope 'NetworkLantern.Throughput' {
        $s = 'banner {"a":"{x}"} trailer'
        Get-JsonSubstringOrNull -Text $s | Should -Be '{"a":"{x}"}'
      }
    }

    It 'returns null when braces exist but no valid JSON' {
      InModuleScope 'NetworkLantern.Throughput' {
        $s = 'prefix {not json} trailer'
        Get-JsonSubstringOrNull -Text $s | Should -Be $null
      }
    }

    It 'returns null when no braces exist' {
      InModuleScope 'NetworkLantern.Throughput' {
        Get-JsonSubstringOrNull -Text 'no json here' | Should -Be $null
      }
    }
  }

  Context 'Metric extraction' {
    It 'extracts TCP metrics (TX)' {
      InModuleScope 'NetworkLantern.Throughput' {
        $json = ConvertFrom-Json '{"end":{"sum_sent":{"bits_per_second":10000000,"retransmits":2},"sum_received":{"bits_per_second":8000000}}}'
        $m = Get-Iperf3Metric -Json $json -Proto TCP -Dir TX
        $m.TxMbps | Should -Be 10.0
        $m.RxMbps | Should -Be 8.0
        $m.Retr | Should -Be 2
        $m.LossPct | Should -Be $null
        $m.JitterMs | Should -Be $null
      }
    }

    It 'extracts UDP metrics (TX)' {
      InModuleScope 'NetworkLantern.Throughput' {
        $json = ConvertFrom-Json '{"end":{"sum_sent":{"bits_per_second":10000000,"lost_percent":2.5},"sum_received":{"bits_per_second":9000000},"sum":{"lost_percent":2.5,"jitter_ms":1.2}}}'
        $m = Get-Iperf3Metric -Json $json -Proto UDP -Dir TX
        $m.TxMbps | Should -Be 10.0
        $m.RxMbps | Should -Be 9.0
        $m.Retr | Should -Be $null
        $m.LossPct | Should -Be 2.5
        $m.JitterMs | Should -Be 1.2
      }
    }
  }

  Context 'CSV row shape' {
    It 'creates a stable column order' {
      InModuleScope 'NetworkLantern.Throughput' {
        $row = ConvertTo-Iperf3CsvRow -No 1 -Proto 'TCP' -Dir 'TX' -DSCP 'CS0' -Streams 1 -Win 'default' `
          -ThrTxMbps 1.23 -RetrTx 0 -ThrRxMbps 0.0 -LossTxPct $null -JitterMs $null -Role 'end'

        $row.PSObject.Properties.Name | Should -Be @(
          'No',
          'Proto',
          'Dir',
          'DSCP',
          'Streams',
          'Win',
          'Thr_TX_Mbps',
          'Retr_TX',
          'Thr_RX_Mbps',
          'Loss_TX_Pct',
          'Jitter_ms',
          'Duration_ms',
          'Role'
        )
      }
    }
  }

  Context 'JSON extraction with apostrophes' {
    It 'correctly parses JSON when text contains apostrophes' {
      InModuleScope 'NetworkLantern.Throughput' {
        $s = "iperf3: error - can't connect to server: {`"error`":`"connection refused`"}"
        $result = Get-JsonSubstringOrNull -Text $s
        $result | Should -Be '{"error":"connection refused"}'
      }
    }

    It 'handles nested braces in JSON values' {
      InModuleScope 'NetworkLantern.Throughput' {
        $s = '{"a":{"b":1}}'
        $result = Get-JsonSubstringOrNull -Text $s
        $result | Should -Be '{"a":{"b":1}}'
      }
    }
  }

  Context 'Build-RunSummary' {
    It 'returns Success for all-pass results' {
      InModuleScope 'NetworkLantern.Throughput' {
        $results = @(
          [pscustomobject]@{ No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 0; JsonParseError = $null; RawText = '' }
          [pscustomobject]@{ No = 2; Proto = 'TCP'; Dir = 'RX'; DSCP = 'CS0'; ExitCode = 0; JsonParseError = $null; RawText = '' }
        )
        $summary = Build-RunSummary -Results $results -TestCount 2 -ParseErrorCount 0 -Target 'x' -Port 5201 -Stack 'IPv4' -Timestamp 'ts' -OutDir '/tmp'
        $summary.Status | Should -Be 'Success'
        $summary.ExitCode | Should -Be 0
        $summary.Counts.Succeeded | Should -Be 2
        $summary.Counts.Failed | Should -Be 0
      }
    }

    It 'returns TotalFailure when all tests fail' {
      InModuleScope 'NetworkLantern.Throughput' {
        $results = @(
          [pscustomobject]@{ No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 1; JsonParseError = 'bad'; RawText = '' }
        )
        $summary = Build-RunSummary -Results $results -TestCount 1 -ParseErrorCount 1 -Target 'x' -Port 5201 -Stack 'IPv4' -Timestamp 'ts' -OutDir '/tmp'
        $summary.Status | Should -Be 'TotalFailure'
        $summary.Counts.Failed | Should -Be 1
      }
    }

    It 'returns PartialFailure for mixed results' {
      InModuleScope 'NetworkLantern.Throughput' {
        $results = @(
          [pscustomobject]@{ No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 0; JsonParseError = $null; RawText = '' }
          [pscustomobject]@{ No = 2; Proto = 'TCP'; Dir = 'RX'; DSCP = 'CS0'; ExitCode = 1; JsonParseError = $null; RawText = 'connection refused' }
        )
        $summary = Build-RunSummary -Results $results -TestCount 2 -ParseErrorCount 0 -Target 'x' -Port 5201 -Stack 'IPv4' -Timestamp 'ts' -OutDir '/tmp'
        $summary.Status | Should -Be 'PartialFailure'
        $summary.Counts.Succeeded | Should -Be 1
        $summary.Counts.Failed | Should -Be 1
      }
    }

    It 'returns TotalFailure for zero tests' {
      InModuleScope 'NetworkLantern.Throughput' {
        $summary = Build-RunSummary -Results @() -TestCount 0 -ParseErrorCount 0 -Target 'x' -Port 5201 -Stack 'IPv4' -Timestamp 'ts' -OutDir '/tmp'
        $summary.Status | Should -Be 'TotalFailure'
      }
    }

    It 'includes timing fields when provided' {
      InModuleScope 'NetworkLantern.Throughput' {
        $summary = Build-RunSummary -Results @() -TestCount 0 -ParseErrorCount 0 -Target 'x' -Port 5201 -Stack 'IPv4' -Timestamp 'ts' -OutDir '/tmp' -StartedUtc '2025-01-01T00:00:00Z' -CompletedUtc '2025-01-01T00:01:00Z' -ElapsedSeconds 60.0 -Iperf3Version 'iperf3 3.9'
        $summary.StartedUtc | Should -Be '2025-01-01T00:00:00Z'
        $summary.CompletedUtc | Should -Be '2025-01-01T00:01:00Z'
        $summary.ElapsedSeconds | Should -Be 60.0
        $summary.SummaryVersion | Should -Be 2
      }
    }

    It 'includes Environment metadata' {
      InModuleScope 'NetworkLantern.Throughput' {
        $summary = Build-RunSummary -Results @() -TestCount 0 -ParseErrorCount 0 -Target 'x' -Port 5201 -Stack 'IPv4' -Timestamp 'ts' -OutDir '/tmp' -Iperf3Version 'iperf3 3.9'
        $summary.Environment | Should -Not -BeNullOrEmpty
        $summary.Environment.Iperf3Version | Should -Be 'iperf3 3.9'
        $summary.Environment.PowerShellVersion | Should -Not -BeNullOrEmpty
      }
    }

    It 'includes FailureBreakdown for partial failures' {
      InModuleScope 'NetworkLantern.Throughput' {
        $results = @(
          [pscustomobject]@{ No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 1; JsonParseError = 'parse error'; RawText = '' }
          [pscustomobject]@{ No = 2; Proto = 'TCP'; Dir = 'RX'; DSCP = 'CS0'; ExitCode = 1; JsonParseError = $null; RawText = 'connection refused' }
          [pscustomobject]@{ No = 3; Proto = 'TCP'; Dir = 'TX'; DSCP = 'EF'; ExitCode = 0; JsonParseError = $null; RawText = '' }
        )
        $summary = Build-RunSummary -Results $results -TestCount 3 -ParseErrorCount 1 -Target 'x' -Port 5201 -Stack 'IPv4' -Timestamp 'ts' -OutDir '/tmp'
        $summary.FailureBreakdown | Should -Not -BeNullOrEmpty
        @($summary.FailureBreakdown).Count | Should -Be 2
      }
    }

    It 'returns TotalFailure when a zero-exit result lacks required metrics' {
      InModuleScope 'NetworkLantern.Throughput' {
        $results = @(
          [pscustomobject]@{
            No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 0
            JsonParseError = $null; MetricError = 'required throughput metrics missing'; RawText = ''
          }
        )

        $summary = Build-RunSummary -Results $results -TestCount 1 -ParseErrorCount 0 -Target 'x' -Port 5201 -Stack 'IPv4' -Timestamp 'ts' -OutDir '/tmp'

        $summary.Status | Should -Be 'TotalFailure'
        $summary.Counts.Failed | Should -Be 1
        $summary.FailureBreakdown[0].Reason | Should -Be 'required throughput metrics missing'
      }
    }
  }

  Context 'CSV row includes Duration_ms column' {
    It 'adds Duration_ms to CSV row' {
      InModuleScope 'NetworkLantern.Throughput' {
        $row = ConvertTo-Iperf3CsvRow -No 1 -Proto 'TCP' -Dir 'TX' -DSCP 'CS0' -Streams 1 -Win 'default' `
          -ThrTxMbps 1.23 -RetrTx 0 -ThrRxMbps 0.0 -LossTxPct $null -JitterMs $null -DurationMs 5200 -Role 'end'
        $row.PSObject.Properties.Name | Should -Contain 'Duration_ms'
        $row.Duration_ms | Should -Be 5200
      }
    }
  }

  Context 'Threshold evaluation in Build-RunSummary' {
    It 'returns Success when no thresholds are configured' {
      InModuleScope 'NetworkLantern.Throughput' {
        $results = @(
          [pscustomobject]@{ No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 0; JsonParseError = $null; RawText = ''; Metrics = [pscustomobject]@{ TxMbps = 100; RxMbps = 90; Retr = 0; LossPct = $null; JitterMs = $null } }
        )
        $summary = Build-RunSummary -Results $results -TestCount 1 -ParseErrorCount 0 -Target 'x' -Port 5201 -Stack 'IPv4' -Timestamp 'ts' -OutDir '/tmp'
        $summary.Status | Should -Be 'Success'
        $summary.ThresholdBreachCount | Should -Be 0
      }
    }

    It 'detects throughput below threshold' {
      InModuleScope 'NetworkLantern.Throughput' {
        $results = @(
          [pscustomobject]@{ No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 0; JsonParseError = $null; RawText = ''; Metrics = [pscustomobject]@{ TxMbps = 50; RxMbps = 40; Retr = 0; LossPct = $null; JitterMs = $null } }
        )
        $summary = Build-RunSummary -Results $results -TestCount 1 -ParseErrorCount 0 -Target 'x' -Port 5201 -Stack 'IPv4' -Timestamp 'ts' -OutDir '/tmp' -ThresholdMinThroughputMbps 100.0
        $summary.Status | Should -Be 'PartialFailure'
        $summary.ThresholdBreachCount | Should -BeGreaterThan 0
        $summary.ThresholdBreaches[0].Reasons | Should -Not -BeNullOrEmpty
      }
    }

    It 'detects loss above threshold' {
      InModuleScope 'NetworkLantern.Throughput' {
        $results = @(
          [pscustomobject]@{ No = 1; Proto = 'UDP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 0; JsonParseError = $null; RawText = ''; Metrics = [pscustomobject]@{ TxMbps = 100; RxMbps = 90; Retr = $null; LossPct = 5.5; JitterMs = 1.0 } }
        )
        $summary = Build-RunSummary -Results $results -TestCount 1 -ParseErrorCount 0 -Target 'x' -Port 5201 -Stack 'IPv4' -Timestamp 'ts' -OutDir '/tmp' -ThresholdMaxLossPct 2.0
        $summary.Status | Should -Be 'PartialFailure'
        $summary.ThresholdBreachCount | Should -Be 1
      }
    }

    It 'passes when metrics are within thresholds' {
      InModuleScope 'NetworkLantern.Throughput' {
        $results = @(
          [pscustomobject]@{ No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 0; JsonParseError = $null; RawText = ''; Metrics = [pscustomobject]@{ TxMbps = 500; RxMbps = 480; Retr = 0; LossPct = $null; JitterMs = $null } }
        )
        $summary = Build-RunSummary -Results $results -TestCount 1 -ParseErrorCount 0 -Target 'x' -Port 5201 -Stack 'IPv4' -Timestamp 'ts' -OutDir '/tmp' -ThresholdMinThroughputMbps 100.0
        $summary.Status | Should -Be 'Success'
        $summary.ThresholdBreachCount | Should -Be 0
      }
    }

    It 'validates threshold config parameters' {
      InModuleScope 'NetworkLantern.Throughput' {
        ConvertTo-Iperf3KnownValue -Key 'ThresholdMinThroughputMbps' -Value 100 | Should -Be 100.0
        ConvertTo-Iperf3KnownValue -Key 'ThresholdMaxLossPct' -Value 2.5 | Should -Be 2.5
        ConvertTo-Iperf3KnownValue -Key 'ThresholdMaxJitterMs' -Value 10 | Should -Be 10.0
      }
    }
  }

  Context 'Get-BitsPerSecondMbps' {
    It 'extracts Mbps from valid object' {
      InModuleScope 'NetworkLantern.Throughput' {
        $obj = [pscustomobject]@{ bits_per_second = 10000000 }
        Get-BitsPerSecondMbps -Obj $obj | Should -Be 10.0
      }
    }

    It 'returns null for null object' {
      InModuleScope 'NetworkLantern.Throughput' {
        Get-BitsPerSecondMbps -Obj $null | Should -Be $null
      }
    }

    It 'returns null when property is missing' {
      InModuleScope 'NetworkLantern.Throughput' {
        $obj = [pscustomobject]@{ other = 123 }
        Get-BitsPerSecondMbps -Obj $obj | Should -Be $null
      }
    }
  }

  Context 'Write-Iperf3SupplementalReports' {
    It 'creates summary JSON and Markdown report files' {
      InModuleScope 'NetworkLantern.Throughput' {
        $summary = [pscustomobject]@{
          SummaryVersion = 2; Timestamp = 'ts'; StartedUtc = ''; CompletedUtc = ''; ElapsedSeconds = 1
          OutDir = $TestDrive; Target = 'x'; Port = 5201; Stack = 'IPv4'
          Status = 'Success'; ExitCode = 0
          Counts = [pscustomobject]@{ Total = 1; Succeeded = 1; Failed = 0; ParseErrors = 0 }
          Environment = [pscustomobject]@{ Iperf3Version = 'test'; PowerShellVersion = '7'; OS = 'test' }
          FailureBreakdown = @(); ThresholdBreaches = @(); ThresholdBreachCount = 0
          TopFailures = @()
          Supplemental = [pscustomobject]@{ SummaryJsonPath = $null; ReportMdPath = $null; RunIndexPath = $null }
        }
        $result = Write-Iperf3SupplementalReports -RunSummary $summary -OutDir $TestDrive -Timestamp 'test_ts'
        (Test-Path -LiteralPath $result.SummaryJsonPath) | Should -Be $true
        (Test-Path -LiteralPath $result.ReportMdPath) | Should -Be $true
        $md = Get-Content -LiteralPath $result.ReportMdPath -Raw
        $md | Should -Match '# iperf3 Test Run Report'
        $md | Should -Match 'Status: Success'
      }
    }
  }

  Context 'Write-Iperf3RunIndex' {
    It 'creates a valid JSON index file' {
      InModuleScope 'NetworkLantern.Throughput' {
        $summary = [pscustomobject]@{
          Timestamp = 'ts'; Status = 'Success'; ExitCode = 0
          Target = 'x'; Port = 5201; Stack = 'IPv4'
        }
        $indexPath = Write-Iperf3RunIndex -OutDir $TestDrive -RunSummary $summary -CsvPath '/csv' -JsonPath '/json' -SummaryJsonPath '/summary' -ReportMdPath '/report'
        (Test-Path -LiteralPath $indexPath) | Should -Be $true
        $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
        $index.schemaVersion | Should -Be 2
        $index.lastRun.status | Should -Be 'Success'
      }
    }
  }

  Context 'Write-FinalOutputs artifact contract' {
    It 'persists the finalized summary returned to the caller' {
      InModuleScope 'NetworkLantern.Throughput' {
        $outDir = Join-Path $TestDrive 'finalized-summary'
        $null = New-Item -ItemType Directory -Path $outDir -Force
        $csvRows = [System.Collections.Generic.List[object]]::new()
        $allResults = [System.Collections.Generic.List[object]]::new()
        $csvRows.Add([pscustomobject]@{ No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; Thr_TX_Mbps = 100 }) | Out-Null
        $allResults.Add([pscustomobject]@{
            No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 0
            JsonParseError = $null; MetricError = $null; RawText = ''
            Metrics = [pscustomobject]@{ TxMbps = 100; RxMbps = $null; Retr = 0; LossPct = $null; JitterMs = $null }
          }) | Out-Null
        $final = [pscustomobject]@{ Target = 'x'; Port = 5201; Stack = 'IPv4' }

        $result = Write-FinalOutputs `
          -CsvRowsList $csvRows `
          -AllResultsList $allResults `
          -CsvPath (Join-Path $outDir 'out.csv') `
          -JsonPath (Join-Path $outDir 'out.json') `
          -FinalResultObject $final `
          -OutDir $outDir `
          -Timestamp 'artifact_success'

        $persisted = Get-Content -LiteralPath $result.SummaryJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $persisted.ArtifactStatus.Complete | Should -BeTrue
        @($persisted.ArtifactStatus.PSObject.Properties.Value | Where-Object { $_ -is [string] -and $_ -eq 'Pending' }) |
          Should -BeNullOrEmpty
        $persisted.Supplemental.SummaryJsonPath | Should -Be $result.SummaryJsonPath
        $persisted.Supplemental.ReportMdPath | Should -Be $result.ReportMdPath
        $persisted.Supplemental.RunIndexPath | Should -Be $result.RunIndexPath
        ($persisted | ConvertTo-Json -Depth 10 -Compress) |
          Should -Be ($result.RunSummary | ConvertTo-Json -Depth 10 -Compress)
      }
    }

    It 'exposes artifact warnings without changing successful measurement status' {
      InModuleScope 'NetworkLantern.Throughput' {
        $csvRows = [System.Collections.Generic.List[object]]::new()
        $allResults = [System.Collections.Generic.List[object]]::new()
        $csvRows.Add([pscustomobject]@{ No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; Thr_TX_Mbps = 100 }) | Out-Null
        $allResults.Add([pscustomobject]@{
            No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 0
            JsonParseError = $null; MetricError = $null; RawText = ''
            Metrics = [pscustomobject]@{ TxMbps = 100; RxMbps = $null; Retr = 0; LossPct = $null; JitterMs = $null }
          }) | Out-Null
        $final = [pscustomobject]@{ Target = 'x'; Port = 5201; Stack = 'IPv4' }
        Mock -CommandName Set-Content { throw 'disk full' }

        $result = Write-FinalOutputs `
          -CsvRowsList $csvRows `
          -AllResultsList $allResults `
          -CsvPath (Join-Path $TestDrive 'out.csv') `
          -JsonPath (Join-Path $TestDrive 'out.json') `
          -FinalResultObject $final `
          -OutDir $TestDrive `
          -Timestamp 'artifact_fail'

        $result.RunSummary.Status | Should -Be 'Success'
        $result.RunSummary.ArtifactStatus.Complete | Should -BeFalse
        $result.RunSummary.ArtifactStatus.Json | Should -Be 'Warn'
        $result.RunSummary.ArtifactStatus.SummaryJson | Should -Be 'Warn'
        $result.RunSummary.ArtifactStatus.ReportMd | Should -Be 'Warn'
        $result.RunSummary.ArtifactStatus.RunIndex | Should -Be 'Warn'
      }
    }

    It 'does not persist a summary path when only the final summary write fails' {
      InModuleScope 'NetworkLantern.Throughput' {
        $outDir = Join-Path $TestDrive 'summary-write-failure'
        $null = New-Item -ItemType Directory -Path $outDir -Force
        $timestamp = 'summary_blocked'
        $blockedSummaryPath = Join-Path $outDir "iperf3_summary_$timestamp.json"
        $null = New-Item -ItemType Directory -Path $blockedSummaryPath
        $csvRows = [System.Collections.Generic.List[object]]::new()
        $allResults = [System.Collections.Generic.List[object]]::new()
        $csvRows.Add([pscustomobject]@{ No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; Thr_TX_Mbps = 100 }) | Out-Null
        $allResults.Add([pscustomobject]@{
            No = 1; Proto = 'TCP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 0
            JsonParseError = $null; MetricError = $null; RawText = ''
            Metrics = [pscustomobject]@{ TxMbps = 100; RxMbps = $null; Retr = 0; LossPct = $null; JitterMs = $null }
          }) | Out-Null
        $final = [pscustomobject]@{ Target = 'x'; Port = 5201; Stack = 'IPv4' }

        $result = Write-FinalOutputs `
          -CsvRowsList $csvRows `
          -AllResultsList $allResults `
          -CsvPath (Join-Path $outDir 'out.csv') `
          -JsonPath (Join-Path $outDir 'out.json') `
          -FinalResultObject $final `
          -OutDir $outDir `
          -Timestamp $timestamp

        $result.SummaryJsonPath | Should -BeNullOrEmpty
        $result.RunSummary.Supplemental.SummaryJsonPath | Should -BeNullOrEmpty
        $result.RunSummary.ArtifactStatus.SummaryJson | Should -Be 'Warn'
        (Test-Path -LiteralPath $blockedSummaryPath -PathType Leaf) | Should -BeFalse
        (Test-Path -LiteralPath $result.ReportMdPath -PathType Leaf) | Should -BeTrue
        (Get-Content -LiteralPath $result.ReportMdPath -Raw) | Should -Match 'Summary JSON: not available'
        $index = Get-Content -LiteralPath $result.RunIndexPath -Raw | ConvertFrom-Json
        $index.lastRun.summaryJsonPath | Should -BeNullOrEmpty
      }
    }
  }

  Context 'Write-Iperf3RunIndex history tracking' {
    It 'creates index with runs array' {
      InModuleScope 'NetworkLantern.Throughput' {
        $summary = [pscustomobject]@{
          Timestamp = 'ts1'; Status = 'Success'; ExitCode = 0
          Target = 'x'; Port = 5201; Stack = 'IPv4'
        }
        $indexPath = Write-Iperf3RunIndex -OutDir $TestDrive -RunSummary $summary -CsvPath '/csv' -JsonPath '/json' -SummaryJsonPath '/s' -ReportMdPath '/r'
        $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
        $index.schemaVersion | Should -Be 2
        $index.lastRun.timestamp | Should -Be 'ts1'
        @($index.runs).Count | Should -Be 1
      }
    }

    It 'appends to existing run history' {
      InModuleScope 'NetworkLantern.Throughput' {
        $histDir = Join-Path $TestDrive 'history-append'
        New-Item -ItemType Directory -Path $histDir -Force | Out-Null
        $summary1 = [pscustomobject]@{ Timestamp = 'ts1'; Status = 'Success'; ExitCode = 0; Target = 'x'; Port = 5201; Stack = 'IPv4' }
        $summary2 = [pscustomobject]@{ Timestamp = 'ts2'; Status = 'PartialFailure'; ExitCode = 14; Target = 'x'; Port = 5201; Stack = 'IPv4' }
        $null = Write-Iperf3RunIndex -OutDir $histDir -RunSummary $summary1 -CsvPath '/csv1' -JsonPath '/json1' -SummaryJsonPath '/s1' -ReportMdPath '/r1'
        $indexPath = Write-Iperf3RunIndex -OutDir $histDir -RunSummary $summary2 -CsvPath '/csv2' -JsonPath '/json2' -SummaryJsonPath '/s2' -ReportMdPath '/r2'
        $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
        @($index.runs).Count | Should -Be 2
        $index.lastRun.timestamp | Should -Be 'ts2'
        $index.runs[0].timestamp | Should -Be 'ts1'
        $index.runs[1].timestamp | Should -Be 'ts2'
      }
    }

    It 'retains every entry from concurrent writers' {
      $historyDir = Join-Path $TestDrive 'history-concurrent'
      $readyDir = Join-Path $historyDir 'ready'
      $gatePath = Join-Path $historyDir 'start.gate'
      $modulePathForJobs = Join-Path $script:RepoRoot 'src/powershell/throughput/NetworkLantern.Throughput.psd1'
      $writerCount = 8
      $null = New-Item -ItemType Directory -Path $readyDir -Force
      $writer = {
        param($modulePath, $outDir, $timestamp, $readyPath, $gate)
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
        & (Get-Module 'NetworkLantern.Throughput') {
          param($targetDir, $stamp)
          $summary = [pscustomobject]@{
            Timestamp = $stamp; Status = 'Success'; ExitCode = 0
            Target = 'x'; Port = 5201; Stack = 'IPv4'
          }
          Write-Iperf3RunIndex -OutDir $targetDir -RunSummary $summary `
            -CsvPath "/$stamp.csv" -JsonPath "/$stamp.json" -SummaryJsonPath $null -ReportMdPath $null
        } $outDir $timestamp
      }
      $jobs = @()
      try {
        foreach ($number in 1..$writerCount) {
          $jobs += Start-Job -ScriptBlock $writer -ArgumentList @(
            $modulePathForJobs,
            $historyDir,
            "concurrent-$number",
            (Join-Path $readyDir "$number.ready"),
            $gatePath
          )
        }

        $readyWait = [System.Diagnostics.Stopwatch]::StartNew()
        while (@(Get-ChildItem -LiteralPath $readyDir -Filter '*.ready' -ErrorAction SilentlyContinue).Count -lt $writerCount) {
          if ($readyWait.Elapsed.TotalSeconds -gt 20) { throw 'Concurrent run-index writers did not become ready.' }
          Start-Sleep -Milliseconds 20
        }
        Set-Content -LiteralPath $gatePath -Value ([datetime]::UtcNow.AddMilliseconds(500).Ticks) -NoNewline
        $null = $jobs | Wait-Job -Timeout 20
        foreach ($job in $jobs) {
          $job.State | Should -Be 'Completed'
          $null = Receive-Job -Job $job -ErrorAction Stop
        }
      }
      finally {
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
      }

      $index = Get-Content -LiteralPath (Join-Path $historyDir 'iperf3_run_index.json') -Raw | ConvertFrom-Json
      $timestamps = @($index.runs | ForEach-Object { $_.timestamp } | Sort-Object)
      $timestamps.Count | Should -Be $writerCount
      $timestamps | Should -Be @(1..$writerCount | ForEach-Object { "concurrent-$_" } | Sort-Object)
    }

  }

  Context 'Compare-Iperf3Runs' {
    It 'produces delta object from two summary files' {
      $baseline = [pscustomobject]@{
        Timestamp = 'ts1'; Status = 'Success'; ElapsedSeconds = 30
        Counts = [pscustomobject]@{ Total = 10; Succeeded = 10; Failed = 0; ParseErrors = 0 }
      }
      $current = [pscustomobject]@{
        Timestamp = 'ts2'; Status = 'PartialFailure'; ElapsedSeconds = 35
        Counts = [pscustomobject]@{ Total = 10; Succeeded = 8; Failed = 2; ParseErrors = 0 }
      }
      $bPath = Join-Path $TestDrive 'baseline.json'
      $cPath = Join-Path $TestDrive 'current.json'
      $baseline | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $bPath -Encoding UTF8
      $current | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cPath -Encoding UTF8

      $delta = Compare-Iperf3Runs -BaselinePath $bPath -CurrentPath $cPath
      $delta.StatusChanged | Should -Be $true
      $delta.BaselineStatus | Should -Be 'Success'
      $delta.CurrentStatus | Should -Be 'PartialFailure'
      $delta.FailedDelta | Should -Be 2
      $delta.TotalDelta | Should -Be 0
    }

    It 'throws when baseline file is missing' {
      { Compare-Iperf3Runs -BaselinePath '/nonexistent.json' -CurrentPath '/also-missing.json' } | Should -Throw '*not found*'
    }
  }
}
