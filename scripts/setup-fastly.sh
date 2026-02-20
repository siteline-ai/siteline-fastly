#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd aws
require_cmd jq
require_cmd curl
require_aws_identity

LOG_BUCKET_NAME="${LOG_BUCKET_NAME:-}"
S3_BUCKET_REGION="${S3_BUCKET_REGION:-${AWS_REGION}}"
FASTLY_API_BASE="${FASTLY_API_BASE:-https://api.fastly.com}"
FASTLY_API_TOKEN="${FASTLY_API_TOKEN:-}"
FASTLY_SERVICE_ID="${FASTLY_SERVICE_ID:-}"
FASTLY_SERVICE_VERSION="${FASTLY_SERVICE_VERSION:-}"
FASTLY_LOG_ENDPOINT_NAME="${FASTLY_LOG_ENDPOINT_NAME:-siteline-fastly-s3}"
FASTLY_S3_ACCESS_KEY="${FASTLY_S3_ACCESS_KEY:-}"
FASTLY_S3_SECRET_KEY="${FASTLY_S3_SECRET_KEY:-}"
FASTLY_S3_PATH="${FASTLY_S3_PATH:-fastly/%Y/%m/%d/%H/%M/%S.log.gz}"
FASTLY_LOG_COMPRESSION_CODEC="${FASTLY_LOG_COMPRESSION_CODEC:-gzip}"
FASTLY_LOG_UPLOAD_PERIOD_SECONDS="${FASTLY_LOG_UPLOAD_PERIOD_SECONDS:-60}"
FASTLY_SKIP_ACTIVATE="${FASTLY_SKIP_ACTIVATE:-false}"

if [[ -z "${LOG_BUCKET_NAME}" ]]; then
  die "LOG_BUCKET_NAME is required. Set it in .env or export it before running this script."
fi

if [[ -z "${FASTLY_API_TOKEN}" ]]; then
  die "FASTLY_API_TOKEN is required."
fi

if [[ -z "${FASTLY_SERVICE_ID}" ]]; then
  die "FASTLY_SERVICE_ID is required."
fi

if [[ -z "${FASTLY_S3_ACCESS_KEY}" || -z "${FASTLY_S3_SECRET_KEY}" ]]; then
  die "FASTLY_S3_ACCESS_KEY and FASTLY_S3_SECRET_KEY are required for Fastly S3 logging."
fi

S3_CMD=(aws --region "${S3_BUCKET_REGION}")
if [[ -n "${AWS_PROFILE}" ]]; then
  S3_CMD+=(--profile "${AWS_PROFILE}")
fi

if ! "${S3_CMD[@]}" s3api head-bucket --bucket "${LOG_BUCKET_NAME}" >/dev/null 2>&1; then
  die "S3 bucket ${LOG_BUCKET_NAME} does not exist or is not accessible. Run scripts/setup-s3.sh first."
fi

if [[ -z "${FASTLY_S3_DOMAIN:-}" ]]; then
  if [[ "${S3_BUCKET_REGION}" == "us-east-1" ]]; then
    FASTLY_S3_DOMAIN="s3.amazonaws.com"
  else
    FASTLY_S3_DOMAIN="s3.${S3_BUCKET_REGION}.amazonaws.com"
  fi
else
  FASTLY_S3_DOMAIN="${FASTLY_S3_DOMAIN}"
fi

DEFAULT_FASTLY_LOG_FORMAT='{"timestamp":"%{begin:%Y-%m-%dT%H:%M:%S%z}t","host":"%{json.escape(req.http.host)}V","url":"%{json.escape(req.url)}V","request_method":"%{json.escape(req.method)}V","response_status":%>s,"time_elapsed_usec":%D,"request_user_agent":"%{json.escape(req.http.User-Agent)}V","request_referer":"%{json.escape(req.http.Referer)}V","client_ip":"%{json.escape(req.http.Fastly-Client-IP)}V"}'
FASTLY_LOG_FORMAT="${FASTLY_LOG_FORMAT:-${DEFAULT_FASTLY_LOG_FORMAT}}"

fastly_request() {
  local method="${1}"
  local path="${2}"
  shift 2

  curl --silent --show-error --fail \
    --request "${method}" \
    --header "Fastly-Key: ${FASTLY_API_TOKEN}" \
    --header 'Accept: application/json' \
    "$@" \
    "${FASTLY_API_BASE}${path}"
}

get_active_version() {
  fastly_request GET "/service/${FASTLY_SERVICE_ID}/details" | jq -r '.active_version.number // empty'
}

get_version_locked() {
  local version_number="${1}"
  fastly_request GET "/service/${FASTLY_SERVICE_ID}/version/${version_number}" | jq -r '.locked'
}

ensure_working_version() {
  if [[ -n "${FASTLY_SERVICE_VERSION}" ]]; then
    printf '%s\n' "${FASTLY_SERVICE_VERSION}"
    return
  fi

  local active_version
  active_version="$(get_active_version)"
  if [[ -z "${active_version}" ]]; then
    die "Could not determine active Fastly service version. Set FASTLY_SERVICE_VERSION explicitly."
  fi

  local locked
  locked="$(get_version_locked "${active_version}")"

  if [[ "${locked}" == "true" ]]; then
    log_info "Fastly active version ${active_version} is locked. Cloning to create an editable version..."
    fastly_request PUT "/service/${FASTLY_SERVICE_ID}/version/${active_version}/clone" | jq -r '.number'
    return
  fi

  printf '%s\n' "${active_version}"
}

apply_logging_endpoint() {
  local method="${1}"
  local path="${2}"

  fastly_request "${method}" "${path}" \
    --data-urlencode "name=${FASTLY_LOG_ENDPOINT_NAME}" \
    --data-urlencode "bucket_name=${LOG_BUCKET_NAME}" \
    --data-urlencode "access_key=${FASTLY_S3_ACCESS_KEY}" \
    --data-urlencode "secret_key=${FASTLY_S3_SECRET_KEY}" \
    --data-urlencode "path=${FASTLY_S3_PATH}" \
    --data-urlencode "domain=${FASTLY_S3_DOMAIN}" \
    --data-urlencode "compression_codec=${FASTLY_LOG_COMPRESSION_CODEC}" \
    --data-urlencode "period=${FASTLY_LOG_UPLOAD_PERIOD_SECONDS}" \
    --data-urlencode "format=${FASTLY_LOG_FORMAT}" >/dev/null
}

WORKING_VERSION="$(ensure_working_version)"
if [[ -z "${WORKING_VERSION}" ]]; then
  die "Unable to determine Fastly service version for update."
fi

log_info "Using Fastly service ${FASTLY_SERVICE_ID} version ${WORKING_VERSION}."

TMP_RESPONSE="$(mktemp)"
trap 'rm -f "${TMP_RESPONSE}"' EXIT

endpoint_status="$(
  curl --silent --output "${TMP_RESPONSE}" --write-out '%{http_code}' \
    --header "Fastly-Key: ${FASTLY_API_TOKEN}" \
    --header 'Accept: application/json' \
    "${FASTLY_API_BASE}/service/${FASTLY_SERVICE_ID}/version/${WORKING_VERSION}/logging/s3/${FASTLY_LOG_ENDPOINT_NAME}"
)"

if [[ "${endpoint_status}" == "200" ]]; then
  log_warn "Fastly S3 logging endpoint ${FASTLY_LOG_ENDPOINT_NAME} already exists on version ${WORKING_VERSION}. Updating in place."
  apply_logging_endpoint "PUT" "/service/${FASTLY_SERVICE_ID}/version/${WORKING_VERSION}/logging/s3/${FASTLY_LOG_ENDPOINT_NAME}"
elif [[ "${endpoint_status}" == "404" ]]; then
  log_info "Creating Fastly S3 logging endpoint ${FASTLY_LOG_ENDPOINT_NAME} on version ${WORKING_VERSION}."
  apply_logging_endpoint "POST" "/service/${FASTLY_SERVICE_ID}/version/${WORKING_VERSION}/logging/s3"
else
  endpoint_response="$(cat "${TMP_RESPONSE}")"
  die "Unexpected Fastly API response while checking endpoint (HTTP ${endpoint_status}): ${endpoint_response}"
fi

if [[ "${FASTLY_SKIP_ACTIVATE}" == "true" ]]; then
  log_warn "FASTLY_SKIP_ACTIVATE=true, leaving Fastly version ${WORKING_VERSION} unactivated."
else
  log_info "Activating Fastly service version ${WORKING_VERSION}..."
  fastly_request PUT "/service/${FASTLY_SERVICE_ID}/version/${WORKING_VERSION}/activate" >/dev/null
  log_success "Activated Fastly service version ${WORKING_VERSION}."
fi

log_success "Fastly S3 logging endpoint ${FASTLY_LOG_ENDPOINT_NAME} configured for bucket ${LOG_BUCKET_NAME}."
