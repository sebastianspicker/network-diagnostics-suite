#!/usr/bin/env bash
# validation.sh - input validation functions

# shellcheck disable=SC1091
source "${BASH_SOURCE[0]%/*}/common.sh" 2>/dev/null || true

# Split a comma-separated string into the PARSED_CSV_ITEMS array.
# Args:
#   $1 - CSV string
#   $2 - option name (used in error messages)
# Side effects:
#   Sets global array PARSED_CSV_ITEMS with trimmed, non-empty items.
#   Calls die() on malformed input.
parse_csv_to_array() {
  local csv=$1
  local opt_name=$2
  local -a raw=()
  local item clean

  PARSED_CSV_ITEMS=()

  [[ -n "$csv" ]] || die "$opt_name requires a non-empty CSV argument"
  if [[ "$csv" == ,* || "$csv" == *, || "$csv" == *,,* ]]; then
    die "$opt_name contains malformed CSV separators"
  fi

  IFS=',' read -r -a raw <<<"$csv"
  for item in "${raw[@]}"; do
    clean=$(trim "$item")
    [[ -n "$clean" ]] || die "$opt_name contains an empty item"
    PARSED_CSV_ITEMS+=("$clean")
  done
}

# Verify every item in PARSED_CSV_ITEMS is present in an allowed list.
# Args:
#   $1 - label for error messages (e.g. "round", "type")
#   $@ - remaining args are the allowed values
# Output/Returns:
#   Calls die() if any item is not in the allowed list
validate_selection() {
  local label=$1
  shift
  local -a selected=()
  local -a allowed=("$@")
  local item

  selected=("${PARSED_CSV_ITEMS[@]}")
  for item in "${selected[@]}"; do
    contains_item "$item" "${allowed[@]}" || die "Unknown $label: $item"
  done
}

# Reject path-like option values that are empty, look like flags, or contain
# control characters / path-traversal sequences.
# Args:
#   $1 - option name (for error messages)
#   $2 - the value to validate
# Output/Returns:
#   Calls die() on invalid input
validate_path_option() {
  local opt_name=$1
  local val=$2
  local normalized
  normalized=$(trim "$val")
  if [[ -z "$normalized" ]]; then
    die "$opt_name argument must not be empty"
  fi
  if [[ -n "$val" && "$val" == -* ]]; then
    die "$opt_name argument must not look like an option (starts with -): $val"
  fi
  if [[ -n "$val" && "$val" == *[[:cntrl:]]* ]]; then
    die "$opt_name argument must not contain control characters"
  fi
  if [[ -n "$val" && ("$val" == ".." || "$val" == *'/../'* || "$val" == '../'* || "$val" == *'/..' || "$val" == *'\\..') ]]; then
    die "$opt_name argument must not contain path traversal (..): $val"
  fi
}

# Ensure a CLI option has a non-empty, safe path argument.
# Args:
#   $1 - option name (e.g. "--log-dir")
#   $2 - remaining argument count (must be >= 2)
#   $3 - the path value to validate
# Output/Returns:
#   Calls die() if argument is missing or invalid
require_path_option() {
  local opt_name=$1
  local argc=$2
  local val=$3
  [[ $argc -ge 2 ]] || die "$opt_name requires an argument"
  validate_path_option "$opt_name" "$val"
}

_reject_forbidden_host_characters() {
  local host=$1
  local index
  local -a forbidden_chars=('/' '|' ';' '&' '`' '$')
  local -a forbidden_labels=("'/'" "'|'" "';'" "'&'" "backtick" "'$'")

  for ((index = 0; index < ${#forbidden_chars[@]}; index++)); do
    [[ "$host" != *"${forbidden_chars[$index]}"* ]] ||
      die "Host name must not contain ${forbidden_labels[$index]}: $host"
  done
}

# Reject host names that are empty or contain shell-unsafe characters.
# Args:
#   $1 - hostname or IP address to validate
# Output/Returns:
#   Calls die() if the host name is unsafe for shell interpolation
validate_host() {
  local host=$1
  [[ -n "$host" ]] || die "Host name must not be empty"
  [[ "$host" != -* ]] || die "Host name must not look like an option (starts with -): $host"
  [[ "$host" != *[[:space:]]* ]] || die "Host name must not contain whitespace: $host"
  _reject_forbidden_host_characters "$host"
  [[ "$host" != *[[:cntrl:]]* ]] || die "Host name must not contain control characters: $host"
}
