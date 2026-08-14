#!/usr/bin/env bats
load test_helper

setup() {
  source "$PROJECT_ROOT/src/bash/path/lib/logging.sh"
  TEST_LOG_DIR=$(mktemp -d)
  SUMMARY_JSON="$TEST_LOG_DIR/summary.json"
  TABLE_LOG=""
}

teardown() {
  rm -rf "$TEST_LOG_DIR"
}

write_empty_summary() {
  printf '%s\n' '{"report":{"dst_name":"target.example","dst_addr":"192.0.2.10","hubs":[]}}' >"$SUMMARY_JSON"
}

@test "summarize_json renders an empty summary to stdout" {
  write_empty_summary

  run summarize_json "$SUMMARY_JSON"

  assert_success
  [ "$output" = $'\nResults for: target.example (192.0.2.10)\nHop\tHost\tIP\tLoss%\tSnt\tLast\tAvg\tBest\tWrst\tStDev\n(No results)' ]
}

@test "summarize_json appends to TABLE_LOG without stdout output" {
  write_empty_summary
  TABLE_LOG="$TEST_LOG_DIR/table.log"
  : >"$TABLE_LOG"

  run summarize_json "$SUMMARY_JSON"

  assert_success
  [ -z "$output" ]
  [ "$(cat "$TABLE_LOG")" = $'\nResults for: target.example (192.0.2.10)\nHop\tHost\tIP\tLoss%\tSnt\tLast\tAvg\tBest\tWrst\tStDev\n(No results)' ]
}

@test "summarize_json returns jq failure status for malformed JSON" {
  printf '{not JSON}\n' >"$SUMMARY_JSON"

  run summarize_json "$SUMMARY_JSON"

  assert_failure
}
