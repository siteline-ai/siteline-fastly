#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

log_info "Starting full infrastructure setup..."

bash "${SCRIPT_DIR}/setup-s3.sh"
bash "${SCRIPT_DIR}/setup-lambda.sh"
bash "${SCRIPT_DIR}/setup-eventbridge.sh"
bash "${SCRIPT_DIR}/setup-fastly.sh"

log_success "Infrastructure setup flow completed."
