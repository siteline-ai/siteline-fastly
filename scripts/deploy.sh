#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

log_info "Building and packaging Lambda..."
(cd "${ROOT_DIR}" && npm run package)

log_info "Provisioning Lambda infrastructure..."
bash "${SCRIPT_DIR}/setup-lambda.sh"

log_success "Deploy complete."
