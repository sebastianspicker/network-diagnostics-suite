#!/usr/bin/env bats

load test_helper.bash

setup() {
  setup_path_app
}

@test "timeout sends TERM before completing as a failed run" {
  install_fake_mtr mtr-timeout
  local json_log="$BATS_TEST_TMPDIR/results.json"
  export MTR_SIGNAL_FILE="$BATS_TEST_TMPDIR/mtr-signal"

  export MTR_TIMEOUT_SECONDS=1
  run_path_app --json-log "$json_log" --table-log "$BATS_TEST_TMPDIR/summary.log" --types ICMP4 --rounds Standard --hosts4 timeout.example --no-summary

  [ "$status" -eq 1 ]
  [ "$(<"$MTR_SIGNAL_FILE")" = "TERM" ]
  [ "$(jq -sr '.[0]._failed' "$json_log")" = "true" ]
  [[ "$output" == *"timeout after 1s"* ]]
}

@test "TERM interrupts a running path command with status 143" {
  install_fake_mtr mtr-timeout
  local output_file="$BATS_TEST_TMPDIR/term-output"
  local json_log="$BATS_TEST_TMPDIR/results.json"

  bash -c 'trap - INT; exec bash "$@"' bash "$PATH_APP" --json-log "$json_log" --table-log "$BATS_TEST_TMPDIR/summary.log" --types ICMP4 --rounds Standard --hosts4 signal.example --no-summary >"$output_file" 2>&1 &
  local app_pid=$!
  sleep 0.3
  kill -TERM "$app_pid"
  local app_status=0
  wait "$app_pid" || app_status=$?

  [ "$app_status" -eq 143 ]
  [[ "$(<"$output_file")" == *"Interrupted (SIGTERM)"* ]]
}

@test "INT cleanup trap exits with status 130" {
  local loader="$BATS_TEST_DIRNAME/../../../src/bash/path/load.sh"

  run bash -c 'source "$1"; path_install_cleanup_traps; kill -INT "$$"; printf unreachable' bash "$loader"

  [ "$status" -eq 130 ]
  [[ "$output" == *"Interrupted (SIGINT)"* ]]
}
