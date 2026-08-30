#!/usr/bin/env bash
# runner.sh - single test run execution

# Emit a JSON object marking a failed test run (appended to the JSON log).
# Args:
#   $1 - round name
#   $2 - test type
#   $3 - target host
#   $4 - optional raw command output
# Output/Returns:
#   Prints a one-line JSON object with _failed:true to stdout
append_failed_marker() {
  local round=$1
  local type=$2
  local host=$3
  local raw_output=${4:-}
  if [[ -n "$raw_output" ]]; then
    printf '{"_failed":true,"round":"%s","type":"%s","host":"%s","raw_output":"%s"}\n' \
      "$(json_escape "$round")" \
      "$(json_escape "$type")" \
      "$(json_escape "$host")" \
      "$(json_escape "$raw_output")"
  else
    printf '{"_failed":true,"round":"%s","type":"%s","host":"%s"}\n' \
      "$(json_escape "$round")" \
      "$(json_escape "$type")" \
      "$(json_escape "$host")"
  fi
}

_terminate_mtr_at_deadline() {
  local mtr_pid=$1

  kill -TERM "$mtr_pid" 2>/dev/null || true
  for _ in {1..10}; do
    if ! kill -0 "$mtr_pid" 2>/dev/null; then
      return
    fi
    sleep 0.1
  done
  if kill -0 "$mtr_pid" 2>/dev/null; then
    kill -KILL "$mtr_pid" 2>/dev/null || true
  fi
}

_capture_mtr_with_deadline() {
  local host=$1
  shift
  local mtr_pid
  local timed_out=0
  local remaining_ticks=$((MTR_TIMEOUT_SECONDS * 10))

  mtr "$@" -- "$host" >"$CURRENT_TMP" 2>>"$TABLE_LOG" &
  mtr_pid=$!
  CURRENT_MTR_PID=$mtr_pid

  while kill -0 "$mtr_pid" 2>/dev/null; do
    if ((remaining_ticks <= 0)); then
      timed_out=1
      _terminate_mtr_at_deadline "$mtr_pid"
      break
    fi
    sleep 0.1
    ((remaining_ticks--)) || true
  done

  local mtr_status=0
  if wait "$mtr_pid"; then
    mtr_status=0
  else
    mtr_status=$?
  fi
  # shellcheck disable=SC2034
  CURRENT_MTR_PID=""
  ((timed_out)) && return 124
  return "$mtr_status"
}

_append_valid_mtr_output() {
  [[ -s "$CURRENT_TMP" ]] || return 1
  jq -e -s 'length == 1 and (.[0] | type == "object")' "$CURRENT_TMP" >/dev/null 2>&1 || return 1

  cat "$CURRENT_TMP" >>"$JSON_LOG"
  printf '\n' >>"$JSON_LOG"
}

_read_current_mtr_output() {
  [[ -s "$CURRENT_TMP" ]] && head -c 4096 -- "$CURRENT_TMP"
  return 0
}

_record_invalid_mtr_output() {
  local round=$1
  local type=$2
  local host=$3
  local invalid_reason="invalid JSON output"
  local invalid_output

  [[ -s "$CURRENT_TMP" ]] || invalid_reason="empty output"
  invalid_output=$(_read_current_mtr_output)
  log_line WARN "mtr produced $invalid_reason for round=$round type=$type host=$host"
  append_failed_marker "$round" "$type" "$host" "$invalid_output" >>"$JSON_LOG"
  ((RUN_FAIL++)) || true
  log_line FAIL "round=$round type=$type host=$host ($invalid_reason)"
}

_record_mtr_failure() {
  local round=$1
  local type=$2
  local host=$3
  local mtr_status=$4
  local raw_output

  raw_output=$(_read_current_mtr_output)
  append_failed_marker "$round" "$type" "$host" "$raw_output" >>"$JSON_LOG"
  ((RUN_FAIL++)) || true
  if ((mtr_status == 124)); then
    log_line FAIL "round=$round type=$type host=$host (timeout after ${MTR_TIMEOUT_SECONDS}s)"
  else
    log_line FAIL "round=$round type=$type host=$host (exit=$mtr_status)"
  fi
}

_cleanup_current_run() {
  rm -f -- "$CURRENT_TMP"
  CURRENT_TMP=""
}

# Run a single MTR test, log results, and update counters.
# Args:
#   $1 - round name
#   $2 - test type (e.g. ICMP4, TCP6)
#   $3 - target host
#   $4 - 1-based run index (for progress display)
# Side effects:
#   Appends output to JSON_LOG and TABLE_LOG; increments RUN_OK or RUN_FAIL.
#   In DRY_RUN mode, only logs the planned command.
execute_single_run() {
  local round=$1
  local type=$2
  local host=$3
  local run_index=$4

  local -a local_mtr_args=()
  local -a local_extra_args=()

  set_round_extra_args "$round"
  # shellcheck disable=SC2154
  local_extra_args=("${extra_args[@]}")

  set_mtr_args_for_type "$type"
  # shellcheck disable=SC2154
  local_mtr_args=("${mtr_args[@]}")

  log_line INFO "RUN [$run_index/$TOTAL_RUNS] round=$round type=$type host=$host"

  if ((DRY_RUN)); then
    log_line PLAN "mtr ${local_mtr_args[*]} ${local_extra_args[*]} $host"
    return 0
  fi

  CURRENT_TMP=$(mktemp "${TMPDIR:-/tmp}/mtr-suite.XXXXXXXX")
  local mtr_status=0
  if _capture_mtr_with_deadline "$host" "${local_mtr_args[@]}" "${local_extra_args[@]}"; then
    :
  else
    mtr_status=$?
    _record_mtr_failure "$round" "$type" "$host" "$mtr_status"
    _cleanup_current_run
    return
  fi

  if ! _append_valid_mtr_output; then
    _record_invalid_mtr_output "$round" "$type" "$host"
    _cleanup_current_run
    return
  fi

  if ((DO_SUMMARY)) && ! summarize_json "$CURRENT_TMP"; then
    log_line WARN "summary failed for round=$round type=$type host=$host"
  fi

  ((RUN_OK++)) || true
  log_line OK "round=$round type=$type host=$host"
  _cleanup_current_run
}
