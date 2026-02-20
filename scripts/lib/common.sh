#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
AWS_PAGER=""
export AWS_PAGER

AWS_CMD=(aws --region "${AWS_REGION}")
if [[ -n "${AWS_PROFILE}" ]]; then
  AWS_CMD+=(--profile "${AWS_PROFILE}")
fi

if [[ -t 1 ]]; then
  COLOR_RESET=$'\033[0m'
  COLOR_GREEN=$'\033[32m'
  COLOR_YELLOW=$'\033[33m'
  COLOR_RED=$'\033[31m'
  COLOR_BLUE=$'\033[34m'
else
  COLOR_RESET=''
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_RED=''
  COLOR_BLUE=''
fi

log_info() {
  printf '%s[INFO]%s %s\n' "${COLOR_BLUE}" "${COLOR_RESET}" "$*"
}

log_success() {
  printf '%s[SUCCESS]%s %s\n' "${COLOR_GREEN}" "${COLOR_RESET}" "$*"
}

log_warn() {
  printf '%s[WARN]%s %s\n' "${COLOR_YELLOW}" "${COLOR_RESET}" "$*" >&2
}

log_error() {
  printf '%s[ERROR]%s %s\n' "${COLOR_RED}" "${COLOR_RESET}" "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

require_cmd() {
  local command_name="${1}"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    die "Missing required command: ${command_name}"
  fi
}

confirm() {
  local prompt="${1}"
  if [[ "${AUTO_APPROVE}" == "true" ]]; then
    log_info "AUTO_APPROVE=true, continuing without prompt: ${prompt}"
    return 0
  fi

  local answer
  read -r -p "${prompt} [y/N]: " answer
  [[ "${answer}" =~ ^[Yy]$ ]]
}

require_aws_identity() {
  local account_id
  if ! account_id="$("${AWS_CMD[@]}" sts get-caller-identity --query 'Account' --output text 2>/dev/null)"; then
    die "Unable to authenticate with AWS. Check AWS credentials, region, and IAM permissions."
  fi

  export AWS_ACCOUNT_ID="${account_id}"
  log_info "Using AWS account ${AWS_ACCOUNT_ID} in region ${AWS_REGION}."
}
