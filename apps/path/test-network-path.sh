#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
LIB_DIR="$REPO_ROOT/src/bash/path/lib"

# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/validation.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/config.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/mtr_args.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/logging.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/plan.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/runner.sh"

VERSION="1.1.0"
ALL_TEST_TYPES=(ICMP4 ICMP6 UDP4 UDP6 TCP4 TCP6 MPLS4 MPLS6 AS4 AS6)
ALL_ROUNDS=(Standard MTU1400 TOS_CS5 TOS_AF11 TTL10 TTL64 FirstTTL3 Timeout5)
DEFAULT_TEST_TYPES=(ICMP4 ICMP6 TCP4 TCP6)
DEFAULT_ROUNDS=(Standard)
DEFAULT_HOSTS_IPV4=(netcologne.de google.com wikipedia.org amazon.de)
DEFAULT_HOSTS_IPV6=(netcologne.de google.com wikipedia.org)

usage() {
	cat <<USAGE
test-network-path.sh v${VERSION}

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

initialize_options() {
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

parse_value_option() {
	local option=$1
	local value=$2

	case "$option" in
	--log-dir)
		validate_path_option "--log-dir" "$value"
		log_dir=$value
		;;
	--json-log)
		validate_path_option "--json-log" "$value"
		json_log=$value
		;;
	--table-log)
		validate_path_option "--table-log" "$value"
		table_log=$value
		;;
	--types)
		types_csv=$value
		types_set=1
		;;
	--rounds)
		rounds_csv=$value
		rounds_set=1
		;;
	--hosts4)
		hosts4_csv=$value
		hosts4_set=1
		;;
	--hosts6)
		hosts6_csv=$value
		hosts6_set=1
		;;
	esac
}

parse_flag_option() {
	case "$1" in
	--list-types)
		list_types=1
		;;
	--list-rounds)
		list_rounds=1
		;;
	--no-summary)
		DO_SUMMARY=0
		;;
	--dry-run)
		DRY_RUN=1
		;;
	--quiet)
		# shellcheck disable=SC2034
		QUIET=1
		;;
	-h | --help)
		usage
		exit 0
		;;
	--version)
		echo "test-network-path.sh v${VERSION}"
		exit 0
		;;
	--)
		return 2
		;;
	*)
		return 1
		;;
	esac
}

parse_options() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--log-dir | --json-log | --table-log | --types | --rounds | --hosts4 | --hosts6)
			[[ $# -ge 2 ]] || die "$1 requires an argument"
			parse_value_option "$1" "$2"
			shift 2
			;;
		*)
			parse_flag_option "$1" || {
				[[ $? -eq 2 ]] && {
					shift
					break
				}
				die "Unknown argument: $1 (use --help)"
			}
			shift
			;;
		esac
	done

	[[ $# -eq 0 ]] || die "Unexpected positional args: $*"
}

validate_startup_options() {
	# Validate log_dir regardless of source (env, CLI, or default)
	validate_path_option "log-dir" "$log_dir"
	[[ "$MTR_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "MTR_TIMEOUT_SECONDS must be a positive integer."

	require_bash4

	if ((list_types)); then
		print_list "${ALL_TEST_TYPES[@]}"
		exit 0
	fi

	if ((list_rounds)); then
		print_list "${ALL_ROUNDS[@]}"
		exit 0
	fi
}

configure_selections() {
	TEST_ORDER=("${DEFAULT_TEST_TYPES[@]}")
	ROUND_ORDER=("${DEFAULT_ROUNDS[@]}")
	HOSTS_IPV4=("${DEFAULT_HOSTS_IPV4[@]}")
	HOSTS_IPV6=("${DEFAULT_HOSTS_IPV6[@]}")

	load_hosts_from_config "$(default_hosts_config_path)"

	if ((types_set)); then
		parse_csv_to_array "$types_csv" "--types"
		validate_selection "test type" "${ALL_TEST_TYPES[@]}"
		TEST_ORDER=("${PARSED_CSV_ITEMS[@]}")
	fi

	if ((rounds_set)); then
		parse_csv_to_array "$rounds_csv" "--rounds"
		validate_selection "round" "${ALL_ROUNDS[@]}"
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

	local h
	for h in "${HOSTS_IPV4[@]}" "${HOSTS_IPV6[@]}"; do
		validate_host "$h"
	done
}

verify_dependencies() {
	if ((DRY_RUN == 0)); then
		require_cmd mtr
		require_cmd jq
	fi
	if ((DO_SUMMARY)) && ((DRY_RUN == 0)); then
		require_cmd column
	fi
}

prepare_dry_run_logs() {
	local ts=$1
	would_json_log=${json_log:-"$log_dir/mtr_results_${ts}.json.log"}
	would_table_log=${table_log:-"$log_dir/mtr_summary_${ts}.log"}
	JSON_LOG=""
	TABLE_LOG=""
}

assign_real_log_paths() {
	local ts=$1
	JSON_LOG=${json_log:-"$log_dir/mtr_results_${ts}.json.log"}
	TABLE_LOG=${table_log:-"$log_dir/mtr_summary_${ts}.log"}
}

prepare_real_log_directories() {
	mkdir -p -- "$log_dir" || die "Failed to create log directory: $log_dir"
	if [[ -n "$json_log" ]]; then
		mkdir -p -- "$(dirname "$JSON_LOG")" || die "Failed to create directory for JSON log"
	fi
	if [[ -n "$table_log" ]]; then
		mkdir -p -- "$(dirname "$TABLE_LOG")" || die "Failed to create directory for table log"
	fi
}

initialize_real_logs() {
	if [[ -d "$JSON_LOG" ]] || [[ -d "$TABLE_LOG" ]]; then
		die "Log path must not be an existing directory: JSON_LOG=$JSON_LOG TABLE_LOG=$TABLE_LOG"
	fi

	: >"$JSON_LOG"
	: >"$TABLE_LOG"
}

prepare_logs() {
	local ts
	ts=$(date +'%Y%m%d_%H%M%S')_$$

	if ((DRY_RUN)); then
		prepare_dry_run_logs "$ts"
		return
	fi

	assign_real_log_paths "$ts"
	prepare_real_log_directories
	initialize_real_logs
}

cleanup_and_exit() {
	local sig=${1:-}
	local code=${2:-130}
	if [[ -n "${CURRENT_MTR_PID:-}" ]]; then
		kill -KILL "$CURRENT_MTR_PID" 2>/dev/null || true
	fi
	rm -f "${CURRENT_TMP:-}" 2>/dev/null
	if [[ -n "$sig" ]]; then
		echo "Interrupted (SIG$sig)" >&2
		exit "$code"
	fi
}

install_cleanup_traps() {
	CURRENT_TMP=""
	CURRENT_MTR_PID=""
	trap 'cleanup_and_exit INT 130' INT
	trap 'cleanup_and_exit TERM 143' TERM
	trap 'cleanup_and_exit' EXIT
}

prepare_run_plan() {
	compute_run_plan
	((TOTAL_RUNS > 0)) || die "No runs planned. Check selected rounds/types/hosts."
}

announce_run_plan() {
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

execute_run_plan() {
	RUN_OK=0
	RUN_FAIL=0

	local start_ts end_ts
	start_ts=$(date +%s)

	local entry round type host idx=0
	for entry in "${PLAN_ENTRIES[@]}"; do
		IFS='|' read -r round type host <<<"$entry"
		((idx++)) || true
		execute_single_run "$round" "$type" "$host" "$idx"
	done

	end_ts=$(date +%s)
	elapsed=$((end_ts - start_ts))
}

finish_run() {
	if ((DRY_RUN)); then
		log_line SUMMARY "Dry-run complete. Planned runs: $TOTAL_RUNS"
		return 0
	fi

	log_line SUMMARY "All tests done. Passed: $RUN_OK, Failed: $RUN_FAIL, Elapsed: ${elapsed}s"
	log_line SUMMARY "Logs: JSON=$JSON_LOG TABLE=$TABLE_LOG"

	if ((RUN_FAIL > 0)); then
		exit 1
	fi
}

main() {
	local log_dir json_log table_log
	local types_csv rounds_csv hosts4_csv hosts6_csv
	local list_types list_rounds types_set rounds_set hosts4_set hosts6_set
	local would_json_log=""
	local would_table_log=""
	local elapsed=0

	initialize_options
	parse_options "$@"
	validate_startup_options
	configure_selections
	verify_dependencies
	prepare_logs
	install_cleanup_traps
	prepare_run_plan
	announce_run_plan
	execute_run_plan
	finish_run
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
