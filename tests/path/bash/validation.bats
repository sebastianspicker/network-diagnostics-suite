#!/usr/bin/env bats

load test_helper.bash

setup() {
  setup_path_app
}

@test "rejects unsafe hosts, unsafe log paths, and malformed CSV" {
  run_path_app --types ICMP4 --hosts4 'host;command' --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Host name must not contain ';'"* ]]

  run_path_app --log-dir ../unsafe --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"path traversal"* ]]

  run_path_app --types ICMP4,,TCP4 --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed CSV separators"* ]]
}

@test "lists the complete public type and round vocabularies" {
  run_path_app --list-types
  [ "$status" -eq 0 ]
  [[ "$output" == *$'ICMP4\nICMP6'* ]]
  [[ "$output" == *"AS6"* ]]

  run_path_app --list-rounds
  [ "$status" -eq 0 ]
  [[ "$output" == *"Standard"* ]]
  [[ "$output" == *"Timeout5"* ]]
}
