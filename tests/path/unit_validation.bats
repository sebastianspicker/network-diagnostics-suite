#!/usr/bin/env bats
load test_helper

setup() {
  source "$PATH_APP"
}

# ---------- validate_host ----------

@test "validate_host accepts valid hostname" {
  run validate_host "google.com"
  assert_success
}

@test "validate_host accepts punycode IDN" {
  run validate_host "xn--nxasmq6b.com"
  assert_success
}

@test "validate_host rejects empty string" {
  run validate_host ""
  assert_failure
}

@test "validate_host rejects dash prefix" {
  run validate_host "-evil"
  assert_failure
}

@test "validate_host rejects whitespace" {
  run validate_host "host name"
  assert_failure
}

@test "validate_host rejects pipe" {
  run validate_host "host|cmd"
  assert_failure
}

@test "validate_host rejects semicolon" {
  run validate_host "host;cmd"
  assert_failure
}

@test "validate_host rejects ampersand" {
  run validate_host "host&cmd"
  assert_failure
}

@test "validate_host rejects backtick" {
  run validate_host 'host`cmd`'
  assert_failure
}

@test "validate_host rejects dollar sign" {
  run validate_host 'host$var'
  assert_failure
}

@test "validate_host rejects slash" {
  run validate_host "host/path"
  assert_failure
}

# ---------- trim ----------

@test "trim removes leading spaces" {
  run trim "  hello"
  assert_output "hello"
}

@test "trim removes trailing spaces" {
  run trim "hello  "
  assert_output "hello"
}

@test "trim removes both sides" {
  run trim "  hello  "
  assert_output "hello"
}

@test "trim handles empty string" {
  run trim ""
  assert_output ""
}

@test "trim preserves internal spaces" {
  run trim "  hello world  "
  assert_output "hello world"
}

# ---------- contains_item ----------

@test "contains_item finds present item" {
  run contains_item "b" "a" "b" "c"
  assert_success
}

@test "contains_item rejects missing item" {
  run contains_item "x" "a" "b" "c"
  assert_failure
}

@test "contains_item handles single-element array" {
  run contains_item "a" "a"
  assert_success
}

# ---------- json_escape ----------

@test "json_escape handles plain text" {
  run json_escape "hello"
  assert_output "hello"
}

@test "json_escape escapes backslash" {
  run json_escape 'a\b'
  assert_output 'a\\b'
}

@test "json_escape escapes double quote" {
  run json_escape 'a"b'
  assert_output 'a\"b'
}

# ---------- parse_csv_to_array ----------

@test "parse_csv_to_array parses simple CSV" {
  parse_csv_to_array "a,b,c" "--test"
  [[ "${#PARSED_CSV_ITEMS[@]}" -eq 3 ]]
  [[ "${PARSED_CSV_ITEMS[0]}" == "a" ]]
  [[ "${PARSED_CSV_ITEMS[1]}" == "b" ]]
  [[ "${PARSED_CSV_ITEMS[2]}" == "c" ]]
}

@test "parse_csv_to_array trims whitespace" {
  parse_csv_to_array " a , b , c " "--test"
  [[ "${PARSED_CSV_ITEMS[0]}" == "a" ]]
  [[ "${PARSED_CSV_ITEMS[1]}" == "b" ]]
  [[ "${PARSED_CSV_ITEMS[2]}" == "c" ]]
}

@test "parse_csv_to_array rejects leading comma" {
  run parse_csv_to_array ",a,b" "--test"
  assert_failure
}

@test "parse_csv_to_array rejects trailing comma" {
  run parse_csv_to_array "a,b," "--test"
  assert_failure
}

@test "parse_csv_to_array rejects empty argument" {
  run parse_csv_to_array "" "--test"
  assert_failure
}

# ---------- validate_path_option ----------

@test "validate_path_option accepts valid path" {
  run validate_path_option "--log-dir" "/tmp/logs"
  assert_success
}

@test "validate_path_option rejects empty" {
  run validate_path_option "--log-dir" ""
  assert_failure
}

@test "validate_path_option rejects path traversal" {
  run validate_path_option "--log-dir" "../../../etc"
  assert_failure
}

@test "validate_path_option rejects option-like" {
  run validate_path_option "--log-dir" "--other"
  assert_failure
}

@test "require_path_option accepts a present safe path" {
  run require_path_option "--log-dir" 2 "/tmp/logs"
  assert_success
}

@test "require_path_option reports a missing path argument" {
  run require_path_option "--log-dir" 1 ""
  assert_failure
  assert_output "ERROR: --log-dir requires an argument"
}

# Additional edge cases

@test "validate_host rejects control character" {
  run validate_host $'host\x01name'
  assert_failure
}

@test "validate_path_option rejects control character" {
  run validate_path_option "--log-dir" $'/tmp/\x01bad'
  assert_failure
}

@test "validate_path_option rejects bare .." {
  run validate_path_option "--log-dir" ".."
  assert_failure
}

@test "validate_path_option rejects trailing .." {
  run validate_path_option "--log-dir" "/foo/.."
  assert_failure
}

@test "validate_path_option rejects whitespace-only" {
  run validate_path_option "--log-dir" "   "
  assert_failure
}

@test "parse_csv_to_array handles single item" {
  parse_csv_to_array "single" "--test"
  [ ${#PARSED_CSV_ITEMS[@]} -eq 1 ]
  [ "${PARSED_CSV_ITEMS[0]}" = "single" ]
}

@test "parse_csv_to_array rejects consecutive commas" {
  run parse_csv_to_array "a,,b" "--test"
  assert_failure
}

@test "json_escape escapes newline" {
  run json_escape $'line1\nline2'
  assert_output 'line1\nline2'
}

@test "json_escape escapes carriage return" {
  run json_escape $'a\rb'
  assert_output 'a\rb'
}

@test "json_escape escapes tab" {
  run json_escape $'a\tb'
  assert_output 'a\tb'
}

@test "json_escape escapes arbitrary JSON control characters" {
  run json_escape $'a\001b\bc\f'
  assert_success
  assert_output 'a\u0001b\bc\f'
}

@test "contains_item with empty haystack returns failure" {
  run contains_item "x"
  assert_failure
}
