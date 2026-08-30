#!/usr/bin/env bash
# load.sh - explicit composition root for the Bash path feature

PATH_FEATURE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck disable=SC1091
source "$PATH_FEATURE_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$PATH_FEATURE_DIR/lib/validation.sh"
# shellcheck disable=SC1091
source "$PATH_FEATURE_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$PATH_FEATURE_DIR/lib/mtr_args.sh"
# shellcheck disable=SC1091
source "$PATH_FEATURE_DIR/lib/logging.sh"
# shellcheck disable=SC1091
source "$PATH_FEATURE_DIR/lib/plan.sh"
# shellcheck disable=SC1091
source "$PATH_FEATURE_DIR/lib/runner.sh"
# shellcheck disable=SC1091
source "$PATH_FEATURE_DIR/main.sh"
