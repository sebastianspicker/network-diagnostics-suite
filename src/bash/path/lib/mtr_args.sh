#!/usr/bin/env bash
# mtr_args.sh - MTR argument construction

# Populate extra_args array with MTR flags for the given round name.
# Args:
#   $1 - round name (Standard, MTU1400, TOS_CS5, TOS_AF11, TTL10, etc.)
# Side effects:
#   Sets the caller-scoped array extra_args
# shellcheck disable=SC2034
set_round_extra_args() {
  local round=$1
  case "$round" in
    Standard) extra_args=() ;;
    MTU1400) extra_args=(-s 1400) ;;
    TOS_CS5) extra_args=(--tos 160) ;;
    TOS_AF11) extra_args=(--tos 40) ;;
    TTL10) extra_args=(-m 10) ;;
    TTL64) extra_args=(-m 64) ;;
    FirstTTL3) extra_args=(-f 3) ;;
    Timeout5) extra_args=(-Z 5) ;;
    *) die "Unknown round: $round" ;;
  esac
}

# Populate mtr_args array with protocol/mode flags for a test type.
# Args:
#   $1 - test type (ICMP4, ICMP6, UDP4, UDP6, TCP4, TCP6, MPLS4, etc.)
# Side effects:
#   Sets the caller-scoped array mtr_args
# shellcheck disable=SC2034
set_mtr_args_for_type() {
  local type=$1
  local -a base_mtr=(-b -i 1 -c 300 -r --json)
  case "$type" in
    ICMP4) mtr_args=(-4 "${base_mtr[@]}") ;;
    ICMP6) mtr_args=(-6 "${base_mtr[@]}") ;;
    UDP4) mtr_args=(-u -4 "${base_mtr[@]}") ;;
    UDP6) mtr_args=(-u -6 "${base_mtr[@]}") ;;
    TCP4) mtr_args=(-T -P 443 -4 "${base_mtr[@]}") ;;
    TCP6) mtr_args=(-T -P 443 -6 "${base_mtr[@]}") ;;
    MPLS4) mtr_args=(-e -4 "${base_mtr[@]}") ;;
    MPLS6) mtr_args=(-e -6 "${base_mtr[@]}") ;;
    AS4) mtr_args=(-z --aslookup -4 "${base_mtr[@]}") ;;
    AS6) mtr_args=(-z --aslookup -6 "${base_mtr[@]}") ;;
    *) die "Unknown test type: $type" ;;
  esac
}

# Print the appropriate host list for a given test type.
# Args:
#   $1 - test type (types ending in "6" use HOSTS_IPV6, others use HOSTS_IPV4)
# Output/Returns:
#   Prints one host per line to stdout
hosts_for_type() {
  local type=$1
  if [[ "$type" == *6 ]]; then
    [[ ${#HOSTS_IPV6[@]} -gt 0 ]] && print_list "${HOSTS_IPV6[@]}"
  else
    [[ ${#HOSTS_IPV4[@]} -gt 0 ]] && print_list "${HOSTS_IPV4[@]}"
  fi
  return 0
}
