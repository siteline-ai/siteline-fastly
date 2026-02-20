#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd aws
require_cmd jq
require_aws_identity

LOG_BUCKET_NAME="${LOG_BUCKET_NAME:-}"
S3_BUCKET_REGION="${S3_BUCKET_REGION:-${AWS_REGION}}"

if [[ -z "${LOG_BUCKET_NAME}" ]]; then
  die "LOG_BUCKET_NAME is required. Set it in .env or export it before running this script."
fi

S3_CMD=(aws --region "${S3_BUCKET_REGION}")
if [[ -n "${AWS_PROFILE}" ]]; then
  S3_CMD+=(--profile "${AWS_PROFILE}")
fi

bucket_exists() {
  "${S3_CMD[@]}" s3api head-bucket --bucket "${LOG_BUCKET_NAME}" >/dev/null 2>&1
}

log_info "Ensuring S3 bucket ${LOG_BUCKET_NAME} exists in region ${S3_BUCKET_REGION}..."
if bucket_exists; then
  log_warn "Bucket ${LOG_BUCKET_NAME} already exists. Skipping create."
  existing_region="$("${S3_CMD[@]}" s3api get-bucket-location --bucket "${LOG_BUCKET_NAME}" --query 'LocationConstraint' --output text 2>/dev/null || true)"
  if [[ "${existing_region}" == "None" || -z "${existing_region}" ]]; then
    existing_region="us-east-1"
  fi
  if [[ "${existing_region}" != "${S3_BUCKET_REGION}" ]]; then
    log_warn "Bucket region is ${existing_region} while S3_BUCKET_REGION=${S3_BUCKET_REGION}."
  fi
else
  if [[ "${S3_BUCKET_REGION}" == "us-east-1" ]]; then
    if ! "${S3_CMD[@]}" s3api create-bucket --bucket "${LOG_BUCKET_NAME}" >/dev/null; then
      die "Unable to create bucket ${LOG_BUCKET_NAME}. The bucket name may already be in use."
    fi
  else
    if ! "${S3_CMD[@]}" s3api create-bucket \
      --bucket "${LOG_BUCKET_NAME}" \
      --create-bucket-configuration "LocationConstraint=${S3_BUCKET_REGION}" >/dev/null; then
      die "Unable to create bucket ${LOG_BUCKET_NAME}. The bucket name may already be in use."
    fi
  fi
  log_success "Created bucket ${LOG_BUCKET_NAME}."
fi

log_info "Applying S3 security baseline (public access block + SSE-S3 encryption)..."
"${S3_CMD[@]}" s3api put-public-access-block \
  --bucket "${LOG_BUCKET_NAME}" \
  --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null

"${S3_CMD[@]}" s3api put-bucket-encryption \
  --bucket "${LOG_BUCKET_NAME}" \
  --server-side-encryption-configuration 'Rules=[{ApplyServerSideEncryptionByDefault={SSEAlgorithm=AES256}}]' >/dev/null

existing_notifications="$("${S3_CMD[@]}" s3api get-bucket-notification-configuration --bucket "${LOG_BUCKET_NAME}" --output json)"
if echo "${existing_notifications}" | jq -e '.EventBridgeConfiguration != null' >/dev/null; then
  log_warn "S3 EventBridge notifications are already enabled on ${LOG_BUCKET_NAME}. Skipping."
else
  tmp_notification_file="$(mktemp)"
  trap 'rm -f "${tmp_notification_file}"' EXIT

  updated_notifications="$(
    printf '%s\n' "${existing_notifications}" | jq -c 'if type == "object" then . else {} end | .EventBridgeConfiguration = {}' 2>/dev/null || true
  )"

  # Some AWS CLI responses can be empty or non-JSON despite exit=0.
  # Fall back to the minimal valid EventBridge notification document.
  if [[ -z "${updated_notifications}" || "${updated_notifications}" == "null" ]]; then
    updated_notifications='{"EventBridgeConfiguration":{}}'
    log_warn "Could not reuse existing S3 notifications; applying minimal EventBridge notification config."
  fi

  printf '%s\n' "${updated_notifications}" >"${tmp_notification_file}"
  "${S3_CMD[@]}" s3api put-bucket-notification-configuration \
    --bucket "${LOG_BUCKET_NAME}" \
    --notification-configuration "file://${tmp_notification_file}" >/dev/null

  rm -f "${tmp_notification_file}"
  trap - EXIT
  log_success "Enabled S3 -> EventBridge notifications for ${LOG_BUCKET_NAME}."
fi

log_success "S3 setup complete."
