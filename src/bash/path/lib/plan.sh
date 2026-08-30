#!/usr/bin/env bash
# plan.sh - test run plan computation

# Build the full test matrix from ROUND_ORDER x TEST_ORDER x hosts.
# Side effects:
#   Sets global array PLAN_ENTRIES (each element: "round|type|host")
#   Sets global TOTAL_RUNS to the entry count
compute_run_plan() {
  PLAN_ENTRIES=()

  local round type host
  local -a hosts=()
  for round in "${ROUND_ORDER[@]}"; do
    for type in "${TEST_ORDER[@]}"; do
      mapfile -t hosts < <(hosts_for_type "$type")
      for host in "${hosts[@]}"; do
        PLAN_ENTRIES+=("$round|$type|$host")
      done
    done
  done

  # shellcheck disable=SC2034
  TOTAL_RUNS=${#PLAN_ENTRIES[@]}
}
