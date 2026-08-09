#!/usr/bin/env bats
load test_helper

setup() {
  source "$PROJECT_ROOT/src/bash/path/lib/runner.sh"
  TEST_RUN_DIR=$(mktemp -d)
  JSON_LOG="$TEST_RUN_DIR/results.json.log"
  TABLE_LOG="$TEST_RUN_DIR/table.log"
  : >"$JSON_LOG"
  : >"$TABLE_LOG"
  TOTAL_RUNS=1
  DRY_RUN=0
  DO_SUMMARY=0
  RUN_OK=0
  RUN_FAIL=0
  CURRENT_TMP=""
  # shellcheck disable=SC2034
  CURRENT_MTR_PID=""
  MTR_TIMEOUT_SECONDS=5
}

teardown() {
  rm -rf "$TEST_RUN_DIR"
}

@test "failed mtr output keeps JSON log parseable" {
  # shellcheck disable=SC2329
  mtr() {
    printf 'not json\nsecond line\n'
    return 1
  }

  execute_single_run "Standard" "ICMP4" "example.com" 1

  [ "$RUN_FAIL" -eq 1 ]
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" | jq -e . >/dev/null
  done <"$JSON_LOG"
}

@test "successful mtr with invalid JSON is recorded as failed" {
  # shellcheck disable=SC2329
  mtr() {
    printf 'not json\n'
    return 0
  }

  execute_single_run "Standard" "ICMP4" "example.com" 1

  [ "$RUN_OK" -eq 0 ]
  [ "$RUN_FAIL" -eq 1 ]
  jq -e '._failed == true' "$JSON_LOG" >/dev/null
}

@test "successful mtr appends one JSON object and clears run state" {
  # shellcheck disable=SC2329
  mtr() {
    printf '{"report":{"dst_name":"example.com"}}'
  }

  execute_single_run "Standard" "ICMP4" "example.com" 1

  [ "$RUN_OK" -eq 1 ]
  [ "$RUN_FAIL" -eq 0 ]
  [ "$(wc -l <"$JSON_LOG")" -eq 1 ]
  jq -e '.report.dst_name == "example.com"' "$JSON_LOG" >/dev/null
  [ -z "$CURRENT_TMP" ]
  [ -z "$CURRENT_MTR_PID" ]
}

@test "summary failure does not fail a valid mtr run" {
  DO_SUMMARY=1
  # shellcheck disable=SC2329
  mtr() {
    printf '{"report":{}}\n'
  }
  # shellcheck disable=SC2329
  summarize_json() {
    return 1
  }

  execute_single_run "Standard" "ICMP4" "example.com" 1

  [ "$RUN_OK" -eq 1 ]
  [ "$RUN_FAIL" -eq 0 ]
  grep -F 'summary failed for round=Standard type=ICMP4 host=example.com' "$TABLE_LOG"
}

@test "non-timeout mtr failures preserve the exit status in the log" {
  # shellcheck disable=SC2329
  mtr() {
    printf 'mtr diagnostic output\n'
    return 7
  }

  execute_single_run "Standard" "ICMP4" "example.com" 1

  [ "$RUN_OK" -eq 0 ]
  [ "$RUN_FAIL" -eq 1 ]
  jq -e '._failed == true and .raw_output == "mtr diagnostic output"' "$JSON_LOG" >/dev/null
  grep -F 'round=Standard type=ICMP4 host=example.com (exit=7)' "$TABLE_LOG"
  [ -z "$CURRENT_TMP" ]
  [ -z "$CURRENT_MTR_PID" ]
}

@test "hung mtr is terminated at the per-run deadline" {
  MTR_TIMEOUT_SECONDS=1
  # shellcheck disable=SC2329
  mtr() {
    while :; do :; done
  }

  execute_single_run "Standard" "ICMP4" "example.com" 1

  [ "$RUN_OK" -eq 0 ]
  [ "$RUN_FAIL" -eq 1 ]
  jq -e '._failed == true' "$JSON_LOG" >/dev/null
}
