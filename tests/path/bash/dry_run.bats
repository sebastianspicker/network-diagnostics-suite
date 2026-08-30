#!/usr/bin/env bats

load test_helper.bash

setup() {
  setup_path_app
}

@test "dry-run produces a plan without creating the requested output tree" {
  local output_root="$BATS_TEST_TMPDIR/requested-output"
  local before after
  before=$(find "$BATS_TEST_TMPDIR" -print | sort)

  run_path_app \
    --log-dir "$output_root/logs" \
    --json-log "$output_root/results.json" \
    --table-log "$output_root/summary.log" \
    --types ICMP4 \
    --rounds Standard \
    --hosts4 dry-run.example \
    --dry-run \
    --no-summary

  [ "$status" -eq 0 ]
  after=$(find "$BATS_TEST_TMPDIR" -print | sort)
  [ "$before" = "$after" ]
  [[ "$output" == *"Would write JSON_LOG=$output_root/results.json"* ]]
}
