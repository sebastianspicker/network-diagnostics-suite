#!/usr/bin/env bats

load test_helper.bash

setup() {
  setup_path_app
}

@test "streams one valid MTR JSON object per line and reports success" {
  install_fake_mtr mtr-valid
  local json_log="$BATS_TEST_TMPDIR/results.json"
  local table_log="$BATS_TEST_TMPDIR/summary.log"

  run_path_app --json-log "$json_log" --table-log "$table_log" --types ICMP4 --rounds Standard --hosts4 fixture.example --no-summary

  [ "$status" -eq 0 ]
  [ "$(jq -s 'length == 1 and (.[0] | type == "object")' "$json_log")" = "true" ]
  [ "$(jq -sr '.[0].report.dst_name' "$json_log")" = "fixture.example" ]
  [[ "$output" == *"Passed: 1, Failed: 0"* ]]
}

@test "writes an explicit failure marker for invalid MTR JSON" {
  install_fake_mtr mtr-invalid
  local json_log="$BATS_TEST_TMPDIR/results.json"

  run_path_app --json-log "$json_log" --table-log "$BATS_TEST_TMPDIR/summary.log" --types ICMP4 --rounds Standard --hosts4 fixture.example --no-summary

  [ "$status" -eq 1 ]
  [ "$(jq -sr '.[0]._failed' "$json_log")" = "true" ]
  [ "$(jq -sr '.[0].host' "$json_log")" = "fixture.example" ]
  [[ "$output" == *"invalid JSON output"* ]]
}

@test "writes an explicit failure marker when MTR exits unsuccessfully" {
  install_fake_mtr mtr-fail
  local json_log="$BATS_TEST_TMPDIR/results.json"

  run_path_app --json-log "$json_log" --table-log "$BATS_TEST_TMPDIR/summary.log" --types ICMP4 --rounds Standard --hosts4 fixture.example --no-summary

  [ "$status" -eq 1 ]
  [ "$(jq -sr '.[0]._failed' "$json_log")" = "true" ]
  [ "$(jq -sr '.[0].raw_output' "$json_log")" = '{"error":"fixture failure"}' ]
  [[ "$output" == *"exit=7"* ]]
}
