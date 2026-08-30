#!/usr/bin/env bats

setup() {
  PATH_APP="$BATS_TEST_DIRNAME/../../apps/path/test-network-path.sh"
}

@test "path dry-run preserves the public CLI adapter" {
  run bash "$PATH_APP" --types ICMP4 --rounds Standard --hosts4 localhost --dry-run --no-summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"Planned runs: 1"* ]]
}

@test "path CLI rejects injected host and traversal output path" {
  run bash "$PATH_APP" --types ICMP4 --hosts4 'host;command' --dry-run
  [ "$status" -ne 0 ]
  run bash "$PATH_APP" --log-dir ../unsafe --dry-run
  [ "$status" -ne 0 ]
}
