#!/usr/bin/env bash
# main.sh - CLI orchestration for the Bash MTR path feature

PATH_FEATURE_VERSION="1.1.0"
PATH_ALL_TEST_TYPES=(ICMP4 ICMP6 UDP4 UDP6 TCP4 TCP6 MPLS4 MPLS6 AS4 AS6)
PATH_ALL_ROUNDS=(Standard MTU1400 TOS_CS5 TOS_AF11 TTL10 TTL64 FirstTTL3 Timeout5)
PATH_DEFAULT_TEST_TYPES=(ICMP4 ICMP6 TCP4 TCP6)
PATH_DEFAULT_ROUNDS=(Standard)
PATH_DEFAULT_HOSTS_IPV4=(netcologne.de google.com wikipedia.org amazon.de)
PATH_DEFAULT_HOSTS_IPV6=(netcologne.de google.com wikipedia.org)

path_usage() {
	cat <<USAGE
test-network-path.sh v${PATH_FEATURE_VERSION}

Runs an MTR test matrix (types x rounds x hosts) and writes:
  - JSON_LOG: raw per-run JSON output
  - TABLE_LOG: human-readable summaries and progress

Default log directory: LOG_DIR env or ~/logs.
Default host config: <repo>/config/hosts.conf (loaded when present).
Per-run timeout: MTR_TIMEOUT_SECONDS env (default: 360).

Usage:
  ./apps/path/test-network-path.sh [options]

Options:
  --log-dir DIR      Log directory (default: ~/logs)
  --json-log PATH    Override JSON_LOG path
  --table-log PATH   Override TABLE_LOG path
  --types CSV        Run selected test types (e.g. ICMP4,TCP4)
  --rounds CSV       Run selected rounds (e.g. Standard,TTL64)
  --hosts4 CSV       Override IPv4 hosts (comma-separated)
  --hosts6 CSV       Override IPv6 hosts (comma-separated)
  --list-types       Print supported test types and exit
  --list-rounds      Print supported rounds and exit
  --no-summary       Skip jq/column summary tables (JSON still logged)
  --dry-run          Print planned runs only; no files created
  --quiet            Print warnings/failures and final summary only
  -h, --help         Show this help
  --version          Print version
USAGE
}

path_initialize_options() {
	log_dir="${LOG_DIR:-$HOME/logs}"
	json_log=""
	table_log=""
	types_csv=""
	rounds_csv=""
	hosts4_csv=""
	hosts6_csv=""
	list_types=0
	list_rounds=0
	types_set=0
	rounds_set=0
	hosts4_set=0
	hosts6_set=0
	DO_SUMMARY=1
	DRY_RUN=0
	QUIET=0
	MTR_TIMEOUT_SECONDS=${MTR_TIMEOUT_SECONDS:-360}
}

path_parse_value_option() {
	local option=$1 value=$2
	case "$option" in
	--log-dir) log_dir=$value ;;
	--json-log) json_log=$value ;;
	--table-log) table_log=$value ;;
	--types) types_csv=$value; types_set=1 ;;
	--rounds) rounds_csv=$value; rounds_set=1 ;;
	--hosts4) hosts4_csv=$value; hosts4_set=1 ;;
	--hosts6) hosts6_csv=$value; hosts6_set=1 ;;
	esac
}

path_parse_flag_option() {
	case "$1" in
	--list-types) list_types=1 ;;
	--list-rounds) list_rounds=1 ;;
	--no-summary) DO_SUMMARY=0 ;;
	--dry-run) DRY_RUN=1 ;;
	--quiet)
		# shellcheck disable=SC2034
		QUIET=1
		;;
	-h | --help) path_usage; exit 0 ;;
	--version) echo "test-network-path.sh v${PATH_FEATURE_VERSION}"; exit 0 ;;
	--) return 2 ;;
	*) return 1 ;;
	esac
}

path_parse_options() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--log-dir | --json-log | --table-log)
			require_path_option "$1" "$#" "${2:-}"
			path_parse_value_option "$1" "$2"
			shift 2
			;;
		--types | --rounds | --hosts4 | --hosts6)
			[[ $# -ge 2 ]] || die "$1 requires an argument"
			path_parse_value_option "$1" "$2"
			shift 2
			;;
		*)
			path_parse_flag_option "$1" || {
				[[ $? -eq 2 ]] && { shift; break; }
				die "Unknown argument: $1 (use --help)"
			}
			shift
			;;
		esac
	done
	[[ $# -eq 0 ]] || die "Unexpected positional args: $*"
}

path_validate_startup_options() {
	validate_path_option "log-dir" "$log_dir"
	[[ "$MTR_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "MTR_TIMEOUT_SECONDS must be a positive integer."
	require_bash4
	if ((list_types)); then
		print_list "${PATH_ALL_TEST_TYPES[@]}"
		exit 0
	fi
	if ((list_rounds)); then
		print_list "${PATH_ALL_ROUNDS[@]}"
		exit 0
	fi
}

path_configure_selections() {
	TEST_ORDER=("${PATH_DEFAULT_TEST_TYPES[@]}")
	ROUND_ORDER=("${PATH_DEFAULT_ROUNDS[@]}")
	HOSTS_IPV4=("${PATH_DEFAULT_HOSTS_IPV4[@]}")
	HOSTS_IPV6=("${PATH_DEFAULT_HOSTS_IPV6[@]}")
	load_hosts_from_config "$(default_hosts_config_path)"
	if ((types_set)); then
		parse_csv_to_array "$types_csv" "--types"
		validate_selection "test type" "${PATH_ALL_TEST_TYPES[@]}"
		TEST_ORDER=("${PARSED_CSV_ITEMS[@]}")
	fi
	if ((rounds_set)); then
		parse_csv_to_array "$rounds_csv" "--rounds"
		validate_selection "round" "${PATH_ALL_ROUNDS[@]}"
		ROUND_ORDER=("${PARSED_CSV_ITEMS[@]}")
	fi
	if ((hosts4_set)); then
		parse_csv_to_array "$hosts4_csv" "--hosts4"
		HOSTS_IPV4=("${PARSED_CSV_ITEMS[@]}")
	fi
	if ((hosts6_set)); then
		parse_csv_to_array "$hosts6_csv" "--hosts6"
		HOSTS_IPV6=("${PARSED_CSV_ITEMS[@]}")
	fi
	local host
	for host in "${HOSTS_IPV4[@]}" "${HOSTS_IPV6[@]}"; do
		validate_host "$host"
	done
}

path_verify_dependencies() {
	if ((DRY_RUN == 0)); then
		require_cmd mtr
		require_cmd jq
	fi
	if ((DO_SUMMARY)) && ((DRY_RUN == 0)); then
		require_cmd column
	fi
}

path_prepare_logs() {
	local timestamp
	timestamp=$(date +'%Y%m%d_%H%M%S')_$$
	if ((DRY_RUN)); then
		would_json_log=${json_log:-"$log_dir/mtr_results_${timestamp}.json.log"}
		would_table_log=${table_log:-"$log_dir/mtr_summary_${timestamp}.log"}
		JSON_LOG=""
		TABLE_LOG=""
		return
	fi
	JSON_LOG=${json_log:-"$log_dir/mtr_results_${timestamp}.json.log"}
	TABLE_LOG=${table_log:-"$log_dir/mtr_summary_${timestamp}.log"}
	mkdir -p -- "$log_dir" || die "Failed to create log directory: $log_dir"
	if [[ -n "$json_log" ]]; then
		mkdir -p -- "$(dirname "$JSON_LOG")" || die "Failed to create directory for JSON log"
	fi
	if [[ -n "$table_log" ]]; then
		mkdir -p -- "$(dirname "$TABLE_LOG")" || die "Failed to create directory for table log"
	fi
	if [[ -d "$JSON_LOG" ]] || [[ -d "$TABLE_LOG" ]]; then
		die "Log path must not be an existing directory: JSON_LOG=$JSON_LOG TABLE_LOG=$TABLE_LOG"
	fi
	: >"$JSON_LOG"
	: >"$TABLE_LOG"
}

path_cleanup_and_exit() {
	local signal=${1:-} code=${2:-130}
	if [[ -n "${CURRENT_MTR_PID:-}" ]]; then
		kill -KILL "$CURRENT_MTR_PID" 2>/dev/null || true
	fi
	rm -f "${CURRENT_TMP:-}" 2>/dev/null
	if [[ -n "$signal" ]]; then
		echo "Interrupted (SIG$signal)" >&2
		exit "$code"
	fi
}

path_install_cleanup_traps() {
	CURRENT_TMP=""
	CURRENT_MTR_PID=""
	trap 'path_cleanup_and_exit INT 130' INT
	trap 'path_cleanup_and_exit TERM 143' TERM
	trap 'path_cleanup_and_exit' EXIT
}

path_prepare_run_plan() {
	compute_run_plan
	((TOTAL_RUNS > 0)) || die "No runs planned. Check selected rounds/types/hosts."
}

path_announce_run_plan() {
	log_line INFO "Starting MTR tests (planned runs: $TOTAL_RUNS)"
	log_line INFO "Selected rounds: ${ROUND_ORDER[*]}"
	log_line INFO "Selected types: ${TEST_ORDER[*]}"
	log_line INFO "IPv4 hosts: ${HOSTS_IPV4[*]}"
	log_line INFO "IPv6 hosts: ${HOSTS_IPV6[*]}"
	if ((DRY_RUN)); then
		log_line SUMMARY "Dry-run only. Planned runs: $TOTAL_RUNS"
		log_line SUMMARY "Would write JSON_LOG=$would_json_log"
		log_line SUMMARY "Would write TABLE_LOG=$would_table_log"
	else
		log_line INFO "JSON_LOG=$JSON_LOG"
		log_line INFO "TABLE_LOG=$TABLE_LOG"
	fi
}

path_execute_run_plan() {
	RUN_OK=0
	RUN_FAIL=0
	local start_ts end_ts entry round type host index=0
	start_ts=$(date +%s)
	for entry in "${PLAN_ENTRIES[@]}"; do
		IFS='|' read -r round type host <<<"$entry"
		((index++)) || true
		execute_single_run "$round" "$type" "$host" "$index"
	done
	end_ts=$(date +%s)
	elapsed=$((end_ts - start_ts))
}

path_finish_run() {
	if ((DRY_RUN)); then
		log_line SUMMARY "Dry-run complete. Planned runs: $TOTAL_RUNS"
		return 0
	fi
	log_line SUMMARY "All tests done. Passed: $RUN_OK, Failed: $RUN_FAIL, Elapsed: ${elapsed}s"
	log_line SUMMARY "Logs: JSON=$JSON_LOG TABLE=$TABLE_LOG"
	((RUN_FAIL == 0)) || return 1
}

path_main() {
	local log_dir json_log table_log
	local types_csv rounds_csv hosts4_csv hosts6_csv
	local list_types list_rounds types_set rounds_set hosts4_set hosts6_set
	local would_json_log="" would_table_log="" elapsed=0
	path_initialize_options
	path_parse_options "$@"
	path_validate_startup_options
	path_configure_selections
	path_verify_dependencies
	path_prepare_logs
	path_install_cleanup_traps
	path_prepare_run_plan
	path_announce_run_plan
	path_execute_run_plan
	path_finish_run
}
