#!/usr/bin/env bats

load test_helper.bash

setup() {
  setup_path_app
}

@test "loads repository host config unless a CLI host override is provided" {
  run_path_app --types ICMP4 --rounds Standard --dry-run --no-summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"IPv4 hosts: cloudflare.com google.com wikipedia.org amazon.de"* ]]
  [[ "$output" == *"Planned runs: 4"* ]]

  run_path_app --types ICMP4 --rounds Standard --hosts4 override.example --dry-run --no-summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"IPv4 hosts: override.example"* ]]
  [[ "$output" == *"Planned runs: 1"* ]]
}

@test "expands rounds, types, and address-family host sets into the MTR matrix" {
  run_path_app \
    --types ICMP4,ICMP6 \
    --rounds Standard,TTL64 \
    --hosts4 v4.example \
    --hosts6 v6.example \
    --dry-run \
    --no-summary

  [ "$status" -eq 0 ]
  [[ "$output" == *"Planned runs: 4"* ]]
  [[ "$output" == *"mtr -4 -b -i 1 -c 300 -r --json  v4.example"* ]]
  [[ "$output" == *"mtr -6 -b -i 1 -c 300 -r --json  v6.example"* ]]
  [[ "$output" == *"-m 64 v4.example"* ]]
}
