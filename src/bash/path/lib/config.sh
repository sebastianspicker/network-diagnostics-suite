#!/usr/bin/env bash
# config.sh - host configuration loading

# Return the absolute path to the default hosts.conf file.
# Output/Returns:
#   Prints "<repo_root>/config/hosts.conf" to stdout
default_hosts_config_path() {
  local script_dir repo_root
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  repo_root=$(cd "$script_dir/../../../.." && pwd)
  echo "$repo_root/config/hosts.conf"
}

# Normalize one hosts.conf line into a tab-delimited key/value pair.
# Returns 1 for comments, blanks, malformed lines, and empty values.
_parse_hosts_config_entry() {
  local line key value
  line=$(trim "$1")

  [[ -n "$line" ]] || return 1
  [[ "$line" != \#* ]] || return 1
  [[ "$line" == *=* ]] || return 1

  key=$(trim "${line%%=*}")
  value=$(trim "${line#*=}")
  [[ -n "$value" ]] || return 1

  printf '%s\t%s\n' "${key,,}" "$value"
}

# Parse a hosts.conf file and populate HOSTS_IPV4 / HOSTS_IPV6 arrays.
# Args:
#   $1 - path to config file (key=value format, keys: ipv4, ipv6)
# Side effects:
#   Sets global arrays HOSTS_IPV4 and HOSTS_IPV6 when entries are found
load_hosts_from_config() {
  local config_path=$1
  local line entry key val
  local -a loaded4=()
  local -a loaded6=()

  [[ -f "$config_path" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    entry=$(_parse_hosts_config_entry "$line") || continue
    key=${entry%%$'\t'*}
    val=${entry#*$'\t'}

    case "$key" in
      ipv4)
        validate_host "$val"
        loaded4+=("$val")
        ;;
      ipv6)
        validate_host "$val"
        loaded6+=("$val")
        ;;
    esac
  done <"$config_path"

  if ((${#loaded4[@]} > 0)); then
    # shellcheck disable=SC2034
    HOSTS_IPV4=("${loaded4[@]}")
  fi
  if ((${#loaded6[@]} > 0)); then
    # shellcheck disable=SC2034
    HOSTS_IPV6=("${loaded6[@]}")
  fi
}
