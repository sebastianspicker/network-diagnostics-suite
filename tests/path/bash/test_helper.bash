setup_path_app() {
  PATH_APP="$BATS_TEST_DIRNAME/../../../apps/path/test-network-path.sh"
}

install_fake_mtr() {
  local fake_name=$1
  local fake_dir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_dir"
  cp "$BATS_TEST_DIRNAME/fakes/$fake_name" "$fake_dir/mtr"
  chmod +x "$fake_dir/mtr"
  PATH="$fake_dir:$PATH"
}

run_path_app() {
  run bash "$PATH_APP" "$@"
}
