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
LAMBDA_FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-siteline-fastly-s3-processor}"
EVENT_RULE_NAME="${EVENT_RULE_NAME:-siteline-fastly-s3-log-created}"
EVENT_TARGET_ID="${EVENT_TARGET_ID:-siteline-lambda-target}"

if [[ -z "${LOG_BUCKET_NAME}" ]]; then
  die "LOG_BUCKET_NAME is required. Set it in .env or export it before running this script."
fi

if ! LAMBDA_ARN="$("${AWS_CMD[@]}" lambda get-function --function-name "${LAMBDA_FUNCTION_NAME}" --query 'Configuration.FunctionArn' --output text 2>/dev/null)"; then
  die "Lambda function ${LAMBDA_FUNCTION_NAME} not found. Run scripts/setup-lambda.sh first."
fi

event_pattern="$(jq -n --arg bucket "${LOG_BUCKET_NAME}" '{
  source: ["aws.s3"],
  "detail-type": ["Object Created"],
  detail: {
    bucket: {
      name: [$bucket]
    }
  }
}')"

RULE_ARN="$("${AWS_CMD[@]}" events put-rule \
  --name "${EVENT_RULE_NAME}" \
  --event-pattern "${event_pattern}" \
  --state ENABLED \
  --query 'RuleArn' --output text)"
log_success "EventBridge rule ready: ${EVENT_RULE_NAME}"

statement_id="${EVENT_RULE_NAME//[^a-zA-Z0-9-_]/-}-invoke"
lambda_policy="$("${AWS_CMD[@]}" lambda get-policy --function-name "${LAMBDA_FUNCTION_NAME}" --query 'Policy' --output text 2>/dev/null || true)"

if [[ -n "${lambda_policy}" ]] && echo "${lambda_policy}" | jq -e --arg sid "${statement_id}" '.Statement[]? | select(.Sid == $sid)' >/dev/null; then
  log_warn "Lambda invoke permission ${statement_id} already exists. Skipping."
else
  "${AWS_CMD[@]}" lambda add-permission \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --statement-id "${statement_id}" \
    --action 'lambda:InvokeFunction' \
    --principal events.amazonaws.com \
    --source-arn "${RULE_ARN}" >/dev/null
  log_success "Added EventBridge invoke permission on ${LAMBDA_FUNCTION_NAME}."
fi

targets_payload="$(jq -n \
  --arg id "${EVENT_TARGET_ID}" \
  --arg arn "${LAMBDA_ARN}" \
  '[
    {
      Id: $id,
      Arn: $arn
    }
  ]')"

put_targets_result="$("${AWS_CMD[@]}" events put-targets \
  --rule "${EVENT_RULE_NAME}" \
  --targets "${targets_payload}" \
  --output json)"

failed_entries="$(echo "${put_targets_result}" | jq -r '.FailedEntryCount')"
if [[ "${failed_entries}" != "0" ]]; then
  die "Failed to attach EventBridge target. Details: ${put_targets_result}"
fi

log_success "Linked S3 object-created events directly to Lambda via EventBridge."
log_success "EventBridge setup complete."
