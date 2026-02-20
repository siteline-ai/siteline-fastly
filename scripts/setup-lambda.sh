#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd aws
require_cmd jq
require_aws_identity

ASSUME_ROLE_POLICY_FILE="${ROOT_DIR}/config/iam/lambda-assume-role-policy.json"
LAMBDA_FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-siteline-fastly-s3-processor}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-siteline-fastly-s3-processor-role}"
LAMBDA_RUNTIME="${LAMBDA_RUNTIME:-nodejs20.x}"
LAMBDA_HANDLER="${LAMBDA_HANDLER:-index.handler}"
LAMBDA_ARCHITECTURE="${LAMBDA_ARCHITECTURE:-x86_64}"
LAMBDA_TIMEOUT_SECONDS="${LAMBDA_TIMEOUT_SECONDS:-60}"
LAMBDA_MEMORY_MB="${LAMBDA_MEMORY_MB:-256}"
LAMBDA_ZIP_PATH="${LAMBDA_ZIP_PATH:-${ROOT_DIR}/dist/lambda-edge.zip}"
LOG_BUCKET_NAME="${LOG_BUCKET_NAME:-}"
APP_NAME="${APP_NAME:-siteline-fastly-s3-processor}"
SITELINE_WEBSITE_KEY="${SITELINE_WEBSITE_KEY:-}"
SITELINE_ENDPOINT="${SITELINE_ENDPOINT:-https://api.siteline.ai/v1/intake/pageview}"
SITELINE_DEBUG="${SITELINE_DEBUG:-false}"
LAMBDA_CREATE_MAX_RETRIES="${LAMBDA_CREATE_MAX_RETRIES:-8}"
LAMBDA_CREATE_INITIAL_DELAY_SECONDS="${LAMBDA_CREATE_INITIAL_DELAY_SECONDS:-2}"

if [[ -z "${LOG_BUCKET_NAME}" ]]; then
  die "LOG_BUCKET_NAME is required. Set it in .env or export it before running this script."
fi

if [[ ! -f "${LAMBDA_ZIP_PATH}" ]]; then
  log_warn "Package not found at ${LAMBDA_ZIP_PATH}."
  if confirm "Run npm run package now?"; then
    (cd "${ROOT_DIR}" && npm run package)
  else
    die "Lambda package is required. Run npm run package and re-run this script."
  fi
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
EXECUTION_POLICY_FILE="${TMP_DIR}/lambda-execution-policy.json"
LAMBDA_ENV_FILE="${TMP_DIR}/lambda-environment.json"

cat >"${EXECUTION_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudWatchLogs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:*:*:*"
    },
    {
      "Sid": "AllowReadFastlyLogsFromS3",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::${LOG_BUCKET_NAME}/*"
    }
  ]
}
EOF

jq -n \
  --arg appName "${APP_NAME}" \
  --arg logBucketName "${LOG_BUCKET_NAME}" \
  --arg websiteKey "${SITELINE_WEBSITE_KEY}" \
  --arg endpoint "${SITELINE_ENDPOINT}" \
  --arg debug "${SITELINE_DEBUG}" \
  '
  {
    Variables:
      ({
        APP_NAME: $appName,
        LOG_BUCKET_NAME: $logBucketName,
        SITELINE_ENDPOINT: $endpoint,
        SITELINE_DEBUG: $debug
      } + (if $websiteKey != "" then {SITELINE_WEBSITE_KEY: $websiteKey} else {} end))
  }
  ' >"${LAMBDA_ENV_FILE}"

log_info "Ensuring IAM role ${LAMBDA_ROLE_NAME} exists..."
if ! ROLE_ARN="$("${AWS_CMD[@]}" iam get-role --role-name "${LAMBDA_ROLE_NAME}" --query 'Role.Arn' --output text 2>/dev/null)"; then
  "${AWS_CMD[@]}" iam create-role \
    --role-name "${LAMBDA_ROLE_NAME}" \
    --assume-role-policy-document "file://${ASSUME_ROLE_POLICY_FILE}" >/dev/null

  ROLE_ARN="$("${AWS_CMD[@]}" iam get-role --role-name "${LAMBDA_ROLE_NAME}" --query 'Role.Arn' --output text)"
  log_success "Created IAM role ${LAMBDA_ROLE_NAME}."
else
  log_warn "IAM role ${LAMBDA_ROLE_NAME} already exists. Reusing it."
fi

"${AWS_CMD[@]}" iam update-assume-role-policy \
  --role-name "${LAMBDA_ROLE_NAME}" \
  --policy-document "file://${ASSUME_ROLE_POLICY_FILE}" >/dev/null

"${AWS_CMD[@]}" iam put-role-policy \
  --role-name "${LAMBDA_ROLE_NAME}" \
  --policy-name "${LAMBDA_ROLE_NAME}-execution" \
  --policy-document "file://${EXECUTION_POLICY_FILE}" >/dev/null
log_success "IAM execution policy applied to ${LAMBDA_ROLE_NAME}."

log_info "Ensuring Lambda function ${LAMBDA_FUNCTION_NAME} exists..."
if "${AWS_CMD[@]}" lambda get-function --function-name "${LAMBDA_FUNCTION_NAME}" >/dev/null 2>&1; then
  log_warn "Lambda ${LAMBDA_FUNCTION_NAME} already exists. Updating code and configuration."
  "${AWS_CMD[@]}" lambda update-function-code \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --zip-file "fileb://${LAMBDA_ZIP_PATH}" >/dev/null
  "${AWS_CMD[@]}" lambda wait function-updated --function-name "${LAMBDA_FUNCTION_NAME}"

  "${AWS_CMD[@]}" lambda update-function-configuration \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --runtime "${LAMBDA_RUNTIME}" \
    --handler "${LAMBDA_HANDLER}" \
    --role "${ROLE_ARN}" \
    --architectures "${LAMBDA_ARCHITECTURE}" \
    --timeout "${LAMBDA_TIMEOUT_SECONDS}" \
    --memory-size "${LAMBDA_MEMORY_MB}" \
    --environment "file://${LAMBDA_ENV_FILE}" >/dev/null
  "${AWS_CMD[@]}" lambda wait function-updated --function-name "${LAMBDA_FUNCTION_NAME}"
else
  attempt=1
  delay_seconds="${LAMBDA_CREATE_INITIAL_DELAY_SECONDS}"
  while true; do
    if create_output="$("${AWS_CMD[@]}" lambda create-function \
      --function-name "${LAMBDA_FUNCTION_NAME}" \
      --runtime "${LAMBDA_RUNTIME}" \
      --handler "${LAMBDA_HANDLER}" \
      --role "${ROLE_ARN}" \
      --architectures "${LAMBDA_ARCHITECTURE}" \
      --timeout "${LAMBDA_TIMEOUT_SECONDS}" \
      --memory-size "${LAMBDA_MEMORY_MB}" \
      --environment "file://${LAMBDA_ENV_FILE}" \
      --zip-file "fileb://${LAMBDA_ZIP_PATH}" 2>&1)"; then
      break
    fi

    if [[ "${create_output}" == *"cannot be assumed by Lambda"* ]] && [[ "${attempt}" -lt "${LAMBDA_CREATE_MAX_RETRIES}" ]]; then
      log_warn "IAM role propagation in progress. Retrying Lambda create in ${delay_seconds}s (${attempt}/${LAMBDA_CREATE_MAX_RETRIES})..."
      sleep "${delay_seconds}"
      attempt=$((attempt + 1))
      delay_seconds=$((delay_seconds * 2))
      continue
    fi

    printf '%s\n' "${create_output}" >&2
    die "Failed to create Lambda function ${LAMBDA_FUNCTION_NAME}."
  done

  "${AWS_CMD[@]}" lambda wait function-active --function-name "${LAMBDA_FUNCTION_NAME}"
  log_success "Created Lambda function ${LAMBDA_FUNCTION_NAME}."
fi

FUNCTION_ARN="$("${AWS_CMD[@]}" lambda get-function --function-name "${LAMBDA_FUNCTION_NAME}" --query 'Configuration.FunctionArn' --output text)"
log_success "Lambda setup complete: ${FUNCTION_ARN}"
