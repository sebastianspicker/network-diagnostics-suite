#!/usr/bin/env bats
load test_helper

@test "default dry-run exits 0" {
  run bash "$PATH_APP" --dry-run --no-summary
  assert_success
}

@test "default dry-run shows planned run count" {
  run bash "$PATH_APP" --dry-run --no-summary
  assert_success
  assert_output --partial "Planned runs: 14"
}

@test "filtered single type and round" {
  run bash "$PATH_APP" --types ICMP4 --rounds Standard --hosts4 localhost --dry-run --no-summary
  assert_success
  assert_output --partial "Planned runs: 1"
}

@test "multiple types can be combined" {
  run bash "$PATH_APP" --types ICMP4,TCP4 --rounds Standard --hosts4 localhost --dry-run --no-summary
  assert_success
  assert_output --partial "Planned runs: 2"
}

@test "all 10 test types listed" {
  run bash "$PATH_APP" --list-types
  assert_success
  assert_output --partial "ICMP4"
  assert_output --partial "ICMP6"
  assert_output --partial "UDP4"
  assert_output --partial "UDP6"
  assert_output --partial "TCP4"
  assert_output --partial "TCP6"
  assert_output --partial "MPLS4"
  assert_output --partial "MPLS6"
  assert_output --partial "AS4"
  assert_output --partial "AS6"
}

@test "all 8 rounds listed" {
  run bash "$PATH_APP" --list-rounds
  assert_success
  assert_output --partial "Standard"
  assert_output --partial "MTU1400"
  assert_output --partial "TOS_CS5"
  assert_output --partial "TOS_AF11"
  assert_output --partial "TTL10"
  assert_output --partial "TTL64"
  assert_output --partial "FirstTTL3"
  assert_output --partial "Timeout5"
}

@test "invalid type is rejected" {
  run bash "$PATH_APP" --types INVALID --dry-run
  assert_failure
  assert_output --partial "Unknown test type"
}

@test "invalid round is rejected" {
  run bash "$PATH_APP" --rounds INVALID --dry-run
  assert_failure
  assert_output --partial "Unknown round"
}

@test "empty type CSV is rejected" {
  run bash "$PATH_APP" --types "" --dry-run --no-summary
  assert_failure
  assert_output --partial "--types requires a non-empty CSV argument"
}

@test "empty round CSV is rejected" {
  run bash "$PATH_APP" --rounds "" --dry-run --no-summary
  assert_failure
  assert_output --partial "--rounds requires a non-empty CSV argument"
}

@test "empty hosts4 CSV is rejected" {
  run bash "$PATH_APP" --hosts4 "" --dry-run --no-summary
  assert_failure
  assert_output --partial "--hosts4 requires a non-empty CSV argument"
}

@test "empty hosts6 CSV is rejected" {
  run bash "$PATH_APP" --hosts6 "" --dry-run --no-summary
  assert_failure
  assert_output --partial "--hosts6 requires a non-empty CSV argument"
}

@test "explicit full matrix remains available" {
  run bash "$PATH_APP" --types ICMP4,ICMP6,UDP4,UDP6,TCP4,TCP6,MPLS4,MPLS6,AS4,AS6 --rounds Standard,MTU1400,TOS_CS5,TOS_AF11,TTL10,TTL64,FirstTTL3,Timeout5 --dry-run --no-summary
  assert_success
  assert_output --partial "Planned runs: 280"
}

@test "unknown argument is rejected" {
  run bash "$PATH_APP" --bogus
  assert_failure
  assert_output --partial "Unknown argument"
}

@test "version flag works" {
  run bash "$PATH_APP" --version
  assert_success
  assert_output --partial "v1.1.0"
}

@test "dry-run log filenames include PID" {
  run bash "$PATH_APP" --dry-run --no-summary
  assert_success
  assert_output --regexp "mtr_results_[0-9]{8}_[0-9]{6}_[0-9]+\.json\.log"
}

@test "dry-run reports explicit JSON and table log paths without creating them" {
  local json_log="$BATS_TEST_TMPDIR/results.json.log"
  local table_log="$BATS_TEST_TMPDIR/summary.log"

  run bash "$PATH_APP" --dry-run --no-summary --json-log "$json_log" --table-log "$table_log"

  assert_success
  assert_output --partial "Would write JSON_LOG=$json_log"
  assert_output --partial "Would write TABLE_LOG=$table_log"
  [ ! -e "$json_log" ]
  [ ! -e "$table_log" ]
}

@test "quiet dry-run suppresses informational planning output" {
  run bash "$PATH_APP" --dry-run --no-summary --quiet

  assert_success
  assert_output --partial "Dry-run complete. Planned runs: 14"
  [[ "$output" != *"Starting MTR tests"* ]]
  [[ "$output" != *"RUN ["* ]]
}

@test "custom hosts4 override in dry-run" {
  run bash "$PATH_APP" --types ICMP4 --rounds Standard --hosts4 custom.example.com --dry-run --no-summary
  assert_success
  assert_output --partial "custom.example.com"
  assert_output --partial "Planned runs: 1"
}

@test "custom hosts6 override in dry-run" {
  run bash "$PATH_APP" --types ICMP6 --rounds Standard --hosts6 v6.example.com --dry-run --no-summary
  assert_success
  assert_output --partial "v6.example.com"
  assert_output --partial "Planned runs: 1"
}

@test "combination types x rounds x hosts" {
  run bash "$PATH_APP" --types ICMP4,TCP4 --rounds Standard,TTL64 --hosts4 localhost --dry-run --no-summary
  assert_success
  assert_output --partial "Planned runs: 4"
}

@test "all 8 rounds with single type and host" {
  run bash "$PATH_APP" --types ICMP4 --rounds Standard,MTU1400,TOS_CS5,TOS_AF11,TTL10,TTL64,FirstTTL3,Timeout5 --hosts4 localhost --dry-run --no-summary
  assert_success
  assert_output --partial "Planned runs: 8"
}

@test "malicious hostname is rejected" {
  run bash "$PATH_APP" --hosts4 "host;evil" --dry-run
  assert_failure
}

@test "path traversal in log-dir is rejected" {
  run bash "$PATH_APP" --log-dir ".." --dry-run
  assert_failure
}

@test "non-positive MTR timeout is rejected" {
  run env MTR_TIMEOUT_SECONDS=0 bash "$PATH_APP" --dry-run --no-summary
  assert_failure
  assert_output --partial "MTR_TIMEOUT_SECONDS must be a positive integer"
}
