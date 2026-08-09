#!/usr/bin/env bats
load test_helper

@test "directly invoked Unix entrypoints exist and are executable" {
  local entrypoint

  for entrypoint in \
    "$PATH_APP" \
    "$PROJECT_ROOT/scripts/ci-local.sh" \
    "$PROJECT_ROOT/scripts/install-test-deps.sh" \
    "$PROJECT_ROOT/scripts/run-workflow.sh"; do
    [ -x "$entrypoint" ]
  done
}

@test "dry-run exits 0" {
  run bash "$PATH_APP" --dry-run --no-summary
  assert_success
}

@test "--list-types prints test types" {
  run bash "$PATH_APP" --list-types
  assert_success
  assert_output --partial "ICMP4"
}

@test "--list-rounds prints rounds" {
  run bash "$PATH_APP" --list-rounds
  assert_success
  assert_output --partial "Standard"
}

@test "--version prints version" {
  run bash "$PATH_APP" --version
  assert_success
  assert_output --partial "v1.1.0"
}

@test "--help shows usage" {
  run bash "$PATH_APP" --help
  assert_success
  assert_output --partial "Usage"
}
