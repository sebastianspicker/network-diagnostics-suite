#!/usr/bin/env bash
# logging.sh - output and summary formatting

# Emit a timestamped log line; optionally append to TABLE_LOG.
# Args:
#   $1 - log level (e.g. INFO, WARN, FAIL, OK, SUMMARY)
#   $@ - remaining args form the message
# Output/Returns:
#   Prints "[date] [LEVEL] message" to stdout and TABLE_LOG (if set).
#   In QUIET mode, only WARN/FAIL/ERROR/SUMMARY levels are emitted.
log_line() {
  local level=$1
  shift
  local msg=$*
  if [[ "${QUIET:-0}" -eq 1 ]]; then
    case "$level" in
      WARN | FAIL | ERROR | SUMMARY) ;;
      *) return 0 ;;
    esac
  fi

  local line
  line=$(printf '[%s] [%s] %s\n' "$(date +'%F %T')" "$level" "$msg")
  if [[ -n "${TABLE_LOG:-}" ]]; then
    (echo "$line" | tee -a -- "$TABLE_LOG") || echo "$line" >&2
  else
    echo "$line"
  fi
}

_format_summary_rows() {
  local table_out=$1

  if [[ -n "$table_out" ]] && command -v column >/dev/null 2>&1; then
    echo "$table_out" | column -t -s $'\t' 2>/dev/null
  else
    printf '%s' "$table_out"
  fi
}

_render_json_summary() {
  local dst_name=$1
  local dst_ip=$2
  local table_out=$3

  echo
  echo "Results for: ${dst_name} (${dst_ip})"
  printf 'Hop\tHost\tIP\tLoss%%\tSnt\tLast\tAvg\tBest\tWrst\tStDev\n'
  if [[ -n "$table_out" ]]; then
    echo "$table_out"
  else
    echo "(No results)"
  fi
  echo
}

# Pretty-print an MTR JSON result file as a hop-by-hop summary table.
# Args:
#   $1 - path to a single MTR JSON output file
# Output/Returns:
#   When TABLE_LOG is set, appends to TABLE_LOG (stdout suppressed). Otherwise prints to stdout.
#   Returns the jq exit status (non-zero when parsing fails).
summarize_json() {
  local f=$1
  local dst_name dst_ip
  local table_out jq_status

  dst_name=$(jq -r '(.report // {} | .dst_name? // .dst_addr? // .dst_ip? // .mtr.dst?) // "???"' "$f" 2>/dev/null) || true
  dst_name="${dst_name:-???}"
  dst_ip=$(jq -r '(.report // {} | .dst_addr? // .dst_ip? // .mtr.dst?) // "???"' "$f" 2>/dev/null) || true
  dst_ip="${dst_ip:-???}"

  table_out=$(jq -r '
    ((.report // {}) | .hubs // [])[]? as $h |
    [
      ($h.count // 0),
      ( $h.host // "???" | sub(" \\(.*"; "") ),
      ( ($h.ip // ($h.host | if type == "string" and test("\\(.*\\)") then capture("\\((?<ip>[^)]+)\\)").ip else . end)) // "???" ),
      ($h."Loss%" // 0),
      ($h.Snt     // 0),
      ($h.Last    // 0),
      ($h.Avg     // 0),
      ($h.Best    // 0),
      ($h.Wrst    // 0),
      ($h.StDev   // 0)
    ] | map(tostring) | @tsv' "$f" 2>/dev/null)
  jq_status=$?

  table_out=$(_format_summary_rows "$table_out") || true

  if [[ -n "${TABLE_LOG:-}" ]]; then
    _render_json_summary "$dst_name" "$dst_ip" "$table_out" | tee -a -- "$TABLE_LOG" >/dev/null
  else
    _render_json_summary "$dst_name" "$dst_ip" "$table_out"
  fi
  return "$jq_status"
}
